// MARK: - Guardian Manager
// Source of truth: life_os_invariants.md §5 (Control Model)
// Handles FamilyControls authorization and ManagedSettings for app blocking.

import DeviceActivity
import Foundation
import SwiftUI
@preconcurrency import FamilyControls
import GRDB
import ManagedSettings
import OSLog

private let guardianMaxEnforcementDuration: TimeInterval = 2 * 60 * 60
private let guardianDefaultEnforcementDuration: TimeInterval = 60 * 60

enum AppRuntimeBannerSource: Int, CaseIterable, Sendable {
    case guardianFeatureFlag
    case guardianAuthorization
    case authCloudReconnect
    case authStateRefresh
    case authLocalProfile
    case cloudSync
    case dailyStateSync
    case privacyMaintenance

    static let priorityOrder: [Self] = [
        .guardianFeatureFlag,
        .guardianAuthorization,
        .authCloudReconnect,
        .authStateRefresh,
        .authLocalProfile,
        .cloudSync,
        .dailyStateSync,
        .privacyMaintenance
    ]

    var symbolName: String {
        switch self {
        case .guardianFeatureFlag:
            return "lock.slash.fill"
        case .guardianAuthorization:
            return "lock.shield.fill"
        case .authCloudReconnect, .authStateRefresh, .authLocalProfile:
            return "person.crop.circle.badge.exclamationmark"
        case .cloudSync:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .dailyStateSync:
            return "heart.text.square.fill"
        case .privacyMaintenance:
            return "hand.raised.fill"
        }
    }
}

enum GuardianAuthorizationError: LocalizedError {
    case capabilityUnavailable

    var errorDescription: String? {
        switch self {
        case .capabilityUnavailable:
            return AppCapabilityAvailability.familyControlsUnavailableMessage
        }
    }
}

@MainActor
@Observable
final class GuardianManager {
    static let shared = GuardianManager()
    private let logger = Logger(subsystem: "com.lifeos.app", category: "Guardian")

    private let center = AuthorizationCenter.shared
    private let activityCenter = DeviceActivityCenter()
    private let store = ManagedSettingsStore(named: GuardianMonitorIdentifiers.storeName)
    private let selectionKey = "guardian_mode_selection"
    private let sessionKey = "guardian_mode_session"
    private let pauseKey = "guardian_mode_pause_day"
    private let executedRulesKey = "guardian_mode_executed_rules"
    private let protectedAppBundleIdentifiers: Set<String> = [
        "com.apple.Health",
        "com.apple.mobilephone"
    ]
    private let protectedAppNameKeywords: Set<String> = [
        "emergency",
        "health",
        "phone"
    ]
    private var sessionEndTask: Task<Void, Never>?
    private var runtimeBannerMessages: [AppRuntimeBannerSource: String] = [:]

#if DEBUG
    @MainActor private static var testAuthorizationOverride: Bool?
    @MainActor private static var testRequestAuthorization: (() async throws -> Void)?
    @MainActor private static var testRevokeAuthorization: ((@escaping (Result<Void, any Error>) -> Void) -> Void)?
    @MainActor private static var testSystemRevokeAuthorization: ((@escaping (Result<Void, any Error>) -> Void) -> Void)?
    @MainActor private static var testDefaultRequestAuthorization: (() async throws -> Void)?
    @MainActor private static var testDefaultSystemRevokeAuthorization: ((@escaping (Result<Void, any Error>) -> Void) -> Void)?
    @MainActor private static var testNowProvider: (() -> Date)?
    @MainActor private static var testSelectionPresenceOverride: Bool?
#endif

    var runtimeBannerMessage: String? {
        currentRuntimeBanner?.message
    }

    var runtimeBannerSymbolName: String {
        currentRuntimeBanner?.source.symbolName ?? AppRuntimeBannerSource.guardianAuthorization.symbolName
    }

    var isAuthorized: Bool {
#if DEBUG
        if let override = Self.testAuthorizationOverride {
            return override
        }
#endif
        return center.authorizationStatus == .approved
    }

    private var isGuardianFeatureEnabled: Bool {
        AppContainer.shared?.featureFlags.isEnabled(.guardianModeEnabled) ?? true
    }

    private var guardianFeatureDisabledMessage: String {
        String(localized: "settings_notifications_guardian_feature_disabled")
    }
    
    // MARK: - Authorization

    func requestAuthorization() async throws {
        guard AppCapabilityAvailability.isFamilyControlsAvailable else {
            showRuntimeBanner(
                message: AppCapabilityAvailability.familyControlsUnavailableMessage,
                for: .guardianAuthorization
            )
            throw GuardianAuthorizationError.capabilityUnavailable
        }
#if DEBUG
        if let testRequestAuthorization = Self.testRequestAuthorization {
            try await testRequestAuthorization()
        } else if let testDefaultRequestAuthorization = Self.testDefaultRequestAuthorization {
            try await testDefaultRequestAuthorization()
        } else {
            try await center.requestAuthorization(for: .individual)
        }
#else
        try await center.requestAuthorization(for: .individual)
#endif
        clearRuntimeBanner(for: .guardianAuthorization)
    }

