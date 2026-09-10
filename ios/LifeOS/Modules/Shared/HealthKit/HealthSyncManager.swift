import Foundation
import GRDB
import Observation

protocol HealthSyncDataProviding: Sendable {
    func fetchLatestHRV(for dayContext: HistoricalLocalDayContext) async throws -> Double?
    func fetchSleep(for dayContext: HistoricalLocalDayContext) async throws -> SleepData?
    func fetchRestingHeartRate(for dayContext: HistoricalLocalDayContext) async throws -> Int?
    func fetchWristTemperature(for dayContext: HistoricalLocalDayContext) async throws -> Double?
    func fetchSteps(for dayContext: HistoricalLocalDayContext) async throws -> Int?
    func fetchActiveCalories(for dayContext: HistoricalLocalDayContext) async throws -> Int?
    func fetchRespiratoryRate(for dayContext: HistoricalLocalDayContext) async throws -> Double?
    func fetchBloodOxygen(for dayContext: HistoricalLocalDayContext) async throws -> Double?
    func fetchWorkouts(for dayContext: HistoricalLocalDayContext) async throws -> [HealthKitImportedWorkout]
    func dataCompleteness(
        hrv: Double?,
        sleep: SleepData?,
        rhr: Int?,
        steps: Int?,
        activeCal: Int?
    ) async -> Double
}

extension HealthKitManager: HealthSyncDataProviding {}

extension HealthSyncDataProviding {
    func fetchWorkouts(for dayContext: HistoricalLocalDayContext) async throws -> [HealthKitImportedWorkout] {
        _ = dayContext
        return []
    }
}

