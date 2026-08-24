// MARK: - Background Sync Manager
// Source of truth: life_os_sync_engine_spec.md §10
// BGProcessingTask for outbox replay. BGAppRefreshTask for daily pull.

import Foundation
@preconcurrency import BackgroundTasks
import GRDB
import OSLog

/// Registers and handles background tasks for sync.
enum BackgroundSyncManager {

    // MARK: - Task Identifiers

    static let outboxReplayTaskId = "com.lifeos.sync.outbox-replay"
    static let dailyPullTaskId = "com.lifeos.sync.daily-pull"
    private static let logger = Logger(subsystem: "com.lifeos.app", category: "BackgroundSync")
    private nonisolated static let baseIsRunningTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private static let registrationState = OSAllocatedUnfairLock<Bool>(initialState: false)
#if DEBUG
    private static let testIsRunningTestsOverride = LockedTestOverride<Bool>()
    private static let testRegisterTaskOverride = LockedTestOverride<(_ identifier: String, _ handler: @escaping (BGTask) -> Void) -> Void>()
    private static let testOutboxActionOverride = LockedTestOverride<@Sendable (SyncEngine) async throws -> Void>()
    private static let testDailyPullActionOverride = LockedTestOverride<@Sendable (SyncEngine) async throws -> Void>()
    private static let testSubmitTaskRequestOverride = LockedTestOverride<(BGTaskRequest) throws -> Void>()
#endif

    private enum BackgroundSyncTaskError: Error {
        case syncEngineUnavailable
    }

    private static var shouldAttemptBackgroundScheduling: Bool {
        computeShouldAttemptBackgroundScheduling(isRunningTests: isRunningTests)
    }

    /// Whether this process may talk to the real system BGTaskScheduler.
    /// XCTest runs must stay isolated even when logic tests override
    /// `isRunningTests` to exercise non-test code paths.
    private static var shouldUseSystemScheduler: Bool {
        !baseIsRunningTests
    }

    private static var isRunningTests: Bool {
#if DEBUG
        if let override = testIsRunningTestsOverride.value {
            return override
        }
#endif
        return baseIsRunningTests
    }

    private static func computeShouldAttemptBackgroundScheduling(isRunningTests: Bool) -> Bool {
        guard !isRunningTests else { return false }
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    // MARK: - Registration (call from LifeOSApp.init)

    static func registerTasks() {
        let shouldRegister = registrationState.withLock { registered -> Bool in
            if registered {
                return false
            }
            registered = true
            return true
        }
        performRegistration(
            shouldRegister: shouldRegister,
            isRunningTests: isRunningTests,
            register: registerTaskWithScheduler(identifier:handler:)
        )
    }

    private static func registerTaskWithScheduler(
        identifier: String,
        handler: @escaping (BGTask) -> Void
    ) {
#if DEBUG
        if let override = testRegisterTaskOverride.value {
            override(identifier, handler)
            return
        }
#endif
        guard shouldUseSystemScheduler else { return }
        let didRegister = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil,
            launchHandler: handler
        )
        if !didRegister {
            logger.error("Failed to register background task: \(identifier, privacy: .public)")
        }
    }

    private static func registerOutboxReplayTask(_ task: BGTask) {
        handleOutboxReplayInternal(
            scheduleNext: scheduleOutboxReplay,
            syncEngineProvider: { AppContainer.shared?.syncEngine },
            complete: { task.setTaskCompleted(success: $0) },
            setExpirationHandler: { handler in
                setExpirationHandlerIfSupported(task: task, handler: handler)
            }
        )
    }

    private static func registerDailyPullTask(_ task: BGTask) {
        handleDailyPullInternal(
            scheduleNext: scheduleDailyPull,
            syncEngineProvider: { AppContainer.shared?.syncEngine },
            complete: { task.setTaskCompleted(success: $0) },
            setExpirationHandler: { handler in
                setExpirationHandlerIfSupported(task: task, handler: handler)
            }
        )
    }

    private static func performRegistration(
        shouldRegister: Bool,
        isRunningTests: Bool,
        register: (_ identifier: String, _ handler: @escaping (BGTask) -> Void) -> Void
    ) {
        guard shouldRegister else { return }
        // Avoid touching BGTaskScheduler in XCTest processes to prevent duplicate-registration assertions.
        guard !isRunningTests else { return }
        register(outboxReplayTaskId, registerOutboxReplayTask)
        register(dailyPullTaskId, registerDailyPullTask)
    }

    private static func setExpirationHandlerIfSupported(task: BGTask, handler: @escaping () -> Void) {
        if shouldAssignExpirationHandler(supportsExpiration: task.responds(to: Selector(("setExpirationHandler:")))) {
            task.expirationHandler = handler
        }
    }