    func revokeAuthorization() {
#if DEBUG
        if let testRevokeAuthorization = Self.testRevokeAuthorization {
            testRevokeAuthorization { result in
                self.handleRevokeResult(result)
            }
            return
        }
#endif
        performSystemRevokeAuthorization { result in
            self.handleRevokeResult(result)
        }
    }

    private func performSystemRevokeAuthorization(
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
#if DEBUG
        if let testSystemRevokeAuthorization = Self.testSystemRevokeAuthorization {
            testSystemRevokeAuthorization(completion)
        } else if let testDefaultSystemRevokeAuthorization = Self.testDefaultSystemRevokeAuthorization {
            testDefaultSystemRevokeAuthorization(completion)
        } else {
            center.revokeAuthorization(completionHandler: completion)
        }
#else
        center.revokeAuthorization(completionHandler: completion)
#endif
    }

    private func handleRevokeResult(_ result: Result<Void, any Error>) {
        switch result {
        case .success:
            clearPersistedSession()
            clearShields()
            logger.info("Authorization revoked")
        case .failure(let error):
            logger.error("Failed to revoke authorization: \(error.localizedDescription)")
        }
    }

    // MARK: - Shielding

    /// Blocks specified application tokens.
    /// - Parameter selection: The FamilyActivitySelection containing apps/categories to block.
    func shieldApps(selection: FamilyActivitySelection) {
        let sanitizedSelection = sanitizeSelection(selection)
        if isSelectionEmpty(sanitizedSelection) {
            clearShields()
            return
        }
        store.shield.applications = sanitizedSelection.applicationTokens
        store.shield.applicationCategories = ShieldSettings.ActivityCategoryPolicy.specific(
            sanitizedSelection.categoryTokens
        )
        store.shield.webDomains = sanitizedSelection.webDomainTokens
    }

    /// Clears all shields (e.g. when exiting Guardian Mode).
    func clearShields() {
        stopSystemMonitoring()
        store.clearAllSettings()
    }

    // MARK: - Monitoring

    @discardableResult
    func startEnforcementWindow(
        reason: String,
        duration: TimeInterval = 60 * 60,
        settings: NotificationSettings,
        source: GuardianEnforcementSource = .manual
    ) -> GuardianEnforcementStartResult {
        let now = currentDate()
        let normalized = settings.normalizedForInvariants(
            guardianModeEnabled: isGuardianFeatureEnabled
        )

        guard isGuardianFeatureEnabled else {
            showRuntimeBanner(
                message: guardianFeatureDisabledMessage,
                for: .guardianFeatureFlag
            )
            clearPersistedSession()
            clearShields()
            return .ineligible
        }
        clearRuntimeBanner(for: .guardianFeatureFlag)

        if isPauseActive(on: now) {
            clearPersistedSession()
            clearShields()
            return .pausedForToday
        }

        guard normalized.controlLevel == .guardian,
              normalized.focusControlEnabled,
              !normalized.criticalOnly else {
            clearPersistedSession()
            clearShields()
            return .ineligible
        }

        guard isAuthorized else {
            clearPersistedSession()
            clearShields()
            return .unauthorized
        }

        guard !isWithinScheduledWakeGuardWindow(settings: normalized, now: now) else {
            logger.info("Skipped Guardian enforcement within scheduled wake-up guard window")
            clearPersistedSession()
            clearShields()
            return .guardedByWakeWindow
        }

        let selection = loadSelection()
        guard !isSelectionEmpty(selection) else {
            clearPersistedSession()
            clearShields()
            return .noSelection
        }

        if let activeSession = currentSession(now: now) {
            applyShieldsIfAllowed(selection: selection, settings: normalized)
            scheduleSystemMonitoring(for: activeSession)
            scheduleEndTask(for: activeSession)
            return .alreadyActive(activeSession)
        }

        let session = GuardianEnforcementSession(
            id: UUID(),
            reason: normalizedGuardianReason(reason),
            startedAt: now,
            endsAt: now.addingTimeInterval(Self.clampedDuration(duration)),
            source: source
        )
        persistSession(session)
        applyShieldsIfAllowed(selection: selection, settings: normalized)
        scheduleSystemMonitoring(for: session)
        scheduleEndTask(for: session)
        logger.info(
            "Started Guardian enforcement session \(session.id.uuidString, privacy: .public) until \(session.endsAt.formatted(date: .omitted, time: .shortened), privacy: .public)"
        )
        return .activated(session)
    }