/// Orchestrates the daily creation of `PhysiologicalState` from HealthKit data.
/// Resolves the PRD requirement for "deterministic daily aggregation".
/// NOTE: This is an actor (not @MainActor) to avoid blocking the UI during
/// heavy HealthKit queries and RecoveryEngine computation.
actor HealthSyncManager {
    static let shared = HealthSyncManager()

    private let healthKitManager: any HealthSyncDataProviding
    private let environmentService: EnvironmentServiceProtocol
    private let dbQueue: DatabaseQueue
    private let isHealthKitAvailable: @Sendable () -> Bool
    private let syncEngineProvider: @Sendable () -> SyncEngine?
    private let timeZoneHistoryStore: TimeZoneHistoryStore
    private let nowProvider: @Sendable () -> Date

    init(
        healthKitManager: any HealthSyncDataProviding = HealthKitManager(),
        environmentService: EnvironmentServiceProtocol = EnvironmentService(),
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue,
        isHealthKitAvailable: @escaping @Sendable () -> Bool = HealthSyncManager.defaultHealthKitAvailability,
        timeZoneHistoryStore: TimeZoneHistoryStore = .shared,
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.healthKitManager = healthKitManager
        self.environmentService = environmentService
        self.dbQueue = dbQueue
        self.isHealthKitAvailable = isHealthKitAvailable
        self.syncEngineProvider = HealthSyncManager.defaultSyncEngineProvider
        self.timeZoneHistoryStore = timeZoneHistoryStore
        self.nowProvider = nowProvider
    }

    init(
        healthKitManager: any HealthSyncDataProviding,
        environmentService: EnvironmentServiceProtocol,
        dbQueue: DatabaseQueue,
        isHealthKitAvailable: @escaping @Sendable () -> Bool,
        syncEngineProvider: @escaping @Sendable () -> SyncEngine?,
        timeZoneHistoryStore: TimeZoneHistoryStore = .shared,
        nowProvider: @escaping @Sendable () -> Date
    ) {
        self.healthKitManager = healthKitManager
        self.environmentService = environmentService
        self.dbQueue = dbQueue
        self.isHealthKitAvailable = isHealthKitAvailable
        self.syncEngineProvider = syncEngineProvider
        self.timeZoneHistoryStore = timeZoneHistoryStore
        self.nowProvider = nowProvider
    }

    private static func defaultSyncEngineProvider() -> SyncEngine? {
        AppContainer.shared?.syncEngine
    }

    private static func defaultHealthKitAvailability() -> Bool {
        HealthKitManager.isAvailable
    }

    /// Generates and persists the PhysiologicalState for a target date.
    func syncDailyState(for date: Date = Date(), userId: UUID) async throws {
        if try await timeZoneHistoryStore.hasRelevantSnapshot(for: date, userId: userId) == false {
            try await timeZoneHistoryStore.captureCurrentTimeZoneIfNeeded(
                userId: userId,
                recordedAt: nowProvider()
            )
        }

        guard isHealthKitAvailable() else { return }

        let dayContext = try await timeZoneHistoryStore.resolveLocalDayContext(for: date, userId: userId)
        try await syncDailyState(for: dayContext, userId: userId)
    }

    private func syncDailyState(
        for dayContext: HistoricalLocalDayContext,
        userId: UUID
    ) async throws {
        // 1. Fetch all HealthKit components concurrently
        async let hrvTask = healthKitManager.fetchLatestHRV(for: dayContext)
        async let sleepTask = healthKitManager.fetchSleep(for: dayContext)
        async let rhrTask = healthKitManager.fetchRestingHeartRate(for: dayContext)
        async let tempTask = try? healthKitManager.fetchWristTemperature(for: dayContext)
        async let stepsTask = healthKitManager.fetchSteps(for: dayContext)
        async let activeCalTask = healthKitManager.fetchActiveCalories(for: dayContext)
        async let respRateTask = healthKitManager.fetchRespiratoryRate(for: dayContext)
        async let o2Task = healthKitManager.fetchBloodOxygen(for: dayContext)
        async let environmentTask = try? environmentService.fetchEnvironment(for: dayContext.referenceDate)

        let (hrv, sleep, rhr) = try await (hrvTask, sleepTask, rhrTask)
        let temp = await tempTask
        let steps = try? await stepsTask
        let activeCal = try? await activeCalTask
        let respRate = try? await respRateTask
        let o2 = try? await o2Task
        let environment = await environmentTask
        // P2 #13: Use pre-fetched data instead of re-querying HealthKit
        let completeness = await healthKitManager.dataCompleteness(
            hrv: hrv, sleep: sleep, rhr: rhr,
            steps: steps, activeCal: activeCal
        )

        let dateString = dayContext.dayString
        // Scores are computed from the persisted state inside its transaction,
        // using the same health flags, age and sleep history as every other caller.
        let computed = RecoveryEngine.ComputedScore(
            score: 50, zone: RecoveryZone.from(score: 50), confidence: 0, components: .init()
        )

        let existingState = try await dbQueue.read { db in
            try PhysiologicalState
                .filter(Column("user_id") == userId.uuidString && Column("date") == dateString)
                .fetchOne(db)
        }

        // 4. Construct PhysiologicalState
        let state = Self.buildState(
            dateString: dateString,
            userId: userId,
            existingState: existingState,
            computed: computed,
            completeness: completeness,
            hrv: hrv,
            sleep: sleep,
            rhr: rhr,
            temp: temp,
            steps: steps,
            activeCal: activeCal,
            respRate: respRate,
            o2: o2,
            environment: environment,
            dayContext: dayContext
        )

        // 5+6. Save to database and enqueue the sync event in ONE transaction:
        // a crash between the local write and the outbox insert would otherwise
        // leave the change stranded locally forever.
        let stateSnapshot = state
        if let syncEngine = syncEngineProvider() {
            _ = try await syncEngine.performConditionalOptimisticMutation { db -> (value: Void, event: OutboxEvent?) in
                var stateToPersist = stateSnapshot
                if existingState != nil {
                    stateToPersist.updatedAt = Date()
                    try stateToPersist.update(db)
                } else {
                    try stateToPersist.insert(db)
                }
                try Self.applyRecovery(to: &stateToPersist, sleep: sleep, db: db, enqueue: { try syncEngine.enqueueMutation($0, in: db) })
                let payload = try JSONEncoder.supabase.encode(stateToPersist)
                let event = OutboxEvent(
                    httpMethod: .POST,
                    path: "rest/v1/physiological_states",
                    bodyJson: payload,
                    priority: 90
                )
                return (value: (), event: event)
            }
        } else {
            let stateSnapshot = stateSnapshot
            _ = try await dbQueue.write { db -> Void in
                var stateToPersist = stateSnapshot
                if existingState != nil {
                    stateToPersist.updatedAt = Date()
                    try stateToPersist.update(db)
                } else {
                    try stateToPersist.insert(db)
                }
                try Self.applyRecovery(to: &stateToPersist, sleep: sleep, db: db, enqueue: { try $0.insert(db) })
                var stateEvent = OutboxEvent(httpMethod: .POST, path: "rest/v1/physiological_states", bodyJson: try JSONEncoder.supabase.encode(stateToPersist), priority: 90)
                stateEvent.headersJson = try Self.outboxHeadersJson()
                try stateEvent.insert(db)
            }
        }

        try await syncImportedWorkouts(for: dayContext, userId: userId)
        await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
    }

    /// Backfills daily state for the recent N days (inclusive of today).
    func backfillRecentData(days: Int, userId: UUID) async throws {
        guard days > 0 else { return }
        let referenceNow = nowProvider()
        try await timeZoneHistoryStore.captureCurrentTimeZoneIfNeeded(
            userId: userId,
            recordedAt: referenceNow
        )
        let contexts = try await timeZoneHistoryStore.recentLocalDayContexts(
            days: days,
            userId: userId,
            referenceNow: referenceNow
        )

        var firstError: Error?
        for context in contexts {
            do {
                try await syncDailyState(for: context, userId: userId)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if let firstError {
            throw firstError
        }

        await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
    }

    func syncImportedWorkouts(
        for date: Date = Date(),
        userId: UUID
    ) async throws {
        let dayContext = try await timeZoneHistoryStore.resolveLocalDayContext(for: date, userId: userId)
        try await syncImportedWorkouts(for: dayContext, userId: userId)
    }

    func syncImportedWorkouts(
        for dayContext: HistoricalLocalDayContext,
        userId: UUID
    ) async throws {
        guard isHealthKitAvailable() else { return }

        let workouts = try await healthKitManager.fetchWorkouts(for: dayContext)
        let activeSourceIds = Set(workouts.map(\.sourceId))
        let targetSessionDate = dayContext.dayString

        var firstError: Error?
        for workout in workouts {
            do {
                try await upsertImportedWorkout(workout, userId: userId)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        do {
            try await reconcileRemovedImportedWorkouts(
                on: targetSessionDate,
                userId: userId,
                activeSourceIds: activeSourceIds
            )
        } catch {
            if firstError == nil {
                firstError = error
            }
        }

        if let firstError {
            throw firstError
        }
    }
    
    private func upsertImportedWorkout(
        _ workout: HealthKitImportedWorkout,
        userId: UUID
    ) async throws {
        let updateTimestamp = nowProvider()

        // The session write and its outbox event must commit together: a crash
        // between them would leave an imported workout stranded locally forever.
        let persist: @Sendable (Database) throws -> WorkoutSession? = { db in
            if let existing = try WorkoutSession.fetchOne(
                db,
                sql: """
                    SELECT *
                    FROM workout_sessions
                    WHERE (user_id = ? OR user_id = ?)
                      AND import_provider = ?
                      AND import_source_id = ?
                    ORDER BY updated_at DESC
                    LIMIT 1
                    """,
                arguments: [userId, userId.uuidString, ImportProvider.healthkit.rawValue, workout.sourceId]
            ) {
                if existing.deletedAt != nil {
                    return nil
                }

                var updated = existing
                Self.applyImportedWorkout(
                    workout,
                    to: &updated,
                    userId: userId,
                    updatedAt: updateTimestamp
                )

                if Self.importedSessionHasMeaningfulChanges(existing: existing, updated: updated) {
                    try updated.update(db)
                    return updated
                }
                return nil
            }

            var inserted = WorkoutSession(
                userId: userId,
                startedAt: workout.startDate,
                sessionDate: workout.sessionDate,
                source: .import
            )
            Self.applyImportedWorkout(
                workout,
                to: &inserted,
                userId: userId,
                updatedAt: updateTimestamp
            )
            try inserted.insert(db)
            return inserted
        }

        guard let syncEngine = syncEngineProvider() else {
            try await dbQueue.write { db in
                guard let session = try persist(db) else { return }
                var event = OutboxEvent(httpMethod: .POST, path: "rest/v1/workout_sessions", bodyJson: try JSONEncoder.supabase.encode(session), priority: 95)
                event.headersJson = try Self.outboxHeadersJson()
                try event.insert(db)
            }
            return
        }

        let session: WorkoutSession? = try await syncEngine.performConditionalOptimisticMutation { db in
            let value = try persist(db)
            guard let session = value else {
                return (value: nil as WorkoutSession?, event: nil)
            }
            var event = OutboxEvent(
                httpMethod: .POST,
                path: "rest/v1/workout_sessions",
                bodyJson: try JSONEncoder.supabase.encode(session),
                priority: 95
            )
            event.headersJson = try Self.outboxHeadersJson()
            return (value: session, event: event)
        }
        _ = session
    }

    private static func applyImportedWorkout(
        _ workout: HealthKitImportedWorkout,
        to session: inout WorkoutSession,
        userId: UUID,
        updatedAt: Date
    ) {
        session.userId = userId
        session.updatedAt = updatedAt
        session.startedAt = workout.startDate
        session.endedAt = workout.endDate
        session.durationMinutes = workout.durationMinutes
        session.sessionDate = workout.sessionDate
        session.startedTimezone = workout.startedTimezone
        session.startedUtcOffsetMinutes = workout.startedUTCOffsetMinutes
        session.source = .import
        session.importProvider = .healthkit
        session.importSourceId = workout.sourceId
        session.workoutType = workout.workoutType
        session.estimatedCalories = workout.estimatedCalories
        session.trimpScore = workout.trimpScore
        session.perceivedExertionRpe = workout.inferredRPE
        session.deletedAt = nil
        session.deletedReason = nil
    }

    private static func importedSessionHasMeaningfulChanges(
        existing: WorkoutSession,
        updated: WorkoutSession
    ) -> Bool {
        existing.startedAt != updated.startedAt ||
            existing.endedAt != updated.endedAt ||
            existing.durationMinutes != updated.durationMinutes ||
            existing.sessionDate != updated.sessionDate ||
            existing.startedTimezone != updated.startedTimezone ||
            existing.startedUtcOffsetMinutes != updated.startedUtcOffsetMinutes ||
            existing.source != updated.source ||
            existing.importProvider != updated.importProvider ||
            existing.importSourceId != updated.importSourceId ||
            existing.workoutType != updated.workoutType ||
            existing.estimatedCalories != updated.estimatedCalories ||
            existing.trimpScore != updated.trimpScore ||
            existing.perceivedExertionRpe != updated.perceivedExertionRpe ||
            existing.deletedAt != updated.deletedAt ||
            existing.deletedReason != updated.deletedReason
    }

    private func reconcileRemovedImportedWorkouts(
        on sessionDate: String,
        userId: UUID,
        activeSourceIds: Set<String>
    ) async throws {
        let updateTimestamp = nowProvider()
        let removedSessions = try await dbQueue.write { db -> [WorkoutSession] in
            let candidates = try WorkoutSession.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM workout_sessions
                    WHERE (user_id = ? OR user_id = ?)
                      AND source = ?
                      AND import_provider = ?
                      AND session_date = ?
                      AND deleted_at IS NULL
                    """,
                arguments: [
                    userId,
                    userId.uuidString,
                    WorkoutSource.import.rawValue,
                    ImportProvider.healthkit.rawValue,
                    sessionDate,
                ]
            )

            var removed: [WorkoutSession] = []
            for var session in candidates {
                guard let importSourceId = session.importSourceId,
                      activeSourceIds.contains(importSourceId) else {
                    session.updatedAt = updateTimestamp
                    session.deletedAt = updateTimestamp
                    session.deletedReason = nil
                    try session.update(db)
                    removed.append(session)
                    continue
                }
            }

            return removed
        }

        guard !removedSessions.isEmpty else { return }

        for session in removedSessions {
            let event: OutboxEvent = try {
                var event = OutboxEvent(
                    httpMethod: .POST,
                    path: "rest/v1/workout_sessions",
                    bodyJson: try JSONEncoder.supabase.encode(session),
                    priority: 95
                )
                event.headersJson = try Self.outboxHeadersJson()
                return event
            }()
            try await dbQueue.write { db in
                try event.insert(db)
            }
        }
    }

    nonisolated private static func outboxHeadersJson() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
    }

    private static func applyRecovery(to state: inout PhysiologicalState, sleep: SleepData?, db: Database, enqueue: ((OutboxEvent) throws -> Void)? = nil) throws {
        if let sleep {
            let existing = try SleepRecordSelection.daily(userId: state.userId, day: state.date, includeDeleted: true, db: db)
            // Respect an explicit local deletion; a later HealthKit pull must not resurrect it.
            if existing?.deletedAt == nil && existing?.overridesImportedSleep != true {
                var log = existing ?? SleepLog(userId: state.userId, date: state.date)
                log.source = .healthkit
                log.date = state.date
                log.sleepDate = state.date
                let sample = sleep.scoringLog
                log.totalDurationMinutes = sample.totalDurationMinutes
                log.deepSleepMinutes = sample.deepSleepMinutes
                log.remSleepMinutes = sample.remSleepMinutes
                log.lightSleepMinutes = sample.lightSleepMinutes
                log.awakeMinutes = sample.awakeMinutes
                log.sleepEfficiency = sample.sleepEfficiency
                log.bedTime = sample.bedTime
                log.wakeTime = sample.wakeTime
                log.sleepTimezone = state.localTimezone
                log.sleepUtcOffsetMinutes = state.localUtcOffsetMinutes
                log.updatedAt = state.updatedAt
                try log.save(db)
                try SleepRecordSelection.supersedeOtherRecords(with: log, db: db)
                if let enqueue {
                    try enqueue(SleepRecordSelection.outboxEvent(for: log))
                }
            }
        }
        // The visible values and the score must use the same selected record.
        // A manual correction takes precedence over a later wearable refresh.
        let selected = try SleepRecordSelection.daily(userId: state.userId, day: state.date, db: db)
        if let selected { try SleepRecordSelection.supersedeOtherRecords(with: selected, db: db) }
        SleepRecordSelection.applySleepFields(selected, to: &state)
        try state.update(db)
        let score = try RecoveryEngine.computeScore(userId: state.userId, date: state.date, db: db)
        state.recoveryScore = score.score
        state.recoveryZone = RecoveryZone.from(score: score.score)
        state.confidenceScore = score.confidence
        state.hrvScore = score.components.hrvScore
        state.sleepScore = score.components.sleepScore
        state.sleepQualityPercent = score.components.sleepScore
        state.rhrScore = score.components.rhrScore
        state.tempScore = score.components.tempScore
        try state.update(db)
    }

    private static func buildState(
        dateString: String,
        userId: UUID,
        existingState: PhysiologicalState?,
        computed: RecoveryEngine.ComputedScore,
        completeness: Double,
        hrv: Double?,
        sleep: SleepData?,
        rhr: Int?,
        temp: Double?,
        steps: Int?,
        activeCal: Int?,
        respRate: Double?,
        o2: Double?,
        environment: EnvironmentalContext?,
        dayContext: HistoricalLocalDayContext? = nil
    ) -> PhysiologicalState {
        var state = PhysiologicalState(
            id: existingState?.id ?? UUID(),
            userId: userId,
            date: dateString,
            recoveryScore: computed.score
        )
        if let existingState {
            state.createdAt = existingState.createdAt
        }

        state.recoveryZone = computed.zone
        state.confidenceScore = computed.confidence
        state.dataCompleteness = completeness

        state.hrvLnRmssd = hrv
        state.hrvScore = computed.components.hrvScore
        state.restingHeartRateBpm = rhr
        state.rhrScore = computed.components.rhrScore

        state.wristTemperatureDeviationC = temp
        state.tempScore = computed.components.tempScore

        state.sleepDurationHours = sleep?.totalHours
        state.sleepQualityPercent = sleep?.qualityScore
        state.sleepScore = computed.components.sleepScore
        state.deepSleepPercent = Self.safePercentage(sleep?.hasStages == true ? sleep?.deepMinutes : nil, total: sleep?.totalHours)
        state.remSleepPercent = Self.safePercentage(sleep?.hasStages == true ? sleep?.remMinutes : nil, total: sleep?.totalHours)
        state.lightSleepPercent = Self.safePercentage(sleep?.hasStages == true ? sleep?.lightMinutes : nil, total: sleep?.totalHours)
        state.awakePercent = Self.safePercentage(sleep?.awakeMinutes, total: sleep?.totalHours)

        state.steps = steps ?? nil
        state.activeCalories = activeCal ?? nil

        state.respiratoryRateBpm = respRate
        state.bloodOxygenPercent = o2
        state.environmentalContext = environment ?? existingState?.environmentalContext
        state.localTimezone = dayContext?.timeZoneIdentifier ?? existingState?.localTimezone
        state.localUtcOffsetMinutes = dayContext?.utcOffsetMinutes ?? existingState?.localUtcOffsetMinutes
        return state
    }
    
    private static func safePercentage(_ minutes: Int?, total hours: Double?) -> Double? {
        guard let minutes = minutes, let hours = hours, hours > 0 else { return nil }
        let totalMinutes = hours * 60.0
        return (Double(minutes) / totalMinutes) * 100.0
    }
}

#if DEBUG
extension HealthSyncManager {
    nonisolated static func _testDefaultSyncEngineProvider() -> SyncEngine? {
        defaultSyncEngineProvider()
    }

    nonisolated static func _testDefaultHealthKitAvailability() -> Bool {
        defaultHealthKitAvailability()
    }

    nonisolated static func _testDateString(from date: Date) -> String {
        HistoricalLocalDayContext.dayString(for: date, timeZone: .current)
    }

    nonisolated static func _testSafePercentage(_ minutes: Int?, total hours: Double?) -> Double? {
        safePercentage(minutes, total: hours)
    }

    nonisolated static func _testBuildState(
        dateString: String,
        userId: UUID,
        existingState: PhysiologicalState?,
        computed: RecoveryEngine.ComputedScore,
        completeness: Double,
        hrv: Double?,
        sleep: SleepData?,
        rhr: Int?,
        temp: Double?,
        steps: Int?,
        activeCal: Int?,
        respRate: Double?,
        o2: Double?,
        environment: EnvironmentalContext?,
        dayContext: HistoricalLocalDayContext? = nil
    ) -> PhysiologicalState {
        buildState(
            dateString: dateString,
            userId: userId,
            existingState: existingState,
            computed: computed,
            completeness: completeness,
            hrv: hrv,
            sleep: sleep,
            rhr: rhr,
            temp: temp,
            steps: steps,
            activeCal: activeCal,
            respRate: respRate,
            o2: o2,
            environment: environment,
            dayContext: dayContext
        )
    }
}
#endif
