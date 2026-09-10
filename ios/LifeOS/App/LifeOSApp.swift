// MARK: - Life OS App Entry Point
// Phase 2: Auth-gated root view with database initialization.

import SwiftUI
import OSLog
import GRDB
#if os(iOS)
import UIKit
#endif

@main
struct LifeOSApp: App {
#if os(iOS)
    @UIApplicationDelegateAdaptor(LifeOSAppDelegate.self) private var appDelegate
#endif

    private static let logger = Logger(subsystem: "com.lifeos.app", category: "Lifecycle")
    private let databaseStartupState: DatabaseManager.PersistentStartupState
    @State private var authManager = AuthManager()
    @State private var deepLinkRouter = DeepLinkRouter()
    @State private var showRecoveryNotice = false
    /// Atomic flag to prevent double-application of the initial deep link URL.
    /// Uses OSAllocatedUnfairLock instead of @State to guarantee thread safety
    /// if `.onOpenURL` fires concurrently with the bootstrap `MainActor.run {}` block.
    private let didApplyInitialURL = OSAllocatedUnfairLock(initialState: false)
    private let skipBackgroundWork = UITestBootstrap.disableBackgroundWork
#if DEBUG
    nonisolated private static let testBootstrapOverride = LockedTestOverride<@Sendable () async -> Void>()
    nonisolated private static let testRunSyncLoopOverride = LockedTestOverride<@Sendable () async throws -> Void>()
    nonisolated private static let testRefreshAuthStateOverride = LockedTestOverride<@Sendable () async -> Void>()
    nonisolated private static let testRunPrivacyMaintenanceOverride = LockedTestOverride<@Sendable () async throws -> Void>()
    nonisolated private static let testSyncDailyStateOverride = LockedTestOverride<@Sendable (UUID) async throws -> Void>()
#endif

    init() {
        self.databaseStartupState = DatabaseManager.sharedStartupState
        PerformanceMonitor.trackColdLaunchStart()
        let shouldSkipBackgroundWork = UITestBootstrap.disableBackgroundWork

        guard case .available(let db) = databaseStartupState else {
            AppContainer.shared = nil
            return
        }

        // Initialize database on launch (runs migrations)
        UITestBootstrap.seedLocalDataIfNeeded(dbQueue: db.dbQueue)

        // Register shared sync engine for foreground/background replay.
        let syncEngine = SyncEngine(dbQueue: db.dbQueue)
        let notificationScheduler = NotificationScheduleCoordinator(dbQueue: db.dbQueue)
        let featureFlags = FeatureFlagManager(dbQueue: db.dbQueue)
        AppContainer.shared = AppContainer(
            syncEngine: syncEngine,
            dbQueue: db.dbQueue,
            notificationScheduler: notificationScheduler,
            featureFlags: featureFlags
        )

        // Register background/watch bootstrap only in normal app runs.
        // UI perf tests set disable-background to isolate launch budget from background work.
        if !shouldSkipBackgroundWork {
            BackgroundSyncManager.registerTasks()
#if os(iOS)
            WatchSyncManager.shared.start()
#endif
        }
    }

    private func handleOpenURL(_ url: URL) {
        guard databaseStartupState.isAvailable else { return }
        if AuthManager.isAuthCallbackURL(url) {
            _ = deepLinkRouter.handle(url)
            Task {
                await authManager.handleAuthCallback(url)
            }
            return
        }
        _ = deepLinkRouter.handle(url)
    }

    private func applyInitialURLIfNeeded() {
        guard let initialURL = UITestBootstrap.initialURL else { return }
        // Atomic compare-and-swap: only the first caller proceeds.
        let alreadyApplied = didApplyInitialURL.withLock { flag -> Bool in
            if flag { return true }
            flag = true
            return false
        }
        guard !alreadyApplied else { return }
        _ = deepLinkRouter.handle(initialURL)
    }

    private func clearRuntimeBanner(for source: AppRuntimeBannerSource) async {
        await MainActor.run {
            GuardianManager.shared.clearRuntimeBanner(for: source)
        }
    }

    private func reportRuntimeFailure(
        _ error: Error,
        source: AppRuntimeBannerSource,
        fallbackMessage: String,
        operation: String
    ) async {
        Self.logger.error("\(operation, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        await MainActor.run {
            GuardianManager.shared.showRuntimeBanner(message: fallbackMessage, for: source)
        }
    }

    private func runSyncLoopIfAvailable() async {
        guard let syncEngine = AppContainer.shared?.syncEngine else { return }
        do {
            try await Self.runSyncLoop(syncEngine: syncEngine)
            await clearRuntimeBanner(for: .cloudSync)
        } catch {
            await reportRuntimeFailure(
                error,
                source: .cloudSync,
                fallbackMessage: String(localized: "runtime_banner_cloud_sync_failed"),
                operation: "Cloud sync"
            )
        }
    }

    private func refreshNotificationSchedulesIfAvailable() async {
        if let notificationScheduler = AppContainer.shared?.notificationScheduler {
            await notificationScheduler.refreshSchedules()
        }
    }

    private func refreshFeatureFlagsIfAvailable() async {
        guard let featureFlags = AppContainer.shared?.featureFlags else { return }
        let authContext = await MainActor.run {
            (authManager.hasCloudSession, AuthManager.activeAuthId)
        }
        _ = await featureFlags.refresh(
            hasCloudSession: authContext.0,
            authId: authContext.1
        )
    }

    private func refreshGuardianRuntimeIfAvailable() async {
        guard let dbQueue = AppContainer.shared?.dbQueue else { return }
        _ = await GuardianManager.shared.refreshRuntimeState(
            dbQueue: dbQueue,
            syncEngine: AppContainer.shared?.syncEngine
        )
    }