    private static func shouldAssignExpirationHandler(supportsExpiration: Bool) -> Bool {
        supportsExpiration
    }

    // MARK: - Schedule

    /// Schedule outbox replay for when device is on wifi + power.
    static func scheduleOutboxReplay() {
        scheduleOutboxReplayWithDefaultSubmit(
            shouldSchedule: shouldAttemptBackgroundScheduling,
            now: Date()
        )
    }

    /// Schedule daily pull sync.
    static func scheduleDailyPull() {
        scheduleDailyPullWithDefaultSubmit(
            shouldSchedule: shouldAttemptBackgroundScheduling,
            now: Date()
        )
    }

    private static func submitTaskRequest(_ request: BGTaskRequest) throws {
    #if DEBUG
        if let override = testSubmitTaskRequestOverride.value {
            try override(request)
            return
        }
    #endif
        guard shouldUseSystemScheduler else { return }
        try BGTaskScheduler.shared.submit(request)
    }

    private static func scheduleOutboxReplay(
        shouldSchedule: Bool,
        now: Date,
        submit: (BGTaskRequest) throws -> Void
    ) {
        guard shouldSchedule else { return }

        let request = BGProcessingTaskRequest(identifier: outboxReplayTaskId)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true   // §10: avoid battery drain during background sync
        request.earliestBeginDate = now.addingTimeInterval(15 * 60)

        do {
            try submit(request)
        } catch {
            logger.error("Failed to schedule outbox replay: \(error.localizedDescription)")
        }
    }

    private static func scheduleOutboxReplayWithDefaultSubmit(
        shouldSchedule: Bool,
        now: Date
    ) {
        guard shouldSchedule else { return }

        let request = BGProcessingTaskRequest(identifier: outboxReplayTaskId)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        request.earliestBeginDate = now.addingTimeInterval(15 * 60)

        do {
            try submitTaskRequest(request)
        } catch {
            logger.error("Failed to schedule outbox replay: \(error.localizedDescription)")
        }
    }

    private static func scheduleDailyPull(
        shouldSchedule: Bool,
        now: Date,
        submit: (BGTaskRequest) throws -> Void
    ) {
        guard shouldSchedule else { return }

        let request = BGAppRefreshTaskRequest(identifier: dailyPullTaskId)
        request.earliestBeginDate = now.addingTimeInterval(4 * 3600)

        do {
            try submit(request)
        } catch {
            logger.error("Failed to schedule daily pull: \(error.localizedDescription)")
        }
    }

    private static func scheduleDailyPullWithDefaultSubmit(
        shouldSchedule: Bool,
        now: Date
    ) {
        guard shouldSchedule else { return }

        let request = BGAppRefreshTaskRequest(identifier: dailyPullTaskId)
        request.earliestBeginDate = now.addingTimeInterval(4 * 3600)

        do {
            try submitTaskRequest(request)
        } catch {
            logger.error("Failed to schedule daily pull: \(error.localizedDescription)")
        }
    }

    // MARK: - Handlers

    private static func runBackgroundTask(
        scheduleNext: () -> Void,
        action: @escaping @Sendable () async throws -> Void,
        complete: @escaping @MainActor (Bool) -> Void,
        setExpirationHandler: (@escaping () -> Void) -> Void
    ) {
        scheduleNext()

        let taskOp = Task {
            do {
                try await action()
                await complete(true)
            } catch {
                await complete(false)
            }
        }

        setExpirationHandler {
            taskOp.cancel()
        }
    }

    private static func outboxReplayAction(
        syncEngineProvider: @escaping @Sendable () -> SyncEngine?
    ) -> @Sendable () async throws -> Void {
        {
            guard let syncEngine = syncEngineProvider() else {
                throw BackgroundSyncTaskError.syncEngineUnavailable
            }
#if DEBUG
            if let override = testOutboxActionOverride.value {
                try await override(syncEngine)
                return
            }
#endif
            try await syncEngine.pushPendingEvents()
        }
    }

    private static func dailyPullAction(
        syncEngineProvider: @escaping @Sendable () -> SyncEngine?
    ) -> @Sendable () async throws -> Void {
        {
            guard let syncEngine = syncEngineProvider() else {
                throw BackgroundSyncTaskError.syncEngineUnavailable
            }
#if DEBUG
            if let override = testDailyPullActionOverride.value {
                try await override(syncEngine)
                return
            }
#endif
            try await syncEngine.pullAll()
        }
    }

    private static func dispatchRegisteredTask<T>(
        castedTask: T?,
        completeFailure: () -> Void,
        handleTask: (T) -> Void
    ) {
        guard let castedTask else {
            completeFailure()
            return
        }
        handleTask(castedTask)
    }