    @discardableResult
    func pauseControlForToday(settings: NotificationSettings) -> GuardianRuntimeSnapshot {
        UserDefaults.standard.set(dayString(for: currentDate()), forKey: pauseKey)
        clearPersistedSession()
        clearShields()
        return syncEnforcementState(settings: settings)
    }

    @discardableResult
    func syncEnforcementState(settings: NotificationSettings) -> GuardianRuntimeSnapshot {
        let now = currentDate()
        let normalized = settings.normalizedForInvariants(
            guardianModeEnabled: isGuardianFeatureEnabled
        )

        pruneExpiredPauseIfNeeded(now: now)

        guard isGuardianFeatureEnabled else {
            if settings.controlLevel == .guardian ||
                settings.focusControlEnabled ||
                runtimeBannerMessages[.guardianFeatureFlag] != nil {
                showRuntimeBanner(
                    message: guardianFeatureDisabledMessage,
                    for: .guardianFeatureFlag
                )
            } else {
                clearRuntimeBanner(for: .guardianFeatureFlag)
            }
            clearPersistedSession()
            clearShields()
            return .inactive
        }
        clearRuntimeBanner(for: .guardianFeatureFlag)

        if isPauseActive(on: now) {
            clearPersistedSession()
            clearShields()
            return .pausedForToday(day: dayString(for: now))
        }

        guard normalized.controlLevel == .guardian,
              normalized.focusControlEnabled,
              !normalized.criticalOnly,
              isAuthorized else {
            clearPersistedSession()
            clearPauseIfNeeded()
            clearShields()
            return .inactive
        }

        guard let session = currentSession(now: now) else {
            clearShields()
            return .inactive
        }

        let selection = loadSelection()
        guard !isSelectionEmpty(selection) else {
            clearPersistedSession()
            clearShields()
            return .inactive
        }

        if isWithinScheduledWakeGuardWindow(settings: normalized, now: now) {
            clearPersistedSession()
            clearShields()
            return .inactive
        }

        applyShieldsIfAllowed(selection: selection, settings: normalized)
        scheduleSystemMonitoring(for: session)
        scheduleEndTask(for: session)
        return .active(session)
    }

    @discardableResult
    func refreshRuntimeState(
        dbQueue: DatabaseQueue,
        syncEngine: SyncEngine? = AppContainer.shared?.syncEngine
    ) async -> GuardianRuntimeRefreshResult {
        do {
            let authId = AuthManager.activeAuthId?.uuidString
            let today = dayString(for: currentDate())
            guard let context = try await dbQueue.read({
                try Self.runtimeContext(
                    db: $0,
                    authId: authId,
                    today: today
                )
            }) else {
                clearPersistedSession()
                clearShields()
                clearRuntimeBanner(for: .guardianFeatureFlag)
                clearRuntimeBanner(for: .guardianAuthorization)
                return GuardianRuntimeRefreshResult(settings: nil, snapshot: .inactive)
            }

            try await persistDrainedScreenTimeEvents(
                userId: context.settings.userId,
                dbQueue: dbQueue
            )

            let featureFlagAdjustedSettings = try await downgradeIfGuardianFeatureDisabled(
                context.settings,
                dbQueue: dbQueue,
                syncEngine: syncEngine
            )

            let effectiveSettings = try await downgradeIfAuthorizationRevoked(
                featureFlagAdjustedSettings,
                dbQueue: dbQueue,
                syncEngine: syncEngine
            )

            let initialSnapshot = syncEnforcementState(settings: effectiveSettings)
            maybeStartAutomaticRule(
                triggers: context.triggers,
                settings: effectiveSettings,
                snapshot: initialSnapshot
            )
            let finalSnapshot = syncEnforcementState(settings: effectiveSettings)
            return GuardianRuntimeRefreshResult(settings: effectiveSettings, snapshot: finalSnapshot)
        } catch {
            logger.error("Failed to refresh Guardian runtime state: \(error.localizedDescription)")
            clearPersistedSession()
            clearShields()
            return GuardianRuntimeRefreshResult(settings: nil, snapshot: .inactive)
        }
    }

    func dismissRuntimeBanner() {
        guard let source = currentRuntimeBanner?.source else { return }
        runtimeBannerMessages.removeValue(forKey: source)
    }

    func showRuntimeBanner(message: String, for source: AppRuntimeBannerSource) {
        runtimeBannerMessages[source] = message
    }

    func clearRuntimeBanner(for source: AppRuntimeBannerSource) {
        runtimeBannerMessages.removeValue(forKey: source)
    }

    // MARK: - Critical-Only Linkage (per §5 Control Model)