    private func refreshWidgetsIfAvailable() async {
        await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
    }

    private func refreshAuthState() async {
#if DEBUG
        if let override = Self.testRefreshAuthStateOverride.value {
            await override()
            return
        }
#endif
        await authManager.refreshPostAuthState()
    }

    private func runPrivacyMaintenance() async {
        guard let dbQueue = AppContainer.shared?.dbQueue else { return }
        do {
            try await Self.runPrivacyMaintenanceTask(dbQueue: dbQueue)
            await clearRuntimeBanner(for: .privacyMaintenance)
        } catch {
            await reportRuntimeFailure(
                error,
                source: .privacyMaintenance,
                fallbackMessage: String(localized: "runtime_banner_privacy_maintenance_failed"),
                operation: "Privacy maintenance"
            )
        }
    }

    private func syncDailyStateIfAvailable(userId: UUID) async {
        do {
            try await Self.syncDailyState(userId: userId)
            await clearRuntimeBanner(for: .dailyStateSync)
        } catch {
            await reportRuntimeFailure(
                error,
                source: .dailyStateSync,
                fallbackMessage: String(localized: "runtime_banner_daily_state_sync_failed"),
                operation: "Daily state sync"
            )
        }
    }

    /// Reacts to HealthKit change notifications by recomputing the recent
    /// days. Runs inside a background task held by HealthKitManager, so iOS
    /// grants us time even when the process was woken in the background.
    private func installHealthKitChangeHandler() {
        #if DEBUG
        if Self.testBootstrapOverride.value != nil { return }
        #endif
        let authManager = self.authManager
        HealthKitManager.setBackgroundChangeHandler { [weak authManager] in
            guard let authManager, let userId = await authManager.userId else { return }
            try? await HealthSyncManager.shared.backfillRecentData(days: 3, userId: userId)
        }
    }

    private func bootstrapAndRunLaunchWork() async {
        guard databaseStartupState.isAvailable else { return }
        installHealthKitChangeHandler()
        if !skipBackgroundWork {
            await HealthKitManager.shared.restoreBackgroundObservers()
        }
#if DEBUG
        if let override = Self.testBootstrapOverride.value {
            await override()
        } else {
            await authManager.bootstrap()
        }
#else
        await authManager.bootstrap()
#endif
        await MainActor.run {
            applyInitialURLIfNeeded()
            applyPendingWatchDeepLinksIfNeeded()
        }
        await Self.performPostBootstrapWork(
            skipBackgroundWork: skipBackgroundWork,
            hasCloudSession: authManager.hasCloudSession,
            userId: authManager.userId,
            runSyncLoop: runSyncLoopIfAvailable,
            refreshPostAuthState: refreshAuthState,
            runMaintenance: runPrivacyMaintenance,
            scheduleDailyPull: BackgroundSyncManager.scheduleDailyPull,
            scheduleOutboxReplay: BackgroundSyncManager.scheduleOutboxReplay,
            syncDailyState: syncDailyStateIfAvailable(userId:)
        )
        await refreshFeatureFlagsIfAvailable()
        await refreshGuardianRuntimeIfAvailable()
        await refreshNotificationSchedulesIfAvailable()
        await refreshWidgetsIfAvailable()
    }

    private static func runSyncLoop(syncEngine: SyncEngine) async throws {
#if DEBUG
        if let override = testRunSyncLoopOverride.value {
            try await override()
            return
        }
#endif
        try await syncEngine.runSyncLoop()
    }

    private static func runPrivacyMaintenanceTask(dbQueue: DatabaseQueue) async throws {
#if DEBUG
        if let override = testRunPrivacyMaintenanceOverride.value {
            try await override()
            return
        }
#endif
        let retentionManager = PrivacyRetentionManager(dbQueue: dbQueue)
        try await retentionManager.runMaintenance()
    }

    private static func runSyncDailyStateOverrideIfPresent(_ userId: UUID) async throws -> Bool {
#if DEBUG
        if let override = testSyncDailyStateOverride.value {
            try await override(userId)
            return true
        }
#endif
        return false
    }

    private static func syncDailyState(userId: UUID) async throws { if try await runSyncDailyStateOverrideIfPresent(userId) { return }; try await HealthSyncManager.shared.syncDailyState(userId: userId) }

    private func runForegroundWork() {
        guard databaseStartupState.isAvailable else { return }
        Task {
            await MainActor.run {
                applyPendingWatchDeepLinksIfNeeded()
            }
            await Self.performForegroundWork(
                skipBackgroundWork: skipBackgroundWork,
                hasCloudSession: authManager.hasCloudSession,
                userId: authManager.userId,
                runSyncLoop: runSyncLoopIfAvailable,
                refreshPostAuthState: refreshAuthState,
                syncDailyState: syncDailyStateIfAvailable(userId:)
            )
            await refreshFeatureFlagsIfAvailable()
            await refreshGuardianRuntimeIfAvailable()
            await refreshNotificationSchedulesIfAvailable()
            await refreshWidgetsIfAvailable()
        }
    }

    private func handleWillEnterForeground() {
        guard databaseStartupState.isAvailable else { return }
        Self.handleWillEnterForeground(
            skipBackgroundWork: skipBackgroundWork,
            trackWarmLaunchStart: PerformanceMonitor.trackWarmLaunchStart,
            runWork: runForegroundWork
        )
    }

    private func handleDidBecomeActive() {
        guard databaseStartupState.isAvailable else { return }
        Self.handleDidBecomeActive(
            skipBackgroundWork: skipBackgroundWork,
            trackWarmLaunchEnd: PerformanceMonitor.trackWarmLaunchEnd
        )
    }

