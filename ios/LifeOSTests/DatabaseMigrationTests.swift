// MARK: - Database Migration Tests
// Verifies the full migration chain runs and stays in sync with the declared schema version.

import XCTest
@testable import LifeOS
import GRDB

final class DatabaseMigrationTests: XCTestCase {

    func testLatestSchemaVersionTracksAppliedMigrationCount() throws {
        let manager = try DatabaseManager.inMemory()

        let appliedMigrationCount = try manager.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations") ?? 0
        }

        XCTAssertGreaterThan(appliedMigrationCount, 0)
        XCTAssertEqual(Migrations.latestSchemaVersion, appliedMigrationCount)
    }

    func testFullMigrationChainCreatesAllTables() throws {
        // Given: An in-memory database
        let manager = try DatabaseManager.inMemory()

        // When: The full migrator has run (happens in inMemory())
        // Then: All expected tables exist
        let expectedTables: Set<String> = [
            // Sync
            "local_meta", "sync_state", "outbox_events", "sync_row_state",
            // User
            "users", "user_health_flags", "notification_settings",
            // Recovery
            "physiological_states", "timezone_history",
            // Nutrition
            "food_logs", "food_items", "daily_nutrition_targets",
            "food_catalog_items", "user_foods", "user_food_favorites",
            "batch_recipes", "batch_recipe_ingredients", "meal_templates",
            // Training
            "exercise_catalog", "training_plans", "workout_sessions",
            "workout_exercises", "workout_sets",
            "training_plan_sessions", "training_loads",
            // Supplements
            "supplement_catalog", "user_supplements", "supplement_logs",
            // Health
            "wellness_checks", "body_composition", "hydration_logs",
            // Labs
            "medical_scans", "health_measurements",
            // AI
            "insights", "experiments", "experiment_measurements",
            "recommendations", "weekly_strategy_reports", "vector_memory",
            "deletion_audit_log", "deletion_failures", "export_jobs",
            // Health reference
            "health_marker_catalog", "health_diagnoses",
            // V2 templates + analytics
            "training_templates", "analytics_events",
            "ai_cache",
            "consent_records",
            // Onboarding & Privacy
            "onboarding_state", "user_baselines", "privacy_settings",
            // V24 feature flags + guardian
            "feature_flags_cache", "screen_time_events",
            // Misc support
            "sleep_logs", "notification_log", "menstrual_logs",
        ]

        try manager.dbQueue.read { db in
            for table in expectedTables {
                XCTAssertTrue(
                    try db.tableExists(table),
                    "Table '\(table)' should exist after the full migration chain"
                )
            }
        }
    }

    func testInsertAndQueryUser() throws {
        let manager = try DatabaseManager.inMemory()

        let user = User(
            id: UUID(),
            authId: UUID(),
            timezone: "America/New_York",
            units: .metric
        )

        try manager.dbQueue.write { db in
            try user.insert(db)
        }

        let fetched = try manager.dbQueue.read { db in
            try User
                .filter(Column("id") == user.id.uuidString)
                .fetchOne(db)
        }

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.authId, user.authId)
        XCTAssertEqual(fetched?.timezone, "America/New_York")
    }

    func testInsertAndQueryFoodLog() throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()

        // Insert user first (foreign key)
        let user = User(id: userId, authId: UUID())
        try manager.dbQueue.write { db in
            try user.insert(db)
        }

        let log = FoodLog(
            id: UUID(),
            userId: userId,
            loggedDate: "2026-02-16",
            inputMethod: .manual,
            calories: 500,
            proteinG: 30,
            fatG: 20,
            carbsG: 50
        )

        try manager.dbQueue.write { db in
            try log.insert(db)
        }

        let count = try manager.dbQueue.read { db in
            try FoodLog.fetchCount(db)
        }
        XCTAssertEqual(count, 1)
    }

    func testSleepLogDecodesWithSleepDateOnlyPayload() throws {
        let userId = UUID()
        let json = """
            [{
                "id": "11111111-1111-1111-1111-111111111111",
                "user_id": "\(userId.uuidString)",
                "sleep_date": "2026-02-22",
                "created_at": "2026-02-22T12:00:00Z",
                "updated_at": "2026-02-22T12:00:00Z",
                "caffeine_after_14": true,
                "source": "manual"
            }]
            """

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        let logs = try decoder.decode([SleepLog].self, from: Data(json.utf8))
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs.first?.date, "2026-02-22")
        XCTAssertEqual(logs.first?.sleepDate, "2026-02-22")
        XCTAssertEqual(logs.first?.caffeineAfter14, true)
    }

    func testSleepLogInsertUsesSnakeCaseColumns() throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()

        try manager.dbQueue.write { db in
            let user = User(id: userId, authId: UUID())
            try user.insert(db)
        }

        let log = SleepLog(id: UUID(), userId: userId, date: "2026-02-22", source: .manual)
        try manager.dbQueue.write { db in
            try log.insert(db)
        }

        try manager.dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT date, sleep_date
                    FROM sleep_logs
                    ORDER BY updated_at DESC
                    LIMIT 1
                    """,
                arguments: []
            )

            let storedDate: String? = row?["date"]
            let storedSleepDate: String? = row?["sleep_date"]

            XCTAssertEqual(storedDate, "2026-02-22")
            XCTAssertEqual(storedSleepDate, "2026-02-22")
        }
    }

    func testExperimentsSoftDeleteColumnsExist() throws {
        let manager = try DatabaseManager.inMemory()

        try manager.dbQueue.read { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(experiments)")
            let names = Set(columns.compactMap { $0["name"] as String? })
            XCTAssertTrue(names.contains("deleted_at"))
            XCTAssertTrue(names.contains("deleted_reason"))
            XCTAssertTrue(names.contains("primary_metric"))
            XCTAssertTrue(names.contains("measurement_frequency"))
            XCTAssertTrue(names.contains("effect_size"))
            XCTAssertTrue(names.contains("ai_recommendation"))
        }
    }

    func testExperimentMeasurementParityColumnsExist() throws {
        let manager = try DatabaseManager.inMemory()

        try manager.dbQueue.read { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(experiment_measurements)")
            let names = Set(columns.compactMap { $0["name"] as String? })
            XCTAssertTrue(names.contains("measurement_date"))
            XCTAssertTrue(names.contains("measurement_phase"))
            XCTAssertTrue(names.contains("metric_name"))
            XCTAssertTrue(names.contains("metric_value"))
            XCTAssertTrue(names.contains("metric_unit"))
            XCTAssertTrue(names.contains("protocol_followed"))
        }
    }

    func testOutboxEventEnqueue() throws {
        let manager = try DatabaseManager.inMemory()
        let syncEngine = SyncEngine(dbQueue: manager.dbQueue)

        let event = OutboxEvent(
            httpMethod: .POST,
            path: "api-food-log",
            bodyJson: "{}".data(using: .utf8)!
        )

        let expectation = expectation(description: "enqueue")
        Task {
            try await syncEngine.enqueueMutation(event)
            let count = try await syncEngine.pendingEventCount()
            XCTAssertEqual(count, 1)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    func testConfidenceTriggerForInsightsSetsNeedsReview() throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let insightId = UUID()

        try manager.dbQueue.write { db in
            let user = User(id: userId, authId: UUID())
            try user.insert(db)

            var insight = Insight(
                id: insightId,
                userId: userId,
                category: .health,
                title: "t",
                body: "b",
                confidence: 0.40
            )
            // Trigger should elevate this to true on insert.
            insight.needsReview = false
            insight.shownToUser = false
            insight.actedUpon = false
            try insight.insert(db)
        }

        let needsReview = try manager.dbQueue.read { db in
            try Insight
                .filter(Column("id") == insightId.uuidString)
                .fetchOne(db)?
                .needsReview ?? false
        }

        XCTAssertTrue(needsReview)
    }

    func testSchemaParityColumnsExistForCriticalTables() throws {
        let manager = try DatabaseManager.inMemory()

        try manager.dbQueue.read { db in
            func columns(for table: String) throws -> Set<String> {
                let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                return Set(rows.compactMap { $0["name"] as String? })
            }

            let foodLogColumns = try columns(for: "food_logs")
            XCTAssertTrue(foodLogColumns.contains("location_lat"))
            XCTAssertTrue(foodLogColumns.contains("location_lng"))

            let sleepColumns = try columns(for: "sleep_logs")
            XCTAssertTrue(sleepColumns.contains("sleep_date"))
            XCTAssertTrue(sleepColumns.contains("bedtime_actual"))
            XCTAssertTrue(sleepColumns.contains("waketime"))
            XCTAssertTrue(sleepColumns.contains("perceived_quality"))

            let insightColumns = try columns(for: "insights")
            XCTAssertTrue(insightColumns.contains("reasoning"))
            XCTAssertTrue(insightColumns.contains("confidence_score"))
            XCTAssertTrue(insightColumns.contains("shown_to_user"))

            let scanColumns = try columns(for: "medical_scans")
            XCTAssertTrue(scanColumns.contains("extraction_status"))
            XCTAssertTrue(scanColumns.contains("processed_data"))
            XCTAssertTrue(scanColumns.contains("scheduled_deletion_at"))

            let flagsColumns = try columns(for: "user_health_flags")
            XCTAssertTrue(flagsColumns.contains("disable_hrv"))
            XCTAssertTrue(flagsColumns.contains("hide_calories"))
            XCTAssertTrue(flagsColumns.contains("pregnancy_mode"))

            let privacyColumns = try columns(for: "privacy_settings")
            XCTAssertTrue(privacyColumns.contains("cloud_backup_enabled"))

            let notificationColumns = try columns(for: "notification_log")
            XCTAssertTrue(notificationColumns.contains("user_id"))
            XCTAssertTrue(notificationColumns.contains("body"))
            XCTAssertTrue(notificationColumns.contains("delivered_date_local"))
            XCTAssertTrue(notificationColumns.contains("timezone"))

            let exportColumns = try columns(for: "export_jobs")
            XCTAssertTrue(exportColumns.contains("status"))
            XCTAssertTrue(exportColumns.contains("requested_at"))

            let deletionAuditColumns = try columns(for: "deletion_audit_log")
            XCTAssertTrue(deletionAuditColumns.contains("user_id_deleted"))
            XCTAssertTrue(deletionAuditColumns.contains("deleted_at"))

            let deletionFailureColumns = try columns(for: "deletion_failures")
            XCTAssertTrue(deletionFailureColumns.contains("failure_type"))
            XCTAssertTrue(deletionFailureColumns.contains("error"))
        }
    }

    func testV22MedicalScanTypeCanonicalizationMigrationNormalizesLegacyRowsAndOutboxPayloads() throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let bloodworkScanId = UUID()
        let urineScanId = UUID()
        let outboxId = UUID()
        let now = Date()

        try manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [userId, authId, "UTC", "metric", now, now]
            )

            try db.execute(
                sql: """
                    INSERT INTO medical_scans (
                        id, user_id, scan_type, status, user_reviewed, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [bloodworkScanId, userId, "bloodwork", "completed", false, now, now]
            )

            try db.execute(
                sql: """
                    INSERT INTO medical_scans (
                        id, user_id, scan_type, status, user_reviewed, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [urineScanId, userId, "urine", "completed", false, now, now]
            )

            try db.execute(
                sql: """
                    INSERT INTO outbox_events (
                        id, created_at_local, updated_at_local, status, priority,
                        http_method, path, headers_json, body_json, idempotency_key,
                        attempt_count, user_visible_blocker
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    outboxId.uuidString,
                    now,
                    now,
                    "pending",
                    100,
                    "POST",
                    "rest/v1/medical_scans",
                    Data("{}".utf8),
                    Data("""
                        {
                          "id": "\(bloodworkScanId.uuidString)",
                          "user_id": "\(userId.uuidString)",
                          "scan_type": "bloodwork",
                          "created_at": "2026-03-15T00:00:00.000Z",
                          "updated_at": "2026-03-15T00:00:00.000Z"
                        }
                        """.utf8),
                    outboxId.uuidString,
                    0,
                    false,
                ]
            )

            try Migrations._testApplyV22MedicalScanTypeCanonicalizationMigration(db: db)
        }

        try manager.dbQueue.read { db in
            let canonicalTypes = try String.fetchAll(
                db,
                sql: """
                    SELECT scan_type
                    FROM medical_scans
                    ORDER BY id
                    """
            )
            XCTAssertEqual(Set(canonicalTypes), ["blood_test", "other"])

            let outboxRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT body_json
                    FROM outbox_events
                    WHERE id = ?
                    """,
                arguments: [outboxId.uuidString]
            )
            let outboxBody: Data? = outboxRow?["body_json"]
            XCTAssertNotNil(outboxBody)

            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try XCTUnwrap(outboxBody)) as? [String: Any]
            )
            XCTAssertEqual(object["scan_type"] as? String, "blood_test")
        }
    }

    func testNotificationCriticalOnlyTriggerForcesAdvisoryAndDisablesFocus() throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let settingsId = UUID()

        try manager.dbQueue.write { db in
            let user = User(id: userId, authId: UUID())
            try user.insert(db)

            var settings = NotificationSettings(id: settingsId, userId: userId)
            settings.criticalOnly = true
            settings.controlLevel = .guardian
            settings.focusControlEnabled = true
            try settings.insert(db)
        }

        let stateAfterInsert = try manager.dbQueue.read { db in
            try NotificationSettings
                .filter(Column("id") == settingsId.uuidString)
                .fetchOne(db)
        }
        XCTAssertEqual(stateAfterInsert?.controlLevel, .advisory)
        XCTAssertEqual(stateAfterInsert?.focusControlEnabled, false)

        try manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE notification_settings
                    SET control_level = 'guardian',
                        focus_control_enabled = 1,
                        critical_only = 1
                    WHERE id = ?
                    """,
                arguments: [settingsId]
            )
        }

        let stateAfterUpdate = try manager.dbQueue.read { db in
            try NotificationSettings
                .filter(Column("id") == settingsId.uuidString)
                .fetchOne(db)
        }
        XCTAssertEqual(stateAfterUpdate?.controlLevel, .advisory)
        XCTAssertEqual(stateAfterUpdate?.focusControlEnabled, false)
    }

    func testTrainingPlanSessionStatusCanonicalizationMigrationNormalizesLegacyValues() throws {
        let dbQueue = try DatabaseQueue(path: ":memory:")

        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE training_plan_sessions (
                    id TEXT PRIMARY KEY NOT NULL,
                    status TEXT
                )
                """)
            try db.execute(
                sql: """
                    INSERT INTO training_plan_sessions (id, status)
                    VALUES (?, ?), (?, ?), (?, ?)
                    """,
                arguments: [
                    UUID().uuidString, "scheduled",
                    UUID().uuidString, "modified",
                    UUID().uuidString, "completed"
                ]
            )

            try Migrations._testApplyV26TrainingPlanSessionStatusCanonicalizationMigration(db: db)

            let statuses = try String.fetchAll(
                db,
                sql: "SELECT status FROM training_plan_sessions ORDER BY status ASC"
            )
            XCTAssertEqual(statuses, ["completed", "planned", "rescheduled"])
        }
    }
}