    /// Apply shields only if criticalOnly mode is NOT active.
    /// When criticalOnly=true, the system forces Advisory control level and disables shielding.
    /// This method only applies shields while an active bounded Guardian session exists.
    func applyShieldsIfAllowed(selection: FamilyActivitySelection, settings: NotificationSettings) {
        let normalized = settings.normalizedForInvariants(
            guardianModeEnabled: isGuardianFeatureEnabled
        )
        guard currentSession(now: currentDate()) != nil else {
            clearShields()
            return
        }
        if !isGuardianFeatureEnabled ||
            normalized.criticalOnly ||
            normalized.controlLevel != .guardian ||
            !normalized.focusControlEnabled ||
            !isAuthorized {
            clearShields()
            return
        }
        shieldApps(selection: selection)
    }

    /// Re-evaluates the currently active session when settings change or the app returns to foreground.
    func reevaluateShieldsForSettings(_ settings: NotificationSettings) {
        _ = syncEnforcementState(settings: settings)
    }

    // MARK: - Persistence

    @discardableResult
    func saveSelection(_ selection: FamilyActivitySelection, settings: NotificationSettings? = nil) -> FamilyActivitySelection {
        let sanitizedSelection = sanitizeSelection(selection)
        if let data = sanitizedSelection.encode() {
            UserDefaults.standard.set(data, forKey: selectionKey)
            if let settings {
                _ = syncEnforcementState(settings: settings)
            } else if currentSession(now: currentDate()) != nil && isAuthorized {
                shieldApps(selection: sanitizedSelection)
            }
        }
        return sanitizedSelection
    }

    func loadSelection() -> FamilyActivitySelection {
        guard let data = UserDefaults.standard.data(forKey: selectionKey) else {
            return FamilyActivitySelection()
        }
        if let decoded = FamilyActivitySelection.decode(from: data) {
            return sanitizeSelection(decoded)
        }
        return FamilyActivitySelection()
    }

    private func maybeStartAutomaticRule(
        triggers: [GuardianRuleTrigger],
        settings: NotificationSettings,
        snapshot: GuardianRuntimeSnapshot
    ) {
        guard snapshot.state == .inactive else { return }

        let today = dayString(for: currentDate())
        for trigger in triggers where !hasExecutedRule(trigger.ruleId, on: today) {
            let result = startEnforcementWindow(
                reason: trigger.reason,
                duration: trigger.duration,
                settings: settings,
                source: .recommendation(id: trigger.ruleId)
            )
            switch result {
            case .activated:
                markRuleExecuted(trigger.ruleId, on: today)
                return
            case .alreadyActive(let session):
                if session.source == .recommendation(id: trigger.ruleId) {
                    markRuleExecuted(trigger.ruleId, on: today)
                }
                return
            case .pausedForToday, .guardedByWakeWindow, .ineligible, .noSelection, .unauthorized:
                return
            }
        }
    }

    private func downgradeIfAuthorizationRevoked(
        _ settings: NotificationSettings,
        dbQueue: DatabaseQueue,
        syncEngine: SyncEngine?
    ) async throws -> NotificationSettings {
        guard settings.controlLevel == .guardian,
              settings.focusControlEnabled,
              !isAuthorized else {
            return settings
        }

        var downgraded = settings
        downgraded.controlLevel = .protective
        downgraded.focusControlEnabled = false
        downgraded.updatedAt = currentDate()
        clearPersistedSession()
        clearShields()
        showRuntimeBanner(
            message: String(localized: "runtime_banner_guardian_authorization_revoked"),
            for: .guardianAuthorization
        )

        let settingsToSave = downgraded
        try await dbQueue.write { db in
            try settingsToSave.save(db)
        }
        if let syncEngine {
            try? await enqueueOutbox(
                syncEngine: syncEngine,
                path: "api-settings-notifications",
                method: .PATCH,
                body: settingsToSave.apiPayload(
                    guardianModeEnabled: isGuardianFeatureEnabled
                )
            )
        }
        logger.warning("Guardian downgraded to Protective after authorization revocation")
        return downgraded
    }

    private func downgradeIfGuardianFeatureDisabled(
        _ settings: NotificationSettings,
        dbQueue: DatabaseQueue,
        syncEngine: SyncEngine?
    ) async throws -> NotificationSettings {
        guard !isGuardianFeatureEnabled,
              settings.controlLevel == .guardian || settings.focusControlEnabled else {
            if isGuardianFeatureEnabled {
                clearRuntimeBanner(for: .guardianFeatureFlag)
            }
            return settings
        }

        var downgraded = settings
        downgraded.controlLevel = .protective
        downgraded.focusControlEnabled = false
        downgraded.updatedAt = currentDate()
        clearPersistedSession()
        clearShields()
        showRuntimeBanner(
            message: guardianFeatureDisabledMessage,
            for: .guardianFeatureFlag
        )

        let settingsToSave = downgraded
        try await dbQueue.write { db in
            try settingsToSave.save(db)
        }
        if let syncEngine {
            try? await enqueueOutbox(
                syncEngine: syncEngine,
                path: "api-settings-notifications",
                method: .PATCH,
                body: settingsToSave.apiPayload(guardianModeEnabled: false)
            )
        }
        logger.warning("Guardian downgraded to Protective because guardian_mode_enabled is false")
        return downgraded
    }

