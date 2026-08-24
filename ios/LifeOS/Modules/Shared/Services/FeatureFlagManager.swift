// MARK: - Feature Flag Manager
// Remote kill switches with cached fallback per life_os_technical_architecture.md §9C.

import Foundation
import GRDB
import OSLog

enum AppFeatureFlag: String, CaseIterable, Codable, Sendable {
    case aiFoodPhotoEnabled = "ai_food_photo_enabled"
    case aiVoiceLoggingEnabled = "ai_voice_logging_enabled"
    case aiLabOcrEnabled = "ai_lab_ocr_enabled"
    case aiInsightsEnabled = "ai_insights_enabled"
    case openrouterAvailable = "openrouter_available"
    case guardianModeEnabled = "guardian_mode_enabled"
    case batchRecipesEnabled = "batch_recipes_enabled"

    var defaultEnabled: Bool {
        switch self {
        case .batchRecipesEnabled:
            // Meal prep ships enabled by default; remote config remains a kill switch.
            return true
        case .guardianModeEnabled:
            // Guardian ships enabled by default, but remote flags and runtime banners can still disable it.
            return true
        default:
            return true
        }
    }
}

struct FeatureFlagValue: Codable, Equatable, Sendable {
    let enabled: Bool
    let variant: String?
    let fetchedAt: Date?
}

enum FeatureFlagSnapshotSource: String, Codable, Equatable, Sendable {
    case remote
    case cache
    case safeFallback
    case defaults
}

struct FeatureFlagSnapshot: Equatable, Sendable {
    let source: FeatureFlagSnapshotSource
    let resolvedAt: Date
    let values: [AppFeatureFlag: FeatureFlagValue]

    func isEnabled(_ flag: AppFeatureFlag) -> Bool {
        values[flag]?.enabled ?? flag.defaultEnabled
    }

    func variant(for flag: AppFeatureFlag) -> String? {
        values[flag]?.variant
    }

    static func defaults(resolvedAt: Date) -> FeatureFlagSnapshot {
        let values = Dictionary(
            uniqueKeysWithValues: AppFeatureFlag.allCases.map { flag in
                (
                    flag,
                    FeatureFlagValue(
                        enabled: flag.defaultEnabled,
                        variant: nil,
                        fetchedAt: nil
                    )
                )
            }
        )
        return FeatureFlagSnapshot(source: .defaults, resolvedAt: resolvedAt, values: values)
    }
}

private struct FeatureFlagRemotePayload: Decodable, Sendable {
    let flagKey: String
    let enabled: Bool
    let variant: String?
}

private struct FeatureFlagsRemoteResponse: Decodable, Sendable {
    let flags: [FeatureFlagRemotePayload]
    let fetchedAt: Date
    let ttlSeconds: Int
}

struct FeatureFlagCacheEntry: Codable, Equatable, Sendable, SnakeCaseGRDBRecord {
    static let databaseTableName = "feature_flags_cache"

    var flagKey: String
    var enabled: Bool
    var variant: String?
    var fetchedAt: Date
}

final class FeatureFlagManager: @unchecked Sendable {
    static let cacheTTL: TimeInterval = 60 * 60
    static let didUpdateNotification = Notification.Name("lifeos.feature_flags.did_update")

    private static let cacheOwnerAuthIdDefaultsKey = "lifeos.feature_flags.cache_owner_auth_id"

    private let dbQueue: DatabaseQueue
    private let apiClient: APIClient
    private let logger = Logger(subsystem: "com.lifeos.app", category: "FeatureFlags")
    private let snapshotLock = OSAllocatedUnfairLock<FeatureFlagSnapshot>(
        initialState: .defaults(resolvedAt: Date())
    )

#if DEBUG
    private static let testNowProvider = LockedTestOverride<@Sendable () -> Date>()
#endif

    init(
        dbQueue: DatabaseQueue,
        apiClient: APIClient = APIClient()
    ) {
        self.dbQueue = dbQueue
        self.apiClient = apiClient
        snapshotLock.withLock { $0 = .defaults(resolvedAt: currentDate()) }
    }

    func currentSnapshot() -> FeatureFlagSnapshot {
        snapshotLock.withLock { $0 }
    }