    private func handleWatchDeepLinkNotification(_ notification: Notification) {
        guard databaseStartupState.isAvailable else { return }
        if let url = Self.watchDeepLinkURL(from: notification.userInfo) {
            if WatchSyncManager.isWatchDeepLinkNotification(notification.userInfo) {
                WatchSyncManager.clearPendingWatchDeepLinks()
            }
            _ = deepLinkRouter.handle(url)
            return
        }

        applyPendingWatchDeepLinksIfNeeded()
    }

    private func handleWillEnterForegroundNotification(_: Notification) {
        handleWillEnterForeground()
    }

    private func handleDidBecomeActiveNotification(_: Notification) {
        handleDidBecomeActive()
    }

    private static func watchDeepLinkURL(from userInfo: [AnyHashable: Any]?) -> URL? {
        guard let deepLink = userInfo?["deep_link"] as? String else {
            return nil
        }
        return URL(string: deepLink)
    }

    @MainActor
    private func applyPendingWatchDeepLinksIfNeeded() {
        while let url = WatchSyncManager.consumePendingWatchDeepLinkURL() {
            _ = deepLinkRouter.handle(url)
        }
    }

    private static func performPostBootstrapWork(
        skipBackgroundWork: Bool,
        hasCloudSession: Bool,
        userId: UUID?,
        runSyncLoop: @escaping @Sendable () async -> Void,
        refreshPostAuthState: @escaping @Sendable () async -> Void,
        runMaintenance: @escaping @Sendable () async -> Void,
        scheduleDailyPull: () -> Void,
        scheduleOutboxReplay: () -> Void,
        syncDailyState: @escaping @Sendable (UUID) async -> Void
    ) async {
        if !skipBackgroundWork && hasCloudSession {
            await runSyncLoop()
            await refreshPostAuthState()
        }

        if !skipBackgroundWork {
            await runMaintenance()
            scheduleDailyPull()
            scheduleOutboxReplay()

            if let userId {
                await syncDailyState(userId)
            }
        }
    }

    private static func performForegroundWork(
        skipBackgroundWork: Bool,
        hasCloudSession: Bool,
        userId: UUID?,
        runSyncLoop: @escaping @Sendable () async -> Void,
        refreshPostAuthState: @escaping @Sendable () async -> Void,
        syncDailyState: @escaping @Sendable (UUID) async -> Void
    ) async {
        guard !skipBackgroundWork else { return }

        if hasCloudSession {
            await runSyncLoop()
            await refreshPostAuthState()
        }

        if let userId {
            await syncDailyState(userId)
        }
    }

    private static func handleWillEnterForeground(
        skipBackgroundWork: Bool,
        trackWarmLaunchStart: () -> Void,
        runWork: () -> Void
    ) {
        guard !skipBackgroundWork else { return }
        trackWarmLaunchStart()
        runWork()
    }

    private static func handleDidBecomeActive(
        skipBackgroundWork: Bool,
        trackWarmLaunchEnd: () -> Void
    ) {
        guard !skipBackgroundWork else { return }
        trackWarmLaunchEnd()
    }

    var body: some Scene {
        WindowGroup {
            RootView(databaseStartupState: databaseStartupState)
                .environment(authManager)
                .environment(deepLinkRouter)
                .environment(ForceUpdateManager.shared)
                .onOpenURL(perform: handleOpenURL)
                .task(bootstrapAndRunLaunchWork)
                .onAppear { showRecoveryNotice = databaseStartupState.manager?.wasRestoredFromBackup == true }
                .alert(String(localized: "database_restored_title", defaultValue: "Backup restored"), isPresented: $showRecoveryNotice) {
                    Button(String(localized: "ok"), role: .cancel) { }
                } message: {
                    Text(String(localized: "database_restored_message", defaultValue: "Life OS recovered your data from a valid backup after detecting database damage. Recent changes may be missing. The original files were preserved for recovery; please check your latest records."))
                }
#if os(iOS)
                .onReceive(
                    NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification),
                    perform: handleWillEnterForegroundNotification
                )
                .onReceive(
                    NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification),
                    perform: handleDidBecomeActiveNotification
                )
                .onReceive(NotificationCenter.default.publisher(for: .watchDeepLink), perform: handleWatchDeepLinkNotification)
#endif
        }
    }
}

// MARK: - Root View (Auth-Gated)