    private static func handleOutboxReplayInternal(
        scheduleNext: @escaping () -> Void,
        syncEngineProvider: @escaping @Sendable () -> SyncEngine?,
        complete: @escaping @MainActor (Bool) -> Void,
        setExpirationHandler: (@escaping () -> Void) -> Void
    ) {
        runBackgroundTask(
            scheduleNext: scheduleNext,
            action: outboxReplayAction(syncEngineProvider: syncEngineProvider),
            complete: complete,
            setExpirationHandler: setExpirationHandler
        )
    }

    private static func handleDailyPullInternal(
        scheduleNext: @escaping () -> Void,
        syncEngineProvider: @escaping @Sendable () -> SyncEngine?,
        complete: @escaping @MainActor (Bool) -> Void,
        setExpirationHandler: (@escaping () -> Void) -> Void
    ) {
        runBackgroundTask(
            scheduleNext: scheduleNext,
            action: dailyPullAction(syncEngineProvider: syncEngineProvider),
            complete: complete,
            setExpirationHandler: setExpirationHandler
        )
    }

}

#if DEBUG
extension BackgroundSyncManager {
    static func _testSetRegistrationOverrides(
        isRunningTests: Bool? = nil,
        registerTask: ((_ identifier: String, _ handler: @escaping (BGTask) -> Void) -> Void)? = nil
    ) {
        testIsRunningTestsOverride.value = isRunningTests
        testRegisterTaskOverride.value = registerTask
    }

    static func _testResetRegistrationOverrides() {
        testIsRunningTestsOverride.value = nil
        testRegisterTaskOverride.value = nil
        testSubmitTaskRequestOverride.value = nil
    }

    static func _testInvokeRegisterTasks() {
        registerTasks()
    }

    static func _testSetActionOverrides(
        outbox: (@Sendable (SyncEngine) async throws -> Void)? = nil,
        dailyPull: (@Sendable (SyncEngine) async throws -> Void)? = nil
    ) {
        testOutboxActionOverride.value = outbox
        testDailyPullActionOverride.value = dailyPull
    }

    static func _testResetActionOverrides() {
        testOutboxActionOverride.value = nil
        testDailyPullActionOverride.value = nil
    }

    static func _testPerformRegistration(shouldRegister: Bool, isRunningTests: Bool) -> [String] {
        var registrations: [String] = []
        performRegistration(shouldRegister: shouldRegister, isRunningTests: isRunningTests) { identifier, _ in
            registrations.append(identifier)
        }
        return registrations
    }

    static func _testSetExpirationHandlerIfSupported(supportsExpiration: Bool) -> Bool {
        shouldAssignExpirationHandler(supportsExpiration: supportsExpiration)
    }

    static func _testComputeShouldAttemptBackgroundScheduling(isRunningTests: Bool) -> Bool {
        computeShouldAttemptBackgroundScheduling(isRunningTests: isRunningTests)
    }

    static func _testScheduleOutboxReplay(
        shouldSchedule: Bool,
        now: Date,
        submit: (BGTaskRequest) throws -> Void
    ) {
        scheduleOutboxReplay(shouldSchedule: shouldSchedule, now: now, submit: submit)
    }

    static func _testScheduleOutboxReplayWithDefaultSubmit(shouldSchedule: Bool, now: Date) {
        scheduleOutboxReplayWithDefaultSubmit(shouldSchedule: shouldSchedule, now: now)
    }

    static func _testScheduleDailyPull(
        shouldSchedule: Bool,
        now: Date,
        submit: (BGTaskRequest) throws -> Void
    ) {
        scheduleDailyPull(shouldSchedule: shouldSchedule, now: now, submit: submit)
    }

    static func _testScheduleDailyPullWithDefaultSubmit(shouldSchedule: Bool, now: Date) {
        scheduleDailyPullWithDefaultSubmit(shouldSchedule: shouldSchedule, now: now)
    }

    static func _testSetSubmitTaskRequestOverride(_ override: ((BGTaskRequest) throws -> Void)?) {
        testSubmitTaskRequestOverride.value = override
    }

    static func _testRunBackgroundTask(
        triggerExpiration: Bool = false,
        action: @escaping @Sendable () async throws -> Void
    ) async -> (scheduleCalls: Int, completions: [Bool], hasExpirationHandler: Bool) {
        let state = OSAllocatedUnfairLock<(scheduleCalls: Int, completions: [Bool])>(
            initialState: (0, [])
        )
        var expirationHandler: (() -> Void)?

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            runBackgroundTask(
                scheduleNext: {
                    state.withLock {
                        $0.scheduleCalls += 1
                    }
                },
                action: action,
                complete: { success in
                    state.withLock {
                        $0.completions.append(success)
                    }
                    continuation.resume()
                },
                setExpirationHandler: { handler in
                    expirationHandler = handler
                }
            )

            if triggerExpiration {
                expirationHandler?()
            }
        }