    func isEnabled(_ flag: AppFeatureFlag) -> Bool {
        currentSnapshot().isEnabled(flag)
    }

    @discardableResult
    func refresh(
        hasCloudSession: Bool,
        authId: UUID?
    ) async -> FeatureFlagSnapshot {
        let now = currentDate()

        guard hasCloudSession, let authId else {
            let fallback = await loadFallbackSnapshot(authId: authId, now: now)
            return setSnapshot(fallback)
        }

        do {
            let response: FeatureFlagsRemoteResponse = try await apiClient.callEdgeRoute(
                function: "api-config-feature-flags",
                route: "",
                method: "GET",
                queryItems: [],
                body: nil,
                headers: [:],
                maxAttempts: 1
            )

            let remoteSnapshot = try await persistRemoteSnapshot(
                response: response,
                authId: authId,
                now: now
            )
            return setSnapshot(remoteSnapshot)
        } catch {
            logger.error("Remote feature flag refresh failed: \(error.localizedDescription, privacy: .public)")
            let fallback = await loadFallbackSnapshot(authId: authId, now: now)
            return setSnapshot(fallback)
        }
    }

    @discardableResult
    func useDefaults() -> FeatureFlagSnapshot {
        setSnapshot(.defaults(resolvedAt: currentDate()))
    }

    private func loadFallbackSnapshot(authId: UUID?, now: Date) async -> FeatureFlagSnapshot {
        do {
            if let entries = try Self.loadCachedEntries(
                dbQueue: dbQueue,
                authId: authId
            ) {
                let latestFetchedAt = entries.map(\.fetchedAt).max() ?? .distantPast
                if now.timeIntervalSince(latestFetchedAt) <= Self.cacheTTL {
                    return Self.snapshot(from: entries, source: .cache, resolvedAt: now)
                }

                logger.warning(
                    "Feature flag cache is stale by \(Int(now.timeIntervalSince(latestFetchedAt)), privacy: .public)s; using safe fallback"
                )
                return Self.safeFallbackSnapshot(from: entries, resolvedAt: now)
            }
        } catch {
            logger.error("Failed to load cached feature flags: \(error.localizedDescription, privacy: .public)")
        }
        return .defaults(resolvedAt: now)
    }

    private func persistRemoteSnapshot(
        response: FeatureFlagsRemoteResponse,
        authId: UUID,
        now: Date
    ) async throws -> FeatureFlagSnapshot {
        let mergedEntries = Self.makeMergedEntries(
            from: response.flags,
            fetchedAt: response.fetchedAt
        )

        try await dbQueue.write { db in
            try FeatureFlagCacheEntry.deleteAll(db)
            for entry in mergedEntries {
                try entry.insert(db)
            }
        }

        UserDefaults.standard.set(authId.uuidString, forKey: Self.cacheOwnerAuthIdDefaultsKey)
        logger.info(
            "Cached \(mergedEntries.count) feature flags (ttl=\(response.ttlSeconds, privacy: .public)s)"
        )

        return Self.snapshot(
            from: mergedEntries,
            source: .remote,
            resolvedAt: now
        )
    }

    @discardableResult
    private func setSnapshot(_ snapshot: FeatureFlagSnapshot) -> FeatureFlagSnapshot {
        let didChange = snapshotLock.withLock { current in
            let changed = current != snapshot
            current = snapshot
            return changed
        }
        if didChange {
            NotificationCenter.default.post(
                name: Self.didUpdateNotification,
                object: self,
                userInfo: ["snapshot": snapshot]
            )
        }
        return snapshot
    }

    private func currentDate() -> Date {
#if DEBUG
        if let provider = Self.testNowProvider.value {
            return provider()
        }
#endif
        return Date()
    }

    private static func loadCachedEntries(
        dbQueue: DatabaseQueue,
        authId: UUID?
    ) throws -> [FeatureFlagCacheEntry]? {
        guard let authId,
              UserDefaults.standard.string(forKey: cacheOwnerAuthIdDefaultsKey) == authId.uuidString else {
            return nil
        }

        let entries = try dbQueue.read { db in
            try FeatureFlagCacheEntry.fetchAll(db)
        }
        guard !entries.isEmpty else { return nil }
        return entries
    }

