import Foundation
import GRDB
import XCTest
@testable import LifeOS

private enum HealthSyncTestError: Error, Equatable, Sendable {
    case hrv(String)
    case environment
}

private actor HealthSyncDataProviderStub: HealthSyncDataProviding {
    struct Config: Sendable {
        var hrv: Double?
        var sleep: SleepData?
        var rhr: Int?
        var temperature: Double?
        var steps: Int?
        var activeCalories: Int?
        var respiratoryRate: Double?
        var bloodOxygen: Double?
        var completenessOverride: Double?
        var failingHRVDateKeys: Set<String> = []
        var throwOnSteps = false
        var throwOnActiveCalories = false
        var workouts: [HealthKitImportedWorkout] = []
    }

    private let config: Config
    private var hrvRequestedDateKeys: [String] = []

    init(config: Config) {
        self.config = config
    }

    func fetchWorkouts(for dayContext: HistoricalLocalDayContext) async throws -> [HealthKitImportedWorkout] { config.workouts }

    func fetchLatestHRV(for dayContext: HistoricalLocalDayContext) async throws -> Double? {
        let key = dayContext.dayString
        hrvRequestedDateKeys.append(key)
        if config.failingHRVDateKeys.contains(key) {
            throw HealthSyncTestError.hrv(key)
        }
        return config.hrv
    }

    func fetchSleep(for dayContext: HistoricalLocalDayContext) async throws -> SleepData? {
        _ = dayContext
        return config.sleep
    }

    func fetchRestingHeartRate(for dayContext: HistoricalLocalDayContext) async throws -> Int? {
        _ = dayContext
        return config.rhr
    }

    func fetchWristTemperature(for dayContext: HistoricalLocalDayContext) async throws -> Double? {
        _ = dayContext
        return config.temperature
    }

    func fetchSteps(for dayContext: HistoricalLocalDayContext) async throws -> Int? {
        _ = dayContext
        if config.throwOnSteps {
            throw HealthSyncTestError.hrv("steps")
        }
        return config.steps
    }

    func fetchActiveCalories(for dayContext: HistoricalLocalDayContext) async throws -> Int? {
        _ = dayContext
        if config.throwOnActiveCalories {
            throw HealthSyncTestError.hrv("active_calories")
        }
        return config.activeCalories
    }

    func fetchRespiratoryRate(for dayContext: HistoricalLocalDayContext) async throws -> Double? {
        _ = dayContext
        return config.respiratoryRate
    }

    func fetchBloodOxygen(for dayContext: HistoricalLocalDayContext) async throws -> Double? {
        _ = dayContext
        return config.bloodOxygen
    }

    func dataCompleteness(
        hrv: Double?,
        sleep: SleepData?,
        rhr: Int?,
        steps: Int?,
        activeCal: Int?
    ) async -> Double {
        if let override = config.completenessOverride {
            return override
        }

        var score = 0.0
        if hrv != nil { score += 0.35 }
        if sleep != nil { score += 0.35 }
        if rhr != nil { score += 0.20 }
        if (steps ?? 0) > 0 || (activeCal ?? 0) > 0 { score += 0.10 }
        return score
    }

    func observedHRVDateKeys() -> [String] {
        hrvRequestedDateKeys
    }
}

private actor EnvironmentServiceStub: EnvironmentServiceProtocol {
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private let result: Result<EnvironmentalContext, Error>
    private let datedResults: [String: Result<EnvironmentalContext, Error>]
    private var requestedDateKeys: [String] = []

    init(
        result: Result<EnvironmentalContext, Error>,
        datedResults: [String: Result<EnvironmentalContext, Error>] = [:]
    ) {
        self.result = result
        self.datedResults = datedResults
    }

    func fetchCurrentEnvironment() async throws -> EnvironmentalContext {
        try result.get()
    }

    func fetchEnvironment(for date: Date) async throws -> EnvironmentalContext {
        let key = Self.dayFormatter.string(from: date)
        requestedDateKeys.append(key)
        if let datedResult = datedResults[key] {
            return try datedResult.get()
        }
        return try result.get()
    }

    func observedRequestedDateKeys() -> [String] {
        requestedDateKeys
    }
}