        let snapshot = state.withLock { $0 }
        return (snapshot.scheduleCalls, snapshot.completions, expirationHandler != nil)
    }

    static func _testRunOutboxReplayAction(syncEngine: SyncEngine?) async -> Bool {
        do {
            try await outboxReplayAction(syncEngineProvider: { syncEngine })()
            return true
        } catch {
            return false
        }
    }

    static func _testRunDailyPullAction(syncEngine: SyncEngine?) async -> Bool {
        do {
            try await dailyPullAction(syncEngineProvider: { syncEngine })()
            return true
        } catch {
            return false
        }
    }

    static func _testDispatchRegisteredTaskSamples() -> (nilFailures: Int, handledValues: [Int]) {
        var nilFailures = 0
        var handledValues: [Int] = []
        let appendHandler: (Int) -> Void = { handledValues.append($0) }
        let failureHandler: () -> Void = { nilFailures += 1 }

        dispatchRegisteredTask(
            castedTask: Optional<Int>.none,
            completeFailure: failureHandler,
            handleTask: appendHandler
        )
        dispatchRegisteredTask(
            castedTask: Optional<Int>.some(42),
            completeFailure: failureHandler,
            handleTask: appendHandler
        )

        return (nilFailures, handledValues)
    }

    static func _testDispatchOutboxRegisteredTask(_ task: BGTask) {
        registerOutboxReplayTask(task)
    }

    static func _testDispatchDailyRegisteredTask(_ task: BGTask) {
        registerDailyPullTask(task)
    }

    static func _testResetRegistrationState() {
        registrationState.withLock { registered in
            registered = false
        }
    }

    static func _testSubmitTaskRequestNoop(identifier: String) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        try? submitTaskRequest(request)
    }

    static func _testRunInternalHandlers(
        runOutbox: Bool,
        triggerExpiration: Bool = false
    ) async -> (scheduleCalls: Int, completions: [Bool], hasExpirationHandler: Bool) {
        let state = OSAllocatedUnfairLock<(scheduleCalls: Int, completions: [Bool])>(
            initialState: (0, [])
        )
        var expirationHandler: (() -> Void)?

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let complete: @MainActor (Bool) -> Void = { success in
                state.withLock {
                    $0.completions.append(success)
                }
                continuation.resume()
            }

            if runOutbox {
                handleOutboxReplayInternal(
                    scheduleNext: {
                        state.withLock { $0.scheduleCalls += 1 }
                    },
                    syncEngineProvider: { nil },
                    complete: complete,
                    setExpirationHandler: { expirationHandler = $0 }
                )
            } else {
                handleDailyPullInternal(
                    scheduleNext: {
                        state.withLock { $0.scheduleCalls += 1 }
                    },
                    syncEngineProvider: { nil },
                    complete: complete,
                    setExpirationHandler: { expirationHandler = $0 }
                )
            }

            if triggerExpiration {
                expirationHandler?()
            }
        }

        let snapshot = state.withLock { $0 }
        return (snapshot.scheduleCalls, snapshot.completions, expirationHandler != nil)
    }
}
#endif

// MARK: - App Container (lightweight DI)

/// Simple shared container for background task access to core services.
/// Thread-safe via OSAllocatedUnfairLock to prevent data races between
/// main thread init and background task handlers.
final class AppContainer: Sendable {
    private static let _lock = OSAllocatedUnfairLock<AppContainer?>(initialState: nil)

    static var shared: AppContainer? {
        get { _lock.withLock { $0 } }
        set { _lock.withLock { $0 = newValue } }
    }

    let dbQueue: DatabaseQueue
    let syncEngine: SyncEngine
    let notificationScheduler: NotificationScheduleCoordinator
    let widgetSnapshotCoordinator: WidgetSnapshotCoordinator
    let featureFlags: FeatureFlagManager

    init(
        syncEngine: SyncEngine,
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue,
        notificationScheduler: NotificationScheduleCoordinator? = nil,
        widgetSnapshotCoordinator: WidgetSnapshotCoordinator? = nil,
        featureFlags: FeatureFlagManager? = nil
    ) {
        self.dbQueue = dbQueue
        self.syncEngine = syncEngine
        self.notificationScheduler = notificationScheduler ?? NotificationScheduleCoordinator(
            dbQueue: dbQueue
        )
        self.widgetSnapshotCoordinator = widgetSnapshotCoordinator ?? WidgetSnapshotCoordinator(
            dbQueue: dbQueue
        )
        self.featureFlags = featureFlags ?? FeatureFlagManager(dbQueue: dbQueue)
    }
}