    private func persistDrainedScreenTimeEvents(
        userId: UUID,
        dbQueue: DatabaseQueue
    ) async throws {
        let drainedEvents = drainScreenTimeEvents()
        guard !drainedEvents.isEmpty else { return }

        let records = drainedEvents.map {
            GuardianScreenTimeEventRecord.fromRuntimeEvent(
                $0,
                userId: userId,
                createdAt: currentDate()
            )
        }

        try await dbQueue.write { db in
            for record in records {
                try record.insert(db)
            }
        }
    }

    func recordEmergencyOverride(
        userId: UUID,
        dbQueue: DatabaseQueue
    ) async {
        let record = GuardianScreenTimeEventRecord.emergencyOverride(
            userId: userId,
            recordedAt: currentDate()
        )
        do {
            try await dbQueue.write { db in
                try record.insert(db)
            }
        } catch {
            logger.error("Failed to persist Guardian emergency override event: \(error.localizedDescription)")
        }
    }

    nonisolated private static func runtimeContext(
        db: Database,
        authId: String?,
        today: String
    ) throws -> GuardianRuntimeContext? {
        guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
            return nil
        }

        let settings = try NotificationSettings.fetchOne(
            db,
            sql: """
                SELECT *
                FROM notification_settings
                WHERE user_id = ? OR user_id = ?
                ORDER BY updated_at DESC
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString]
        ) ?? NotificationSettings(userId: userId)

        let recommendations = try Recommendation.fetchAll(
            db,
            sql: """
                SELECT *
                FROM recommendations
                WHERE (user_id = ? OR user_id = ?)
                  AND dismissed = 0
                  AND action_type = 'block_apps'
                  AND auto_execute = 1
                  AND recommendation_date = ?
                  AND COALESCE(followed, 0) = 0
                ORDER BY
                  CASE priority
                    WHEN 'critical' THEN 0
                    WHEN 'high' THEN 1
                    WHEN 'medium' THEN 2
                    ELSE 3
                  END,
                  updated_at DESC,
                  created_at DESC
                """,
            arguments: [userId, userId.uuidString, today]
        )

        let triggers = recommendations.map { recommendation in
            GuardianRuleTrigger(
                ruleId: recommendation.id.uuidString,
                reason: recommendation.title,
                duration: Self.durationForAutoBlockRecommendation(recommendation)
            )
        }

        return GuardianRuntimeContext(settings: settings, triggers: triggers)
    }

    nonisolated private static func durationForAutoBlockRecommendation(_ recommendation: Recommendation) -> TimeInterval {
        guard let actionParameters = recommendation.actionParameters,
              let payload = try? JSONSerialization.jsonObject(with: actionParameters) as? [String: Any] else {
            return guardianDefaultEnforcementDuration
        }

        if let minutes = numericActionParameter(
            payload,
            keys: ["duration_minutes", "minutes", "window_minutes", "estimated_duration_minutes"]
        ) {
            return clampedDuration(minutes * 60)
        }

        if let hours = numericActionParameter(payload, keys: ["duration_hours", "hours", "window_hours"]) {
            return clampedDuration(hours * 60 * 60)
        }

        return guardianDefaultEnforcementDuration
    }

    nonisolated private static func numericActionParameter(
        _ payload: [String: Any],
        keys: [String]
    ) -> TimeInterval? {
        for key in keys {
            if let value = payload[key] as? NSNumber {
                return value.doubleValue
            }
            if let value = payload[key] as? Double {
                return value
            }
            if let value = payload[key] as? Int {
                return Double(value)
            }
            if let value = payload[key] as? String, let parsed = Double(value) {
                return parsed
            }
        }
        return nil
    }

    private func sanitizeSelection(_ selection: FamilyActivitySelection) -> FamilyActivitySelection {
        guard !selection.applicationTokens.isEmpty else { return selection }

        let resolvedApplications = selection.applications
        guard resolvedApplications.count == selection.applicationTokens.count else {
            logger.warning("Guardian selection contains unresolved app tokens; skipping protected-app filtering")
            return selection
        }

        let allowedApplications = resolvedApplications.filter { application in
            if let bundleIdentifier = application.bundleIdentifier,
               protectedAppBundleIdentifiers.contains(bundleIdentifier) {
                return false
            }
            let displayName = application.localizedDisplayName?.lowercased() ?? ""
            return !protectedAppNameKeywords.contains(where: { displayName.contains($0) })
        }

        var sanitized = selection
        sanitized.applicationTokens = Set(allowedApplications.compactMap(\.token))
        if sanitized.applicationTokens.count != selection.applicationTokens.count {
            logger.info("Removed protected applications from Guardian selection")
        }
        return sanitized
    }

    private func isSelectionEmpty(_ selection: FamilyActivitySelection) -> Bool {
#if DEBUG
        if let override = Self.testSelectionPresenceOverride {
            return !override
        }
#endif
        return selection.applicationTokens.isEmpty &&
            selection.categoryTokens.isEmpty &&
            selection.webDomainTokens.isEmpty
    }

    private func currentSession(now: Date) -> GuardianEnforcementSession? {
        guard let session = loadPersistedSession() else { return nil }
        if session.endsAt <= now {
            clearPersistedSession()
            clearShields()
            return nil
        }
        return session
    }

    private func loadPersistedSession() -> GuardianEnforcementSession? {
        guard let data = UserDefaults.standard.data(forKey: sessionKey) else { return nil }
        return try? JSONDecoder().decode(GuardianEnforcementSession.self, from: data)
    }

    private func persistSession(_ session: GuardianEnforcementSession) {
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: sessionKey)
        }
    }

    private func clearPersistedSession() {
        sessionEndTask?.cancel()
        sessionEndTask = nil
        UserDefaults.standard.removeObject(forKey: sessionKey)
    }

    private func scheduleEndTask(for session: GuardianEnforcementSession) {
        sessionEndTask?.cancel()
        sessionEndTask = Task { [weak self] in
            let remaining = max(0, session.endsAt.timeIntervalSince(self?.currentDate() ?? Date()))
            guard remaining > 0 else {
                self?.handleScheduledSessionEnd(expectedSessionId: session.id)
                return
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            } catch {
                return
            }
            self?.handleScheduledSessionEnd(expectedSessionId: session.id)
        }
    }

    private func handleScheduledSessionEnd(expectedSessionId: UUID) {
        guard let session = loadPersistedSession(), session.id == expectedSessionId else { return }
        clearPersistedSession()
        clearShields()
        logger.info("Guardian enforcement session ended at scheduled boundary")
    }

    private func pruneExpiredPauseIfNeeded(now: Date) {
        guard let pausedDay = UserDefaults.standard.string(forKey: pauseKey) else { return }
        if pausedDay != dayString(for: now) {
            UserDefaults.standard.removeObject(forKey: pauseKey)
        }
    }

    private func clearPauseIfNeeded() {
        UserDefaults.standard.removeObject(forKey: pauseKey)
    }

    private func isPauseActive(on date: Date) -> Bool {
        UserDefaults.standard.string(forKey: pauseKey) == dayString(for: date)
    }

    private func hasExecutedRule(_ ruleId: String, on day: String) -> Bool {
        loadExecutedRules()[ruleId] == day
    }

    private func markRuleExecuted(_ ruleId: String, on day: String) {
        var rules = loadExecutedRules()
        let retentionCutoff = dayString(for: currentDate().addingTimeInterval(-7 * 86_400))
        rules = rules.filter { $0.value >= retentionCutoff }
        rules[ruleId] = day
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: executedRulesKey)
        }
    }

    private func loadExecutedRules() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: executedRulesKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private var currentRuntimeBanner: (source: AppRuntimeBannerSource, message: String)? {
        for source in AppRuntimeBannerSource.priorityOrder {
            if let message = runtimeBannerMessages[source], !message.isEmpty {
                return (source, message)
            }
        }
        return nil
    }

    nonisolated private static func clampedDuration(_ duration: TimeInterval) -> TimeInterval {
        min(max(1, duration), guardianMaxEnforcementDuration)
    }

    private func normalizedGuardianReason(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "settings_notifications_guardian_reason_default") : trimmed
    }

    private func isWithinScheduledWakeGuardWindow(settings: NotificationSettings, now: Date) -> Bool {
        guard let scheduledWake = wallClockDate(
            on: now,
            wallClockTime: settings.quietHoursEnd,
            preferNextDayForOvernightWindow: settings.quietHoursStart > settings.quietHoursEnd
        ) else {
            return false
        }
        return abs(scheduledWake.timeIntervalSince(now)) <= 15 * 60
    }

    private func wallClockDate(
        on date: Date,
        wallClockTime: String,
        preferNextDayForOvernightWindow: Bool
    ) -> Date? {
        let parts = wallClockTime.split(separator: ":")
        guard parts.count >= 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else {
            return nil
        }
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        guard let todayDate = calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: dayStart
        ) else {
            return nil
        }
        if preferNextDayForOvernightWindow && todayDate < date {
            return calendar.date(byAdding: .day, value: 1, to: todayDate)
        }
        return todayDate
    }

    private func currentDate() -> Date {
#if DEBUG
        if let provider = Self.testNowProvider {
            return provider()
        }
#endif
        return Date()
    }

    private func scheduleSystemMonitoring(for session: GuardianEnforcementSession) {
        let schedule = DeviceActivitySchedule(
            intervalStart: scheduleDateComponents(for: session.startedAt),
            intervalEnd: scheduleDateComponents(for: session.endsAt),
            repeats: false
        )

        do {
            activityCenter.stopMonitoring([GuardianMonitorIdentifiers.activityName])
            try activityCenter.startMonitoring(
                GuardianMonitorIdentifiers.activityName,
                during: schedule
            )
        } catch {
            logger.error("Failed to schedule Guardian monitor: \(error.localizedDescription)")
        }
    }

    private func stopSystemMonitoring() {
        activityCenter.stopMonitoring([GuardianMonitorIdentifiers.activityName])
    }

    private func scheduleDateComponents(for date: Date) -> DateComponents {
        Calendar.current.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
            from: date
        )
    }

    private func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - Passive Screen Time Tracking

    /// Screen time event recorded by the GuardianMonitorExtension via shared UserDefaults.
    struct ScreenTimeEvent: Codable, Sendable {
        enum EventType: Codable, Sendable {
            case intervalStarted
            case intervalEnded
            case intervalWillStart
            case intervalWillEnd
            case thresholdReached(event: String)
        }
        let type: EventType
        let timestamp: Date
    }

    /// Drains pending screen-time events written by the GuardianMonitorExtension.
    /// Call this on foreground (e.g., during `refreshGuardianRuntimeIfAvailable`).
    /// Returns the events for the caller to persist into GRDB analytics_events.
    func drainScreenTimeEvents() -> [ScreenTimeEvent] {
        guard let defaults = UserDefaults(suiteName: GuardianMonitorIdentifiers.appGroupSuiteName) else {
            return []
        }
        guard let data = defaults.data(forKey: GuardianMonitorIdentifiers.screenTimeEventsKey) else {
            return []
        }
        guard let events = try? JSONDecoder().decode([ScreenTimeEvent].self, from: data) else {
            defaults.removeObject(forKey: GuardianMonitorIdentifiers.screenTimeEventsKey)
            logger.warning("Discarded malformed screen-time events from Guardian extension")
            return []
        }
        guard !events.isEmpty else {
            defaults.removeObject(forKey: GuardianMonitorIdentifiers.screenTimeEventsKey)
            return []
        }
        // Clear the buffer after reading.
        defaults.removeObject(forKey: GuardianMonitorIdentifiers.screenTimeEventsKey)
        logger.info("Drained \(events.count) screen-time events from Guardian extension")
        return events
    }
}

private struct GuardianScreenTimeEventRecord: Codable, Equatable, Sendable, SnakeCaseGRDBRecord {
    static let databaseTableName = "screen_time_events"

    var id: Int64?
    var userId: String
    var eventType: String
    var eventDetail: String?
    var recordedAt: Date
    var createdAt: Date

    static func fromRuntimeEvent(
        _ event: GuardianManager.ScreenTimeEvent,
        userId: UUID,
        createdAt: Date
    ) -> GuardianScreenTimeEventRecord {
        let mapped: (type: String, detail: String?)
        switch event.type {
        case .intervalStarted:
            mapped = ("interval_started", nil)
        case .intervalEnded:
            mapped = ("interval_ended", nil)
        case .intervalWillStart:
            mapped = ("interval_will_start", nil)
        case .intervalWillEnd:
            mapped = ("interval_will_end", nil)
        case .thresholdReached(let event):
            mapped = ("threshold_reached", event)
        }

        return GuardianScreenTimeEventRecord(
            id: nil,
            userId: userId.uuidString,
            eventType: mapped.type,
            eventDetail: mapped.detail,
            recordedAt: event.timestamp,
            createdAt: createdAt
        )
    }

    static func emergencyOverride(
        userId: UUID,
        recordedAt: Date
    ) -> GuardianScreenTimeEventRecord {
        GuardianScreenTimeEventRecord(
            id: nil,
            userId: userId.uuidString,
            eventType: "emergency_override",
            eventDetail: "hold_to_confirm_15s",
            recordedAt: recordedAt,
            createdAt: recordedAt
        )
    }
}

// MARK: - FamilyActivitySelection Persistence

extension FamilyActivitySelection {
    /// Helper to encode selection for storage in GRDB/UserDefaults
    func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }
    
    static func decode(from data: Data) -> FamilyActivitySelection? {
        try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
    }
}

#if DEBUG
extension GuardianManager {
    static func _testSetAuthorizationOverride(_ value: Bool?) {
        testAuthorizationOverride = value
    }

    static func _testSetRequestAuthorization(_ handler: (() async throws -> Void)?) {
        testRequestAuthorization = handler
    }

    static func _testSetRevokeAuthorization(
        _ handler: ((@escaping (Result<Void, any Error>) -> Void) -> Void)?
    ) {
        testRevokeAuthorization = handler
    }

    static func _testSetSystemRevokeAuthorization(
        _ handler: ((@escaping (Result<Void, any Error>) -> Void) -> Void)?
    ) {
        testSystemRevokeAuthorization = handler
    }

    static func _testSetDefaultRequestAuthorization(_ handler: (() async throws -> Void)?) {
        testDefaultRequestAuthorization = handler
    }

    static func _testSetDefaultSystemRevokeAuthorization(
        _ handler: ((@escaping (Result<Void, any Error>) -> Void) -> Void)?
    ) {
        testDefaultSystemRevokeAuthorization = handler
    }

    static func _testSetNowProvider(_ provider: (() -> Date)?) {
        testNowProvider = provider
    }

    static func _testSetSelectionPresenceOverride(_ value: Bool?) {
        testSelectionPresenceOverride = value
    }

    static func _testResetPersistedState() {
        UserDefaults.standard.removeObject(forKey: shared.selectionKey)
        UserDefaults.standard.removeObject(forKey: shared.sessionKey)
        UserDefaults.standard.removeObject(forKey: shared.pauseKey)
        UserDefaults.standard.removeObject(forKey: shared.executedRulesKey)
        shared.clearPersistedSession()
        shared.clearShields()
        shared.runtimeBannerMessages.removeAll()
        testAuthorizationOverride = nil
        testRequestAuthorization = nil
        testRevokeAuthorization = nil
        testSystemRevokeAuthorization = nil
        testDefaultRequestAuthorization = nil
        testDefaultSystemRevokeAuthorization = nil
        testNowProvider = nil
        testSelectionPresenceOverride = nil
    }

    @discardableResult
    func _testStartEnforcementWindow(
        reason: String,
        duration: TimeInterval,
        settings: NotificationSettings
    ) -> GuardianEnforcementStartResult {
        startEnforcementWindow(reason: reason, duration: duration, settings: settings)
    }

    func _testSyncEnforcementState(settings: NotificationSettings) -> GuardianRuntimeSnapshot {
        syncEnforcementState(settings: settings)
    }

    func _testPauseControlForToday(settings: NotificationSettings) -> GuardianRuntimeSnapshot {
        pauseControlForToday(settings: settings)
    }

    func _testRefreshRuntimeState(
        dbQueue: DatabaseQueue,
        syncEngine: SyncEngine? = nil
    ) async -> GuardianRuntimeRefreshResult {
        await refreshRuntimeState(dbQueue: dbQueue, syncEngine: syncEngine)
    }

    func _testHandleRevokeResult(_ result: Result<Void, any Error>) {
        handleRevokeResult(result)
    }
}
#endif

struct GuardianRuntimeRefreshResult: Sendable {
    let settings: NotificationSettings?
    let snapshot: GuardianRuntimeSnapshot
}

struct GuardianRuntimeSnapshot: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case inactive
        case pausedToday(day: String)
        case active
    }

    static let inactive = GuardianRuntimeSnapshot(state: .inactive, session: nil)

    let state: State
    let session: GuardianEnforcementSession?

    static func pausedForToday(day: String) -> GuardianRuntimeSnapshot {
        GuardianRuntimeSnapshot(state: .pausedToday(day: day), session: nil)
    }

    static func active(_ session: GuardianEnforcementSession) -> GuardianRuntimeSnapshot {
        GuardianRuntimeSnapshot(state: .active, session: session)
    }
}

enum GuardianEnforcementStartResult: Equatable, Sendable {
    case activated(GuardianEnforcementSession)
    case alreadyActive(GuardianEnforcementSession)
    case pausedForToday
    case guardedByWakeWindow
    case ineligible
    case noSelection
    case unauthorized
}

struct GuardianEnforcementSession: Codable, Equatable, Sendable {
    let id: UUID
    let reason: String
    let startedAt: Date
    let endsAt: Date
    let source: GuardianEnforcementSource
}

enum GuardianEnforcementSource: Codable, Equatable, Sendable {
    case manual
    case recommendation(id: String)
}

private struct GuardianRuleTrigger: Sendable {
    let ruleId: String
    let reason: String
    let duration: TimeInterval
}

private struct GuardianRuntimeContext: Sendable {
    let settings: NotificationSettings
    let triggers: [GuardianRuleTrigger]
}
