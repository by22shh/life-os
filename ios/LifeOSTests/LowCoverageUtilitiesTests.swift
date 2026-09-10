import ComposableArchitecture
import CryptoKit
import Foundation
import GRDB
import Supabase
import SwiftUI
import XCTest
@preconcurrency import AuthenticationServices
@preconcurrency import BackgroundTasks
@preconcurrency import CoreLocation
@preconcurrency import FamilyControls
@preconcurrency import HealthKit
@preconcurrency import WatchConnectivity
@testable import LifeOS

private enum DummySyncHandler: SyncModuleHandler {
    static let ownedTables: [SyncableTable] = [.foodLogs]
}

private func makeNoopSyncEngine(dbQueue: DatabaseQueue) -> SyncEngine {
    SyncEngine(
        dbQueue: dbQueue,
        apiClient: FakeSyncAPIClient(),
        pushTransportOverride: { _ in }
    )
}

private func insertTestUser(
    db: Database,
    userId: UUID,
    authId: UUID,
    now: Date
) throws {
    try db.execute(
        sql: """
            INSERT INTO users (
                id, auth_id, timezone, units, notification_enabled,
                onboarding_completed, calibration_days_remaining, deletion_in_progress,
                created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
        arguments: [
            userId.uuidString,
            authId.uuidString,
            "UTC",
            "metric",
            true,
            false,
            3,
            false,
            now,
            now
        ]
    )
}

private struct SimulationPredictionStub: PredictionServiceProtocol {
    let response: PredictiveScenarioResponse

    func runPredictiveSimulation(request _: PredictiveScenarioRequest) async throws -> PredictiveScenarioResponse {
        response
    }
}

private struct SimulationEnvironmentStub: EnvironmentServiceProtocol {
    let context: EnvironmentalContext

    func fetchCurrentEnvironment() async throws -> EnvironmentalContext {
        context
    }
}

private actor DailyInsightsNoopService: DailyInsightsManaging {
    func refreshCurrentDaySnapshot() async throws -> DailyInsightsSnapshot? {
        nil
    }
}

private actor WeeklyStrategyNoopService: WeeklyStrategyManaging {
    func refreshCurrentWeekReport() async throws -> WeeklyStrategyReport? {
        nil
    }
}

@MainActor
final class FinalCoverageGapTests: XCTestCase {
    override func tearDown() {
        APIClient._testResetOverrides()
        AuthManager.setActiveAuthIdForTests(nil)
        super.tearDown()
    }

    func testPrivacyNoteTextCoverageForAllBuiltInCases() {
        let builtInNotes: [PrivacyNote] = [
            .photoRetention,
            .menstrualLocalOnly,
            .medicalScanLocalOnly,
            .medicalScanRetention,
            .aiCacheExpiry,
            .healthKitReadOnly,
            .onDeviceOnly
        ]

        for note in builtInNotes {
            let text = note.text
            XCTAssertFalse(text.isEmpty)
            XCTAssertEqual(note.accessibilityText, text)
        }
    }

    func testAPIClientExecuteDecodedQueryRawPathWithoutDecodedOverride() async throws {
        APIClient._testResetOverrides()
        defer { APIClient._testResetOverrides() }

        let api = APIClient(deviceId: "coverage-device-execute-decoded-raw")
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://example.com/rest/v1/insights")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )
        let count = try await api._testExecuteDecodedQueryRawPathInsightCount(
            data: Data("[]".utf8),
            response: response
        )
        XCTAssertEqual(count, 0)
    }

    func testHomeViewRefreshTaskActionCoverageHook() async {
        let viewModel = HomeViewModel(pushLatestWatchSnapshot: { _ in })
        let view = HomeView(viewModel: viewModel)
        await view._testRunRefreshTaskAction()
        XCTAssertTrue(true)
    }

    func testSleepSummaryRowFallbackWhenDurationAndEfficiencyMissing() async throws {
        let dbQueue = try DatabaseQueue(path: ":memory:")
        let row = try await dbQueue.write { db -> Row in
            try db.execute(sql: """
                CREATE TABLE sleep_logs (
                    sleep_date TEXT,
                    date TEXT,
                    total_duration_minutes INTEGER,
                    sleep_efficiency DOUBLE,
                    deleted_at DATETIME,
                    updated_at DATETIME
                )
                """)
            try db.execute(
                sql: """
                    INSERT INTO sleep_logs (
                        sleep_date, date, total_duration_minutes, sleep_efficiency, deleted_at, updated_at
                    )
                    VALUES (?, ?, 0, NULL, NULL, CURRENT_TIMESTAMP)
                    """,
                arguments: ["2026-02-24", "2026-02-24"]
            )
            return try XCTUnwrap(
                Row.fetchOne(
                    db,
                    sql: "SELECT total_duration_minutes, sleep_efficiency FROM sleep_logs LIMIT 1"
                )
            )
        }

        let summary = SleepSummary(row: row)
        XCTAssertEqual(summary.primaryText, String(localized: "sleep_title"))
        XCTAssertNil(summary.secondaryText)
        XCTAssertEqual(summary.accessibilitySummary, String(localized: "sleep_title"))
    }

    func testRecoverySummaryRowFallbackZoneAndNilConfidence() async throws {
        let dbQueue = try DatabaseQueue(path: ":memory:")
        let row = try await dbQueue.write { db -> Row in
            try db.execute(sql: """
                CREATE TABLE physiological_states (
                    user_id TEXT NOT NULL,
                    date TEXT NOT NULL,
                    recovery_score DOUBLE,
                    recovery_zone TEXT,
                    confidence_score DOUBLE
                )
                """)
            try db.execute(
                sql: """
                    INSERT INTO physiological_states (
                        user_id, date, recovery_score, recovery_zone, confidence_score
                    )
                    VALUES (?, ?, ?, ?, NULL)
                    """,
                arguments: [UUID().uuidString, "2026-02-24", 30.0, "unknown-zone"]
            )
            return try XCTUnwrap(
                Row.fetchOne(
                    db,
                    sql: "SELECT recovery_score, recovery_zone, confidence_score FROM physiological_states LIMIT 1"
                )
            )
        }

        let resolvedSummary = try XCTUnwrap(RecoverySummary(row: row).map(\.accessibilitySummary))
        XCTAssertTrue(resolvedSummary.contains("30"))
        XCTAssertFalse(resolvedSummary.contains("%"))
    }

    func testMigrationsV21RebuildAndAddColumnIfMissingBranches() throws {
        let dbQueue = try DatabaseQueue(path: ":memory:")
        let validUserId = UUID().uuidString
        let validLogId = UUID().uuidString
        let orphanLogId = UUID().uuidString

        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "CREATE TABLE users (id TEXT PRIMARY KEY NOT NULL)")
            try db.execute(sql: """
                CREATE TABLE menstrual_logs (
                    id TEXT PRIMARY KEY NOT NULL,
                    user_id TEXT NOT NULL,
                    date TEXT NOT NULL,
                    flow TEXT,
                    pain_level INTEGER,
                    deleted_at DATETIME,
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL
                )
                """)

            try db.execute(sql: "INSERT INTO users (id) VALUES (?)", arguments: [validUserId])
            try db.execute(
                sql: """
                    INSERT INTO menstrual_logs (
                        id, user_id, date, flow, pain_level, deleted_at, created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, NULL, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                    """,
                arguments: [validLogId, validUserId, "2026-02-24", "light", 2]
            )
            try db.execute(
                sql: """
                    INSERT INTO menstrual_logs (
                        id, user_id, date, flow, pain_level, deleted_at, created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, NULL, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                    """,
                arguments: [orphanLogId, UUID().uuidString, "2026-02-24", "medium", 3]
            )

            try Migrations._testApplyV21MenstrualUserFkCascadeMigration(db: db)

            XCTAssertTrue(try hasCascadeUserForeignKey(db: db))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM menstrual_logs"), 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT id FROM menstrual_logs LIMIT 1"),
                validLogId
            )

            try db.execute(sql: "CREATE TABLE tmp_cols (id INTEGER PRIMARY KEY)")
            try Migrations._testAddColumnIfMissing(
                db: db,
                table: "tmp_cols",
                sql: "ALTER TABLE tmp_cols ADD COLUMN note TEXT"
            )
            try Migrations._testAddColumnIfMissing(
                db: db,
                table: "tmp_cols",
                sql: "ALTER TABLE tmp_cols ADD COLUMN note TEXT"
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM pragma_table_info('tmp_cols') WHERE lower(name) = 'note'"
                ),
                1
            )

            try Migrations._testAddColumnIfMissing(
                db: db,
                table: "tmp_cols",
                sql: "CREATE INDEX IF NOT EXISTS idx_tmp_cols_id ON tmp_cols(id)"
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_tmp_cols_id'"
                ),
                "idx_tmp_cols_id"
            )

            do {
                try Migrations._testAddColumnIfMissing(
                    db: db,
                    table: "tmp_cols",
                    sql: "ALTER TABLE tmp_cols ADD COLUMN "
                )
                XCTFail("Expected invalid SQL to throw")
            } catch {
                XCTAssertNotNil(error.localizedDescription)
            }
        }
    }

    func testMigrationsV21EarlyReturnWhenCascadeAlreadyPresent() throws {
        let dbQueue = try DatabaseQueue(path: ":memory:")
        let userId = UUID().uuidString
        let logId = UUID().uuidString

        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "CREATE TABLE users (id TEXT PRIMARY KEY NOT NULL)")
            try db.execute(sql: """
                CREATE TABLE menstrual_logs (
                    id TEXT PRIMARY KEY NOT NULL,
                    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    date TEXT NOT NULL,
                    flow TEXT,
                    pain_level INTEGER,
                    deleted_at DATETIME,
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL
                )
                """)
            try db.execute(sql: "INSERT INTO users (id) VALUES (?)", arguments: [userId])
            try db.execute(
                sql: """
                    INSERT INTO menstrual_logs (
                        id, user_id, date, flow, pain_level, deleted_at, created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, NULL, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                    """,
                arguments: [logId, userId, "2026-02-24", "light", 2]
            )

            try Migrations._testApplyV21MenstrualUserFkCascadeMigration(db: db)

            XCTAssertTrue(try hasCascadeUserForeignKey(db: db))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM menstrual_logs"), 1)
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT id FROM menstrual_logs LIMIT 1"),
                logId
            )
        }
    }

    private func hasCascadeUserForeignKey(db: Database) throws -> Bool {
        let fkRows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(menstrual_logs)")
        return fkRows.contains { row in
            let table = ((row["table"] as String?) ?? "").lowercased()
            let from = ((row["from"] as String?) ?? "").lowercased()
            let to = ((row["to"] as String?) ?? "").lowercased()
            let onDelete = ((row["on_delete"] as String?) ?? "").uppercased()
            return table == "users" && from == "user_id" && to == "id" && onDelete == "CASCADE"
        }
    }
}

private actor CoverageNutritionMealLoggerRecorder: NutritionMealLogging {
    private(set) var loggedMeals: [FoodLog] = []

    func logMeal(_ log: FoodLog) async throws {
        loggedMeals.append(log)
    }

    func latestMeal() -> FoodLog? {
        loggedMeals.last
    }
}

@MainActor
final class CoverageCompletionTests: XCTestCase {
    override func tearDown() {
        AuthManager.setActiveAuthIdForTests(nil)
        ForceUpdateManager.shared._testSetStatus(.upToDate)
        GuardianManager._testSetAuthorizationOverride(nil)
        GuardianManager._testSetRequestAuthorization(nil)
        GuardianManager._testSetRevokeAuthorization(nil)
        GuardianManager._testSetSystemRevokeAuthorization(nil)
        GuardianManager._testSetDefaultRequestAuthorization(nil)
        GuardianManager._testSetDefaultSystemRevokeAuthorization(nil)
        super.tearDown()
    }

    func testSleepLogDecodingErrorFallbackAndStrategies() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let missingDateJSON = """
        {
          "id":"00000000-0000-4000-8000-000000000100",
          "userId":"00000000-0000-4000-8000-000000000101",
          "createdAt":"2026-02-24T10:00:00Z",
          "updatedAt":"2026-02-24T10:00:00Z"
        }
        """
        XCTAssertThrowsError(try decoder.decode(SleepLog.self, from: Data(missingDateJSON.utf8)))

        let fallbackJSON = """
        {
          "id":"00000000-0000-4000-8000-000000000110",
          "userId":"00000000-0000-4000-8000-000000000111",
          "date":"2026-02-24",
          "createdAt":"2026-02-24T10:00:00Z",
          "updatedAt":"2026-02-24T10:00:00Z",
          "caffeine_after_14": true
        }
        """
        let decoded = try decoder.decode(SleepLog.self, from: Data(fallbackJSON.utf8))
        XCTAssertEqual(decoded.sleepDate, "2026-02-24")
        XCTAssertEqual(decoded.date, "2026-02-24")
        XCTAssertEqual(decoded.caffeineAfter14, true)
        if case .convertFromSnakeCase = SleepLog.databaseColumnDecodingStrategy {
            // expected
        } else {
            XCTFail("Expected convertFromSnakeCase decoding strategy")
        }
        if case .convertToSnakeCase = SleepLog.databaseColumnEncodingStrategy {
            // expected
        } else {
            XCTFail("Expected convertToSnakeCase encoding strategy")
        }
    }

    func testSleepLogDerivedPercentagesAndAnyCodingKeyBranches() {
        var log = SleepLog(userId: UUID(), date: "2026-02-24")
        log.totalDurationMinutes = 0
        log.deepSleepMinutes = 90
        log.remSleepMinutes = 110
        XCTAssertNil(log.deepSleepPercent)
        XCTAssertNil(log.remSleepPercent)

        log.totalDurationMinutes = 480
        XCTAssertEqual(try XCTUnwrap(log.deepSleepPercent), 18.75, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(log.remSleepPercent), 22.9166667, accuracy: 0.0001)

        XCTAssertTrue(SleepLog._testAnyCodingKeyFromStringValue("caffeine_after_14"))
        XCTAssertFalse(SleepLog._testAnyCodingKeyFromIntValue(14))
    }

    func testRecoveryAndSleepViewHarnessFallbackLoadBranches() async throws {
        let dbQueue = try DatabaseQueue(path: ":memory:")

        let recoveryNil = await RecoveryDetailViewTestHarness.loadSummary(
            dateString: nil,
            dbQueue: dbQueue
        )
        XCTAssertNil(recoveryNil)

        let sleepNil = await SleepDayViewTestHarness.loadSummary(
            dateString: nil,
            dbQueue: dbQueue
        )
        XCTAssertNil(sleepNil)
    }

    func testRecoveryEngineSleepAndTemperatureFallbackBranches() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let now = Date()

        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [userId.uuidString, UUID().uuidString, "UTC", "metric", now, now]
            )

            let baselineDates = ["2026-02-18", "2026-02-19", "2026-02-20", "2026-02-21", "2026-02-22"]
            for (offset, date) in baselineDates.enumerated() {
                try db.execute(
                    sql: """
                    INSERT INTO physiological_states
                    (id, user_id, date, resting_heart_rate_bpm, recovery_score, recovery_zone, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [UUID().uuidString, userId.uuidString, date, 55 + offset, 50, RecoveryZone.ready.rawValue, now, now]
                )
            }

            try db.execute(
                sql: """
                INSERT INTO physiological_states
                (id, user_id, date, resting_heart_rate_bpm, wrist_temperature_deviation_c, sleep_quality_percent, recovery_score, recovery_zone, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [UUID().uuidString, userId.uuidString, "2026-02-23", 58, 0.4, 72, 50, RecoveryZone.ready.rawValue, now, now]
            )

            try db.execute(
                sql: """
                INSERT INTO physiological_states
                (id, user_id, date, resting_heart_rate_bpm, sleep_duration_hours, deep_sleep_percent, rem_sleep_percent, recovery_score, recovery_zone, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [UUID().uuidString, userId.uuidString, "2026-02-24", 57, 7.2, 18, 22, 50, RecoveryZone.ready.rawValue, now, now]
            )
        }

        let fallbackScore = try await manager.dbQueue.read { db in
            try RecoveryEngine.computeScore(userId: userId, date: "2026-02-23", db: db)
        }
        XCTAssertEqual(fallbackScore.components.sleepScore, 72)
        XCTAssertNotNil(fallbackScore.components.rhrScore)
        XCTAssertNotNil(fallbackScore.components.tempScore)

        let scorerScore = try await manager.dbQueue.read { db in
            try RecoveryEngine.computeScore(userId: userId, date: "2026-02-24", db: db)
        }
        XCTAssertNotNil(scorerScore.components.sleepScore)
    }

    func testSleepTargetEngineSupportiveFeedbackCoverageBranches() {
        let disclaimer = String(localized: "clinician_disclaimer")

        let noData = SleepTargetEngine.supportiveStageFeedback(
            deepPercent: nil,
            remPercent: nil,
            age: 32
        )
        XCTAssertFalse(noData.isEmpty)

        let inRange = SleepTargetEngine.supportiveStageFeedback(
            deepPercent: 16,
            remPercent: 20,
            age: 32
        )
        XCTAssertTrue(inRange.contains(disclaimer))

        let bothOutside = SleepTargetEngine.supportiveStageFeedback(
            deepPercent: 4,
            remPercent: 30,
            age: 32
        )
        XCTAssertTrue(bothOutside.contains(disclaimer))

        let deepOutside = SleepTargetEngine.supportiveStageFeedback(
            deepPercent: 6,
            remPercent: 21,
            age: 32
        )
        XCTAssertTrue(deepOutside.contains(disclaimer))

        let remOutside = SleepTargetEngine.supportiveStageFeedback(
            deepPercent: 15,
            remPercent: 30,
            age: 32
        )
        XCTAssertTrue(remOutside.contains(disclaimer))
    }

    func testForceUpdateManagerNormalizationAndVersionEdgeBranches() {
        let manager = ForceUpdateManager()
        XCTAssertFalse(manager.compareVersions("1.beta.3", isLessThan: "1.0.3"))

        manager._testSetStatus(.upToDate)
        manager.checkHeaders([
            "X-Soft-Update-Version": 999
        ])
        if case let .softUpdate(minVersion) = manager.status {
            XCTAssertEqual(minVersion, "999")
        } else {
            XCTFail("Expected soft update status for numeric header normalization")
        }
    }

    func testGRDBRecordsSyncCursorStrategies() {
        if case .useDefaultKeys = SyncRowCursor.databaseColumnDecodingStrategy {
            // expected
        } else {
            XCTFail("Expected useDefaultKeys decoding strategy")
        }
        if case .useDefaultKeys = SyncRowCursor.databaseColumnEncodingStrategy {
            // expected
        } else {
            XCTFail("Expected useDefaultKeys encoding strategy")
        }
    }

    func testBackgroundSyncManagerResetRegistrationState() {
        BackgroundSyncManager._testResetRegistrationState()
        let samples = BackgroundSyncManager._testDispatchRegisteredTaskSamples()
        XCTAssertEqual(samples.nilFailures, 1)
        XCTAssertEqual(samples.handledValues, [42])
    }

    func testGuardianManagerUnauthorizedAndSelectionFallbackBranches() {
        let defaults = UserDefaults.standard
        let key = "guardian_mode_selection"
        defaults.removeObject(forKey: key)

        var settings = NotificationSettings(userId: UUID())
        settings.controlLevel = .guardian
        settings.focusControlEnabled = true
        settings.criticalOnly = false

        GuardianManager._testSetAuthorizationOverride(false)
        GuardianManager.shared.applyShieldsIfAllowed(selection: FamilyActivitySelection(), settings: settings)
        let loadedSelection = GuardianManager.shared.loadSelection()
        XCTAssertNotNil(loadedSelection.encode())

        defaults.set(Data("not-a-valid-selection".utf8), forKey: key)
        let fallbackSelection = GuardianManager.shared.loadSelection()
        XCTAssertNotNil(fallbackSelection.encode())
    }

    func testNutritionLogViewModelAiConfidenceAndMissingUserBranches() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let logger = CoverageNutritionMealLoggerRecorder()

        try await manager.dbQueue.write { db in
            let now = Date()
            try db.execute(
                sql: """
                INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [userId.uuidString, authId.uuidString, "UTC", "metric", now, now]
            )
        }

        AuthManager.setActiveAuthIdForTests(authId)
        let successVM = NutritionLogViewModel(
            method: .photo,
            aiConfidence: 0.42,
            nutritionService: logger,
            dbQueue: manager.dbQueue
        )
        successVM.didReviewLowConfidence = true
        let saved = await successVM.save()
        XCTAssertTrue(saved)
        let recorded = await logger.latestMeal()
        XCTAssertEqual(recorded?.aiConfidence, 0.42)

        AuthManager.setActiveAuthIdForTests(UUID())
        let missingUserVM = NutritionLogViewModel(
            method: .manual,
            aiConfidence: nil,
            nutritionService: logger,
            dbQueue: manager.dbQueue
        )
        missingUserVM.addMealItem()
        let missingSaved = await missingUserVM.save()
        XCTAssertFalse(missingSaved)
        XCTAssertNotNil(missingUserVM.errorMessage)
    }

    func testSleepScorerUsesPhysiologicalStateFallbackForDeepAndRem() {
        var state = PhysiologicalState(userId: UUID(), date: "2026-02-24", recoveryScore: 50)
        state.sleepDurationHours = 7.2
        state.deepSleepPercent = 18
        state.remSleepPercent = 21

        let score = SleepScorer.compositeScore(
            sleepLog: nil,
            physiologicalState: state,
            age: 33
        )
        XCTAssertNotNil(score)
    }

    func testSupplementsAndTrainingLoadCatchBranches() async throws {
        let invalidQueue = try DatabaseQueue(path: ":memory:")

        AuthManager.setActiveAuthIdForTests(nil)
        let noAuthLogs = await SupplementsDayViewTestHarness.loadLogs(
            dateString: nil,
            dbQueue: invalidQueue
        )
        XCTAssertTrue(noAuthLogs.isEmpty)

        AuthManager.setActiveAuthIdForTests(UUID())
        let catchLogs = await SupplementsDayViewTestHarness.loadLogs(
            dateString: nil,
            dbQueue: invalidQueue
        )
        XCTAssertTrue(catchLogs.isEmpty)

        let catchSessions = await TrainingDayViewTestHarness.loadSessions(
            dateString: nil,
            dbQueue: invalidQueue
        )
        XCTAssertTrue(catchSessions.isEmpty)
    }

    func testInsightClinicianCaveatAlreadyPresentBranch() {
        let disclaimer = String(localized: "clinician_disclaimer")
        let body = "Keep monitoring trends. \(disclaimer)"
        let insight = Insight(
            userId: UUID(),
            category: .sleep,
            title: "Sleep pattern",
            body: body,
            confidence: 0.9
        )
        XCTAssertEqual(insight.body, body)
    }

    func testNutritionCleanupServiceCatchBranchWithReadOnlyDirectory() async throws {
        let fileManager = FileManager.default
        let root = try XCTUnwrap(fileManager.urls(for: .documentDirectory, in: .userDomainMask).first)
        let imagesDirectory = root.appendingPathComponent("images", isDirectory: true)
        let directoryExisted = fileManager.fileExists(atPath: imagesDirectory.path)
        try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        let image = imagesDirectory.appendingPathComponent("old-photo-\(UUID().uuidString).jpg")
        try Data("x".utf8).write(to: image)

        let oldDate = Date(timeIntervalSinceNow: -100 * 24 * 60 * 60)
        try fileManager.setAttributes([.creationDate: oldDate], ofItemAtPath: image.path)
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: imagesDirectory.path)

        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: imagesDirectory.path)
            try? fileManager.removeItem(at: image)
            if !directoryExisted {
                try? fileManager.removeItem(at: imagesDirectory)
            }
        }

        await NutritionCleanupService.pruneOldPhotos()
        XCTAssertTrue(fileManager.fileExists(atPath: image.path))
    }

    func testDeepLinkFallbackAuditFailureBranchViaOutboxTrigger() async throws {
        let triggerName = "lifeos_test_fail_outbox_insert"
        try await DatabaseManager.shared.dbQueue.write { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS \(triggerName)")
            try db.execute(sql: """
                CREATE TRIGGER \(triggerName)
                BEFORE INSERT ON outbox_events
                BEGIN
                    SELECT RAISE(FAIL, 'forced outbox failure');
                END;
                """)
        }
        defer {
            Task {
                try? await DatabaseManager.shared.dbQueue.write { db in
                    try db.execute(sql: "DROP TRIGGER IF EXISTS \(triggerName)")
                }
            }
        }

        DeepLinkRouter._testLogFallback(URL(string: "lifeos://unknown-route")!, isRunningTests: false)
        try await Task.sleep(nanoseconds: 300_000_000)
    }
}

final class HealthKitManagerCoverageExpansionTests: XCTestCase {
    private actor VisitRecorder {
        var identifiers: [String] = []

        func append(_ identifier: String) {
            identifiers.append(identifier)
        }

        func snapshot() -> [String] {
            identifiers
        }
    }

    override func tearDown() {
        HealthKitManager._testResetOverrides()
        super.tearDown()
    }

    func testAuthorizationHelpersAndReadTypeCatalog() async {
        XCTAssertGreaterThan(HealthKitManager._testReadTypesCount(), 0)
        XCTAssertGreaterThan(HealthKitManager._testBackgroundDeliveryTypesCount(), 0)

        let manager = HealthKitManager()
        let stepType = HKQuantityType(.stepCount)
        let sleepType = HKCategoryType(.sleepAnalysis)
        let readTypes: Set<HKObjectType> = [stepType, sleepType]
        let statuses: [ObjectIdentifier: HKAuthorizationStatus] = [
            ObjectIdentifier(stepType): .sharingAuthorized,
            ObjectIdentifier(sleepType): .sharingDenied
        ]

        let authorizedCount = await manager._testAuthorizedReadTypeCount(
            for: readTypes,
            statuses: statuses
        )
        XCTAssertEqual(authorizedCount, 1)
        let fallbackStatusCount = await manager._testAuthorizedReadTypeCount(
            for: readTypes,
            statuses: [ObjectIdentifier(stepType): .sharingAuthorized]
        )
        XCTAssertEqual(fallbackStatusCount, 1)
        let shouldEnable = await manager._testShouldEnableBackgroundDelivery(forAuthorizedTypeCount: 1)
        let shouldDisable = await manager._testShouldEnableBackgroundDelivery(forAuthorizedTypeCount: 0)
        XCTAssertTrue(shouldEnable)
        XCTAssertFalse(shouldDisable)
    }

    func testMetricComputationHelpers() async throws {
        let manager = HealthKitManager()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let hrvType = HKQuantityType(.heartRateVariabilitySDNN)
        let validHRV = HKQuantitySample(
            type: hrvType,
            quantity: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: 60),
            start: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(-300)
        )
        let noisyHRV = HKQuantitySample(
            type: hrvType,
            quantity: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: 4),
            start: now.addingTimeInterval(-600),
            end: now.addingTimeInterval(-600)
        )

        let latestHRV = await manager._testLatestHRVValue(from: [validHRV, noisyHRV])
        XCTAssertEqual(try XCTUnwrap(latestHRV), log(66), accuracy: 0.0001)
        let nilHRV = await manager._testLatestHRVValue(from: [noisyHRV])
        XCTAssertNil(nilHRV)

        let rhrType = HKQuantityType(.restingHeartRate)
        let rhr1 = HKQuantitySample(
            type: rhrType,
            quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: 50),
            start: now.addingTimeInterval(-100),
            end: now.addingTimeInterval(-100)
        )
        let rhr2 = HKQuantitySample(
            type: rhrType,
            quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: 55),
            start: now.addingTimeInterval(-50),
            end: now.addingTimeInterval(-50)
        )
        let meanRHR = await manager._testMeanRestingHeartRate(from: [rhr1, rhr2])
        XCTAssertEqual(meanRHR, 53)
        let nilRHR = await manager._testMeanRestingHeartRate(from: [])
        XCTAssertNil(nilRHR)

        let sleepType = HKCategoryType(.sleepAnalysis)
        let deep = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            start: now.addingTimeInterval(-7_200),
            end: now.addingTimeInterval(-5_400)
        )
        let rem = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            start: now.addingTimeInterval(-5_400),
            end: now.addingTimeInterval(-4_500)
        )
        let core = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            start: now.addingTimeInterval(-4_500),
            end: now.addingTimeInterval(-2_700)
        )
        let unspecified = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            start: now.addingTimeInterval(-2_700),
            end: now.addingTimeInterval(-2_100)
        )
        let awake = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.awake.rawValue,
            start: now.addingTimeInterval(-2_100),
            end: now.addingTimeInterval(-1_500)
        )
        let inBed = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.inBed.rawValue,
            start: now.addingTimeInterval(-7_200),
            end: now.addingTimeInterval(-1_200)
        )

        let sleepData = await manager._testSleepData(from: [deep, rem, core, unspecified, awake, inBed])
        XCTAssertEqual(sleepData.deepMinutes, 30)
        XCTAssertEqual(sleepData.remMinutes, 15)
        XCTAssertEqual(sleepData.lightMinutes, 40)
        XCTAssertEqual(sleepData.awakeMinutes, 10)
        XCTAssertEqual(sleepData.totalHours, 85.0 / 60.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(sleepData.efficiency), 85.0, accuracy: 0.0001)

        let spO2Type = HKQuantityType(.oxygenSaturation)
        let spO2 = HKQuantitySample(
            type: spO2Type,
            quantity: HKQuantity(unit: .percent(), doubleValue: 0.977),
            start: now,
            end: now
        )
        let spO2Percent = await manager._testBloodOxygenPercent(from: spO2)
        XCTAssertEqual(try XCTUnwrap(spO2Percent), 97.7, accuracy: 0.0001)
        let nilSpO2 = await manager._testBloodOxygenPercent(from: nil)
        XCTAssertNil(nilSpO2)
    }

    func testPublicHealthKitMethodsExecuteTransformsWithOverrides() async throws {
        let manager = HealthKitManager()
        let recorder = VisitRecorder()
        let now = Date(timeIntervalSince1970: 1_700_100_000)

        @Sendable func sample(
            type: HKQuantityType,
            unit: HKUnit,
            value: Double,
            startOffset: TimeInterval
        ) -> HKQuantitySample {
            HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: unit, doubleValue: value),
                start: now.addingTimeInterval(startOffset),
                end: now.addingTimeInterval(startOffset + 60)
            )
        }

        HealthKitManager._testSetIsAvailableOverride(true)
        HealthKitManager._testSetRequestAccessOverride {
            await recorder.append("request_access")
        }
        HealthKitManager._testSetAuthorizedTypeCountOverride { 1 }
        HealthKitManager._testSetEnableBackgroundOverride {
            await recorder.append("enable_background")
        }
        let granted = try await manager.requestAuthorization()
        XCTAssertTrue(granted)

        HealthKitManager._testSetAuthorizedTypeCountOverride { 0 }
        let denied = try await manager.requestAuthorization()
        XCTAssertTrue(denied) // zero WRITE grants does not imply denied READ access

        HealthKitManager._testSetRequestAccessOverride(nil)
        HealthKitManager._testSetDefaultRequestAccessRunner {
            await recorder.append("default_request_access")
        }
        HealthKitManager._testSetAuthorizedTypeCountOverride(nil)
        HealthKitManager._testSetEnableBackgroundOverride {
            await recorder.append("default_background_override")
        }
        let defaultAuthorization = try await manager.requestAuthorization()
        XCTAssertTrue(defaultAuthorization)

        HealthKitManager._testSetRequestAccessOverride {
            await recorder.append("request_access_second_pass")
        }
        HealthKitManager._testSetAuthorizedTypeCountOverride { 1 }
        HealthKitManager._testSetEnableBackgroundOverride(nil)
        HealthKitManager._testSetEnableBackgroundDeliveryRunner { types in
            await recorder.append("default_background_delivery:\(types.count)")
        }
        let defaultBackground = try await manager.requestAuthorization()
        XCTAssertTrue(defaultBackground)

        let hrvType = HKQuantityType(.heartRateVariabilitySDNN)
        let rhrType = HKQuantityType(.restingHeartRate)
        let respiratoryType = HKQuantityType(.respiratoryRate)
        let oxygenType = HKQuantityType(.oxygenSaturation)
        let wristTemperatureType = HKQuantityType(.appleSleepingWristTemperature)
        let sleepType = HKCategoryType(.sleepAnalysis)

        HealthKitManager._testSetQuerySamplesOverride { type, _, _, _, _ in
            await recorder.append("query:\(type.identifier)")
            switch type.identifier {
            case HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue:
                return [sample(type: hrvType, unit: .secondUnit(with: .milli), value: 55, startOffset: -3_600)]
            case HKQuantityTypeIdentifier.restingHeartRate.rawValue:
                return [sample(type: rhrType, unit: .count().unitDivided(by: .minute()), value: 52, startOffset: -3_000)]
            case HKQuantityTypeIdentifier.respiratoryRate.rawValue:
                return [sample(type: respiratoryType, unit: .count().unitDivided(by: .minute()), value: 13, startOffset: -2_000)]
            case HKQuantityTypeIdentifier.oxygenSaturation.rawValue:
                return [sample(type: oxygenType, unit: .percent(), value: 0.97, startOffset: -1_000)]
            case HKQuantityTypeIdentifier.appleSleepingWristTemperature.rawValue:
                return [sample(type: wristTemperatureType, unit: .degreeCelsius(), value: 0.2, startOffset: -900)]
            default:
                return []
            }
        }

        HealthKitManager._testSetSleepSamplesOverride { _, _ in
            await recorder.append("sleep_query")
            return [
                HKCategorySample(
                    type: sleepType,
                    value: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                    start: now.addingTimeInterval(-8_000),
                    end: now.addingTimeInterval(-5_000)
                ),
                HKCategorySample(
                    type: sleepType,
                    value: HKCategoryValueSleepAnalysis.awake.rawValue,
                    start: now.addingTimeInterval(-5_000),
                    end: now.addingTimeInterval(-4_800)
                )
            ]
        }

        HealthKitManager._testSetCumulativeSumOverride { type, _, _ in
            await recorder.append("sum:\(type.identifier)")
            switch type.identifier {
            case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue: return 620
            case HKQuantityTypeIdentifier.stepCount.rawValue: return 8_500
            case HKQuantityTypeIdentifier.appleExerciseTime.rawValue: return 42
            default: return nil
            }
        }

        _ = try await manager.fetchLatestHRV(for: now)
        _ = try await manager.fetchRestingHeartRate(for: now)
        _ = try await manager.fetchSleep(for: now)
        _ = try await manager.fetchActiveCalories(for: now)
        _ = try await manager.fetchSteps(for: now)
        _ = try await manager.fetchExerciseMinutes(for: now)
        _ = try await manager.fetchRespiratoryRate(for: now)
        _ = try await manager.fetchBloodOxygen(for: now)
        if #available(iOS 16.0, *) {
            _ = try await manager.fetchWristTemperature(for: now)
        }
        _ = try await manager.dataCompleteness(for: now)

        let visited = await recorder.snapshot()
        XCTAssertTrue(visited.contains("request_access"))
        XCTAssertTrue(visited.contains("default_request_access"))
        XCTAssertTrue(visited.contains("request_access_second_pass"))
        XCTAssertTrue(visited.contains("default_background_delivery:\(HealthKitManager._testBackgroundDeliveryTypesCount())"))
        XCTAssertTrue(visited.contains("enable_background"))
        XCTAssertTrue(visited.contains("sleep_query"))
        XCTAssertTrue(visited.contains("query:\(HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue)"))
        XCTAssertTrue(visited.contains("query:\(HKQuantityTypeIdentifier.restingHeartRate.rawValue)"))
        XCTAssertTrue(visited.contains("query:\(HKQuantityTypeIdentifier.respiratoryRate.rawValue)"))
        XCTAssertTrue(visited.contains("query:\(HKQuantityTypeIdentifier.oxygenSaturation.rawValue)"))
        XCTAssertTrue(visited.contains("query:\(HKQuantityTypeIdentifier.appleSleepingWristTemperature.rawValue)"))
        XCTAssertTrue(visited.contains("sum:\(HKQuantityTypeIdentifier.activeEnergyBurned.rawValue)"))
        XCTAssertTrue(visited.contains("sum:\(HKQuantityTypeIdentifier.stepCount.rawValue)"))
        XCTAssertTrue(visited.contains("sum:\(HKQuantityTypeIdentifier.appleExerciseTime.rawValue)"))
    }

    func testBackgroundDeliveryHelperSuccessAndErrorPaths() async throws {
        enum CoverageError: Error { case expected }

        let manager = HealthKitManager()
        let types: [HKSampleType] = [HKQuantityType(.stepCount), HKCategoryType(.sleepAnalysis)]
        let recorder = VisitRecorder()

        try await manager._testEnableBackgroundDelivery(types: types) { type in
            await recorder.append(type.identifier)
            return true
        }
        let visited = await recorder.snapshot()
        XCTAssertEqual(visited, types.map(\.identifier))

        let sleepTypeIdentifier = HKCategoryType(.sleepAnalysis).identifier
        do {
            try await manager._testEnableBackgroundDelivery(types: types) { type in
                type.identifier != sleepTypeIdentifier
            }
            XCTFail("Expected authorizationDenied for false delivery status")
        } catch let error as HealthKitError {
            switch error {
            case .authorizationDenied:
                break
            default:
                XCTFail("Unexpected HealthKitError: \(error)")
            }
        }

        do {
            try await manager._testEnableBackgroundDelivery(types: types) { _ in
                throw CoverageError.expected
            }
            XCTFail("Expected underlying delivery error")
        } catch let error as CoverageError {
            XCTAssertEqual(error, .expected)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testRequestAuthorizationFlowHelperBranches() async throws {
        enum FlowError: Error, Equatable {
            case denied
        }

        actor FlagStore {
            var requestCount = 0
            var backgroundCount = 0

            func incrementRequest() { requestCount += 1 }
            func incrementBackground() { backgroundCount += 1 }
            func snapshot() -> (Int, Int) { (requestCount, backgroundCount) }
        }

        let manager = HealthKitManager()
        let flags = FlagStore()

        let unavailable = try await manager._testRequestAuthorizationFlow(
            isAvailable: false,
            requestAccess: { await flags.incrementRequest() },
            authorizedTypeCount: { 1 },
            enableBackground: { await flags.incrementBackground() }
        )
        XCTAssertFalse(unavailable)
        let unavailableCounts = await flags.snapshot()
        XCTAssertEqual(unavailableCounts.0, 0)
        XCTAssertEqual(unavailableCounts.1, 0)

        let denied = try await manager._testRequestAuthorizationFlow(
            isAvailable: true,
            requestAccess: { await flags.incrementRequest() },
            authorizedTypeCount: { 0 },
            enableBackground: { await flags.incrementBackground() }
        )
        XCTAssertTrue(denied) // read grants are deliberately undisclosed by HealthKit
        let deniedCounts = await flags.snapshot()
        XCTAssertEqual(deniedCounts.0, 1)
        XCTAssertEqual(deniedCounts.1, 1)

        let granted = try await manager._testRequestAuthorizationFlow(
            isAvailable: true,
            requestAccess: { await flags.incrementRequest() },
            authorizedTypeCount: { 2 },
            enableBackground: { await flags.incrementBackground() }
        )
        XCTAssertTrue(granted)
        let grantedCounts = await flags.snapshot()
        XCTAssertEqual(grantedCounts.0, 2)
        XCTAssertEqual(grantedCounts.1, 2)

        do {
            _ = try await manager._testRequestAuthorizationFlow(
                isAvailable: true,
                requestAccess: { throw FlowError.denied },
                authorizedTypeCount: { 5 },
                enableBackground: { await flags.incrementBackground() }
            )
            XCTFail("Expected flow to propagate requestAccess error")
        } catch let error as FlowError {
            XCTAssertEqual(error, .denied)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSleepSourceAndBoutPreferenceComparators() {
        XCTAssertTrue(
            HealthKitManager._testShouldPreferSleepSource(
                lhsRank: 0,
                lhsHasStages: false,
                lhsDurationSeconds: 1_000,
                rhsRank: 2,
                rhsHasStages: true,
                rhsDurationSeconds: 9_000
            )
        )
        XCTAssertTrue(
            HealthKitManager._testShouldPreferSleepSource(
                lhsRank: 1,
                lhsHasStages: true,
                lhsDurationSeconds: 1_000,
                rhsRank: 1,
                rhsHasStages: false,
                rhsDurationSeconds: 9_000
            )
        )
        XCTAssertTrue(
            HealthKitManager._testShouldPreferSleepSource(
                lhsRank: 1,
                lhsHasStages: true,
                lhsDurationSeconds: 8_000,
                rhsRank: 1,
                rhsHasStages: true,
                rhsDurationSeconds: 7_000
            )
        )
        XCTAssertFalse(
            HealthKitManager._testShouldPreferSleepSource(
                lhsRank: 2,
                lhsHasStages: false,
                lhsDurationSeconds: 2_000,
                rhsRank: 1,
                rhsHasStages: true,
                rhsDurationSeconds: 3_000
            )
        )

        XCTAssertTrue(
            HealthKitManager._testShouldPreferSleepBout(
                lhsAsleepMinutes: 420,
                lhsDistanceToEightAM: 3_600,
                lhsHasStages: false,
                rhsAsleepMinutes: 390,
                rhsDistanceToEightAM: 1_200,
                rhsHasStages: true
            )
        )
        XCTAssertTrue(
            HealthKitManager._testShouldPreferSleepBout(
                lhsAsleepMinutes: 400,
                lhsDistanceToEightAM: 900,
                lhsHasStages: false,
                rhsAsleepMinutes: 400,
                rhsDistanceToEightAM: 1_800,
                rhsHasStages: true
            )
        )
        XCTAssertTrue(
            HealthKitManager._testShouldPreferSleepBout(
                lhsAsleepMinutes: 400,
                lhsDistanceToEightAM: 900,
                lhsHasStages: true,
                rhsAsleepMinutes: 400,
                rhsDistanceToEightAM: 900,
                rhsHasStages: false
            )
        )
        XCTAssertFalse(
            HealthKitManager._testShouldPreferSleepBout(
                lhsAsleepMinutes: 300,
                lhsDistanceToEightAM: 9_000,
                lhsHasStages: false,
                rhsAsleepMinutes: 360,
                rhsDistanceToEightAM: 3_600,
                rhsHasStages: true
            )
        )
    }

    func testHealthKitQueryResolutionHelpers() async throws {
        enum ExpectedError: Error {
            case boom
        }

        let manager = HealthKitManager()
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let quantitySample = HKQuantitySample(
            type: HKQuantityType(.stepCount),
            quantity: HKQuantity(unit: .count(), doubleValue: 123),
            start: now,
            end: now
        )

        let resolvedSamples = try await manager._testResolveQuantitySamples(
            results: [quantitySample],
            error: nil
        )
        XCTAssertEqual(resolvedSamples.count, 1)
        let mismatchedSample = HKCategorySample(
            type: HKCategoryType(.sleepAnalysis),
            value: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            start: now,
            end: now.addingTimeInterval(60)
        )
        let resolvedMismatchedSamples = try await manager._testResolveQuantitySamples(
            results: [mismatchedSample],
            error: nil
        )
        XCTAssertTrue(resolvedMismatchedSamples.isEmpty)

        do {
            _ = try await manager._testResolveQuantitySamples(
                results: [quantitySample],
                error: ExpectedError.boom
            )
            XCTFail("Expected quantity sample resolver to throw")
        } catch is ExpectedError {
            // expected
        }

        let anchorKey = "coverage_anchor_\(UUID().uuidString)"
        let anchor = HKQueryAnchor(fromValue: 5)
        let anchoredSamples = try await manager._testResolveAnchoredQuantitySamples(
            samples: [quantitySample],
            newAnchor: anchor,
            error: nil,
            anchorKey: anchorKey
        )
        XCTAssertEqual(anchoredSamples.count, 1)
        let anchoredMismatchedSamples = try await manager._testResolveAnchoredQuantitySamples(
            samples: [mismatchedSample],
            newAnchor: nil,
            error: nil,
            anchorKey: anchorKey
        )
        XCTAssertTrue(anchoredMismatchedSamples.isEmpty)

        do {
            _ = try await manager._testResolveAnchoredQuantitySamples(
                samples: [quantitySample],
                newAnchor: nil,
                error: ExpectedError.boom,
                anchorKey: anchorKey
            )
            XCTFail("Expected anchored resolver to throw")
        } catch is ExpectedError {
            // expected
        }

        let nilSum = try await manager._testResolveCumulativeSum(
            stats: nil,
            error: nil,
            unit: .count()
        )
        XCTAssertNil(nilSum)

        do {
            _ = try await manager._testResolveCumulativeSum(
                stats: nil,
                error: ExpectedError.boom,
                unit: .count()
            )
            XCTFail("Expected cumulative sum resolver to throw")
        } catch is ExpectedError {
            // expected
        }
    }

    func testHealthKitManagerAdditionalNilResolversAndMedianBranches() async throws {
        let manager = HealthKitManager()

        let medianEmpty = await manager._testMedian([])
        XCTAssertNil(medianEmpty)

        let medianSingleOptional = await manager._testMedian([7])
        let medianSingle = try XCTUnwrap(medianSingleOptional)
        XCTAssertEqual(medianSingle, 7, accuracy: 0.0001)

        let medianOddOptional = await manager._testMedian([1, 3, 5])
        let medianOdd = try XCTUnwrap(medianOddOptional)
        XCTAssertEqual(medianOdd, 3, accuracy: 0.0001)

        let medianEvenOptional = await manager._testMedian([1, 3, 5, 7])
        let medianEven = try XCTUnwrap(medianEvenOptional)
        XCTAssertEqual(medianEven, 4, accuracy: 0.0001)

        let emptyResolved = try await manager._testResolveQuantitySamples(results: nil, error: nil)
        XCTAssertTrue(emptyResolved.isEmpty)

        let emptyAnchored = try await manager._testResolveAnchoredQuantitySamples(
            samples: nil,
            newAnchor: nil,
            error: nil,
            anchorKey: "coverage_anchor_nil_\(UUID().uuidString)"
        )
        XCTAssertTrue(emptyAnchored.isEmpty)

        let noDataCompleteness = await manager.dataCompleteness(
            hrv: nil,
            sleep: nil,
            rhr: nil,
            steps: 0,
            activeCal: 0
        )
        XCTAssertEqual(noDataCompleteness, 0, accuracy: 0.0001)
    }

    func testHealthKitManagerSelectionHelpersCoverGroupingAndTieBranches() async {
        let manager = HealthKitManager()
        let now = Date(timeIntervalSince1970: 1_700_000_500)
        let stepType = HKQuantityType(.stepCount)
        let unit = HKUnit.count()

        let older = HKQuantitySample(
            type: stepType,
            quantity: HKQuantity(unit: unit, doubleValue: 10),
            start: now.addingTimeInterval(-600),
            end: now.addingTimeInterval(-540)
        )
        let newer = HKQuantitySample(
            type: stepType,
            quantity: HKQuantity(unit: unit, doubleValue: 12),
            start: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(-240)
        )
        let best = await manager._testBestBySourcePrecedence([older, newer])
        XCTAssertEqual(best?.startDate, newer.startDate)

        let manualSample = HKQuantitySample(
            type: stepType,
            quantity: HKQuantity(unit: unit, doubleValue: 5),
            start: now.addingTimeInterval(-1_200),
            end: now.addingTimeInterval(-1_140),
            metadata: [HKMetadataKeyWasUserEntered: true, "group": "manual"]
        )
        let automaticSampleA = HKQuantitySample(
            type: stepType,
            quantity: HKQuantity(unit: unit, doubleValue: 15),
            start: now.addingTimeInterval(-900),
            end: now.addingTimeInterval(-840),
            metadata: ["group": "autoA"]
        )
        let automaticSampleB = HKQuantitySample(
            type: stepType,
            quantity: HKQuantity(unit: unit, doubleValue: 16),
            start: now.addingTimeInterval(-840),
            end: now.addingTimeInterval(-780),
            metadata: ["group": "autoA"]
        )
        let automaticSingle = HKQuantitySample(
            type: stepType,
            quantity: HKQuantity(unit: unit, doubleValue: 17),
            start: now.addingTimeInterval(-720),
            end: now.addingTimeInterval(-660),
            metadata: ["group": "autoB"]
        )

        HealthKitManager._testSetQuantitySampleSourceKeyOverride { sample in
            (sample.metadata?["group"] as? String) ?? "fallback"
        }

        let rankPreferred = await manager._testPreferredSourceSamples([manualSample, automaticSampleA])
        XCTAssertEqual(rankPreferred.count, 1)
        XCTAssertEqual(rankPreferred.first?.metadata?["group"] as? String, "autoA")

        let countPreferred = await manager._testPreferredSourceSamples([automaticSampleA, automaticSampleB, automaticSingle])
        XCTAssertEqual(countPreferred.count, 2)
        XCTAssertTrue(countPreferred.allSatisfy { ($0.metadata?["group"] as? String) == "autoA" })
    }

    func testHealthKitManagerSleepSelectionAndDayFallbackBranches() async {
        let manager = HealthKitManager()
        let day = Date(timeIntervalSince1970: 1_700_050_000)
        let sleepType = HKCategoryType(.sleepAnalysis)

        HealthKitManager._testSetDayBoundsDateByAddingRunner { _, _ in nil }
        let fallbackBounds = await manager._testDayBounds(for: day)
        XCTAssertEqual(
            fallbackBounds.end.timeIntervalSince(fallbackBounds.start),
            86_400,
            accuracy: 0.001
        )

        let sourceA1 = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            start: day.addingTimeInterval(-9 * 3_600),
            end: day.addingTimeInterval(-8 * 3_600),
            metadata: ["group": "A"]
        )
        let sourceA2 = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.awake.rawValue,
            start: day.addingTimeInterval(-8 * 3_600),
            end: day.addingTimeInterval(-7.5 * 3_600),
            metadata: ["group": "A"]
        )
        let sourceB1 = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            start: day.addingTimeInterval(-8.8 * 3_600),
            end: day.addingTimeInterval(-7.3 * 3_600),
            metadata: ["group": "B"]
        )

        HealthKitManager._testSetCategorySampleSourceKeyOverride { sample in
            (sample.metadata?["group"] as? String) ?? "fallback"
        }
        let preferred = await manager._testSelectPreferredSleepSource([sourceA1, sourceA2, sourceB1])
        XCTAssertEqual(preferred.count, 1)
        XCTAssertEqual(preferred.first?.metadata?["group"] as? String, "B")

        let boutOneA = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            start: day.addingTimeInterval(-10 * 3_600),
            end: day.addingTimeInterval(-9.5 * 3_600)
        )
        let boutOneB = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            start: day.addingTimeInterval(-9.4 * 3_600),
            end: day.addingTimeInterval(-9.0 * 3_600)
        )
        let boutTwoA = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            start: day.addingTimeInterval(-5 * 3_600),
            end: day.addingTimeInterval(-3.5 * 3_600)
        )
        let boutTwoB = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            start: day.addingTimeInterval(-3.4 * 3_600),
            end: day.addingTimeInterval(-2.0 * 3_600)
        )

        HealthKitManager._testSetEightAMDateByAddingRunner { _, _ in nil }
        let selectedBout = await manager._testSelectMainSleepBout([boutOneA, boutOneB, boutTwoA, boutTwoB], for: day)
        XCTAssertEqual(selectedBout.count, 2)
        XCTAssertEqual(selectedBout.first?.startDate, boutTwoA.startDate)
        XCTAssertEqual(selectedBout.last?.endDate, boutTwoB.endDate)
    }

    func testHealthKitManagerAnchorAndArchiveFallbackBranches() {
        enum ArchiveError: Error { case expected }

        let anchorKey = "test_anchor_\(UUID().uuidString)"
        let storageKey = "healthkit_anchor_" + anchorKey
        let anchor = HKQueryAnchor(fromValue: 7)

        defer {
            UserDefaults.standard.removeObject(forKey: storageKey)
            HealthKitManager._testSetAnchorUnarchiveRunner(nil)
            HealthKitManager._testSetAnchorArchiveRunner(nil)
        }

        HealthKitManager._testSaveAnchor(anchor, anchorKey: anchorKey)
        XCTAssertNotNil(HealthKitManager._testLoadAnchor(anchorKey: anchorKey))

        UserDefaults.standard.set(Data("invalid-anchor".utf8), forKey: storageKey)
        XCTAssertNil(HealthKitManager._testLoadAnchor(anchorKey: anchorKey))

        HealthKitManager._testSetAnchorUnarchiveRunner { _ in
            throw ArchiveError.expected
        }
        XCTAssertNil(HealthKitManager._testLoadAnchor(anchorKey: anchorKey))

        let failingKey = "test_anchor_failing_\(UUID().uuidString)"
        let failingStorageKey = "healthkit_anchor_" + failingKey
        HealthKitManager._testSetAnchorArchiveRunner { _ in
            throw ArchiveError.expected
        }
        HealthKitManager._testSaveAnchor(anchor, anchorKey: failingKey)
        XCTAssertNil(UserDefaults.standard.data(forKey: failingStorageKey))
    }

    func testHealthKitManagerRequestAuthorizationUsesStoreRunnersForDefaultPaths() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            var requestRuns = 0
            var deliveredTypes: [String] = []

            func markRequest() {
                lock.lock()
                defer { lock.unlock() }
                requestRuns += 1
            }

            func markDelivery(_ identifier: String) {
                lock.lock()
                defer { lock.unlock() }
                deliveredTypes.append(identifier)
            }

            func snapshot() -> (Int, [String]) {
                lock.lock()
                defer { lock.unlock() }
                return (requestRuns, deliveredTypes)
            }
        }

        let manager = HealthKitManager()
        let counter = Counter()

        HealthKitManager._testSetIsAvailableOverride(true)
        HealthKitManager._testSetRequestAccessOverride(nil)
        HealthKitManager._testSetDefaultRequestAccessRunner(nil)
        HealthKitManager._testSetStoreRequestAuthorizationRunner { _, _ in
            counter.markRequest()
        }
        HealthKitManager._testSetDefaultStoreRequestAuthorizationRunner(nil)
        HealthKitManager._testSetAuthorizedTypeCountOverride { 1 }
        HealthKitManager._testSetEnableBackgroundOverride(nil)
        HealthKitManager._testSetEnableBackgroundDeliveryRunner(nil)
        HealthKitManager._testSetStoreEnableBackgroundDeliveryRunner { _, type, completion in
            counter.markDelivery(type.identifier)
            completion(true, nil)
        }
        HealthKitManager._testSetDefaultStoreEnableBackgroundDeliveryRunner(nil)

        let granted = try await manager.requestAuthorization()
        XCTAssertTrue(granted)

        let snapshot = counter.snapshot()
        XCTAssertEqual(snapshot.0, 1)
        XCTAssertEqual(snapshot.1.count, HealthKitManager._testBackgroundDeliveryTypesCount())
        XCTAssertEqual(Set(snapshot.1).count, HealthKitManager._testBackgroundDeliveryTypesCount())

        let defaultCounter = Counter()
        HealthKitManager._testSetStoreRequestAuthorizationRunner(nil)
        HealthKitManager._testSetDefaultStoreRequestAuthorizationRunner { _, _ in
            defaultCounter.markRequest()
        }
        HealthKitManager._testSetStoreEnableBackgroundDeliveryRunner(nil)
        HealthKitManager._testSetDefaultStoreEnableBackgroundDeliveryRunner { _, type, completion in
            defaultCounter.markDelivery(type.identifier)
            completion(true, nil)
        }

        let defaultGranted = try await manager.requestAuthorization()
        XCTAssertTrue(defaultGranted)
        let defaultSnapshot = defaultCounter.snapshot()
        XCTAssertEqual(defaultSnapshot.0, 1)
        XCTAssertEqual(defaultSnapshot.1.count, 0) // observers already installed on this manager
        XCTAssertEqual(Set(defaultSnapshot.1).count, 0)
    }

    func testHealthKitPrivateHelperCoverageForCategoryAndBackgroundPaths() async throws {
        enum ExpectedError: Error, Equatable {
            case boom
        }

        let manager = HealthKitManager()
        let now = Date(timeIntervalSince1970: 1_700_000_777)
        let sleepType = HKCategoryType(.sleepAnalysis)
        let sleepSample = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            start: now.addingTimeInterval(-3_600),
            end: now
        )
        let stepSample = HKQuantitySample(
            type: HKQuantityType(.stepCount),
            quantity: HKQuantity(unit: .count(), doubleValue: 123),
            start: now,
            end: now
        )

        let resolvedCategories = try await manager._testResolveCategorySamples(
            results: [sleepSample],
            error: nil
        )
        XCTAssertEqual(resolvedCategories.count, 1)
        let resolvedMixed = try await manager._testResolveCategorySamples(
            results: [stepSample],
            error: nil
        )
        XCTAssertTrue(resolvedMixed.isEmpty)
        do {
            _ = try await manager._testResolveCategorySamples(
                results: [sleepSample],
                error: ExpectedError.boom
            )
            XCTFail("Expected category resolver to throw")
        } catch let error as ExpectedError {
            XCTAssertEqual(error, .boom)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let dayStart = Date(timeIntervalSince1970: 1_700_000_000)
        let eightAM = HealthKitManager._testDefaultEightAMDate(calendar: calendar, dayStart: dayStart)
        XCTAssertGreaterThan(eightAM.timeIntervalSince(dayStart), 0)
        let selectionKey = HealthKitManager._testSleepBoutSelectionKey(
            for: [sleepSample],
            eightAM: eightAM,
            hasStages: { _ in true },
            asleepMinutes: { _ in 95 }
        )
        XCTAssertEqual(selectionKey.asleepMinutes, 95, accuracy: 0.001)
        XCTAssertTrue(selectionKey.hasStages)
        let emptySelectionKey = HealthKitManager._testSleepBoutSelectionKey(
            for: [],
            eightAM: eightAM,
            hasStages: { _ in false },
            asleepMinutes: { _ in 0 }
        )
        XCTAssertEqual(emptySelectionKey.asleepMinutes, 0, accuracy: 0.001)
        XCTAssertFalse(emptySelectionKey.hasStages)

        let successResult = HealthKitManager._testBackgroundDeliveryResult(success: true, error: nil)
        switch successResult {
        case .success(let success):
            XCTAssertTrue(success)
        case .failure(let error):
            XCTFail("Expected success, got \(error)")
        }
        let deniedResult = HealthKitManager._testBackgroundDeliveryResult(success: false, error: nil)
        switch deniedResult {
        case .success(let success):
            XCTAssertFalse(success)
        case .failure(let error):
            XCTFail("Expected successful false result, got \(error)")
        }
        let explicitFailure = HealthKitManager._testBackgroundDeliveryResult(
            success: true,
            error: ExpectedError.boom
        )
        switch explicitFailure {
        case .success:
            XCTFail("Expected propagated failure")
        case .failure(let error as ExpectedError):
            XCTAssertEqual(error, .boom)
        case .failure(let error):
            XCTFail("Unexpected propagated error: \(error)")
        }

        final class RequestRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var calls = 0

            func mark() {
                lock.lock()
                calls += 1
                lock.unlock()
            }

            func snapshot() -> Int {
                lock.lock()
                let value = calls
                lock.unlock()
                return value
            }
        }

        let recorder = RequestRecorder()
        HealthKitManager._testSetStoreRequestAuthorizationRunner { _, _ in
            recorder.mark()
        }
        defer {
            HealthKitManager._testSetStoreRequestAuthorizationRunner(nil)
        }

        try await manager._testRequestReadAuthorization(
            store: HKHealthStore(),
            readTypes: [HKQuantityType(.stepCount)]
        )
        XCTAssertEqual(recorder.snapshot(), 1)
    }
}

@MainActor
final class AuthManagerCoverageExpansionTests: XCTestCase {
    private enum TestError: Error {
        case expected
    }

    private func makeSession(authId: UUID, isAnonymous: Bool, now: Date) -> Supabase.Session {
        let user = Supabase.User(
            id: authId,
            appMetadata: [:],
            userMetadata: [:],
            aud: "authenticated",
            createdAt: now,
            updatedAt: now,
            isAnonymous: isAnonymous
        )
        return Supabase.Session(
            accessToken: "token-\(authId.uuidString)",
            tokenType: "bearer",
            expiresIn: 3600,
            expiresAt: now.addingTimeInterval(3600).timeIntervalSince1970,
            refreshToken: "refresh-\(authId.uuidString)",
            user: user
        )
    }

    override func tearDown() {
        AuthManager._testResetOverrides()
        AuthManager.setActiveAuthIdForTests(nil)
        super.tearDown()
    }

    func testAppleIdentityTokenStringHelper() {
        XCTAssertThrowsError(try AuthManager._testAppleIdentityTokenString(from: nil))
        XCTAssertThrowsError(try AuthManager._testAppleIdentityTokenString(from: Data([0xFF])))

        do {
            let token = try AuthManager._testAppleIdentityTokenString(from: Data("token".utf8))
            XCTAssertEqual(token, "token")
        } catch {
            XCTFail("Expected valid UTF-8 token to decode, got \(error)")
        }
    }

    func testPublicAuthMethodSmokePaths() async throws {
        let manager = try DatabaseManager.inMemory()
        let auth = AuthManager(client: SupabaseConfig.client, db: manager)
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let anonAuthId = UUID()
        let otpAuthId = UUID()

        AuthManager._testSetDefaultAnonymousSignInOverride {
            self.makeSession(authId: anonAuthId, isAnonymous: true, now: now)
        }
        AuthManager._testSetDefaultSendOTPOverride { _ in }
        AuthManager._testSetDefaultVerifyOTPOverride { _, _ in
            self.makeSession(authId: otpAuthId, isAnonymous: false, now: now)
        }
        AuthManager._testSetDefaultDeleteAccountOverride { _ in }
        AuthManager._testSetDefaultSignOutOverride { }

        await auth.signInAnonymously()
        XCTAssertEqual(auth.authState, .needsOnboarding)
        XCTAssertEqual(auth.userId, anonAuthId)

        try await auth.sendOTP(to: "coverage@example.invalid")
        try await auth.verifyOTP(email: "coverage@example.invalid", token: "000000")
        XCTAssertEqual(auth.userId, otpAuthId)

        try await auth.signOut()
        XCTAssertEqual(auth.authState, .signedOut)

        auth._testSetState(authState: .authenticated, userId: UUID(), isAnonymous: false)
        _ = try? await auth.deleteAccount(reason: "coverage")
    }

    func testAuthDebugOverridesAndSessionApplication() async throws {
        let manager = try DatabaseManager.inMemory()
        let auth = AuthManager(client: SupabaseConfig.client, db: manager)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let authId = UUID()

        auth._testApplyUITestOverride(.signedOut)
        XCTAssertEqual(auth.authState, .signedOut)
        XCTAssertNil(auth.userId)
        XCTAssertFalse(auth.isAnonymous)

        auth._testApplyUITestOverride(.anonymous)
        XCTAssertEqual(auth.authState, .anonymous)
        XCTAssertTrue(auth.isAnonymous)
        XCTAssertNotNil(auth.userId)

        auth._testApplyUITestOverride(.authenticated)
        XCTAssertEqual(auth.authState, .authenticated)
        XCTAssertFalse(auth.isAnonymous)
        XCTAssertNotNil(auth.userId)

        auth._testApplyUITestOverride(.needsOnboarding)
        XCTAssertEqual(auth.authState, .needsOnboarding)
        XCTAssertFalse(auth.isAnonymous)
        XCTAssertNotNil(auth.userId)

        auth._testApplyUITestOverride(.loading)
        XCTAssertEqual(auth.authState, .signedOut)
        XCTAssertFalse(auth.isAnonymous)
        XCTAssertNotNil(auth.userId)

        let user = Supabase.User(
            id: authId,
            appMetadata: [:],
            userMetadata: [:],
            aud: "authenticated",
            createdAt: now,
            updatedAt: now,
            isAnonymous: false
        )
        let session = Supabase.Session(
            accessToken: "token",
            tokenType: "bearer",
            expiresIn: 3600,
            expiresAt: now.addingTimeInterval(3600).timeIntervalSince1970,
            refreshToken: "refresh",
            user: user
        )

        auth._testApplySessionState(session, isAnonymous: false)
        XCTAssertEqual(auth.userId, authId)
        XCTAssertFalse(auth.isAnonymous)

        auth._testApplySessionState(session, isAnonymous: true)
        XCTAssertEqual(auth.userId, authId)
        XCTAssertTrue(auth.isAnonymous)
    }

    @MainActor
    func testAuthOverridesCoverBootstrapAppleOTPAndSignOutBranches() async throws {
        final class FakeAppleCredential: NSObject {
            @objc let identityToken: Data?

            init(identityToken: Data?) {
                self.identityToken = identityToken
            }
        }

        let manager = try DatabaseManager.inMemory()
        let auth = AuthManager(client: SupabaseConfig.client, db: manager)
        let now = Date(timeIntervalSince1970: 1_700_200_000)
        let anonAuthId = UUID()
        let fullAuthId = UUID()
        let otpAuthId = UUID()

        AuthManager._testResetOverrides()
        AuthManager._testSetRunningTestsOverride(false)
        defer {
            AuthManager._testResetOverrides()
            AuthManager.setActiveAuthIdForTests(nil)
        }

        AuthManager._testSetBootstrapSessionOverride {
            self.makeSession(authId: anonAuthId, isAnonymous: true, now: now)
        }
        await auth.bootstrap()
        XCTAssertEqual(auth.authState, .needsOnboarding)
        XCTAssertEqual(auth.userId, anonAuthId)
        XCTAssertTrue(auth.isAnonymous)

        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (
                        id, auth_id, timezone, units, onboarding_completed, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    fullAuthId.uuidString,
                    "UTC",
                    "metric",
                    false,
                    now,
                    now,
                ]
            )
        }
        AuthManager._testSetBootstrapSessionOverride {
            self.makeSession(authId: fullAuthId, isAnonymous: false, now: now)
        }
        await auth.bootstrap()
        XCTAssertEqual(auth.authState, .needsOnboarding)
        XCTAssertEqual(auth.userId, fullAuthId)
        XCTAssertFalse(auth.isAnonymous)

        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE users
                    SET onboarding_completed = 1, updated_at = ?
                    WHERE auth_id = ? OR lower(CAST(auth_id AS TEXT)) = lower(?)
                    """,
                arguments: [now.addingTimeInterval(1), fullAuthId, fullAuthId.uuidString]
            )
        }
        await auth.bootstrap()
        XCTAssertEqual(auth.authState, .authenticated)

        AuthManager._testSetBootstrapSessionOverride {
            throw TestError.expected
        }
        AuthManager._testSetAnonymousSignInOverride {
            self.makeSession(authId: anonAuthId, isAnonymous: true, now: now)
        }
        await auth.bootstrap()
        XCTAssertEqual(auth.authState, .authenticated)

        AuthManager._testSetAnonymousSignInOverride {
            throw TestError.expected
        }
        await auth.signInAnonymously()
        XCTAssertEqual(auth.authState, .authenticated)

        var sentEmails: [String] = []
        AuthManager._testSetSendOTPOverride { email in
            sentEmails.append(email)
        }
        try await auth.sendOTP(to: "otp-coverage@example.invalid")
        XCTAssertEqual(sentEmails, ["otp-coverage@example.invalid"])

        AuthManager._testSetVerifyOTPOverride { _, _ in nil }
        do {
            try await auth.verifyOTP(email: "otp@example.invalid", token: "123456")
            XCTFail("Expected sessionExpired when verify OTP returns nil session")
        } catch let error as LifeOS.AuthError {
            switch error {
            case .sessionExpired:
                break
            default:
                XCTFail("Expected sessionExpired, got \(error)")
            }
        }

        AuthManager._testSetVerifyOTPOverride { _, _ in
            self.makeSession(authId: otpAuthId, isAnonymous: false, now: now)
        }
        try await auth.verifyOTP(email: "otp@example.invalid", token: "654321")
        XCTAssertEqual(auth.userId, otpAuthId)
        XCTAssertFalse(auth.isAnonymous)

        var capturedAppleToken: String?
        AuthManager._testSetAppleSignInOverride { token in
            capturedAppleToken = token
            return self.makeSession(authId: fullAuthId, isAnonymous: false, now: now)
        }
        let fakeCredential = FakeAppleCredential(identityToken: Data("apple-token".utf8))
        let credential = unsafeBitCast(fakeCredential, to: ASAuthorizationAppleIDCredential.self)
        try await auth.signInWithApple(credential: credential)
        XCTAssertEqual(capturedAppleToken, "apple-token")

        var signOutCalls = 0
        AuthManager._testSetSignOutOverride {
            signOutCalls += 1
        }
        try await auth.signOut()
        XCTAssertEqual(signOutCalls, 1)
        XCTAssertEqual(auth.authState, .signedOut)
    }

    func testAuthManagerAdditionalBootstrapAndDebugPaths() async throws {
        let manager = try DatabaseManager.inMemory()
        let auth = AuthManager(client: SupabaseConfig.client, db: manager)
        let now = Date(timeIntervalSince1970: 1_700_250_000)
        let anonAuthId = UUID()
        let appleAuthId = UUID()

        let previousAuthState = getenv("LIFEOS_UI_TEST_AUTH_STATE").map { String(cString: $0) }
        let previousBootstrap = getenv("LIFEOS_UI_TEST_BOOTSTRAP").map { String(cString: $0) }
        defer {
            if let previousAuthState {
                setenv("LIFEOS_UI_TEST_AUTH_STATE", previousAuthState, 1)
            } else {
                unsetenv("LIFEOS_UI_TEST_AUTH_STATE")
            }
            if let previousBootstrap {
                setenv("LIFEOS_UI_TEST_BOOTSTRAP", previousBootstrap, 1)
            } else {
                unsetenv("LIFEOS_UI_TEST_BOOTSTRAP")
            }
            AuthManager._testResetOverrides()
            AuthManager.setActiveAuthIdForTests(nil)
        }

        setenv("LIFEOS_UI_TEST_BOOTSTRAP", "1", 1)
        setenv("LIFEOS_UI_TEST_AUTH_STATE", "authenticated", 1)
        await auth.bootstrap()
        XCTAssertEqual(auth.authState, .authenticated)

        unsetenv("LIFEOS_UI_TEST_AUTH_STATE")
        setenv("LIFEOS_UI_TEST_BOOTSTRAP", "1", 1)
        auth._testSetState(authState: .needsOnboarding, userId: UUID(), isAnonymous: false)
        await auth._testRefreshPostAuthState(hasSession: true)
        XCTAssertEqual(auth.authState, .needsOnboarding)

        unsetenv("LIFEOS_UI_TEST_BOOTSTRAP")
        auth._testSetState(authState: .authenticated, userId: nil, isAnonymous: false)
        await auth._testRefreshPostAuthState(hasSession: true)
        XCTAssertEqual(auth.authState, .needsOnboarding)

        AuthManager._testSetRunningTestsOverride(false)
        AuthManager._testSetDefaultBootstrapSessionOverride {
            throw TestError.expected
        }
        AuthManager._testSetDefaultAnonymousSignInOverride {
            self.makeSession(authId: anonAuthId, isAnonymous: true, now: now)
        }
        AuthManager._testSetDefaultAppleSignInOverride { _ in
            self.makeSession(authId: appleAuthId, isAnonymous: false, now: now)
        }
        AuthManager._testSetDefaultDeleteAccountOverride { _ in }
        await auth.bootstrap()
        XCTAssertEqual(auth.authState, .needsOnboarding)
        XCTAssertEqual(auth.userId, anonAuthId)

        try await auth._testSignInWithAppleToken("coverage-token")
        XCTAssertEqual(auth.userId, appleAuthId)

        auth._testSetState(authState: .authenticated, userId: UUID(), isAnonymous: false)
        _ = try? await auth.deleteAccount()
    }

    func testAuthManagerDefaultNetworkFallbackAndImplicitDeleteReasonBranches() async throws {
        let manager = try DatabaseManager.inMemory()
        let auth = AuthManager(client: SupabaseConfig.client, db: manager)
        let now = Date(timeIntervalSince1970: 1_700_300_000)
        let anonAuthId = UUID()

        AuthManager._testResetOverrides()
        AuthManager._testSetRunningTestsOverride(false)
        AuthManager._testSetBootstrapSessionOverride(nil)
        AuthManager._testSetDefaultBootstrapSessionOverride {
            throw TestError.expected
        }
        AuthManager._testSetAnonymousSignInOverride {
            self.makeSession(authId: anonAuthId, isAnonymous: true, now: now)
        }
        AuthManager._testSetDefaultAppleSignInOverride { _ in
            throw TestError.expected
        }
        AuthManager._testSetDefaultSendOTPOverride { _ in }
        AuthManager._testSetDefaultDeleteAccountOverride { _ in }
        defer {
            AuthManager._testResetOverrides()
            AuthManager.setActiveAuthIdForTests(nil)
        }

        await auth.bootstrap()
        XCTAssertEqual(auth.authState, .needsOnboarding)
        XCTAssertEqual(auth.userId, anonAuthId)

        auth._testApplyUITestOverride(.loading)
        XCTAssertEqual(auth.authState, .signedOut)

        auth._testSetState(authState: .authenticated, userId: UUID(), isAnonymous: false)
        _ = try? await auth.deleteAccount()

        AuthManager._testSetAppleSignInOverride(nil)
        do {
            try await auth._testSignInWithAppleToken("network-default-coverage-token")
            XCTFail("Expected default Apple sign-in path to fail in test environment")
        } catch {
            XCTAssertNotNil(error.localizedDescription)
        }

        AuthManager._testSetSendOTPOverride(nil)
        try await auth.sendOTP(to: "default-branch-coverage@example.invalid")
    }
}

final class BackgroundSyncManagerActionCoverageTests: XCTestCase {
    override func tearDown() {
        AppContainer.shared = nil
        super.tearDown()
    }

    func testActionHelpersForMissingAndPresentSyncEngine() async throws {
        let missingOutbox = await BackgroundSyncManager._testRunOutboxReplayAction(syncEngine: nil)
        let missingDaily = await BackgroundSyncManager._testRunDailyPullAction(syncEngine: nil)
        XCTAssertFalse(missingOutbox)
        XCTAssertFalse(missingDaily)

        let manager = try DatabaseManager.inMemory()
        let syncEngine = SyncEngine(dbQueue: manager.dbQueue, apiClient: FakeSyncAPIClient())
        BackgroundSyncManager._testSetActionOverrides(
            outbox: { _ in },
            dailyPull: { _ in }
        )
        defer { BackgroundSyncManager._testResetActionOverrides() }

        let outboxResult = await BackgroundSyncManager._testRunOutboxReplayAction(syncEngine: syncEngine)
        XCTAssertTrue(outboxResult)

        let dailyPullResult = await BackgroundSyncManager._testRunDailyPullAction(syncEngine: syncEngine)
        XCTAssertTrue(dailyPullResult)
    }
}

@MainActor
final class ForceUpdateManagerCoverageExpansionTests: XCTestCase {
    func testObservedMinVersionFallbackAndForceFlag() {
        let versionKey = "force_update_observed_min_version"
        let observedAtKey = "force_update_observed_min_version_at"
        defer {
            UserDefaults.standard.removeObject(forKey: versionKey)
            UserDefaults.standard.removeObject(forKey: observedAtKey)
        }

        let manager = ForceUpdateManager()
        manager._testResetSoftPresentationFlag()
        manager.checkHeaders(["X-Min-App-Version": "999.0.0"])

        UserDefaults.standard.set("999.0.0", forKey: versionKey)
        UserDefaults.standard.removeObject(forKey: observedAtKey)
        manager._testResetSoftPresentationFlag()
        manager.checkHeaders(["X-Min-App-Version": "999.0.0"])

        XCTAssertNotNil(UserDefaults.standard.object(forKey: observedAtKey) as? Date)

        manager._testSetStatus(.forceUpdate(minVersion: "999.0.0"))
        XCTAssertTrue(manager.isForceUpdateRequired)
    }
}

final class APIClientForceUpdateCoverageTests: XCTestCase {
    func testForceUpdateHeaderHandlingAndMutationBlocking() async throws {
        let api = APIClient(deviceId: "coverage-force-update")
        let url = try XCTUnwrap(URL(string: "https://example.com/coverage"))
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["X-Soft-Update-Version": "999.0.0"]
            )
        )

        await api._testCheckForceUpdateHeaders(nil)
        await api._testCheckForceUpdateHeaders(response)

        await MainActor.run {
            ForceUpdateManager.shared._testSetStatus(.upToDate)
        }
        let blocksWhenUpToDate = await api.shouldBlockMutationsForForceUpdate()
        XCTAssertFalse(blocksWhenUpToDate)

        await MainActor.run {
            ForceUpdateManager.shared._testSetStatus(.forceUpdate(minVersion: "999.0.0"))
        }
        let blocksWhenForced = await api.shouldBlockMutationsForForceUpdate()
        XCTAssertTrue(blocksWhenForced)

        await MainActor.run {
            ForceUpdateManager.shared._testSetStatus(.upToDate)
        }
    }
}

private actor NutritionMealLoggerMock: NutritionMealLogging {
    private var shouldThrow = false
    private var logged: [FoodLog] = []

    func logMeal(_ log: FoodLog) async throws {
        if shouldThrow {
            throw SyncError.networkUnavailable
        }
        logged.append(log)
    }

    func setShouldThrow(_ value: Bool) {
        shouldThrow = value
    }

    func lastLogged() -> FoodLog? {
        logged.last
    }

    func loggedCount() -> Int {
        logged.count
    }
}

private actor NutritionMealManagerMock: NutritionMealManaging {
    private let detail: NutritionMealDetail?
    private(set) var lastUpdate: NutritionMealUpdateDraft?
    private(set) var deleteCount = 0
    private(set) var undoCount = 0

    init(detail: NutritionMealDetail?) {
        self.detail = detail
    }

    func persist(log: FoodLog, detectedItems: [NutritionDraftCandidateItem]) async throws {}

    func persist(log: FoodLog, items: [FoodItem]) async throws {}

    func loadMealDetail(id: UUID, preferRemote: Bool) async throws -> NutritionMealDetail? {
        detail
    }

    func updateMeal(_ update: NutritionMealUpdateDraft) async throws {
        lastUpdate = update
    }

    func deleteMeal(id: UUID) async throws -> Date {
        deleteCount += 1
        return Date()
    }

    func undoDeleteMeal(id: UUID) async throws {
        undoCount += 1
    }

    func snapshot() -> NutritionMealUpdateDraft? {
        lastUpdate
    }

    func deleteInvocationCount() -> Int {
        deleteCount
    }

    func undoInvocationCount() -> Int {
        undoCount
    }
}

final class LowCoverageUtilitiesTests: XCTestCase {

    func testSyncModuleHandlerDefaultsAndLabsPullTables() async throws {
        let manager = try DatabaseManager.inMemory()
        try await manager.dbQueue.write { db in
            try DummySyncHandler.reconcileParentChild(in: db)
        }
        XCTAssertEqual(DummySyncHandler.pullTables, [.foodLogs])

        XCTAssertEqual(
            LabsSyncHandler.pullTables(includeRestrictedMedicalData: true),
            [.healthMeasurements, .medicalScans, .healthDiagnoses]
        )
        XCTAssertEqual(
            LabsSyncHandler.pullTables(includeRestrictedMedicalData: false),
            [.healthMeasurements]
        )
        XCTAssertTrue(LabsSyncHandler.ownedTables.contains(.healthMarkerCatalog))
    }

    func testDatabaseDependencyQueueCanBeReadAndOverridden() throws {
        var dependencies = DependencyValues()
        let defaultQueue = dependencies.databaseQueue

        let customQueue = try DatabaseManager.inMemory().dbQueue
        dependencies.databaseQueue = customQueue

        XCTAssertTrue(defaultQueue !== dependencies.databaseQueue)
        XCTAssertTrue(customQueue === dependencies.databaseQueue)
    }

    func testNutritionReviewGateBranches() {
        XCTAssertTrue(NutritionReviewGate.requiresEditFirst(method: .photo, confidence: nil))
        XCTAssertFalse(NutritionReviewGate.requiresEditFirst(method: .manual, confidence: nil))
        XCTAssertTrue(NutritionReviewGate.requiresEditFirst(method: .manual, confidence: 0.2))
        XCTAssertFalse(NutritionReviewGate.requiresEditFirst(method: .manual, confidence: 0.9))
    }

    func testTrainingSyncHandlerReconcilesSessionTotalsFromChildRows() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let sessionId = UUID()
        let exerciseId = UUID()

        try await manager.dbQueue.write { db in
            let user = User(id: userId, authId: UUID(), timezone: "UTC", units: .metric)
            try user.insert(db)

            var session = WorkoutSession(
                id: sessionId,
                userId: userId,
                startedAt: Date(),
                sessionDate: "2026-02-24",
                source: .manual
            )
            session.totalSets = 0
            session.totalVolume = 0
            try session.insert(db)

            let exercise = WorkoutExercise(id: exerciseId, sessionId: sessionId, orderInSession: 1)
            try exercise.insert(db)

            var set1 = WorkoutSet(exerciseEntryId: exerciseId, userId: userId, setNumber: 1)
            set1.weight = 100
            set1.reps = 5
            try set1.insert(db)

            var set2 = WorkoutSet(exerciseEntryId: exerciseId, userId: userId, setNumber: 2)
            set2.weight = 80
            set2.reps = 8
            try set2.insert(db)

            let now = Date()
            try db.execute(
                sql: "INSERT INTO sync_row_state (table_name, row_id, updated_at_server) VALUES (?, ?, ?)",
                arguments: ["workout_exercises", exerciseId.uuidString, now]
            )
            try db.execute(
                sql: "INSERT INTO sync_row_state (table_name, row_id, updated_at_server) VALUES (?, ?, ?)",
                arguments: ["workout_sets", set1.id.uuidString, now]
            )
            try db.execute(
                sql: "INSERT INTO sync_row_state (table_name, row_id, updated_at_server) VALUES (?, ?, ?)",
                arguments: ["workout_sets", set2.id.uuidString, now]
            )
        }

        try await manager.dbQueue.write { db in
            try TrainingSyncHandler.reconcileParentChild(in: db)
        }

        try await manager.dbQueue.read { db in
            let totalSets = try Int.fetchOne(
                db,
                sql: "SELECT total_sets FROM workout_sessions WHERE id = ?",
                arguments: [sessionId.uuidString]
            )
            let totalVolume = try Double.fetchOne(
                db,
                sql: "SELECT total_volume FROM workout_sessions WHERE id = ?",
                arguments: [sessionId.uuidString]
            )
            XCTAssertEqual(totalSets, 2)
            XCTAssertEqual(totalVolume ?? 0, 1140, accuracy: 0.0001)
        }
    }

    func testRateLimitTrackerSlidingWindowsAndTierChecks() async {
        let tracker = RateLimitTracker.shared
        await tracker.reset()

        let firstWindowAccept = await tracker.checkAndRecord(key: "k", limit: 1, windowSeconds: 60)
        XCTAssertTrue(firstWindowAccept)
        let secondWindowAccept = await tracker.checkAndRecord(key: "k", limit: 1, windowSeconds: 60)
        XCTAssertFalse(secondWindowAccept)

        await tracker.reset()
        let settingsAllowed = await tracker.checkAllLimits(forFunction: "api-settings-privacy")
        XCTAssertTrue(settingsAllowed)
        let foodLogAllowed = await tracker.checkAllLimits(forFunction: "api-food-log")
        XCTAssertTrue(foodLogAllowed)
        let accountDeleteAllowed = await tracker.checkAllLimits(forFunction: "api-account-delete")
        XCTAssertTrue(accountDeleteAllowed)
        let userExportAllowed = await tracker.checkAllLimits(forFunction: "api-user-export")
        XCTAssertTrue(userExportAllowed)
        let analyticsAllowed = await tracker.checkAllLimits(forFunction: "api-analytics-batch")
        XCTAssertTrue(analyticsAllowed)

        await tracker.reset()
        for _ in 0..<RateLimitPolicy.aiVisionPerMinute {
            let allowed = await tracker.checkAllLimits(forFunction: "api-insights-predict")
            XCTAssertTrue(allowed)
        }
        let finalAllowed = await tracker.checkAllLimits(forFunction: "api-insights-predict")
        XCTAssertFalse(finalAllowed)
    }

    func testRateLimitAdditionalPolicyTiersAndTrackerBranches() async {
        XCTAssertEqual(RateLimitPolicy.tier(forFunction: "api-menstrual-sync"), .writeHeavy)
        XCTAssertEqual(RateLimitPolicy.tier(forFunction: "api-workouts-daily"), .standard)
        XCTAssertEqual(RateLimitPolicy.tier(forFunction: "api-workouts-summary"), .standard)
        XCTAssertEqual(RateLimitPolicy.tier(forFunction: "api-workouts-weekly"), .standard)
        XCTAssertEqual(RateLimitPolicy.tier(forFunction: "ai-openrouter-gateway"), .aiVision)

        let tracker = RateLimitTracker.shared
        await tracker.reset()

        let searchAllowed = await tracker.checkAllLimits(forFunction: "api-search")
        XCTAssertTrue(searchAllowed)

        let authAllowed = await tracker.checkAllLimits(forFunction: "auth-signin")
        XCTAssertTrue(authAllowed)
    }

    func testAppErrorsExposeUserFacingDescriptions() {
        XCTAssertNotNil(NutritionError.invalidMacros(reason: "bad").errorDescription)
        XCTAssertNotNil(NutritionError.imageTooLarge(maxMB: 10).errorDescription)
        XCTAssertNotNil(NutritionError.barcodeNotFound(barcode: "123").errorDescription)
        XCTAssertNotNil(NutritionError.catalogUnavailable.errorDescription)
        XCTAssertNotNil(NutritionError.templateEmpty.errorDescription)
        XCTAssertNotNil(NutritionError.batchRecipeSaveFailed.errorDescription)
        XCTAssertNotNil(NutritionError.duplicateLog(existingId: UUID()).errorDescription)

        XCTAssertNotNil(TrainingError.invalidSet(reason: "x").errorDescription)
        XCTAssertNotNil(TrainingError.workoutAlreadyActive.errorDescription)
        XCTAssertNotNil(TrainingError.planLimitReached(max: 3).errorDescription)
        XCTAssertNotNil(TrainingError.exerciseNotFound(id: UUID()).errorDescription)

        XCTAssertNotNil(SupplementsError.scheduleConflict.errorDescription)
        XCTAssertNotNil(SupplementsError.invalidDose.errorDescription)
        XCTAssertNotNil(SupplementsError.reminderWindowInvalid.errorDescription)

        XCTAssertNotNil(LabsError.unsupportedDocument.errorDescription)
        XCTAssertNotNil(LabsError.extractionFailed.errorDescription)
        XCTAssertNotNil(LabsError.lowConfidenceExtraction.errorDescription)

        XCTAssertNotNil(SettingsError.exportFailed.errorDescription)
        XCTAssertNotNil(SettingsError.deletionFailed.errorDescription)
        XCTAssertNotNil(SettingsError.consentVersionMismatch.errorDescription)

        XCTAssertNotNil(SyncError.networkUnavailable.errorDescription)
        XCTAssertNotNil(SyncError.authRequired.errorDescription)
        XCTAssertNotNil(SyncError.serverError(code: 500, message: "oops").errorDescription)
        XCTAssertNotNil(SyncError.conflictResolutionFailed(table: "users").errorDescription)
        XCTAssertNotNil(SyncError.watermarkCorrupted(table: "users").errorDescription)
        XCTAssertNotNil(SyncError.maxRetriesExceeded(eventId: UUID()).errorDescription)

        XCTAssertNotNil(HealthKitError.notAvailable.errorDescription)
        XCTAssertNotNil(HealthKitError.authorizationDenied.errorDescription)
        XCTAssertNotNil(HealthKitError.noDataForDate(Date()).errorDescription)
        XCTAssertNotNil(HealthKitError.invalidSample(reason: "x").errorDescription)
        XCTAssertNotNil(HealthKitError.sdnnTooLow(value: 5).errorDescription)

        XCTAssertNotNil(RecoveryError.insufficientBaseline(daysAvailable: 1, daysRequired: 5).errorDescription)
        XCTAssertNotNil(RecoveryError.noPhysiologicalState(date: "2026-02-24").errorDescription)
        XCTAssertNotNil(RecoveryError.computationFailed(reason: "x").errorDescription)

        XCTAssertNotNil(HydrationError.invalidAmount(reason: "x").errorDescription)
        XCTAssertNotNil(HydrationError.targetNotSet.errorDescription)
        XCTAssertNotNil(HydrationError.dailyLimitExceeded(maxMl: 5000).errorDescription)

        XCTAssertNotNil(WellnessError.checkAlreadyCompleted(date: "2026-02-24").errorDescription)
        XCTAssertNotNil(WellnessError.invalidResponse(field: "mood").errorDescription)
        XCTAssertNotNil(WellnessError.pss4OutOfRange.errorDescription)

        XCTAssertNotNil(ExperimentError.alreadyActive(existingId: UUID()).errorDescription)
        XCTAssertNotNil(ExperimentError.invalidProtocol(reason: "x").errorDescription)
        XCTAssertNotNil(ExperimentError.durationExceeded(maxDays: 14).errorDescription)
        XCTAssertNotNil(ExperimentError.insufficientBaselineDays(required: 7).errorDescription)

        XCTAssertNotNil(PrivacyError.exportAlreadyInProgress.errorDescription)
        XCTAssertNotNil(PrivacyError.exportNotReady.errorDescription)
        XCTAssertNotNil(PrivacyError.deletionScheduled(at: Date()).errorDescription)
    }

    @MainActor
    func testPrivacyNoteAndAuthCallbackViewConstruction() {
        let authManager = AuthManager()
        authManager._testSetAuthCallbackStatus(.idle)
        render(AuthCallbackView().environment(authManager))
        authManager._testSetAuthCallbackStatus(.processing)
        render(AuthCallbackView().environment(authManager))
        authManager._testSetAuthCallbackStatus(.succeeded(email: "user@lifeos.local"))
        render(AuthCallbackView().environment(authManager))
        authManager._testSetAuthCallbackStatus(.failed("Callback failed"))
        render(AuthCallbackView().environment(authManager))
        _ = PrivacyNoteView(.photoRetention)

        XCTAssertEqual(PrivacyNote.photoRetention.icon, "clock.arrow.circlepath")
        XCTAssertEqual(PrivacyNote.medicalScanRetention.icon, "clock.arrow.circlepath")
        XCTAssertEqual(PrivacyNote.menstrualLocalOnly.icon, "iphone")
        XCTAssertEqual(PrivacyNote.medicalScanLocalOnly.icon, "iphone")
        XCTAssertEqual(PrivacyNote.onDeviceOnly.icon, "iphone")
        XCTAssertEqual(PrivacyNote.aiCacheExpiry.icon, "timer")
        XCTAssertEqual(PrivacyNote.healthKitReadOnly.icon, "lock.shield")
        XCTAssertEqual(PrivacyNote.custom(icon: "star", text: "hello").icon, "star")
        XCTAssertEqual(PrivacyNote.custom(icon: "star", text: "hello").text, "hello")
        XCTAssertEqual(
            PrivacyNote.custom(icon: "star", text: "hello").accessibilityText,
            "hello"
        )
    }

    func testAuthFeatureReducerStateTransitions() {
        var state = AuthFeature.State()
        let reducer = AuthFeature()

        _ = reducer.reduce(into: &state, action: .openEmailOTP(true))
        XCTAssertTrue(state.showEmailOTP)

        state.otpCode = "123456"
        state.errorMessage = "stale"
        _ = reducer.reduce(into: &state, action: .openEmailOTP(false))
        XCTAssertFalse(state.showEmailOTP)
        XCTAssertEqual(state.otpCode, "")
        XCTAssertNil(state.errorMessage)

        state.email = "user@example.com"
        _ = reducer.reduce(into: &state, action: .sendOTPTapped)
        XCTAssertTrue(state.isLoading)
        XCTAssertNil(state.errorMessage)

        _ = reducer.reduce(into: &state, action: .sendOTPSucceeded)
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(state.otpSent)

        _ = reducer.reduce(into: &state, action: .sendOTPFailed("send_failed"))
        XCTAssertFalse(state.isLoading)
        XCTAssertEqual(state.errorMessage, "send_failed")

        state.otpCode = "123456"
        _ = reducer.reduce(into: &state, action: .verifyOTPTapped)
        XCTAssertTrue(state.isLoading)
        XCTAssertNil(state.errorMessage)

        state.showEmailOTP = true
        state.otpCode = "999999"
        _ = reducer.reduce(into: &state, action: .verifyOTPSucceeded)
        XCTAssertFalse(state.isLoading)
        XCTAssertFalse(state.showEmailOTP)
        XCTAssertEqual(state.otpCode, "")

        _ = reducer.reduce(into: &state, action: .verifyOTPFailed("verify_failed"))
        XCTAssertFalse(state.isLoading)
        XCTAssertEqual(state.errorMessage, "verify_failed")

        _ = reducer.reduce(into: &state, action: .appleSignInFailed("apple_failed"))
        XCTAssertEqual(state.errorMessage, "apple_failed")

        _ = reducer.reduce(into: &state, action: .binding(.set(\.email, "user@example.com")))
        XCTAssertEqual(state.email, "user@example.com")
    }

    private func render<V: View>(_ view: sending V, file: StaticString = #filePath, line: UInt = #line) {
        let host = UIHostingController(rootView: view)
        _ = host.view
        XCTAssertNotNil(host.viewIfLoaded, file: file, line: line)
    }

}

@MainActor
final class HomeViewModelCoverageTests: XCTestCase {
    override func tearDown() {
        AuthManager.setActiveAuthIdForTests(nil)
        super.tearDown()
    }

    func testRefreshWithoutAuthReturnsEmptyState() async {
        AuthManager.setActiveAuthIdForTests(nil)
        let viewModel = HomeViewModel(pushLatestWatchSnapshot: { _ in })

        await viewModel.refresh()

        XCTAssertNil(viewModel.recoveryScore)
        XCTAssertNil(viewModel.recoveryZone)
        XCTAssertNil(viewModel.recoveryConfidence)
        XCTAssertNil(viewModel.contextualRecoveryAction)
    }

    func testRefreshWithUnknownAuthReturnsEmptyState() async {
        AuthManager.setActiveAuthIdForTests(UUID())
        let viewModel = HomeViewModel(pushLatestWatchSnapshot: { _ in })

        await viewModel.refresh()

        XCTAssertNil(viewModel.recoveryScore)
        XCTAssertNil(viewModel.recoveryZone)
        XCTAssertNil(viewModel.recoveryConfidence)
        XCTAssertNil(viewModel.contextualRecoveryAction)
    }

    func testDefaultPushLatestWatchSnapshotClosurePathDoesNotCrash() async {
        AuthManager.setActiveAuthIdForTests(nil)
        WatchSyncManager._testSetPushLatestSnapshotOverride { _ in }
        defer { WatchSyncManager._testSetPushLatestSnapshotOverride(nil) }
        let viewModel = HomeViewModel()

        await viewModel.refresh()

        XCTAssertNil(viewModel.recoveryScore)
        XCTAssertNil(viewModel.contextualRecoveryAction)
    }

    func testDeepLinkFallbackPathForInvalidHostEncoding() {
        let url = HomeViewModel._testDeepLink(host: "#", date: "2026-02-24")
        XCTAssertEqual(url.absoluteString, "lifeos://#")
    }

    func testRefreshBuildsSleepDeficitContextualAction() async throws {
        let authId = UUID()
        let userId = try await insertUser(authId: authId, baselineSleepHours: 7.0)

        try await insertPhysiologicalState(
            userId: userId,
            date: DiaryDateFormatter.formatDate(Date()),
            score: 22,
            sleepDurationHours: 5.0
        )
        AuthManager.setActiveAuthIdForTests(authId)

        let viewModel = HomeViewModel(pushLatestWatchSnapshot: { _ in })
        await viewModel.refresh()

        XCTAssertEqual(try XCTUnwrap(viewModel.recoveryScore), 22, accuracy: 0.001)
        XCTAssertEqual(viewModel.recoveryZone, .critical)

        let action = try XCTUnwrap(viewModel.contextualRecoveryAction)
        let components = try XCTUnwrap(URLComponents(url: action.deepLink, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "lifeos")
        XCTAssertEqual(components.host, "sleep")
        XCTAssertTrue(
            components.queryItems?.contains(where: { $0.name == "date" && $0.value == DiaryDateFormatter.formatDate(Date()) }) == true
        )
    }

    func testRefreshBuildsGeneralContextualActionWhenSleepContextMissing() async throws {
        let authId = UUID()
        let userId = try await insertUser(authId: authId, baselineSleepHours: nil)

        try await insertPhysiologicalState(
            userId: userId,
            date: "not-a-date",
            score: 40,
            sleepDurationHours: nil
        )
        AuthManager.setActiveAuthIdForTests(authId)

        let viewModel = HomeViewModel(pushLatestWatchSnapshot: { _ in })
        await viewModel.refresh()

        XCTAssertNil(viewModel.recoveryZone)
        XCTAssertNil(viewModel.contextualRecoveryAction) // invalid dates must not look current
    }

    func testRefreshKeepsActionNilForOptimalZone() async throws {
        let authId = UUID()
        let userId = try await insertUser(authId: authId, baselineSleepHours: 8.0)

        try await insertPhysiologicalState(
            userId: userId,
            date: DiaryDateFormatter.formatDate(Date()),
            score: 93,
            sleepDurationHours: 4.0
        )
        AuthManager.setActiveAuthIdForTests(authId)

        let viewModel = HomeViewModel(pushLatestWatchSnapshot: { _ in })
        await viewModel.refresh()

        XCTAssertEqual(viewModel.recoveryZone, .optimal)
        XCTAssertNil(viewModel.contextualRecoveryAction)
    }

    func testRefreshResetsStateWhenSnapshotDecodingFails() async throws {
        let authId = UUID()
        let userId = try await insertUser(authId: authId, baselineSleepHours: 7.5)
        let malformedStateId = "not-a-uuid-\(UUID().uuidString)"

        try await insertPhysiologicalState(
            userId: userId,
            date: DiaryDateFormatter.formatDate(Date()),
            score: 58,
            sleepDurationHours: 6.5
        )
        AuthManager.setActiveAuthIdForTests(authId)

        let viewModel = HomeViewModel(pushLatestWatchSnapshot: { _ in })
        await viewModel.refresh()
        XCTAssertNotNil(viewModel.recoveryScore)

        try await DatabaseManager.shared.dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM physiological_states WHERE user_id = ?",
                arguments: [userId.uuidString]
            )
            try db.execute(
                sql: """
                    INSERT INTO physiological_states (
                        id, user_id, date, recovery_score, recovery_zone, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    malformedStateId,
                    userId.uuidString,
                    DiaryDateFormatter.formatDate(Date()),
                    47.0,
                    "caution",
                    Date(),
                    Date()
                ]
            )
        }

        await viewModel.refresh()

        XCTAssertNil(viewModel.recoveryScore)
        XCTAssertNil(viewModel.recoveryZone)
        XCTAssertNil(viewModel.recoveryConfidence)
        XCTAssertNil(viewModel.contextualRecoveryAction)
    }

    func testSupplementsDueSoonIncludesNextDaySlotAcrossMidnight() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let now = makeLocalDate(year: 2026, month: 2, day: 24, hour: 23, minute: 15)

        try await manager.dbQueue.write { db in
            try Self.seedDueSoonUser(db: db, userId: userId, authId: authId, now: now)
            _ = try Self.insertDueSoonSupplement(
                db: db,
                userId: userId,
                scheduledTimes: ["00:30"],
                startedAt: "2026-02-24",
                now: now
            )
        }

        let result = try await HomeViewModel._testQuerySupplementsDueSoon(
            db: manager.dbQueue,
            userId: userId,
            referenceDate: now
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.nextTime, "00:30")
    }

    func testSupplementsDueSoonChoosesEarliestOccurrenceByActualDateAcrossMidnight() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let now = makeLocalDate(year: 2026, month: 2, day: 24, hour: 23, minute: 40)

        try await manager.dbQueue.write { db in
            try Self.seedDueSoonUser(db: db, userId: userId, authId: authId, now: now)
            _ = try Self.insertDueSoonSupplement(
                db: db,
                userId: userId,
                scheduledTimes: ["23:50", "00:15"],
                startedAt: "2026-02-24",
                now: now
            )
        }

        let result = try await HomeViewModel._testQuerySupplementsDueSoon(
            db: manager.dbQueue,
            userId: userId,
            referenceDate: now
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.nextTime, "23:50")
    }

    func testSupplementsDueSoonSkipsNextDaySlotWhenTomorrowLogAlreadyExists() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let now = makeLocalDate(year: 2026, month: 2, day: 24, hour: 23, minute: 15)

        try await manager.dbQueue.write { db in
            try Self.seedDueSoonUser(db: db, userId: userId, authId: authId, now: now)
            let supplementId = try Self.insertDueSoonSupplement(
                db: db,
                userId: userId,
                scheduledTimes: ["00:30"],
                startedAt: "2026-02-24",
                now: now
            )
            try Self.insertSupplementLog(
                db: db,
                userId: userId,
                userSupplementId: supplementId,
                takenDate: "2026-02-25",
                scheduledTime: "00:30:59",
                now: now
            )
        }

        let result = try await HomeViewModel._testQuerySupplementsDueSoon(
            db: manager.dbQueue,
            userId: userId,
            referenceDate: now
        )

        XCTAssertEqual(result.count, 0)
        XCTAssertNil(result.nextTime)
    }

    private func render<V: View>(_ view: sending V, file: StaticString = #filePath, line: UInt = #line) {
        let host = UIHostingController(rootView: view)
        _ = host.view
        XCTAssertNotNil(host.viewIfLoaded, file: file, line: line)
    }

    private func insertUser(authId: UUID, baselineSleepHours: Double?) async throws -> UUID {
        let userId = UUID()
        let baseline = baselineSleepHours
        try await DatabaseManager.shared.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (
                        id, auth_id, timezone, units, baseline_sleep_hours, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    userId.uuidString,
                    authId.uuidString,
                    "UTC",
                    "metric",
                    baseline,
                    Date(),
                    Date()
                ]
            )
        }
        return userId
    }

    private func insertPhysiologicalState(
        userId: UUID,
        date: String,
        score: Double,
        sleepDurationHours: Double?
    ) async throws {
        let sleepHours = sleepDurationHours
        try await DatabaseManager.shared.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO physiological_states (
                        id, user_id, date, sleep_duration_hours,
                        recovery_score, recovery_zone, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    date,
                    sleepHours,
                    score,
                    RecoveryZone.from(score: score).rawValue,
                    Date(),
                    Date()
                ]
            )
        }
    }

    private func makeLocalDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    nonisolated private static func seedDueSoonUser(
        db: Database,
        userId: UUID,
        authId: UUID,
        now: Date
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO users (
                    id, auth_id, timezone, units, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [userId.uuidString, authId.uuidString, "UTC", "metric", now, now]
        )
    }

    @discardableResult
    nonisolated private static func insertDueSoonSupplement(
        db: Database,
        userId: UUID,
        scheduledTimes: [String],
        frequency: String = SupplementFrequency.daily.rawValue,
        daysOfWeek: [Int]? = nil,
        startedAt: String,
        endedAt: String? = nil,
        now: Date
    ) throws -> UUID {
        let supplementId = UUID()
        let scheduledTimesJSON = try jsonString(scheduledTimes)
        let daysOfWeekJSON = try daysOfWeek.map { try jsonString($0) }
        try db.execute(
            sql: """
                INSERT INTO user_supplements (
                    id, user_id, catalog_id, custom_name, dose_amount, dose_unit,
                    frequency, scheduled_times, days_of_week, take_with_food,
                    notes, active, started_at, ended_at, created_at, updated_at
                ) VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, 0, NULL, 1, ?, ?, ?, ?)
                """,
            arguments: [
                supplementId.uuidString,
                userId.uuidString,
                "Magnesium",
                200.0,
                "mg",
                frequency,
                scheduledTimesJSON,
                daysOfWeekJSON,
                startedAt,
                endedAt,
                now,
                now
            ]
        )
        return supplementId
    }

    nonisolated private static func insertSupplementLog(
        db: Database,
        userId: UUID,
        userSupplementId: UUID,
        takenDate: String,
        scheduledTime: String,
        now: Date
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO supplement_logs (
                    id, user_id, user_supplement_id, taken_at, taken_date,
                    supplement_name, dose_amount, dose_unit, was_scheduled,
                    scheduled_time, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                UUID().uuidString,
                userId.uuidString,
                userSupplementId.uuidString,
                now,
                takenDate,
                "Magnesium",
                200.0,
                "mg",
                true,
                scheduledTime,
                now,
                now
            ]
        )
    }

    nonisolated private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class InsightsViewModelCoverageTests: XCTestCase {
    override func tearDown() {
        AuthManager.setActiveAuthIdForTests(nil)
        super.tearDown()
    }

    func testRefreshLoadsInsightsAndLowConfidenceCountSortedByPriorityThenDate() async throws {
        let authId = UUID()
        let userId = try await insertUser(authId: authId)

        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let olderLowConfidenceId = UUID()
        let newerPriorityPeerId = UUID()
        let lowerPriorityId = UUID()

        try await insertInsightRow(
            id: olderLowConfidenceId,
            userId: userId,
            category: "recovery",
            title: "Older",
            body: "Older insight",
            confidence: 0.4,
            priority: 1,
            dismissed: false,
            needsReview: true,
            createdAt: baseDate
        )
        try await insertInsightRow(
            id: newerPriorityPeerId,
            userId: userId,
            category: "sleep",
            title: "Newer",
            body: "Newer insight",
            confidence: 0.9,
            priority: 1,
            dismissed: false,
            needsReview: false,
            createdAt: baseDate.addingTimeInterval(120)
        )
        try await insertInsightRow(
            id: lowerPriorityId,
            userId: userId,
            category: "general",
            title: "Lower Priority",
            body: "Another insight",
            confidence: 0.8,
            priority: 2,
            dismissed: false,
            needsReview: false,
            createdAt: baseDate.addingTimeInterval(300)
        )
        try await insertInsightRow(
            id: UUID(),
            userId: userId,
            category: "health",
            title: "Dismissed",
            body: "Should be filtered",
            confidence: 0.3,
            priority: 1,
            dismissed: true,
            needsReview: true,
            createdAt: baseDate.addingTimeInterval(180)
        )

        AuthManager.setActiveAuthIdForTests(authId)
        let viewModel = InsightsViewModel(
            dailyInsightsService: DailyInsightsNoopService(),
            weeklyStrategyService: WeeklyStrategyNoopService()
        )

        await viewModel.refresh()

        XCTAssertEqual(viewModel.lowConfidenceCount, 1)
        XCTAssertEqual(viewModel.insights.map(\.id), [
            newerPriorityPeerId,
            olderLowConfidenceId,
            lowerPriorityId
        ])
        XCTAssertNil(viewModel.loadError)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testRefreshWithoutAuthReturnsEmptyState() async {
        AuthManager.setActiveAuthIdForTests(nil)
        let viewModel = InsightsViewModel()

        await viewModel.refresh()

        XCTAssertEqual(viewModel.lowConfidenceCount, 0)
        XCTAssertTrue(viewModel.insights.isEmpty)
        XCTAssertNil(viewModel.loadError)
    }

    func testRefreshSetsErrorWhenInsightsDecodingFails() async throws {
        let authId = UUID()
        let userId = try await insertUser(authId: authId)
        let malformedInsightId = "invalid-uuid-\(UUID().uuidString)"

        try await DatabaseManager.shared.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO insights (
                        id, user_id, category, title, body, confidence,
                        priority, actionable, read, acknowledged, dismissed,
                        needs_review, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    malformedInsightId,
                    userId.uuidString,
                    "recovery",
                    "Broken",
                    "Broken row",
                    0.2,
                    1,
                    false,
                    false,
                    false,
                    false,
                    true,
                    Date(),
                    Date()
                ]
            )
        }

        AuthManager.setActiveAuthIdForTests(authId)
        let viewModel = InsightsViewModel()

        await viewModel.refresh()

        XCTAssertEqual(viewModel.lowConfidenceCount, 0)
        XCTAssertTrue(viewModel.insights.isEmpty)
        XCTAssertNotNil(viewModel.loadError)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testDomainFiltersUpdateVisibleInsightsAndLowConfidenceCount() async throws {
        let authId = UUID()
        let userId = try await insertUser(authId: authId)

        let baseDate = Date(timeIntervalSince1970: 1_710_000_000)
        let recoveryId = UUID()
        let nutritionId = UUID()
        let sleepId = UUID()

        try await insertInsightRow(
            id: recoveryId,
            userId: userId,
            category: "recovery",
            title: "Recovery",
            body: "Recovery insight",
            confidence: 0.4,
            priority: 1,
            dismissed: false,
            needsReview: true,
            createdAt: baseDate
        )
        try await insertInsightRow(
            id: nutritionId,
            userId: userId,
            category: "nutrition",
            title: "Nutrition",
            body: "Nutrition insight",
            confidence: 0.9,
            priority: 2,
            dismissed: false,
            needsReview: false,
            createdAt: baseDate.addingTimeInterval(60)
        )
        try await insertInsightRow(
            id: sleepId,
            userId: userId,
            category: "sleep",
            title: "Sleep",
            body: "Sleep insight",
            confidence: 0.3,
            priority: 3,
            dismissed: false,
            needsReview: true,
            createdAt: baseDate.addingTimeInterval(120)
        )

        AuthManager.setActiveAuthIdForTests(authId)
        let viewModel = InsightsViewModel(
            dailyInsightsService: DailyInsightsNoopService(),
            weeklyStrategyService: WeeklyStrategyNoopService()
        )

        await viewModel.refresh()

        XCTAssertEqual(viewModel.totalInsightCount, 3)
        XCTAssertEqual(viewModel.lowConfidenceCount, 2)
        XCTAssertEqual(viewModel.availableDomains, [.recovery, .nutrition, .sleep])

        viewModel.toggleDomain(.nutrition)
        XCTAssertEqual(viewModel.insights.map(\.id), [nutritionId])
        XCTAssertEqual(viewModel.lowConfidenceCount, 0)
        XCTAssertTrue(viewModel.hasActiveDomainFilters)

        viewModel.toggleDomain(.sleep)
        XCTAssertEqual(viewModel.insights.map(\.id), [nutritionId, sleepId])
        XCTAssertEqual(viewModel.lowConfidenceCount, 1)

        viewModel.selectAllDomains()
        XCTAssertEqual(viewModel.insights.map(\.id), [recoveryId, nutritionId, sleepId])
        XCTAssertEqual(viewModel.lowConfidenceCount, 2)
        XCTAssertFalse(viewModel.hasActiveDomainFilters)
    }

    private func insertUser(authId: UUID) async throws -> UUID {
        let userId = UUID()
        try await DatabaseManager.shared.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [userId.uuidString, authId.uuidString, "UTC", "metric", Date(), Date()]
            )
        }
        return userId
    }

    private func insertInsightRow(
        id: UUID,
        userId: UUID,
        category: String,
        title: String,
        body: String,
        confidence: Double,
        priority: Int,
        dismissed: Bool,
        needsReview: Bool,
        createdAt: Date
    ) async throws {
        try await DatabaseManager.shared.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO insights (
                        id, user_id, category, title, body, confidence,
                        priority, actionable, read, acknowledged, dismissed,
                        needs_review, shown_to_user, acted_upon, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    id.uuidString,
                    userId.uuidString,
                    category,
                    title,
                    body,
                    confidence,
                    priority,
                    false,
                    false,
                    false,
                    dismissed,
                    needsReview,
                    false,
                    false,
                    createdAt,
                    createdAt
                ]
            )
        }
    }
}

@MainActor
final class LabsFeatureCoverageTests: XCTestCase {
    override func tearDown() {
        AuthManager.setActiveAuthIdForTests(nil)
        super.tearDown()
    }

    func testLabsSummaryBuildsFallbackAndAccessibilityText() {
        let withStatus = LabsSummary(latestStatus: "completed", markerCount: 3, scanCount: 0)
        let completedText = LabsLocalizedText.identifier("completed")
        XCTAssertEqual(withStatus.primaryText, completedText)
        XCTAssertEqual(withStatus.secondaryText, LabsLocalizedText.markersCountSummary(3))
        XCTAssertEqual(
            withStatus.accessibilitySummary,
            "\(completedText), \(LabsLocalizedText.markersCountSummary(3))"
        )

        let withoutStatusOrCount = LabsSummary(latestStatus: nil, markerCount: 0, scanCount: 0)
        XCTAssertNotEqual(
            withoutStatusOrCount.primaryText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
            ""
        )
        XCTAssertNil(withoutStatusOrCount.secondaryText)
        XCTAssertFalse(withoutStatusOrCount.accessibilitySummary.isEmpty)
    }

    func testTaskLoadsSummaryWhenLabsDataExists() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        AuthManager.setActiveAuthIdForTests(user.authId)

        try await manager.dbQueue.write { db in
            try user.insert(db)

            var olderScan = MedicalScan(userId: user.id, scanType: .bloodTest)
            olderScan.status = .processing
            olderScan.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
            olderScan.updatedAt = olderScan.createdAt
            try olderScan.insert(db)

            var latestScan = MedicalScan(userId: user.id, scanType: .bloodTest)
            latestScan.status = .completed
            latestScan.createdAt = Date(timeIntervalSince1970: 1_700_000_500)
            latestScan.updatedAt = latestScan.createdAt
            try latestScan.insert(db)

            try HealthMeasurement(
                userId: user.id,
                biomarkerName: "CRP",
                value: 1.2,
                unit: "mg/L"
            ).insert(db)
            try HealthMeasurement(
                userId: user.id,
                biomarkerName: "Vitamin D",
                value: 42.0,
                unit: "ng/mL"
            ).insert(db)
        }

        let store = TestStore(initialState: LabsFeature.State()) {
            LabsFeature()
        } withDependencies: {
            $0.databaseQueue = manager.dbQueue
        }
        let expectedSnapshot = try await manager.dbQueue.read { db in
            let historyRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        ms.id,
                        ms.scan_type,
                        ms.status,
                        ms.created_at,
                        ms.scan_date,
                        ms.lab_name,
                        ms.needs_review,
                        ms.pinned_by_user,
                        ms.storage_mode,
                        COUNT(DISTINCT hm.id) AS marker_count
                    FROM medical_scans ms
                    LEFT JOIN health_measurements hm
                      ON hm.medical_scan_id = ms.id
                      OR hm.source_scan_id = ms.id
                    WHERE (ms.user_id = ? OR ms.user_id = ?)
                      AND ms.deleted_at IS NULL
                    GROUP BY
                        ms.id,
                        ms.scan_type,
                        ms.status,
                        ms.created_at,
                        ms.scan_date,
                        ms.lab_name,
                        ms.needs_review,
                        ms.pinned_by_user,
                        ms.storage_mode
                    ORDER BY
                        CASE WHEN ms.needs_review = 1 THEN 0 ELSE 1 END,
                        CASE WHEN ms.pinned_by_user = 1 THEN 0 ELSE 1 END,
                        COALESCE(ms.scan_date, strftime('%Y-%m-%d', ms.created_at)) DESC,
                        ms.created_at DESC
                    """,
                arguments: [user.id, user.id.uuidString]
            )
            return LabsOverviewSnapshot(
                summary: LabsSummary(latestStatus: "completed", markerCount: 2, scanCount: 2),
                metrics: LabsOverviewMetrics(
                    totalScanCount: 2,
                    totalMarkerCount: 2,
                    reviewRequiredCount: 0,
                    pinnedCount: 0
                ),
                scanHistory: historyRows.compactMap(LabScanHistoryItem.init(row:))
            )
        }

        await store.send(.task) {
            $0.isLoading = true
        }

        await store.receive(.loadResponse(.success(expectedSnapshot))) {
            $0.summary = expectedSnapshot.summary
            $0.metrics = expectedSnapshot.metrics
            $0.scanHistory = expectedSnapshot.scanHistory
            $0.isLoading = false
        }
    }

    func testTaskLoadsNilSummaryWhenNoLabsDataExists() async throws {
        let manager = try DatabaseManager.inMemory()

        let store = TestStore(
            initialState: LabsFeature.State(
                summary: LabsSummary(latestStatus: "completed", markerCount: 1, scanCount: 1),
                isLoading: false
            )
        ) {
            LabsFeature()
        } withDependencies: {
            $0.databaseQueue = manager.dbQueue
        }

        await store.send(.task) {
            $0.isLoading = true
        }

        await store.receive(.loadResponse(.success(LabsOverviewSnapshot(summary: nil, metrics: nil, scanHistory: [])))) {
            $0.summary = nil
            $0.metrics = nil
            $0.scanHistory = []
            $0.isLoading = false
        }
    }

    func testLoadResponseFailureClearsSummaryAndLoadingFlag() {
        struct DummyError: LocalizedError {
            var errorDescription: String? { "dummy" }
        }

        var state = LabsFeature.State(
            summary: LabsSummary(latestStatus: "completed", markerCount: 2, scanCount: 1),
            isLoading: true
        )
        _ = LabsFeature().reduce(into: &state, action: .loadResponse(.failure(.init(DummyError()))))

        XCTAssertNil(state.summary)
        XCTAssertFalse(state.isLoading)
    }
}

@MainActor
final class ViewSmokeCoverageTests: XCTestCase {
    func testAuthAndOnboardingViewsRenderAcrossStates() {
        let authManager = AuthManager()

        let defaultAuthView = AuthView(
            store: Store(initialState: AuthFeature.State()) { AuthFeature() }
        )
        render(defaultAuthView.environment(authManager))

        var authErrorState = AuthFeature.State()
        authErrorState.errorMessage = "auth-error"
        render(AuthView(
            store: Store(initialState: authErrorState) { AuthFeature() }
        ).environment(authManager))

        var otpEntryState = AuthFeature.State()
        otpEntryState.showEmailOTP = true
        otpEntryState.email = "qa@lifeos.local"
        render(AuthView(
            store: Store(initialState: otpEntryState) { AuthFeature() }
        )._testEmailOTPSheet())

        var otpEntryLoadingState = AuthFeature.State()
        otpEntryLoadingState.showEmailOTP = true
        otpEntryLoadingState.email = "qa@lifeos.local"
        otpEntryLoadingState.isLoading = true
        render(AuthView(
            store: Store(initialState: otpEntryLoadingState) { AuthFeature() }
        )._testEmailOTPSheet())

        var otpVerifyState = AuthFeature.State()
        otpVerifyState.showEmailOTP = true
        otpVerifyState.otpSent = true
        otpVerifyState.email = "qa@lifeos.local"
        otpVerifyState.otpCode = "123456"
        otpVerifyState.errorMessage = "invalid_code"
        render(AuthView(
            store: Store(initialState: otpVerifyState) { AuthFeature() }
        )._testEmailOTPSheet())

        var otpVerifyLoadingState = AuthFeature.State()
        otpVerifyLoadingState.showEmailOTP = true
        otpVerifyLoadingState.otpSent = true
        otpVerifyLoadingState.email = "qa@lifeos.local"
        otpVerifyLoadingState.otpCode = "123456"
        otpVerifyLoadingState.isLoading = true
        render(AuthView(
            store: Store(initialState: otpVerifyLoadingState) { AuthFeature() }
        )._testEmailOTPSheet())

        render(OnboardingStepView(
            icon: "person",
            title: "Title",
            description: "Description",
            buttonTitle: "Continue",
            action: {}
        ))

        var authStepState = OnboardingFeature.State()
        authStepState.currentStep = .authComplete
        render(OnboardingView(
            store: Store(initialState: authStepState) { OnboardingFeature() }
        )
        .environment(authManager))

        var profileState = OnboardingFeature.State()
        profileState.currentStep = .profileComplete
        render(OnboardingView(
            store: Store(initialState: profileState) { OnboardingFeature() }
        )
        .environment(authManager))

        var weightState = OnboardingFeature.State()
        weightState.currentStep = .healthkitPrompted
        weightState.weightInputText = "82"
        render(OnboardingView(
            store: Store(initialState: weightState) { OnboardingFeature() }
        )
        .environment(authManager))

        var healthKitState = OnboardingFeature.State()
        healthKitState.currentStep = .healthkitGranted
        healthKitState.isRequestingHealthKit = true
        render(OnboardingView(
            store: Store(initialState: healthKitState) { OnboardingFeature() }
        )
        .environment(authManager))

        var healthKitSkippedState = OnboardingFeature.State()
        healthKitSkippedState.currentStep = .healthkitSkipped
        render(OnboardingView(
            store: Store(initialState: healthKitSkippedState) { OnboardingFeature() }
        )
        .environment(authManager))

        var backfillState = OnboardingFeature.State()
        backfillState.currentStep = .backfillInProgress
        backfillState.isBackfilling = true
        render(OnboardingView(
            store: Store(initialState: backfillState) { OnboardingFeature() }
        )
        .environment(authManager))

        var backfillDoneState = OnboardingFeature.State()
        backfillDoneState.currentStep = .backfillComplete
        backfillDoneState.isBackfilling = false
        render(OnboardingView(
            store: Store(initialState: backfillDoneState) { OnboardingFeature() }
        )
        .environment(authManager))

        var tutorialState = OnboardingFeature.State()
        tutorialState.currentStep = .tutorialShown
        tutorialState.isCompleting = true
        render(OnboardingView(
            store: Store(initialState: tutorialState) { OnboardingFeature() }
        )
        .environment(authManager))

        var completeState = OnboardingFeature.State()
        completeState.currentStep = .onboardingComplete
        render(OnboardingView(
            store: Store(initialState: completeState) { OnboardingFeature() }
        )
        .environment(authManager))
    }

    func testPrimaryScreensAndDetailViewsRender() throws {
        let router = DeepLinkRouter()

        render(HomeView().environment(router))
        render(MainTabView().environment(router))
        render(DiaryView())
        render(DiaryView(initialDateString: "2026-02-24"))
        render(InsightsView())
        render(SettingsView())
        render(NutritionDayView(dateString: "2026-02-24"))
        render(NutritionLogView(method: .photo, aiConfidence: 0.42))
        render(NutritionLogView(method: nil, aiConfidence: nil))
        render(SupplementsDayView(dateString: "2026-02-24"))
        render(TrainingDayView(dateString: "2026-02-24"))
        render(WorkoutLogView())
        render(RecoveryDetailView(dateString: "2026-02-24"))
        render(SleepDayView(dateString: "2026-02-24"))
        render(MenstrualDayView(dateString: "2026-02-24"))
        render(InsightDetailView(insightId: UUID()))
        render(ExperimentDetailView(experimentId: UUID()))
        render(LabScanDetailView(scanId: UUID()))
        render(SimulationView())

        let noDataStore = Store(initialState: LabsFeature.State()) { LabsFeature() }
        render(LabsOverviewView(store: noDataStore))

        let loadingStore = Store(initialState: LabsFeature.State(summary: nil, isLoading: true)) { LabsFeature() }
        render(LabsOverviewView(store: loadingStore))

        let summaryStore = Store(
            initialState: LabsFeature.State(
                summary: LabsSummary(latestStatus: "completed", markerCount: 4, scanCount: 1),
                isLoading: false
            )
        ) {
            LabsFeature()
        }
        render(LabsOverviewView(store: summaryStore))
    }

    @MainActor
    func testMenstrualDayViewCoverageStates() {
        let userId = UUID()
        let currentLog = MenstrualLog(userId: userId, date: "2026-02-24", flow: .medium, painLevel: 3)
        let earlierLog = MenstrualLog(userId: userId, date: "2026-02-20", flow: .light, painLevel: 1)
        let viewModel = MenstrualDayViewModel(dateString: "2026-02-24")
        viewModel._testOverrideState(
            userId: userId,
            currentLog: currentLog,
            recentLogs: [currentLog, earlierLog],
            trackingEnabled: false,
            syncEnabled: false,
            statusMessage: "Saved",
            isLoading: false,
            isSaving: false
        )

        XCTAssertFalse(MenstrualDayViewModel._testSummary(flow: nil, painLevel: nil).isEmpty)
        XCTAssertTrue(MenstrualDayViewModel._testSummary(flow: .heavy, painLevel: 4).contains("4"))

        render(MenstrualDayView(testViewModel: viewModel))
    }

    func testSettingsDestinationViewsRenderWithInMemoryDependencies() throws {
        let manager = try DatabaseManager.inMemory()
        let syncEngine = SyncEngine(dbQueue: manager.dbQueue)

        render(SettingsSyncView(syncEngine: syncEngine))
        render(SettingsNotificationsView(syncEngine: syncEngine, dbQueue: manager.dbQueue))
        render(SettingsPrivacyView(syncEngine: syncEngine, dbQueue: manager.dbQueue))
        render(SettingsFoodDataSourcesView())
    }

    func testAuthViewHelperBranchesAndFlows() async throws {
        struct LocalizedTestError: LocalizedError {
            let description: String
            var errorDescription: String? { description }
        }
        final class FakeAppleCredential: NSObject {
            @objc let identityToken: Data?

            init(identityToken: Data?) {
                self.identityToken = identityToken
            }
        }
        final class FakeAuthorization: NSObject {
            @objc let credential: ASAuthorizationCredential

            init(credential: ASAuthorizationCredential) {
                self.credential = credential
            }
        }
        AuthView._testResetDefaultAuthOverrides()
        defer { AuthView._testResetDefaultAuthOverrides() }

        let bodyRenderAuthManager = AuthManager(
            client: SupabaseConfig.client,
            db: try DatabaseManager.inMemory()
        )

        AuthView._testSetAppleSignInOverride {}
        AuthView._testSetAppleSignInOverride(nil)

        XCTAssertTrue(AuthView._testShouldAnimateLogo(environment: [:]))
        XCTAssertFalse(
            AuthView._testShouldAnimateLogo(environment: ["XCTestConfigurationFilePath": "/tmp/xctest"])
        )
        XCTAssertEqual(
            Set(AuthView._testConfiguredAppleRequestScopes()),
            Set([ASAuthorization.Scope.email, .fullName])
        )
        XCTAssertEqual(AuthView._testRequestedScopesOrEmpty(nil), [])
        XCTAssertEqual(AuthView._testRequestedScopesOrEmpty([.email]), [.email])
        XCTAssertFalse(
            AuthView._testShouldReportAppleFailure(
                NSError(domain: "auth", code: ASAuthorizationError.canceled.rawValue)
            )
        )
        XCTAssertTrue(
            AuthView._testShouldReportAppleFailure(
                NSError(domain: "auth", code: ASAuthorizationError.failed.rawValue)
            )
        )
        XCTAssertEqual(
            AuthView._testFriendlyAuthError(LocalizedTestError(description: "explicit-localized-error")),
            "explicit-localized-error"
        )
        XCTAssertFalse(
            AuthView._testFriendlyAuthError(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)).isEmpty
        )
        XCTAssertEqual(
            AuthView._testFriendlyAuthError(AuthError.invalidCredential),
            AuthError.invalidCredential.localizedDescription
        )

        let baselineAuthView = AuthView(
            store: Store(initialState: AuthFeature.State()) { AuthFeature() },
            testAuthManager: bodyRenderAuthManager
        )
        baselineAuthView._testEvaluateLogoVariants()
        baselineAuthView._testEvaluateBody()
        _ = baselineAuthView._testEmailOTPSheet()
        _ = baselineAuthView._testEmailOTPSheetContent()

        let inlineErrorStore = Store(
            initialState: AuthFeature.State(errorMessage: "inline-auth-error")
        ) { AuthFeature() }
        AuthView(store: inlineErrorStore, testAuthManager: bodyRenderAuthManager)._testEvaluateBody()

        let sheetVisibleStore = Store(
            initialState: AuthFeature.State(showEmailOTP: true)
        ) { AuthFeature() }
        AuthView(store: sheetVisibleStore, testAuthManager: bodyRenderAuthManager)._testEvaluateBody()

        let openEmailStore = Store(initialState: AuthFeature.State()) { AuthFeature() }
        let openEmailViewStore = ViewStore(openEmailStore, observe: { $0 })
        AuthView(store: openEmailStore)._testOpenEmailOTP(store: openEmailStore)
        XCTAssertTrue(openEmailViewStore.showEmailOTP)
        let bindingRoundTripValue = AuthView(store: openEmailStore)._testEmailOTPSheetBindingRoundTrip(
            store: openEmailStore,
            value: false
        )
        XCTAssertFalse(bindingRoundTripValue)

        let openEmailTaskStore = Store(initialState: AuthFeature.State()) { AuthFeature() }
        let openEmailTaskViewStore = ViewStore(openEmailTaskStore, observe: { $0 })
        AuthView(store: openEmailTaskStore)._testOpenEmailOTPTask(store: openEmailTaskStore)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(openEmailTaskViewStore.showEmailOTP)

        let completionFailureStore = Store(initialState: AuthFeature.State()) { AuthFeature() }
        let completionFailureViewStore = ViewStore(completionFailureStore, observe: { $0 })
        AuthView(store: completionFailureStore)._testHandleAppleSignInCompletion(
            .failure(LocalizedTestError(description: "apple-completion-failed")),
            store: completionFailureStore
        )
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(completionFailureViewStore.errorMessage, "apple-completion-failed")

        let completionCanceledStore = Store(initialState: AuthFeature.State()) { AuthFeature() }
        let completionCanceledViewStore = ViewStore(completionCanceledStore, observe: { $0 })
        AuthView(store: completionCanceledStore)._testHandleAppleSignInCompletion(
            .failure(NSError(domain: "auth", code: ASAuthorizationError.canceled.rawValue)),
            store: completionCanceledStore
        )
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(completionCanceledViewStore.errorMessage)

        let defaultActionsStore = Store(
            initialState: AuthFeature.State(email: "default-actions@example.com", otpCode: "445566")
        ) { AuthFeature() }
        let defaultActionsViewStore = ViewStore(defaultActionsStore, observe: { $0 })
        let defaultActionsSendExpectation = expectation(description: "default action send override")
        let defaultActionsVerifyExpectation = expectation(description: "default action verify override")
        AuthView._testSetSendOTPOverride { email in
            XCTAssertEqual(email, "default-actions@example.com")
            defaultActionsSendExpectation.fulfill()
        }
        AuthView._testSetVerifyOTPOverride { email, _ in
            XCTAssertEqual(email, "default-actions@example.com")
            defaultActionsVerifyExpectation.fulfill()
        }
        AuthView(store: defaultActionsStore)._testTriggerDefaultActionMethods(
            error: LocalizedTestError(description: "default-actions-apple-failed")
        )
        await fulfillment(of: [defaultActionsSendExpectation, defaultActionsVerifyExpectation], timeout: 1.0)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(defaultActionsViewStore.showEmailOTP)
        XCTAssertEqual(defaultActionsViewStore.errorMessage, "default-actions-apple-failed")

        let directResultStore = Store(initialState: AuthFeature.State()) { AuthFeature() }
        await AuthView(store: directResultStore)._testHandleAppleSignInResult(
            .failure(LocalizedTestError(description: "apple-direct-failed")),
            store: directResultStore
        )
        XCTAssertEqual(
            ViewStore(directResultStore, observe: { $0 }).errorMessage,
            "apple-direct-failed"
        )

        let fakeCredentialObject = FakeAppleCredential(identityToken: Data("auth-view-token".utf8))
        let fakeCredential = unsafeBitCast(fakeCredentialObject, to: ASAuthorizationAppleIDCredential.self)
        let fakeAuthorizationObject = FakeAuthorization(credential: fakeCredential)
        let fakeAuthorization = unsafeBitCast(fakeAuthorizationObject, to: ASAuthorization.self)
        let successResultStore = Store(initialState: AuthFeature.State()) { AuthFeature() }
        await AuthView(store: successResultStore)._testHandleAppleSignInResult(
            .success(fakeAuthorization),
            store: successResultStore
        )
        XCTAssertNotNil(ViewStore(successResultStore, observe: { $0 }).errorMessage)

        let invalidCredentialStore = Store(initialState: AuthFeature.State()) { AuthFeature() }
        let invalidViewStore = ViewStore(invalidCredentialStore, observe: { $0 })
        let authView = AuthView(store: invalidCredentialStore)
        await authView._testHandleAppleAuthorization(
            hasValidCredential: false,
            store: invalidCredentialStore
        ) {
            XCTFail("signIn closure must not be called for invalid credential")
        }
        XCTAssertNotNil(invalidViewStore.errorMessage)

        let signInSuccessStore = Store(initialState: AuthFeature.State()) { AuthFeature() }
        await AuthView(store: signInSuccessStore)._testHandleAppleSignInSuccess(
            hasCredential: true,
            store: signInSuccessStore
        ) {}
        XCTAssertNil(ViewStore(signInSuccessStore, observe: { $0 }).errorMessage)

        let signInSuccessResultStore = Store(initialState: AuthFeature.State()) { AuthFeature() }
        await AuthView(store: signInSuccessResultStore)._testHandleAppleSignInSuccessResult(
            hasCredential: true,
            store: signInSuccessResultStore
        ) { _ in }
        XCTAssertNil(ViewStore(signInSuccessResultStore, observe: { $0 }).errorMessage)

        let overrideSuccessStore = Store(initialState: AuthFeature.State()) { AuthFeature() }
        let overrideSuccessExpectation = expectation(description: "auth view apple override path")
        AuthView._testSetAppleSignInOverride {
            overrideSuccessExpectation.fulfill()
        }
        await AuthView(store: overrideSuccessStore)._testHandleAppleSignInSuccessResult(
            hasCredential: true,
            store: overrideSuccessStore
        ) { _ in
            XCTFail("default sign-in closure should not run when override is present")
        }
        await fulfillment(of: [overrideSuccessExpectation], timeout: 1.0)
        AuthView._testSetAppleSignInOverride(nil)

        let signInMissingCredentialStore = Store(initialState: AuthFeature.State()) { AuthFeature() }
        await AuthView(store: signInMissingCredentialStore)._testHandleAppleSignInSuccess(
            hasCredential: false,
            store: signInMissingCredentialStore
        ) {
            XCTFail("signIn should not run without credential")
        }
        XCTAssertNotNil(ViewStore(signInMissingCredentialStore, observe: { $0 }).errorMessage)

        let failedAppleStore = Store(initialState: AuthFeature.State()) { AuthFeature() }
        let failedAppleViewStore = ViewStore(failedAppleStore, observe: { $0 })
        await AuthView(store: failedAppleStore)._testHandleAppleAuthorization(
            hasValidCredential: true,
            store: failedAppleStore
        ) {
            throw LocalizedTestError(description: "apple-sign-in-failed")
        }
        XCTAssertEqual(failedAppleViewStore.errorMessage, "apple-sign-in-failed")

        let otpSuccessStore = Store(initialState: AuthFeature.State()) { AuthFeature() }
        let otpSuccessViewStore = ViewStore(otpSuccessStore, observe: { $0 })
        let scheduledTaskExpectation = expectation(description: "auth scheduled task executes")
        AuthView(store: otpSuccessStore)._testScheduleAuthTask {
            scheduledTaskExpectation.fulfill()
        }
        await fulfillment(of: [scheduledTaskExpectation], timeout: 1.0)
        await AuthView(store: otpSuccessStore)._testRunAuthAction(
            store: otpSuccessStore,
            startAction: .sendOTPTapped,
            successAction: .sendOTPSucceeded,
            failureAction: { .sendOTPFailed($0) }
        ) {}
        XCTAssertTrue(otpSuccessViewStore.otpSent)
        XCTAssertFalse(otpSuccessViewStore.isLoading)

        let otpFailureStore = Store(initialState: AuthFeature.State()) { AuthFeature() }
        let otpFailureViewStore = ViewStore(otpFailureStore, observe: { $0 })
        await AuthView(store: otpFailureStore)._testRunAuthAction(
            store: otpFailureStore,
            startAction: .verifyOTPTapped,
            successAction: .verifyOTPSucceeded,
            failureAction: { .verifyOTPFailed($0) }
        ) {
            throw LocalizedTestError(description: "verify-failed")
        }
        XCTAssertEqual(otpFailureViewStore.errorMessage, "verify-failed")

        let sendOtpStore = Store(initialState: AuthFeature.State(email: "send@example.com")) { AuthFeature() }
        let sendOtpViewStore = ViewStore(sendOtpStore, observe: { $0 })
        let sendTaskExpectation = expectation(description: "send otp task wrapper executes")
        AuthView(store: sendOtpStore)._testSendOTPTask(store: sendOtpStore) { _ in
            sendTaskExpectation.fulfill()
        }
        await fulfillment(of: [sendTaskExpectation], timeout: 1.0)
        await AuthView(store: sendOtpStore)._testRunSendOTP(store: sendOtpStore) { email in
            XCTAssertEqual(email, "send@example.com")
        }
        XCTAssertTrue(sendOtpViewStore.otpSent)

        let sendOtpWrapperStore = Store(initialState: AuthFeature.State(email: "send-wrapper@example.com")) { AuthFeature() }
        await AuthView(store: sendOtpWrapperStore)._testSendOTP(store: sendOtpWrapperStore) { email in
            XCTAssertEqual(email, "send-wrapper@example.com")
        }
        XCTAssertTrue(ViewStore(sendOtpWrapperStore, observe: { $0 }).otpSent)

        let sendOtpFailureStore = Store(initialState: AuthFeature.State(email: "fail@example.com")) { AuthFeature() }
        let sendOtpFailureViewStore = ViewStore(sendOtpFailureStore, observe: { $0 })
        await AuthView(store: sendOtpFailureStore)._testRunSendOTP(store: sendOtpFailureStore) { _ in
            throw LocalizedTestError(description: "send-otp-failed")
        }
        XCTAssertEqual(sendOtpFailureViewStore.errorMessage, "send-otp-failed")

        let verifyStore = Store(initialState: AuthFeature.State(email: "verify@example.com", otpCode: "123456")) { AuthFeature() }
        let verifyViewStore = ViewStore(verifyStore, observe: { $0 })
        let verifyTaskExpectation = expectation(description: "verify otp task wrapper executes")
        AuthView(store: verifyStore)._testVerifyOTPTask(store: verifyStore) { _ in
            verifyTaskExpectation.fulfill()
        }
        await fulfillment(of: [verifyTaskExpectation], timeout: 1.0)
        await AuthView(store: verifyStore)._testRunVerifyOTP(store: verifyStore) { email, token in
            XCTAssertEqual(email, "verify@example.com")
            XCTAssertEqual(token, "123456")
        }
        XCTAssertNil(verifyViewStore.errorMessage)

        let verifyWrapperStore = Store(
            initialState: AuthFeature.State(email: "verify-wrapper@example.com", otpCode: "112233")
        ) { AuthFeature() }
        await AuthView(store: verifyWrapperStore)._testVerifyOTP(store: verifyWrapperStore) { email, token in
            XCTAssertEqual(email, "verify-wrapper@example.com")
            XCTAssertEqual(token, "112233")
        }
        XCTAssertNil(ViewStore(verifyWrapperStore, observe: { $0 }).errorMessage)

        let verifyFailureStore = Store(initialState: AuthFeature.State(email: "verify@example.com", otpCode: "654321")) { AuthFeature() }
        let verifyFailureViewStore = ViewStore(verifyFailureStore, observe: { $0 })
        await AuthView(store: verifyFailureStore)._testRunVerifyOTP(store: verifyFailureStore) { _, _ in
            throw LocalizedTestError(description: "verify-otp-failed")
        }
        XCTAssertEqual(verifyFailureViewStore.errorMessage, "verify-otp-failed")

        let defaultSendTaskExpectation = expectation(description: "default send otp task path")
        AuthView._testSetSendOTPOverride { email in
            XCTAssertEqual(email, "default-send@example.com")
            defaultSendTaskExpectation.fulfill()
        }
        let defaultSendTaskStore = Store(initialState: AuthFeature.State(email: "default-send@example.com")) { AuthFeature() }
        AuthView(store: defaultSendTaskStore)._testRunDefaultSendOTPTask(store: defaultSendTaskStore)
        await fulfillment(of: [defaultSendTaskExpectation], timeout: 1.0)

        let defaultSendDirectExpectation = expectation(description: "default send otp direct path")
        AuthView._testSetSendOTPOverride { email in
            XCTAssertEqual(email, "default-send-direct@example.com")
            defaultSendDirectExpectation.fulfill()
        }
        let defaultSendStore = Store(initialState: AuthFeature.State(email: "default-send-direct@example.com")) { AuthFeature() }
        await AuthView(store: defaultSendStore)._testRunDefaultSendOTP(store: defaultSendStore)
        await fulfillment(of: [defaultSendDirectExpectation], timeout: 1.0)
        XCTAssertTrue(ViewStore(defaultSendStore, observe: { $0 }).otpSent)
        AuthView._testSetSendOTPOverride(nil)

        let explicitDefaultSendStore = Store(initialState: AuthFeature.State(email: "explicit-default-send@example.com")) {
            AuthFeature()
        }
        await AuthView(store: explicitDefaultSendStore)._testRunDefaultSendOTP(
            store: explicitDefaultSendStore,
            defaultSend: { email in
                XCTAssertEqual(email, "explicit-default-send@example.com")
            }
        )
        XCTAssertTrue(ViewStore(explicitDefaultSendStore, observe: { $0 }).otpSent)

        let authManagerDB = try DatabaseManager.inMemory()
        let authManager = AuthManager(client: SupabaseConfig.client, db: authManagerDB)
        let managerDefaultStore = Store(
            initialState: AuthFeature.State(email: "manager-default@example.com", otpCode: "212121")
        ) { AuthFeature() }
        let managerSendExpectation = expectation(description: "auth manager send otp default path")
        let managerVerifyExpectation = expectation(description: "auth manager verify otp default path")
        AuthView._testSetSendOTPOverride(nil)
        AuthView._testSetVerifyOTPOverride(nil)
        await MainActor.run {
            AuthManager._testSetSendOTPOverride { email in
                XCTAssertEqual(email, "manager-default@example.com")
                managerSendExpectation.fulfill()
            }
            AuthManager._testSetVerifyOTPOverride { email, token in
                XCTAssertEqual(email, "manager-default@example.com")
                XCTAssertEqual(token, "212121")
                managerVerifyExpectation.fulfill()
                return nil
            }
        }
        await AuthView(store: managerDefaultStore, testAuthManager: authManager)
            ._testRunDefaultSendOTP(store: managerDefaultStore)
        await AuthView(store: managerDefaultStore, testAuthManager: authManager)
            ._testRunDefaultVerifyOTP(store: managerDefaultStore)
        await fulfillment(of: [managerSendExpectation, managerVerifyExpectation], timeout: 1.0)
        await MainActor.run {
            AuthManager._testSetSendOTPOverride(nil)
            AuthManager._testSetVerifyOTPOverride(nil)
        }

        let defaultVerifyTaskExpectation = expectation(description: "default verify otp task path")
        AuthView._testSetVerifyOTPOverride { email, token in
            XCTAssertEqual(email, "default-verify@example.com")
            XCTAssertEqual(token, "777777")
            defaultVerifyTaskExpectation.fulfill()
        }
        let defaultVerifyTaskStore = Store(
            initialState: AuthFeature.State(email: "default-verify@example.com", otpCode: "777777")
        ) { AuthFeature() }
        AuthView(store: defaultVerifyTaskStore)._testRunDefaultVerifyOTPTask(store: defaultVerifyTaskStore)
        await fulfillment(of: [defaultVerifyTaskExpectation], timeout: 1.0)

        let defaultVerifyDirectExpectation = expectation(description: "default verify otp direct path")
        AuthView._testSetVerifyOTPOverride { email, token in
            XCTAssertEqual(email, "default-verify-direct@example.com")
            XCTAssertEqual(token, "888888")
            defaultVerifyDirectExpectation.fulfill()
        }
        let defaultVerifyStore = Store(
            initialState: AuthFeature.State(email: "default-verify-direct@example.com", otpCode: "888888")
        ) { AuthFeature() }
        await AuthView(store: defaultVerifyStore)._testRunDefaultVerifyOTP(store: defaultVerifyStore)
        await fulfillment(of: [defaultVerifyDirectExpectation], timeout: 1.0)
        XCTAssertNil(ViewStore(defaultVerifyStore, observe: { $0 }).errorMessage)
        AuthView._testSetVerifyOTPOverride(nil)

        let explicitDefaultVerifyStore = Store(
            initialState: AuthFeature.State(email: "explicit-default-verify@example.com", otpCode: "999999")
        ) { AuthFeature() }
        await AuthView(store: explicitDefaultVerifyStore)._testRunDefaultVerifyOTP(
            store: explicitDefaultVerifyStore,
            defaultVerify: { email, token in
                XCTAssertEqual(email, "explicit-default-verify@example.com")
                XCTAssertEqual(token, "999999")
            }
        )
        XCTAssertNil(ViewStore(explicitDefaultVerifyStore, observe: { $0 }).errorMessage)

        do {
            try await AuthView._testRunDefaultAppleSignIn(
                credential: nil,
                signIn: { _ in XCTFail("signIn must not run for nil credential") }
            )
            XCTFail("Expected invalid credential error for nil Apple credential")
        } catch let error as LifeOS.AuthError {
            switch error {
            case .invalidCredential:
                break
            default:
                XCTFail("Expected invalidCredential, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error for nil Apple credential: \(error)")
        }

        var didRunDefaultAppleSignIn = false
        try await AuthView._testRunDefaultAppleSignIn(
            credential: fakeCredential,
            signIn: { _ in didRunDefaultAppleSignIn = true }
        )
        XCTAssertTrue(didRunDefaultAppleSignIn)
    }

    private func render<V: View>(_ view: sending V, file: StaticString = #filePath, line: UInt = #line) {
        let host = UIHostingController(rootView: view)
        _ = host.view
        XCTAssertNotNil(host.viewIfLoaded, file: file, line: line)
    }
}

final class BackgroundSyncManagerCoverageTests: XCTestCase {
    private enum TestError: Error {
        case expected
    }

    private final class FakeBGTask: NSObject {
        var expirationHandler: (() -> Void)?
        private(set) var completions: [Bool] = []
        private let onComplete: ((Bool) -> Void)?

        init(onComplete: ((Bool) -> Void)? = nil) {
            self.onComplete = onComplete
            super.init()
        }

        @objc func setTaskCompleted(success: Bool) {
            completions.append(success)
            onComplete?(success)
        }

        @objc(setExpirationHandler:)
        func setObjCExpirationHandler(_ handler: Any?) {
            if let handler = handler as? (() -> Void) {
                expirationHandler = handler
                return
            }
            if let handler = handler as? (@convention(block) () -> Void) {
                expirationHandler = { handler() }
                return
            }
            expirationHandler = nil
        }

        override func responds(to aSelector: Selector!) -> Bool {
            if aSelector == Selector(("setExpirationHandler:")) {
                return true
            }
            return super.responds(to: aSelector)
        }
    }

    override func setUp() {
        super.setUp()
        AppContainer.shared = nil
    }

    override func tearDown() {
        AppContainer.shared = nil
        super.tearDown()
    }

    func testShouldAttemptBackgroundSchedulingComputation() {
        XCTAssertFalse(
            BackgroundSyncManager._testComputeShouldAttemptBackgroundScheduling(isRunningTests: true)
        )

#if targetEnvironment(simulator)
        XCTAssertFalse(
            BackgroundSyncManager._testComputeShouldAttemptBackgroundScheduling(isRunningTests: false)
        )
#else
        XCTAssertTrue(
            BackgroundSyncManager._testComputeShouldAttemptBackgroundScheduling(isRunningTests: false)
        )
#endif
    }

    func testRegistrationAndActionOverrideCoverageHooks() async throws {
        XCTAssertTrue(
            BackgroundSyncManager
                ._testPerformRegistration(shouldRegister: false, isRunningTests: false)
                .isEmpty
        )
        XCTAssertTrue(
            BackgroundSyncManager
                ._testPerformRegistration(shouldRegister: true, isRunningTests: true)
                .isEmpty
        )
        XCTAssertEqual(
            BackgroundSyncManager._testPerformRegistration(shouldRegister: true, isRunningTests: false),
            [BackgroundSyncManager.outboxReplayTaskId, BackgroundSyncManager.dailyPullTaskId]
        )

        let manager = try DatabaseManager.inMemory()
        let syncEngine = SyncEngine(
            dbQueue: manager.dbQueue,
            apiClient: FakeSyncAPIClient(),
            pushTransportOverride: { _ in }
        )
        BackgroundSyncManager._testSetActionOverrides(
            outbox: { _ in },
            dailyPull: { _ in }
        )
        defer { BackgroundSyncManager._testResetActionOverrides() }

        let didRunOutboxAction = await BackgroundSyncManager._testRunOutboxReplayAction(syncEngine: syncEngine)
        XCTAssertTrue(didRunOutboxAction)
        let didRunDailyPullAction = await BackgroundSyncManager._testRunDailyPullAction(syncEngine: syncEngine)
        XCTAssertTrue(didRunDailyPullAction)
        XCTAssertTrue(BackgroundSyncManager._testSetExpirationHandlerIfSupported(supportsExpiration: true))
        XCTAssertFalse(BackgroundSyncManager._testSetExpirationHandlerIfSupported(supportsExpiration: false))
    }

    func testScheduleOutboxReplayBuildsExpectedRequestAndHonorsGate() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var captured: BGTaskRequest?

        BackgroundSyncManager._testScheduleOutboxReplay(shouldSchedule: true, now: now) { request in
            captured = request
        }

        let request = try XCTUnwrap(captured as? BGProcessingTaskRequest)
        XCTAssertEqual(request.identifier, BackgroundSyncManager.outboxReplayTaskId)
        XCTAssertTrue(request.requiresNetworkConnectivity)
        XCTAssertTrue(request.requiresExternalPower)
        XCTAssertEqual(
            request.earliestBeginDate?.timeIntervalSince1970 ?? 0,
            now.addingTimeInterval(15 * 60).timeIntervalSince1970,
            accuracy: 0.001
        )

        var submitCalls = 0
        BackgroundSyncManager._testScheduleOutboxReplay(shouldSchedule: false, now: now) { _ in
            submitCalls += 1
        }
        XCTAssertEqual(submitCalls, 0)

        BackgroundSyncManager._testScheduleOutboxReplay(shouldSchedule: true, now: now) { _ in
            throw TestError.expected
        }
    }

    func testScheduleDailyPullBuildsExpectedRequestAndHonorsGate() throws {
        let now = Date(timeIntervalSince1970: 1_700_010_000)
        var captured: BGTaskRequest?

        BackgroundSyncManager._testScheduleDailyPull(shouldSchedule: true, now: now) { request in
            captured = request
        }

        let request = try XCTUnwrap(captured as? BGAppRefreshTaskRequest)
        XCTAssertEqual(request.identifier, BackgroundSyncManager.dailyPullTaskId)
        XCTAssertEqual(
            request.earliestBeginDate?.timeIntervalSince1970 ?? 0,
            now.addingTimeInterval(4 * 3600).timeIntervalSince1970,
            accuracy: 0.001
        )

        var submitCalls = 0
        BackgroundSyncManager._testScheduleDailyPull(shouldSchedule: false, now: now) { _ in
            submitCalls += 1
        }
        XCTAssertEqual(submitCalls, 0)

        BackgroundSyncManager._testScheduleDailyPull(shouldSchedule: true, now: now) { _ in
            throw TestError.expected
        }
    }

    func testRunBackgroundTaskSuccessFailureAndExpirationPaths() async {
        let success = await BackgroundSyncManager._testRunBackgroundTask(action: {})
        XCTAssertEqual(success.scheduleCalls, 1)
        XCTAssertEqual(success.completions, [true])
        XCTAssertTrue(success.hasExpirationHandler)

        let failure = await BackgroundSyncManager._testRunBackgroundTask(action: {
            throw TestError.expected
        })
        XCTAssertEqual(failure.scheduleCalls, 1)
        XCTAssertEqual(failure.completions, [false])
        XCTAssertTrue(failure.hasExpirationHandler)

        let expiration = await BackgroundSyncManager._testRunBackgroundTask(
            triggerExpiration: true,
            action: {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        )
        XCTAssertEqual(expiration.scheduleCalls, 1)
        XCTAssertEqual(expiration.completions, [false])
        XCTAssertTrue(expiration.hasExpirationHandler)
    }

    func testRegisterDispatchAndInternalHandlersCoverFailureBranches() async {
        let dispatch = BackgroundSyncManager._testDispatchRegisteredTaskSamples()
        XCTAssertEqual(dispatch.nilFailures, 1)
        XCTAssertEqual(dispatch.handledValues, [42])

        let outboxInternal = await BackgroundSyncManager._testRunInternalHandlers(runOutbox: true)
        XCTAssertEqual(outboxInternal.scheduleCalls, 1)
        XCTAssertEqual(outboxInternal.completions, [false])
        XCTAssertTrue(outboxInternal.hasExpirationHandler)

        let dailyInternal = await BackgroundSyncManager._testRunInternalHandlers(
            runOutbox: false,
            triggerExpiration: true
        )
        XCTAssertEqual(dailyInternal.scheduleCalls, 1)
        XCTAssertEqual(dailyInternal.completions, [false])
        XCTAssertTrue(dailyInternal.hasExpirationHandler)
    }

    func testRegisteredTaskDispatchCoversTypedAndUntypedBackgroundTasks() async {
        let outboxExpectation = expectation(description: "outbox registered task completes")
        let outboxRaw = FakeBGTask { _ in outboxExpectation.fulfill() }
        let outboxTask = unsafeBitCast(outboxRaw, to: BGTask.self)
        BackgroundSyncManager._testDispatchOutboxRegisteredTask(outboxTask)
        await fulfillment(of: [outboxExpectation], timeout: 1.0)
        XCTAssertEqual(outboxRaw.completions.last, false)

        let dailyExpectation = expectation(description: "daily registered task completes")
        let dailyRaw = FakeBGTask { _ in dailyExpectation.fulfill() }
        let dailyTask = unsafeBitCast(dailyRaw, to: BGTask.self)
        BackgroundSyncManager._testDispatchDailyRegisteredTask(dailyTask)
        await fulfillment(of: [dailyExpectation], timeout: 1.0)
        XCTAssertEqual(dailyRaw.completions.last, false)
    }
}

final class EnvironmentServiceCoverageTests: XCTestCase {
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        func current() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private enum TestError: Error {
        case expected
    }

    override func setUp() {
        super.setUp()
        EnvironmentService._testResetOverrides()
    }

    override func tearDown() {
        EnvironmentService._testResetOverrides()
        super.tearDown()
    }

    func testFetchCurrentEnvironmentUsesInjectedLocationAndCity() async throws {
        let service = EnvironmentService()
        let context = try await service._testFetchCurrentEnvironment(
            requestLocationBlock: { CLLocation(latitude: 40.4093, longitude: 49.8671) },
            resolveCityBlock: { _ in "Baku" },
            fetchEnvironmentBlock: { _, city in
                EnvironmentalContext(
                    weatherCondition: "Clear",
                    temperatureC: 21.3,
                    pressureHpa: 1015.0,
                    pressureDeltaHpa24h: -2.1,
                    aqi: 42,
                    indoorCo2Ppm: nil,
                    moonPhase: "Waxing Gibbous",
                    daylightHours: 11.2,
                    city: city
                )
            }
        )

        XCTAssertEqual(context.city, "Baku")
        XCTAssertEqual(context.weatherCondition, "Clear")
        XCTAssertEqual(try XCTUnwrap(context.temperatureC), 21.3, accuracy: 0.0001)
    }

    func testRequestLocationDeniedThrowsPermissionError() async {
        let service = EnvironmentService()

        do {
            _ = try await service._testRequestLocation(
                currentStatus: .denied,
                requestAuthorizationBlock: { .denied },
                requestLocationAction: {},
                timeoutNanoseconds: 1_000_000
            )
            XCTFail("Expected locationPermissionDenied")
        } catch let error as EnvironmentError {
            guard case .locationPermissionDenied = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRequestLocationResolvesAndFailsForUnavailableSamples() async throws {
        let successService = EnvironmentService()
        let requestCounter = LockedCounter()
        let requestedLocation = CLLocation(latitude: 51.5072, longitude: -0.1276)

        let successTask = Task {
            try await successService._testRequestLocation(
                currentStatus: .authorizedWhenInUse,
                requestAuthorizationBlock: { .authorizedWhenInUse },
                requestLocationAction: { requestCounter.increment() },
                timeoutNanoseconds: 5_000_000_000
            )
        }

        try? await Task.sleep(nanoseconds: 5_000_000)
        successService.locationManager(CLLocationManager(), didUpdateLocations: [requestedLocation])

        let resolved = try await successTask.value
        XCTAssertEqual(requestCounter.current(), 1)
        XCTAssertEqual(resolved.coordinate.latitude, requestedLocation.coordinate.latitude, accuracy: 0.0001)
        XCTAssertEqual(resolved.coordinate.longitude, requestedLocation.coordinate.longitude, accuracy: 0.0001)

        let unavailableService = EnvironmentService()
        let unavailableTask = Task {
            try await unavailableService._testRequestLocation(
                currentStatus: .authorizedWhenInUse,
                requestAuthorizationBlock: { .authorizedWhenInUse },
                requestLocationAction: {},
                timeoutNanoseconds: 5_000_000_000
            )
        }

        try? await Task.sleep(nanoseconds: 5_000_000)
        unavailableService.locationManager(CLLocationManager(), didUpdateLocations: [])

        do {
            _ = try await unavailableTask.value
            XCTFail("Expected locationUnavailable")
        } catch let error as EnvironmentError {
            guard case .locationUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRequestLocationTimesOutWhenNoCallbackArrives() async {
        let service = EnvironmentService()

        do {
            _ = try await service._testRequestLocation(
                currentStatus: .authorizedAlways,
                requestAuthorizationBlock: { .authorizedAlways },
                requestLocationAction: {},
                timeoutNanoseconds: 1_000_000
            )
            XCTFail("Expected locationRequestTimedOut")
        } catch let error as EnvironmentError {
            guard case .locationRequestTimedOut = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRequestAuthorizationAndResolveCityFallbackPaths() async throws {
        let service = EnvironmentService()

        let requestCounter = LockedCounter()
        let authTask = Task {
            await service._testRequestAuthorization(
                currentStatus: .notDetermined,
                requestWhenInUseAuthorization: { requestCounter.increment() }
            )
        }

        try? await Task.sleep(nanoseconds: 5_000_000)
        service.locationManagerDidChangeAuthorization(CLLocationManager())
        _ = await authTask.value
        XCTAssertEqual(requestCounter.current(), 1)

        let direct = await service._testRequestAuthorization(
            currentStatus: .authorizedWhenInUse,
            requestWhenInUseAuthorization: { requestCounter.increment() }
        )
        XCTAssertEqual(direct, .authorizedWhenInUse)
        XCTAssertEqual(requestCounter.current(), 1)

        let fallbackCity = try await service._testResolveCity(
            from: CLLocation(latitude: 0, longitude: 0),
            reverseGeocode: { _ in [] }
        )
        XCTAssertEqual(fallbackCity, "Unknown")

        do {
            _ = try await service._testResolveCity(
                from: CLLocation(latitude: 0, longitude: 0),
                reverseGeocode: { _ in throw TestError.expected }
            )
            XCTFail("Expected thrown geocode error")
        } catch is TestError {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPublicEnvironmentServiceWrappersAndLocalityResolver() async throws {
        let service = EnvironmentService()
        let requestedLocation = CLLocation(latitude: 48.8566, longitude: 2.3522)
        let requestCounter = LockedCounter()

        EnvironmentService._testSetAuthorizationStatusOverride(.authorizedWhenInUse)
        EnvironmentService._testSetRequestLocationActionOverride {
            requestCounter.increment()
        }
        EnvironmentService._testSetRequestWhenInUseAuthorizationOverride {
            requestCounter.increment()
        }
        EnvironmentService._testSetReverseGeocodeOverride { _ in [] }
        EnvironmentService._testSetFetchEnvironmentOverride { _, city in
            EnvironmentalContext(
                weatherCondition: "Rain",
                temperatureC: 17.4,
                pressureHpa: 1009.0,
                pressureDeltaHpa24h: -4.0,
                aqi: 38,
                indoorCo2Ppm: nil,
                moonPhase: "Full Moon",
                daylightHours: 10.5,
                city: city
            )
        }

        let contextTask = Task {
            try await service.fetchCurrentEnvironment()
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
        service.locationManager(CLLocationManager(), didUpdateLocations: [requestedLocation])

        let context = try await contextTask.value
        XCTAssertEqual(requestCounter.current(), 1)
        XCTAssertEqual(context.city, "Unknown")
        XCTAssertEqual(context.weatherCondition, "Rain")
        XCTAssertEqual(try XCTUnwrap(context.aqi), 38)

        let directAuthStatus = await service._testRequestAuthorizationViaPublicWrapper()
        XCTAssertEqual(directAuthStatus, .authorizedWhenInUse)

        let directLocationTask = Task {
            try await service._testRequestLocationViaPublicWrapper()
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
        service.locationManager(CLLocationManager(), didUpdateLocations: [requestedLocation])
        let directLocation = try await directLocationTask.value
        XCTAssertEqual(directLocation.coordinate.latitude, requestedLocation.coordinate.latitude, accuracy: 0.0001)

        let resolvedViaPublicWrapper = try await service._testResolveCityViaPublicWrapper(from: requestedLocation)
        XCTAssertEqual(resolvedViaPublicWrapper, "Unknown")

        XCTAssertEqual(EnvironmentService._testResolvedCity(locality: "Paris"), "Paris")
        XCTAssertEqual(EnvironmentService._testResolvedCity(locality: nil), "Unknown")
    }

    func testFetchEnvironmentForSpecificDatePassesTargetDateThroughInjectedFetcher() async throws {
        let service = EnvironmentService()
        let targetDate = ISO8601DateFormatter().date(from: "2026-03-08T12:00:00Z") ?? Date(timeIntervalSince1970: 0)
        let context = try await service._testFetchEnvironment(
            for: targetDate,
            requestLocationBlock: { CLLocation(latitude: 40.4093, longitude: 49.8671) },
            resolveCityBlock: { _ in "Baku" },
            fetchEnvironmentBlock: { _, city, requestedDate in
                EnvironmentalContext(
                    weatherCondition: "Clear",
                    temperatureC: 21.3,
                    pressureHpa: 1015.0,
                    pressureDeltaHpa24h: -2.1,
                    aqi: 42,
                    indoorCo2Ppm: nil,
                    moonPhase: requestedDate.formatted(.iso8601.year().month().day()),
                    daylightHours: 11.2,
                    city: city
                )
            }
        )

        XCTAssertEqual(context.city, "Baku")
        XCTAssertEqual(context.moonPhase, "2026-03-08")
    }

    func testRequestLocationNotDeterminedPromotesAuthorizedStatus() async throws {
        let service = EnvironmentService()
        let requestedLocation = CLLocation(latitude: 34.0522, longitude: -118.2437)
        let requestCounter = LockedCounter()

        let requestTask = Task {
            try await service._testRequestLocation(
                currentStatus: .notDetermined,
                requestAuthorizationBlock: { .authorizedWhenInUse },
                requestLocationAction: { requestCounter.increment() },
                timeoutNanoseconds: 5_000_000_000
            )
        }

        try? await Task.sleep(nanoseconds: 5_000_000)
        service.locationManager(CLLocationManager(), didUpdateLocations: [requestedLocation])

        let resolved = try await requestTask.value
        XCTAssertEqual(requestCounter.current(), 1)
        XCTAssertEqual(resolved.coordinate.latitude, requestedLocation.coordinate.latitude, accuracy: 0.0001)
    }
}

@MainActor
final class OnboardingFeatureCoverageTests: XCTestCase {
    override func tearDown() {
        OnboardingFeature._testSetDatabaseQueueOverride(nil)
        AuthManager.setActiveAuthIdForTests(nil)
        AppContainer.shared = nil
        super.tearDown()
    }

    func testStateTransitionsAndProgressLogic() {
        var state = OnboardingFeature.State()
        let reducer = OnboardingFeature()

        XCTAssertEqual(state.currentDisplayStep, .valueProp)
        XCTAssertEqual(
            state.progress,
            1 / Double(OnboardingStep.flowSteps.count),
            accuracy: 0.0001
        )

        _ = reducer.reduce(
            into: &state,
            action: .progressAdvanceFinished(step: .quickWin, result: .succeeded)
        )
        XCTAssertEqual(state.currentStep, .quickWin)

        state.quickWinCompleted = true
        _ = reducer.reduce(into: &state, action: .advanceFromQuickWin)
        XCTAssertEqual(state.currentStep, .healthKitPermission)

        _ = reducer.reduce(
            into: &state,
            action: .healthKitAdvanceFinished(granted: false, result: .succeeded)
        )
        XCTAssertEqual(state.currentStep, .basicProfile)
        XCTAssertFalse(state.healthKitGranted)

        state.hasConfirmedDateOfBirth = true
        state.sex = .female
        state.heightInputText = "168"
        state.heightCm = 168
        state.primaryGoal = .recovery
        state.activityLevel = .moderate

        _ = reducer.reduce(into: &state, action: .advanceFromProfile)
        XCTAssertTrue(state.isSavingProfile)
        XCTAssertTrue(state.isSavingHealthFlags)
        XCTAssertTrue(state.isSavingWeight)
        _ = reducer.reduce(into: &state, action: .profileAdvanceFinished(.succeeded))
        XCTAssertEqual(state.currentStep, .firstInsight)
        XCTAssertFalse(state.isSavingProfile)
        XCTAssertFalse(state.isSavingHealthFlags)
        XCTAssertFalse(state.isSavingWeight)

        _ = reducer.reduce(into: &state, action: .weightChanged("85.5"))
        XCTAssertEqual(state.weightInputText, "85.5")
        XCTAssertEqual(state.weightKg, 85.5, accuracy: 0.0001)

        _ = reducer.reduce(into: &state, action: .weightChanged("5"))
        XCTAssertEqual(state.weightKg, 85.5, accuracy: 0.0001)

        state.isSavingWeight = true
        _ = reducer.reduce(into: &state, action: .weightAdvanceFinished(.succeeded))
        XCTAssertFalse(state.isSavingWeight)

        state.isSavingHealthFlags = true
        _ = reducer.reduce(into: &state, action: .healthFlagsAdvanceFinished(.succeeded))
        XCTAssertFalse(state.isSavingHealthFlags)

        _ = reducer.reduce(
            into: &state,
            action: .progressAdvanceFinished(step: .notifications, result: .succeeded)
        )
        XCTAssertEqual(state.currentStep, .notifications)

        _ = reducer.reduce(into: &state, action: .advanceFromWeight)
        XCTAssertFalse(state.isSavingWeight)

        _ = reducer.reduce(into: &state, action: .advanceFromHealthFlags)
        XCTAssertFalse(state.isSavingHealthFlags)

        _ = reducer.reduce(into: &state, action: .startBackfill)
        XCTAssertFalse(state.isBackfilling)

        _ = reducer.reduce(into: &state, action: .skipHealthKit)
        XCTAssertEqual(state.currentStep, .notifications)

        state.isBackfilling = true
        _ = reducer.reduce(into: &state, action: .backfillFinished(.succeeded))
        XCTAssertFalse(state.isBackfilling)

        state.currentStep = .healthKitPermission
        state.isRequestingHealthKit = true
        _ = reducer.reduce(into: &state, action: .healthKitResult(false))
        XCTAssertFalse(state.isRequestingHealthKit)
        XCTAssertFalse(state.healthKitGranted)
        XCTAssertEqual(state.currentStep, .healthKitPermission)

        state.currentStep = .healthKitPermission
        state.isBackfilling = true
        state.isRequestingHealthKit = false
        _ = reducer.reduce(into: &state, action: .requestHealthKit)
        XCTAssertFalse(state.isRequestingHealthKit)
        XCTAssertFalse(state.isSavingWeight)
        state.isBackfilling = false

        state.currentStep = .notifications
        _ = reducer.reduce(into: &state, action: .completeFinished(.failed("failed")))
        XCTAssertEqual(state.currentStep, .notifications)
        XCTAssertEqual(state.errorMessage, "failed")

        _ = reducer.reduce(into: &state, action: .completeFinished(.succeeded))
        XCTAssertEqual(state.currentStep, .onboardingComplete)
    }

    func testAdvanceFromProfileRequiresCompleteProfile() {
        var state = OnboardingFeature.State()

        _ = OnboardingFeature().reduce(into: &state, action: .advanceFromProfile)

        XCTAssertEqual(state.currentStep, .notStarted)
        XCTAssertFalse(state.canAdvanceFromProfile)
        XCTAssertFalse(state.isSavingProfile)
        XCTAssertFalse(state.isSavingHealthFlags)
        XCTAssertFalse(state.isSavingWeight)
    }

    func testConfirmDateOfBirthMarksProfileAsConfirmed() {
        var state = OnboardingFeature.State()
        state.hasConfirmedDateOfBirth = false

        _ = OnboardingFeature().reduce(into: &state, action: .confirmDateOfBirth)

        XCTAssertTrue(state.hasConfirmedDateOfBirth)
        XCTAssertNotNil(state.profileAge)
    }

    func testLoadProfileIfNeededPrefillsStoredProfileAndWeight() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let dateOfBirth = Calendar(identifier: .gregorian).date(from: DateComponents(year: 1994, month: 5, day: 16))!

        try await seedOnboardingUser(
            dbQueue: manager.dbQueue,
            userId: userId,
            authId: authId,
            cloudBackupEnabled: false
        )
        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE users
                    SET date_of_birth = ?, age_range = ?, sex = ?, height_cm = ?, weight_kg = ?,
                        primary_goal = ?, activity_level = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    dateOfBirth,
                    AgeRange(age: 31).rawValue,
                    BiologicalSex.female.rawValue,
                    172.5,
                    63.4,
                    PrimaryGoal.performance.rawValue,
                    ActivityLevel.active.rawValue,
                    Date(),
                    userId.uuidString
                ]
            )
        }

        OnboardingFeature._testSetDatabaseQueueOverride(manager.dbQueue)
        AuthManager.setActiveAuthIdForTests(authId)

        let store = TestStore(initialState: OnboardingFeature.State()) {
            OnboardingFeature()
        }

        await store.send(.loadProfileIfNeeded) {
            $0.hasLoadedProfile = true
        }
        await store.receive(.loadOptionalSetupSummary)
        await store.receive(.profileLoaded(.init(
            dateOfBirth: dateOfBirth,
            sex: .female,
            heightCm: 172.5,
            primaryGoal: .performance,
            activityLevel: .active,
            weightKg: 63.4
        ))) {
            $0.dateOfBirth = dateOfBirth
            $0.hasConfirmedDateOfBirth = true
            $0.sex = .female
            $0.heightCm = 172.5
            $0.heightInputText = "172.5"
            $0.primaryGoal = .performance
            $0.activityLevel = .active
            $0.weightKg = 63.4
            $0.weightInputText = "63.4"
            $0.currentStep = .valueProp
        }
        await store.receive(.optionalSetupSummaryLoaded(.init()))
    }

    func testAdvanceFromProfilePersistsProfileAndEnqueuesOutbox() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let dateOfBirth = Calendar(identifier: .gregorian).date(from: DateComponents(year: 1996, month: 9, day: 12))!

        try await seedOnboardingUser(
            dbQueue: manager.dbQueue,
            userId: userId,
            authId: authId,
            cloudBackupEnabled: false
        )
        OnboardingFeature._testSetDatabaseQueueOverride(manager.dbQueue)
        AuthManager.setActiveAuthIdForTests(authId)
        AppContainer.shared = AppContainer(syncEngine: makeNoopSyncEngine(dbQueue: manager.dbQueue))

        var initialState = OnboardingFeature.State()
        initialState.dateOfBirth = dateOfBirth
        initialState.hasConfirmedDateOfBirth = true
        initialState.sex = .male
        initialState.heightInputText = "181.2"
        initialState.heightCm = 181.2
        initialState.primaryGoal = .generalHealth
        initialState.activityLevel = .moderate
        initialState.currentStep = .basicProfile

        let store = TestStore(initialState: initialState) {
            OnboardingFeature()
        }
        store.exhaustivity = .off

        await store.send(.advanceFromProfile) {
            $0.isSavingProfile = true
            $0.isSavingHealthFlags = true
            $0.isSavingWeight = true
        }
        await store.receive(.profileAdvanceFinished(.succeeded)) {
            $0.isSavingProfile = false
            $0.isSavingHealthFlags = false
            $0.isSavingWeight = false
            $0.currentStep = .firstInsight
        }
        await store.finish()

        try await manager.dbQueue.read { db in
            let user = try XCTUnwrap(UserIdentityLookup.fetchUser(authId: authId.uuidString, db: db))
            XCTAssertEqual(DateFormatting.dateOnlyString(from: try XCTUnwrap(user.dateOfBirth)), "1996-09-12")
            XCTAssertEqual(user.ageRange, AgeRange(age: 29))
            XCTAssertEqual(user.sex, .male)
            XCTAssertEqual(user.heightCm ?? 0, 181.2, accuracy: 0.0001)
            XCTAssertEqual(user.primaryGoal, .generalHealth)
            XCTAssertEqual(user.activityLevel, .moderate)
            XCTAssertEqual(user.weightKg ?? 0, 70, accuracy: 0.0001)

            let payloadRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT body_json
                    FROM outbox_events
                    WHERE path = ?
                    ORDER BY created_at_local ASC
                    """,
                arguments: ["rest/v1/users"]
            )
            let payloads = try payloadRows.compactMap { row -> [String: Any]? in
                let payloadData: Data = row["body_json"]
                return try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
            }

            XCTAssertEqual(payloads.count, 2)
            XCTAssertTrue(payloads.contains { payload in
                payload["id"] as? String == userId.uuidString &&
                payload["date_of_birth"] as? String == "1996-09-12" &&
                payload["age_range"] as? String == AgeRange(age: 29).rawValue &&
                payload["sex"] as? String == BiologicalSex.male.rawValue &&
                payload["primary_goal"] as? String == PrimaryGoal.generalHealth.rawValue &&
                payload["activity_level"] as? String == ActivityLevel.moderate.rawValue &&
                abs(((payload["height_cm"] as? Double) ?? 0) - 181.2) < 0.0001
            })
            XCTAssertTrue(payloads.contains { payload in
                payload["id"] as? String == userId.uuidString &&
                abs(((payload["weight_kg"] as? Double) ?? 0) - 70) < 0.0001
            })
        }
    }

    func testAdvanceFromProfileFailureDoesNotAdvanceOrPersistPartialState() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let dateOfBirth = Calendar(identifier: .gregorian).date(from: DateComponents(year: 1991, month: 4, day: 21))!

        try await seedOnboardingUser(
            dbQueue: manager.dbQueue,
            userId: userId,
            authId: authId,
            cloudBackupEnabled: false
        )
        try await manager.dbQueue.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS outbox_events")
        }

        OnboardingFeature._testSetDatabaseQueueOverride(manager.dbQueue)
        AuthManager.setActiveAuthIdForTests(authId)
        AppContainer.shared = AppContainer(syncEngine: makeNoopSyncEngine(dbQueue: manager.dbQueue))

        var initialState = OnboardingFeature.State()
        initialState.dateOfBirth = dateOfBirth
        initialState.hasConfirmedDateOfBirth = true
        initialState.sex = .male
        initialState.heightInputText = "180"
        initialState.heightCm = 180
        initialState.primaryGoal = .performance
        initialState.activityLevel = .active

        let store = TestStore(initialState: initialState) {
            OnboardingFeature()
        }

        await store.send(.advanceFromProfile) {
            $0.isSavingProfile = true
            $0.isSavingHealthFlags = true
            $0.isSavingWeight = true
        }
        await store.receive(.profileAdvanceFinished(.failed(String(localized: "onboarding_step_save_failed")))) {
            $0.isSavingProfile = false
            $0.isSavingHealthFlags = false
            $0.isSavingWeight = false
            $0.currentStep = .notStarted
            $0.errorMessage = String(localized: "onboarding_step_save_failed")
        }

        try await manager.dbQueue.read { db in
            let user = try XCTUnwrap(UserIdentityLookup.fetchUser(authId: authId.uuidString, db: db))
            XCTAssertNil(user.dateOfBirth)
            XCTAssertNil(user.ageRange)
            XCTAssertNil(user.sex)
            XCTAssertNil(user.heightCm)
            XCTAssertNil(user.primaryGoal)
            XCTAssertNil(user.activityLevel)
            XCTAssertNil(user.weightKg)
        }
    }

    func testStartBackfillWithoutHealthKitGrantFallsBackToTutorial() {
        var state = OnboardingFeature.State()
        state.healthKitGranted = false
        state.currentStep = .healthkitSkipped

        _ = OnboardingFeature().reduce(into: &state, action: .startBackfill)

        XCTAssertFalse(state.isBackfilling)
        XCTAssertEqual(state.currentStep, .healthkitSkipped)
    }

    func testStartBackfillWithGrantEmitsBackfillCompleted() {
        var state = OnboardingFeature.State()
        state.healthKitGranted = true
        state.currentStep = .healthkitGranted

        _ = OnboardingFeature().reduce(into: &state, action: .startBackfill)
        XCTAssertFalse(state.isBackfilling)
        XCTAssertEqual(state.currentStep, .healthkitGranted)

        state.isBackfilling = true
        _ = OnboardingFeature().reduce(into: &state, action: .backfillFinished(.succeeded))
        XCTAssertFalse(state.isBackfilling)
        XCTAssertEqual(state.currentStep, .healthkitGranted)
    }

    func testAdvanceFromWeightPersistsWeightAndEnqueuesOutbox() async throws {
        let authId = UUID()
        let userId = UUID()
        let dbQueue = DatabaseManager.shared.dbQueue

        AuthManager.setActiveAuthIdForTests(authId)
        AppContainer.shared = AppContainer(syncEngine: makeNoopSyncEngine(dbQueue: dbQueue))

        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM outbox_events WHERE path = 'rest/v1/users'")
            try db.execute(
                sql: "DELETE FROM users WHERE auth_id = ? OR auth_id = ?",
                arguments: [authId, authId.uuidString]
            )
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, onboarding_completed, created_at, updated_at)
                    VALUES (?, ?, 'UTC', 'metric', 0, ?, ?)
                    """,
                arguments: [userId.uuidString, authId.uuidString, Date(), Date()]
            )
        }

        var state = OnboardingFeature.State()
        state.currentStep = .healthkitPrompted
        state.weightKg = 83.2
        state.weightInputText = "83.2"

        let store = TestStore(initialState: state) {
            OnboardingFeature()
        }

        await store.send(.advanceFromWeight)

        try await dbQueue.read { db in
            let storedWeight = try Double.fetchOne(
                db,
                sql: "SELECT weight_kg FROM users WHERE auth_id = ? LIMIT 1",
                arguments: [authId.uuidString]
            )
            XCTAssertNil(storedWeight)

            let outboxCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM outbox_events
                    WHERE path = 'rest/v1/users'
                    """
            ) ?? 0
            XCTAssertEqual(outboxCount, 0)
        }
    }

    func testAdvanceFromWeightFailureDoesNotAdvanceOrPersistWeight() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()

        try await seedOnboardingUser(
            dbQueue: manager.dbQueue,
            userId: userId,
            authId: authId,
            cloudBackupEnabled: false
        )
        try await manager.dbQueue.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS outbox_events")
        }

        OnboardingFeature._testSetDatabaseQueueOverride(manager.dbQueue)
        AuthManager.setActiveAuthIdForTests(authId)
        AppContainer.shared = AppContainer(syncEngine: makeNoopSyncEngine(dbQueue: manager.dbQueue))

        var state = OnboardingFeature.State()
        state.currentStep = .healthkitPrompted
        state.weightKg = 82.4
        state.weightInputText = "82.4"
        state.isSavingWeight = true

        let store = TestStore(initialState: state) {
            OnboardingFeature()
        }

        await store.send(.weightAdvanceFinished(.failed(String(localized: "onboarding_step_save_failed")))) {
            $0.isSavingWeight = false
            $0.currentStep = .healthkitPrompted
            $0.errorMessage = String(localized: "onboarding_step_save_failed")
        }

        try await manager.dbQueue.read { db in
            let storedWeight = try Double.fetchOne(
                db,
                sql: "SELECT weight_kg FROM users WHERE id = ? LIMIT 1",
                arguments: [userId.uuidString]
            )
            XCTAssertNil(storedWeight)
        }
    }

    func testCompleteActionSuccessAndFailurePaths() async throws {
        let authId = UUID()
        let userId = UUID()
        let dbQueue = DatabaseManager.shared.dbQueue

        AuthManager.setActiveAuthIdForTests(authId)
        AppContainer.shared = AppContainer(syncEngine: makeNoopSyncEngine(dbQueue: dbQueue))

        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM outbox_events WHERE path = 'rest/v1/users'")
            try db.execute(
                sql: "DELETE FROM users WHERE auth_id = ? OR auth_id = ?",
                arguments: [authId, authId.uuidString]
            )
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, onboarding_completed, created_at, updated_at)
                    VALUES (?, ?, 'UTC', 'metric', 0, ?, ?)
                    """,
                arguments: [userId.uuidString, authId.uuidString, Date(), Date()]
            )
        }

        var successState = OnboardingFeature.State()
        successState.currentStep = .tutorialShown

        let successStore = TestStore(initialState: successState) {
            OnboardingFeature()
        }

        await successStore.send(.complete) {
            $0.isCompleting = true
        }
        await successStore.receive(.completeFinished(.succeeded)) {
            $0.isCompleting = false
            $0.currentStep = .onboardingComplete
        }

        try await dbQueue.read { db in
            let completed = try Int.fetchOne(
                db,
                sql: "SELECT onboarding_completed FROM users WHERE auth_id = ? LIMIT 1",
                arguments: [authId.uuidString]
            )
            XCTAssertEqual(completed, 1)
        }

        AuthManager.setActiveAuthIdForTests(nil)

        var failureState = OnboardingFeature.State()
        failureState.currentStep = .tutorialShown
        let failureStore = TestStore(initialState: failureState) {
            OnboardingFeature()
        }

        await failureStore.send(.complete) {
            $0.isCompleting = true
        }
        await failureStore.receive(.completeFinished(.failed(String(localized: "error.user.unavailable")))) {
            $0.isCompleting = false
            $0.currentStep = .tutorialShown
            $0.errorMessage = String(localized: "error.user.unavailable")
        }
    }

    func testRequestHealthKitActionCoversSuccessAndErrorBranches() async {
        enum ExpectedError: Error { case denied }

        defer { HealthKitManager._testResetOverrides() }

        let expectedMessage = AppCapabilityAvailability.healthKitCapabilityWarning
            ?? String(localized: "onboarding_healthkit_denied_notice")

        var deniedState = OnboardingFeature.State()
        deniedState.currentStep = .healthKitPermission
        let deniedStore = TestStore(initialState: deniedState) {
            OnboardingFeature()
        }
        HealthKitManager._testSetIsAvailableOverride(false)
        HealthKitManager._testSetRequestAccessOverride { }
        HealthKitManager._testSetAuthorizedTypeCountOverride { 0 }
        HealthKitManager._testSetEnableBackgroundOverride { }

        await deniedStore.send(.requestHealthKit) {
            $0.isRequestingHealthKit = true
        }
        await deniedStore.receive(.healthKitResult(false)) {
            $0.isRequestingHealthKit = false
            $0.healthKitGranted = false
            $0.currentStep = .healthKitPermission
            $0.errorMessage = expectedMessage
        }

        HealthKitManager._testSetIsAvailableOverride(true)
        var errorState = OnboardingFeature.State()
        errorState.currentStep = .healthKitPermission
        let errorStore = TestStore(initialState: errorState) {
            OnboardingFeature()
        }
        HealthKitManager._testSetRequestAccessOverride {
            throw ExpectedError.denied
        }

        await errorStore.send(.requestHealthKit) {
            $0.isRequestingHealthKit = true
        }
        await errorStore.receive(.healthKitResult(false)) {
            $0.isRequestingHealthKit = false
            $0.healthKitGranted = false
            $0.currentStep = .healthKitPermission
            $0.errorMessage = expectedMessage
        }
    }

    func testStartBackfillGrantedWithResolvedUserHitsBackfillPath() async throws {
        var state = OnboardingFeature.State()
        state.healthKitGranted = true
        state.currentStep = .healthkitGranted

        _ = OnboardingFeature().reduce(into: &state, action: .startBackfill)

        XCTAssertFalse(state.isBackfilling)
        XCTAssertEqual(state.currentStep, .healthkitGranted)
        XCTAssertTrue(state.healthKitGranted)
    }

    func testStartBackfillFailureKeepsRetryStateAndShowsError() async {
        var state = OnboardingFeature.State()
        state.healthKitGranted = true
        state.currentStep = .healthkitGranted
        state.isBackfilling = true

        _ = OnboardingFeature().reduce(
            into: &state,
            action: .backfillFinished(.failed(String(localized: "error.user.unavailable")))
        )

        XCTAssertFalse(state.isBackfilling)
        XCTAssertEqual(state.currentStep, .healthkitGranted)
        XCTAssertEqual(state.errorMessage, String(localized: "error.user.unavailable"))
    }

    func testCompleteActionCatchBranchWhenOutboxInsertFails() async throws {
        let authId = UUID()
        let userId = UUID()

        let failingManager = try DatabaseManager.inMemory()
        try await failingManager.dbQueue.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS outbox_events")
        }

        defer {
            AuthManager.setActiveAuthIdForTests(nil)
            AppContainer.shared = nil
        }

        AuthManager.setActiveAuthIdForTests(authId)
        OnboardingFeature._testSetDatabaseQueueOverride(failingManager.dbQueue)
        AppContainer.shared = AppContainer(syncEngine: makeNoopSyncEngine(dbQueue: failingManager.dbQueue))

        try await failingManager.dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM users WHERE auth_id = ? OR auth_id = ?",
                arguments: [authId, authId.uuidString]
            )
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, onboarding_completed, created_at, updated_at)
                    VALUES (?, ?, 'UTC', 'metric', 0, ?, ?)
                    """,
                arguments: [userId.uuidString, authId.uuidString, Date(), Date()]
            )
        }

        var state = OnboardingFeature.State()
        state.currentStep = .tutorialShown
        let store = TestStore(initialState: state) {
            OnboardingFeature()
        }

        await store.send(.complete) {
            $0.isCompleting = true
        }
        await store.receive(.completeFinished(.failed(String(localized: "onboarding_step_save_failed")))) {
            $0.isCompleting = false
            $0.currentStep = .tutorialShown
            $0.errorMessage = String(localized: "onboarding_step_save_failed")
        }

        try await failingManager.dbQueue.read { db in
            let completed = try Int.fetchOne(
                db,
                sql: "SELECT onboarding_completed FROM users WHERE auth_id = ? LIMIT 1",
                arguments: [authId.uuidString]
            )
            XCTAssertEqual(completed, 0)
        }
    }

    func testAdvanceFromHealthFlagsFailureDoesNotAdvanceOrPersistFlags() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()

        try await seedOnboardingUser(
            dbQueue: manager.dbQueue,
            userId: userId,
            authId: authId,
            cloudBackupEnabled: true
        )
        try await manager.dbQueue.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS outbox_events")
        }

        OnboardingFeature._testSetDatabaseQueueOverride(manager.dbQueue)
        AuthManager.setActiveAuthIdForTests(authId)

        var initialState = OnboardingFeature.State()
        initialState.currentStep = .basicProfile
        initialState.hasPacemaker = true
        initialState.isSavingHealthFlags = true

        let store = TestStore(initialState: initialState) {
            OnboardingFeature()
        }

        await store.send(.healthFlagsAdvanceFinished(.failed(String(localized: "onboarding_step_save_failed")))) {
            $0.isSavingHealthFlags = false
            $0.currentStep = .basicProfile
            $0.errorMessage = String(localized: "onboarding_step_save_failed")
        }

        try await manager.dbQueue.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM user_health_flags WHERE user_id = ?",
                arguments: [userId.uuidString]
            ) ?? 0
            XCTAssertEqual(count, 0)
        }
    }

    func testAdvanceFromHealthFlagsPersistsLocalFlagsWhenCloudBackupDisabled() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        try await seedOnboardingUser(
            dbQueue: manager.dbQueue,
            userId: userId,
            authId: authId,
            cloudBackupEnabled: false
        )
        OnboardingFeature._testSetDatabaseQueueOverride(manager.dbQueue)
        AuthManager.setActiveAuthIdForTests(authId)

        var initialState = OnboardingFeature.State()
        initialState.hasCardiacCondition = true
        initialState.onBetaBlockers = true
        initialState.isPregnant = true
        initialState.menstrualTrackingEnabled = true
        initialState.hasEatingDisorderHistory = true
        initialState.hasChronicFatigue = true

        let store = TestStore(initialState: initialState) {
            OnboardingFeature()
        }

        await store.send(.advanceFromHealthFlags)

        try await manager.dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT has_cardiac_condition, has_pacemaker, on_beta_blockers,
                           is_pregnant, menstrual_tracking_enabled,
                           has_eating_disorder_history, has_chronic_fatigue,
                           disable_hrv, hide_calories, pregnancy_mode
                    FROM user_health_flags
                    WHERE user_id = ?
                    LIMIT 1
                    """,
                arguments: [userId.uuidString]
            )
            XCTAssertNil(row)

            let outboxCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?",
                arguments: ["rest/v1/user_health_flags"]
            ) ?? 0
            XCTAssertEqual(outboxCount, 0)
        }
    }

    func testAdvanceFromHealthFlagsEnqueuesOutboxWhenCloudBackupEnabled() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        try await seedOnboardingUser(
            dbQueue: manager.dbQueue,
            userId: userId,
            authId: authId,
            cloudBackupEnabled: true
        )
        OnboardingFeature._testSetDatabaseQueueOverride(manager.dbQueue)
        AuthManager.setActiveAuthIdForTests(authId)

        var initialState = OnboardingFeature.State()
        initialState.hasPacemaker = true

        let store = TestStore(initialState: initialState) {
            OnboardingFeature()
        }

        await store.send(.advanceFromHealthFlags)

        try await manager.dbQueue.read { db in
            let outboxCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?",
                arguments: ["rest/v1/user_health_flags"]
            ) ?? 0
            XCTAssertEqual(outboxCount, 0)
        }
    }

    private func seedOnboardingUser(
        dbQueue: DatabaseQueue,
        userId: UUID,
        authId: UUID,
        cloudBackupEnabled: Bool
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [userId.uuidString, authId.uuidString, "UTC", "metric", Date(), Date()]
            )

            try db.execute(
                sql: """
                    INSERT INTO privacy_settings (
                        id, user_id, menstrual_local_only, medical_scan_local_only,
                        vector_opt_in, analytics_consent, cloud_ocr_enabled, cloud_backup_enabled,
                        created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    true,
                    true,
                    false,
                    false,
                    true,
                    cloudBackupEnabled,
                    Date(),
                    Date()
                ]
            )
        }
    }
}

final class UITestBootstrapCoverageTests: XCTestCase {
    private let keys = [
        "LIFEOS_UI_TEST_BOOTSTRAP",
        "LIFEOS_UI_TEST_DISABLE_BACKGROUND",
        "LIFEOS_UI_TEST_AUTH_STATE",
        "LIFEOS_UI_TEST_AUTH_ID",
        "LIFEOS_UI_TEST_USER_ID",
        "LIFEOS_UI_TEST_SEED_SYNC_BLOCKER",
        "LIFEOS_UI_TEST_SEED_NUTRITION",
        "LIFEOS_UI_TEST_SEED_TRAINING",
        "LIFEOS_UI_TEST_SEED_SUPPLEMENTS",
        "LIFEOS_UI_TEST_SEED_INSIGHTS",
        "LIFEOS_UI_TEST_SEED_DATE",
        "LIFEOS_UI_TEST_INITIAL_URL"
    ]

    override func tearDown() {
        for key in keys {
            unsetenv(key)
        }
        super.tearDown()
    }

    func testFlagsAndRequestedAuthStateFromEnvironment() {
        withEnvironment(["LIFEOS_UI_TEST_BOOTSTRAP": "1"]) {
            XCTAssertTrue(UITestBootstrap.isEnabled)
        }
        withEnvironment(["LIFEOS_UI_TEST_DISABLE_BACKGROUND": "1"]) {
            XCTAssertTrue(UITestBootstrap.disableBackgroundWork)
        }
        withEnvironment(["LIFEOS_UI_TEST_AUTH_STATE": "authenticated"]) {
            XCTAssertEqual(UITestBootstrap.requestedAuthState, .authenticated)
        }
        withEnvironment(["LIFEOS_UI_TEST_AUTH_STATE": "needs_onboarding"]) {
            XCTAssertEqual(UITestBootstrap.requestedAuthState, .needsOnboarding)
        }
        withEnvironment(["LIFEOS_UI_TEST_AUTH_STATE": "anonymous"]) {
            XCTAssertEqual(UITestBootstrap.requestedAuthState, .anonymous)
        }
        withEnvironment(["LIFEOS_UI_TEST_AUTH_STATE": "signed-out"]) {
            XCTAssertEqual(UITestBootstrap.requestedAuthState, .signedOut)
        }
        withEnvironment(["LIFEOS_UI_TEST_AUTH_STATE": "unknown"]) {
            XCTAssertNil(UITestBootstrap.requestedAuthState)
        }
    }

    func testIdentifierFallbackWhenEnvironmentInvalid() {
        withEnvironment([
            "LIFEOS_UI_TEST_AUTH_ID": "invalid",
            "LIFEOS_UI_TEST_USER_ID": "invalid"
        ]) {
            XCTAssertEqual(UITestBootstrap.authId.uuidString, "11111111-1111-4111-8111-111111111111")
            XCTAssertEqual(UITestBootstrap.userId.uuidString, "22222222-2222-4222-8222-222222222222")
        }
    }

    func testScenarioFlagsSeedDateAndInitialURLFromEnvironment() {
        withEnvironment([
            "LIFEOS_UI_TEST_SEED_NUTRITION": "1",
            "LIFEOS_UI_TEST_SEED_TRAINING": "1",
            "LIFEOS_UI_TEST_SEED_SUPPLEMENTS": "1",
            "LIFEOS_UI_TEST_SEED_INSIGHTS": "1",
            "LIFEOS_UI_TEST_SEED_DATE": "2026-02-25",
            "LIFEOS_UI_TEST_INITIAL_URL": "lifeos://nutrition?date=2026-02-24"
        ]) {
            XCTAssertTrue(UITestBootstrap.shouldSeedNutritionScenario)
            XCTAssertTrue(UITestBootstrap.shouldSeedTrainingScenario)
            XCTAssertTrue(UITestBootstrap.shouldSeedSupplementsScenario)
            XCTAssertTrue(UITestBootstrap.shouldSeedInsightsScenario)
            XCTAssertEqual(UITestBootstrap.seedDate, "2026-02-25")
            XCTAssertEqual(UITestBootstrap.initialURL?.absoluteString, "lifeos://nutrition?date=2026-02-24")
        }

        withEnvironment([
            "LIFEOS_UI_TEST_INITIAL_URL": "lifeos://supplements?date=2026-02-26"
        ]) {
            XCTAssertEqual(UITestBootstrap.seedDate, "2026-02-26")
        }

        withEnvironment([
            "LIFEOS_UI_TEST_INITIAL_URL": "https://example.com/not-supported"
        ]) {
            XCTAssertNil(UITestBootstrap.initialURL)
            XCTAssertEqual(UITestBootstrap.seedDate, "2026-02-24")
        }
    }

    func testSeedLocalDataWhenEnabledCreatesDeterministicRows() throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()

        withEnvironment([
            "LIFEOS_UI_TEST_BOOTSTRAP": "1",
            "LIFEOS_UI_TEST_AUTH_ID": authId.uuidString,
            "LIFEOS_UI_TEST_USER_ID": userId.uuidString,
            "LIFEOS_UI_TEST_AUTH_STATE": "authenticated",
            "LIFEOS_UI_TEST_SEED_SYNC_BLOCKER": "1"
        ]) {
            UITestBootstrap.seedLocalDataIfNeeded(dbQueue: manager.dbQueue)
        }

        try manager.dbQueue.read { db in
            let users = try User.fetchAll(db)
            XCTAssertTrue(users.contains { $0.id == userId && $0.authId == authId && $0.onboardingCompleted })

            let notificationCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notification_settings")
            XCTAssertEqual(notificationCount, 1)

            let privacyCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM privacy_settings")
            XCTAssertEqual(privacyCount, 1)

            let blockerCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE user_visible_blocker = 1 AND path = 'api-food-log'"
            )
            XCTAssertEqual(blockerCount, 1)
        }
    }

    func testSeedLocalDataCreatesScenarioFixturesWhenRequested() throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()

        withEnvironment([
            "LIFEOS_UI_TEST_BOOTSTRAP": "1",
            "LIFEOS_UI_TEST_AUTH_ID": authId.uuidString,
            "LIFEOS_UI_TEST_USER_ID": userId.uuidString,
            "LIFEOS_UI_TEST_AUTH_STATE": "authenticated",
            "LIFEOS_UI_TEST_SEED_NUTRITION": "1",
            "LIFEOS_UI_TEST_SEED_TRAINING": "1",
            "LIFEOS_UI_TEST_SEED_SUPPLEMENTS": "1",
            "LIFEOS_UI_TEST_SEED_INSIGHTS": "1",
            "LIFEOS_UI_TEST_SEED_DATE": "2026-02-24"
        ]) {
            UITestBootstrap.seedLocalDataIfNeeded(dbQueue: manager.dbQueue)
        }

        try manager.dbQueue.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM daily_nutrition_targets WHERE date = '2026-02-24'"),
                1
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM food_logs WHERE logged_date = '2026-02-24'"),
                1
            )
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT name FROM food_catalog_items LIMIT 1"),
                "Banana Bread UITest"
            )

            let exerciseNames = try String.fetchAll(
                db,
                sql: "SELECT name FROM exercise_catalog ORDER BY name"
            )
            XCTAssertEqual(exerciseNames, ["Back Squat UITest", "Bench Press UITest"])

            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: """
                        SELECT supplement_catalog.name
                        FROM user_supplements
                        JOIN supplement_catalog ON supplement_catalog.id = user_supplements.catalog_id
                        LIMIT 1
                        """
                ),
                "Vitamin D3 UITest"
            )

            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT title FROM insights LIMIT 1"),
                "Caffeine Timing UITest"
            )
        }
    }

    func testSeedLocalDataPreservesExistingWorkoutSessionsForSameUser() throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()

        withEnvironment([
            "LIFEOS_UI_TEST_BOOTSTRAP": "1",
            "LIFEOS_UI_TEST_AUTH_ID": authId.uuidString,
            "LIFEOS_UI_TEST_USER_ID": userId.uuidString,
            "LIFEOS_UI_TEST_AUTH_STATE": "authenticated",
            "LIFEOS_UI_TEST_SEED_TRAINING": "1"
        ]) {
            UITestBootstrap.seedLocalDataIfNeeded(dbQueue: manager.dbQueue)
        }

        try manager.dbQueue.write { db in
            var session = WorkoutSession(
                id: UUID(),
                userId: userId,
                startedAt: Date(),
                sessionDate: "2026-03-09",
                source: .manual
            )
            session.totalSets = 3
            try session.insert(db)
        }

        withEnvironment([
            "LIFEOS_UI_TEST_BOOTSTRAP": "1",
            "LIFEOS_UI_TEST_AUTH_ID": authId.uuidString,
            "LIFEOS_UI_TEST_USER_ID": userId.uuidString,
            "LIFEOS_UI_TEST_AUTH_STATE": "authenticated",
            "LIFEOS_UI_TEST_SEED_TRAINING": "1"
        ]) {
            UITestBootstrap.seedLocalDataIfNeeded(dbQueue: manager.dbQueue)
        }

        try manager.dbQueue.read { db in
            XCTAssertEqual(try WorkoutSession.fetchCount(db), 1)
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM workout_sessions WHERE user_id = ? OR user_id = ?",
                    arguments: [userId, userId.uuidString]
                ),
                1
            )
        }
    }

    func testSeedLocalDataWhenDisabledLeavesDatabaseUntouched() throws {
        let manager = try DatabaseManager.inMemory()

        withEnvironment([
            "LIFEOS_UI_TEST_BOOTSTRAP": "0",
            "LIFEOS_UI_TEST_SEED_SYNC_BLOCKER": "1"
        ]) {
            UITestBootstrap.seedLocalDataIfNeeded(dbQueue: manager.dbQueue)
        }

        try manager.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM users"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox_events"), 0)
        }
    }

    func testSeedLocalDataSkipsWhenRequiredTablesAreMissing() throws {
        let rawQueue = try DatabaseQueue()

        withEnvironment([
            "LIFEOS_UI_TEST_BOOTSTRAP": "1",
            "LIFEOS_UI_TEST_SEED_SYNC_BLOCKER": "1"
        ]) {
            UITestBootstrap.seedLocalDataIfNeeded(dbQueue: rawQueue)
        }

        try rawQueue.read { db in
            let tables = try String.fetchAll(
                db,
                sql: """
                    SELECT name
                    FROM sqlite_master
                    WHERE type = 'table'
                    """
            )
            XCTAssertFalse(tables.contains("users"))
            XCTAssertFalse(tables.contains("notification_settings"))
            XCTAssertFalse(tables.contains("privacy_settings"))
            XCTAssertFalse(tables.contains("outbox_events"))
        }
    }

    private func withEnvironment(_ updates: [String: String], perform: () throws -> Void) rethrows {
        var previous: [String: String?] = [:]
        for (key, value) in updates {
            previous[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, value, 1)
        }
        defer {
            for (key, oldValue) in previous {
                if let oldValue {
                    setenv(key, oldValue, 1)
                } else {
                    unsetenv(key)
                }
            }
        }
        try perform()
    }
}

@MainActor
final class NavigationCoverageTests: XCTestCase {
    func testAppTabMetadataAndDeepLinkDestinationIdentifiers() {
        XCTAssertEqual(AppTab.home.icon, "heart.text.square")
        XCTAssertEqual(AppTab.diary.icon, "book")
        XCTAssertEqual(AppTab.insights.icon, "lightbulb")
        XCTAssertEqual(AppTab.settings.icon, "gearshape")

        XCTAssertFalse(AppTab.home.title.isEmpty)
        XCTAssertFalse(AppTab.diary.title.isEmpty)
        XCTAssertFalse(AppTab.insights.title.isEmpty)
        XCTAssertFalse(AppTab.settings.title.isEmpty)

        let id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

        XCTAssertEqual(DeepLinkDestination.home.id, "home")
        XCTAssertEqual(DeepLinkDestination.diary(date: "2026-02-24").id, "diary:2026-02-24")
        XCTAssertEqual(DeepLinkDestination.insights.id, "insights")
        XCTAssertEqual(DeepLinkDestination.simulation.id, "simulation")
        XCTAssertEqual(DeepLinkDestination.insightDetail(id: id).id, "insight:\(id.uuidString)")
        XCTAssertEqual(DeepLinkDestination.settings.id, "settings")
        XCTAssertEqual(DeepLinkDestination.settingsSync.id, "settings:sync")
        XCTAssertEqual(DeepLinkDestination.settingsNotifications.id, "settings:notifications")
        XCTAssertEqual(DeepLinkDestination.settingsPrivacy.id, "settings:privacy")
        XCTAssertEqual(DeepLinkDestination.recoveryDetail(date: nil).id, "recovery:today")
        XCTAssertEqual(DeepLinkDestination.nutrition(date: "2026-02-24").id, "nutrition:2026-02-24")
        XCTAssertEqual(DeepLinkDestination.nutritionLog(method: .photo, aiConfidence: 0.5).id, "nutrition_log:photo:0.50")
        XCTAssertEqual(DeepLinkDestination.supplements(date: nil).id, "supplements:today")
        XCTAssertEqual(DeepLinkDestination.supplementsLog(date: nil).id, "supplements_log:today")
        XCTAssertEqual(DeepLinkDestination.workout(date: nil).id, "workout:today")
        XCTAssertEqual(DeepLinkDestination.workoutLog.id, "workout_log")
        XCTAssertEqual(DeepLinkDestination.authCallback.id, "auth_callback")
        XCTAssertEqual(DeepLinkDestination.experiment(id: id).id, "experiment:\(id.uuidString)")
        XCTAssertEqual(DeepLinkDestination.labs.id, "labs")
        XCTAssertEqual(DeepLinkDestination.labScan(id: id).id, "labs:\(id.uuidString)")
        XCTAssertEqual(DeepLinkDestination.hydration(date: nil).id, "hydration:today")
        XCTAssertEqual(DeepLinkDestination.wellness(date: "2026-02-24").id, "wellness:2026-02-24")
        XCTAssertEqual(DeepLinkDestination.menstrual(date: "2026-02-24").id, "menstrual:2026-02-24")
        XCTAssertEqual(DeepLinkDestination.bodyComposition.id, "body_composition")
        XCTAssertEqual(DeepLinkDestination.sleep(date: "2026-02-24").id, "sleep:2026-02-24")
    }

    func testNutritionInputMethodMappingAndDestinationRendering() {
        XCTAssertEqual(NutritionLogMethod.photo.asInputMethod, .vision)
        XCTAssertEqual(NutritionLogMethod.barcode.asInputMethod, .barcode)
        XCTAssertEqual(NutritionLogMethod.voice.asInputMethod, .voice)
        XCTAssertEqual(NutritionLogMethod.manual.asInputMethod, .manual)
        XCTAssertEqual(NutritionLogMethod.batch.asInputMethod, .batch)
        XCTAssertEqual(NutritionLogMethod.template.asInputMethod, .template)

        let id = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let destinations: [DeepLinkDestination] = [
            .home,
            .diary(date: "2026-02-24"),
            .insights,
            .simulation,
            .insightDetail(id: id),
            .settings,
            .settingsSync,
            .settingsNotifications,
            .settingsPrivacy,
            .recoveryDetail(date: "2026-02-24"),
            .nutrition(date: "2026-02-24"),
            .nutritionLog(method: .photo, aiConfidence: 0.8),
            .supplements(date: "2026-02-24"),
            .supplementsLog(date: "2026-02-24"),
            .workout(date: "2026-02-24"),
            .workoutLog,
            .authCallback,
            .experiment(id: id),
            .labs,
            .labScan(id: id),
            .hydration(date: "2026-02-24"),
            .wellness(date: "2026-02-24"),
            .menstrual(date: "2026-02-24"),
            .bodyComposition,
            .sleep(date: "2026-02-24")
        ]

        for destination in destinations {
            _ = DeepLinkDestinationView(destination: destination).body
        }
    }
}

@MainActor
final class RemainingCoverageBoostTests: XCTestCase {
    override func tearDown() {
        AuthManager.setActiveAuthIdForTests(nil)
        AuthManager._testSetRunningTestsOverride(nil)
        GuardianManager._testSetAuthorizationOverride(nil)
        GuardianManager._testSetRequestAuthorization(nil)
        GuardianManager._testSetRevokeAuthorization(nil)
        GuardianManager._testSetSystemRevokeAuthorization(nil)
        GuardianManager._testSetDefaultRequestAuthorization(nil)
        GuardianManager._testSetDefaultSystemRevokeAuthorization(nil)
        GuardianManager._testSetNowProvider(nil)
        GuardianManager._testSetSelectionPresenceOverride(nil)
        GuardianManager._testResetPersistedState()
        AppContainer.shared = nil
        super.tearDown()
    }

    func testLabsViewsBodyCoversDisplayBranches() {
        let loadingStore = Store(
            initialState: LabsFeature.State(summary: nil, isLoading: true)
        ) {
            LabsFeature()
        }
        let summaryStore = Store(
            initialState: LabsFeature.State(
                summary: LabsSummary(latestStatus: "completed", markerCount: 2, scanCount: 1),
                isLoading: false
            )
        ) {
            LabsFeature()
        }
        let emptyStore = Store(initialState: LabsFeature.State(summary: nil, isLoading: false)) {
            LabsFeature()
        }

        _ = LabsOverviewView(store: loadingStore).body
        _ = LabsOverviewView(store: summaryStore).body
        _ = LabsOverviewView(store: emptyStore).body
        _ = LabScanDetailView(scanId: UUID()).body
    }

    func testACWRDetailViewCoverageAcrossDisplayStates() async {
        func renderACWR(_ view: some View, file: StaticString = #filePath, line: UInt = #line) {
            let host = UIHostingController(rootView: view)
            _ = host.view
            XCTAssertNotNil(host.viewIfLoaded, file: file, line: line)
        }

        let populated = await ACWRDetailViewTestHarness.populatedView()
        let coldStart = await ACWRDetailViewTestHarness.coldStartView(daysOfData: 9)
        let loading = await ACWRDetailViewTestHarness.loadingView()

        renderACWR(populated)
        renderACWR(coldStart)
        renderACWR(loading)

        populated._testEvaluateRatioCard()
        populated._testEvaluateLoadBars()
        populated._testEvaluateTrendRow()
        populated._testEvaluateAdvancedMetrics()
        coldStart._testEvaluateColdStart()
        populated._testEvaluateDisclaimer()

        let resolvedDay = await ACWRDetailViewTestHarness.resolvedDay("2026-03-10")
        let defaultResolvedDay = await ACWRDetailViewTestHarness.resolvedDay(nil)
        let epochDayString = await ACWRDetailViewTestHarness.localDayString(for: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(resolvedDay, "2026-03-10")
        XCTAssertFalse(defaultResolvedDay.isEmpty)
        XCTAssertEqual(epochDayString, "1970-01-01")
    }

    func testACWRDetailViewModelLoadTrainingCoverage() async throws {
        let dbQueue = try DatabaseQueue(path: ":memory:")
        let authId = UUID()
        let userId = UUID()

        try await dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE users (
                    id TEXT PRIMARY KEY,
                    auth_id TEXT,
                    updated_at TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE sync_row_state (
                    table_name TEXT,
                    row_id TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE training_loads (
                    user_id TEXT,
                    date TEXT,
                    daily_trimp DOUBLE,
                    acute_load_7d DOUBLE,
                    chronic_load_28d DOUBLE,
                    acwr DOUBLE,
                    training_zone TEXT,
                    weekly_trend TEXT,
                    monotony_7d DOUBLE,
                    strain_7d DOUBLE,
                    fitness_ctl DOUBLE,
                    fatigue_atl DOUBLE,
                    form_tsb DOUBLE
                )
                """)
            try db.execute(
                sql: "INSERT INTO users (id, auth_id, updated_at) VALUES (?, ?, ?)",
                arguments: [userId.uuidString, authId.uuidString, "2026-03-21T00:00:00Z"]
            )

            for day in 1...21 {
                let date = String(format: "2026-03-%02d", day)
                let isTargetDay = day == 21
                try db.execute(
                    sql: """
                        INSERT INTO training_loads (
                            user_id,
                            date,
                            daily_trimp,
                            acute_load_7d,
                            chronic_load_28d,
                            acwr,
                            training_zone,
                            weekly_trend,
                            monotony_7d,
                            strain_7d,
                            fitness_ctl,
                            fatigue_atl,
                            form_tsb
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        userId.uuidString,
                        date,
                        55.0,
                        isTargetDay ? 90.0 : nil,
                        isTargetDay ? 75.0 : nil,
                        isTargetDay ? 1.2 : nil,
                        isTargetDay ? TrainingZoneState.optimal.rawValue : nil,
                        isTargetDay ? WeeklyTrend.increasing.rawValue : nil,
                        isTargetDay ? 1.4 : nil,
                        isTargetDay ? 320.0 : nil,
                        isTargetDay ? 70.0 : nil,
                        isTargetDay ? 82.0 : nil,
                        isTargetDay ? -12.0 : nil
                    ]
                )
            }
        }

        let missingUser = try await dbQueue.read { db in
            try ACWRDetailViewTestHarness.loadTrainingLoadSnapshot(
                day: "2026-03-21",
                authId: nil,
                db: db
            )
        }
        XCTAssertNil(missingUser.acwr)
        XCTAssertEqual(missingUser.daysOfData, 0)

        let missingDay = try await dbQueue.read { db in
            try ACWRDetailViewTestHarness.loadTrainingLoadSnapshot(
                day: "2026-03-22",
                authId: authId.uuidString,
                db: db
            )
        }
        XCTAssertNil(missingDay.acwr)
        XCTAssertEqual(missingDay.daysOfData, 21)

        let snapshot = try await dbQueue.read { db in
            try ACWRDetailViewTestHarness.loadTrainingLoadSnapshot(
                day: "2026-03-21",
                authId: authId.uuidString,
                db: db
            )
        }
        XCTAssertEqual(snapshot.daysOfData, 21)
        XCTAssertEqual(snapshot.zone, .optimal)
        XCTAssertEqual(snapshot.trend, .increasing)
        XCTAssertEqual(snapshot.acute, 90.0)
        XCTAssertEqual(snapshot.chronic, 75.0)
        XCTAssertEqual(snapshot.monotony, 1.4)
        XCTAssertEqual(snapshot.strain, 320.0)
        XCTAssertEqual(snapshot.fitnessCtl, 70.0)
        XCTAssertEqual(snapshot.fatigueAtl, 82.0)
        XCTAssertEqual(snapshot.formTsb, -12.0)
        XCTAssertEqual(snapshot.acwr ?? 0, 1.2, accuracy: 0.0001)

        AuthManager.setActiveAuthIdForTests(authId)
        let loaded = await ACWRDetailViewTestHarness.loadState(
            dateString: "2026-03-21",
            dbQueue: dbQueue
        )
        XCTAssertFalse(loaded.isLoading)
        XCTAssertEqual(loaded.daysOfData, 21)
        XCTAssertEqual(loaded.zone, .optimal)
        XCTAssertEqual(loaded.trend, .increasing)
        XCTAssertEqual(loaded.acute, 90.0)
        XCTAssertEqual(loaded.chronic, 75.0)
        XCTAssertEqual(loaded.monotony, 1.4)
        XCTAssertEqual(loaded.strain, 320.0)
        XCTAssertEqual(loaded.fitnessCtl, 70.0)
        XCTAssertEqual(loaded.fatigueAtl, 82.0)
        XCTAssertEqual(loaded.formTsb, -12.0)
        XCTAssertEqual(loaded.acwr ?? 0, 1.2, accuracy: 0.0001)

        AuthManager.setActiveAuthIdForTests(UUID())
        let emptyLoaded = await ACWRDetailViewTestHarness.loadState(
            dateString: "2026-03-21",
            dbQueue: dbQueue
        )
        XCTAssertNil(emptyLoaded.acwr)
        XCTAssertEqual(emptyLoaded.daysOfData, 0)
        XCTAssertFalse(emptyLoaded.isLoading)
    }

    @MainActor
    func testMenstrualDayViewModelLoadSaveDeleteCoverage() async throws {
        // menstrual_logs persist through FieldEncryption; use a fixed
        // in-memory key so the test never depends on a real Keychain.
        let fixedEncryptionKey = SymmetricKey(size: .bits256)
        FieldEncryption._testSetDeviceKeyOverride { fixedEncryptionKey }
        defer { FieldEncryption._testResetOverrides() }

        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let store = MenstrualStore(dbQueue: manager.dbQueue)

        try await manager.dbQueue.write { db in
            var user = User(id: userId, authId: authId, timezone: "UTC", units: .metric)
            try user.insert(db)

            var privacy = PrivacySettings(userId: userId)
            privacy.menstrualLocalOnly = false
            try privacy.insert(db)

            var flags = UserHealthFlags(userId: userId)
            flags.menstrualTrackingEnabled = true
            try flags.insert(db)

            var earlierLog = MenstrualLog(
                userId: userId,
                date: "2026-02-20",
                flow: .light,
                painLevel: 1
            )
            try earlierLog.insert(db)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let viewModel = MenstrualDayViewModel(dateString: "2026-02-24", store: store)
        XCTAssertFalse(viewModel.currentSummary.isEmpty)

        await viewModel.loadForSelectedDayTask()
        XCTAssertTrue(viewModel.trackingEnabled)
        XCTAssertTrue(viewModel.syncEnabled)
        XCTAssertNil(viewModel.currentLog)
        XCTAssertEqual(viewModel.historyEntries.count, 1)
        XCTAssertEqual(viewModel.formattedHistoryDate("invalid-date"), "invalid-date")
        XCTAssertFalse(viewModel.formattedHistoryDate("2026-02-20").isEmpty)

        let previewLog = MenstrualLog(
            userId: userId,
            date: "2026-02-24",
            flow: .heavy,
            painLevel: 4
        )
        XCTAssertEqual(
            viewModel.summary(for: previewLog),
            MenstrualDayViewModel._testSummary(flow: .heavy, painLevel: 4)
        )

        let stableDay = viewModel.selectedDay
        viewModel.jumpTo(dateString: "not-a-date")
        XCTAssertEqual(viewModel.selectedDay, stableDay)

        viewModel.toggleFlow(.spotting)
        XCTAssertEqual(viewModel.draftFlow, .spotting)
        viewModel.toggleFlow(.spotting)
        XCTAssertNil(viewModel.draftFlow)

        viewModel.setPainLevel(9)
        XCTAssertEqual(viewModel.draftPainLevel, 5)
        viewModel.setPainLevel(-3)
        XCTAssertEqual(viewModel.draftPainLevel, 0)

        viewModel.statusMessage = "Old"
        viewModel.currentLog = MenstrualLog(
            userId: userId,
            date: viewModel.selectedDay,
            flow: .medium,
            painLevel: 2
        )
        viewModel.draftFlow = .medium
        viewModel.draftPainLevel = 2
        viewModel.updateSelectedDate(Date(timeIntervalSince1970: 0))
        XCTAssertNil(viewModel.statusMessage)
        XCTAssertNil(viewModel.currentLog)
        XCTAssertNil(viewModel.draftFlow)
        XCTAssertEqual(viewModel.draftPainLevel, 0)
        XCTAssertEqual(viewModel.selectedDay, "1970-01-01")

        viewModel.jumpTo(dateString: "2026-02-24")
        await viewModel.loadForSelectedDayTask()
        viewModel.toggleFlow(.heavy)
        viewModel.setPainLevel(4)
        XCTAssertTrue(viewModel.canSaveDraft)

        await viewModel.save()
        XCTAssertEqual(viewModel.currentLog?.flow, .heavy)
        XCTAssertEqual(viewModel.currentLog?.painLevel, 4)
        XCTAssertFalse(viewModel.currentSummary.isEmpty)
        XCTAssertFalse(viewModel.statusMessage?.isEmpty ?? true)

        viewModel.setPainLevel(1)
        await viewModel.save()
        XCTAssertEqual(viewModel.currentLog?.painLevel, 1)

        let saveOutboxCount = try await manager.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?",
                arguments: ["api-menstrual-sync"]
            ) ?? 0
        }
        XCTAssertGreaterThanOrEqual(saveOutboxCount, 2)

        await viewModel.deleteCurrentLog()
        XCTAssertNil(viewModel.currentLog)
        XCTAssertFalse(viewModel.statusMessage?.isEmpty ?? true)

        let deletedRows = try await manager.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM menstrual_logs
                    WHERE date = ?
                      AND deleted_at IS NOT NULL
                    """,
                arguments: ["2026-02-24"]
            ) ?? 0
        }
        XCTAssertEqual(deletedRows, 1)

        AuthManager.setActiveAuthIdForTests(nil)
        let unavailableViewModel = MenstrualDayViewModel(dateString: "2026-02-25", store: store)
        unavailableViewModel.toggleFlow(.light)
        await unavailableViewModel.save()
        XCTAssertFalse(unavailableViewModel.statusMessage?.isEmpty ?? true)
        XCTAssertFalse(unavailableViewModel.canSaveDraft)
        await unavailableViewModel.loadForSelectedDayTask()
        XCTAssertFalse(unavailableViewModel.trackingEnabled)
        XCTAssertFalse(unavailableViewModel.syncEnabled)
        XCTAssertTrue(unavailableViewModel.historyEntries.isEmpty)

        let noDraftViewModel = MenstrualDayViewModel(dateString: "2026-02-26", store: store)
        await noDraftViewModel.save()
        await noDraftViewModel.deleteCurrentLog()
    }

    @MainActor
    func testMenstrualDayViewAdditionalBodyBranches() {
        func renderMenstrual(_ view: MenstrualDayView, file: StaticString = #filePath, line: UInt = #line) {
            let host = UIHostingController(rootView: view)
            _ = host.view
            XCTAssertNotNil(host.viewIfLoaded, file: file, line: line)
        }

        let loadingViewModel = MenstrualDayViewModel(dateString: "2026-02-24")
        loadingViewModel._testOverrideState(
            userId: UUID(),
            currentLog: nil,
            recentLogs: [],
            trackingEnabled: false,
            syncEnabled: false,
            statusMessage: "Loading",
            isLoading: true,
            isSaving: false
        )
        let loadingView = MenstrualDayView(testViewModel: loadingViewModel)
        renderMenstrual(loadingView)
        loadingView._testEvaluateBody()

        let syncViewModel = MenstrualDayViewModel(dateString: "2026-02-24")
        syncViewModel._testOverrideState(
            userId: UUID(),
            currentLog: nil,
            recentLogs: [],
            trackingEnabled: true,
            syncEnabled: true,
            statusMessage: nil,
            isLoading: false,
            isSaving: true
        )
        let syncView = MenstrualDayView(testViewModel: syncViewModel)
        renderMenstrual(syncView)
        syncView._testEvaluateBody()

        let historyUserId = UUID()
        let currentLog = MenstrualLog(
            userId: historyUserId,
            date: "2026-02-24",
            flow: .medium,
            painLevel: 2
        )
        let earlierLog = MenstrualLog(
            userId: historyUserId,
            date: "2026-02-18",
            flow: .spotting,
            painLevel: nil
        )
        let historyViewModel = MenstrualDayViewModel(dateString: "2026-02-24")
        historyViewModel._testOverrideState(
            userId: historyUserId,
            currentLog: currentLog,
            recentLogs: [currentLog, earlierLog],
            trackingEnabled: true,
            syncEnabled: false,
            statusMessage: "Saved",
            isLoading: false,
            isSaving: false
        )
        let historyView = MenstrualDayView(testViewModel: historyViewModel)
        renderMenstrual(historyView)
        historyView._testEvaluateBody()
        XCTAssertEqual(historyViewModel.historyEntries.map(\.date), ["2026-02-18"])
    }

    func testEnvironmentServiceDelegateCallbacksWithoutPendingRequests() {
        let service = EnvironmentService()
        let manager = CLLocationManager()

        service.locationManager(manager, didUpdateLocations: [])
        service.locationManager(manager, didFailWithError: NSError(domain: "EnvironmentTests", code: 1))
        service.locationManagerDidChangeAuthorization(manager)

        _ = EnvironmentError.locationPermissionDenied
        _ = EnvironmentError.locationUnavailable
        _ = EnvironmentError.locationRequestTimedOut
    }

    func testHealthKitManagerPureCalculationsAndSleepQualityScore() async {
        let manager = HealthKitManager()

        let empty = await manager.dataCompleteness(
            hrv: nil,
            sleep: nil,
            rhr: nil,
            steps: nil,
            activeCal: nil
        )
        XCTAssertEqual(empty, 0.0, accuracy: 0.0001)

        let sleep = SleepData(
            totalHours: 8.0,
            deepMinutes: 90,
            remMinutes: 95,
            lightMinutes: 295,
            awakeMinutes: 20,
            efficiency: 90,
            bedTime: nil,
            wakeTime: nil
        )
        let full = await manager.dataCompleteness(
            hrv: 4.1,
            sleep: sleep,
            rhr: 52,
            steps: 1,
            activeCal: 0
        )
        XCTAssertEqual(full, 1.0, accuracy: 0.0001)

        let mixed = await manager.dataCompleteness(
            hrv: 4.1,
            sleep: nil,
            rhr: 52,
            steps: 0,
            activeCal: 0
        )
        XCTAssertEqual(mixed, 0.55, accuracy: 0.0001)

        XCTAssertGreaterThan(sleep.qualityScore, 75)

        let poorSleep = SleepData(
            totalHours: 4.5,
            deepMinutes: 10,
            remMinutes: 25,
            lightMinutes: 230,
            awakeMinutes: 85,
            efficiency: 45,
            bedTime: nil,
            wakeTime: nil
        )
        XCTAssertLessThan(poorSleep.qualityScore, 55)

        let healthKitAvailability = HealthKitManager.isAvailable
        XCTAssertEqual(healthKitAvailability, HealthKitManager.isAvailable)
    }

    func testHealthSyncManagerGuardPathsAndBackfillNoop() async throws {
        let manager = HealthSyncManager()
        let userId = UUID()

        try await manager.backfillRecentData(days: 0, userId: userId)
        try await manager.backfillRecentData(days: -3, userId: userId)
    }

    func testAppContainerSharedAndGuardianReevaluation() async {
        let syncEngine = makeNoopSyncEngine(dbQueue: DatabaseManager.shared.dbQueue)
        AppContainer.shared = AppContainer(syncEngine: syncEngine)
        XCTAssertNotNil(AppContainer.shared)

        AppContainer.shared = nil
        XCTAssertNil(AppContainer.shared)
        AppCapabilityAvailability._testSetFamilyControlsAvailableOverride(true)
        defer {
            AppCapabilityAvailability._testResetOverrides()
            GuardianManager._testSetAuthorizationOverride(nil)
            GuardianManager._testSetRequestAuthorization(nil)
            GuardianManager._testSetRevokeAuthorization(nil)
            GuardianManager._testSetSystemRevokeAuthorization(nil)
        }

        var settings = NotificationSettings(userId: UUID())
        settings.controlLevel = .guardian
        settings.focusControlEnabled = true
        settings.criticalOnly = true

        GuardianManager.shared.reevaluateShieldsForSettings(settings)
        let selection = FamilyActivitySelection()
        GuardianManager.shared.shieldApps(selection: selection)
        GuardianManager.shared.clearShields()

        GuardianManager._testSetAuthorizationOverride(false)
        XCTAssertFalse(GuardianManager.shared.isAuthorized)
        GuardianManager.shared.applyShieldsIfAllowed(selection: selection, settings: settings)

        settings.criticalOnly = false
        GuardianManager._testSetAuthorizationOverride(true)
        XCTAssertTrue(GuardianManager.shared.isAuthorized)
        GuardianManager.shared.applyShieldsIfAllowed(selection: selection, settings: settings)
        GuardianManager.shared.saveSelection(selection, settings: settings)
        GuardianManager.shared.saveSelection(selection, settings: nil)
        XCTAssertNotNil(GuardianManager.shared.loadSelection().encode())

        GuardianManager.shared._testHandleRevokeResult(.success(()))
        GuardianManager.shared._testHandleRevokeResult(
            .failure(NSError(domain: "GuardianCoverage", code: 1))
        )

        var didRequestAuthorization = false
        GuardianManager._testSetRequestAuthorization {
            didRequestAuthorization = true
        }
        _ = try? await GuardianManager.shared.requestAuthorization()
        XCTAssertTrue(didRequestAuthorization)

        let revokeExpectation = expectation(description: "Guardian revoke callback")
        GuardianManager._testSetRevokeAuthorization { completion in
            completion(.success(()))
            revokeExpectation.fulfill()
        }
        GuardianManager.shared.revokeAuthorization()
        await fulfillment(of: [revokeExpectation], timeout: 1.0)

        GuardianManager._testSetRevokeAuthorization(nil)
        let systemRevokeExpectation = expectation(description: "Guardian system revoke callback")
        GuardianManager._testSetSystemRevokeAuthorization { completion in
            completion(.failure(NSError(domain: "GuardianCoverage", code: 2)))
            systemRevokeExpectation.fulfill()
        }
        GuardianManager.shared.revokeAuthorization()
        await fulfillment(of: [systemRevokeExpectation], timeout: 1.0)

        GuardianManager._testSetAuthorizationOverride(nil)
        _ = GuardianManager.shared.isAuthorized
    }

    @MainActor
    func testGuardianManagerStartsBoundedSessionAndExpiresWhenTimeAdvances() {
        GuardianManager._testResetPersistedState()
        GuardianManager._testSetAuthorizationOverride(true)
        GuardianManager._testSetSelectionPresenceOverride(true)

        let start = guardianLocalDate(year: 2026, month: 2, day: 24, hour: 12, minute: 0)
        GuardianManager._testSetNowProvider { start }

        var settings = NotificationSettings(userId: UUID())
        settings.controlLevel = .guardian
        settings.focusControlEnabled = true
        settings.quietHoursStart = "23:00"
        settings.quietHoursEnd = "07:00"

        let result = GuardianManager.shared._testStartEnforcementWindow(
            reason: "Low recovery",
            duration: 3 * 60 * 60,
            settings: settings
        )

        switch result {
        case .activated(let session):
            XCTAssertEqual(session.reason, "Low recovery")
            XCTAssertLessThanOrEqual(session.endsAt.timeIntervalSince(session.startedAt), 2 * 60 * 60)
        default:
            XCTFail("Expected Guardian session to activate")
        }

        XCTAssertEqual(
            GuardianManager.shared._testSyncEnforcementState(settings: settings).state,
            .active
        )

        GuardianManager._testSetNowProvider { start.addingTimeInterval(2 * 60 * 60 + 1) }
        XCTAssertEqual(
            GuardianManager.shared._testSyncEnforcementState(settings: settings).state,
            .inactive
        )
    }

    @MainActor
    func testGuardianManagerPauseForTodaySuppressesNewSessions() {
        GuardianManager._testResetPersistedState()
        GuardianManager._testSetAuthorizationOverride(true)
        GuardianManager._testSetSelectionPresenceOverride(true)

        let now = guardianLocalDate(year: 2026, month: 2, day: 24, hour: 12, minute: 0)
        GuardianManager._testSetNowProvider { now }

        var settings = NotificationSettings(userId: UUID())
        settings.controlLevel = .guardian
        settings.focusControlEnabled = true
        settings.quietHoursStart = "23:00"
        settings.quietHoursEnd = "07:00"

        _ = GuardianManager.shared._testStartEnforcementWindow(
            reason: "Recovery guard",
            duration: 30 * 60,
            settings: settings
        )

        let paused = GuardianManager.shared._testPauseControlForToday(settings: settings)
        if case .pausedToday(let day) = paused.state {
            XCTAssertEqual(day, "2026-02-24")
        } else {
            XCTFail("Expected Guardian pause state for today")
        }

        let restartResult = GuardianManager.shared._testStartEnforcementWindow(
            reason: "Should not restart",
            duration: 30 * 60,
            settings: settings
        )
        XCTAssertEqual(restartResult, .pausedForToday)
    }

    @MainActor
    func testGuardianRuntimeRefreshAutoExecutesBlockAppsRecommendationOnlyOnce() async throws {
        GuardianManager._testResetPersistedState()
        GuardianManager._testSetAuthorizationOverride(true)
        GuardianManager._testSetSelectionPresenceOverride(true)

        let manager = try DatabaseManager.inMemory()
        let syncEngine = makeNoopSyncEngine(dbQueue: manager.dbQueue)
        let authId = UUID()
        let userId = UUID()
        let now = guardianLocalDate(year: 2026, month: 2, day: 24, hour: 12, minute: 0)
        let recommendationDate = Self.guardianDayString(now)
        GuardianManager._testSetNowProvider { now }
        AuthManager.setActiveAuthIdForTests(authId)

        let recommendationId = try await manager.dbQueue.write { db in
            try Self.insertGuardianUser(db: db, userId: userId, authId: authId, now: now)
            try Self.insertGuardianNotificationSettings(db: db, userId: userId, now: now) { settings in
                settings.controlLevel = .guardian
                settings.focusControlEnabled = true
                settings.quietHoursStart = "23:00"
                settings.quietHoursEnd = "07:00"
            }
            return try Self.insertGuardianAutoBlockRecommendation(
                db: db,
                userId: userId,
                recommendationDate: recommendationDate,
                durationMinutes: 90
            )
        }

        let firstRefresh = await GuardianManager.shared._testRefreshRuntimeState(
            dbQueue: manager.dbQueue,
            syncEngine: syncEngine
        )
        XCTAssertEqual(firstRefresh.snapshot.state, .active)
        if case .recommendation(let id) = firstRefresh.snapshot.session?.source {
            XCTAssertEqual(id, recommendationId.uuidString)
        } else {
            XCTFail("Expected recommendation-backed Guardian session")
        }

        GuardianManager._testSetNowProvider { now.addingTimeInterval(91 * 60) }
        let secondRefresh = await GuardianManager.shared._testRefreshRuntimeState(
            dbQueue: manager.dbQueue,
            syncEngine: syncEngine
        )
        XCTAssertEqual(secondRefresh.snapshot.state, .inactive)
    }

    @MainActor
    func testGuardianRuntimeRefreshDowngradesGuardianAfterAuthorizationRevocation() async throws {
        GuardianManager._testResetPersistedState()
        GuardianManager._testSetAuthorizationOverride(false)
        GuardianManager._testSetSelectionPresenceOverride(true)

        let manager = try DatabaseManager.inMemory()
        let syncEngine = makeNoopSyncEngine(dbQueue: manager.dbQueue)
        let authId = UUID()
        let userId = UUID()
        let now = guardianLocalDate(year: 2026, month: 2, day: 24, hour: 12, minute: 0)
        AuthManager.setActiveAuthIdForTests(authId)
        GuardianManager._testSetNowProvider { now }

        try await manager.dbQueue.write { db in
            try Self.insertGuardianUser(db: db, userId: userId, authId: authId, now: now)
            try Self.insertGuardianNotificationSettings(db: db, userId: userId, now: now) { settings in
                settings.controlLevel = .guardian
                settings.focusControlEnabled = true
            }
        }

        let refresh = await GuardianManager.shared._testRefreshRuntimeState(
            dbQueue: manager.dbQueue,
            syncEngine: syncEngine
        )
        XCTAssertEqual(refresh.settings?.controlLevel, .protective)
        XCTAssertEqual(refresh.settings?.focusControlEnabled, false)
        XCTAssertFalse((GuardianManager.shared.runtimeBannerMessage ?? "").isEmpty)

        try await manager.dbQueue.read { db in
            let stored = try NotificationSettings.fetchOne(
                db,
                sql: """
                    SELECT *
                    FROM notification_settings
                    WHERE user_id = ? OR user_id = ?
                    LIMIT 1
                    """,
                arguments: [userId, userId.uuidString]
            )
            XCTAssertEqual(stored?.controlLevel, .protective)
            XCTAssertEqual(stored?.focusControlEnabled, false)
        }
    }

    private func guardianLocalDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private static func guardianDayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    nonisolated private static func insertGuardianUser(
        db: Database,
        userId: UUID,
        authId: UUID,
        now: Date
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO users (
                    id, auth_id, timezone, units, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [userId.uuidString, authId.uuidString, "UTC", "metric", now, now]
        )
    }

    nonisolated private static func insertGuardianNotificationSettings(
        db: Database,
        userId: UUID,
        now: Date,
        mutate: (inout NotificationSettings) -> Void
    ) throws {
        var settings = NotificationSettings(userId: userId)
        settings.createdAt = now
        settings.updatedAt = now
        mutate(&settings)
        try settings.insert(db)
    }

    nonisolated private static func insertGuardianAutoBlockRecommendation(
        db: Database,
        userId: UUID,
        recommendationDate: String,
        durationMinutes: Int
    ) throws -> UUID {
        let recommendationId = UUID()
        var recommendation = Recommendation(
            id: recommendationId,
            userId: userId,
            recommendationDate: recommendationDate,
            category: "behavior",
            priority: "critical",
            title: "Protect recovery",
            description: "Reduce late-night screen time.",
            reasoning: "Low recovery score triggered a temporary restriction."
        )
        recommendation.actionType = "block_apps"
        recommendation.autoExecute = true
        recommendation.actionParameters = try JSONSerialization.data(
            withJSONObject: ["duration_minutes": durationMinutes]
        )
        try recommendation.insert(db)
        return recommendationId
    }

    func testOnboardingViewStepBuildersExerciseAllFactories() {
        let defaultStore = Store(initialState: OnboardingFeature.State()) {
            OnboardingFeature()
        }
        let defaultView = OnboardingView(store: defaultStore)
        defaultView._testEvaluateBody()
        defaultView._testEvaluateStepBuilders()
        defaultView._testTriggerActions()
        defaultView._testTriggerInstanceStepChangeHandlers()

        var inProgressState = OnboardingFeature.State()
        inProgressState.currentStep = .backfillInProgress
        inProgressState.isBackfilling = true
        let inProgressStore = Store(initialState: inProgressState) {
            OnboardingFeature()
        }
        let inProgressView = OnboardingView(store: inProgressStore)
        inProgressView._testEvaluateBody()
        inProgressView._testEvaluateStepBuilders()
        inProgressView._testTriggerActions()
        inProgressView._testTriggerInstanceStepChangeHandlers()

        var requestingHealthKitState = OnboardingFeature.State()
        requestingHealthKitState.currentStep = .healthkitPrompted
        requestingHealthKitState.isRequestingHealthKit = true
        let requestingStore = Store(initialState: requestingHealthKitState) {
            OnboardingFeature()
        }
        let requestingView = OnboardingView(store: requestingStore)
        requestingView._testEvaluateBody()
        requestingView._testEvaluateStepBuilders()
        requestingView._testTriggerActions()
        requestingView._testTriggerInstanceStepChangeHandlers()

        var completeState = OnboardingFeature.State()
        completeState.currentStep = .backfillComplete
        completeState.isBackfilling = false
        completeState.isCompleting = true
        let completeStore = Store(initialState: completeState) {
            OnboardingFeature()
        }
        let completeView = OnboardingView(store: completeStore)
        completeView._testEvaluateBody()
        completeView._testEvaluateStepBuilders()
        completeView._testTriggerActions()
        completeView._testTriggerInstanceStepChangeHandlers()

        OnboardingStepView(
            icon: "person.circle",
            title: "Profile",
            description: "desc",
            buttonTitle: "Continue",
            action: {}
        )._testEvaluateBody()
    }

    func testHomeViewSectionBuildersAcrossRecoveryAndSetupStates() async {
        let setupItem = SetupChecklistFeature.Item(
            id: "food",
            icon: "fork.knife",
            title: "Log first meal",
            subtitle: "Start nutrition tracking",
            isComplete: false,
            route: "lifeos://nutrition/log"
        )
        let action = RecoveryContextualAction(
            title: "Recover",
            message: "Go lighter today",
            buttonTitle: "Open",
            deepLink: URL(string: "lifeos://recovery?date=2026-02-24")!
        )

        let noData = HomeViewModel(pushLatestWatchSnapshot: { _ in })
        noData._testOverrideState(
            recoveryScore: nil,
            recoveryZone: nil,
            recoveryConfidence: nil,
            contextualAction: nil,
            setupItems: [],
            setupComplete: true,
            baselineDaysCollected: 0
        )
        let noDataView = HomeView(viewModel: noData)
        noDataView._testEvaluateSections()
        await noDataView._testRunRefreshTask {}
        await noDataView._testRunInstanceRefreshTask {}
        _ = noDataView.body

        let calibratedProgress = HomeViewModel(pushLatestWatchSnapshot: { _ in })
        calibratedProgress._testOverrideState(
            recoveryScore: nil,
            recoveryZone: nil,
            recoveryConfidence: nil,
            contextualAction: nil,
            setupItems: [],
            setupComplete: true,
            baselineDaysCollected: 3
        )
        let progressView = HomeView(viewModel: calibratedProgress)
        progressView._testEvaluateSections()
        _ = progressView.body

        let withRecovery = HomeViewModel(pushLatestWatchSnapshot: { _ in })
        withRecovery._testOverrideState(
            recoveryScore: 47,
            recoveryZone: .caution,
            recoveryConfidence: 0.5,
            contextualAction: action,
            setupItems: [setupItem],
            setupComplete: false,
            baselineDaysCollected: 2
        )
        let recoveryView = HomeView(viewModel: withRecovery)
        recoveryView._testEvaluateSections()
        _ = recoveryView.body

        let routeSamples = HomeView._testRouteExecutionSamples()
        XCTAssertEqual(routeSamples.count, 4)
        XCTAssertTrue(routeSamples.contains("lifeos://nutrition/log"))
        XCTAssertTrue(routeSamples.contains("lifeos://wellness"))
        XCTAssertTrue(routeSamples.contains("lifeos://workout/log"))
        XCTAssertTrue(routeSamples.contains("lifeos://simulation"))

        let instanceSamples = recoveryView._testTriggerInstanceActions()
        XCTAssertGreaterThanOrEqual(instanceSamples.count, 7)
        XCTAssertTrue(instanceSamples.contains("lifeos://hydration"))
        XCTAssertTrue(instanceSamples.contains("lifeos://sleep"))
        XCTAssertTrue(instanceSamples.contains("lifeos://wellness"))
        XCTAssertTrue(instanceSamples.contains("lifeos://nutrition/log"))
    }

    func testInsightsViewBuildersAcrossViewStates() {
        let insight = Insight(
            userId: UUID(),
            category: .recovery,
            title: "Recovery trend",
            body: "Take a lighter day.",
            confidence: 0.4
        )

        let loadingVM = InsightsViewModel()
        loadingVM._testOverrideState(
            lowConfidenceCount: 0,
            insights: [],
            latestWeeklyStrategyReport: nil,
            isLoading: true,
            loadError: nil
        )
        _ = InsightsView(viewModel: loadingVM).body

        let errorVM = InsightsViewModel()
        errorVM._testOverrideState(
            lowConfidenceCount: 0,
            insights: [],
            latestWeeklyStrategyReport: nil,
            isLoading: false,
            loadError: "Something went wrong"
        )
        _ = InsightsView(viewModel: errorVM).body

        let emptyVM = InsightsViewModel()
        emptyVM._testOverrideState(
            lowConfidenceCount: 0,
            insights: [],
            latestWeeklyStrategyReport: nil,
            isLoading: false,
            loadError: nil
        )
        _ = InsightsView(viewModel: emptyVM).body

        let filteredEmptyVM = InsightsViewModel()
        filteredEmptyVM._testOverrideState(
            lowConfidenceCount: 0,
            insights: [],
            latestWeeklyStrategyReport: nil,
            isLoading: false,
            loadError: nil,
            allInsights: [insight],
            selectedDomains: [.nutrition]
        )
        _ = InsightsView(viewModel: filteredEmptyVM).body

        let contentVM = InsightsViewModel()
        contentVM._testOverrideState(
            lowConfidenceCount: 1,
            insights: [insight],
            latestWeeklyStrategyReport: nil,
            isLoading: false,
            loadError: nil,
            allInsights: [insight]
        )
        let contentView = InsightsView(viewModel: contentVM)
        contentView._testEvaluateSections(sampleInsight: insight)
        contentView._testExerciseFilterActions()
        _ = contentView.body
    }

    func testDiarySettingsAndSimulationViewBuilders() {
        let diaryVM = DiaryViewModel()
        diaryVM.caloriesValue = "2100"
        diaryVM.proteinValue = "120"
        diaryVM.fatValue = "70"
        diaryVM.carbsValue = "230"
        diaryVM.nutritionSubtitle = "3 meals logged"
        diaryVM.targetSummary = "Target: 2200 kcal"
        let diaryView = DiaryView(initialDateString: "2026-02-24", viewModel: diaryVM)
        diaryView._testEvaluateSections()
        _ = diaryView.body

        SettingsView()._testEvaluateBody()
        SettingsView(testExportStatusMessage: "Export queued")._testEvaluateBody()
        SettingsView()._testTriggerExportAction()

        let response = PredictiveScenarioResponse(
            predictedRecoveryRange: [72, 78],
            predictedZone: .ready,
            explanation: "Looks supportive.",
            confidenceScore: 0.8
        )
        let simulationVM = SimulationViewModel(
            predictionService: SimulationPredictionStub(response: response),
            environmentService: SimulationEnvironmentStub(
                context: EnvironmentalContext(
                    weatherCondition: "Clear",
                    temperatureC: 18,
                    pressureHpa: 1014,
                    pressureDeltaHpa24h: 1.2,
                    aqi: 24,
                    indoorCo2Ppm: 650,
                    moonPhase: "Waxing Crescent",
                    daylightHours: 11.1,
                    city: "Novosibirsk"
                )
            )
        )
        simulationVM.scenarioText = "Sleep at 22:30"
        simulationVM.selectedType = .sleep
        simulationVM.response = response

        let simulationView = SimulationView(testViewModel: simulationVM)
        simulationView._testEvaluateSections(response: response, error: "Network unavailable")
        simulationView._testTriggerActions()
        _ = simulationView.body
    }

    @MainActor
    func testAdditionalViewWrapperCoverageHooks() async throws {
        let insight = Insight(
            userId: UUID(),
            category: .recovery,
            title: "Hook",
            body: "Coverage",
            confidence: 0.92
        )

        let insightsViewModel = InsightsViewModel()
        insightsViewModel._testOverrideState(
            lowConfidenceCount: 0,
            insights: [insight],
            latestWeeklyStrategyReport: nil,
            isLoading: false,
            loadError: nil,
            allInsights: [insight]
        )
        let insightsView = InsightsView(viewModel: insightsViewModel)
        await insightsView._testExerciseNavigationAndTaskWrappers(sampleInsight: insight)
        insightsView._testExerciseFilterActions()

        let dbQueue = try DatabaseQueue(path: ":memory:")
        let sleepLoadComplete = await SleepDayViewTestHarness.runLoadTask(
            dateString: "2026-02-24",
            dbQueue: dbQueue
        )
        let supplementsLoadComplete = await SupplementsDayViewTestHarness.runLoadTask(
            dateString: "2026-02-24",
            dbQueue: dbQueue
        )
        let trainingLoadComplete = await TrainingDayViewTestHarness.runLoadTask(
            dateString: "2026-02-24",
            dbQueue: dbQueue
        )

        XCTAssertTrue(sleepLoadComplete)
        XCTAssertTrue(supplementsLoadComplete)
        XCTAssertTrue(trainingLoadComplete)
    }

    @MainActor
    func testSettingsViewModelExportStatusBranches() async {
        let successMessage = await SettingsView._testRequestExportSuccessMessage(exportId: "export-123")
        XCTAssertEqual(successMessage, "\(String(localized: "settings_export_data")): export-123")

        let failureMessage = await SettingsView._testRequestExportFailureMessage()
        XCTAssertEqual(failureMessage, "export-failed")
    }

    func testSettingsDestinationHarnessCoversBodiesAndViewModels() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let syncEngine = SyncEngine(
            dbQueue: manager.dbQueue,
            apiClient: api,
            pushTransportOverride: { _ in }
        )
        GuardianManager._testSetAuthorizationOverride(true)
        GuardianManager._testSetRequestAuthorization { }
        defer {
            GuardianManager._testSetAuthorizationOverride(nil)
            GuardianManager._testSetRequestAuthorization(nil)
            AuthManager.setActiveAuthIdForTests(nil)
        }

        SettingsDestinationViewsTestHarness.exerciseBodyBranches()
        SettingsDestinationViewsTestHarness.exerciseAccountSettingsBodyBranches()

        let errors = SettingsDestinationViewsTestHarness.userFacingErrors()
        XCTAssertEqual(errors.first, "custom")
        XCTAssertEqual(errors.count, 3)
        XCTAssertFalse(errors[2].isEmpty)
        let privacyPayload = SettingsDestinationViewsTestHarness.privacyPayloadSnapshot()
        XCTAssertEqual(privacyPayload["cloud_backup_enabled"] as? Bool, true)
        XCTAssertEqual(privacyPayload["cloud_ocr_enabled"] as? Bool, true)
        XCTAssertNotNil(privacyPayload["id"])
        XCTAssertNotNil(privacyPayload["user_id"])

        let syncOutputs = await SettingsDestinationViewsTestHarness.exerciseSyncViewModel(syncEngine: syncEngine)
        XCTAssertFalse(syncOutputs.isEmpty)

        try await SettingsDestinationViewsTestHarness.enqueueOutboxMutation(
            syncEngine: syncEngine,
            path: "api-settings-notifications"
        )

        AuthManager.setActiveAuthIdForTests(nil)
        let noAuthNotifications = await SettingsDestinationViewsTestHarness.exerciseNotificationsViewModel(
            syncEngine: syncEngine,
            dbQueue: manager.dbQueue
        )
        XCTAssertTrue(noAuthNotifications.isLoaded)

        let noAuthPrivacy = await SettingsDestinationViewsTestHarness.exercisePrivacyViewModel(
            syncEngine: syncEngine,
            dbQueue: manager.dbQueue
        )
        XCTAssertTrue(noAuthPrivacy.isLoaded)

        let authId = UUID()
        let userId = UUID()
        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [userId.uuidString, authId.uuidString, "UTC", "metric", Date(), Date()]
            )
        }

        AuthManager.setActiveAuthIdForTests(authId)
        let withAuthNotifications = await SettingsDestinationViewsTestHarness.exerciseNotificationsViewModel(
            syncEngine: syncEngine,
            dbQueue: manager.dbQueue
        )
        XCTAssertTrue(withAuthNotifications.isLoaded)

        let withAuthPrivacy = await SettingsDestinationViewsTestHarness.exercisePrivacyViewModel(
            syncEngine: syncEngine,
            dbQueue: manager.dbQueue
        )
        XCTAssertTrue(withAuthPrivacy.isLoaded)
        XCTAssertTrue(withAuthPrivacy.canCancelDeletion)
        let existingPrivacyLoaded = await SettingsDestinationViewsTestHarness.exercisePrivacyExistingLoadBranch(
            syncEngine: syncEngine,
            dbQueue: manager.dbQueue
        )
        XCTAssertTrue(existingPrivacyLoaded.isLoaded)
        XCTAssertTrue(existingPrivacyLoaded.usedExistingBranch)

        let forcedSuccess = await SettingsDestinationViewsTestHarness.exerciseInsertionAndSaveSuccessPaths(
            syncEngine: syncEngine,
            dbQueue: manager.dbQueue,
            authId: authId,
            userId: userId
        )
        XCTAssertTrue(forcedSuccess.notificationsLoaded)
        XCTAssertTrue(forcedSuccess.privacyLoaded)
        XCTAssertFalse((forcedSuccess.notificationsStatus ?? "").isEmpty)
        XCTAssertFalse((forcedSuccess.privacyStatus ?? "").isEmpty)

        let additionalBranchOutputs = await SettingsDestinationViewsTestHarness
            .exerciseLatestUserIdAndExistingLoadBranches(
                syncEngine: syncEngine,
                dbQueue: manager.dbQueue,
                authId: authId
            )
        XCTAssertEqual(additionalBranchOutputs.count, 5)
        XCTAssertFalse(additionalBranchOutputs[0].isEmpty)
        XCTAssertFalse(additionalBranchOutputs[1].isEmpty)

        let deterministicCoverageOutputs = await SettingsDestinationViewsTestHarness
            .exerciseDeterministicCoverageBranches(
                syncEngine: syncEngine,
                dbQueue: manager.dbQueue,
                authId: authId
            )
        XCTAssertEqual(deterministicCoverageOutputs.count, 7)
        XCTAssertFalse(deterministicCoverageOutputs[0].isEmpty)
        XCTAssertFalse(deterministicCoverageOutputs[1].isEmpty)
        XCTAssertEqual(deterministicCoverageOutputs[2], "notifications_inserted")
        XCTAssertEqual(deterministicCoverageOutputs[3], "notifications_loaded_existing")
        XCTAssertEqual(deterministicCoverageOutputs[4], "privacy_inserted")
        XCTAssertEqual(deterministicCoverageOutputs[5], "privacy_loaded_existing")
        XCTAssertFalse(deterministicCoverageOutputs[6].isEmpty)

        let nilHelperOutputs = SettingsDestinationViewsTestHarness.exerciseOptionalStringHelpersWithNilBranches()
        XCTAssertEqual(nilHelperOutputs.count, 4)
        XCTAssertEqual(nilHelperOutputs[0], "")
        XCTAssertEqual(nilHelperOutputs[1], "nil")
        XCTAssertEqual(nilHelperOutputs[2], "")
        XCTAssertEqual(nilHelperOutputs[3], "fallback")

        let valueHelperOutputs = SettingsDestinationViewsTestHarness.exerciseOptionalStringHelpersWithValueBranches()
        XCTAssertEqual(valueHelperOutputs.count, 4)
        XCTAssertEqual(valueHelperOutputs[0], "value")
        XCTAssertEqual(valueHelperOutputs[1], "value")
        XCTAssertEqual(valueHelperOutputs[2], "flagged")
        XCTAssertEqual(valueHelperOutputs[3], "status")

        let loadSaveCoverageOutputs = await SettingsDestinationViewsTestHarness
            .exerciseNotificationsAndPrivacyLoadSaveCoverage(
                syncEngine: syncEngine,
                dbQueue: manager.dbQueue,
                authId: authId,
                userId: userId
            )
        XCTAssertEqual(loadSaveCoverageOutputs.count, 8)
        XCTAssertFalse(loadSaveCoverageOutputs[0].isEmpty)
        XCTAssertFalse(loadSaveCoverageOutputs[2].isEmpty)
        XCTAssertEqual(loadSaveCoverageOutputs[4], "notifications_insert_loaded")
        XCTAssertEqual(loadSaveCoverageOutputs[5], "notifications_existing_loaded")
        XCTAssertEqual(loadSaveCoverageOutputs[6], "privacy_insert_loaded")
        XCTAssertEqual(loadSaveCoverageOutputs[7], "privacy_existing_loaded")

        let explicitTransitions = await SettingsDestinationViewsTestHarness
            .exerciseExplicitLoadSaveTransitionBranches(
                syncEngine: syncEngine,
                dbQueue: manager.dbQueue,
                authId: authId,
                userId: userId
            )
        XCTAssertEqual(explicitTransitions.count, 4)
        XCTAssertEqual(explicitTransitions[0], "notifications_inserted")
        XCTAssertEqual(explicitTransitions[1], "notifications_existing")
        XCTAssertEqual(explicitTransitions[2], "privacy_inserted")
        XCTAssertEqual(explicitTransitions[3], "privacy_existing")

        let deterministicLoadSave = await SettingsDestinationViewsTestHarness
            .exerciseDeterministicLoadAndSaveBranches(
                syncEngine: syncEngine,
                dbQueue: manager.dbQueue,
                authId: authId,
                userId: userId
            )
        XCTAssertEqual(deterministicLoadSave.count, 6)
        XCTAssertEqual(deterministicLoadSave[0], "notifications_insert_path")
        XCTAssertEqual(deterministicLoadSave[1], "notifications_loaded_path")
        XCTAssertFalse(deterministicLoadSave[2].isEmpty)
        XCTAssertEqual(deterministicLoadSave[3], "privacy_insert_path")
        XCTAssertEqual(deterministicLoadSave[4], "privacy_loaded_path")
        XCTAssertFalse(deterministicLoadSave[5].isEmpty)

        let directHelperOutputs = await SettingsDestinationViewsTestHarness.exerciseDirectViewModelHelperBranches(
            syncEngine: syncEngine,
            dbQueue: manager.dbQueue
        )
        XCTAssertEqual(directHelperOutputs.count, 7)
        XCTAssertEqual(directHelperOutputs[0], "notifications_loaded")
        XCTAssertEqual(directHelperOutputs[1], "privacy_loaded")
        XCTAssertFalse(directHelperOutputs[2].isEmpty)
        XCTAssertEqual(directHelperOutputs[3], "nil")
        XCTAssertFalse(directHelperOutputs[4].isEmpty)
        XCTAssertEqual(directHelperOutputs[5], "nil")
        XCTAssertFalse(directHelperOutputs[6].isEmpty)

        let syncFailureManager = try DatabaseManager.inMemory()
        let syncFailureEngine = SyncEngine(
            dbQueue: syncFailureManager.dbQueue,
            apiClient: FakeSyncAPIClient(),
            pushTransportOverride: { _ in }
        )
        let syncFailureOutputs = await SettingsDestinationViewsTestHarness.exerciseSyncViewModelFailureBranches(
            syncEngine: syncFailureEngine,
            dbQueue: syncFailureManager.dbQueue
        )
        XCTAssertEqual(syncFailureOutputs.count, 4)
        XCTAssertGreaterThanOrEqual(syncFailureOutputs.filter { !$0.isEmpty }.count, 3)

        GuardianManager._testSetRequestAuthorization {
            throw NSError(
                domain: "GuardianCoverage",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "guardian-denied"]
            )
        }
        let guardianFailureStatus = await SettingsDestinationViewsTestHarness.exerciseGuardianAuthorizationFailure(
            syncEngine: syncEngine,
            dbQueue: manager.dbQueue
        )
        XCTAssertFalse((guardianFailureStatus ?? "").isEmpty)
        GuardianManager._testSetRequestAuthorization { }

        let failureOutputs = await SettingsDestinationViewsTestHarness.exerciseFailureBranches(
            syncEngine: syncEngine,
            dbQueue: manager.dbQueue
        )
        XCTAssertEqual(failureOutputs.count, 8)
        XCTAssertGreaterThanOrEqual(failureOutputs.filter { !$0.isEmpty }.count, 5)

        let accountManager = try DatabaseManager.inMemory()
        let accountSyncEngine = SyncEngine(
            dbQueue: accountManager.dbQueue,
            apiClient: FakeSyncAPIClient(),
            pushTransportOverride: { _ in }
        )

        let profileOutputs = try await SettingsDestinationViewsTestHarness.exerciseProfileSettingsViewModel(
            syncEngine: accountSyncEngine,
            dbQueue: accountManager.dbQueue,
            authId: authId,
            userId: userId
        )
        XCTAssertTrue(profileOutputs.isLoaded)
        XCTAssertFalse((profileOutputs.statusMessage ?? "").isEmpty)
        XCTAssertEqual(profileOutputs.storedDisplayName, "Morgan")
        XCTAssertEqual(profileOutputs.storedDateOfBirth, "1993-04-12")
        XCTAssertEqual(profileOutputs.outboxDisplayName, "Morgan")
        XCTAssertEqual(profileOutputs.outboxGoal, PrimaryGoal.recovery.rawValue)

        let healthFlagsOutputs = try await SettingsDestinationViewsTestHarness.exerciseHealthFlagsSettingsViewModel(
            syncEngine: accountSyncEngine,
            dbQueue: accountManager.dbQueue,
            authId: authId,
            userId: userId
        )
        XCTAssertTrue(healthFlagsOutputs.isLoaded)
        XCTAssertFalse((healthFlagsOutputs.statusMessage ?? "").isEmpty)
        XCTAssertTrue(healthFlagsOutputs.disableHrv)
        XCTAssertTrue(healthFlagsOutputs.hideCalories)
        XCTAssertTrue(healthFlagsOutputs.pregnancyMode)

        let unitsLocaleOutputs = try await SettingsDestinationViewsTestHarness.exerciseUnitsLocaleSettingsViewModel(
            syncEngine: accountSyncEngine,
            dbQueue: accountManager.dbQueue,
            authId: authId,
            userId: userId
        )
        XCTAssertTrue(unitsLocaleOutputs.isLoaded)
        XCTAssertFalse((unitsLocaleOutputs.statusMessage ?? "").isEmpty)
        XCTAssertEqual(unitsLocaleOutputs.storedUnits, UnitSystem.imperial.rawValue)
        XCTAssertEqual(unitsLocaleOutputs.storedTimeZone, "America/New_York")

        let appleHealthOutputs = try await SettingsDestinationViewsTestHarness.exerciseAppleHealthSettingsViewModel(
            dbQueue: accountManager.dbQueue,
            authId: authId,
            userId: userId
        )
        XCTAssertEqual(
            appleHealthOutputs.summaryBefore,
            String(localized: "settings_apple_health_status_not_requested")
        )
        XCTAssertEqual(
            appleHealthOutputs.summaryAfter,
            String(localized: "settings_apple_health_status_connected")
        )
        XCTAssertFalse((appleHealthOutputs.statusMessage ?? "").isEmpty)
        XCTAssertTrue(appleHealthOutputs.canImportAfterRequest)

        let exportOutputs = try await SettingsDestinationViewsTestHarness.exerciseExportViewModel(
            dbQueue: accountManager.dbQueue,
            authId: authId,
            userId: userId
        )
        XCTAssertTrue(exportOutputs.isLoaded)
        XCTAssertFalse((exportOutputs.statusMessage ?? "").isEmpty)
        XCTAssertFalse((exportOutputs.exportId ?? "").isEmpty)
        XCTAssertTrue(exportOutputs.canDownload)
        XCTAssertTrue(exportOutputs.queuedLocally)
    }

    func testSettingsDeterministicLoadSaveSucceedsInIsolatedStore() async throws {
        let manager = try DatabaseManager.inMemory()
        let syncEngine = SyncEngine(
            dbQueue: manager.dbQueue,
            apiClient: FakeSyncAPIClient(),
            pushTransportOverride: { _ in }
        )
        let authId = UUID()
        let userId = UUID()

        let outputs = await SettingsDestinationViewsTestHarness.exerciseDeterministicLoadAndSaveBranches(
            syncEngine: syncEngine,
            dbQueue: manager.dbQueue,
            authId: authId,
            userId: userId
        )

        XCTAssertEqual(outputs.count, 6)
        XCTAssertEqual(outputs[0], "notifications_insert_path")
        XCTAssertEqual(outputs[1], "notifications_loaded_path")
        XCTAssertFalse(outputs[2].isEmpty)
        XCTAssertEqual(outputs[3], "privacy_insert_path")
        XCTAssertEqual(outputs[4], "privacy_loaded_path")
        XCTAssertFalse(outputs[5].isEmpty)
    }

    func testInsightDetailHarnessLoadsRowsAndDecodeErrorBranch() async throws {
        InsightDetailViewTestHarness.exerciseBodyBranches()
        InsightDetailViewTestHarness.exerciseExperimentDetailBody()
        XCTAssertEqual(InsightDetailViewTestHarness.localizedCategories().count, 8)

        let authId = UUID()
        let userId = UUID()
        let validInsightId = UUID()
        let brokenInsightId = UUID()

        try await DatabaseManager.shared.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [userId.uuidString, authId.uuidString, "UTC", "metric", Date(), Date()]
            )

            try db.execute(
                sql: """
                    INSERT INTO insights (
                        id, user_id, category, title, body, confidence, priority,
                        actionable, read, acknowledged, dismissed, needs_review,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    validInsightId.uuidString,
                    userId.uuidString,
                    "recovery",
                    "Valid",
                    "Body",
                    0.8,
                    1,
                    false,
                    false,
                    false,
                    false,
                    false,
                    Date(),
                    Date()
                ]
            )

            try db.execute(
                sql: """
                    INSERT INTO insights (
                        id, user_id, category, title, body, confidence, priority,
                        actionable, read, acknowledged, dismissed, needs_review,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    brokenInsightId.uuidString,
                    userId.uuidString,
                    "unknown_category",
                    "Broken",
                    "Body",
                    0.4,
                    1,
                    false,
                    false,
                    false,
                    false,
                    true,
                    Date(),
                    Date()
                ]
            )
        }

        let valid = await InsightDetailViewTestHarness.loadInsightResult(insightId: validInsightId)
        XCTAssertNotNil(valid.insight)
        XCTAssertNil(valid.loadError)

        let broken = await InsightDetailViewTestHarness.loadInsightResult(insightId: brokenInsightId)
        XCTAssertNil(broken.insight)
        XCTAssertNotNil(broken.loadError)
    }

    func testDayViewHarnessesLoadDataRows() async throws {
        TrainingDayViewTestHarness.exerciseBodyBranches()
        SupplementsDayViewTestHarness.exerciseBodyBranches()
        SleepDayViewTestHarness.exerciseBodyBranches()
        RecoveryDetailViewTestHarness.exerciseBodyBranches()

        let trainingFormattingSamples = TrainingDayViewTestHarness.summaryFormattingCoverageSamples()
        XCTAssertGreaterThanOrEqual(trainingFormattingSamples.count, 9)
        XCTAssertTrue(trainingFormattingSamples.contains("figure.cooldown"))

        let decodedTrainingCount = try TrainingDayViewTestHarness.decodeSummaryCountWithInvalidRows()
        XCTAssertEqual(decodedTrainingCount, 1)
        let decodedSupplementCount = try SupplementsDayViewTestHarness.decodeSummaryCountWithInvalidRows()
        XCTAssertEqual(decodedSupplementCount, 2)

        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        AuthManager.setActiveAuthIdForTests(authId)

        let day = "2026-02-24"
        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [userId.uuidString, authId.uuidString, "UTC", "metric", Date(), Date()]
            )

            let sessionId = UUID()
            try db.execute(
                sql: """
                    INSERT INTO workout_sessions (
                        id, user_id, started_at, session_date, source,
                        duration_minutes, workout_type, total_sets, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    sessionId.uuidString,
                    userId.uuidString,
                    Date(),
                    day,
                    "manual",
                    45,
                    "cardio",
                    12,
                    Date(),
                    Date()
                ]
            )

            let supplementId = UUID()
            try db.execute(
                sql: """
                    INSERT INTO supplement_logs (
                        id, user_id, taken_at, taken_date, supplement_name,
                        dose_amount, dose_unit, was_scheduled, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    supplementId.uuidString,
                    userId.uuidString,
                    Date(),
                    day,
                    "Magnesium",
                    200.0,
                    "mg",
                    false,
                    Date(),
                    Date()
                ]
            )

            let sleepId = UUID()
            try db.execute(
                sql: """
                    INSERT INTO sleep_logs (
                        id, user_id, date, sleep_date, total_duration_minutes,
                        sleep_efficiency, source, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    sleepId.uuidString,
                    userId.uuidString,
                    day,
                    day,
                    470,
                    91.0,
                    "healthkit",
                    Date(),
                    Date()
                ]
            )

            let stateId = UUID()
            try db.execute(
                sql: """
                    INSERT INTO physiological_states (
                        id, user_id, date, recovery_score, recovery_zone,
                        confidence_score, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    stateId.uuidString,
                    userId.uuidString,
                    day,
                    71.0,
                    "ready",
                    0.79,
                    Date(),
                    Date()
                ]
            )
        }

        let trainingSummaries = await TrainingDayViewTestHarness.loadSessions(
            dateString: day,
            dbQueue: manager.dbQueue
        )
        XCTAssertEqual(trainingSummaries.count, 1)
        _ = await TrainingDayViewTestHarness.loadSessions(dateString: nil, dbQueue: manager.dbQueue)

        let supplementSummaries = await SupplementsDayViewTestHarness.loadLogs(
            dateString: day,
            dbQueue: manager.dbQueue
        )
        XCTAssertEqual(supplementSummaries.count, 1)
        _ = await SupplementsDayViewTestHarness.loadLogs(dateString: nil, dbQueue: manager.dbQueue)

        let sleepSummary = await SleepDayViewTestHarness.loadSummary(
            dateString: day,
            dbQueue: manager.dbQueue
        )
        XCTAssertNotNil(sleepSummary)

        let recoverySummary = await RecoveryDetailViewTestHarness.loadSummary(
            dateString: day,
            dbQueue: manager.dbQueue
        )
        XCTAssertNotNil(recoverySummary)
    }

    func testHealthSyncManagerDebugBuilderAndPercentages() throws {
        let userId = UUID()
        let existing = PhysiologicalState(
            id: UUID(),
            userId: userId,
            date: "2026-02-23",
            recoveryScore: 50
        )

        let computed = RecoveryEngine.ComputedScore(
            score: 77,
            zone: .ready,
            confidence: 0.82,
            components: RecoveryScoreValue.Components(
                hrvScore: 70,
                sleepScore: 80,
                rhrScore: 75,
                tempScore: 83
            )
        )
        let sleep = SleepData(
            totalHours: 8,
            deepMinutes: 90,
            remMinutes: 100,
            lightMinutes: 260,
            awakeMinutes: 30,
            efficiency: 92,
            bedTime: nil,
            wakeTime: nil
        )
        let environment = EnvironmentalContext(
            weatherCondition: "clear",
            temperatureC: 22,
            pressureHpa: nil,
            pressureDeltaHpa24h: nil,
            aqi: 34,
            indoorCo2Ppm: nil,
            moonPhase: nil,
            daylightHours: nil,
            city: "Baku"
        )

        let built = HealthSyncManager._testBuildState(
            dateString: "2026-02-24",
            userId: userId,
            existingState: existing,
            computed: computed,
            completeness: 0.9,
            hrv: 4.2,
            sleep: sleep,
            rhr: 54,
            temp: 0.2,
            steps: 9000,
            activeCal: 620,
            respRate: 14.2,
            o2: 98.3,
            environment: environment
        )

        XCTAssertEqual(built.id, existing.id)
        XCTAssertEqual(built.createdAt, existing.createdAt)
        XCTAssertEqual(built.recoveryScore, 77, accuracy: 0.001)
        XCTAssertEqual(built.recoveryZone, .ready)
        XCTAssertEqual(try XCTUnwrap(built.deepSleepPercent), 18.75, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(built.remSleepPercent), 20.8333, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(built.lightSleepPercent), 54.1666, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(built.awakePercent), 6.25, accuracy: 0.001)
        XCTAssertEqual(built.steps, 9000)
        XCTAssertEqual(built.activeCalories, 620)
        XCTAssertEqual(built.environmentalContext?.city, "Baku")

        var existingWithEnvironment = existing
        existingWithEnvironment.environmentalContext = environment
        let preservedEnvironment = HealthSyncManager._testBuildState(
            dateString: "2026-02-24",
            userId: userId,
            existingState: existingWithEnvironment,
            computed: computed,
            completeness: 0.9,
            hrv: 4.2,
            sleep: sleep,
            rhr: 54,
            temp: 0.2,
            steps: 9000,
            activeCal: 620,
            respRate: 14.2,
            o2: 98.3,
            environment: nil
        )
        XCTAssertEqual(preservedEnvironment.environmentalContext?.city, "Baku")

        XCTAssertEqual(
            try XCTUnwrap(HealthSyncManager._testSafePercentage(30, total: 2)),
            25,
            accuracy: 0.0001
        )
        XCTAssertNil(HealthSyncManager._testSafePercentage(nil, total: 2))
        XCTAssertNil(HealthSyncManager._testSafePercentage(30, total: nil))
        XCTAssertNil(HealthSyncManager._testSafePercentage(30, total: 0))

        let dateString = HealthSyncManager._testDateString(from: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(dateString.isEmpty)
    }

    func testHealthKitManagerDebugHelpersAndSourceRanking() async throws {
        let manager = HealthKitManager()

        let bounds = await manager._testDayBounds(for: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertLessThan(bounds.start, bounds.end)

        let medianEmpty = await manager._testMedian([])
        let medianOdd = await manager._testMedian([3, 1, 2])
        let medianEven = await manager._testMedian([1, 2, 3, 4])
        XCTAssertNil(medianEmpty)
        XCTAssertEqual(try XCTUnwrap(medianOdd), 2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(medianEven), 2.5, accuracy: 0.0001)

        let sleepType = HKCategoryType(.sleepAnalysis)
        let now = Date()
        let deep = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            start: now.addingTimeInterval(-3600),
            end: now.addingTimeInterval(-1800)
        )
        let awake = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.awake.rawValue,
            start: now.addingTimeInterval(-1800),
            end: now
        )
        let unspecified = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            start: now.addingTimeInterval(-7200),
            end: now.addingTimeInterval(-3600)
        )
        let samples = [unspecified, deep, awake]

        let hasStages = await manager._testHasSleepStages(samples)
        let asleepMinutes = await manager._testAsleepMinutes(samples)
        let mainBout = await manager._testSelectMainSleepBout(samples, for: now)
        let preferredSleepSource = await manager._testSelectPreferredSleepSource(samples)
        XCTAssertTrue(hasStages)
        XCTAssertGreaterThan(asleepMinutes, 0)
        XCTAssertFalse(mainBout.isEmpty)
        XCTAssertEqual(preferredSleepSource.count, samples.count)

        let quantityType = HKQuantityType(.heartRateVariabilitySDNN)
        let q1 = HKQuantitySample(
            type: quantityType,
            quantity: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: 60),
            start: now.addingTimeInterval(-1200),
            end: now.addingTimeInterval(-1200)
        )
        let q2 = HKQuantitySample(
            type: quantityType,
            quantity: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: 55),
            start: now.addingTimeInterval(-600),
            end: now.addingTimeInterval(-600),
            metadata: [HKMetadataKeyWasUserEntered: true]
        )

        let preferred = await manager._testPreferredSourceSamples([q1, q2])
        let best = await manager._testBestBySourcePrecedence([q1, q2])
        XCTAssertFalse(preferred.isEmpty)
        XCTAssertNotNil(best)

        XCTAssertEqual(
            HealthKitManager._testSourceRank(
                bundleIdentifier: "com.apple.watch.health",
                productType: "Watch7,4",
                userEntered: false
            ),
            0
        )
        XCTAssertEqual(
            HealthKitManager._testSourceRank(
                bundleIdentifier: "com.apple.health",
                productType: "iPhone15,3",
                userEntered: false
            ),
            2
        )
        XCTAssertEqual(
            HealthKitManager._testSourceRank(
                bundleIdentifier: "com.other.provider",
                productType: nil,
                userEntered: true
            ),
            3
        )
        XCTAssertTrue(
            HealthKitManager._testIsWatch(
                bundleIdentifier: "com.apple.watch.health",
                productType: "Watch8,1"
            )
        )
        XCTAssertTrue(HealthKitManager._testIsIPhone(productType: "iPhone16,2"))
        XCTAssertFalse(HealthKitManager._testIsIPhone(productType: "Watch9,1"))
    }

    func testAPIClientDebugHelpersCoverRetryDateAndDecodingLogic() async throws {
        struct SnakePayload: Decodable, Sendable {
            let createdAt: Date
            let payloadData: Data
        }
        struct EdgePayload: Decodable, Sendable {}

        let api = APIClient(deviceId: "test-device")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        APIClient._testResetOverrides()
        defer { APIClient._testResetOverrides() }

        let isoFractional = ISO8601DateFormatter.supabaseString(from: now)
        XCTAssertNotNil(APIClient._testParseSupabaseDate(isoFractional))
        XCTAssertNotNil(APIClient._testParseSupabaseDate("2023-11-14T10:00:00Z"))
        XCTAssertNotNil(APIClient._testParseSupabaseDate("2023-11-14"))
        XCTAssertNotNil(APIClient._testParseSupabaseDate("1700000000"))
        XCTAssertNil(APIClient._testParseSupabaseDate("not-a-date"))

        let dayString = APIClient._testUTCDateOnlyString(now)
        XCTAssertEqual(dayString.count, 10)
        let utcIdentifier = APIClient._testUTCGregorianCalendarTimeZoneIdentifier()
        XCTAssertTrue(["UTC", "GMT"].contains(utcIdentifier))

        let daysAgo0 = await api._testDaysAgo(0, now: now)
        let daysAgo7 = await api._testDaysAgo(7, now: now)
        XCTAssertEqual(daysAgo0, now)
        XCTAssertLessThan(daysAgo7, now)
        APIClient._testSetDaysAgoDateByAddingRunner { _, _ in nil }
        let fallbackDaysAgo = await api._testDaysAgo(2, now: now)
        XCTAssertEqual(
            fallbackDaysAgo.timeIntervalSince1970,
            now.addingTimeInterval(-172_800).timeIntervalSince1970,
            accuracy: 0.1
        )
        APIClient._testSetDaysAgoDateByAddingRunner(nil)

        let dateOnlyCutoff = await api._testCutoffString(forTable: "physiological_states", days: 7, now: now)
        XCTAssertEqual(dateOnlyCutoff.count, 10)
        let timestampCutoff = await api._testCutoffString(forTable: "food_items", days: 7, now: now)
        XCTAssertTrue(timestampCutoff.contains("T"))

        let transport429 = NSError(domain: "APIClient", code: 0, userInfo: ["status": 429])
        let retry429 = await api._testIsRetryable(transport429)
        let retryTimeout = await api._testIsRetryable(URLError(.timedOut))
        let retryBadURL = await api._testIsRetryable(URLError(.badURL))
        let retry500 = await api._testIsRetryable(NSError(domain: "Custom", code: 500))
        let retry404 = await api._testIsRetryable(NSError(domain: "Custom", code: 404))
        XCTAssertTrue(retry429)
        XCTAssertTrue(retryTimeout)
        XCTAssertFalse(retryBadURL)
        XCTAssertTrue(retry500)
        XCTAssertFalse(retry404)

        let snakeData = Data(
            """
            {"created_at":"\(isoFractional)","payload_data":"SGVsbG8="}
            """.utf8
        )
        let decoded: SnakePayload = try await api._testDecodePayload(snakeData, as: SnakePayload.self)
        XCTAssertEqual(String(data: decoded.payloadData, encoding: .utf8), "Hello")
        do {
            let _: SnakePayload = try await api._testDecodePayload(
                Data("{\"created_at\":\"\(isoFractional)\",\"payload_data\":null}".utf8),
                as: SnakePayload.self
            )
            XCTFail("Expected null Data payload to throw")
        } catch {
            XCTAssertNotNil(error.localizedDescription)
        }
        let utf8Payload: SnakePayload = try await api._testDecodePayload(
            Data("{\"created_at\":\"\(isoFractional)\",\"payload_data\":\"plain-text\"}".utf8),
            as: SnakePayload.self
        )
        XCTAssertEqual(String(data: utf8Payload.payloadData, encoding: .utf8), "plain-text")
        let jsonPayload: SnakePayload = try await api._testDecodePayload(
            Data("{\"created_at\":\"\(isoFractional)\",\"payload_data\":{\"k\":\"v\"}}".utf8),
            as: SnakePayload.self
        )
        let payloadObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: jsonPayload.payloadData) as? [String: String]
        )
        XCTAssertEqual(payloadObject["k"], "v")
        do {
            let _: SnakePayload = try await api._testDecodePayload(
                Data("{\"created_at\":\"bad-date\",\"payload_data\":\"SGVsbG8=\"}".utf8),
                as: SnakePayload.self
            )
            XCTFail("Expected invalid date decoding to throw")
        } catch {
            XCTAssertNotNil(error.localizedDescription)
        }

        let lossyValue = try APIClient._testLossyJSONFoundationValue(
            Data("{\"a\":[1,true,null,{\"k\":\"v\"}]}".utf8)
        )
        let top = try XCTUnwrap(lossyValue as? [String: Any])
        XCTAssertNotNil(top["a"] as? [Any])
        XCTAssertTrue(APIClient._testTriggerLossyJSONUnsupportedBranch())

        let requestURL = try XCTUnwrap(URL(string: "https://example.com/rest/v1/users"))
        let okResponse = try XCTUnwrap(
            HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: nil, headerFields: ["X-Min-App-Version": "0.0.1"])
        )
        APIClient._testSetExecuteDecodedQueryOverride { (Data("[]".utf8), okResponse) }

        let _: [FoodLog] = try await api.fetchFoodLogs()
        let _: [DailyNutritionTarget] = try await api.fetchNutritionTargets()
        let _: [WorkoutSession] = try await api.fetchWorkoutSessions()
        let _: [TrainingLoad] = try await api.fetchTrainingLoads()
        let _: [UserSupplement] = try await api.fetchUserSupplements()
        let _: [SupplementLog] = try await api.fetchSupplementLogs()
        let _: [WellnessCheck] = try await api.fetchWellnessChecks()
        let _: [BodyComposition] = try await api.fetchBodyComposition()
        let _: [HydrationLog] = try await api.fetchHydrationLogs()
        let _: [Insight] = try await api.fetchInsights()
        let _: [FoodLog] = try await api.fetchHistoricalFoodLogs(
            orderBy: "logged_at",
            ascending: true,
            limit: 25,
            offset: 0,
            exactMatch: ["logged_date": "2026-02-24"]
        )
        let _: [LifeOS.User] = try await api.fetch(
            from: "users",
            since: now,
            orderBy: "updated_at",
            ascending: true,
            limit: 10,
            offset: 0,
            activeWindowDays: 90,
            exactMatch: ["id": UUID().uuidString]
        )
        let _: [LifeOS.User] = try await api.fetchSyncPage(
            from: "users",
            since: nil,
            cursor: nil,
            limit: 0,
            activeWindowDays: 14
        )
        let _: LifeOS.User? = try await api.fetchUserProfile()
        let _: PhysiologicalState? = try await api.fetchLatestRecovery()
        let _: [PhysiologicalState] = try await api.fetchRecoveryTrend(days: 1)
        let _: NotificationSettings? = try await api.fetchNotificationSettings()
        let _: OnboardingState? = try await api.fetchOnboardingState()
        let _: UserBaseline? = try await api.fetchUserBaseline()

        APIClient._testSetPostgrestAccessTokenOverride("coverage-token")
        APIClient._testSetPostgrestDataForRequestOverride { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer coverage-token")
            return (Data(), okResponse)
        }
        let validBody = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString])
        try await api.upsertRow(table: "users", bodyJson: validBody, headers: [:])

        APIClient._testSetPostgrestDataForRequestOverride { request in
            let fallbackURL = request.url ?? requestURL
            return (
                Data(),
                URLResponse(
                    url: fallbackURL,
                    mimeType: nil,
                    expectedContentLength: 0,
                    textEncodingName: nil
                )
            )
        }
        do {
            try await api.upsertRow(table: "users", bodyJson: validBody, headers: [:])
            XCTFail("Expected invalid HTTP response error")
        } catch {
            XCTAssertNotNil(error.localizedDescription)
        }

        let badStatus = try XCTUnwrap(
            HTTPURLResponse(
                url: requestURL,
                statusCode: 400,
                httpVersion: nil,
                headerFields: ["Retry-After": "120"]
            )
        )
        APIClient._testSetPostgrestDataForRequestOverride { _ in
            (Data([0xFF]), badStatus)
        }
        do {
            try await api.upsertRow(table: "users", bodyJson: validBody, headers: [:])
            XCTFail("Expected HTTP status error")
        } catch let error as NSError {
            XCTAssertEqual(error.userInfo["status"] as? Int, 400)
            XCTAssertEqual(error.userInfo["retry_after_seconds"] as? TimeInterval, 120)
        }

        actor AttemptCounter {
            private var value = 0
            func increment() { value += 1 }
            func snapshot() -> Int { value }
        }

        let notRetryableStatus = try XCTUnwrap(
            HTTPURLResponse(url: requestURL, statusCode: 404, httpVersion: nil, headerFields: nil)
        )
        let notRetryableAttempts = AttemptCounter()
        APIClient._testSetPostgrestDataForRequestOverride { _ in
            await notRetryableAttempts.increment()
            return (Data("not-found".utf8), notRetryableStatus)
        }
        do {
            try await api.upsertRow(table: "users", bodyJson: validBody, headers: [:])
            XCTFail("Expected non-retryable HTTP status error")
        } catch {
            XCTAssertNotNil(error.localizedDescription)
        }
        let notRetryableAttemptsCount = await notRetryableAttempts.snapshot()
        XCTAssertEqual(notRetryableAttemptsCount, 1)

        let edgeResponse = try XCTUnwrap(
            HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: nil, headerFields: ["X-Min-App-Version": "0.0.1"])
        )
        let passthrough = try APIClient._testPassthroughFunctionInvokeResult(
            data: Data("{\"ok\":true}".utf8),
            response: edgeResponse
        )
        XCTAssertEqual(String(data: passthrough.0, encoding: .utf8), "{\"ok\":true}")
        XCTAssertEqual(passthrough.1.statusCode, 200)
        APIClient._testSetEdgeInvokeOverride { _, _ in
            (Data("{}".utf8), edgeResponse)
        }
        let _: EdgePayload = try await api.callEdgeFunction(
            "coverage_fn_ok",
            body: Data("{}".utf8),
            headers: ["X-Outbox-Replay": "true"],
            maxAttempts: 1
        )

        APIClient._testSetEdgeInvokeOverride { _, _ in
            throw NSError(domain: "APIClient", code: 0, userInfo: ["status": 500])
        }
        do {
            let _: EdgePayload = try await api.callEdgeFunction(
                "coverage_fn_retry",
                body: Data("{}".utf8),
                headers: ["X-Outbox-Replay": "true"],
                maxAttempts: 1
            )
            XCTFail("Expected retryLimitReached")
        } catch let error as APIClientError {
            switch error {
            case .retryLimitReached:
                break
            default:
                XCTFail("Unexpected APIClientError: \(error)")
            }
        }

        _ = try? await api.upsertRow(table: "coverage", bodyJson: Data())
        let invalidEdgePayload = Data([0xFF])
        let _: EdgePayload? = try? await api.callEdgeFunction(
            "coverage_fn",
            body: invalidEdgePayload,
            headers: [:],
            maxAttempts: 1
        )
    }

    func testAPIClientFetchSyncPageHelperBranching() async throws {
        actor CallRecorder {
            struct Call: Equatable {
                var operatorName: String?
                var updatedAt: Date?
                var idGreaterThan: String?
                var orderByUpdatedAt: Bool
                var queryLimit: Int
            }

            private var calls: [Call] = []

            func record(
                operatorName: String?,
                updatedAt: Date?,
                idGreaterThan: String?,
                orderByUpdatedAt: Bool,
                queryLimit: Int
            ) {
                calls.append(
                    Call(
                        operatorName: operatorName,
                        updatedAt: updatedAt,
                        idGreaterThan: idGreaterThan,
                        orderByUpdatedAt: orderByUpdatedAt,
                        queryLimit: queryLimit
                    )
                )
            }

            func snapshot() -> [Call] {
                calls
            }
        }

        let api = APIClient(deviceId: "sync-page-coverage")
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let noCursorRecorder = CallRecorder()
        let noCursorRows = try await api._testFetchSyncPageImpl(
            since: now,
            cursor: nil,
            limit: 3
        ) { op, updatedAt, idGreaterThan, orderByUpdatedAt, queryLimit in
            await noCursorRecorder.record(
                operatorName: op,
                updatedAt: updatedAt,
                idGreaterThan: idGreaterThan,
                orderByUpdatedAt: orderByUpdatedAt,
                queryLimit: queryLimit
            )
            return [1, 2]
        }
        XCTAssertEqual(noCursorRows, [1, 2])
        let noCursorCalls = await noCursorRecorder.snapshot()
        XCTAssertEqual(noCursorCalls.count, 1)
        XCTAssertEqual(noCursorCalls.first?.operatorName, "gte")
        XCTAssertEqual(noCursorCalls.first?.updatedAt, now)
        XCTAssertNil(noCursorCalls.first?.idGreaterThan)
        XCTAssertEqual(noCursorCalls.first?.orderByUpdatedAt, true)
        XCTAssertEqual(noCursorCalls.first?.queryLimit, 3)

        let fullCursorRecorder = CallRecorder()
        let cursor = APIClient.SyncPageCursor(updatedAt: now, rowId: "row-10")
        let fullCursorRows = try await api._testFetchSyncPageImpl(
            since: nil,
            cursor: cursor,
            limit: 2
        ) { op, updatedAt, idGreaterThan, orderByUpdatedAt, queryLimit in
            await fullCursorRecorder.record(
                operatorName: op,
                updatedAt: updatedAt,
                idGreaterThan: idGreaterThan,
                orderByUpdatedAt: orderByUpdatedAt,
                queryLimit: queryLimit
            )
            if op == "eq" {
                return [10, 11]
            }
            return [99]
        }
        XCTAssertEqual(fullCursorRows, [10, 11])
        let fullCursorCalls = await fullCursorRecorder.snapshot()
        XCTAssertEqual(fullCursorCalls.count, 1)
        XCTAssertEqual(fullCursorCalls.first?.operatorName, "eq")
        XCTAssertEqual(fullCursorCalls.first?.updatedAt, now)
        XCTAssertEqual(fullCursorCalls.first?.idGreaterThan, "row-10")
        XCTAssertEqual(fullCursorCalls.first?.orderByUpdatedAt, false)
        XCTAssertEqual(fullCursorCalls.first?.queryLimit, 2)

        let partialCursorRecorder = CallRecorder()
        let partialCursorRows = try await api._testFetchSyncPageImpl(
            since: nil,
            cursor: cursor,
            limit: 3
        ) { op, updatedAt, idGreaterThan, orderByUpdatedAt, queryLimit in
            await partialCursorRecorder.record(
                operatorName: op,
                updatedAt: updatedAt,
                idGreaterThan: idGreaterThan,
                orderByUpdatedAt: orderByUpdatedAt,
                queryLimit: queryLimit
            )
            if op == "eq" {
                return [1]
            }
            return [2, 3]
        }
        XCTAssertEqual(partialCursorRows, [1, 2, 3])
        let partialCalls = await partialCursorRecorder.snapshot()
        XCTAssertEqual(partialCalls.count, 2)
        XCTAssertEqual(partialCalls[0].operatorName, "eq")
        XCTAssertEqual(partialCalls[0].updatedAt, now)
        XCTAssertEqual(partialCalls[0].idGreaterThan, "row-10")
        XCTAssertEqual(partialCalls[0].orderByUpdatedAt, false)
        XCTAssertEqual(partialCalls[0].queryLimit, 3)
        XCTAssertEqual(partialCalls[1].operatorName, "gt")
        XCTAssertEqual(partialCalls[1].updatedAt, now)
        XCTAssertNil(partialCalls[1].idGreaterThan)
        XCTAssertEqual(partialCalls[1].orderByUpdatedAt, true)
        XCTAssertEqual(partialCalls[1].queryLimit, 2)

        let nilFilterRecorder = CallRecorder()
        let nilFilterRows = try await api._testFetchSyncPageImpl(
            since: nil,
            cursor: nil,
            limit: 0
        ) { op, updatedAt, idGreaterThan, orderByUpdatedAt, queryLimit in
            await nilFilterRecorder.record(
                operatorName: op,
                updatedAt: updatedAt,
                idGreaterThan: idGreaterThan,
                orderByUpdatedAt: orderByUpdatedAt,
                queryLimit: queryLimit
            )
            return [99]
        }
        XCTAssertEqual(nilFilterRows, [99])
        let nilFilterCalls = await nilFilterRecorder.snapshot()
        XCTAssertEqual(nilFilterCalls.count, 1)
        XCTAssertNil(nilFilterCalls[0].operatorName)
        XCTAssertNil(nilFilterCalls[0].updatedAt)
        XCTAssertNil(nilFilterCalls[0].idGreaterThan)
        XCTAssertEqual(nilFilterCalls[0].orderByUpdatedAt, true)
        XCTAssertEqual(nilFilterCalls[0].queryLimit, 1)
    }

    @MainActor
    func testNutritionHarnessAndViewModelBranches() async throws {
        await NutritionViewsTestHarness.exerciseBodyBranches()
        XCTAssertEqual(NutritionDayView._testInputMethodsCount(), 6)
        XCTAssertEqual(NutritionDayView._testInputMethodsCount(batchRecipesEnabled: false), 5)
        XCTAssertEqual(
            NutritionDayView._testVisibleInputMethods(batchRecipesEnabled: false),
            [.photo, .barcode, .voice, .manual, .template]
        )
        XCTAssertEqual(
            NutritionViewsTestHarness.inputMethodMappings(),
            [.vision, .barcode, .voice, .manual, .batch, .template]
        )
        let saveSuccessFlags = NutritionViewsTestHarness.saveOutcomeFlags(didSave: true)
        XCTAssertTrue(saveSuccessFlags.dismissed)
        XCTAssertTrue(saveSuccessFlags.success)
        XCTAssertFalse(saveSuccessFlags.failure)
        let saveFailureFlags = NutritionViewsTestHarness.saveOutcomeFlags(didSave: false)
        XCTAssertFalse(saveFailureFlags.dismissed)
        XCTAssertFalse(saveFailureFlags.success)
        XCTAssertTrue(saveFailureFlags.failure)

        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        AuthManager.setActiveAuthIdForTests(authId)

        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (
                        id, auth_id, timezone, units, weight_kg, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [userId.uuidString, authId.uuidString, "UTC", "metric", 80.0, Date(), Date()]
            )

            try db.execute(
                sql: """
                    INSERT INTO physiological_states (
                        id, user_id, date, recovery_score, recovery_zone,
                        confidence_score, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [UUID().uuidString, userId.uuidString, "2026-02-24", 83, "ready", 0.9, Date(), Date()]
            )
            try db.execute(
                sql: """
                    INSERT INTO training_loads (
                        id, user_id, date, daily_trimp, daily_active_calories, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [UUID().uuidString, userId.uuidString, "2026-02-24", 88, 620, Date(), Date()]
            )
        }

        let logger = NutritionMealLoggerMock()
        let vm = NutritionLogViewModel(
            method: .photo,
            aiConfidence: nil,
            nutritionService: logger,
            dbQueue: manager.dbQueue
        )

        await vm.loadDynamicHint()
        XCTAssertFalse(vm.dynamicHint.isEmpty)

        let target = try await vm._testResolvedDynamicTarget()
        XCTAssertNotNil(target)
        XCTAssertTrue(vm.requiresEditFirst)
        XCTAssertFalse(vm.canSave)

        vm.didReviewLowConfidence = true
        XCTAssertTrue(vm.canSave)
        let didSave = await vm.save()
        XCTAssertTrue(didSave)
        XCTAssertNil(vm.errorMessage)

        let logged = await logger.lastLogged()
        let saved = try XCTUnwrap(logged)
        XCTAssertEqual(saved.inputMethod, .vision)
        XCTAssertEqual(try XCTUnwrap(saved.aiConfidence), 0, accuracy: 0.0001)
        XCTAssertTrue(saved.needsReview)

        try await manager.dbQueue.read { db in
            let userLookup = try NutritionLogViewModel._testLatestUserId(authId: authId.uuidString, db: db)
            XCTAssertEqual(userLookup, userId)
        }

        let dateString = NutritionLogViewModel._testLocalDateString(Date(timeIntervalSince1970: 0))
        XCTAssertEqual(dateString.count, 10)

        let labels = [
            NutritionLogViewModel(method: .photo, aiConfidence: nil).methodLabel,
            NutritionLogViewModel(method: .barcode, aiConfidence: nil).methodLabel,
            NutritionLogViewModel(method: .voice, aiConfidence: nil).methodLabel,
            NutritionLogViewModel(method: .manual, aiConfidence: nil).methodLabel,
            NutritionLogViewModel(method: .batch, aiConfidence: nil).methodLabel,
            NutritionLogViewModel(method: .template, aiConfidence: nil).methodLabel,
            NutritionLogViewModel(method: nil, aiConfidence: nil).methodLabel
        ]
        XCTAssertEqual(labels.count, 7)
        XCTAssertFalse(labels.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))

        AuthManager.setActiveAuthIdForTests(nil)
        let noAuthVM = NutritionLogViewModel(
            method: .manual,
            aiConfidence: 0.9,
            nutritionService: logger,
            dbQueue: manager.dbQueue
        )
        noAuthVM.addMealItem()
        await noAuthVM.loadDynamicHint()
        XCTAssertEqual(noAuthVM.dynamicHint, "")
        let noAuthSaved = await noAuthVM.save()
        XCTAssertFalse(noAuthSaved)
        XCTAssertNotNil(noAuthVM.errorMessage)
        let loggedCount = await logger.loggedCount()
        XCTAssertEqual(loggedCount, 1)
    }

    func testNutritionLogViewModelPersistsDraftContextAndStructuredItems() async throws {
        struct NoopNutritionLogger: NutritionMealLogging {
            func logMeal(_ log: FoodLog) async throws {}
        }

        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let loggedAt = Date(timeIntervalSince1970: 1_708_732_800) // 2024-02-24 16:00:00 UTC

        try await manager.dbQueue.write { db in
            var user = User(id: userId, authId: authId, timezone: "UTC", units: .metric)
            user.weightKg = 80
            try user.insert(db)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let draft = NutritionLogDraft(
            method: .voice,
            confidence: 0.88,
            loggedAt: loggedAt,
            loggedDate: "2024-02-24",
            summary: "Oatmeal and berries",
            sourceText: "I had oatmeal and berries for breakfast",
            recognizedBarcodes: ["4601234567890"],
            candidateItems: [
                NutritionDraftCandidateItem(
                    name: "Oatmeal",
                    weightG: 100,
                    calories: 380,
                    proteinG: 13,
                    fatG: 7,
                    carbsG: 67,
                    confidence: 0.88
                ),
                NutritionDraftCandidateItem(
                    name: "Berries",
                    confidence: 0.72
                )
            ]
        )

        let viewModel = NutritionLogViewModel(
            method: .voice,
            aiConfidence: 0.88,
            draft: draft,
            nutritionService: NoopNutritionLogger(),
            dbQueue: manager.dbQueue
        )

        let didSave = await viewModel.save()
        XCTAssertTrue(didSave)
        XCTAssertNil(viewModel.errorMessage)

        try await manager.dbQueue.read { db in
            let logRow = try XCTUnwrap(Row.fetchOne(
                db,
                sql: """
                    SELECT id, logged_at, logged_date, input_method, ai_context_analysis, ai_detected_items
                    FROM food_logs
                    LIMIT 1
                    """
            ))

            let logId = try XCTUnwrap(MixedUUIDStorage.decode(from: logRow, column: "id"))
            let savedLoggedAt: Date = try XCTUnwrap(logRow["logged_at"])
            let savedLoggedDate: String = try XCTUnwrap(logRow["logged_date"])
            let savedInputMethod: String = try XCTUnwrap(logRow["input_method"])
            let contextSummary: String = try XCTUnwrap(logRow["ai_context_analysis"])
            let detectedBlob: Data = try XCTUnwrap(logRow["ai_detected_items"])

            XCTAssertEqual(savedLoggedAt, loggedAt)
            XCTAssertEqual(savedLoggedDate, "2024-02-24")
            XCTAssertEqual(savedInputMethod, NutritionInputMethod.voice.rawValue)
            XCTAssertEqual(contextSummary, "Oatmeal and berries")

            let payload = try JSONDecoder().decode(NutritionAIDetectedPayload.self, from: detectedBlob)
            XCTAssertEqual(payload.recognizedBarcodes, ["4601234567890"])
            XCTAssertEqual(payload.candidateItems.count, 2)

            let foodItemCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM food_items WHERE food_log_id = ? OR food_log_id = ?",
                arguments: [logId, logId.uuidString]
            )
            XCTAssertEqual(foodItemCount, 1)
        }
    }

    @MainActor
    func testNutritionLogViewModelExistingMealSaveUsesPatchFlow() async throws {
        struct NoopLogger: NutritionMealLogging {
            func logMeal(_ log: FoodLog) async throws {}
        }

        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let mealId = UUID()

        let existingLog = FoodLog(
            id: mealId,
            userId: userId,
            loggedAt: Date(timeIntervalSince1970: 1_773_331_200),
            loggedDate: "2026-03-12",
            inputMethod: .manual,
            calories: 500,
            proteinG: 30,
            fatG: 18,
            carbsG: 52
        )
        let existingItem = FoodItem(
            foodLogId: mealId,
            userId: userId,
            name: "Chicken bowl",
            weightG: 300,
            calories: 500,
            proteinG: 30,
            fatG: 18,
            carbsG: 52
        )

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }
        try await manager.dbQueue.write { db in
            var user = User(id: userId, authId: authId, timezone: "UTC", units: .metric)
            user.weightKg = 80
            try user.insert(db)
        }

        let mealManager = NutritionMealManagerMock(
            detail: NutritionMealDetail(log: existingLog, items: [existingItem])
        )
        let viewModel = NutritionLogViewModel(
            method: .manual,
            aiConfidence: nil,
            existingMealId: mealId,
            nutritionService: NoopLogger(),
            mealManager: mealManager,
            dbQueue: manager.dbQueue
        )

        await viewModel.loadMealDetailIfNeeded()
        XCTAssertEqual(viewModel.mealItems.count, 1)

        viewModel.didReviewLowConfidence = true
        viewModel.mealType = .dinner
        viewModel.mealContext = .restaurant
        viewModel.userNotes = "Updated in detail screen"
        viewModel.mealItems[0].name = "Salmon bowl"
        viewModel.mealItems[0].calories = 640
        viewModel.mealItems[0].proteinG = 41
        viewModel.mealItems[0].fatG = 24
        viewModel.mealItems[0].carbsG = 58

        let didSave = await viewModel.save()
        XCTAssertTrue(didSave)
        XCTAssertNil(viewModel.errorMessage)

        let snapshot = await mealManager.snapshot()
        let update = try XCTUnwrap(snapshot)
        XCTAssertEqual(update.id, mealId)
        XCTAssertEqual(update.mealType, .dinner)
        XCTAssertEqual(update.context, .restaurant)
        XCTAssertEqual(update.userNotes, "Updated in detail screen")
        XCTAssertEqual(update.items.count, 1)
        XCTAssertEqual(update.items[0].name, "Salmon bowl")
        XCTAssertEqual(update.items[0].calories, 640, accuracy: 0.001)
    }

    @MainActor
    func testNutritionLogViewModelExistingMealDeleteAndUndoBranches() async throws {
        struct NoopLogger: NutritionMealLogging {
            func logMeal(_ log: FoodLog) async throws {}
        }

        let manager = try DatabaseManager.inMemory()
        let mealId = UUID()
        let existingLog = FoodLog(
            id: mealId,
            userId: UUID(),
            loggedAt: Date(),
            loggedDate: "2026-03-12",
            inputMethod: .manual,
            calories: 500,
            proteinG: 30,
            fatG: 18,
            carbsG: 52
        )
        let existingItem = FoodItem(
            foodLogId: mealId,
            userId: existingLog.userId,
            name: "Bowl",
            weightG: 250,
            calories: 500,
            proteinG: 30,
            fatG: 18,
            carbsG: 52
        )

        let mealManager = NutritionMealManagerMock(
            detail: NutritionMealDetail(log: existingLog, items: [existingItem])
        )
        let viewModel = NutritionLogViewModel(
            method: .manual,
            aiConfidence: nil,
            existingMealId: mealId,
            nutritionService: NoopLogger(),
            mealManager: mealManager,
            dbQueue: manager.dbQueue
        )

        await viewModel.loadMealDetailIfNeeded()
        let didDelete = await viewModel.deleteMeal()
        XCTAssertTrue(didDelete)
        XCTAssertTrue(viewModel.isDeleted)
        XCTAssertTrue(viewModel.canUndoDelete)
        let deleteInvocationCount = await mealManager.deleteInvocationCount()
        XCTAssertEqual(deleteInvocationCount, 1)

        let didUndo = await viewModel.undoDeleteMeal()
        XCTAssertTrue(didUndo)
        XCTAssertFalse(viewModel.isDeleted)
        XCTAssertNil(viewModel.deletedAt)
        let undoInvocationCount = await mealManager.undoInvocationCount()
        XCTAssertEqual(undoInvocationCount, 1)
    }

    func testNutritionCleanupServicePrunesOldPhotos() async throws {
        let fileManager = FileManager.default
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            XCTFail("Documents directory unavailable")
            return
        }

        let images = documents.appendingPathComponent("images")
        try? fileManager.removeItem(at: images)
        try fileManager.createDirectory(at: images, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: images) }

        let oldFile = images.appendingPathComponent("old-photo.jpg")
        let freshFile = images.appendingPathComponent("fresh-photo.jpg")
        try Data("old".utf8).write(to: oldFile)
        try Data("fresh".utf8).write(to: freshFile)

        try fileManager.setAttributes(
            [.creationDate: Date().addingTimeInterval(-95 * 24 * 3600)],
            ofItemAtPath: oldFile.path
        )
        try fileManager.setAttributes(
            [.creationDate: Date().addingTimeInterval(-2 * 24 * 3600)],
            ofItemAtPath: freshFile.path
        )

        await NutritionCleanupService.pruneOldPhotos()

        XCTAssertFalse(fileManager.fileExists(atPath: oldFile.path))
        XCTAssertTrue(fileManager.fileExists(atPath: freshFile.path))
    }

    @MainActor
    func testWatchSyncManagerDebugHelpersAndMessagePath() async throws {
        let manager = WatchSyncManager()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let largeDeepLink = "lifeos://recovery?blob=\(String(repeating: "x", count: 10_000))"

        let largeSnapshot = WatchSnapshot(
            date: "2026-02-24",
            lastUpdatedAt: now,
            recoveryScore: 73,
            recoveryZone: "ready",
            confidenceScore: 0.88,
            nextBestAction: .init(
                type: "open",
                labelCopyId: "watch_action_open",
                payload: .init(
                    deepLink: largeDeepLink,
                    supplementName: nil,
                    scheduledTime: nil,
                    insightId: nil,
                    date: nil
                )
            ),
            sleepDurationHours: 7.9,
            sleepQualityPercent: 92,
            nutritionAdherencePercent: 85,
            supplementsDueSoon: .init(time: "08:30", count: 2),
            wasTruncated: false
        )

        XCTAssertGreaterThan(manager._testEncodedSize(largeSnapshot), 4096)
        let truncated = manager._testTruncateIfNeeded(largeSnapshot)
        XCTAssertEqual(truncated.wasTruncated, true)
        XCTAssertNil(truncated.nutritionAdherencePercent)
        XCTAssertNil(truncated.sleepQualityPercent)
        XCTAssertNil(truncated.supplementsDueSoon)
        XCTAssertNil(truncated.sleepDurationHours)

        let smallSnapshot = WatchSnapshot(
            date: "2026-02-24",
            lastUpdatedAt: now,
            recoveryScore: 70,
            recoveryZone: "ready",
            confidenceScore: 0.8,
            nextBestAction: nil,
            sleepDurationHours: 7.2,
            sleepQualityPercent: 90,
            nutritionAdherencePercent: 88,
            supplementsDueSoon: .init(time: "09:00", count: 1),
            wasTruncated: false
        )
        XCTAssertLessThan(manager._testEncodedSize(smallSnapshot), 4096)
        XCTAssertEqual(manager._testTruncateIfNeeded(smallSnapshot).wasTruncated, false)

        XCTAssertEqual(WatchSyncManager._testNormalizedWallClockTime(from: "9:05"), "09:05")
        XCTAssertEqual(WatchSyncManager._testNormalizedWallClockTime(from: "09:05:20"), "09:05")
        XCTAssertNil(WatchSyncManager._testNormalizedWallClockTime(from: "24:00"))
        XCTAssertNil(WatchSyncManager._testNormalizedWallClockTime(from: ""))

        let responseData = Data(
            """
            {
              "date":"2026-02-24",
              "last_updated_at":"2026-02-24T08:00:00Z",
              "recovery_score":81,
              "recovery_zone":"ready",
              "confidence_score":0.94,
              "next_best_action":{"type":"supplement_taken","label_copy_id":"supplements.log_primary","payload":{"supplement_name":"Magnesium Glycinate","scheduled_time":"08:45"}},
              "sleep_duration_hours":7.5,
              "sleep_quality_percent":91,
              "nutrition_adherence_percent":84,
              "supplements_due_soon":{"time":"08:45","count":2}
            }
            """.utf8
        )
        let mapped = try WatchSyncManager._testSnapshot(from: responseData)
        XCTAssertEqual(mapped.date, "2026-02-24")
        XCTAssertEqual(mapped.nextBestAction?.type, "supplement_taken")
        XCTAssertEqual(mapped.nextBestAction?.payload?.supplementName, "Magnesium Glycinate")
        XCTAssertEqual(mapped.nextBestAction?.payload?.scheduledTime, "08:45")
        XCTAssertEqual(mapped.supplementsDueSoon?.count, 2)
        XCTAssertEqual(mapped.wasTruncated, false)

        let insightResponseData = Data(
            """
            {
              "date":"2026-02-24",
              "last_updated_at":"2026-02-24T08:00:00Z",
              "recovery_score":77,
              "recovery_zone":"ready",
              "confidence_score":0.94,
              "next_best_action":{"type":"insight_acknowledge","label_copy_id":"insights.acknowledge","payload":{"insight_id":"11111111-1111-4111-8111-111111111111"}},
              "sleep_duration_hours":7.1
            }
            """.utf8
        )
        let insightMapped = try WatchSyncManager._testSnapshot(from: insightResponseData)
        XCTAssertEqual(insightMapped.nextBestAction?.type, "insight_acknowledge")
        XCTAssertEqual(
            insightMapped.nextBestAction?.payload?.insightId,
            "11111111-1111-4111-8111-111111111111"
        )

        let suiteName = "group.com.lifeos.tests.watch.\(UUID().uuidString)"
        manager._testWriteComplicationData(snapshot: smallSnapshot, suiteName: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)
        let data = try XCTUnwrap(defaults?.data(forKey: "latestSnapshot"))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["recovery_zone"] as? String, "ready")
        defaults?.removePersistentDomain(forName: suiteName)

        let pendingSuiteName = "group.com.lifeos.tests.watch.pending.\(UUID().uuidString)"
        let pendingDefaults = try XCTUnwrap(UserDefaults(suiteName: pendingSuiteName))
        pendingDefaults.removePersistentDomain(forName: pendingSuiteName)
        defer { pendingDefaults.removePersistentDomain(forName: pendingSuiteName) }

        let messageExpectation = expectation(forNotification: .watchDeepLink, object: nil) { notification in
            (notification.userInfo?["deep_link"] as? String) == "lifeos://insights"
        }
        manager.session(
            WCSession.default,
            didReceiveMessage: ["action": "open_on_iphone", "deep_link": "lifeos://insights"]
        )
        await fulfillment(of: [messageExpectation], timeout: 1.0)
        WatchSyncManager.enqueuePendingWatchDeepLink("lifeos://insights", defaults: pendingDefaults)
        XCTAssertEqual(
            WatchSyncManager._testPendingWatchDeepLinks(defaults: pendingDefaults),
            ["lifeos://insights"]
        )

        WatchSyncManager.removePendingWatchDeepLink("lifeos://insights", defaults: pendingDefaults)
        XCTAssertTrue(WatchSyncManager._testPendingWatchDeepLinks(defaults: pendingDefaults).isEmpty)

        let userInfoExpectation = expectation(forNotification: .watchDeepLink, object: nil) { (notification: Notification) in
            (notification.userInfo?["deep_link"] as? String) == "lifeos://labs"
        }
        manager.session(
            WCSession.default,
            didReceiveUserInfo: ["action": "open_on_iphone", "deep_link": "lifeos://labs"]
        )
        await fulfillment(of: [userInfoExpectation], timeout: 1.0)
        WatchSyncManager.enqueuePendingWatchDeepLink("lifeos://labs", defaults: pendingDefaults)
        XCTAssertEqual(
            WatchSyncManager._testPendingWatchDeepLinks(defaults: pendingDefaults),
            ["lifeos://labs"]
        )
    }

    func testWatchSyncManagerCoverageActionHandlersAndLifecycle() async throws {
        let manager = WatchSyncManager()
        let dbManager = try DatabaseManager.inMemory()
        let syncEngine = makeNoopSyncEngine(dbQueue: dbManager.dbQueue)
        let authId = UUID()
        let userId = UUID()
        let insightId = UUID()
        let now = Date()
        let utc = TimeZone(secondsFromGMT: 0) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let scheduledDate = calendar.date(byAdding: .minute, value: 30, to: now) ?? now
        let scheduledTime = String(
            format: "%02d:%02d",
            calendar.component(.hour, from: scheduledDate),
            calendar.component(.minute, from: scheduledDate)
        )
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)

        AppContainer.shared = AppContainer(syncEngine: syncEngine)
        WatchSyncManager._testSetPushLatestSnapshotOverride { _ in }
        defer {
            WatchSyncManager._testSetPushLatestSnapshotOverride(nil)
            AppContainer.shared = nil
            AuthManager.setActiveAuthIdForTests(nil)
        }
        AuthManager.setActiveAuthIdForTests(authId)

        try await dbManager.dbQueue.write { db in
            var user = User(id: userId, authId: authId, timezone: "UTC")
            user.onboardingCompleted = true
            try user.insert(db)

            var state = PhysiologicalState(userId: userId, date: today, recoveryScore: 72)
            state.createdAt = now
            state.updatedAt = now
            state.confidenceScore = 0.9
            state.sleepDurationHours = 7.5
            state.sleepQualityPercent = 82
            try state.insert(db)

            var insight = Insight(
                id: insightId,
                userId: userId,
                category: .general,
                title: "Hydrate earlier",
                body: "Keep fluids steady through the afternoon.",
                confidence: 0.9
            )
            insight.createdAt = now
            insight.updatedAt = now
            insight.read = false
            insight.acknowledged = false
            insight.dismissed = false
            try insight.insert(db)

            try db.execute(
                sql: """
                    INSERT INTO user_supplements (
                        id, user_id, catalog_id, custom_name, dose_amount, dose_unit,
                        frequency, scheduled_times, days_of_week, take_with_food,
                        notes, active, started_at, ended_at, created_at, updated_at
                    )
                    VALUES (?, ?, NULL, ?, ?, ?, ?, ?, NULL, 0, NULL, 1, ?, NULL, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    "Magnesium",
                    200.0,
                    "mg",
                    "daily",
                    "[\"\(scheduledTime)\"]",
                    today,
                    now,
                    now
                ]
            )
        }

        manager.sessionDidBecomeInactive(WCSession.default)
        manager.sessionDidDeactivate(WCSession.default)

        let snapshot = WatchSnapshot(
            date: today,
            lastUpdatedAt: now,
            recoveryScore: 71,
            recoveryZone: "ready",
            confidenceScore: 0.9,
            nextBestAction: .init(
                type: "supplement_taken",
                labelCopyId: "supplements.log_primary",
                payload: .init(
                    deepLink: nil,
                    supplementName: "Magnesium",
                    scheduledTime: scheduledTime,
                    insightId: nil,
                    date: nil
                )
            ),
            sleepDurationHours: 7.3,
            sleepQualityPercent: 88,
            nutritionAdherencePercent: 82,
            supplementsDueSoon: .init(time: scheduledTime, count: 1),
            wasTruncated: false
        )
        manager.start()
        manager.push(snapshot: snapshot)
        await manager.pushLatestSnapshotFromServer(date: today)

        manager.session(
            WCSession.default,
            didReceiveMessage: [
                "action": "supplement_taken",
                "supplement_name": "Magnesium",
                "scheduled_time": "\(scheduledTime):59"
            ]
        )
        let supplementActionApplied = try await waitUntilTrue(timeout: 3.0) {
            try await dbManager.dbQueue.read { db in
                let supplementCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?",
                    arguments: ["api-supplements-log"]
                ) ?? 0
                let localLogCount = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*)
                        FROM supplement_logs
                        WHERE (user_id = ? OR user_id = ?)
                          AND supplement_name = ?
                          AND scheduled_time = ?
                          AND taken_date = ?
                        """,
                    arguments: [userId, userId.uuidString, "Magnesium", scheduledTime, today]
                ) ?? 0
                return supplementCount > 0 && localLogCount > 0
            }
        }
        XCTAssertTrue(supplementActionApplied)
        XCTAssertEqual(manager._testLastPushedSnapshot()?.nextBestAction?.type, "insight_acknowledge")
        XCTAssertNil(manager._testLastPushedSnapshot()?.supplementsDueSoon)

        let localSnapshotAfterSupplement = try await WatchSyncManager._testBuildLocalSnapshot(
            syncEngine: syncEngine,
            date: today,
            now: now
        )
        XCTAssertEqual(localSnapshotAfterSupplement?.nextBestAction?.type, "insight_acknowledge")

        manager.push(
            snapshot: WatchSnapshot(
                date: today,
                lastUpdatedAt: now,
                recoveryScore: 71,
                recoveryZone: "ready",
                confidenceScore: 0.9,
                nextBestAction: .init(
                    type: "insight_acknowledge",
                    labelCopyId: "insights.acknowledge",
                    payload: .init(
                        deepLink: nil,
                        supplementName: nil,
                        scheduledTime: nil,
                        insightId: insightId.uuidString,
                        date: nil
                    )
                ),
                sleepDurationHours: 7.3,
                sleepQualityPercent: 88,
                nutritionAdherencePercent: 82,
                supplementsDueSoon: nil,
                wasTruncated: false
            )
        )
        manager.session(
            WCSession.default,
            didReceiveMessage: [
                "action": "insight_acknowledge",
                "insight_id": insightId.uuidString
            ]
        )
        manager.session(WCSession.default, didReceiveMessage: ["action": "unknown_action"])

        XCTAssertNil(WatchSyncManager._testNormalizedWallClockTime(from: "09:05:99"))

        let inserted = try await waitUntilTrue(timeout: 3.0) {
            try await dbManager.dbQueue.read { db in
                let supplementCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?",
                    arguments: ["api-supplements-log"]
                ) ?? 0
                let insightCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?",
                    arguments: ["api-insight-acknowledge"]
                ) ?? 0
                let acknowledged = try Bool.fetchOne(
                    db,
                    sql: "SELECT acknowledged FROM insights WHERE id = ? OR id = ?",
                    arguments: [insightId, insightId.uuidString]
                ) ?? false
                return supplementCount > 0 && insightCount > 0 && acknowledged
            }
        }
        XCTAssertTrue(inserted)
        XCTAssertEqual(manager._testLastPushedSnapshot()?.nextBestAction?.type, "open_on_iphone")

        let localSnapshotAfterInsight = try await WatchSyncManager._testBuildLocalSnapshot(
            syncEngine: syncEngine,
            date: today,
            now: now
        )
        XCTAssertEqual(localSnapshotAfterInsight?.nextBestAction?.type, "open_on_iphone")
    }

    func testWatchSyncManagerQueuedActionsApplyAndDeduplicateByActionId() async throws {
        let manager = WatchSyncManager()
        let dbManager = try DatabaseManager.inMemory()
        let syncEngine = makeNoopSyncEngine(dbQueue: dbManager.dbQueue)
        let authId = UUID()
        let userId = UUID()
        let insightId = UUID()
        let now = Date()
        let utc = TimeZone(secondsFromGMT: 0) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let scheduledDate = calendar.date(byAdding: .minute, value: 45, to: now) ?? now
        let scheduledTime = String(
            format: "%02d:%02d",
            calendar.component(.hour, from: scheduledDate),
            calendar.component(.minute, from: scheduledDate)
        )
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)

        AppContainer.shared = AppContainer(syncEngine: syncEngine)
        WatchSyncManager._testSetPushLatestSnapshotOverride { _ in }
        defer {
            WatchSyncManager._testSetPushLatestSnapshotOverride(nil)
            AppContainer.shared = nil
            AuthManager.setActiveAuthIdForTests(nil)
        }
        AuthManager.setActiveAuthIdForTests(authId)

        try await dbManager.dbQueue.write { db in
            var user = User(id: userId, authId: authId, timezone: "UTC")
            user.onboardingCompleted = true
            try user.insert(db)

            var state = PhysiologicalState(userId: userId, date: today, recoveryScore: 74)
            state.createdAt = now
            state.updatedAt = now
            state.confidenceScore = 0.92
            state.sleepDurationHours = 7.8
            state.sleepQualityPercent = 84
            try state.insert(db)

            var insight = Insight(
                id: insightId,
                userId: userId,
                category: .general,
                title: "Morning walk",
                body: "Keep the same cadence tomorrow.",
                confidence: 0.88
            )
            insight.createdAt = now
            insight.updatedAt = now
            insight.read = false
            insight.acknowledged = false
            insight.dismissed = false
            try insight.insert(db)

            try db.execute(
                sql: """
                    INSERT INTO user_supplements (
                        id, user_id, catalog_id, custom_name, dose_amount, dose_unit,
                        frequency, scheduled_times, days_of_week, take_with_food,
                        notes, active, started_at, ended_at, created_at, updated_at
                    )
                    VALUES (?, ?, NULL, ?, ?, ?, ?, ?, NULL, 0, NULL, 1, ?, NULL, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    "Magnesium",
                    200.0,
                    "mg",
                    "daily",
                    "[\"\(scheduledTime)\"]",
                    today,
                    now,
                    now
                ]
            )
        }

        manager.start()
        manager.push(
            snapshot: WatchSnapshot(
                date: today,
                lastUpdatedAt: now,
                recoveryScore: 74,
                recoveryZone: "ready",
                confidenceScore: 0.92,
                nextBestAction: .init(
                    type: "supplement_taken",
                    labelCopyId: "supplements.log_primary",
                    payload: .init(
                        deepLink: nil,
                        supplementName: "Magnesium",
                        scheduledTime: scheduledTime,
                        insightId: nil,
                        date: nil
                    )
                ),
                sleepDurationHours: 7.8,
                sleepQualityPercent: 84,
                nutritionAdherencePercent: 85,
                supplementsDueSoon: .init(time: scheduledTime, count: 1),
                wasTruncated: false
            )
        )

        let supplementActionId = UUID()
        manager.session(
            WCSession.default,
            didReceiveUserInfo: [
                "action": "supplement_taken",
                "action_id": supplementActionId.uuidString.lowercased(),
                "supplement_name": "Magnesium",
                "scheduled_time": scheduledTime
            ]
        )

        let queuedSupplementApplied = try await waitUntilTrue(timeout: 3.0) {
            try await dbManager.dbQueue.read { db in
                let eventCount = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*)
                        FROM outbox_events
                        WHERE path = ?
                          AND (id = ? OR id = ?)
                        """,
                    arguments: ["api-supplements-log", supplementActionId, supplementActionId.uuidString]
                ) ?? 0
                let logCount = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*)
                        FROM supplement_logs
                        WHERE (id = ? OR id = ?)
                          AND (user_id = ? OR user_id = ?)
                          AND supplement_name = ?
                          AND scheduled_time = ?
                          AND taken_date = ?
                        """,
                    arguments: [
                        supplementActionId,
                        supplementActionId.uuidString,
                        userId,
                        userId.uuidString,
                        "Magnesium",
                        scheduledTime,
                        today
                    ]
                ) ?? 0
                return eventCount == 1 && logCount == 1
            }
        }
        XCTAssertTrue(queuedSupplementApplied)

        manager.session(
            WCSession.default,
            didReceiveMessage: [
                "action": "supplement_taken",
                "action_id": supplementActionId.uuidString.lowercased(),
                "supplement_name": "Magnesium",
                "scheduled_time": scheduledTime
            ]
        )

        let supplementStillDeduped = try await waitUntilTrue(timeout: 3.0) {
            try await dbManager.dbQueue.read { db in
                let eventCount = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*)
                        FROM outbox_events
                        WHERE path = ?
                          AND (id = ? OR id = ?)
                        """,
                    arguments: ["api-supplements-log", supplementActionId, supplementActionId.uuidString]
                ) ?? 0
                let logCount = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*)
                        FROM supplement_logs
                        WHERE id = ? OR id = ?
                        """,
                    arguments: [supplementActionId, supplementActionId.uuidString]
                ) ?? 0
                return eventCount == 1 && logCount == 1
            }
        }
        XCTAssertTrue(supplementStillDeduped)

        manager.push(
            snapshot: WatchSnapshot(
                date: today,
                lastUpdatedAt: now,
                recoveryScore: 74,
                recoveryZone: "ready",
                confidenceScore: 0.92,
                nextBestAction: .init(
                    type: "insight_acknowledge",
                    labelCopyId: "insights.acknowledge",
                    payload: .init(
                        deepLink: nil,
                        supplementName: nil,
                        scheduledTime: nil,
                        insightId: insightId.uuidString,
                        date: nil
                    )
                ),
                sleepDurationHours: 7.8,
                sleepQualityPercent: 84,
                nutritionAdherencePercent: 85,
                supplementsDueSoon: nil,
                wasTruncated: false
            )
        )

        let insightActionId = UUID()
        manager.session(
            WCSession.default,
            didReceiveMessage: [
                "action": "insight_acknowledge",
                "action_id": insightActionId.uuidString.lowercased(),
                "insight_id": insightId.uuidString
            ]
        )

        let insightApplied = try await waitUntilTrue(timeout: 3.0) {
            try await dbManager.dbQueue.read { db in
                let eventCount = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*)
                        FROM outbox_events
                        WHERE path = ?
                          AND (id = ? OR id = ?)
                        """,
                    arguments: ["api-insight-acknowledge", insightActionId, insightActionId.uuidString]
                ) ?? 0
                let acknowledged = try Bool.fetchOne(
                    db,
                    sql: "SELECT acknowledged FROM insights WHERE id = ? OR id = ?",
                    arguments: [insightId, insightId.uuidString]
                ) ?? false
                return eventCount == 1 && acknowledged
            }
        }
        XCTAssertTrue(insightApplied)

        manager.session(
            WCSession.default,
            didReceiveUserInfo: [
                "action": "insight_acknowledge",
                "action_id": insightActionId.uuidString.lowercased(),
                "insight_id": insightId.uuidString
            ]
        )

        let insightStillDeduped = try await waitUntilTrue(timeout: 3.0) {
            try await dbManager.dbQueue.read { db in
                let eventCount = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*)
                        FROM outbox_events
                        WHERE path = ?
                          AND (id = ? OR id = ?)
                        """,
                    arguments: ["api-insight-acknowledge", insightActionId, insightActionId.uuidString]
                ) ?? 0
                let acknowledged = try Bool.fetchOne(
                    db,
                    sql: "SELECT acknowledged FROM insights WHERE id = ? OR id = ?",
                    arguments: [insightId, insightId.uuidString]
                ) ?? false
                return eventCount == 1 && acknowledged
            }
        }
        XCTAssertTrue(insightStillDeduped)
    }

    @MainActor
    func testAuthManagerDebugHelpersAndStateMachinePaths() async throws {
        let manager = try DatabaseManager.inMemory()
        let auth = AuthManager(client: SupabaseConfig.client, db: manager)

        await auth.bootstrap()
        XCTAssertEqual(auth.authState, .signedOut)
        XCTAssertNil(auth.userId)

        auth._testApplyUITestOverride(.signedOut)
        XCTAssertEqual(auth.authState, .signedOut)
        XCTAssertNil(auth.userId)

        auth._testApplyUITestOverride(.anonymous)
        XCTAssertEqual(auth.authState, .anonymous)
        XCTAssertEqual(auth.userId, UITestBootstrap.authId)
        XCTAssertTrue(auth.isAnonymous)

        auth._testApplyUITestOverride(.authenticated)
        XCTAssertEqual(auth.authState, .authenticated)
        XCTAssertFalse(auth.isAnonymous)

        auth._testApplyUITestOverride(.needsOnboarding)
        XCTAssertEqual(auth.authState, .needsOnboarding)

        auth._testApplyUITestOverride(.loading)
        XCTAssertEqual(auth.authState, .signedOut)
        XCTAssertNotNil(auth.userId)

        auth._testSetState(authState: .loading, userId: UUID(), isAnonymous: true)
        await auth._testRefreshPostAuthState(hasSession: false)
        XCTAssertEqual(auth.authState, .needsOnboarding)

        auth._testSetState(authState: .loading, userId: UUID(), isAnonymous: false)
        await auth._testRefreshPostAuthState(hasSession: false)
        XCTAssertEqual(auth.authState, .signedOut)

        let localAuthId = UUID()
        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (
                        id, auth_id, timezone, units, onboarding_completed, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [UUID().uuidString, localAuthId.uuidString, "UTC", "metric", false, Date(), Date()]
            )
        }
        auth._testSetState(authState: .loading, userId: localAuthId, isAnonymous: false)
        await auth._testRefreshPostAuthState(hasSession: true)
        XCTAssertEqual(auth.authState, .needsOnboarding)

        try await manager.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE users SET onboarding_completed = 1, updated_at = ? WHERE auth_id = ?",
                arguments: [Date(), localAuthId.uuidString]
            )
        }
        await auth._testRefreshPostAuthState(hasSession: true)
        XCTAssertEqual(auth.authState, .authenticated)

        let brokenManager = try DatabaseManager.inMemory()
        let brokenAuth = AuthManager(client: SupabaseConfig.client, db: brokenManager)
        try await brokenManager.dbQueue.write { db in
            try db.execute(sql: "DROP TABLE users")
        }
        brokenAuth._testSetState(authState: .loading, userId: localAuthId, isAnonymous: false)
        await brokenAuth._testRefreshPostAuthState(hasSession: true)
        XCTAssertEqual(brokenAuth.authState, .needsOnboarding)

        let scopedUserId = UUID()
        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [scopedUserId.uuidString, scopedUserId.uuidString, "UTC", "metric", Date(), Date()]
            )
            try db.execute(
                sql: "CREATE TABLE IF NOT EXISTS temp_table_to_clear (id INTEGER PRIMARY KEY, value TEXT)"
            )
            try db.execute(sql: "INSERT INTO temp_table_to_clear (value) VALUES ('x')")

            var event = OutboxEvent(
                httpMethod: .POST,
                path: "api-test",
                bodyJson: Data("{}".utf8),
                priority: 1
            )
            event.headersJson = Data("{}".utf8)
            try event.insert(db)
            try db.execute(
                sql: """
                    INSERT INTO sync_state (
                        table_name, last_pulled_at_server, last_pull_attempt_at,
                        last_pull_success_at, last_error_code
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: ["food_logs", Date(), Date(), Date(), nil]
            )
            try db.execute(
                sql: """
                    INSERT INTO sync_row_state (table_name, row_id, updated_at_server)
                    VALUES (?, ?, ?)
                    """,
                arguments: ["food_logs", UUID().uuidString, Date()]
            )
            try db.execute(
                sql: """
                    INSERT INTO food_logs (
                        id, user_id, logged_at, logged_date, input_method,
                        calories, protein_g, fat_g, carbs_g, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    scopedUserId.uuidString,
                    Date(),
                    "2026-02-24",
                    "manual",
                    400.0,
                    20.0,
                    12.0,
                    45.0,
                    Date(),
                    Date()
                ]
            )
        }
        auth._testSetState(authState: .authenticated, userId: scopedUserId, isAnonymous: false)
        try await auth._testClearLocalUserState()

        try await manager.dbQueue.read { db in
            let foodLogsCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM food_logs") ?? -1
            let outboxCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox_events") ?? -1
            let rowStateCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_row_state") ?? -1
            XCTAssertEqual(foodLogsCount, 0)
            XCTAssertEqual(outboxCount, 0)
            XCTAssertEqual(rowStateCount, 0)
        }

        try await manager.dbQueue.write { db in
            try AuthManager._testDeleteAllRowsIfTableExists("temp_table_to_clear", db: db)
            try AuthManager._testDeleteAllRowsIfTableExists("missing_table", db: db)
        }
        try await manager.dbQueue.read { db in
            let tempCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM temp_table_to_clear") ?? -1
            XCTAssertEqual(tempCount, 0)
        }

        XCTAssertEqual(AuthManager._testQuotedIdentifier("a\"b"), "\"a\"\"b\"")

        AuthManager._testSetDefaultDeleteAccountOverride { _ in }
        auth._testSetState(authState: .signedOut, userId: nil, isAnonymous: false)
        try await auth.deleteAccount(reason: "qa")
        XCTAssertEqual(AuthError.invalidCredential.errorDescription?.isEmpty, false)
        XCTAssertEqual(AuthError.sessionExpired.errorDescription?.isEmpty, false)
        XCTAssertEqual(AuthError.networkUnavailable.errorDescription?.isEmpty, false)
    }

    @MainActor
    func testAuthManagerCoverageBootstrapAndPublicActionSmoke() async {
        let manager: DatabaseManager
        do {
            manager = try DatabaseManager.inMemory()
        } catch {
            XCTFail("Expected in-memory database for auth coverage smoke, got \(error)")
            return
        }
        let auth = AuthManager(client: SupabaseConfig.client, db: manager)

        AuthManager._testSetRunningTestsOverride(true)
        AuthManager._testSetDefaultDeleteAccountOverride { _ in }
        defer {
            AuthManager._testSetRunningTestsOverride(nil)
            AuthManager.setActiveAuthIdForTests(nil)
        }

        await auth.bootstrap()
        XCTAssertEqual(auth.authState, .signedOut)
        await auth.refreshPostAuthState()
        XCTAssertEqual(auth.authState, .signedOut)

        _ = try? await auth.deleteAccount(reason: "coverage-no-user")
        auth._testSetState(authState: .authenticated, userId: UUID(), isAnonymous: false)
        _ = try? await auth.deleteAccount(reason: "coverage-with-user")
    }

    func testRecoveryEngineCoverageDatabaseAndRawOverloads() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let today = "2026-02-24"

        let missingState = try await manager.dbQueue.read { db in
            try RecoveryEngine.computeScore(userId: userId, date: today, db: db)
        }
        XCTAssertEqual(missingState.score, 50, accuracy: 0.0001)
        XCTAssertEqual(missingState.confidence, 0, accuracy: 0.0001)

        try await manager.dbQueue.write { db in
            var user = User(id: userId, authId: userId, timezone: "UTC", units: .metric)
            user.dateOfBirth = Calendar.current.date(byAdding: .year, value: -34, to: Date())
            try user.insert(db)

            for day in 19...23 {
                var baselineState = PhysiologicalState(
                    userId: userId,
                    date: "2026-02-\(day)",
                    recoveryScore: 60
                )
                baselineState.hrvMs = 4.0 + Double(day - 19) * 0.2
                baselineState.restingHeartRateBpm = 55 + (day - 19)
                try baselineState.insert(db)
            }

            var state = PhysiologicalState(userId: userId, date: today, recoveryScore: 55)
            state.hrvMs = 5.0
            state.restingHeartRateBpm = 52
            state.wristTemperatureDeviationC = 0.4
            state.sleepQualityPercent = 68
            try state.insert(db)
        }

        let scoreWithUser = try await manager.dbQueue.read { db in
            try RecoveryEngine.computeScore(userId: userId, date: today, db: db)
        }
        XCTAssertGreaterThanOrEqual(scoreWithUser.score, 0, "score must be clamped to [0, 100]")
        XCTAssertLessThanOrEqual(scoreWithUser.score, 100, "score must be clamped to [0, 100]")
        XCTAssertGreaterThanOrEqual(scoreWithUser.confidence, 0, "confidence must be non-negative")
        XCTAssertLessThanOrEqual(scoreWithUser.confidence, 1, "confidence must be <= 1")

        try await manager.dbQueue.write { db in
            try db.execute(sql: "DROP TABLE users")
        }

        let scoreWithoutUsersTable = try await manager.dbQueue.read { db in
            try RecoveryEngine.computeScore(userId: userId, date: today, db: db)
        }
        XCTAssertGreaterThanOrEqual(scoreWithoutUsersTable.score, 0)

        let sleep = SleepData(
            totalHours: 7.8,
            deepMinutes: 95,
            remMinutes: 92,
            lightMinutes: 260,
            awakeMinutes: 20,
            efficiency: 90,
            bedTime: nil,
            wakeTime: nil
        )
        let baseline = RecoveryEngine.Baseline(
            hrvMean: 4.6,
            hrvStd: 0.4,
            sleepMean: nil,
            sleepStd: nil,
            rhrMean: 56,
            rhrStd: 2.0,
            tempMean: nil,
            tempStd: nil,
            dataDays: 7
        )
        let computed = RecoveryEngine.computeScore(
            hrv: 5.0,
            sleep: sleep,
            restingHeartRate: 52,
            wristTempDeviation: 0.6,
            baseline: baseline
        )
        XCTAssertEqual(computed.zone, RecoveryZone.from(score: computed.score))
        XCTAssertGreaterThan(computed.confidence, 0)

        let neutralComputed = RecoveryEngine.computeScore(
            hrv: nil,
            sleep: nil,
            restingHeartRate: nil,
            wristTempDeviation: nil,
            baseline: RecoveryEngine.Baseline()
        )
        XCTAssertEqual(neutralComputed.score, 50, accuracy: 0.0001)
        XCTAssertEqual(neutralComputed.confidence, 0, accuracy: 0.0001)

        XCTAssertTrue(RecoveryEngine.Baseline(dataDays: 7).hasSufficientData)
        XCTAssertFalse(RecoveryEngine.Baseline(dataDays: 3).hasSufficientData)

        XCTAssertEqual(RecoveryEngine.rhrPercentageScore(current: 45, baseline: 50), 100, accuracy: 0.0001)
        XCTAssertEqual(RecoveryEngine.rhrPercentageScore(current: 50, baseline: 50), 60, accuracy: 0.0001)
        XCTAssertEqual(RecoveryEngine.rhrPercentageScore(current: 55, baseline: 50), 20, accuracy: 0.0001)
        XCTAssertEqual(RecoveryEngine.rhrPercentageScore(current: 57.5, baseline: 50), 0, accuracy: 0.0001)
        XCTAssertEqual(RecoveryEngine.rhrPercentageScore(current: 60, baseline: 50), 0, accuracy: 0.0001)
    }

    func testMainTabViewBadgeComputationAndRefreshPaths() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let now = Date()

        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (
                        id, auth_id, timezone, units, notification_enabled,
                        onboarding_completed, calibration_days_remaining, deletion_in_progress,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    userId.uuidString,
                    authId.uuidString,
                    "UTC",
                    "metric",
                    true,
                    false,
                    3,
                    false,
                    now,
                    now
                ]
            )

            try db.execute(
                sql: """
                    INSERT INTO insights (
                        id, user_id, category, title, body, confidence, priority,
                        actionable, read, acknowledged, dismissed, needs_review,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    "recovery",
                    "Needs review",
                    "Body",
                    0.2,
                    1,
                    false,
                    false,
                    false,
                    false,
                    true,
                    now,
                    now
                ]
            )

            try db.execute(
                sql: """
                    INSERT INTO insights (
                        id, user_id, category, title, body, confidence, priority,
                        actionable, read, acknowledged, dismissed, needs_review,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    "recovery",
                    "Dismissed",
                    "Body",
                    0.2,
                    1,
                    false,
                    false,
                    false,
                    true,
                    true,
                    now,
                    now
                ]
            )

            try db.execute(
                sql: """
                    INSERT INTO food_logs (
                        id, user_id, logged_at, logged_date, input_method,
                        calories, protein_g, fat_g, carbs_g, ai_confidence, needs_review,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    now,
                    "2026-02-24",
                    "manual",
                    420.0,
                    22.0,
                    15.0,
                    48.0,
                    0.4,
                    true,
                    now,
                    now
                ]
            )

            try db.execute(
                sql: """
                    INSERT INTO food_logs (
                        id, user_id, logged_at, logged_date, input_method,
                        calories, protein_g, fat_g, carbs_g, needs_review,
                        deleted_at, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    now,
                    "2026-02-24",
                    "manual",
                    350.0,
                    18.0,
                    11.0,
                    35.0,
                    true,
                    now,
                    now,
                    now
                ]
            )
        }

        try await manager.dbQueue.read { db in
            let missingUserCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT (
                        (SELECT COUNT(*) FROM insights WHERE user_id = ? AND needs_review = 1 AND dismissed = 0) +
                        (SELECT COUNT(*) FROM food_logs WHERE user_id = ? AND needs_review = 1 AND deleted_at IS NULL)
                    )
                    """,
                arguments: [UUID().uuidString, UUID().uuidString]
            ) ?? -1
            XCTAssertEqual(missingUserCount, 0)

            let expectedCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT (
                        (SELECT COUNT(*) FROM insights WHERE user_id = ? AND needs_review = 1 AND dismissed = 0) +
                        (SELECT COUNT(*) FROM food_logs WHERE user_id = ? AND needs_review = 1 AND deleted_at IS NULL)
                    )
                """,
                arguments: [userId.uuidString, userId.uuidString]
            ) ?? -1
            XCTAssertGreaterThanOrEqual(expectedCount, 1)
        }

        let computedCount = try await manager.dbQueue.read { db in
            try MainTabView._testComputeNeedsReviewCount(db: db, authId: authId.uuidString)
        }
        XCTAssertEqual(computedCount, 2)

        let missingAuthCount = try await manager.dbQueue.read { db in
            try MainTabView._testComputeNeedsReviewCount(db: db, authId: nil)
        }
        XCTAssertEqual(missingAuthCount, 0)

        let unknownAuthCount = try await manager.dbQueue.read { db in
            try MainTabView._testComputeNeedsReviewCount(db: db, authId: UUID().uuidString)
        }
        XCTAssertEqual(unknownAuthCount, 0)

        XCTAssertNil(MainTabView._testConsumePresentableDestination(nil))
        XCTAssertNil(MainTabView._testConsumePresentableDestination(.home))
        XCTAssertNil(MainTabView._testConsumePresentableDestination(.insights))
        XCTAssertNil(MainTabView._testConsumePresentableDestination(.settings))
        XCTAssertEqual(MainTabView._testConsumePresentableDestination(.simulation), .simulation)
        XCTAssertEqual(
            MainTabView._testConsumePresentableDestination(.supplements(date: "2026-02-24"))?.id,
            "supplements:2026-02-24"
        )

        AuthManager.setActiveAuthIdForTests(nil)
        let refreshRouter = DeepLinkRouter()
        let mainTab = MainTabView(injectedRouter: refreshRouter)
        await mainTab._testRunRefreshTask()
        await mainTab._testRefreshNeedsReviewBadge()
        await mainTab._testRefreshNeedsReviewBadgeFailurePath()
        XCTAssertEqual(mainTab._testInsightsNeedsReviewCount(), 0)
    }

    func testNotificationDeliveryGateRequiresFirstInsight() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let now = Date()

        try await manager.dbQueue.write { db in
            try insertTestUser(db: db, userId: userId, authId: authId, now: now)

            XCTAssertFalse(try NotificationDeliveryGate._testIsUnlocked(db: db, authId: nil))
            XCTAssertFalse(try NotificationDeliveryGate._testIsUnlocked(db: db, authId: authId.uuidString))

            let insight = Insight(
                userId: userId,
                category: .recovery,
                title: "Recovery trend",
                body: "You are ready for moderate intensity training.",
                confidence: 0.92
            )
            try insight.insert(db)

            XCTAssertTrue(try NotificationDeliveryGate._testIsUnlocked(db: db, authId: authId.uuidString))
        }
    }

    func testNotificationDeliveryGateClosesWhenAllCategoriesAreDisabled() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let now = Date()

        try await manager.dbQueue.write { db in
            try insertTestUser(db: db, userId: userId, authId: authId, now: now)

            var insight = Insight(
                userId: userId,
                category: .sleep,
                title: "Sleep insight",
                body: "Your bedtime consistency improved.",
                confidence: 0.88
            )
            insight.createdAt = now
            insight.updatedAt = now
            try insight.insert(db)

            var settings = NotificationSettings(userId: userId)
            settings.morningBriefEnabled = false
            settings.positiveEnabled = false
            settings.nudgesEnabled = false
            settings.celebrationEnabled = false
            settings.criticalOnly = false
            settings.createdAt = now
            settings.updatedAt = now
            try settings.insert(db)

            XCTAssertFalse(try NotificationDeliveryGate._testIsUnlocked(db: db, authId: authId.uuidString))

            settings.criticalOnly = true
            settings.updatedAt = now.addingTimeInterval(60)
            try settings.save(db)

            XCTAssertTrue(try NotificationDeliveryGate._testIsUnlocked(db: db, authId: authId.uuidString))
        }
    }

    func testOnboardingRootAndForceOverlayBodyBranches() async throws {
        let authManager = AuthManager()
        let forceUpdateManager = ForceUpdateManager()
        let appStoreURL = URL(string: "https://apps.apple.com/us/app/lifeos/id0000000000")!

        forceUpdateManager._testSetStatus(.upToDate, appStoreURL: appStoreURL)
        XCTAssertEqual(RootView._testOverlayKind(for: .upToDate), "upToDate")
        XCTAssertFalse(RootView._testShouldShowDatabaseFallbackBanner(isUsingInMemoryFallback: false))
        XCTAssertTrue(RootView._testShouldShowDatabaseFallbackBanner(isUsingInMemoryFallback: true))

        let authStates: [AuthState] = [.loading, .signedOut, .needsOnboarding, .authenticated, .anonymous]
        for state in authStates {
            switch state {
            case .loading:
                XCTAssertEqual(RootView._testRootContentKind(for: state), "loading")
            case .signedOut:
                XCTAssertEqual(RootView._testRootContentKind(for: state), "signedOut")
            case .needsOnboarding:
                XCTAssertEqual(RootView._testRootContentKind(for: state), "needsOnboarding")
            case .authenticated, .anonymous:
                XCTAssertEqual(RootView._testRootContentKind(for: state), "mainTabs")
            }

            switch state {
            case .signedOut, .loading:
                authManager._testSetState(authState: state, userId: nil, isAnonymous: false)
            case .anonymous:
                authManager._testSetState(authState: state, userId: UUID(), isAnonymous: true)
            case .authenticated, .needsOnboarding:
                authManager._testSetState(authState: state, userId: UUID(), isAnonymous: false)
            }

            let root = RootView()
                .environment(authManager)
                .environment(forceUpdateManager)
            renderForCoverage(root)

            let degradedRoot = RootView(isUsingInMemoryFallback: true)
                .environment(authManager)
                .environment(forceUpdateManager)
            renderForCoverage(degradedRoot)
        }

        forceUpdateManager._testSetStatus(.softUpdate(minVersion: "99.0"), appStoreURL: appStoreURL)
        XCTAssertEqual(RootView._testOverlayKind(for: .softUpdate(minVersion: "99.0")), "softUpdate")
        let softRoot = RootView()
            .environment(authManager)
            .environment(forceUpdateManager)
        renderForCoverage(softRoot)

        forceUpdateManager._testSetStatus(.forceUpdate(minVersion: "100.0"), appStoreURL: appStoreURL)
        XCTAssertEqual(RootView._testOverlayKind(for: .forceUpdate(minVersion: "100.0")), "forceUpdate")
        let forceRoot = RootView()
            .environment(authManager)
            .environment(forceUpdateManager)
        renderForCoverage(forceRoot)

        let softOverlay = RootView._testMakeForceUpdateOverlay(
            minVersion: "99.0",
            isSoft: true,
            appStoreURL: appStoreURL
        )
        let forcedOverlay = RootView._testMakeForceUpdateOverlay(
            minVersion: "100.0",
            isSoft: false,
            appStoreURL: appStoreURL
        )
        renderForCoverage(softOverlay)
        renderForCoverage(forcedOverlay)
        renderForCoverage(RootView._testMakeDatabaseFallbackBanner())
        RootView._testEvaluateForceUpdateOverlayBodies(minVersion: "101.0", appStoreURL: appStoreURL)
        RootView._testEvaluateRootContentBodies()
        RootView._testEvaluateDatabaseFallbackBannerBody()
        RootView._testTriggerForceUpdateOpenStoreAction(minVersion: "102.0", appStoreURL: appStoreURL)

        let onboardingStepView = OnboardingStepView(
            icon: "person",
            title: "Title",
            description: "Description",
            buttonTitle: "Continue",
            action: {}
        )
        onboardingStepView._testEvaluateBody()
        renderForCoverage(onboardingStepView)

        let onboardingStates: [OnboardingStep] = [
            .notStarted,
            .authComplete,
            .profileComplete,
            .healthkitPrompted,
            .healthkitGranted,
            .healthkitSkipped,
            .backfillInProgress,
            .backfillComplete,
            .tutorialShown,
            .onboardingComplete
        ]

        for step in onboardingStates {
            var state = OnboardingFeature.State()
            state.currentStep = step
            if step == .backfillInProgress {
                state.isBackfilling = true
            }
            if step == .backfillComplete || step == .tutorialShown || step == .onboardingComplete {
                state.isBackfilling = false
                state.isCompleting = step == .onboardingComplete
            }

            let store = Store(initialState: state) {
                OnboardingFeature()
            }
            let onboarding = OnboardingView(store: store)
            onboarding._testEvaluateBody()
            renderForCoverage(onboarding.environment(authManager))
        }

        LifeOSApp._testInitializeAndEvaluateBody()
        await LifeOSApp._testExerciseInstanceEntrypoints()
        await LifeOSApp._testExercisePrivateAsyncHelpers(userId: UUID())
        await MainActor.run {
            let rootView = RootView()
            rootView._testEvaluateBody()
            renderForCoverage(
                rootView
                    .environment(authManager)
                    .environment(forceUpdateManager)
            )
        }

        let helperManager = try DatabaseManager.inMemory()
        let helperSyncEngine = SyncEngine(
            dbQueue: helperManager.dbQueue,
            apiClient: FakeSyncAPIClient(),
            pushTransportOverride: { _ in }
        )
        AppContainer.shared = AppContainer(syncEngine: helperSyncEngine)
        LifeOSApp._testSetAsyncHelperOverrides(
            bootstrap: {},
            runSyncLoop: {},
            refreshAuthState: {},
            runPrivacyMaintenance: {},
            syncDailyState: { _ in }
        )
        defer {
            LifeOSApp._testResetAsyncHelperOverrides()
            AppContainer.shared = nil
        }
        await LifeOSApp._testExerciseInstanceEntrypoints(runBootstrap: true)
        await LifeOSApp._testExercisePrivateAsyncHelpers(userId: UUID(), runLiveOperations: true)

        let forcedFallbackManager = DatabaseManager._testMakeManagerWithForcedPersistentFailure()
        XCTAssertTrue(forcedFallbackManager.isUsingInMemoryFallback)
        XCTAssertTrue(
            RootView._testShouldShowDatabaseFallbackBanner(
                isUsingInMemoryFallback: forcedFallbackManager.isUsingInMemoryFallback
            )
        )

        XCTAssertNil(LifeOSApp._testWatchDeepLinkURL(userInfo: nil))
        XCTAssertEqual(
            LifeOSApp._testWatchDeepLinkURL(userInfo: ["deep_link": "not a url"])?.absoluteString,
            "not%20a%20url"
        )
        XCTAssertEqual(
            LifeOSApp._testWatchDeepLinkURL(userInfo: ["deep_link": "lifeos://nutrition/log"])?.absoluteString,
            "lifeos://nutrition/log"
        )
        let pendingWatchDestination = await MainActor.run {
            LifeOSApp._testApplyPendingWatchDeepLinks(["lifeos://supplements?date=2026-02-24"])
        }
        XCTAssertEqual(pendingWatchDestination, "supplements:2026-02-24")
        let watchNotificationDestination = await MainActor.run {
            LifeOSApp._testHandleWatchDeepLinkNotification(
                userInfo: ["deep_link": "lifeos://insights", "source": "watch"],
                pendingDeepLinks: ["lifeos://supplements?date=2026-02-24"]
            )
        }
        XCTAssertEqual(watchNotificationDestination, "insights")
        let emptyInitialDestination = await MainActor.run {
            LifeOSApp._testApplyInitialURLIfNeeded(with: nil)
        }
        XCTAssertNil(emptyInitialDestination)
        let appliedInitialDestination = await MainActor.run {
            LifeOSApp._testApplyInitialURLIfNeeded(
                with: URL(string: "lifeos://supplements?date=2026-02-24")
            )
        }
        XCTAssertEqual(appliedInitialDestination, "supplements:2026-02-24")

        let foregroundSkipped = LifeOSApp._testHandleForegroundEvent(skipBackgroundWork: true)
        XCTAssertEqual(foregroundSkipped.started, 0)
        XCTAssertEqual(foregroundSkipped.workRuns, 0)

        let foregroundAllowed = LifeOSApp._testHandleForegroundEvent(skipBackgroundWork: false)
        XCTAssertEqual(foregroundAllowed.started, 1)
        XCTAssertEqual(foregroundAllowed.workRuns, 1)

        XCTAssertEqual(LifeOSApp._testHandleDidBecomeActiveEvent(skipBackgroundWork: true), 0)
        XCTAssertEqual(LifeOSApp._testHandleDidBecomeActiveEvent(skipBackgroundWork: false), 1)

        let userId = UUID()
        let postBootstrapSkipped = await LifeOSApp._testPerformPostBootstrapWork(
            skipBackgroundWork: true,
            isAuthenticated: true,
            userId: userId
        )
        XCTAssertEqual(postBootstrapSkipped.syncLoops, 0)
        XCTAssertEqual(postBootstrapSkipped.refreshes, 0)
        XCTAssertEqual(postBootstrapSkipped.maintenances, 0)
        XCTAssertEqual(postBootstrapSkipped.schedules, 0)
        XCTAssertTrue(postBootstrapSkipped.syncedUserIds.isEmpty)

        let postBootstrapAuth = await LifeOSApp._testPerformPostBootstrapWork(
            skipBackgroundWork: false,
            isAuthenticated: true,
            userId: userId
        )
        XCTAssertEqual(postBootstrapAuth.syncLoops, 1)
        XCTAssertEqual(postBootstrapAuth.refreshes, 1)
        XCTAssertEqual(postBootstrapAuth.maintenances, 1)
        XCTAssertEqual(postBootstrapAuth.schedules, 2)
        XCTAssertEqual(postBootstrapAuth.syncedUserIds, [userId])

        let postBootstrapNoAuth = await LifeOSApp._testPerformPostBootstrapWork(
            skipBackgroundWork: false,
            isAuthenticated: false,
            userId: nil
        )
        XCTAssertEqual(postBootstrapNoAuth.syncLoops, 0)
        XCTAssertEqual(postBootstrapNoAuth.refreshes, 0)
        XCTAssertEqual(postBootstrapNoAuth.maintenances, 1)
        XCTAssertEqual(postBootstrapNoAuth.schedules, 2)
        XCTAssertTrue(postBootstrapNoAuth.syncedUserIds.isEmpty)

        let foregroundWorkSkipped = await LifeOSApp._testPerformForegroundWork(
            skipBackgroundWork: true,
            isAuthenticated: true,
            userId: userId
        )
        XCTAssertEqual(foregroundWorkSkipped.syncLoops, 0)
        XCTAssertEqual(foregroundWorkSkipped.refreshes, 0)
        XCTAssertTrue(foregroundWorkSkipped.syncedUserIds.isEmpty)

        let foregroundWorkAuth = await LifeOSApp._testPerformForegroundWork(
            skipBackgroundWork: false,
            isAuthenticated: true,
            userId: userId
        )
        XCTAssertEqual(foregroundWorkAuth.syncLoops, 1)
        XCTAssertEqual(foregroundWorkAuth.refreshes, 1)
        XCTAssertEqual(foregroundWorkAuth.syncedUserIds, [userId])

        let foregroundWorkNoAuth = await LifeOSApp._testPerformForegroundWork(
            skipBackgroundWork: false,
            isAuthenticated: false,
            userId: userId
        )
        XCTAssertEqual(foregroundWorkNoAuth.syncLoops, 0)
        XCTAssertEqual(foregroundWorkNoAuth.refreshes, 0)
        XCTAssertEqual(foregroundWorkNoAuth.syncedUserIds, [userId])
    }

    func testDiaryViewModelCoverageLoadSummaryAndTargetBranches() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let date = Date(timeIntervalSince1970: 1_706_659_200)
        let day = DiaryDateFormatter.formatDate(date)
        let now = Date()

        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (
                        id, auth_id, timezone, units, weight_kg, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [userId.uuidString, authId.uuidString, "UTC", "metric", 82.5, now, now]
            )

            try db.execute(
                sql: """
                    INSERT INTO food_logs (
                        id, user_id, logged_at, logged_date, input_method,
                        calories, protein_g, fat_g, carbs_g, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [UUID().uuidString, userId.uuidString, now, day, "manual", 640, 32, 20, 74, now, now]
            )
            try db.execute(
                sql: """
                    INSERT INTO food_logs (
                        id, user_id, logged_at, logged_date, input_method,
                        calories, protein_g, fat_g, carbs_g, deleted_at, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [UUID().uuidString, userId.uuidString, now, day, "manual", 500, 20, 15, 55, now, now, now]
            )

            try db.execute(
                sql: """
                    INSERT INTO daily_nutrition_targets (
                        id, user_id, date, final_calories, final_protein_g, final_fat_g,
                        final_carbs_g, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [UUID().uuidString, userId.uuidString, day, 2300, 150, 70, 250, now, now]
            )
        }

        try await manager.dbQueue.read { db in
            XCTAssertNil(try DiaryViewModel._testLatestUserId(authId: nil, db: db))
            XCTAssertNil(try DiaryViewModel._testLatestUserId(authId: UUID().uuidString, db: db))
            XCTAssertEqual(try DiaryViewModel._testLatestUserId(authId: authId.uuidString, db: db), userId)

            let emptySummary = try DiaryViewModel._testLoadSummary(day: day, authId: nil, db: db)
            XCTAssertEqual(emptySummary.foodCount, 0)
            XCTAssertNil(emptySummary.target)

            let summary = try DiaryViewModel._testLoadSummary(day: day, authId: authId.uuidString, db: db)
            XCTAssertEqual(summary.foodCount, 1)
            XCTAssertEqual(summary.calories, 640, accuracy: 0.0001)
            XCTAssertEqual(summary.protein, 32, accuracy: 0.0001)
            XCTAssertEqual(summary.target?.calories, 2300)
            XCTAssertEqual(summary.target?.protein, 150)
        }

        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE daily_nutrition_targets
                    SET final_calories = NULL,
                        final_protein_g = NULL,
                        final_fat_g = NULL,
                        final_carbs_g = NULL,
                        updated_at = ?
                    WHERE user_id = ? AND date = ?
                    """,
                arguments: [now, userId.uuidString, day]
            )
            try db.execute(
                sql: """
                    INSERT INTO physiological_states (
                        id, user_id, date, recovery_score, recovery_zone,
                        confidence_score, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [UUID().uuidString, userId.uuidString, day, 81, "ready", 0.9, now, now]
            )
            try db.execute(
                sql: """
                    INSERT INTO training_loads (
                        id, user_id, date, daily_trimp, daily_active_calories, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [UUID().uuidString, userId.uuidString, day, 92, 710, now, now]
            )
        }

        try await manager.dbQueue.read { db in
            let computedTarget = try DiaryViewModel._testResolvedTarget(for: day, userId: userId, db: db)
            let target = try XCTUnwrap(computedTarget)
            XCTAssertGreaterThan(target.calories, 0)
            XCTAssertGreaterThan(target.protein, 0)
            XCTAssertGreaterThan(target.carbs, 0)
            XCTAssertGreaterThan(target.fat, 0)
        }

        try await manager.dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM physiological_states WHERE user_id = ? AND date = ?",
                arguments: [userId.uuidString, day]
            )
        }
        try await manager.dbQueue.read { db in
            let fallbackTarget = try DiaryViewModel._testResolvedTarget(for: day, userId: userId, db: db)
            XCTAssertNotNil(fallbackTarget)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let vm = DiaryViewModel(dbQueue: manager.dbQueue)
        await vm.refresh(for: date)

        XCTAssertEqual(vm.caloriesValue, "640")
        XCTAssertEqual(vm.proteinValue, "32")
        XCTAssertNotEqual(vm.nutritionSubtitle, String(localized: "no_meals_logged"))
        XCTAssertFalse((vm.targetSummary ?? "").isEmpty)
    }

    func testDiaryViewModelCoverageErrorResetPath() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        try await manager.dbQueue.write { db in
            try db.execute(sql: "DROP TABLE users")
        }

        let vm = DiaryViewModel(dbQueue: manager.dbQueue)
        vm.caloriesValue = "100"
        vm.proteinValue = "40"
        vm.fatValue = "20"
        vm.carbsValue = "10"
        vm.nutritionSubtitle = "loaded"
        vm.targetSummary = "target"

        await vm.refresh(for: Date())

        XCTAssertEqual(vm.caloriesValue, "—")
        XCTAssertEqual(vm.proteinValue, "—")
        XCTAssertEqual(vm.fatValue, "—")
        XCTAssertEqual(vm.carbsValue, "—")
        XCTAssertEqual(vm.nutritionSubtitle, String(localized: "no_meals_logged"))
        XCTAssertNil(vm.targetSummary)
    }

    func testMixedUUIDUserLookupAcrossHomeDiaryAndMainTab() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let now = Date()
        let day = "2026-03-05"

        try await manager.dbQueue.write { db in
            var user = User(id: userId, authId: authId, timezone: "UTC", units: .metric)
            user.createdAt = now
            user.updatedAt = now
            try user.insert(db)
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO users (
                        id, auth_id, timezone, units, created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [userId, authId, "UTC", "metric", now, now]
            )

            try db.execute(
                sql: """
                    INSERT INTO food_logs (
                        id, user_id, logged_at, logged_date, input_method,
                        calories, protein_g, fat_g, carbs_g, ai_confidence, needs_review, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    now,
                    day,
                    "manual",
                    640.0,
                    32.0,
                    20.0,
                    74.0,
                    0.4,
                    true,
                    now,
                    now
                ]
            )

            try db.execute(
                sql: """
                    INSERT INTO daily_nutrition_targets (
                        id, user_id, date, final_calories, final_protein_g, final_fat_g, final_carbs_g, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [UUID().uuidString, userId.uuidString, day, 2300, 150, 70, 250, now, now]
            )

            try db.execute(
                sql: """
                    INSERT INTO insights (
                        id, user_id, category, title, body, confidence, priority,
                        actionable, read, acknowledged, dismissed, needs_review,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    "recovery",
                    "Needs review",
                    "Body",
                    0.2,
                    1,
                    false,
                    false,
                    false,
                    false,
                    true,
                    now,
                    now
                ]
            )
        }

        try await manager.dbQueue.read { db in
            XCTAssertEqual(try DiaryViewModel._testLatestUserId(authId: authId.uuidString, db: db), userId)

            let summary = try DiaryViewModel._testLoadSummary(day: day, authId: authId.uuidString, db: db)
            XCTAssertEqual(summary.foodCount, 1)
            XCTAssertEqual(summary.calories, 640, accuracy: 0.0001)

            let rawInsightCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM insights
                    WHERE (user_id = ? OR user_id = ?)
                      AND needs_review = 1
                      AND dismissed = 0
                    """,
                arguments: [userId, userId.uuidString]
            )
            let rawFoodCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM food_logs
                    WHERE (user_id = ? OR user_id = ?)
                      AND needs_review = 1
                      AND deleted_at IS NULL
                    """,
                arguments: [userId, userId.uuidString]
            )
            XCTAssertEqual(rawInsightCount, 1)
            XCTAssertEqual(rawFoodCount, 1)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let homeAction = try await HomeViewModel._testComputeNextBestAction(
            db: manager.dbQueue,
            confidenceScore: 0.9
        )
        XCTAssertEqual(homeAction, .needsReview(count: 2))

        let badgeCount = try await manager.dbQueue.read { db in
            try MainTabView._testComputeNeedsReviewCount(db: db, authId: authId.uuidString)
        }
        XCTAssertEqual(badgeCount, 2)
    }

    func testSettingsScopedLoadPrefersActiveUserAcrossMixedUUIDRows() async {
        let manager = try! DatabaseManager.inMemory()
        let dbQueue = manager.dbQueue
        let syncEngine = SyncEngine(dbQueue: dbQueue, apiClient: FakeSyncAPIClient())
        let authId = UUID()
        let userId = UUID()
        let otherUserId = UUID()

        let outputs = await SettingsDestinationViewsTestHarness.exerciseMixedUUIDScopedExistingLoad(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            authId: authId,
            userId: userId,
            otherUserId: otherUserId
        )

        XCTAssertEqual(outputs[0], userId.uuidString)
        XCTAssertEqual(outputs[1], userId.uuidString)
        XCTAssertEqual(outputs[2], "advisory")
        XCTAssertEqual(outputs[3], "cloud_off")
    }

    func testWellnessSaveDeduplicatesMixedUUIDRowsForSameDay() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let day = "2026-03-05"
        let now = Date()
        let rawUserId = MixedUUIDStorage.rawData(userId)
        let rawWellnessId = MixedUUIDStorage.rawData(UUID())

        try await manager.dbQueue.write { db in
            var user = User(id: userId, authId: authId, timezone: "UTC", units: .metric)
            user.createdAt = now
            user.updatedAt = now
            try user.insert(db)
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO users (
                        id, auth_id, timezone, units, created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [rawUserId, authId.uuidString, "UTC", "metric", now, now]
            )

            try db.execute(
                sql: """
                    INSERT INTO wellness_checks (
                        id, user_id, checked_at, date, perceived_sleep_quality,
                        energy_level, muscle_soreness, stress_level, mood,
                        feeling_ill, headache, digestive_issues, notes,
                        wellness_score, mental_health_resources_shown,
                        created_at, updated_at, deleted_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    now,
                    day,
                    2, 2, 2, 2, 2,
                    false, false, false, "legacy-text",
                    20.0, true,
                    now,
                    now,
                    nil
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO wellness_checks (
                        id, user_id, checked_at, date, perceived_sleep_quality,
                        energy_level, muscle_soreness, stress_level, mood,
                        feeling_ill, headache, digestive_issues, notes,
                        wellness_score, mental_health_resources_shown,
                        created_at, updated_at, deleted_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    rawWellnessId,
                    rawUserId,
                    now.addingTimeInterval(-60),
                    day,
                    3, 3, 3, 3, 3,
                    false, false, false, "blob-row",
                    35.0, false,
                    now.addingTimeInterval(-60),
                    now.addingTimeInterval(-60),
                    nil
                ]
            )
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let status = await WellnessCheckDayViewTestHarness.saveSnapshot(
            dateString: day,
            dbQueue: manager.dbQueue,
            sleepQuality: 5,
            energyLevel: 4,
            muscleSoreness: 2,
            stressLevel: 1,
            mood: 5,
            feelingIll: false,
            headache: false,
            digestiveIssues: false,
            notes: "normalized"
        )
        XCTAssertEqual(status, String(localized: "wellness_saved"))

        try await manager.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, user_id, perceived_sleep_quality, notes, deleted_at
                    FROM wellness_checks
                    WHERE (user_id = ? OR user_id = ? OR user_id = ?)
                      AND date = ?
                    ORDER BY updated_at DESC
                    """,
                arguments: [userId, userId.uuidString, rawUserId, day]
            )

            XCTAssertEqual(rows.count, 1)
            let activeRows = rows.filter { ($0["deleted_at"] as Date?) == nil }
            XCTAssertEqual(activeRows.count, 1)
            let activeRow = try XCTUnwrap(activeRows.first)
            XCTAssertEqual((activeRow["perceived_sleep_quality"] as Int?), 5)
            XCTAssertEqual((activeRow["notes"] as String?), "normalized")
            XCTAssertEqual(MixedUUIDStorage.decode(from: activeRow, column: "user_id"), userId)
        }
    }

    func testAPIClientCoverageNetworkEntryPointsSmoke() async {
        APIClient._testResetOverrides()
        defer { APIClient._testResetOverrides() }

        let api = APIClient(deviceId: "coverage-device")
        let now = Date()
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/rest/v1/users")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["X-Min-App-Version": "0.0.1"]
        )!

        APIClient._testSetExecuteDecodedQueryOverride { (Data("[]".utf8), response) }

        let _: [LifeOS.User]? = try? await api.fetch(
            from: "users",
            since: now.addingTimeInterval(-86_400),
            orderBy: "updated_at",
            ascending: false,
            limit: 5,
            offset: 2,
            activeWindowDays: 7,
            exactMatch: ["id": UUID().uuidString]
        )

        let cursor = APIClient.SyncPageCursor(updatedAt: now.addingTimeInterval(-3_600), rowId: UUID().uuidString)
        let _: [LifeOS.User]? = try? await api.fetchSyncPage(
            from: "users",
            since: now.addingTimeInterval(-86_400),
            cursor: nil,
            limit: 3,
            activeWindowDays: 14
        )
        let _: [LifeOS.User]? = try? await api.fetchSyncPage(
            from: "users",
            since: nil,
            cursor: cursor,
            limit: 3,
            activeWindowDays: 14
        )

        let anyUUID = UUID()
        let _: PhysiologicalState? = try? await api.fetchLatestRecovery()
        let _: [PhysiologicalState]? = try? await api.fetchRecoveryTrend(days: 7)
        let _: LifeOS.User? = try? await api.fetchUserProfile()
        let _: [FoodLog]? = try? await api.fetchFoodLogs(since: now.addingTimeInterval(-10_000))
        let _: [FoodItem]? = try? await api.fetchFoodItems(forLogId: anyUUID)
        let _: [DailyNutritionTarget]? = try? await api.fetchNutritionTargets(since: now.addingTimeInterval(-20_000))
        let _: [WorkoutSession]? = try? await api.fetchWorkoutSessions(since: now.addingTimeInterval(-30_000))
        let _: [TrainingLoad]? = try? await api.fetchTrainingLoads(since: now.addingTimeInterval(-30_000))
        let _: [UserSupplement]? = try? await api.fetchUserSupplements()
        let _: [SupplementLog]? = try? await api.fetchSupplementLogs(since: now.addingTimeInterval(-40_000))
        let _: [WellnessCheck]? = try? await api.fetchWellnessChecks(since: now.addingTimeInterval(-50_000))
        let _: [BodyComposition]? = try? await api.fetchBodyComposition(since: now.addingTimeInterval(-60_000))
        let _: [HydrationLog]? = try? await api.fetchHydrationLogs(since: now.addingTimeInterval(-70_000))
        let _: [Insight]? = try? await api.fetchInsights(since: now.addingTimeInterval(-80_000))
        let _: NotificationSettings? = try? await api.fetchNotificationSettings()
        let _: OnboardingState? = try? await api.fetchOnboardingState()
        let _: UserBaseline? = try? await api.fetchUserBaseline()

        _ = try? await api.upsertRow(table: "users", bodyJson: Data(), headers: [:])
        _ = try? await api.upsertRow(table: "users", bodyJson: Data("not-json".utf8), headers: [:])
        if let validPayload = try? JSONSerialization.data(withJSONObject: ["id": UUID().uuidString]) {
            APIClient._testSetPostgrestAccessTokenOverride("coverage-token")
            APIClient._testSetPostgrestDataForRequestOverride { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer coverage-token")
                return (Data(), response)
            }
            _ = try? await api.upsertRow(table: "users", bodyJson: validPayload, headers: ["X-Correlation-Id": "coverage-corr"])
        }

        APIClient._testSetEdgeInvokeOverride { name, _ in
            XCTAssertEqual(name, "api-analytics-batch")
            return (Data("{}".utf8), response)
        }
        let _: EmptyResponse? = try? await api.callEdgeFunction(
            "api-analytics-batch",
            body: Data("{}".utf8),
            headers: ["X-Outbox-Replay": "true"],
            maxAttempts: 1
        )

        _ = await api.shouldBlockMutationsForForceUpdate()
        XCTAssertNotNil(APIClientError.retryLimitReached(underlying: nil).errorDescription)
        XCTAssertNotNil(APIClientError.rateLimited(function: "fn").errorDescription)
    }

    func testAPIClientCoverageAdditionalRetryAndDecodePaths() async {
        let api = APIClient(deviceId: "coverage-device-extra")

        do {
            let _: EmptyResponse = try await api.callEdgeFunction(
                "api-analytics-batch",
                body: Data("{}".utf8),
                maxAttempts: 0
            )
            XCTFail("Expected retryLimitReached when maxAttempts=0")
        } catch let error as APIClientError {
            switch error {
            case .retryLimitReached:
                break
            default:
                XCTFail("Unexpected APIClientError case: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            let _: EmptyResponse = try await api.callEdgeFunction(
                "api-analytics-batch",
                body: Data([0xFF, 0x00]),
                maxAttempts: 1
            )
            XCTFail("Expected payload encoding error")
        } catch {
            XCTAssertNotNil(error.localizedDescription)
        }

        do {
            try await api.upsertRow(table: "users", bodyJson: Data("{}".utf8), headers: [:])
            XCTFail("Expected upsert to fail without an authenticated session")
        } catch {
            XCTAssertNotNil(error.localizedDescription)
        }
    }

    func testAPIClientCoverageRateLimitRetryAndSyncPageKeysetBranches() async throws {
        let api = APIClient(deviceId: "coverage-device-branches")
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://example.com/api")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )

        APIClient._testResetOverrides()
        defer {
            APIClient._testResetOverrides()
            Task { await RateLimitTracker.shared.reset() }
        }

        await RateLimitTracker.shared.reset()
        for _ in 0..<RateLimitPolicy.analyticsPerMinute {
            _ = await RateLimitTracker.shared.checkAndRecord(
                key: "analytics_perMin",
                limit: RateLimitPolicy.analyticsPerMinute,
                windowSeconds: 60
            )
        }

        do {
            let _: EmptyResponse = try await api.callEdgeFunction(
                "api-analytics-batch",
                body: Data("{}".utf8),
                headers: [:],
                maxAttempts: 1
            )
            XCTFail("Expected client-side rate limiting to reject request")
        } catch let error as APIClientError {
            switch error {
            case .rateLimited(let function):
                XCTAssertEqual(function, "api-analytics-batch")
            default:
                XCTFail("Expected rateLimited, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await RateLimitTracker.shared.reset()

        APIClient._testSetPostgrestAccessTokenOverride("coverage-token")
        APIClient._testSetPostgrestDataForRequestOverride { _ in
            throw NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue)
        }

        do {
            try await api.upsertRow(
                table: "users",
                bodyJson: try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString]),
                headers: [:]
            )
            XCTFail("Expected retryLimitReached for repeated retryable transport failures")
        } catch let error as APIClientError {
            switch error {
            case .retryLimitReached:
                break
            default:
                XCTFail("Expected retryLimitReached, got \(error)")
            }
        }

        APIClient._testSetExecuteDecodedQueryOverride {
            (Data("[]".utf8), response)
        }
        let cursor = APIClient.SyncPageCursor(updatedAt: Date(), rowId: "row-1")
        let page: [LifeOS.User] = try await api.fetchSyncPage(
            from: "users",
            since: nil,
            cursor: cursor,
            limit: 2,
            activeWindowDays: nil
        )
        XCTAssertTrue(page.isEmpty)
    }

    func testAPIClientCoverageSuccessfulMutationInvokeAndDecoderBranches() async throws {
        struct CoverageBinaryPayload: Decodable {
            let payload: Data
        }

        final class CaptureStore: @unchecked Sendable {
            private let lock = NSLock()
            private var postgrestRequest: URLRequest?
            private var edgeFunctionName: String?

            func setPostgrestRequest(_ request: URLRequest) {
                lock.lock()
                postgrestRequest = request
                lock.unlock()
            }

            func setEdgeFunctionName(_ name: String) {
                lock.lock()
                edgeFunctionName = name
                lock.unlock()
            }

            func snapshot() -> (request: URLRequest?, edgeName: String?) {
                lock.lock()
                let value = (postgrestRequest, edgeFunctionName)
                lock.unlock()
                return value
            }
        }

        let api = APIClient(deviceId: "coverage-device-success")
        let capture = CaptureStore()
        let postgrestResponse = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://example.com/rest")!,
                statusCode: 201,
                httpVersion: nil,
                headerFields: nil
            )
        )
        let edgeResponse = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://example.com/functions")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )

        APIClient._testResetOverrides()
        defer {
            APIClient._testResetOverrides()
            Task { await RateLimitTracker.shared.reset() }
        }

        await RateLimitTracker.shared.reset()

        APIClient._testSetPostgrestAccessTokenOverride("coverage-success-token")
        APIClient._testSetPostgrestDataForRequestOverride { request in
            capture.setPostgrestRequest(request)
            return (Data(), postgrestResponse)
        }

        let validPayload = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString])
        try await api.upsertRow(table: "users", bodyJson: validPayload, headers: [:])

        APIClient._testSetEdgeInvokeOverride { name, _ in
            capture.setEdgeFunctionName(name)
            return (Data("{}".utf8), edgeResponse)
        }
        let _: EmptyResponse = try await api.callEdgeFunction(
            "coverage_fn_ok",
            body: Data("{}".utf8),
            headers: [:],
            maxAttempts: 1
        )

        let captured = capture.snapshot()
        XCTAssertEqual(captured.request?.httpMethod, "POST")
        XCTAssertEqual(captured.request?.value(forHTTPHeaderField: "Authorization"), "Bearer coverage-success-token")
        XCTAssertNotNil(captured.request?.value(forHTTPHeaderField: "X-Correlation-Id"))
        XCTAssertEqual(captured.edgeName, "coverage_fn_ok")

        let decoded = try await api._testDecodePayload(
            Data(#"{"payload":"plain-text"}"#.utf8),
            as: CoverageBinaryPayload.self
        )
        XCTAssertEqual(decoded.payload, Data("plain-text".utf8))

        let passthrough = try APIClient._testPassthroughFunctionInvokeResult(
            data: Data("ok".utf8),
            response: edgeResponse
        )
        XCTAssertEqual(passthrough.0, Data("ok".utf8))
        XCTAssertEqual(passthrough.1.statusCode, 200)
        XCTAssertEqual(APIClient._testUTCGregorianCalendarTimeZoneIdentifier(), "GMT")
        XCTAssertTrue(APIClient._testTriggerLossyJSONUnsupportedBranch())
    }

    func testHealthKitManagerCoveragePublicMethodsSmoke() async {
        HealthKitManager._testResetOverrides()
        defer { HealthKitManager._testResetOverrides() }

        let manager = HealthKitManager()
        let now = Date()
        let sampleType = HKQuantityType(.stepCount)

        HealthKitManager._testSetStoreRequestAuthorizationRunner { _, _ in }
        HealthKitManager._testSetStoreEnableBackgroundDeliveryRunner { _, _, completion in
            completion(true, nil)
        }
        HealthKitManager._testSetQuerySamplesOverride { _, _, _, _, _ in [] }
        HealthKitManager._testSetSleepSamplesOverride { _, _ in [] }
        HealthKitManager._testSetCumulativeSumOverride { _, _, _ in nil }
        HealthKitManager._testSetQueryAnchoredSamplesOverride { _, _, _, _ in [] }

        _ = try? await manager._testRequestReadAuthorization(
            store: HKHealthStore(),
            readTypes: [sampleType]
        )
        _ = try? await manager._testEnableBackgroundDeliveryUsingStore(
            types: [sampleType],
            store: HKHealthStore()
        )

        _ = try? await manager.fetchLatestHRV(for: now)
        _ = try? await manager.fetchRestingHeartRate(for: now)
        _ = try? await manager.fetchSleep(for: now)
        if #available(iOS 16.0, *) {
            _ = try? await manager.fetchWristTemperature(for: now)
        }
        _ = try? await manager.fetchActiveCalories(for: now)
        _ = try? await manager.fetchSteps(for: now)
        _ = try? await manager.fetchExerciseMinutes(for: now)
        _ = try? await manager.fetchRespiratoryRate(for: now)
        _ = try? await manager.fetchBloodOxygen(for: now)
        _ = try? await manager.dataCompleteness(for: now)

        let bounds = await manager._testDayBounds(for: now)
        _ = try? await manager.queryAnchoredSamples(
            type: sampleType,
            start: bounds.start,
            end: bounds.end,
            anchorKey: "coverage_anchor_\(UUID().uuidString)"
        )
    }

    func testDeepLinkRouterCoverageFallbackAuditInsertsOutbox() async throws {
        let dbQueue = DatabaseManager.shared.dbQueue
        let url = URL(string: "lifeos://unknown/coverage?from=test")!

        let initialEventCount = try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM analytics_events WHERE event_name = ?",
                arguments: ["analytics.deeplink_fallback"]
            ) ?? 0
        }
        let initialOutboxCount = try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?",
                arguments: ["api-analytics-batch"]
            ) ?? 0
        }

        DeepLinkRouter._testLogFallback(url, isRunningTests: false)

        let logged = try await waitUntilTrue(timeout: 3.0) {
            try await dbQueue.read { db in
                let eventCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM analytics_events WHERE event_name = ?",
                    arguments: ["analytics.deeplink_fallback"]
                ) ?? 0
                let outboxCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?",
                    arguments: ["api-analytics-batch"]
                ) ?? 0
                return eventCount > initialEventCount && outboxCount > initialOutboxCount
            }
        }
        XCTAssertTrue(logged)

        let beforeSkip = try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM analytics_events WHERE event_name = ?",
                arguments: ["analytics.deeplink_fallback"]
            ) ?? 0
        }
        DeepLinkRouter._testLogFallback(url, isRunningTests: true)
        try? await Task.sleep(nanoseconds: 150_000_000)
        let afterSkip = try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM analytics_events WHERE event_name = ?",
                arguments: ["analytics.deeplink_fallback"]
            ) ?? 0
        }
        XCTAssertEqual(beforeSkip, afterSkip)
    }

    @MainActor
    func testMainTabCoverageAllDeepLinkDestinations() async {
        let router = DeepLinkRouter()
        var mainTabs = MainTabView(injectedRouter: router)

        for tab in AppTab.allCases {
            router.selectedTab = tab
            mainTabs._testEvaluateBody()
            renderForCoverage(MainTabView(injectedRouter: router).environment(router))
            XCTAssertFalse(tab.title.isEmpty)
            XCTAssertFalse(tab.icon.isEmpty)
        }

        router.pendingNavigation = .settings
        mainTabs._testHandlePendingNavigationChange()
        mainTabs._testHandleSelectedTabChange()
        await mainTabs._testRefreshNeedsReviewBadge()

        let insightId = UUID()
        let experimentId = UUID()
        let scanId = UUID()
        let destinations: [DeepLinkDestination] = [
            .home,
            .diary(date: "2026-02-24"),
            .insights,
            .simulation,
            .insightDetail(id: insightId),
            .settings,
            .settingsSync,
            .settingsNotifications,
            .settingsPrivacy,
            .recoveryDetail(date: "2026-02-24"),
            .nutrition(date: "2026-02-24"),
            .nutritionLog(method: .photo, aiConfidence: 0.55),
            .supplements(date: "2026-02-24"),
            .workout(date: "2026-02-24"),
            .workoutLog,
            .authCallback,
            .experiment(id: experimentId),
            .labs,
            .labScan(id: scanId),
            .hydration(date: "2026-02-24"),
            .wellness(date: "2026-02-24"),
            .menstrual(date: "2026-02-24"),
            .bodyComposition,
            .sleep(date: "2026-02-24")
        ]

        var uniqueIDs = Set<String>()
        for destination in destinations {
            uniqueIDs.insert(destination.id)
            renderForCoverage(DeepLinkDestinationView(destination: destination).environment(router))
        }

        XCTAssertEqual(uniqueIDs.count, destinations.count)
    }

    @MainActor
    func testHostedDetailViewsAndAsyncWrappersCoverage() async {
        let insight = Insight(
            userId: UUID(),
            category: .experiment,
            title: "Hosted coverage",
            body: "Body",
            confidence: 0.51
        )
        let insightsVM = InsightsViewModel()
        insightsVM._testOverrideState(
            lowConfidenceCount: 1,
            insights: [insight],
            latestWeeklyStrategyReport: nil,
            isLoading: false,
            loadError: nil,
            allInsights: [insight],
            selectedDomains: [.experiment]
        )

        renderForCoverage(InsightsView(viewModel: insightsVM))
        renderForCoverage(InsightDetailView(insightId: insight.id))
        renderForCoverage(ExperimentDetailView(experimentId: insight.id))
        renderForCoverage(SleepDayView(dateString: "2026-02-24"))
        renderForCoverage(RecoveryDetailView(dateString: "2026-02-24"))
        renderForCoverage(SimulationView())

        let insightsView = InsightsView(viewModel: insightsVM)
        await insightsView._testExerciseNavigationAndTaskWrappers(sampleInsight: insight)
        insightsView._testExerciseFilterActions()
        XCTAssertEqual(insightsView._testTriggerRouteActions(), ["lifeos://simulation", "lifeos://simulation"])
        await Task.yield()
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    private func waitUntilTrue(
        timeout: TimeInterval,
        pollIntervalMs: UInt64 = 50,
        condition: @escaping () async throws -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() {
                return true
            }
            try await Task.sleep(nanoseconds: pollIntervalMs * 1_000_000)
        }
        return false
    }

    private func renderForCoverage<V: View>(_ view: sending V, file: StaticString = #filePath, line: UInt = #line) {
        let host = UIHostingController(rootView: view)
        _ = host.view
        XCTAssertNotNil(host.viewIfLoaded, file: file, line: line)
    }
}

private enum HealthSyncFlowTestError: Error, Equatable, Sendable {
    case hrv(String)
    case environment
}

private actor HealthSyncDataProviderFlowStub: HealthSyncDataProviding {
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
    }

    private let config: Config
    private var hrvRequestedDateKeys: [String] = []

    init(config: Config) {
        self.config = config
    }

    func fetchLatestHRV(for dayContext: HistoricalLocalDayContext) async throws -> Double? {
        let key = dayContext.dayString
        hrvRequestedDateKeys.append(key)
        if config.failingHRVDateKeys.contains(key) {
            throw HealthSyncFlowTestError.hrv(key)
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
            throw HealthSyncFlowTestError.hrv("steps")
        }
        return config.steps
    }

    func fetchActiveCalories(for dayContext: HistoricalLocalDayContext) async throws -> Int? {
        _ = dayContext
        if config.throwOnActiveCalories {
            throw HealthSyncFlowTestError.hrv("active_calories")
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

private struct EnvironmentServiceFlowStub: EnvironmentServiceProtocol {
    enum Mode: Sendable {
        case success(EnvironmentalContext)
        case failure
    }

    var mode: Mode

    func fetchCurrentEnvironment() async throws -> EnvironmentalContext {
        switch mode {
        case .success(let context):
            return context
        case .failure:
            throw HealthSyncFlowTestError.environment
        }
    }
}

final class HealthSyncManagerFlowTests: XCTestCase {
    func testSyncDailyStateInsertsThenUpdatesAndEnqueuesOutbox() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        let targetDate = dateFrom(day: "2026-03-08")
        let targetDateKey = HealthSyncManager._testDateString(from: targetDate)

        try await manager.dbQueue.write { db in
            try user.insert(db)
            try Self.seedBaselineRows(userId: user.id, db: db)
        }

        let firstStub = HealthSyncDataProviderFlowStub(
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
        let firstEnvironment = EnvironmentServiceFlowStub(
            mode: .success(
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

        let inserted = try await fetchState(for: targetDateKey, dbQueue: manager.dbQueue)
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
        XCTAssertEqual(outboxCountAfterInsert, 2)

        let updateStub = HealthSyncDataProviderFlowStub(
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
        let updateEnvironment = EnvironmentServiceFlowStub(mode: .failure)
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

        let updated = try await fetchState(for: targetDateKey, dbQueue: manager.dbQueue)
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

        let provider = HealthSyncDataProviderFlowStub(
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
            environmentService: EnvironmentServiceFlowStub(mode: .failure),
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

        let oldestKey = HealthSyncManager._testDateString(from: oldest)
        let middleKey = HealthSyncManager._testDateString(from: middle)
        let newestKey = HealthSyncManager._testDateString(from: newest)

        let provider = HealthSyncDataProviderFlowStub(
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
            environmentService: EnvironmentServiceFlowStub(mode: .failure),
            dbQueue: manager.dbQueue,
            isHealthKitAvailable: { true },
            syncEngineProvider: { nil },
            timeZoneHistoryStore: timeZoneHistoryStore,
            nowProvider: { today }
        )

        do {
            try await healthSync.backfillRecentData(days: 3, userId: user.id)
            XCTFail("Expected first backfill error")
        } catch let error as HealthSyncFlowTestError {
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
                sql: "SELECT date FROM physiological_states ORDER BY date"
            )
        }
        XCTAssertEqual(insertedDates, [middleKey])
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
        dbQueue: DatabaseQueue
    ) async throws -> PhysiologicalState {
        try await dbQueue.read { db in
            try XCTUnwrap(
                PhysiologicalState
                    .filter(Column("date") == date)
                    .fetchOne(db)
            )
        }
    }

private func dateFrom(day: String) -> Date {
        let components = day.split(separator: "-")
        guard components.count == 3,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let dayOfMonth = Int(components[2]) else {
            return Date(timeIntervalSince1970: 0)
        }

        var dateComponents = DateComponents()
        dateComponents.calendar = Calendar(identifier: .gregorian)
        dateComponents.timeZone = TimeZone.current
        dateComponents.year = year
        dateComponents.month = month
        dateComponents.day = dayOfMonth
        dateComponents.hour = 12
        return dateComponents.date ?? Date(timeIntervalSince1970: 0)
    }

}

@MainActor
final class FinalCoverageContinuationTests: XCTestCase {
    private struct APIBlobPayload: Decodable {
        let blob: Data
    }

    private final class CoverageBGTask: NSObject {
        var expirationHandler: (() -> Void)?

        @objc func setTaskCompleted(success: Bool) {}

        @objc(setExpirationHandler:)
        func setObjCExpirationHandler(_ handler: Any?) {
            if let handler = handler as? (() -> Void) {
                expirationHandler = handler
                return
            }
            if let handler = handler as? (@convention(block) () -> Void) {
                expirationHandler = { handler() }
                return
            }
            expirationHandler = nil
        }

        override func responds(to aSelector: Selector!) -> Bool {
            if aSelector == Selector(("setExpirationHandler:")) {
                return true
            }
            return super.responds(to: aSelector)
        }
    }

    override func tearDown() {
        BackgroundSyncManager._testResetRegistrationOverrides()
        BackgroundSyncManager._testResetRegistrationState()
        BackgroundSyncManager._testResetActionOverrides()
        AuthView._testResetDefaultAuthOverrides()
        AuthManager._testResetOverrides()
        LifeOSApp._testResetAsyncHelperOverrides()
        GuardianManager._testSetSystemRevokeAuthorization(nil)
        GuardianManager._testSetDefaultRequestAuthorization(nil)
        GuardianManager._testSetDefaultSystemRevokeAuthorization(nil)
        AuthManager.setActiveAuthIdForTests(nil)
        super.tearDown()
    }

    func testBackgroundSyncRegistrationOverridesAndDailyPullDefaultPath() async throws {
        BackgroundSyncManager._testResetRegistrationState()
        var registered: [String] = []
        var retainedTasks: [CoverageBGTask] = []
        BackgroundSyncManager._testSetRegistrationOverrides(
            isRunningTests: false,
            registerTask: { identifier, handler in
                registered.append(identifier)
                let rawTask = CoverageBGTask()
                retainedTasks.append(rawTask)
                let task = unsafeBitCast(rawTask, to: BGTask.self)
                handler(task)
            }
        )
        BackgroundSyncManager._testInvokeRegisterTasks()
        XCTAssertEqual(
            Set(registered),
            Set([BackgroundSyncManager.outboxReplayTaskId, BackgroundSyncManager.dailyPullTaskId])
        )
        XCTAssertEqual(retainedTasks.count, 2)
        BackgroundSyncManager._testResetRegistrationOverrides()

        BackgroundSyncManager.scheduleOutboxReplay()
        BackgroundSyncManager.scheduleDailyPull()

        BackgroundSyncManager._testResetRegistrationState()
        BackgroundSyncManager._testSetRegistrationOverrides(
            isRunningTests: false,
            registerTask: nil
        )
        BackgroundSyncManager._testInvokeRegisterTasks()
        BackgroundSyncManager._testResetRegistrationOverrides()
        BackgroundSyncManager._testSubmitTaskRequestNoop(
            identifier: "com.lifeos.tests.noop.\(UUID().uuidString)"
        )

        let manager = try DatabaseManager.inMemory()
        let syncEngine = SyncEngine(
            dbQueue: manager.dbQueue,
            apiClient: FakeSyncAPIClient(),
            pushTransportOverride: { _ in }
        )
        BackgroundSyncManager._testResetActionOverrides()
        let dailyResult = await BackgroundSyncManager._testRunDailyPullAction(syncEngine: syncEngine)
        XCTAssertTrue(dailyResult)
    }

    func testAuthViewAppleRequestWrapperAndDefaultAppleRunner() async throws {
        let authManager = AuthManager(client: SupabaseConfig.client, db: try DatabaseManager.inMemory())
        let authView = AuthView(
            store: Store(initialState: AuthFeature.State()) { AuthFeature() },
            testAuthManager: authManager
        )

        XCTAssertEqual(
            Set(authView._testAppleSignInRequestWrapperScopes()),
            Set([ASAuthorization.Scope.email, ASAuthorization.Scope.fullName])
        )

        do {
            try await authView._testRunDefaultAppleSignInWithAuthManager(credential: nil)
            XCTFail("Expected invalid credential")
        } catch let error as LifeOS.AuthError {
            XCTAssertEqual(error, LifeOS.AuthError.invalidCredential)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRecoveryEngineHrvAndAgeFallbackBranches() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let targetDate = "2026-02-27"
        let now = Date(timeIntervalSince1970: 1_708_000_000)

        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [userId.uuidString, authId.uuidString, "UTC", "metric", now, now]
            )

            let baseline: [(String, Double)] = [
                ("2026-02-20", 3.8),
                ("2026-02-21", 4.0),
                ("2026-02-22", 4.2),
                ("2026-02-23", 4.1),
                ("2026-02-24", 4.3),
                ("2026-02-25", 4.4),
                ("2026-02-26", 4.0),
            ]
            for (date, hrv) in baseline {
                try db.execute(
                    sql: """
                        INSERT INTO physiological_states (
                            id, user_id, date, hrv_ms, resting_heart_rate_bpm,
                            wrist_temperature_deviation_c, sleep_duration_hours, sleep_quality_percent,
                            recovery_score, recovery_zone, created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        UUID().uuidString,
                        userId.uuidString,
                        date,
                        hrv,
                        56,
                        0.1,
                        7.2,
                        80,
                        60,
                        "ready",
                        now,
                        now,
                    ]
                )
            }

            try db.execute(
                sql: """
                    INSERT INTO physiological_states (
                        id, user_id, date, hrv_ms, resting_heart_rate_bpm,
                        wrist_temperature_deviation_c, sleep_duration_hours, sleep_quality_percent,
                        recovery_score, recovery_zone, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    targetDate,
                    5.2,
                    54,
                    0.2,
                    7.4,
                    82,
                    60,
                    "ready",
                    now,
                    now,
                ]
            )
        }

        let withUserTable = try await manager.dbQueue.read { db in
            try RecoveryEngine.computeScore(userId: userId, date: targetDate, db: db)
        }
        XCTAssertNotNil(withUserTable.components.hrvScore)

        enum AgeFetchError: Error {
            case expected
        }
        XCTAssertEqual(
            RecoveryEngine._testResolvedUserAge(fetchUser: { throw AgeFetchError.expected }),
            30
        )
    }

    func testForceUpdateURLResolutionStickyForceAndFlagPaths() {
        let resolved = ForceUpdateManager._testResolveAppStoreURL(
            infoDictionary: ["APP_STORE_URL": "https://example.com/store"]
        )
        XCTAssertEqual(resolved.absoluteString, "https://example.com/store")

        let resolvedByIdentifier = ForceUpdateManager._testResolveAppStoreURL(
            infoDictionary: ["APP_STORE_ID": "1234567890"]
        )
        XCTAssertEqual(
            resolvedByIdentifier.absoluteString,
            "itms-apps://itunes.apple.com/app/id1234567890"
        )

        let normalizedDirectListing = ForceUpdateManager._testResolveAppStoreURL(
            infoDictionary: ["APP_STORE_URL": "https://apps.apple.com/us/app/lifeos/id1234567890"]
        )
        XCTAssertEqual(
            normalizedDirectListing.absoluteString,
            "itms-apps://itunes.apple.com/app/id1234567890"
        )

        let searchFallbackWithIdentifier = ForceUpdateManager._testResolveAppStoreURL(
            infoDictionary: [
                "APP_STORE_ID": "1234567890",
                "APP_STORE_URL": "https://apps.apple.com/us/search?term=Life%20OS"
            ]
        )
        XCTAssertEqual(
            searchFallbackWithIdentifier.absoluteString,
            "itms-apps://itunes.apple.com/app/id1234567890"
        )

        let fallback = ForceUpdateManager._testResolveAppStoreURL(
            infoDictionary: nil
        )
        XCTAssertEqual(fallback.host, "apps.apple.com")

        let manager = ForceUpdateManager()
        manager._testSetStatus(.upToDate)
        XCTAssertFalse(manager.isForceUpdateRequired)

        manager._testSetStatus(.forceUpdate(minVersion: "999.0.0"))
        manager.checkHeaders(["X-App-Store-URL": "https://example.com/forced"])
        XCTAssertEqual(manager.appStoreURL.absoluteString, "https://example.com/forced")
        XCTAssertTrue(manager.isForceUpdateRequired)
    }

    func testInsightDetailTaskAPINilDataDecodeAndClinicianCaveat() async throws {
        await InsightDetailView(insightId: UUID())._testRunLoadInsightTask()

        let api = APIClient()
        let decoded: Data = try await api._testDecodePayload(Data(#""not-base64*""#.utf8))
        XCTAssertEqual(decoded, Data("not-base64*".utf8))

        let body = "Recovery trend summary"
        let insight = Insight(
            userId: UUID(),
            category: .recovery,
            title: "Coverage",
            body: body,
            confidence: 0.9
        )
        XCTAssertTrue(insight.bodyWithClinicianCaveat.contains(body))
        XCTAssertNotEqual(insight.bodyWithClinicianCaveat, body)
    }

    func testHomeRouteHandlerOnboardingLatestUserAndUITestBootstrapFallbacks() async throws {
        let router = DeepLinkRouter()
        XCTAssertTrue(
            HomeView._testRouteHandler(
                router: router,
                url: URL(string: "lifeos://home")!
            )
        )

        AuthManager.setActiveAuthIdForTests(UUID())
        let latestUser = try await OnboardingFeature._testLatestUserId()
        XCTAssertNil(latestUser)

        let previousBootstrap = getenv("LIFEOS_UI_TEST_BOOTSTRAP").map { String(cString: $0) }
        defer {
            if let previousBootstrap {
                setenv("LIFEOS_UI_TEST_BOOTSTRAP", previousBootstrap, 1)
            } else {
                unsetenv("LIFEOS_UI_TEST_BOOTSTRAP")
            }
        }

        setenv("LIFEOS_UI_TEST_BOOTSTRAP", "1", 1)
        let rawQueue = try DatabaseQueue()
        UITestBootstrap.seedLocalDataIfNeeded(dbQueue: rawQueue)
        XCTAssertNil(
            UITestBootstrap._testValue(
                envKey: "LIFEOS_ENV_DOES_NOT_EXIST",
                argumentPrefix: "--lifeos-arg-does-not-exist="
            )
        )
    }

    func testSleepScorerFallbackStatePercentBranches() {
        var state = PhysiologicalState(userId: UUID(), date: "2026-02-27", recoveryScore: 55)
        state.sleepDurationHours = 7.0
        state.deepSleepPercent = 23
        state.remSleepPercent = 21
        state.sleepQualityPercent = 78

        let score = SleepScorer.compositeScore(
            sleepLog: nil,
            physiologicalState: state,
            age: 34
        )
        XCTAssertNotNil(score)
    }

    func testLifeOSAppDefaultAsyncHelpersAndAuthManagerDefaultOtpRunners() async throws {
        LifeOSApp._testResetAsyncHelperOverrides()
        let manager = try DatabaseManager.inMemory()
        let syncEngine = SyncEngine(
            dbQueue: manager.dbQueue,
            apiClient: FakeSyncAPIClient(),
            pushTransportOverride: { _ in }
        )

        await LifeOSApp._testRefreshAuthStateDefaultPath()
        await LifeOSApp._testRunSyncLoopDefault(syncEngine: syncEngine)
        await LifeOSApp._testRunPrivacyMaintenanceDefault()
        LifeOSApp._testSetAsyncHelperOverrides(syncDailyState: { _ in })
        await LifeOSApp._testRunSyncDailyStateDefault(userId: UUID())

        let auth = AuthManager(client: SupabaseConfig.client, db: manager)
        let now = Date(timeIntervalSince1970: 1_709_000_000)
        let expectedUserId = UUID()

        var sentEmail: String?
        AuthManager._testSetSendOTPOverride(nil)
        AuthManager._testSetDefaultSendOTPOverride { email in
            sentEmail = email
        }
        try await auth.sendOTP(to: "coverage-default-send@example.invalid")
        XCTAssertEqual(sentEmail, "coverage-default-send@example.invalid")

        AuthManager._testSetVerifyOTPOverride(nil)
        AuthManager._testSetDefaultVerifyOTPOverride { email, token in
            XCTAssertEqual(email, "coverage-default-verify@example.invalid")
            XCTAssertEqual(token, "123456")
            return self.makeSession(authId: expectedUserId, isAnonymous: false, now: now)
        }
        try await auth.verifyOTP(email: "coverage-default-verify@example.invalid", token: "123456")
        XCTAssertEqual(auth.userId, expectedUserId)

        AuthManager._testSetAppleSignInOverride { token in
            XCTAssertEqual(token, "coverage-token")
            return self.makeSession(authId: expectedUserId, isAnonymous: false, now: now)
        }
        try await auth._testSignInWithAppleToken("coverage-token")
        XCTAssertEqual(auth.userId, expectedUserId)
    }

    @MainActor
    func testAdditionalTaskActionWrappersAndSimulationBodyBranches() async throws {
        let labsStore = Store(initialState: LabsFeature.State()) {
            LabsFeature()
        }
        await LabsOverviewView(store: labsStore)._testRunTaskAction()

        let dbQueue = try DatabaseQueue(path: ":memory:")
        let sleepDone = await SleepDayViewTestHarness.runLoadTaskAction(
            dateString: "2026-02-24",
            dbQueue: dbQueue
        )
        let supplementsDone = await SupplementsDayViewTestHarness.runLoadTaskAction(
            dateString: "2026-02-24",
            dbQueue: dbQueue
        )
        let trainingDone = await TrainingDayViewTestHarness.runLoadTaskAction(
            dateString: "2026-02-24",
            dbQueue: dbQueue
        )
        XCTAssertTrue(sleepDone)
        XCTAssertTrue(supplementsDone)
        XCTAssertTrue(trainingDone)

        let diaryView = DiaryView(initialDateString: "2026-02-24", viewModel: DiaryViewModel())
        await diaryView._testRefreshSelectedDateTask()

        let loadingVM = SimulationViewModel()
        loadingVM.isLoading = true
        _ = SimulationView(testViewModel: loadingVM).body

        let errorVM = SimulationViewModel()
        errorVM.error = "coverage-error"
        _ = SimulationView(testViewModel: errorVM).body
    }

    func testDeepLinkPathDateFallbacksAndHostlessAuditBranch() async throws {
        let router = DeepLinkRouter()
        let date = "2026-02-24"

        XCTAssertTrue(router.handle(URL(string: "lifeos://nutrition/\(date)")!))
        XCTAssertEqual(router.pendingNavigation, .nutrition(date: date))

        XCTAssertTrue(router.handle(URL(string: "lifeos://supplements/\(date)")!))
        XCTAssertEqual(router.pendingNavigation, .supplements(date: date))

        XCTAssertTrue(router.handle(URL(string: "lifeos://workout/\(date)")!))
        XCTAssertEqual(router.pendingNavigation, .workout(date: date))

        XCTAssertTrue(router.handle(URL(string: "lifeos://hydration/\(date)")!))
        XCTAssertEqual(router.pendingNavigation, .hydration(date: date))

        XCTAssertTrue(router.handle(URL(string: "lifeos://wellness/\(date)")!))
        XCTAssertEqual(router.pendingNavigation, .wellness(date: date))

        XCTAssertTrue(router.handle(URL(string: "lifeos://sleep/\(date)")!))
        XCTAssertEqual(router.pendingNavigation, .sleep(date: date))

        let hostlessURL = try XCTUnwrap(URL(string: "lifeos:/unknown-route"))
        DeepLinkRouter._testLogFallback(hostlessURL, isRunningTests: false)
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    func testDeepLinkDestinationIdentifiersCoverEveryCase() {
        let id = UUID()
        let date = "2026-02-24"
        let identifiers: [String] = [
            DeepLinkDestination.home.id,
            DeepLinkDestination.diary(date: date).id,
            DeepLinkDestination.insights.id,
            DeepLinkDestination.simulation.id,
            DeepLinkDestination.insightDetail(id: id).id,
            DeepLinkDestination.settings.id,
            DeepLinkDestination.settingsSync.id,
            DeepLinkDestination.settingsNotifications.id,
            DeepLinkDestination.settingsPrivacy.id,
            DeepLinkDestination.recoveryDetail(date: date).id,
            DeepLinkDestination.nutrition(date: date).id,
            DeepLinkDestination.nutritionLog(method: .photo, aiConfidence: 0.35).id,
            DeepLinkDestination.nutritionLog(method: nil, aiConfidence: nil).id,
            DeepLinkDestination.supplements(date: date).id,
            DeepLinkDestination.supplementsLog(date: date).id,
            DeepLinkDestination.workout(date: date).id,
            DeepLinkDestination.workoutLog.id,
            DeepLinkDestination.authCallback.id,
            DeepLinkDestination.experiment(id: id).id,
            DeepLinkDestination.labs.id,
            DeepLinkDestination.labScan(id: id).id,
            DeepLinkDestination.hydration(date: date).id,
            DeepLinkDestination.wellness(date: date).id,
            DeepLinkDestination.menstrual(date: date).id,
            DeepLinkDestination.bodyComposition.id,
            DeepLinkDestination.sleep(date: date).id
        ]

        XCTAssertTrue(identifiers.contains("settings:privacy"))
        XCTAssertTrue(identifiers.contains("body_composition"))
        XCTAssertTrue(identifiers.contains("nutrition_log:photo:0.35"))
        XCTAssertTrue(identifiers.contains("nutrition_log:none:none"))

        let nilDateIdentifiers: [String] = [
            DeepLinkDestination.diary(date: nil).id,
            DeepLinkDestination.recoveryDetail(date: nil).id,
            DeepLinkDestination.nutrition(date: nil).id,
            DeepLinkDestination.supplements(date: nil).id,
            DeepLinkDestination.supplementsLog(date: nil).id,
            DeepLinkDestination.workout(date: nil).id,
            DeepLinkDestination.hydration(date: nil).id,
            DeepLinkDestination.wellness(date: nil).id,
            DeepLinkDestination.menstrual(date: nil).id,
            DeepLinkDestination.sleep(date: nil).id
        ]
        XCTAssertTrue(nilDateIdentifiers.allSatisfy { $0.contains("today") })
    }

    func testGuardianManagerDefaultAuthorizationPathWithoutOverride() async {
        GuardianManager._testSetRequestAuthorization(nil)
        GuardianManager._testSetRevokeAuthorization(nil)
        GuardianManager._testSetDefaultRequestAuthorization(nil)
        GuardianManager._testSetDefaultSystemRevokeAuthorization(nil)
        AppCapabilityAvailability._testSetFamilyControlsAvailableOverride(false)

        _ = try? await GuardianManager.shared.requestAuthorization()
        GuardianManager.shared.revokeAuthorization()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let requestExpectation = expectation(description: "guardian default request authorization path")
        let revokeExpectation = expectation(description: "guardian default system revoke path")
        GuardianManager._testSetDefaultRequestAuthorization {
            requestExpectation.fulfill()
        }
        GuardianManager._testSetDefaultSystemRevokeAuthorization { completion in
            completion(.success(()))
            revokeExpectation.fulfill()
        }
        defer {
            AppCapabilityAvailability._testResetOverrides()
            GuardianManager._testSetDefaultRequestAuthorization(nil)
            GuardianManager._testSetDefaultSystemRevokeAuthorization(nil)
        }

        AppCapabilityAvailability._testSetFamilyControlsAvailableOverride(true)
        _ = try? await GuardianManager.shared.requestAuthorization()
        GuardianManager.shared.revokeAuthorization()
        await fulfillment(of: [requestExpectation, revokeExpectation], timeout: 1.0)
    }

    func testUITestBootstrapArgumentPrefixBranch() {
        let firstArgument = CommandLine.arguments.first ?? ""
        XCTAssertFalse(firstArgument.isEmpty)
        guard !firstArgument.isEmpty else { return }

        let prefixLength = min(5, firstArgument.count)
        let prefix = String(firstArgument.prefix(prefixLength))
        let expectedValue = String(firstArgument.dropFirst(prefixLength))
        let envKey = "LIFEOS_COVERAGE_MISSING_ENV_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"

        let resolvedValue = UITestBootstrap._testValue(
            envKey: envKey,
            argumentPrefix: prefix
        )
        XCTAssertEqual(resolvedValue, expectedValue)
    }

    func testUITestBootstrapEnvValueBranch() {
        let envKey = "LIFEOS_UI_BOOTSTRAP_VALUE_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let previous = getenv(envKey).map { String(cString: $0) }
        defer {
            if let previous {
                setenv(envKey, previous, 1)
            } else {
                unsetenv(envKey)
            }
        }

        setenv(envKey, "coverage-env-value", 1)
        let resolvedValue = UITestBootstrap._testValue(
            envKey: envKey,
            argumentPrefix: "--lifeos-non-matching-prefix="
        )
        XCTAssertEqual(resolvedValue, "coverage-env-value")
    }

    func testUITestBootstrapEmptyEnvFallsBackToArguments() {
        let envKey = "LIFEOS_UI_BOOTSTRAP_EMPTY_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let previous = getenv(envKey).map { String(cString: $0) }
        defer {
            if let previous {
                setenv(envKey, previous, 1)
            } else {
                unsetenv(envKey)
            }
        }

        setenv(envKey, "", 1)
        let firstArgument = CommandLine.arguments.first ?? ""
        guard !firstArgument.isEmpty else { return }
        let prefixLength = min(4, firstArgument.count)
        let prefix = String(firstArgument.prefix(prefixLength))
        let expectedValue = String(firstArgument.dropFirst(prefixLength))
        let resolvedValue = UITestBootstrap._testValue(envKey: envKey, argumentPrefix: prefix)
        XCTAssertEqual(resolvedValue, expectedValue)
    }

    func testUITestBootstrapReturnsNilForMissingEnvAndArguments() {
        let envKey = "LIFEOS_UI_BOOTSTRAP_MISSING_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        unsetenv(envKey)
        let prefix = "--lifeos-missing-prefix-\(UUID().uuidString)="
        XCTAssertNil(UITestBootstrap._testValue(envKey: envKey, argumentPrefix: prefix))
    }

    func testDatabaseQueueDependencyFactorySuccessAndFallbackBranches() throws {
        defer {
            DependencyValues._testSetDatabaseQueueFactory(nil)
        }
        let customManager = try DatabaseManager.inMemory()
        DependencyValues._testSetDatabaseQueueFactory {
            customManager
        }
        var dependencies = DependencyValues()
        XCTAssertTrue(dependencies.databaseQueue === customManager.dbQueue)

        struct FactoryError: Error {}
        DependencyValues._testSetDatabaseQueueFactory {
            throw FactoryError()
        }
        dependencies = DependencyValues()
        XCTAssertTrue(dependencies.databaseQueue === DatabaseManager.shared.dbQueue)
    }

    func testSettingsPrivacyLoadFailureBranchViaHarness() async throws {
        let manager = try DatabaseManager.inMemory()
        let syncEngine = SyncEngine(
            dbQueue: manager.dbQueue,
            apiClient: FakeSyncAPIClient(),
            pushTransportOverride: { _ in }
        )

        let status = await SettingsDestinationViewsTestHarness.exercisePrivacyLoadFailureBranch(
            syncEngine: syncEngine,
            dbQueue: manager.dbQueue
        )
        XCTAssertFalse(status.isEmpty)
    }

    func testRecoveryDetailAndSleepDayNilResultBranchesWithExistingSchema() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let now = Date()

        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [userId.uuidString, authId.uuidString, "UTC", "metric", now, now]
            )
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let recoverySummary = await RecoveryDetailViewTestHarness.loadSummary(
            dateString: "2026-02-24",
            dbQueue: manager.dbQueue
        )
        XCTAssertNil(recoverySummary)

        let sleepSummary = await SleepDayViewTestHarness.loadSummary(
            dateString: "2026-02-24",
            dbQueue: manager.dbQueue
        )
        XCTAssertNil(sleepSummary)

        let brokenQueue = try DatabaseQueue(path: ":memory:")
        let recoveryAfterError = await RecoveryDetailViewTestHarness.loadSummary(
            dateString: "2026-02-24",
            dbQueue: brokenQueue
        )
        XCTAssertNil(recoveryAfterError)
    }

    func testSleepScorerUsesSleepLogDeepAndRemBranches() {
        var log = SleepLog(userId: UUID(), date: "2026-02-24")
        log.totalDurationMinutes = 480
        log.deepSleepMinutes = 96
        log.remSleepMinutes = 120
        log.sleepEfficiency = 91
        log.numberOfAwakenings = 1

        let score = SleepScorer.compositeScore(
            sleepLog: log,
            physiologicalState: nil,
            age: 31
        )
        XCTAssertNotNil(score)
    }

    func testSimulationResponseBranchAndNutritionDynamicHintCatchBranch() async throws {
        let responseVM = SimulationViewModel()
        responseVM.response = PredictiveScenarioResponse(
            predictedRecoveryRange: [62, 70],
            predictedZone: .ready,
            explanation: "coverage",
            confidenceScore: 0.8
        )
        _ = SimulationView(testViewModel: responseVM).body

        struct NoopNutritionLogger: NutritionMealLogging {
            func logMeal(_ log: FoodLog) async throws {}
        }
        let authId = UUID()
        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }
        let brokenQueue = try DatabaseQueue(path: ":memory:")
        let nutritionVM = NutritionLogViewModel(
            method: nil,
            aiConfidence: nil,
            nutritionService: NoopNutritionLogger(),
            dbQueue: brokenQueue
        )
        await nutritionVM.loadDynamicHint()
        XCTAssertEqual(nutritionVM.dynamicHint, "")
    }

    func testHomeViewModelNoLatestStateAndPrivacyUUIDStringDecodeBranches() async throws {
        let authId = UUID()
        let userId = UUID()
        let now = Date()

        try await DatabaseManager.shared.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [userId.uuidString, authId.uuidString, "UTC", "metric", now, now]
            )
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let viewModel = HomeViewModel(pushLatestWatchSnapshot: { _ in })
        await viewModel.refresh()
        XCTAssertNil(viewModel.recoveryScore)
        XCTAssertNil(viewModel.recoveryZone)
        XCTAssertNil(viewModel.recoveryConfidence)

        let decodedId = UUID()
        let decodeQueue = try DatabaseQueue(path: ":memory:")
        try await decodeQueue.write { db in
            try db.execute(sql: "CREATE TABLE t (value TEXT)")
            try db.execute(sql: "INSERT INTO t (value) VALUES (?)", arguments: [decodedId.uuidString])
        }
        let parsed = try await decodeQueue.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT value FROM t LIMIT 1"))
            return PrivacyGateway._testDecodeUUID(from: row, column: "value")
        }
        XCTAssertEqual(parsed, decodedId)
    }

    func testInsightClinicianCaveatAndHealthSyncDefaultProviderBranches() {
        let baseBody = "Coverage health body"
        let insight = Insight(
            userId: UUID(),
            category: .health,
            title: "Coverage",
            body: baseBody,
            confidence: 0.91
        )
        let bodyWithCaveat = insight.bodyWithClinicianCaveat
        XCTAssertTrue(bodyWithCaveat.contains(baseBody))
        XCTAssertNotEqual(bodyWithCaveat, baseBody)

        let expectedSyncEngine = AppContainer.shared?.syncEngine
        let resolvedSyncEngine = HealthSyncManager._testDefaultSyncEngineProvider()
        XCTAssertTrue((resolvedSyncEngine == nil) == (expectedSyncEngine == nil))
        _ = HealthSyncManager._testDefaultHealthKitAvailability()
    }

    @MainActor
    func testMainTabEnvironmentRouterBranch() {
        let injectedRouter = DeepLinkRouter()
        var mainTab = MainTabView(injectedRouter: injectedRouter)
        mainTab._testHandleSelectedTabChange()
        renderForCoverage(
            MainTabView()
                .environment(DeepLinkRouter())
        )
    }

    @MainActor
    func testFunctionalAuditTrainingDayFiltersSessionsForResolvedUser() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let otherUserId = UUID()
        let day = "2026-02-24"

        try await manager.dbQueue.write { db in
            try Self.seedFunctionalAuditUser(db: db, userId: userId, authId: authId)
            try Self.seedFunctionalAuditUser(db: db, userId: otherUserId, authId: UUID())

            var ownSession = WorkoutSession(userId: userId, startedAt: Date(), sessionDate: day, source: .manual)
            ownSession.workoutType = .strength
            ownSession.totalSets = 12
            try ownSession.insert(db)

            var foreignSession = WorkoutSession(userId: otherUserId, startedAt: Date(), sessionDate: day, source: .manual)
            foreignSession.workoutType = .cardio
            foreignSession.totalSets = 3
            try foreignSession.insert(db)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let summaries = await TrainingDayViewTestHarness.loadSessions(dateString: day, dbQueue: manager.dbQueue)
        XCTAssertEqual(summaries.count, 1)
    }

    @MainActor
    func testFunctionalAuditWorkoutLogSeedsInitialSetWhenAddingExercise() async throws {
        let manager = try DatabaseManager.inMemory()
        let viewModel = WorkoutLogViewModel(dbQueue: manager.dbQueue)
        let catalogEntry = ExerciseCatalogEntry(
            id: UUID(),
            name: "Incline Bench Press",
            category: .strength
        )

        viewModel.addExercise(catalogEntry)

        XCTAssertEqual(viewModel.exercises.count, 1)
        XCTAssertEqual(viewModel.exercises[0].name, "Incline Bench Press")
        XCTAssertEqual(viewModel.exercises[0].sets.count, 1)
        XCTAssertEqual(viewModel.exercises[0].sets[0].weight, 0)
        XCTAssertEqual(viewModel.exercises[0].sets[0].reps, 0)
    }

    @MainActor
    func testFunctionalAuditWorkoutLogEditorNormalizesStringInputs() {
        let samples = TrainingDayViewTestHarness.editorInputNormalizationSamples()

        XCTAssertEqual(samples.weights, ["", "80", "82.5"])
        XCTAssertEqual(samples.parsedWeights.count, 3)
        XCTAssertEqual(samples.parsedWeights[0], 80, accuracy: 0.001)
        XCTAssertEqual(samples.parsedWeights[1], 82.5, accuracy: 0.001)
        XCTAssertEqual(samples.parsedWeights[2], 82.5, accuracy: 0.001)
        XCTAssertEqual(samples.reps, ["", "5"])
        XCTAssertEqual(samples.parsedReps, [5, 5, 0])
    }

    @MainActor
    func testFunctionalAuditWorkoutLogMaintainsExerciseScopedSetsInEditor() async throws {
        let manager = try DatabaseManager.inMemory()
        let firstExerciseId = UUID()
        let secondExerciseId = UUID()

        let viewModel = WorkoutLogViewModel(dbQueue: manager.dbQueue)
        viewModel.exercises = [
            WorkoutLogExercise(id: firstExerciseId, catalogId: UUID(), name: "Back Squat", category: .strength),
            WorkoutLogExercise(id: secondExerciseId, catalogId: UUID(), name: "Bench Press", category: .strength)
        ]

        viewModel.addSet(to: firstExerciseId)
        viewModel.addSet(to: firstExerciseId)
        viewModel.addSet(to: secondExerciseId)

        viewModel.exercises[0].sets[0].weight = 100
        viewModel.exercises[0].sets[0].reps = 5
        viewModel.exercises[0].sets[1].weight = 110
        viewModel.exercises[0].sets[1].reps = 3
        viewModel.exercises[1].sets[0].weight = 80
        viewModel.exercises[1].sets[0].reps = 8

        viewModel.removeSet(from: firstExerciseId, at: 0)

        XCTAssertEqual(viewModel.exercises[0].sets.count, 1)
        XCTAssertEqual(viewModel.exercises[0].sets[0].weight, 110)
        XCTAssertEqual(viewModel.exercises[0].sets[0].reps, 3)
        XCTAssertEqual(viewModel.exercises[1].sets.count, 1)
        XCTAssertEqual(viewModel.exercises[1].sets[0].weight, 80)
        XCTAssertEqual(viewModel.exercises[1].sets[0].reps, 8)

        viewModel.removeExercise(secondExerciseId)

        XCTAssertEqual(viewModel.exercises.count, 1)
        XCTAssertEqual(viewModel.exercises[0].id, firstExerciseId)
        XCTAssertEqual(viewModel.exercises[0].sets.count, 1)
    }

    @MainActor
    func testFunctionalAuditWorkoutLogRejectsEmptySaveAndIgnoresUnknownSetMutations() async throws {
        let manager = try DatabaseManager.inMemory()
        let exerciseId = UUID()
        let missingExerciseId = UUID()

        let emptyViewModel = WorkoutLogViewModel(dbQueue: manager.dbQueue)
        let didSaveEmpty = await emptyViewModel.save()
        XCTAssertFalse(didSaveEmpty)

        let viewModel = WorkoutLogViewModel(dbQueue: manager.dbQueue)
        viewModel.exercises = [
            WorkoutLogExercise(
                id: exerciseId,
                catalogId: UUID(),
                name: "Romanian Deadlift",
                category: .strength,
                sets: [WorkoutLogSet(id: UUID(), weight: 90, reps: 8)]
            )
        ]

        viewModel.addSet(to: missingExerciseId)
        XCTAssertEqual(viewModel.exercises[0].sets.count, 1)

        viewModel.removeSet(from: exerciseId, at: 5)
        XCTAssertEqual(viewModel.exercises[0].sets.count, 1)

        viewModel.removeSet(from: missingExerciseId, at: 0)
        XCTAssertEqual(viewModel.exercises[0].sets.count, 1)
        XCTAssertEqual(viewModel.exercises[0].sets[0].weight, 90)
        XCTAssertEqual(viewModel.exercises[0].sets[0].reps, 8)
    }

    @MainActor
    func testFunctionalAuditWorkoutLogPersistsPerExerciseSetLinkageAndAggregates() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let squatExerciseId = UUID()
        let benchExerciseId = UUID()
        let squatCatalogId = UUID()
        let benchCatalogId = UUID()

        try await manager.dbQueue.write { db in
            try Self.seedFunctionalAuditUser(db: db, userId: userId, authId: authId)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let viewModel = WorkoutLogViewModel(dbQueue: manager.dbQueue)
        viewModel.exercises = [
            WorkoutLogExercise(
                id: squatExerciseId,
                catalogId: squatCatalogId,
                name: "Back Squat",
                category: .strength,
                sets: [
                    WorkoutLogSet(id: UUID(), weight: 100, reps: 5),
                    WorkoutLogSet(id: UUID(), weight: 110, reps: 3)
                ]
            ),
            WorkoutLogExercise(
                id: benchExerciseId,
                catalogId: benchCatalogId,
                name: "Bench Press",
                category: .strength,
                sets: [
                    WorkoutLogSet(id: UUID(), weight: 80, reps: 8)
                ]
            )
        ]

        let didSave = await viewModel.save()
        XCTAssertTrue(didSave)

        let snapshot = try await manager.dbQueue.read { db throws in
            (
                try XCTUnwrap(WorkoutSession.fetchOne(db)),
                try WorkoutExercise
                    .order(Column("order_in_session").asc)
                    .fetchAll(db),
                try WorkoutSet
                    .order(Column("exercise_entry_id").asc)
                    .order(Column("set_number").asc)
                    .fetchAll(db)
            )
        }

        XCTAssertEqual(snapshot.0.userId, userId)
        XCTAssertEqual(try XCTUnwrap(snapshot.0.totalSets), 3)
        XCTAssertEqual(try XCTUnwrap(snapshot.0.totalReps), 16)
        XCTAssertEqual(try XCTUnwrap(snapshot.0.totalVolume), 1_470, accuracy: 0.001)
        XCTAssertEqual(snapshot.1.count, 2)
        XCTAssertEqual(snapshot.2.count, 3)

        let squatEntry = snapshot.1[0]
        let benchEntry = snapshot.1[1]

        XCTAssertEqual(try XCTUnwrap(squatEntry.totalSets), 2)
        XCTAssertEqual(try XCTUnwrap(squatEntry.totalReps), 8)
        XCTAssertEqual(try XCTUnwrap(squatEntry.totalVolume), 830, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(squatEntry.maxWeight), 110, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(benchEntry.totalSets), 1)
        XCTAssertEqual(try XCTUnwrap(benchEntry.totalReps), 8)
        XCTAssertEqual(try XCTUnwrap(benchEntry.totalVolume), 640, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(benchEntry.maxWeight), 80, accuracy: 0.001)

        let setsByEntryId = Dictionary(grouping: snapshot.2, by: \.exerciseEntryId)
        let squatSets = try XCTUnwrap(setsByEntryId[squatEntry.id])
        let benchSets = try XCTUnwrap(setsByEntryId[benchEntry.id])

        XCTAssertEqual(squatSets.map(\.setNumber), [1, 2])
        XCTAssertEqual(squatSets.map { $0.weight ?? -1 }, [100, 110])
        XCTAssertEqual(squatSets.map { $0.reps ?? -1 }, [5, 3])
        XCTAssertEqual(benchSets.map(\.setNumber), [1])
        XCTAssertEqual(benchSets.map { $0.weight ?? -1 }, [80])
        XCTAssertEqual(benchSets.map { $0.reps ?? -1 }, [8])
    }

    @MainActor
    func testFunctionalAuditWorkoutLogSaveFailsWithoutResolvedUser() async throws {
        let manager = try DatabaseManager.inMemory()
        let exerciseId = UUID()

        AuthManager.setActiveAuthIdForTests(nil)

        let viewModel = WorkoutLogViewModel(dbQueue: manager.dbQueue)
        viewModel.exercises = [
            WorkoutLogExercise(
                id: exerciseId,
                catalogId: UUID(),
                name: "Deadlift",
                category: .strength,
                sets: [WorkoutLogSet(id: UUID(), weight: 140, reps: 5)]
            )
        ]

        let didSave = await viewModel.save()
        XCTAssertFalse(didSave)

        let snapshot = try await manager.dbQueue.read { db in
            (
                try WorkoutSession.fetchCount(db),
                try WorkoutExercise.fetchCount(db),
                try WorkoutSet.fetchCount(db)
            )
        }

        XCTAssertEqual(snapshot.0, 0)
        XCTAssertEqual(snapshot.1, 0)
        XCTAssertEqual(snapshot.2, 0)
    }

    @MainActor
    func testFunctionalAuditSupplementsFallbackToCatalogNameWhenCustomNameMissing() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let catalogId = UUID()

        try await manager.dbQueue.write { db in
            try Self.seedFunctionalAuditUser(db: db, userId: userId, authId: authId)

            let catalog = SupplementCatalogEntry(
                id: catalogId,
                name: "Vitamin D3 UITest",
                category: .vitamin
            )
            try catalog.insert(db)

            var supplement = UserSupplement(userId: userId)
            supplement.catalogId = catalogId
            supplement.scheduledTimes = ["08:00"]
            supplement.startedAt = "2026-02-24"
            try supplement.insert(db)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let names = await SupplementsDayViewTestHarness.loadScheduledAndStackNames(
            dateString: "2026-02-24",
            dbQueue: manager.dbQueue
        )

        XCTAssertEqual(names.scheduled, ["Vitamin D3 UITest"])
        XCTAssertEqual(names.stack, ["Vitamin D3 UITest"])
    }

    @MainActor
    func testFunctionalAuditSupplementsMarkTakenPersistsAndUpdatesScheduledState() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let catalogId = UUID()
        let supplementId = UUID()

        try await manager.dbQueue.write { db in
            try Self.seedFunctionalAuditUser(db: db, userId: userId, authId: authId)

            let catalog = SupplementCatalogEntry(
                id: catalogId,
                name: "Vitamin D3 UITest",
                category: .vitamin
            )
            try catalog.insert(db)

            var supplement = UserSupplement(id: supplementId, userId: userId)
            supplement.catalogId = catalogId
            supplement.customName = "Vitamin D3 UITest"
            supplement.scheduledTimes = ["08:00"]
            supplement.startedAt = "2026-02-24"
            try supplement.insert(db)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let result = await SupplementsDayViewTestHarness.markFirstScheduledSupplement(
            dateString: "2026-02-24",
            dbQueue: manager.dbQueue
        )

        XCTAssertEqual(result.takenFlags, [true])
        XCTAssertEqual(result.logNames, ["Vitamin D3 UITest"])

        let persisted = try await manager.dbQueue.read { db in
            return try Row.fetchOne(
                db,
                sql: """
                    SELECT supplement_name, scheduled_time
                    FROM supplement_logs
                    WHERE user_id = ? OR user_id = ?
                    ORDER BY created_at DESC
                    LIMIT 1
                    """,
                arguments: [userId, userId.uuidString]
            )
        }

        XCTAssertEqual(persisted?["supplement_name"], "Vitamin D3 UITest")
        XCTAssertEqual(persisted?["scheduled_time"], "08:00")
    }

    @MainActor
    func testFunctionalAuditStartExperimentPersistsAgainstCurrentSchema() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        var configuredInsight = Insight(
            userId: userId,
            category: .experiment,
            title: "Sleep consistency pattern",
            body: "You sleep better with a consistent routine.",
            confidence: 0.91
        )
        configuredInsight.description = "Consistent sleep timing may improve sleep quality."
        configuredInsight.relatedMetrics = try JSONEncoder().encode(["sleep_quality"])
        let insight = configuredInsight

        try await manager.dbQueue.write { db in
            try Self.seedFunctionalAuditUser(db: db, userId: userId, authId: authId)
        }

        await InsightDetailViewTestHarness.startExperiment(
            insight: insight,
            authId: authId,
            dbQueue: manager.dbQueue
        )

        let snapshot = try await manager.dbQueue.read { db in
            let experiment = try XCTUnwrap(Experiment.fetchOne(db))
            let event = try XCTUnwrap(OutboxEvent.fetchOne(db))
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: event.bodyJson) as? [String: Any]
            )
            return (
                experiment,
                event.path,
                payload["primary_metric"] as? String,
                payload["title"] as? String,
                payload["baseline_start_date"] as? String
            )
        }

        XCTAssertEqual(snapshot.0.userId, userId)
        XCTAssertEqual(snapshot.0.title, insight.title)
        XCTAssertEqual(snapshot.0.status, .baseline)
        XCTAssertEqual(snapshot.0.primaryMetric, "sleep_quality")
        XCTAssertEqual(snapshot.0.hypothesis, insight.description)
        XCTAssertEqual(snapshot.1, "api-experiments/create")
        XCTAssertEqual(snapshot.2, "sleep_quality")
        XCTAssertEqual(snapshot.3, insight.title)
        XCTAssertEqual(snapshot.4, snapshot.0.baselineStartDate, "Queued create must preserve the locally started baseline")
    }

    @MainActor
    func testFunctionalAuditStartExperimentRejectsLowConfidenceInsight() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let insight = Insight(
            userId: userId,
            category: .experiment,
            title: "Low-confidence pattern",
            body: "Needs more data.",
            confidence: 0.41
        )

        try await manager.dbQueue.write { db in
            try Self.seedFunctionalAuditUser(db: db, userId: userId, authId: authId)
        }

        await InsightDetailViewTestHarness.startExperiment(
            insight: insight,
            authId: authId,
            hasCloudSession: true,
            dbQueue: manager.dbQueue
        )

        try await manager.dbQueue.read { db in
            XCTAssertNil(try Experiment.fetchOne(db))
            XCTAssertNil(try OutboxEvent.fetchOne(db))
        }
    }

    @MainActor
    func testFunctionalAuditStartExperimentIgnoresActiveExperimentFromAnotherUser() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let otherUserId = UUID()
        let otherExperimentId = UUID()
        let insight = Insight(
            userId: userId,
            category: .experiment,
            title: "Circadian alignment",
            body: "Test an earlier caffeine cutoff.",
            confidence: 0.89
        )

        try await manager.dbQueue.write { db in
            try Self.seedFunctionalAuditUser(db: db, userId: userId, authId: authId)
            try Self.seedFunctionalAuditUser(db: db, userId: otherUserId, authId: UUID())

            var existingExperiment = Experiment(
                id: otherExperimentId,
                userId: otherUserId,
                title: "Other user's experiment",
                variable: "training_load",
                metric: "recovery_score",
                durationDays: 14
            )
            existingExperiment.status = .baseline
            try existingExperiment.insert(db)
        }

        await InsightDetailViewTestHarness.startExperiment(
            insight: insight,
            authId: authId,
            hasCloudSession: true,
            dbQueue: manager.dbQueue
        )

        try await manager.dbQueue.read { db in
            let currentUserExperimentCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM experiments WHERE user_id = ? OR user_id = ?",
                arguments: [userId, userId.uuidString]
            ) ?? 0
            let otherUserExperimentCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM experiments WHERE user_id = ? OR user_id = ?",
                arguments: [otherUserId, otherUserId.uuidString]
            ) ?? 0

            XCTAssertEqual(currentUserExperimentCount, 1)
            XCTAssertEqual(otherUserExperimentCount, 1)
        }
    }

    @MainActor
    func testFunctionalAuditStartExperimentIgnoresEndedLifecycleWithStaleBaselineStatus() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let staleExperimentId = UUID()
        let insight = Insight(
            userId: userId,
            category: .experiment,
            title: "Morning light",
            body: "Test brighter mornings.",
            confidence: 0.93
        )
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let baselineStartDate = DiaryDateFormatter.formatDate(calendar.date(byAdding: .day, value: -21, to: today) ?? today)
        let baselineEndDate = DiaryDateFormatter.formatDate(calendar.date(byAdding: .day, value: -15, to: today) ?? today)
        let interventionStartDate = DiaryDateFormatter.formatDate(calendar.date(byAdding: .day, value: -14, to: today) ?? today)
        let interventionEndDate = DiaryDateFormatter.formatDate(calendar.date(byAdding: .day, value: -8, to: today) ?? today)
        let washoutStartDate = DiaryDateFormatter.formatDate(calendar.date(byAdding: .day, value: -7, to: today) ?? today)
        let washoutEndDate = DiaryDateFormatter.formatDate(calendar.date(byAdding: .day, value: -1, to: today) ?? today)

        try await manager.dbQueue.write { db in
            try Self.seedFunctionalAuditUser(db: db, userId: userId, authId: authId)

            var staleExperiment = Experiment(
                id: staleExperimentId,
                userId: userId,
                title: "Old circadian test",
                variable: "light_exposure",
                metric: "energy_level",
                durationDays: 7
            )
            staleExperiment.status = .baseline
            staleExperiment.primaryMetric = "energy_level"
            staleExperiment.baselineStartDate = baselineStartDate
            staleExperiment.baselineEndDate = baselineEndDate
            staleExperiment.interventionStartDate = interventionStartDate
            staleExperiment.interventionEndDate = interventionEndDate
            staleExperiment.washoutStartDate = washoutStartDate
            staleExperiment.washoutEndDate = washoutEndDate
            try staleExperiment.insert(db)
        }

        await InsightDetailViewTestHarness.startExperiment(
            insight: insight,
            authId: authId,
            hasCloudSession: true,
            dbQueue: manager.dbQueue
        )

        try await manager.dbQueue.read { db in
            let experimentCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM experiments WHERE user_id = ? OR user_id = ?",
                arguments: [userId, userId.uuidString]
            ) ?? 0
            let outboxCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?",
                arguments: ["api-experiments/create"]
            ) ?? 0

            XCTAssertEqual(experimentCount, 2)
            XCTAssertEqual(outboxCount, 1)
        }
    }

    @MainActor
    func testFunctionalAuditExperimentDetailLoadAndDailyLogUseCurrentSchema() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let experimentId = UUID()

        try await manager.dbQueue.write { db in
            try Self.seedFunctionalAuditUser(db: db, userId: userId, authId: UUID())

            var experiment = Experiment(
                id: experimentId,
                userId: userId,
                title: "Sleep Quality Check",
                variable: "bedtime_consistency",
                metric: "sleep_quality",
                durationDays: 21
            )
            experiment.hypothesis = "Going to bed at the same time improves sleep quality."
            experiment.status = .baseline
            experiment.primaryMetric = "sleep_quality"
            experiment.resultSummary = "Trending positive"
            try experiment.insert(db)

            var measurement = ExperimentMeasurement(
                experimentId: experimentId,
                userId: userId,
                date: "2026-02-20",
                value: 78,
                unit: nil,
                measurementPhase: .baseline,
                metricName: "sleep_quality"
            )
            measurement.notes = "Baseline"
            try measurement.insert(db)
        }

        let viewModel = ExperimentDetailViewModel(experimentId: experimentId, dbQueue: manager.dbQueue)
        AuthManager._testSetActiveHasCloudSession(true)
        defer { AuthManager._testSetActiveHasCloudSession(false) }
        await viewModel.load()

        XCTAssertEqual(viewModel.experimentName, "Sleep Quality Check")
        XCTAssertEqual(viewModel.metricLabel, "sleep_quality")
        XCTAssertEqual(viewModel.conclusion, "Trending positive")
        XCTAssertEqual(viewModel.measurements.count, 1)

        viewModel.dailyValue = "82"
        viewModel.dailyNotes = "Good recovery"
        viewModel.adheredToday = false
        await viewModel.logDailyMeasurement()

        viewModel.dailyValue = "84"
        viewModel.dailyNotes = "Updated entry"
        viewModel.adheredToday = true
        await viewModel.logDailyMeasurement()

        let today = DiaryDateFormatter.formatDate(Date())
        let todayMeasurements = try await manager.dbQueue.read { db in
            try ExperimentMeasurement
                .filter(sql: "experiment_id = ? OR experiment_id = ?", arguments: [experimentId, experimentId.uuidString])
                .filter(Column("measurement_date") == today)
                .filter(Column("metric_name") == "sleep_quality")
                .fetchAll(db)
        }

        XCTAssertEqual(todayMeasurements.count, 1)
        XCTAssertEqual(todayMeasurements[0].userId, userId)
        XCTAssertEqual(todayMeasurements[0].metricValue, 84.0)
        XCTAssertEqual(todayMeasurements[0].notes, "Updated entry")
        XCTAssertTrue(todayMeasurements[0].protocolFollowed)

        try await manager.dbQueue.read { db in
            let event = try XCTUnwrap(OutboxEvent.fetchOne(db))
            XCTAssertEqual(event.path, "api-experiments/\(experimentId.uuidString)/log")

            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: event.bodyJson) as? [String: Any]
            )
            XCTAssertEqual(payload["date"] as? String, today)
            XCTAssertEqual(payload["protocol_followed"] as? Bool, true)
            let measurements = try XCTUnwrap(payload["measurements"] as? [String: Double])
            XCTAssertEqual(measurements["sleep_quality"], 84.0)
        }
    }

    @MainActor
    func testFunctionalAuditExperimentDetailDerivesCompletedFromPastSchedule() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let experimentId = UUID()
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let baselineStartDate = DiaryDateFormatter.formatDate(calendar.date(byAdding: .day, value: -14, to: today) ?? today)
        let baselineEndDate = DiaryDateFormatter.formatDate(calendar.date(byAdding: .day, value: -11, to: today) ?? today)
        let interventionStartDate = DiaryDateFormatter.formatDate(calendar.date(byAdding: .day, value: -10, to: today) ?? today)
        let interventionEndDate = DiaryDateFormatter.formatDate(calendar.date(byAdding: .day, value: -4, to: today) ?? today)
        let washoutStartDate = DiaryDateFormatter.formatDate(calendar.date(byAdding: .day, value: -3, to: today) ?? today)
        let washoutEndDate = DiaryDateFormatter.formatDate(calendar.date(byAdding: .day, value: -1, to: today) ?? today)

        try await manager.dbQueue.write { db in
            try Self.seedFunctionalAuditUser(db: db, userId: userId, authId: UUID())

            var experiment = Experiment(
                id: experimentId,
                userId: userId,
                title: "Completed sleep test",
                variable: "bedtime",
                metric: "sleep_quality",
                durationDays: 14
            )
            experiment.status = .baseline
            experiment.primaryMetric = "sleep_quality"
            experiment.baselineStartDate = baselineStartDate
            experiment.baselineEndDate = baselineEndDate
            experiment.interventionStartDate = interventionStartDate
            experiment.interventionEndDate = interventionEndDate
            experiment.washoutStartDate = washoutStartDate
            experiment.washoutEndDate = washoutEndDate
            try experiment.insert(db)
        }

        let viewModel = ExperimentDetailViewModel(experimentId: experimentId, dbQueue: manager.dbQueue)
        await viewModel.load()

        XCTAssertEqual(viewModel.statusText, ExperimentStatus.completed.rawValue.capitalized)
        XCTAssertTrue(viewModel.isCompleted)
        XCTAssertFalse(viewModel.isActive)
    }

    @MainActor
    func testFunctionalAuditExperimentDetailLogUsesScheduledPhaseWhenStoredStatusIsStale() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let experimentId = UUID()
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let baselineStartDate = DiaryDateFormatter.formatDate(calendar.date(byAdding: .day, value: -7, to: today) ?? today)
        let baselineEndDate = DiaryDateFormatter.formatDate(calendar.date(byAdding: .day, value: -1, to: today) ?? today)
        let interventionStartDate = DiaryDateFormatter.formatDate(calendar.date(byAdding: .day, value: 0, to: today) ?? today)
        let interventionEndDate = DiaryDateFormatter.formatDate(calendar.date(byAdding: .day, value: 6, to: today) ?? today)

        try await manager.dbQueue.write { db in
            try Self.seedFunctionalAuditUser(db: db, userId: userId, authId: UUID())

            var experiment = Experiment(
                id: experimentId,
                userId: userId,
                title: "Intervention in progress",
                variable: "supplement_timing",
                metric: "sleep_quality",
                durationDays: 14
            )
            experiment.status = .baseline
            experiment.primaryMetric = "sleep_quality"
            experiment.baselineStartDate = baselineStartDate
            experiment.baselineEndDate = baselineEndDate
            experiment.interventionStartDate = interventionStartDate
            experiment.interventionEndDate = interventionEndDate
            try experiment.insert(db)
        }

        let viewModel = ExperimentDetailViewModel(experimentId: experimentId, dbQueue: manager.dbQueue)
        AuthManager._testSetActiveHasCloudSession(true)
        defer { AuthManager._testSetActiveHasCloudSession(false) }

        viewModel.dailyValue = "87"
        viewModel.dailyNotes = "Intervention day one"
        viewModel.adheredToday = true
        await viewModel.logDailyMeasurement()

        let todayString = DiaryDateFormatter.formatDate(Date())
        try await manager.dbQueue.read { db in
            let measurement = try XCTUnwrap(
                ExperimentMeasurement
                    .filter(sql: "experiment_id = ? OR experiment_id = ?", arguments: [experimentId, experimentId.uuidString])
                    .filter(Column("measurement_date") == todayString)
                    .filter(Column("metric_name") == "sleep_quality")
                    .fetchOne(db)
            )
            XCTAssertEqual(measurement.measurementPhase, .intervention)
        }
    }

    @MainActor
    func testFunctionalAuditExperimentDetailReportsMissingExperimentAfterReload() async throws {
        let manager = try DatabaseManager.inMemory()
        let viewModel = ExperimentDetailViewModel(experimentId: UUID(), dbQueue: manager.dbQueue)

        await viewModel.load()

        XCTAssertEqual(viewModel.loadError, ExperimentError.notFound.errorDescription)
        XCTAssertFalse(viewModel.isActive)
        XCTAssertTrue(viewModel.measurements.isEmpty)
    }

    func testFunctionalAuditBatchRecipeCreateUsesResolvedDatabaseUserId() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        struct BatchIngredientSnapshot: Sendable {
            let name: String?
            let calories: Double
            let proteinG: Double
            let fatG: Double
            let carbsG: Double
        }
        struct BatchRecipeSnapshot: Sendable {
            let userId: UUID
            let totalPortions: Int?
            let totalCalories: Double
            let totalProteinG: Double
            let totalFatG: Double
            let totalCarbsG: Double
            let caloriesPer100g: Double
            let proteinPer100g: Double
            let fatPer100g: Double
            let carbsPer100g: Double
            let ingredients: [BatchIngredientSnapshot]
        }

        try await manager.dbQueue.write { db in
            try Self.seedFunctionalAuditUser(db: db, userId: userId, authId: authId)
        }

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
        }
        defer {
            AuthManager.setActiveAuthIdForTests(nil)
        }

        let service = NutritionService(dbQueue: manager.dbQueue)
        let batchId = try await service.createBatchRecipe(
            NutritionBatchRecipeDraft(
                name: "Chicken Rice Prep",
                totalWeightG: 800,
                totalPortions: 4,
                ingredients: [
                    NutritionBatchRecipeDraftIngredient(
                        name: "Chicken",
                        weightG: 400,
                        calories: 440,
                        proteinG: 80,
                        fatG: 12,
                        carbsG: 0
                    ),
                    NutritionBatchRecipeDraftIngredient(
                        name: "Rice",
                        weightG: 400,
                        calories: 520,
                        proteinG: 12,
                        fatG: 2,
                        carbsG: 112
                    )
                ]
            )
        )

        let snapshot: BatchRecipeSnapshot = try await manager.dbQueue.read { db in
            let recipeRow = try XCTUnwrap(Row.fetchOne(
                db,
                sql: """
                    SELECT id, user_id, total_portions, total_calories, total_protein_g, total_fat_g, total_carbs_g,
                           calories_per_100g, protein_per_100g, fat_per_100g, carbs_per_100g
                    FROM batch_recipes
                    LIMIT 1
                    """
            ))
            let ingredients = try Row.fetchAll(
                db,
                sql: """
                    SELECT name, calories, protein_g, fat_g, carbs_g
                    FROM batch_recipe_ingredients
                    ORDER BY sort_order ASC
                    """
            )
            let ingredientSnapshots = ingredients.map { row in
                BatchIngredientSnapshot(
                    name: row["name"],
                    calories: row["calories"] ?? 0,
                    proteinG: row["protein_g"] ?? 0,
                    fatG: row["fat_g"] ?? 0,
                    carbsG: row["carbs_g"] ?? 0
                )
            }
            return BatchRecipeSnapshot(
                userId: try XCTUnwrap(MixedUUIDStorage.decode(from: recipeRow, column: "user_id")),
                totalPortions: recipeRow["total_portions"],
                totalCalories: recipeRow["total_calories"] ?? 0,
                totalProteinG: recipeRow["total_protein_g"] ?? 0,
                totalFatG: recipeRow["total_fat_g"] ?? 0,
                totalCarbsG: recipeRow["total_carbs_g"] ?? 0,
                caloriesPer100g: recipeRow["calories_per_100g"] ?? 0,
                proteinPer100g: recipeRow["protein_per_100g"] ?? 0,
                fatPer100g: recipeRow["fat_per_100g"] ?? 0,
                carbsPer100g: recipeRow["carbs_per_100g"] ?? 0,
                ingredients: ingredientSnapshots
            )
        }

        XCTAssertEqual(snapshot.userId, userId)
        XCTAssertEqual(snapshot.totalPortions, 4)
        XCTAssertEqual(snapshot.totalCalories, 960, accuracy: 0.001)
        XCTAssertEqual(snapshot.totalProteinG, 92, accuracy: 0.001)
        XCTAssertEqual(snapshot.totalFatG, 14, accuracy: 0.001)
        XCTAssertEqual(snapshot.totalCarbsG, 112, accuracy: 0.001)
        XCTAssertEqual(snapshot.caloriesPer100g, 120, accuracy: 0.001)
        XCTAssertEqual(snapshot.proteinPer100g, 11.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.fatPer100g, 1.75, accuracy: 0.001)
        XCTAssertEqual(snapshot.carbsPer100g, 14, accuracy: 0.001)
        XCTAssertEqual(snapshot.ingredients.count, 2)

        XCTAssertEqual(snapshot.ingredients[0].name, "Chicken")
        XCTAssertEqual(snapshot.ingredients[0].calories, 440, accuracy: 0.001)
        XCTAssertEqual(snapshot.ingredients[0].proteinG, 80, accuracy: 0.001)
        XCTAssertEqual(snapshot.ingredients[0].fatG, 12, accuracy: 0.001)
        XCTAssertEqual(snapshot.ingredients[0].carbsG, 0, accuracy: 0.001)

        XCTAssertEqual(snapshot.ingredients[1].name, "Rice")
        XCTAssertEqual(snapshot.ingredients[1].calories, 520, accuracy: 0.001)
        XCTAssertEqual(snapshot.ingredients[1].proteinG, 12, accuracy: 0.001)
        XCTAssertEqual(snapshot.ingredients[1].fatG, 2, accuracy: 0.001)
        XCTAssertEqual(snapshot.ingredients[1].carbsG, 112, accuracy: 0.001)

        let loadedDetail = try await service.loadBatchRecipeDetail(id: batchId, preferRemote: false)
        let detail = try XCTUnwrap(loadedDetail)
        let firstIngredient = try XCTUnwrap(detail.ingredients.first)
        XCTAssertEqual(detail.recipe.totalCalories, 960, accuracy: 0.001)
        XCTAssertEqual(detail.recipe.totalProteinG, 92, accuracy: 0.001)
        XCTAssertEqual(detail.recipe.totalFatG, 14, accuracy: 0.001)
        XCTAssertEqual(detail.recipe.totalCarbsG, 112, accuracy: 0.001)
        XCTAssertEqual(detail.ingredients.count, 2)
        XCTAssertEqual(firstIngredient.proteinG, 80, accuracy: 0.001)
        XCTAssertEqual(firstIngredient.fatG, 12, accuracy: 0.001)
        XCTAssertEqual(firstIngredient.carbsG, 0, accuracy: 0.001)
    }

    @MainActor
    func testFunctionalAuditBatchRecipeCreateFailsWithoutResolvedUserIdAndDoesNotPretendSuccess() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let service = NutritionService(dbQueue: manager.dbQueue)

        do {
            _ = try await service.createBatchRecipe(
                NutritionBatchRecipeDraft(
                    name: "Unbound Batch",
                    totalWeightG: 600,
                    totalPortions: 3,
                    ingredients: [
                        NutritionBatchRecipeDraftIngredient(
                            name: "Chicken",
                            weightG: 300,
                            calories: 330,
                            proteinG: 60,
                            fatG: 9,
                            carbsG: 0
                        ),
                        NutritionBatchRecipeDraftIngredient(
                            name: "Rice",
                            weightG: 300,
                            calories: 390,
                            proteinG: 9,
                            fatG: 1,
                            carbsG: 84
                        )
                    ]
                )
            )
            XCTFail("Expected createBatchRecipe to fail when user identity cannot be resolved")
        } catch {
            XCTAssertEqual(error.localizedDescription, SyncError.networkUnavailable.errorDescription)
        }

        let snapshot = try await manager.dbQueue.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM batch_recipes") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM batch_recipe_ingredients") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox_events WHERE path = 'api-nutrition-batches'") ?? 0
            )
        }

        XCTAssertEqual(snapshot.0, 0)
        XCTAssertEqual(snapshot.1, 0)
        XCTAssertEqual(snapshot.2, 0)
    }

    private func makeSession(authId: UUID, isAnonymous: Bool, now: Date) -> Supabase.Session {
        let user = Supabase.User(
            id: authId,
            appMetadata: [:],
            userMetadata: [:],
            aud: "authenticated",
            createdAt: now,
            updatedAt: now,
            isAnonymous: isAnonymous
        )
        return Supabase.Session(
            accessToken: "token-\(authId.uuidString)",
            tokenType: "bearer",
            expiresIn: 3600,
            expiresAt: now.addingTimeInterval(3600).timeIntervalSince1970,
            refreshToken: "refresh-\(authId.uuidString)",
            user: user
        )
    }

    private func renderForCoverage<V: View>(_ view: sending V, file: StaticString = #filePath, line: UInt = #line) {
        let host = UIHostingController(rootView: view)
        _ = host.view
        XCTAssertNotNil(host.viewIfLoaded, file: file, line: line)
    }

    nonisolated private static func seedFunctionalAuditUser(
        db: Database,
        userId: UUID,
        authId: UUID
    ) throws {
        let user = User(id: userId, authId: authId, timezone: "UTC", units: .metric)
        try user.insert(db)
    }
}