    private static func makeMergedEntries(
        from remoteFlags: [FeatureFlagRemotePayload],
        fetchedAt: Date
    ) -> [FeatureFlagCacheEntry] {
        let remoteMap = Dictionary(uniqueKeysWithValues: remoteFlags.map { ($0.flagKey, $0) })

        return AppFeatureFlag.allCases.map { flag in
            let remote = remoteMap[flag.rawValue]
            return FeatureFlagCacheEntry(
                flagKey: flag.rawValue,
                enabled: remote?.enabled ?? flag.defaultEnabled,
                variant: remote?.variant,
                fetchedAt: fetchedAt
            )
        }
    }

    private static func snapshot(
        from entries: [FeatureFlagCacheEntry],
        source: FeatureFlagSnapshotSource,
        resolvedAt: Date
    ) -> FeatureFlagSnapshot {
        let mappedValues = Dictionary(
            uniqueKeysWithValues: entries.compactMap { entry -> (AppFeatureFlag, FeatureFlagValue)? in
                guard let flag = AppFeatureFlag(rawValue: entry.flagKey) else {
                    return nil
                }
                return (
                    flag,
                    FeatureFlagValue(
                        enabled: entry.enabled,
                        variant: entry.variant,
                        fetchedAt: entry.fetchedAt
                    )
                )
            }
        )

        let mergedValues = AppFeatureFlag.allCases.reduce(into: [AppFeatureFlag: FeatureFlagValue]()) { result, flag in
            if let existing = mappedValues[flag] {
                result[flag] = existing
            } else {
                result[flag] = FeatureFlagValue(
                    enabled: flag.defaultEnabled,
                    variant: nil,
                    fetchedAt: nil
                )
            }
        }

        return FeatureFlagSnapshot(
            source: source,
            resolvedAt: resolvedAt,
            values: mergedValues
        )
    }

    private static func safeFallbackSnapshot(
        from staleEntries: [FeatureFlagCacheEntry],
        resolvedAt: Date
    ) -> FeatureFlagSnapshot {
        let staleMap = Dictionary(
            uniqueKeysWithValues: staleEntries.compactMap { entry -> (AppFeatureFlag, FeatureFlagCacheEntry)? in
                guard let flag = AppFeatureFlag(rawValue: entry.flagKey) else {
                    return nil
                }
                return (flag, entry)
            }
        )

        let mergedValues = AppFeatureFlag.allCases.reduce(into: [AppFeatureFlag: FeatureFlagValue]()) { result, flag in
            if let staleEntry = staleMap[flag] {
                result[flag] = FeatureFlagValue(
                    enabled: staleEntry.enabled,
                    variant: nil,
                    fetchedAt: staleEntry.fetchedAt
                )
            } else {
                result[flag] = FeatureFlagValue(
                    enabled: flag.defaultEnabled,
                    variant: nil,
                    fetchedAt: staleMap[flag]?.fetchedAt
                )
            }
        }

        return FeatureFlagSnapshot(
            source: .safeFallback,
            resolvedAt: resolvedAt,
            values: mergedValues
        )
    }
}

#if DEBUG
extension FeatureFlagManager {
    static func _testSetNowProvider(_ provider: (@Sendable () -> Date)?) {
        testNowProvider.value = provider
    }

    static func _testSetCacheOwnerAuthId(_ authId: String?) {
        if let authId {
            UserDefaults.standard.set(authId, forKey: cacheOwnerAuthIdDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: cacheOwnerAuthIdDefaultsKey)
        }
    }

    func _testReplaceSnapshot(_ snapshot: FeatureFlagSnapshot) {
        snapshotLock.withLock { $0 = snapshot }
    }

    func _testPersistCache(entries: [FeatureFlagCacheEntry], authId: UUID?) throws {
        try dbQueue.write { db in
            try FeatureFlagCacheEntry.deleteAll(db)
            for entry in entries {
                try entry.insert(db)
            }
        }
        Self._testSetCacheOwnerAuthId(authId?.uuidString)
    }
}
#endif