final class HealthSyncManagerFlowIntegrationTests: XCTestCase {
    private static func sleepDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid date"))
        }
        return decoder
    }

    func testLiveImportHonorsDisabledHRVAndMatchesDatabaseScoring() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        let target = dateFrom(day: "2026-03-08")
        try await manager.dbQueue.write { db in
            try user.insert(db)
            try Self.seedBaselineRows(userId: user.id, db: db)
            var flags = UserHealthFlags(userId: user.id)
            flags.hasCardiacCondition = true
            try flags.insert(db)
        }
        let sleep = SleepData(totalHours: 8, deepMinutes: 0, remMinutes: 0, lightMinutes: 480, awakeMinutes: 0, efficiency: nil, bedTime: nil, wakeTime: nil, hasStages: false)
        let engine = SyncEngine(dbQueue: manager.dbQueue)
        let sync = HealthSyncManager(
            healthKitManager: HealthSyncDataProviderStub(config: .init(hrv: 4.8, sleep: sleep, rhr: 55)),
            environmentService: EnvironmentServiceStub(result: .failure(HealthSyncTestError.environment)),
            dbQueue: manager.dbQueue, isHealthKitAvailable: { true }, syncEngineProvider: { engine },
            timeZoneHistoryStore: TimeZoneHistoryStore(dbQueue: manager.dbQueue), nowProvider: { target }
        )
        try await sync.syncDailyState(for: target, userId: user.id)
        try await manager.dbQueue.read { db in
            let state = try XCTUnwrap(PhysiologicalState.filter(Column("user_id") == user.id.uuidString && Column("date") == "2026-03-08").fetchOne(db))
            let recomputed = try RecoveryEngine.computeScore(userId: user.id, date: state.date, db: db)
            XCTAssertNil(state.hrvScore)
            XCTAssertNil(state.deepSleepPercent)
            XCTAssertNil(state.remSleepPercent)
            XCTAssertEqual(state.recoveryScore, recomputed.score, accuracy: 0.0001)
            XCTAssertEqual(state.sleepScore, recomputed.components.sleepScore)
            XCTAssertEqual(try SleepLog.filter((Column("user_id") == user.id || Column("user_id") == user.id.uuidString) && Column("date") == state.date).fetchCount(db), 1)
            XCTAssertEqual(try OutboxEvent.fetchCount(db), 2)
        }
    }

    @MainActor
    func testManualSleepValidatesIntervalAndPersistsScoreWithOutboxAtomically() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        try await manager.dbQueue.write { db in try user.insert(db) }
        AuthManager.setActiveAuthIdForTests(user.authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }
        let wake = try XCTUnwrap(DiaryDateFormatter.parseDate("2026-03-08")).addingTimeInterval(8 * 3600)
        let model = SleepDayViewModel(dateString: "2026-03-08", dbQueue: manager.dbQueue, syncEngine: SyncEngine(dbQueue: manager.dbQueue))
        do {
            try await model.saveManualSleep(bedTime: wake, wakeTime: wake)
            XCTFail("Zero duration must fail")
        } catch { }
        try await model.saveManualSleep(bedTime: wake.addingTimeInterval(-8 * 3600), wakeTime: wake)
        try await manager.dbQueue.read { db in
            let log = try XCTUnwrap(SleepLog.fetchOne(db))
            XCTAssertEqual(log.source, .manual)
            XCTAssertEqual(log.totalDurationMinutes, 480)
            XCTAssertNil(log.deepSleepMinutes)
            XCTAssertEqual(try PhysiologicalState.fetchCount(db), 1)
            XCTAssertEqual(try OutboxEvent.fetchCount(db), 2)
        }
    }

    @MainActor
    func testHealthKitManualHealthKitRetainsOneIdentityAndManualMetricsWithoutEngine() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        try await manager.dbQueue.write { db in try user.insert(db) }
        AuthManager.setActiveAuthIdForTests(user.authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }
        let wake = try XCTUnwrap(DiaryDateFormatter.parseDate("2026-03-08")).addingTimeInterval(8 * 3600)
        let sample = SleepData(totalHours: 6, deepMinutes: 60, remMinutes: 60, lightMinutes: 240, awakeMinutes: 0, efficiency: 90, bedTime: wake.addingTimeInterval(-6 * 3600), wakeTime: wake)
        let sync = HealthSyncManager(
            healthKitManager: HealthSyncDataProviderStub(config: .init(sleep: sample)),
            environmentService: EnvironmentServiceStub(result: .failure(HealthSyncTestError.environment)),
            dbQueue: manager.dbQueue, isHealthKitAvailable: { true }, syncEngineProvider: { nil },
            timeZoneHistoryStore: TimeZoneHistoryStore(dbQueue: manager.dbQueue), nowProvider: { wake }
        )
        try await sync.syncDailyState(for: wake, userId: user.id)
        let firstID = try await manager.dbQueue.read { db in try XCTUnwrap(SleepLog.fetchOne(db)).id }
        let model = SleepDayViewModel(dateString: "2026-03-08", dbQueue: manager.dbQueue, syncEngine: nil)
        try await model.saveManualSleep(bedTime: wake.addingTimeInterval(-8 * 3600), wakeTime: wake)
        try await sync.syncDailyState(for: wake, userId: user.id)
        try await manager.dbQueue.read { db in
            let logs = try SleepLog.filter(Column("deleted_at") == nil).fetchAll(db)
            XCTAssertEqual(logs.count, 1)
            let log = try XCTUnwrap(logs.first)
            XCTAssertEqual(log.id, firstID)
            XCTAssertEqual(log.source, .manual)
            XCTAssertEqual(log.totalDurationMinutes, 480)
            XCTAssertNil(log.deepSleepMinutes)
            let state = try XCTUnwrap(PhysiologicalState.fetchOne(db))
            XCTAssertEqual(state.sleepDurationHours, 8)
            XCTAssertNil(state.deepSleepPercent)
            XCTAssertNil(state.remSleepPercent)
            let score = try RecoveryEngine.computeScore(userId: user.id, date: log.date, db: db)
            XCTAssertEqual(state.recoveryScore, score.score, accuracy: 0.0001)
            let sleepEvents = try OutboxEvent.filter(Column("path") == "api-sleep-log").fetchAll(db)
            XCTAssertEqual(sleepEvents.count, 2)
            XCTAssertEqual(try OutboxEvent.fetchCount(db), 5)
            XCTAssertTrue(try sleepEvents.contains { try Self.sleepDecoder().decode(SleepLog.self, from: $0.bodyJson).source == .manual })
        }
    }

    @MainActor
    func testManualSleepAndStateRollbackWhenOutboxInsertFails() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        try await manager.dbQueue.write { db in
            try user.insert(db)
            try db.execute(sql: "CREATE TRIGGER fail_sleep_outbox BEFORE INSERT ON outbox_events WHEN NEW.path = 'api-sleep-log' BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        }
        AuthManager.setActiveAuthIdForTests(user.authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }
        let wake = try XCTUnwrap(DiaryDateFormatter.parseDate("2026-03-08")).addingTimeInterval(8 * 3600)
        let model = SleepDayViewModel(dateString: "2026-03-08", dbQueue: manager.dbQueue, syncEngine: nil)
        do {
            try await model.saveManualSleep(bedTime: wake.addingTimeInterval(-8 * 3600), wakeTime: wake)
            XCTFail("Outbox failure must fail the complete mutation")
        } catch { }
        try await manager.dbQueue.read { db in
            XCTAssertEqual(try SleepLog.fetchCount(db), 0)
            XCTAssertEqual(try PhysiologicalState.fetchCount(db), 0)
            XCTAssertEqual(try OutboxEvent.fetchCount(db), 0)
        }
    }

    func testSleepHistoryUsesDistinctDaysAndManualPrecedenceForLegacyUUIDRepresentations() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        try await manager.dbQueue.write { db in
            try user.insert(db)
            for day in ["2026-03-06", "2026-03-07"] {
                var manual = SleepLog(userId: user.id, date: day, source: .manual)
                manual.totalDurationMinutes = 480
                manual.updatedAt = Date(timeIntervalSince1970: 1000)
                try manual.insert(db)
                var imported = SleepLog(userId: user.id, date: day)
                imported.totalDurationMinutes = 360
                imported.updatedAt = Date(timeIntervalSince1970: 2000)
                try imported.insert(db)
                // Exercise text IDs in addition to GRDB's historical UUID blobs.
                try db.execute(sql: "UPDATE sleep_logs SET user_id = ? WHERE id = ?", arguments: [user.id.uuidString, imported.id])
            }
            let recent = try SleepRecordSelection.recent(userId: user.id, before: "2026-03-08", limit: 7, db: db)
            XCTAssertEqual(recent.count, 2)
            XCTAssertTrue(recent.allSatisfy { $0.source == .manual && $0.totalDurationMinutes == 480 })
            try SleepSyncHandler.reconcileParentChild(in: db)
            XCTAssertEqual(try SleepLog.filter(Column("deleted_at") == nil).fetchCount(db), 2)
        }
    }

    func testLegacySubjectiveSleepCanBeEnrichedWhileManualTombstoneCannot() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        let target = dateFrom(day: "2026-03-08")
        var legacy = SleepLog(userId: user.id, date: "2026-03-08", source: .manual)
        legacy.notes = "Subjective diary retained"
        legacy.perceivedQuality = 4
        let original = legacy
        try await manager.dbQueue.write { db in
            try user.insert(db)
            try original.insert(db)
            var state = PhysiologicalState(userId: user.id, date: original.date, recoveryScore: 50)
            state.sleepDurationHours = 7
            try state.insert(db)
            try SleepSyncHandler.reconcileParentChild(in: db)
            XCTAssertEqual(try PhysiologicalState.fetchOne(db)?.sleepDurationHours, 7)
        }
        let sample = SleepData(totalHours: 8, deepMinutes: 60, remMinutes: 60, lightMinutes: 360, awakeMinutes: 0, efficiency: 90, bedTime: target.addingTimeInterval(-8 * 3600), wakeTime: target)
        let sync = HealthSyncManager(
            healthKitManager: HealthSyncDataProviderStub(config: .init(sleep: sample)),
            environmentService: EnvironmentServiceStub(result: .failure(HealthSyncTestError.environment)),
            dbQueue: manager.dbQueue, isHealthKitAvailable: { true }, syncEngineProvider: { nil },
            timeZoneHistoryStore: TimeZoneHistoryStore(dbQueue: manager.dbQueue), nowProvider: { target }
        )
        try await sync.syncDailyState(for: target, userId: user.id)
        try await manager.dbQueue.write { db in
            var log = try XCTUnwrap(SleepRecordSelection.daily(userId: user.id, day: original.date, db: db))
            XCTAssertEqual(log.id, original.id)
            XCTAssertEqual(log.source, .healthkit)
            XCTAssertEqual(log.totalDurationMinutes, 480)
            XCTAssertEqual(log.perceivedQuality, 4)
            XCTAssertEqual(log.notes, original.notes)
            log.source = .manual
            log.totalDurationMinutes = nil
            log.deletedAt = Date()
            try log.update(db)
        }
        try await sync.syncDailyState(for: target, userId: user.id)
        try await manager.dbQueue.read { db in
            let deleted = try XCTUnwrap(SleepRecordSelection.daily(userId: user.id, day: original.date, includeDeleted: true, db: db))
            XCTAssertNotNil(deleted.deletedAt)
            XCTAssertNil(deleted.totalDurationMinutes)
            XCTAssertNil(try PhysiologicalState.fetchOne(db)?.sleepDurationHours)
        }
    }

    func testSleepPullDecodesLegacyServerDiaryAlongsideObjectiveFields() throws {
        let object: [String: Any] = [
            "id": UUID().uuidString, "user_id": UUID().uuidString,
            "sleep_date": "2026-03-08", "created_at": "2026-03-08T08:00:00Z", "updated_at": "2026-03-08T08:00:00Z",
            "source": "manual", "total_duration_minutes": 480, "bedtime_actual": "23:00:00", "waketime": "07:00:00",
            "sleep_timezone": "UTC", "alcohol": true, "room_temperature": "comfortable", "room_darkness": "dark", "noise_level": "silent"
        ]
        let log = try Self.sleepDecoder().decode(SleepLog.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(log.totalDurationMinutes, 480)
        XCTAssertEqual(log.source, .manual)
        XCTAssertEqual(try XCTUnwrap(log.waketime).timeIntervalSince(try XCTUnwrap(log.bedtimeActual)), 8 * 3600, accuracy: 0.01)
        XCTAssertNil(log.roomTemperature, "Qualitative labels must not fabricate measured temperature")
        XCTAssertEqual(log.alcohol, 1)
        var corrected = log
        corrected.bedTime = try XCTUnwrap(log.bedtimeActual).addingTimeInterval(3600)
        let snapshot = SleepDetailSnapshot(day: log.date, displayDate: log.date, age: 30, baselineSleepHours: nil, sleepLog: corrected, state: nil, score: nil, confidenceScore: nil, trendPoints: [], factors: [], tryTonightItems: [], stageFeedback: nil)
        XCTAssertEqual(snapshot.bedtime, corrected.bedTime, "Canonical bedtime must override stale legacy TIME after cloud pull")
    }

    func testImportedWorkoutWithoutEngineIsQueuedOnce() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        try await manager.dbQueue.write { db in try user.insert(db) }
        let date = dateFrom(day: "2026-03-08")
        let workout = HealthKitImportedWorkout(sourceId: "hk-regression", startDate: date, endDate: date.addingTimeInterval(1800), sessionDate: "2026-03-08", workoutType: .cardio, estimatedCalories: 200, durationMinutes: 30, startedTimezone: "UTC", startedUTCOffsetMinutes: 0, trimpScore: 40, inferredRPE: 5, sourceRank: 1)
        let sync = HealthSyncManager(
            healthKitManager: HealthSyncDataProviderStub(config: .init(workouts: [workout])),
            environmentService: EnvironmentServiceStub(result: .failure(HealthSyncTestError.environment)),
            dbQueue: manager.dbQueue, isHealthKitAvailable: { true }, syncEngineProvider: { nil },
            timeZoneHistoryStore: TimeZoneHistoryStore(dbQueue: manager.dbQueue), nowProvider: { date }
        )
        try await sync.syncImportedWorkouts(for: date, userId: user.id)
        try await sync.syncImportedWorkouts(for: date, userId: user.id)
        try await manager.dbQueue.read { db in
            XCTAssertEqual(try WorkoutSession.fetchCount(db), 1)
            XCTAssertEqual(try OutboxEvent.fetchCount(db), 1)
        }
    }

    func testSyncDailyStateInsertsThenUpdatesAndEnqueuesOutbox() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        let targetDate = dateFrom(day: "2026-03-08")

        try await manager.dbQueue.write { db in
            try user.insert(db)
            try Self.seedBaselineRows(userId: user.id, db: db)
        }

        let firstStub = HealthSyncDataProviderStub(
            config: .init(
                hrv: 4.8,
                sleep: SleepData(
                    totalHours: 8.0,
                    deepMinutes: 96,
                    remMinutes: 96,
                    lightMinutes: 258,
                    awakeMinutes: 30,
                    efficiency: 90,
                    bedTime: targetDate.addingTimeInterval(-8 * 3600),
                    wakeTime: targetDate
                ),
                rhr: 52,
                temperature: 0.2,
                steps: 9100,
                activeCalories: 620,
                respiratoryRate: 14.6,
                bloodOxygen: 98.2,
                completenessOverride: 0.97
            )
        )
        let firstEnvironment = EnvironmentServiceStub(
            result: .success(
                EnvironmentalContext(
                    weatherCondition: "Clear",
                    temperatureC: 23,
                    pressureHpa: 1010,
                    pressureDeltaHpa24h: -2,
                    aqi: 34,
                    indoorCo2Ppm: 650,
                    moonPhase: "Full Moon",
                    daylightHours: 11,
                    city: "Baku"
                )
            )
        )
        let syncEngine = SyncEngine(dbQueue: manager.dbQueue)
        let timeZoneHistoryStore = TimeZoneHistoryStore(dbQueue: manager.dbQueue)
        let firstSync = HealthSyncManager(
            healthKitManager: firstStub,
            environmentService: firstEnvironment,
            dbQueue: manager.dbQueue,
            isHealthKitAvailable: { true },
            syncEngineProvider: { syncEngine },
            timeZoneHistoryStore: timeZoneHistoryStore,
            nowProvider: Date.init
        )

        try await firstSync.syncDailyState(for: targetDate, userId: user.id)

        let inserted = try await fetchState(for: "2026-03-08", userId: user.id, dbQueue: manager.dbQueue)
        XCTAssertEqual(try XCTUnwrap(inserted.hrvMs), 4.8, accuracy: 0.0001)
        XCTAssertEqual(inserted.restingHeartRateBpm, 52)
        XCTAssertEqual(try XCTUnwrap(inserted.sleepDurationHours), 8.0, accuracy: 0.0001)
        XCTAssertEqual(inserted.steps, 9100)
        XCTAssertEqual(inserted.activeCalories, 620)
        XCTAssertEqual(inserted.environmentalContext?.city, "Baku")
        XCTAssertEqual(try XCTUnwrap(inserted.dataCompleteness), 0.97, accuracy: 0.0001)

        let outboxCountAfterInsert = try await manager.dbQueue.read { db in
            try OutboxEvent.fetchCount(db)
        }
        XCTAssertEqual(outboxCountAfterInsert, 2) // state and imported sleep commit together

        let updateStub = HealthSyncDataProviderStub(
            config: .init(
                hrv: 4.1,
                sleep: nil,
                rhr: 60,
                temperature: 0.5,
                steps: nil,
                activeCalories: nil,
                respiratoryRate: 16.2,
                bloodOxygen: 96.9,
                completenessOverride: 0.55,
                throwOnSteps: true,
                throwOnActiveCalories: true
            )
        )
        let updateEnvironment = EnvironmentServiceStub(result: .failure(HealthSyncTestError.environment))
        let updateSync = HealthSyncManager(
            healthKitManager: updateStub,
            environmentService: updateEnvironment,
            dbQueue: manager.dbQueue,
            isHealthKitAvailable: { true },
            syncEngineProvider: { syncEngine },
            timeZoneHistoryStore: timeZoneHistoryStore,
            nowProvider: Date.init
        )

        try await updateSync.syncDailyState(for: targetDate, userId: user.id)

        let updated = try await fetchState(for: "2026-03-08", userId: user.id, dbQueue: manager.dbQueue)
        XCTAssertEqual(updated.id, inserted.id)
        XCTAssertGreaterThanOrEqual(updated.updatedAt, inserted.updatedAt)
        XCTAssertEqual(try XCTUnwrap(updated.hrvMs), 4.1, accuracy: 0.0001)
        XCTAssertEqual(updated.restingHeartRateBpm, 60)
        XCTAssertEqual(updated.sleepDurationHours, 8.0) // retain the saved sleep record when a query has no new data
        XCTAssertNil(updated.steps)
        XCTAssertNil(updated.activeCalories)
        XCTAssertEqual(updated.environmentalContext?.city, "Baku")
        XCTAssertEqual(try XCTUnwrap(updated.dataCompleteness), 0.55, accuracy: 0.0001)

        let outboxCountAfterUpdate = try await manager.dbQueue.read { db in
            try OutboxEvent.fetchCount(db)
        }
        XCTAssertEqual(outboxCountAfterUpdate, 3)
    }

    func testSyncDailyStateExitsWhenHealthKitUnavailable() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        try await manager.dbQueue.write { db in
            try user.insert(db)
        }

        let provider = HealthSyncDataProviderStub(
            config: .init(
                hrv: 4.2,
                sleep: nil,
                rhr: 55,
                temperature: nil,
                steps: 5000,
                activeCalories: 300,
                respiratoryRate: 15.0,
                bloodOxygen: 98.0,
                completenessOverride: 0.65
            )
        )
        let timeZoneHistoryStore = TimeZoneHistoryStore(dbQueue: manager.dbQueue)
        let healthSync = HealthSyncManager(
            healthKitManager: provider,
            environmentService: EnvironmentServiceStub(result: .failure(HealthSyncTestError.environment)),
            dbQueue: manager.dbQueue,
            isHealthKitAvailable: { false },
            syncEngineProvider: { nil },
            timeZoneHistoryStore: timeZoneHistoryStore,
            nowProvider: Date.init
        )

        try await healthSync.syncDailyState(for: dateFrom(day: "2026-03-08"), userId: user.id)

        let dateKeys = await provider.observedHRVDateKeys()
        XCTAssertTrue(dateKeys.isEmpty)

        let stateCount = try await manager.dbQueue.read { db in
            try PhysiologicalState.fetchCount(db)
        }
        XCTAssertEqual(stateCount, 0)
    }

    func testBackfillContinuesAfterFailuresAndThrowsFirstError() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        try await manager.dbQueue.write { db in
            try user.insert(db)
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        let oldest = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))
        let middle = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let newest = today

        let oldestKey = dateString(oldest)
        let middleKey = dateString(middle)
        let newestKey = dateString(newest)

        let provider = HealthSyncDataProviderStub(
            config: .init(
                hrv: 4.4,
                sleep: SleepData(
                    totalHours: 7.5,
                    deepMinutes: 80,
                    remMinutes: 90,
                    lightMinutes: 280,
                    awakeMinutes: 25,
                    efficiency: 87,
                    bedTime: nil,
                    wakeTime: nil
                ),
                rhr: 54,
                temperature: 0.1,
                steps: 7000,
                activeCalories: 500,
                respiratoryRate: 14.0,
                bloodOxygen: 97.5,
                completenessOverride: 0.9,
                failingHRVDateKeys: [oldestKey, newestKey]
            )
        )
        let timeZoneHistoryStore = TimeZoneHistoryStore(dbQueue: manager.dbQueue)

        let healthSync = HealthSyncManager(
            healthKitManager: provider,
            environmentService: EnvironmentServiceStub(result: .failure(HealthSyncTestError.environment)),
            dbQueue: manager.dbQueue,
            isHealthKitAvailable: { true },
            syncEngineProvider: { nil },
            timeZoneHistoryStore: timeZoneHistoryStore,
            nowProvider: Date.init
        )

        do {
            try await healthSync.backfillRecentData(days: 3, userId: user.id)
            XCTFail("Expected first backfill error")
        } catch let error as HealthSyncTestError {
            XCTAssertEqual(error, .hrv(oldestKey))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        let dateKeys = await provider.observedHRVDateKeys()
        XCTAssertTrue(dateKeys.contains(oldestKey))
        XCTAssertTrue(dateKeys.contains(middleKey))
        XCTAssertTrue(dateKeys.contains(newestKey))
        XCTAssertEqual(dateKeys.count, 3)

        let insertedDates = try await manager.dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT date FROM physiological_states WHERE user_id = ? ORDER BY date",
                arguments: [user.id.uuidString]
            )
        }
        XCTAssertEqual(insertedDates, [middleKey])
    }

    func testBackfillRequestsEnvironmentForHistoricalDatesAndPersistsMatchingContext() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        try await manager.dbQueue.write { db in
            try user.insert(db)
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        let oldest = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))
        let middle = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let newest = today

        let oldestKey = dateString(oldest)
        let middleKey = dateString(middle)
        let newestKey = dateString(newest)

        let provider = HealthSyncDataProviderStub(
            config: .init(
                hrv: 4.4,
                sleep: SleepData(
                    totalHours: 7.5,
                    deepMinutes: 80,
                    remMinutes: 90,
                    lightMinutes: 280,
                    awakeMinutes: 25,
                    efficiency: 87,
                    bedTime: nil,
                    wakeTime: nil
                ),
                rhr: 54,
                temperature: 0.1,
                steps: 7000,
                activeCalories: 500,
                respiratoryRate: 14.0,
                bloodOxygen: 97.5,
                completenessOverride: 0.9
            )
        )

        let environment = EnvironmentServiceStub(
            result: .failure(HealthSyncTestError.environment),
            datedResults: [
                oldestKey: .success(environmentContext(for: oldestKey)),
                middleKey: .success(environmentContext(for: middleKey)),
                newestKey: .success(environmentContext(for: newestKey))
            ]
        )
        let timeZoneHistoryStore = TimeZoneHistoryStore(dbQueue: manager.dbQueue)

        let healthSync = HealthSyncManager(
            healthKitManager: provider,
            environmentService: environment,
            dbQueue: manager.dbQueue,
            isHealthKitAvailable: { true },
            syncEngineProvider: { nil },
            timeZoneHistoryStore: timeZoneHistoryStore,
            nowProvider: { today }
        )

        try await healthSync.backfillRecentData(days: 3, userId: user.id)

        let requestedEnvironmentDates = await environment.observedRequestedDateKeys()
        XCTAssertEqual(requestedEnvironmentDates, [oldestKey, middleKey, newestKey])

        let persistedContexts = try await manager.dbQueue.read { db in
            let decoder = JSONDecoder()
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT date, environmental_context
                    FROM physiological_states
                    WHERE user_id = ?
                    ORDER BY date
                    """,
                arguments: [user.id.uuidString]
            ).map { row -> (String, EnvironmentalContext?) in
                let date: String = row["date"]
                let contextData: Data? = row["environmental_context"]
                let context = try contextData.map { try decoder.decode(EnvironmentalContext.self, from: $0) }
                return (date, context)
            }
        }

        XCTAssertEqual(persistedContexts.map { $0.0 }, [oldestKey, middleKey, newestKey])
        XCTAssertEqual(persistedContexts.map { $0.1?.city }, [oldestKey, middleKey, newestKey])
        XCTAssertEqual(
            persistedContexts.map { $0.1?.moonPhase },
            ["phase-\(oldestKey)", "phase-\(middleKey)", "phase-\(newestKey)"]
        )
    }

    func testSyncDailyStatePersistsHistoricalLocalTimezoneMetadata() async throws {
        let manager = try DatabaseManager.inMemory()
        var configuredUser = User(authId: UUID())
        configuredUser.timezone = "UTC"
        let user = configuredUser
        let targetDate = dateFrom(day: "2026-03-08")
        let snapshotDate = zonedDate(day: "2026-03-08", hour: 10, timeZoneIdentifier: "Asia/Tokyo")

        try await manager.dbQueue.write { db in
            try user.insert(db)
            try Self.seedBaselineRows(userId: user.id, db: db)

            var snapshot = TimeZoneHistoryEntry(
                userId: user.id,
                recordedAt: snapshotDate,
                timeZoneIdentifier: "Asia/Tokyo",
                utcOffsetMinutes: 540,
                createdAt: snapshotDate,
                updatedAt: snapshotDate
            )
            try snapshot.insert(db)
        }

        let timeZoneHistoryStore = TimeZoneHistoryStore(
            dbQueue: manager.dbQueue,
            currentTimeZoneProvider: { TimeZone(identifier: "America/Los_Angeles") ?? .current },
            nowProvider: { targetDate }
        )

        let provider = HealthSyncDataProviderStub(
            config: .init(
                hrv: 4.5,
                sleep: SleepData(
                    totalHours: 7.8,
                    deepMinutes: 88,
                    remMinutes: 94,
                    lightMinutes: 286,
                    awakeMinutes: 24,
                    efficiency: 89,
                    bedTime: nil,
                    wakeTime: nil
                ),
                rhr: 53,
                temperature: 0.1,
                steps: 8_400,
                activeCalories: 510,
                respiratoryRate: 14.2,
                bloodOxygen: 98.0,
                completenessOverride: 0.95
            )
        )

        let healthSync = HealthSyncManager(
            healthKitManager: provider,
            environmentService: EnvironmentServiceStub(result: .failure(HealthSyncTestError.environment)),
            dbQueue: manager.dbQueue,
            isHealthKitAvailable: { true },
            syncEngineProvider: { nil },
            timeZoneHistoryStore: timeZoneHistoryStore,
            nowProvider: { targetDate }
        )

        try await healthSync.syncDailyState(for: targetDate, userId: user.id)

        let state = try await fetchState(for: "2026-03-08", userId: user.id, dbQueue: manager.dbQueue)
        XCTAssertEqual(state.localTimezone, "Asia/Tokyo")
        XCTAssertEqual(state.localUtcOffsetMinutes, 540)

        let requestedKeys = await provider.observedHRVDateKeys()
        XCTAssertEqual(requestedKeys, ["2026-03-08"])
    }

    func testTimeZoneHistoryStoreCarriesForwardLatestSnapshotAcrossDays() async throws {
        let manager = try DatabaseManager.inMemory()
        var configuredUser = User(authId: UUID())
        configuredUser.timezone = "UTC"
        let user = configuredUser
        let snapshotDate = zonedDate(day: "2026-03-08", hour: 10, timeZoneIdentifier: "Asia/Tokyo")
        let nextDay = dateFrom(day: "2026-03-09")

        try await manager.dbQueue.write { db in
            try user.insert(db)
            var snapshot = TimeZoneHistoryEntry(
                userId: user.id,
                recordedAt: snapshotDate,
                timeZoneIdentifier: "Asia/Tokyo",
                utcOffsetMinutes: 540,
                createdAt: snapshotDate,
                updatedAt: snapshotDate
            )
            try snapshot.insert(db)
        }

        let store = TimeZoneHistoryStore(
            dbQueue: manager.dbQueue,
            currentTimeZoneProvider: { TimeZone(identifier: "America/Los_Angeles") ?? .current },
            nowProvider: { nextDay }
        )

        let context = try await store.resolveLocalDayContext(
            forDayString: "2026-03-09",
            userId: user.id,
            preferredDate: nextDay
        )

        XCTAssertEqual(context.dayString, "2026-03-09")
        XCTAssertEqual(context.timeZoneIdentifier, "Asia/Tokyo")
        XCTAssertEqual(context.utcOffsetMinutes, 540)
    }

    func testBackfillPreservesHistoricalDayKeysAcrossTimeZoneChanges() async throws {
        let manager = try DatabaseManager.inMemory()
        var configuredUser = User(authId: UUID())
        configuredUser.timezone = "UTC"
        let user = configuredUser

        let tokyoSnapshot = zonedDate(day: "2026-03-08", hour: 12, timeZoneIdentifier: "Asia/Tokyo")
        let losAngelesNow = zonedDate(day: "2026-03-09", hour: 12, timeZoneIdentifier: "America/Los_Angeles")

        try await manager.dbQueue.write { db in
            try user.insert(db)
            try Self.seedBaselineRows(userId: user.id, db: db)

            var snapshot = TimeZoneHistoryEntry(
                userId: user.id,
                recordedAt: tokyoSnapshot,
                timeZoneIdentifier: "Asia/Tokyo",
                utcOffsetMinutes: 540,
                createdAt: tokyoSnapshot,
                updatedAt: tokyoSnapshot
            )
            try snapshot.insert(db)
        }

        let timeZoneHistoryStore = TimeZoneHistoryStore(
            dbQueue: manager.dbQueue,
            currentTimeZoneProvider: { TimeZone(identifier: "America/Los_Angeles") ?? .current },
            nowProvider: { losAngelesNow }
        )

        let provider = HealthSyncDataProviderStub(
            config: .init(
                hrv: 4.4,
                sleep: SleepData(
                    totalHours: 7.7,
                    deepMinutes: 82,
                    remMinutes: 91,
                    lightMinutes: 279,
                    awakeMinutes: 26,
                    efficiency: 88,
                    bedTime: nil,
                    wakeTime: nil
                ),
                rhr: 54,
                temperature: 0.1,
                steps: 7_800,
                activeCalories: 520,
                respiratoryRate: 14.2,
                bloodOxygen: 98.0,
                completenessOverride: 0.94
            )
        )

        let healthSync = HealthSyncManager(
            healthKitManager: provider,
            environmentService: EnvironmentServiceStub(result: .failure(HealthSyncTestError.environment)),
            dbQueue: manager.dbQueue,
            isHealthKitAvailable: { true },
            syncEngineProvider: { nil },
            timeZoneHistoryStore: timeZoneHistoryStore,
            nowProvider: { losAngelesNow }
        )

        try await healthSync.backfillRecentData(days: 2, userId: user.id)

        let requestedKeys = await provider.observedHRVDateKeys()
        XCTAssertEqual(requestedKeys, ["2026-03-08", "2026-03-09"])

        let persistedRows = try await manager.dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT date, local_timezone
                    FROM physiological_states
                    WHERE user_id = ?
                      AND date IN ('2026-03-08', '2026-03-09')
                    ORDER BY date
                    """,
                arguments: [user.id.uuidString]
            ).map { row -> (String, String?) in
                let date: String = row["date"]
                let timeZone: String? = row["local_timezone"]
                return (date, timeZone)
            }
        }

        XCTAssertEqual(persistedRows.map(\.0), ["2026-03-08", "2026-03-09"])
        XCTAssertEqual(persistedRows.map(\.1), ["Asia/Tokyo", "America/Los_Angeles"])
    }

    private static func seedBaselineRows(userId: UUID, db: Database) throws {
        let baselineRows: [(String, Double, Int, Double, Double)] = [
            ("2026-03-01", 3.8, 58, 0.1, 6.8),
            ("2026-03-02", 4.0, 57, -0.1, 7.2),
            ("2026-03-03", 4.3, 56, 0.0, 7.5),
            ("2026-03-04", 4.5, 55, 0.2, 7.9),
            ("2026-03-05", 4.7, 54, 0.3, 8.1),
            ("2026-03-06", 4.1, 56, 0.1, 7.4),
            ("2026-03-07", 3.9, 57, -0.2, 7.0)
        ]

        for row in baselineRows {
            var state = PhysiologicalState(userId: userId, date: row.0, recoveryScore: 60)
            state.hrvMs = row.1
            state.restingHeartRateBpm = row.2
            state.wristTemperatureDeviationC = row.3
            state.sleepDurationHours = row.4
            state.sleepQualityPercent = 75
            try state.insert(db)
        }
    }

    private func fetchState(
        for date: String,
        userId: UUID,
        dbQueue: DatabaseQueue
    ) async throws -> PhysiologicalState {
        try await dbQueue.read { db in
            try XCTUnwrap(
                PhysiologicalState
                    .filter(Column("user_id") == userId.uuidString && Column("date") == date)
                    .fetchOne(db)
            )
        }
    }

    private func dateFrom(day: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let dayStart = formatter.date(from: day) ?? Date(timeIntervalSince1970: 0)
        return dayStart.addingTimeInterval(12 * 3600)
    }

    private func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func zonedDate(day: String, hour: Int, timeZoneIdentifier: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: "\(day) \(String(format: "%02d", hour)):00")
            ?? Date(timeIntervalSince1970: 0)
    }

    private func environmentContext(for dateKey: String) -> EnvironmentalContext {
        EnvironmentalContext(
            weatherCondition: "Clear",
            temperatureC: 20,
            pressureHpa: 1012,
            pressureDeltaHpa24h: -3,
            aqi: 31,
            indoorCo2Ppm: nil,
            moonPhase: "phase-\(dateKey)",
            daylightHours: 10.5,
            city: dateKey
        )
    }
}
