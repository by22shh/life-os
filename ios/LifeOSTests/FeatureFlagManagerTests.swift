import Foundation
import XCTest
import GRDB
@testable import LifeOS

private final class FeatureFlagAttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        attempts += 1
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }
}

final class FeatureFlagManagerTests: XCTestCase {

    override func tearDown() async throws {
        try await super.tearDown()
        APIClient._testResetOverrides()
        FeatureFlagManager._testSetNowProvider(nil)
        FeatureFlagManager._testSetCacheOwnerAuthId(nil)
        AppContainer.shared = nil

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(nil)
            AuthManager._testSetActiveHasCloudSession(false)
            GuardianManager._testSetAuthorizationOverride(nil)
            GuardianManager._testSetRequestAuthorization(nil)
            GuardianManager._testSetRevokeAuthorization(nil)
            GuardianManager._testSetSystemRevokeAuthorization(nil)
            GuardianManager._testSetDefaultRequestAuthorization(nil)
            GuardianManager._testSetDefaultSystemRevokeAuthorization(nil)
            GuardianManager._testSetNowProvider(nil)
            GuardianManager._testSetSelectionPresenceOverride(nil)
            GuardianManager._testResetPersistedState()
        }
    }

    func testFeatureFlagManagerUsesDefaultShippedFlagsWithoutCloudSession() async throws {
        let manager = try DatabaseManager.inMemory()
        let featureFlags = FeatureFlagManager(dbQueue: manager.dbQueue)

        let snapshot = await featureFlags.refresh(
            hasCloudSession: false,
            authId: nil
        )

        XCTAssertEqual(snapshot.source, .defaults)
        XCTAssertTrue(snapshot.isEnabled(.guardianModeEnabled))
        XCTAssertTrue(snapshot.isEnabled(.openrouterAvailable))
        XCTAssertTrue(snapshot.isEnabled(.aiFoodPhotoEnabled))
        XCTAssertTrue(snapshot.isEnabled(.batchRecipesEnabled))
    }

    func testFeatureFlagManagerAllowsRemoteKillSwitchForBatchRecipes() async throws {
        let manager = try DatabaseManager.inMemory()
        let featureFlags = FeatureFlagManager(dbQueue: manager.dbQueue)
        let authId = UUID(uuidString: "10101010-1010-4010-8010-101010101010")!
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://example.com/functions/v1/api-config-feature-flags")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )

        APIClient._testSetEdgeRouteDataForRequestOverride { _ in
            let body = """
            {
              "flags": [
                {
                  "flag_key": "batch_recipes_enabled",
                  "enabled": false,
                  "variant": "kill_switch"
                }
              ],
              "fetched_at": "2026-03-16T08:00:00Z",
              "ttl_seconds": 3600
            }
            """
            return (Data(body.utf8), response)
        }

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
            AuthManager._testSetActiveHasCloudSession(true)
        }

        let snapshot = await featureFlags.refresh(
            hasCloudSession: true,
            authId: authId
        )

        XCTAssertEqual(snapshot.source, .remote)
        XCTAssertFalse(snapshot.isEnabled(.batchRecipesEnabled))
        XCTAssertEqual(snapshot.variant(for: .batchRecipesEnabled), "kill_switch")
    }

    func testAIAvailabilityKeepsLocalFallbackEntryPointsAvailableWithoutCloudSession() async throws {
        let manager = try DatabaseManager.inMemory()
        let syncEngine = SyncEngine(dbQueue: manager.dbQueue)
        let featureFlags = FeatureFlagManager(dbQueue: manager.dbQueue)
        featureFlags._testReplaceSnapshot(.defaults(resolvedAt: Date()))
        let previousContainer = AppContainer.shared
        AppContainer.shared = AppContainer(
            syncEngine: syncEngine,
            dbQueue: manager.dbQueue,
            featureFlags: featureFlags
        )

        defer {
            AppContainer.shared = previousContainer
        }

        await MainActor.run {
            AuthManager._testSetActiveHasCloudSession(false)
        }

        let availability = await MainActor.run {
            let availability = AIAvailability()
            return (
                photoLoggingAvailable: availability.photoLoggingAvailable,
                labOcrAvailable: availability.labOcrAvailable,
                photoCloudAnalysisAvailable: availability.photoCloudAnalysisAvailable,
                voiceLoggingAvailable: availability.voiceLoggingAvailable
            )
        }
        XCTAssertTrue(availability.photoLoggingAvailable)
        XCTAssertTrue(availability.labOcrAvailable)
        XCTAssertFalse(availability.photoCloudAnalysisAvailable)
        XCTAssertFalse(availability.voiceLoggingAvailable)
    }

    func testAIAvailabilityHonorsLabOcrKillSwitchFromFeatureFlags() async throws {
        let manager = try DatabaseManager.inMemory()
        let syncEngine = SyncEngine(dbQueue: manager.dbQueue)
        let featureFlags = FeatureFlagManager(dbQueue: manager.dbQueue)
        let resolvedAt = Date()
        featureFlags._testReplaceSnapshot(
            FeatureFlagSnapshot(
                source: .remote,
                resolvedAt: resolvedAt,
                values: [
                    .aiLabOcrEnabled: FeatureFlagValue(enabled: false, variant: "holdback", fetchedAt: resolvedAt),
                    .aiFoodPhotoEnabled: FeatureFlagValue(enabled: true, variant: nil, fetchedAt: resolvedAt),
                    .aiVoiceLoggingEnabled: FeatureFlagValue(enabled: true, variant: nil, fetchedAt: resolvedAt),
                    .aiInsightsEnabled: FeatureFlagValue(enabled: true, variant: nil, fetchedAt: resolvedAt),
                    .openrouterAvailable: FeatureFlagValue(enabled: true, variant: nil, fetchedAt: resolvedAt),
                    .guardianModeEnabled: FeatureFlagValue(enabled: true, variant: nil, fetchedAt: resolvedAt),
                    .batchRecipesEnabled: FeatureFlagValue(enabled: true, variant: nil, fetchedAt: resolvedAt),
                ]
            )
        )
        let previousContainer = AppContainer.shared
        AppContainer.shared = AppContainer(
            syncEngine: syncEngine,
            dbQueue: manager.dbQueue,
            featureFlags: featureFlags
        )

        defer {
            AppContainer.shared = previousContainer
        }

        let availability = await MainActor.run {
            let availability = AIAvailability()
            return (
                labOcrAvailable: availability.labOcrAvailable,
                photoLoggingAvailable: availability.photoLoggingAvailable
            )
        }
        XCTAssertFalse(availability.labOcrAvailable)
        XCTAssertTrue(availability.photoLoggingAvailable)
    }

    func testFeatureFlagManagerCachesRemoteFlagsAndFallsBackToCache() async throws {
        let manager = try DatabaseManager.inMemory()
        let featureFlags = FeatureFlagManager(dbQueue: manager.dbQueue)
        let authId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://example.com/functions/v1/api-config-feature-flags")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )
        FeatureFlagManager._testSetNowProvider {
            Date(timeIntervalSince1970: 1_773_648_900) // 2026-03-16T08:15:00Z
        }

        APIClient._testSetEdgeRouteDataForRequestOverride { _ in
            let body = """
            {
              "flags": [
                {
                  "flag_key": "guardian_mode_enabled",
                  "enabled": true,
                  "variant": null
                },
                {
                  "flag_key": "ai_insights_enabled",
                  "enabled": false,
                  "variant": "holdback"
                }
              ],
              "fetched_at": "2026-03-16T08:00:00Z",
              "ttl_seconds": 3600
            }
            """
            return (Data(body.utf8), response)
        }

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
            AuthManager._testSetActiveHasCloudSession(true)
        }

        let remoteSnapshot = await featureFlags.refresh(
            hasCloudSession: true,
            authId: authId
        )

        XCTAssertEqual(remoteSnapshot.source, .remote)
        XCTAssertTrue(remoteSnapshot.isEnabled(.guardianModeEnabled))
        XCTAssertFalse(remoteSnapshot.isEnabled(.aiInsightsEnabled))
        XCTAssertEqual(remoteSnapshot.variant(for: .aiInsightsEnabled), "holdback")

        let failedRefreshAttempts = FeatureFlagAttemptCounter()
        APIClient._testSetEdgeRouteDataForRequestOverride { _ in
            failedRefreshAttempts.increment()
            throw NSError(
                domain: NSURLErrorDomain,
                code: URLError.notConnectedToInternet.rawValue
            )
        }

        let cachedSnapshot = await featureFlags.refresh(
            hasCloudSession: true,
            authId: authId
        )

        XCTAssertEqual(cachedSnapshot.source, .cache)
        XCTAssertEqual(failedRefreshAttempts.value(), 1)
        XCTAssertTrue(cachedSnapshot.isEnabled(.guardianModeEnabled))
        XCTAssertFalse(cachedSnapshot.isEnabled(.aiInsightsEnabled))
        XCTAssertEqual(cachedSnapshot.variant(for: .aiInsightsEnabled), "holdback")
    }

    func testFeatureFlagManagerUsesSafeFallbackWhenCacheIsStale() async throws {
        let manager = try DatabaseManager.inMemory()
        let featureFlags = FeatureFlagManager(dbQueue: manager.dbQueue)
        let authId = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://example.com/functions/v1/api-config-feature-flags")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )

        FeatureFlagManager._testSetNowProvider {
            Date(timeIntervalSince1970: 1_710_576_000) // 2024-03-16T08:00:00Z
        }
        APIClient._testSetEdgeRouteDataForRequestOverride { _ in
            let body = """
            {
              "flags": [
                {
                  "flag_key": "guardian_mode_enabled",
                  "enabled": true,
                  "variant": null
                },
                {
                  "flag_key": "ai_insights_enabled",
                  "enabled": false,
                  "variant": "holdback"
                }
              ],
              "fetched_at": "2024-03-16T08:00:00Z",
              "ttl_seconds": 3600
            }
            """
            return (Data(body.utf8), response)
        }

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
            AuthManager._testSetActiveHasCloudSession(true)
        }

        let remoteSnapshot = await featureFlags.refresh(
            hasCloudSession: true,
            authId: authId
        )
        XCTAssertEqual(remoteSnapshot.source, .remote)
        XCTAssertTrue(remoteSnapshot.isEnabled(.guardianModeEnabled))
        XCTAssertFalse(remoteSnapshot.isEnabled(.aiInsightsEnabled))

        FeatureFlagManager._testSetNowProvider {
            Date(timeIntervalSince1970: 1_710_583_800) // > 2h later
        }
        APIClient._testSetEdgeRouteDataForRequestOverride { _ in
            throw NSError(
                domain: NSURLErrorDomain,
                code: URLError.notConnectedToInternet.rawValue
            )
        }

        let fallbackSnapshot = await featureFlags.refresh(
            hasCloudSession: true,
            authId: authId
        )

        XCTAssertEqual(fallbackSnapshot.source, .safeFallback)
        XCTAssertTrue(fallbackSnapshot.isEnabled(.guardianModeEnabled))
        XCTAssertFalse(fallbackSnapshot.isEnabled(.aiInsightsEnabled))
        // Cost-bearing AI flags fail closed on a stale cache instead of
        // restoring their last-known-enabled value.
        XCTAssertFalse(fallbackSnapshot.isEnabled(.openrouterAvailable))
        XCTAssertTrue(fallbackSnapshot.isEnabled(.batchRecipesEnabled))
        XCTAssertNil(fallbackSnapshot.variant(for: .aiInsightsEnabled))
    }

    func testFeatureFlagManagerSafeFallbackPreservesLastKnownBatchRecipesValueWhenCacheIsStale() async throws {
        let manager = try DatabaseManager.inMemory()
        let featureFlags = FeatureFlagManager(dbQueue: manager.dbQueue)
        let authId = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://example.com/functions/v1/api-config-feature-flags")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )

        FeatureFlagManager._testSetNowProvider {
            Date(timeIntervalSince1970: 1_710_576_000) // 2024-03-16T08:00:00Z
        }
        APIClient._testSetEdgeRouteDataForRequestOverride { _ in
            let body = """
            {
              "flags": [
                {
                  "flag_key": "batch_recipes_enabled",
                  "enabled": true,
                  "variant": "ramp"
                }
              ],
              "fetched_at": "2024-03-16T08:00:00Z",
              "ttl_seconds": 3600
            }
            """
            return (Data(body.utf8), response)
        }

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
            AuthManager._testSetActiveHasCloudSession(true)
        }

        let remoteSnapshot = await featureFlags.refresh(
            hasCloudSession: true,
            authId: authId
        )
        XCTAssertEqual(remoteSnapshot.source, .remote)
        XCTAssertTrue(remoteSnapshot.isEnabled(.batchRecipesEnabled))

        FeatureFlagManager._testSetNowProvider {
            Date(timeIntervalSince1970: 1_710_583_800) // > 2h later
        }
        APIClient._testSetEdgeRouteDataForRequestOverride { _ in
            throw NSError(
                domain: NSURLErrorDomain,
                code: URLError.notConnectedToInternet.rawValue
            )
        }

        let fallbackSnapshot = await featureFlags.refresh(
            hasCloudSession: true,
            authId: authId
        )

        XCTAssertEqual(fallbackSnapshot.source, .safeFallback)
        XCTAssertTrue(fallbackSnapshot.isEnabled(.batchRecipesEnabled))
        // AI flags fail closed when the cache is stale.
        XCTAssertFalse(fallbackSnapshot.isEnabled(.aiFoodPhotoEnabled))
        XCTAssertFalse(fallbackSnapshot.isEnabled(.openrouterAvailable))
    }

    func testGuardianRefreshDowngradesGuardianWhenFeatureFlagDisabled() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let userId = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let syncEngine = SyncEngine(
            dbQueue: manager.dbQueue,
            pushTransportOverride: { _ in }
        )
        let featureFlags = FeatureFlagManager(dbQueue: manager.dbQueue)
        let resolvedAt = Date()
        featureFlags._testReplaceSnapshot(
            FeatureFlagSnapshot(
                source: .remote,
                resolvedAt: resolvedAt,
                values: [
                    .aiLabOcrEnabled: FeatureFlagValue(enabled: true, variant: nil, fetchedAt: resolvedAt),
                    .aiFoodPhotoEnabled: FeatureFlagValue(enabled: true, variant: nil, fetchedAt: resolvedAt),
                    .aiVoiceLoggingEnabled: FeatureFlagValue(enabled: true, variant: nil, fetchedAt: resolvedAt),
                    .aiInsightsEnabled: FeatureFlagValue(enabled: true, variant: nil, fetchedAt: resolvedAt),
                    .openrouterAvailable: FeatureFlagValue(enabled: true, variant: nil, fetchedAt: resolvedAt),
                    .guardianModeEnabled: FeatureFlagValue(enabled: false, variant: "holdback", fetchedAt: resolvedAt),
                    .batchRecipesEnabled: FeatureFlagValue(enabled: true, variant: nil, fetchedAt: resolvedAt),
                ]
            )
        )
        let previousContainer = AppContainer.shared
        AppContainer.shared = AppContainer(
            syncEngine: syncEngine,
            dbQueue: manager.dbQueue,
            featureFlags: featureFlags
        )

        defer {
            AppContainer.shared = previousContainer
        }

        await MainActor.run {
            GuardianManager._testResetPersistedState()
            AuthManager.setActiveAuthIdForTests(authId)
            AuthManager._testSetActiveHasCloudSession(false)
            GuardianManager._testSetAuthorizationOverride(true)
            GuardianManager._testSetSelectionPresenceOverride(true)
        }

        try await manager.dbQueue.write { db in
            var user = User(id: userId, authId: authId, timezone: "UTC")
            user.onboardingCompleted = true
            try user.insert(db)

            var settings = NotificationSettings(userId: userId)
            settings.controlLevel = .guardian
            settings.focusControlEnabled = true
            try settings.insert(db)
        }

        let result = await GuardianManager.shared._testRefreshRuntimeState(
            dbQueue: manager.dbQueue,
            syncEngine: syncEngine
        )

        XCTAssertEqual(result.settings?.controlLevel, .protective)
        XCTAssertEqual(result.settings?.focusControlEnabled, false)
        let bannerMessage = await MainActor.run { GuardianManager.shared.runtimeBannerMessage }
        XCTAssertEqual(
            bannerMessage,
            String(localized: "settings_notifications_guardian_feature_disabled")
        )

        try await manager.dbQueue.read { db in
            let stored = try XCTUnwrap(
                NotificationSettings.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM notification_settings
                        WHERE user_id = ? OR user_id = ?
                        LIMIT 1
                        """,
                    arguments: [userId, userId.uuidString]
                )
            )
            XCTAssertEqual(stored.controlLevel, .protective)
            XCTAssertFalse(stored.focusControlEnabled)

            let outboxCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM outbox_events
                    WHERE path = ?
                    """,
                arguments: ["api-settings-notifications"]
            ) ?? 0
            XCTAssertEqual(outboxCount, 1)
        }
    }
}