/// Switches between auth flow and main app based on auth state.
struct RootView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(ForceUpdateManager.self) private var forceUpdateManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var guardianManager = GuardianManager.shared
    @State private var biometricAuthManager = BiometricAuthManager.shared
    @State private var hasRecordedLaunch = false
    @State private var activeBiometricAlert: ActiveBiometricAlert?
    private let databaseStartupState: DatabaseManager.PersistentStartupState
    private let isUsingInMemoryFallback: Bool

    init(
        databaseStartupState: DatabaseManager.PersistentStartupState = DatabaseManager.sharedStartupState,
        isUsingInMemoryFallback: Bool = false
    ) {
        self.databaseStartupState = databaseStartupState
        self.isUsingInMemoryFallback = isUsingInMemoryFallback
    }

    private enum RootContentKind {
        case databaseUnavailable(DatabaseManager.PersistentStartupFailure)
        case loading
        case signedOut
        case needsOnboarding
        case biometricLocked
        case mainTabs
    }

    private enum OverlayKind {
        case forceUpdate(String)
        case softUpdate(String)
        case upToDate
    }

    private enum ActiveBiometricAlert: String, Identifiable {
        case optIn
        case setupFailed

        var id: String { rawValue }
    }

    private static func shouldProtectWithBiometrics(_ authState: AuthState) -> Bool {
        switch authState {
        case .anonymous, .authenticated:
            return true
        case .loading, .needsOnboarding, .signedOut:
            return false
        }
    }

    private static func rootContentKind(
        databaseStartupState: DatabaseManager.PersistentStartupState,
        authState: AuthState,
        isBiometricLocked: Bool
    ) -> RootContentKind {
        if case .unavailable(let failure) = databaseStartupState {
            return .databaseUnavailable(failure)
        }

        switch authState {
        case .loading:
            return .loading
        case .signedOut:
            return .signedOut
        case .needsOnboarding:
            return .needsOnboarding
        case .anonymous, .authenticated:
            return isBiometricLocked ? .biometricLocked : .mainTabs
        }
    }

    private static func overlayKind(for status: ForceUpdateManager.UpdateStatus) -> OverlayKind {
        switch status {
        case .forceUpdate(let minVersion):
            return .forceUpdate(minVersion)
        case .softUpdate(let minVersion):
            return .softUpdate(minVersion)
        case .upToDate:
            return .upToDate
        }
    }

    private static func shouldShowDatabaseFallbackBanner(isUsingInMemoryFallback: Bool) -> Bool {
        isUsingInMemoryFallback
    }

    private static func shouldShowBiometricSnapshotShield(
        authState: AuthState,
        scenePhase: ScenePhase,
        biometricEnabled: Bool
    ) -> Bool {
        biometricEnabled && scenePhase != .active && shouldProtectWithBiometrics(authState)
    }

    @ViewBuilder
    private static func rootContent(for kind: RootContentKind) -> some View {
        switch kind {
        case .databaseUnavailable(let failure):
            DatabaseUnavailableView(failure: failure)
        case .loading:
            ProgressView(String(localized: "loading"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LifeOSColors.Surface.background)
        case .signedOut:
            AuthView()
        case .needsOnboarding:
            OnboardingView()
        case .biometricLocked:
            BiometricLockView()
        case .mainTabs:
            MainTabView()
        }
    }

    var body: some View {
        Group {
            Self.rootContent(
                for: Self.rootContentKind(
                    databaseStartupState: databaseStartupState,
                    authState: authManager.authState,
                    isBiometricLocked: biometricAuthManager.isLocked
                )
            )
        }
        .animation(.default, value: authManager.authState)
        .animation(.default, value: biometricAuthManager.isLocked)
        .safeAreaInset(edge: .top, spacing: 0) {
            if databaseStartupState.isAvailable,
               (Self.shouldShowDatabaseFallbackBanner(isUsingInMemoryFallback: isUsingInMemoryFallback) || guardianManager.runtimeBannerMessage != nil) {
                VStack(spacing: Spacing.xs) {
                    if Self.shouldShowDatabaseFallbackBanner(isUsingInMemoryFallback: isUsingInMemoryFallback) {
                        DatabaseFallbackBanner()
                    }

                    if let runtimeBannerMessage = guardianManager.runtimeBannerMessage {
                        RuntimeStatusBanner(
                            systemImageName: guardianManager.runtimeBannerSymbolName,
                            message: runtimeBannerMessage,
                            dismiss: GuardianManager.shared.dismissRuntimeBanner
                        )
                    }
                }
                .padding(.horizontal, LayoutConstants.contentPadding)
                .padding(.top, Spacing.xs)
            }
        }
        .overlay {
            ZStack {
                if databaseStartupState.isAvailable,
                   Self.shouldShowBiometricSnapshotShield(
                    authState: authManager.authState,
                    scenePhase: scenePhase,
                    biometricEnabled: biometricAuthManager.isBiometricEnabled
                ) {
                    BiometricSnapshotShield()
                }

                if databaseStartupState.isAvailable {
                    switch Self.overlayKind(for: forceUpdateManager.status) {
                    case .forceUpdate(let minVersion):
                        ForceUpdateOverlay(
                            minVersion: minVersion,
                            isSoft: false,
                            appStoreURL: forceUpdateManager.appStoreURL
                        )
                        .task(id: minVersion) {
                            await forceUpdateManager.refreshAppStoreURLIfNeeded()
                        }
                    case .softUpdate(let minVersion):
                        ForceUpdateOverlay(
                            minVersion: minVersion,
                            isSoft: true,
                            appStoreURL: forceUpdateManager.appStoreURL
                        )
                            .allowsHitTesting(false)
                            .padding(.top, 12)
                            .task(id: minVersion) {
                                try? await Task.sleep(nanoseconds: 4_000_000_000)
                                forceUpdateManager.dismissSoftUpdate()
                            }
                    case .upToDate:
                        EmptyView()
                    }
                }
            }
        }
        .onChange(of: authManager.authState) { oldState, newState in
            handleAuthStateChange(from: oldState, to: newState)
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
        .alert(item: $activeBiometricAlert, content: makeBiometricAlert)
        .onAppear {
            if !hasRecordedLaunch {
                hasRecordedLaunch = true
                PerformanceMonitor.trackColdLaunchEnd()
            }
            if databaseStartupState.isAvailable {
                refreshBiometricPresentationIfNeeded()
            }
        }
    }

    private func refreshBiometricPresentationIfNeeded() {
        if Self.shouldProtectWithBiometrics(authManager.authState) {
            biometricAuthManager.lockIfEnabled()
            presentBiometricOptInIfNeeded(for: authManager.authState)
        } else {
            biometricAuthManager.unlock()
        }
    }

    private func handleAuthStateChange(from oldState: AuthState, to newState: AuthState) {
        guard databaseStartupState.isAvailable else { return }
        let oldWasProtected = Self.shouldProtectWithBiometrics(oldState)
        let newIsProtected = Self.shouldProtectWithBiometrics(newState)

        if !newIsProtected {
            biometricAuthManager.unlock()
            if activeBiometricAlert == .optIn {
                activeBiometricAlert = nil
            }
            return
        }

        if !oldWasProtected {
            biometricAuthManager.lockIfEnabled()
        }

        presentBiometricOptInIfNeeded(for: newState)
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        guard databaseStartupState.isAvailable else { return }
        switch newPhase {
        case .background:
            if Self.shouldProtectWithBiometrics(authManager.authState) {
                biometricAuthManager.lockIfEnabled()
            }
        case .active:
            presentBiometricOptInIfNeeded(for: authManager.authState)
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func presentBiometricOptInIfNeeded(for authState: AuthState) {
        guard activeBiometricAlert == nil else { return }
        guard Self.shouldProtectWithBiometrics(authState) else { return }
        guard biometricAuthManager.isBiometricAvailable else { return }
        guard !biometricAuthManager.isBiometricEnabled else { return }
        guard !biometricAuthManager.hasOfferedBiometric else { return }
        guard !biometricAuthManager.isLocked else { return }
        activeBiometricAlert = .optIn
    }

    private func enableBiometricProtection() {
        activeBiometricAlert = nil

        Task {
            let didEnable = await biometricAuthManager.enableBiometrics()
            await MainActor.run {
                if !didEnable {
                    activeBiometricAlert = .setupFailed
                }
            }
        }
    }

    private func declineBiometricProtection() {
        biometricAuthManager.markBiometricOffered()
        activeBiometricAlert = nil
    }

    private func makeBiometricAlert(_ alert: ActiveBiometricAlert) -> Alert {
        switch alert {
        case .optIn:
            return Alert(
                title: Text(String(localized: "biometric_opt_in_title")),
                message: Text(
                    String(
                        format: String(localized: "biometric_opt_in_message_format"),
                        biometricAuthManager.biometricLabel
                    )
                ),
                primaryButton: .default(
                    Text(
                        String(
                            format: String(localized: "biometric_opt_in_enable_format"),
                            biometricAuthManager.biometricLabel
                        )
                    ),
                    action: enableBiometricProtection
                ),
                secondaryButton: .cancel(
                    Text(String(localized: "biometric_opt_in_not_now")),
                    action: declineBiometricProtection
                )
            )
        case .setupFailed:
            return Alert(
                title: Text(String(localized: "biometric_opt_in_failed_title")),
                message: Text(String(localized: "biometric_opt_in_failed_message")),
                dismissButton: .default(Text(String(localized: "ok")))
            )
        }
    }
}

#Preview {
    RootView()
        .environment(AuthManager())
        .environment(ForceUpdateManager.shared)
}

private struct BiometricSnapshotShield: View {
    var body: some View {
        ZStack {
            LifeOSColors.Surface.background
                .ignoresSafeArea()

            VStack(spacing: Spacing.s) {
                Image(systemName: "lock.shield.fill")
                    .font(LifeOSTypography.metricMedium)
                    .foregroundStyle(LifeOSColors.Semantic.primary)

                Text(String(localized: "app_name"))
                    .font(LifeOSTypography.headline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct DatabaseUnavailableView: View {
    let failure: DatabaseManager.PersistentStartupFailure

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                Spacer(minLength: Spacing.xl)

                ZStack {
                    Circle()
                        .fill(LifeOSColors.Recovery.critical.opacity(0.14))
                        .frame(width: 88, height: 88)

                    Image(systemName: failure.kind.symbolName)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(LifeOSColors.Recovery.critical)
                }

                VStack(spacing: Spacing.s) {
                    Text(failure.kind.title)
                        .font(LifeOSTypography.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)

                    Text(failure.kind.message)
                        .font(LifeOSTypography.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text(failure.protectionMessage)
                        .font(LifeOSTypography.footnote)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .padding(.top, Spacing.xs)
                }
                .frame(maxWidth: 520)

                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(String(localized: "startup_recovery_next_steps"))
                        .font(LifeOSTypography.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    ForEach(Array(failure.kind.recoverySteps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: Spacing.s) {
                            Text("\(index + 1).")
                                .font(LifeOSTypography.footnote.weight(.semibold))
                                .foregroundStyle(LifeOSColors.Recovery.caution)

                            Text(step)
                                .font(LifeOSTypography.footnote)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(Spacing.m)
                .frame(maxWidth: 560, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius)
                        .fill(LifeOSColors.Surface.card)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }

                #if DEBUG
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Startup diagnostic")
                        .font(LifeOSTypography.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(failure.reason)
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    if let databaseURL = failure.databaseURL?.path {
                        Text(databaseURL)
                            .font(LifeOSTypography.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    if let databaseDirectoryURL = failure.databaseDirectoryURL?.path {
                        Text(databaseDirectoryURL)
                            .font(LifeOSTypography.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(Spacing.m)
                .frame(maxWidth: 560, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius)
                        .fill(LifeOSColors.Surface.card.opacity(0.88))
                )
                #endif

                Spacer(minLength: Spacing.xl)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, LayoutConstants.contentPadding)
            .padding(.vertical, Spacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LifeOSColors.Surface.background
                .ignoresSafeArea()
        }
    }
}

private struct DatabaseFallbackBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(LifeOSTypography.body.weight(.semibold))
                .foregroundStyle(LifeOSColors.Semantic.warning)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(String(localized: "database_fallback_banner_title"))
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(String(localized: "database_fallback_banner_body"))
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius)
                .fill(LifeOSColors.Semantic.warning.opacity(0.12))
        )
        .overlay {
            RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius)
                .stroke(LifeOSColors.Semantic.warning.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("database.fallback.banner")
    }
}

private struct RuntimeStatusBanner: View {
    let systemImageName: String
    let message: String
    let dismiss: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: systemImageName)
                .font(LifeOSTypography.body.weight(.semibold))
                .foregroundStyle(LifeOSColors.Semantic.warning)
                .padding(.top, 2)

            Text(message)
                .font(LifeOSTypography.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(LifeOSTypography.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(minWidth: LayoutConstants.minTouchTarget, minHeight: LayoutConstants.minTouchTarget)
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius)
                .fill(LifeOSColors.Semantic.warning.opacity(0.12))
        )
        .overlay {
            RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius)
                .stroke(LifeOSColors.Semantic.warning.opacity(0.35), lineWidth: 1)
        }
        .accessibilityIdentifier("app.runtime.banner")
    }
}

private struct ForceUpdateOverlay: View {
    @Environment(\.openURL) private var openURL

    let minVersion: String
    let isSoft: Bool
    let appStoreURL: URL

    var body: some View {
        ZStack {
            if !isSoft {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
            }

            VStack(spacing: Spacing.s) {
                Text(isSoft ? String(localized: "force_update_available_title") : String(localized: "force_update_required_title"))
                    .font(LifeOSTypography.headline.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(String(format: String(localized: "force_update_min_version_format"), minVersion))
                    .font(LifeOSTypography.body)
                    .multilineTextAlignment(.center)

                if !isSoft {
                    Text(String(localized: "force_update_required_body"))
                        .font(LifeOSTypography.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(String(localized: "force_update_open_store_cta"), action: openStoreAction)
                    .buttonStyle(.borderedProminent)
                    .frame(minWidth: LayoutConstants.minTouchTarget, minHeight: LayoutConstants.minTouchTarget)
                } else {
                    Text(String(format: String(localized: "force_update_available_body_format"), minVersion))
                        .font(LifeOSTypography.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(LayoutConstants.contentPadding)
            .frame(maxWidth: isSoft ? 360 : 320)
            .background(LifeOSColors.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
            .padding(.horizontal, LayoutConstants.contentPadding)
        }
    }

    private func openStoreAction() {
        let currentAppStoreURL = appStoreURL
        Task { @MainActor in
            let resolvedURL = await ForceUpdateManager.resolveStoreURLForOpening(
                currentURL: currentAppStoreURL,
                infoDictionary: Bundle.main.infoDictionary
            )
            openURL(resolvedURL)
        }
    }
}

#if DEBUG
extension LifeOSApp {
    nonisolated static func _testSetAsyncHelperOverrides(
        bootstrap: (@Sendable () async -> Void)? = nil,
        runSyncLoop: (@Sendable () async throws -> Void)? = nil,
        refreshAuthState: (@Sendable () async -> Void)? = nil,
        runPrivacyMaintenance: (@Sendable () async throws -> Void)? = nil,
        syncDailyState: (@Sendable (UUID) async throws -> Void)? = nil
    ) {
        testBootstrapOverride.value = bootstrap
        testRunSyncLoopOverride.value = runSyncLoop
        testRefreshAuthStateOverride.value = refreshAuthState
        testRunPrivacyMaintenanceOverride.value = runPrivacyMaintenance
        testSyncDailyStateOverride.value = syncDailyState
    }

    nonisolated static func _testResetAsyncHelperOverrides() {
        testBootstrapOverride.value = nil
        testRunSyncLoopOverride.value = nil
        testRefreshAuthStateOverride.value = nil
        testRunPrivacyMaintenanceOverride.value = nil
        testSyncDailyStateOverride.value = nil
    }

    @MainActor
    static func _testInitializeAndEvaluateBody() {
        let app = LifeOSApp()
        _ = app.body
    }

    static func _testWatchDeepLinkURL(userInfo: [AnyHashable: Any]?) -> URL? {
        watchDeepLinkURL(from: userInfo)
    }

    @MainActor
    static func _testApplyInitialURLIfNeeded(with initialURL: URL?) -> String? {
        let previousValue = ProcessInfo.processInfo.environment["LIFEOS_UI_TEST_INITIAL_URL"]
        defer {
            if let previousValue {
                setenv("LIFEOS_UI_TEST_INITIAL_URL", previousValue, 1)
            } else {
                unsetenv("LIFEOS_UI_TEST_INITIAL_URL")
            }
        }

        if let initialURL {
            setenv("LIFEOS_UI_TEST_INITIAL_URL", initialURL.absoluteString, 1)
        } else {
            unsetenv("LIFEOS_UI_TEST_INITIAL_URL")
        }

        let app = LifeOSApp()
        app.applyInitialURLIfNeeded()
        return app.deepLinkRouter.pendingNavigation?.id
    }

    @MainActor
    static func _testApplyPendingWatchDeepLinks(_ deepLinks: [String]) -> String? {
        WatchSyncManager._testResetPendingWatchDeepLinks()
        defer { WatchSyncManager._testResetPendingWatchDeepLinks() }

        for deepLink in deepLinks {
            WatchSyncManager.enqueuePendingWatchDeepLink(deepLink)
        }

        let app = LifeOSApp()
        app.applyPendingWatchDeepLinksIfNeeded()
        return app.deepLinkRouter.pendingNavigation?.id
    }

    @MainActor
    static func _testHandleWatchDeepLinkNotification(
        userInfo: [AnyHashable: Any]?,
        pendingDeepLinks: [String] = []
    ) -> String? {
        WatchSyncManager._testResetPendingWatchDeepLinks()
        defer { WatchSyncManager._testResetPendingWatchDeepLinks() }

        for deepLink in pendingDeepLinks {
            WatchSyncManager.enqueuePendingWatchDeepLink(deepLink)
        }

        let app = LifeOSApp()
        app.handleWatchDeepLinkNotification(
            Notification(name: .watchDeepLink, object: nil, userInfo: userInfo)
        )
        return app.deepLinkRouter.pendingNavigation?.id
    }

    @MainActor
    static func _testExerciseInstanceEntrypoints(runBootstrap: Bool = false) async {
        let app = LifeOSApp()
        app.handleWatchDeepLinkNotification(
            Notification(name: .watchDeepLink, object: nil, userInfo: [:])
        )
        app.handleOpenURL(URL(string: "lifeos://nutrition/log")!)
        app.handleWatchDeepLinkNotification(
            Notification(name: .watchDeepLink, object: nil, userInfo: ["deep_link": "lifeos://wellness"])
        )
        app.handleWillEnterForegroundNotification(
            Notification(name: Notification.Name("test.foreground"), object: nil)
        )
        app.handleDidBecomeActiveNotification(
            Notification(name: Notification.Name("test.active"), object: nil)
        )
        if runBootstrap {
            await app.bootstrapAndRunLaunchWork()
        }
    }

    @MainActor
    static func _testExercisePrivateAsyncHelpers(
        userId: UUID,
        runLiveOperations: Bool = false
    ) async {
        guard runLiveOperations else {
            await performPostBootstrapWork(
                skipBackgroundWork: false,
                hasCloudSession: true,
                userId: userId,
                runSyncLoop: _testNoopAsync,
                refreshPostAuthState: _testNoopAsync,
                runMaintenance: _testNoopAsync,
                scheduleDailyPull: _testNoopSync,
                scheduleOutboxReplay: _testNoopSync,
                syncDailyState: _testNoopSyncDailyState
            )
            await performForegroundWork(
                skipBackgroundWork: false,
                hasCloudSession: true,
                userId: userId,
                runSyncLoop: _testNoopAsync,
                refreshPostAuthState: _testNoopAsync,
                syncDailyState: _testNoopSyncDailyState
            )
            return
        }

        let app = LifeOSApp()
        await app.runSyncLoopIfAvailable()
        await app.refreshAuthState()
        await app.runPrivacyMaintenance()
        await app.syncDailyStateIfAvailable(userId: userId)
    }

    @MainActor
    static func _testRefreshAuthStateDefaultPath() async {
        let app = LifeOSApp()
        await app.refreshAuthState()
    }

    static func _testRunSyncLoopDefault(syncEngine: SyncEngine) async {
        try? await runSyncLoop(syncEngine: syncEngine)
    }

    static func _testRunPrivacyMaintenanceDefault() async {
        let dbQueue = try? DatabaseManager.inMemory().dbQueue
        if let dbQueue {
            try? await runPrivacyMaintenanceTask(dbQueue: dbQueue)
        }
    }

    static func _testRunSyncDailyStateDefault(userId: UUID) async {
        try? await syncDailyState(userId: userId)
    }

    static func _testRunSyncDailyStateOverrideProbe(userId: UUID) async -> Bool {
        (try? await runSyncDailyStateOverrideIfPresent(userId)) ?? false
    }

    nonisolated private static func _testNoopSync() {}

    nonisolated private static func _testNoopAsync() async {}

    nonisolated private static func _testNoopSyncDailyState(_: UUID) async {}

    static func _testHandleForegroundEvent(
        skipBackgroundWork: Bool
    ) -> (started: Int, workRuns: Int) {
        var started = 0
        var workRuns = 0
        handleWillEnterForeground(
            skipBackgroundWork: skipBackgroundWork,
            trackWarmLaunchStart: { started += 1 },
            runWork: { workRuns += 1 }
        )
        return (started, workRuns)
    }

    static func _testHandleDidBecomeActiveEvent(
        skipBackgroundWork: Bool
    ) -> Int {
        var ended = 0
        handleDidBecomeActive(
            skipBackgroundWork: skipBackgroundWork,
            trackWarmLaunchEnd: { ended += 1 }
        )
        return ended
    }

    static func _testPerformPostBootstrapWork(
        skipBackgroundWork: Bool,
        isAuthenticated: Bool,
        userId: UUID?
    ) async -> (syncLoops: Int, refreshes: Int, maintenances: Int, schedules: Int, syncedUserIds: [UUID]) {
        final class StateStore: @unchecked Sendable {
            private let lock = NSLock()
            private var syncLoops = 0
            private var refreshes = 0
            private var maintenances = 0
            private var schedules = 0
            private var syncedUserIds: [UUID] = []

            func incrementSyncLoops() {
                lock.lock()
                syncLoops += 1
                lock.unlock()
            }

            func incrementRefreshes() {
                lock.lock()
                refreshes += 1
                lock.unlock()
            }

            func incrementMaintenances() {
                lock.lock()
                maintenances += 1
                lock.unlock()
            }

            func incrementSchedules() {
                lock.lock()
                schedules += 1
                lock.unlock()
            }

            func appendUserId(_ id: UUID) {
                lock.lock()
                syncedUserIds.append(id)
                lock.unlock()
            }

            func snapshot() -> (syncLoops: Int, refreshes: Int, maintenances: Int, schedules: Int, syncedUserIds: [UUID]) {
                lock.lock()
                let value = (syncLoops, refreshes, maintenances, schedules, syncedUserIds)
                lock.unlock()
                return value
            }
        }
        let state = StateStore()

        await performPostBootstrapWork(
            skipBackgroundWork: skipBackgroundWork,
            hasCloudSession: isAuthenticated,
            userId: userId,
            runSyncLoop: {
                state.incrementSyncLoops()
            },
            refreshPostAuthState: {
                state.incrementRefreshes()
            },
            runMaintenance: {
                state.incrementMaintenances()
            },
            scheduleDailyPull: {
                state.incrementSchedules()
            },
            scheduleOutboxReplay: {
                state.incrementSchedules()
            },
            syncDailyState: { id in
                state.appendUserId(id)
            }
        )
        return state.snapshot()
    }

    static func _testPerformForegroundWork(
        skipBackgroundWork: Bool,
        isAuthenticated: Bool,
        userId: UUID?
    ) async -> (syncLoops: Int, refreshes: Int, syncedUserIds: [UUID]) {
        final class StateStore: @unchecked Sendable {
            private let lock = NSLock()
            private var syncLoops = 0
            private var refreshes = 0
            private var syncedUserIds: [UUID] = []

            func incrementSyncLoops() {
                lock.lock()
                syncLoops += 1
                lock.unlock()
            }

            func incrementRefreshes() {
                lock.lock()
                refreshes += 1
                lock.unlock()
            }

            func appendUserId(_ id: UUID) {
                lock.lock()
                syncedUserIds.append(id)
                lock.unlock()
            }

            func snapshot() -> (syncLoops: Int, refreshes: Int, syncedUserIds: [UUID]) {
                lock.lock()
                let value = (syncLoops, refreshes, syncedUserIds)
                lock.unlock()
                return value
            }
        }
        let state = StateStore()

        await performForegroundWork(
            skipBackgroundWork: skipBackgroundWork,
            hasCloudSession: isAuthenticated,
            userId: userId,
            runSyncLoop: {
                state.incrementSyncLoops()
            },
            refreshPostAuthState: {
                state.incrementRefreshes()
            },
            syncDailyState: { id in
                state.appendUserId(id)
            }
        )
        return state.snapshot()
    }
}

extension RootView {
    @MainActor
    func _testEvaluateBody() {
        #if os(iOS)
        let host = UIHostingController(
            rootView: self
                .environment(AuthManager())
                .environment(ForceUpdateManager())
        )
        host.loadViewIfNeeded()
        #else
        _ = body
        #endif
    }

    @MainActor
    static func _testMakeForceUpdateOverlay(
        minVersion: String,
        isSoft: Bool,
        appStoreURL: URL
    ) -> some View {
        ForceUpdateOverlay(
            minVersion: minVersion,
            isSoft: isSoft,
            appStoreURL: appStoreURL
        )
    }

    static func _testRootContentKind(for authState: AuthState, isBiometricLocked: Bool = false) -> String {
        switch rootContentKind(
            databaseStartupState: .available(DatabaseManager._testMakeManagerWithForcedPersistentFailure()),
            authState: authState,
            isBiometricLocked: isBiometricLocked
        ) {
        case .databaseUnavailable:
            return "databaseUnavailable"
        case .loading: return "loading"
        case .signedOut: return "signedOut"
        case .needsOnboarding: return "needsOnboarding"
        case .biometricLocked: return "biometricLocked"
        case .mainTabs: return "mainTabs"
        }
    }

    static func _testOverlayKind(for status: ForceUpdateManager.UpdateStatus) -> String {
        switch overlayKind(for: status) {
        case .forceUpdate: return "forceUpdate"
        case .softUpdate: return "softUpdate"
        case .upToDate: return "upToDate"
        }
    }

    static func _testShouldShowDatabaseFallbackBanner(isUsingInMemoryFallback: Bool) -> Bool {
        shouldShowDatabaseFallbackBanner(isUsingInMemoryFallback: isUsingInMemoryFallback)
    }

    static func _testShouldShowBiometricSnapshotShield(
        authState: AuthState,
        scenePhase: ScenePhase,
        biometricEnabled: Bool
    ) -> Bool {
        shouldShowBiometricSnapshotShield(
            authState: authState,
            scenePhase: scenePhase,
            biometricEnabled: biometricEnabled
        )
    }

    static func _testEvaluateForceUpdateOverlayBodies(minVersion: String, appStoreURL: URL) {
        _ = ForceUpdateOverlay(minVersion: minVersion, isSoft: true, appStoreURL: appStoreURL).body
        _ = ForceUpdateOverlay(minVersion: minVersion, isSoft: false, appStoreURL: appStoreURL).body
    }

    static func _testEvaluateRootContentBodies() {
        _ = rootContent(
            for: .databaseUnavailable(
                DatabaseManager.PersistentStartupFailure(
                    kind: .unknown,
                    reason: "test",
                    databaseURL: nil,
                    databaseDirectoryURL: nil
                )
            )
        )
        _ = rootContent(for: .loading)
        _ = rootContent(for: .signedOut)
        _ = rootContent(for: .needsOnboarding)
        _ = rootContent(for: .biometricLocked)
        _ = rootContent(for: .mainTabs)
    }

    static func _testMakeDatabaseFallbackBanner() -> some View {
        DatabaseFallbackBanner()
    }

    static func _testEvaluateDatabaseFallbackBannerBody() {
        _ = DatabaseFallbackBanner().body
    }

    @MainActor
    static func _testTriggerForceUpdateOpenStoreAction(minVersion: String, appStoreURL: URL) {
        ForceUpdateOverlay(
            minVersion: minVersion,
            isSoft: false,
            appStoreURL: appStoreURL
        )._testTriggerOpenStoreAction()
    }
}

private extension ForceUpdateOverlay {
    @MainActor
    func _testTriggerOpenStoreAction() {
        openStoreAction()
    }
}
#endif
