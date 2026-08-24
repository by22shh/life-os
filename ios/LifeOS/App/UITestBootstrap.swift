import Foundation
import GRDB
import OSLog

private let uiTestBootstrapLogger = Logger(subsystem: "LifeOS", category: "UITestBootstrap")

enum UITestBootstrap {
    private static let defaultAuthId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let defaultUserId = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private static let nutritionCatalogId = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
    private static let nutritionMealLogId = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
    private static let nutritionTargetId = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!
    private static let trainingBenchId = UUID(uuidString: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD")!
    private static let trainingSquatId = UUID(uuidString: "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE")!
    private static let supplementCatalogId = UUID(uuidString: "F0F0F0F0-F0F0-4F0F-8F0F-F0F0F0F0F0F0")!
    private static let userSupplementId = UUID(uuidString: "ABABABAB-ABAB-4BAB-8BAB-ABABABABABAB")!
    private static let insightId = UUID(uuidString: "CDCDCDCD-CDCD-4DCD-8DCD-CDCDCDCDCDCD")!
    private static let args = ProcessInfo.processInfo.arguments

    static var isEnabled: Bool {
        flag(
            envKey: "LIFEOS_UI_TEST_BOOTSTRAP",
            argumentPrefix: "--lifeos-ui-test-bootstrap="
        )
    }

    static var disableBackgroundWork: Bool {
        flag(
            envKey: "LIFEOS_UI_TEST_DISABLE_BACKGROUND",
            argumentPrefix: "--lifeos-ui-test-disable-background="
        )
    }

    static var requestedAuthState: AuthState? {
        guard let raw = value(
            envKey: "LIFEOS_UI_TEST_AUTH_STATE",
            argumentPrefix: "--lifeos-ui-test-auth-state="
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return nil
        }

        switch raw {
        case "authenticated":
            return .authenticated
        case "needs_onboarding", "needsonboarding", "needs-onboarding":
            return .needsOnboarding
        case "anonymous":
            return .anonymous
        case "signed_out", "signedout", "signed-out":
            return .signedOut
        default:
            return nil
        }
    }

    static var authId: UUID {
        guard let raw = value(
            envKey: "LIFEOS_UI_TEST_AUTH_ID",
            argumentPrefix: "--lifeos-ui-test-auth-id="
        ),
              let id = UUID(uuidString: raw) else {
            return defaultAuthId
        }
        return id
    }

    static var userId: UUID {
        guard let raw = value(
            envKey: "LIFEOS_UI_TEST_USER_ID",
            argumentPrefix: "--lifeos-ui-test-user-id="
        ),
              let id = UUID(uuidString: raw) else {
            return defaultUserId
        }
        return id
    }

    static var shouldSeedSyncBlocker: Bool {
        flag(
            envKey: "LIFEOS_UI_TEST_SEED_SYNC_BLOCKER",
            argumentPrefix: "--lifeos-ui-test-seed-sync-blocker="
        )
    }

    static var shouldSeedNutritionScenario: Bool {
        flag(
            envKey: "LIFEOS_UI_TEST_SEED_NUTRITION",
            argumentPrefix: "--lifeos-ui-test-seed-nutrition="
        )
    }

    static var shouldSeedTrainingScenario: Bool {
        flag(
            envKey: "LIFEOS_UI_TEST_SEED_TRAINING",
            argumentPrefix: "--lifeos-ui-test-seed-training="
        )
    }

    static var shouldSeedSupplementsScenario: Bool {
        flag(
            envKey: "LIFEOS_UI_TEST_SEED_SUPPLEMENTS",
            argumentPrefix: "--lifeos-ui-test-seed-supplements="
        )
    }

    static var shouldSeedInsightsScenario: Bool {
        flag(
            envKey: "LIFEOS_UI_TEST_SEED_INSIGHTS",
            argumentPrefix: "--lifeos-ui-test-seed-insights="
        )
    }

    static var seedDate: String {
        if let explicit = value(
            envKey: "LIFEOS_UI_TEST_SEED_DATE",
            argumentPrefix: "--lifeos-ui-test-seed-date="
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
           isLocalDate(explicit) {
            return explicit
        }

        if let url = initialURL,
           let date = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "date" })?
            .value,
           isLocalDate(date) {
            return date
        }

        return "2026-02-24"
    }

    static var initialURL: URL? {
        guard let raw = value(
            envKey: "LIFEOS_UI_TEST_INITIAL_URL",
            argumentPrefix: "--lifeos-ui-test-initial-url="
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw),
              url.scheme == "lifeos" else {
            return nil
        }
        return url
    }

    static func seedLocalDataIfNeeded(dbQueue: DatabaseQueue) {
        guard isEnabled else { return }

        do {
            try dbQueue.write { db in
                guard try canSeed(db: db) else { return }
                try upsertUser(db: db)
                try ensureNotificationSettings(db: db)
                try ensurePrivacySettings(db: db)
                if shouldSeedSyncBlocker {
                    try ensureSyncBlocker(db: db)
                }
                if shouldSeedNutritionScenario {
                    try ensureNutritionScenarioSeed(db: db)
                }
                if shouldSeedTrainingScenario {
                    try ensureTrainingScenarioSeed(db: db)
                }
                if shouldSeedSupplementsScenario {
                    try ensureSupplementsScenarioSeed(db: db)
                }
                if shouldSeedInsightsScenario {
                    try ensureInsightsScenarioSeed(db: db)
                }
            }
        } catch {
            #if DEBUG
            uiTestBootstrapLogger.debug("Seeding failed: \(error.localizedDescription, privacy: .private)")
            #endif
        }
    }

    private static func canSeed(db: Database) throws -> Bool {
        let requiredTables = shouldSeedSyncBlocker
            ? ["users", "notification_settings", "privacy_settings", "outbox_events"]
            : ["users", "notification_settings", "privacy_settings"]

        for table in requiredTables {
            let exists = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM sqlite_master
                    WHERE type = 'table' AND name = ?
                    """,
                arguments: [table]
            ) ?? 0
            if exists == 0 {
                return false
            }
        }

        return true
    }

    private static func upsertUser(db: Database) throws {
        var user = User(id: userId, authId: authId, timezone: "UTC", units: .metric)
        user.email = "ui-tests@lifeos.local"
        user.notificationEnabled = true
        user.deletionInProgress = false
        user.calibrationDaysRemaining = 3
        user.onboardingCompleted = requestedAuthState == .authenticated
        user.updatedAt = Date()

        try user.save(db)
        try db.execute(
            sql: """
                DELETE FROM users
                WHERE (auth_id = ? OR auth_id = ?)
                  AND NOT (id = ? OR id = ?)
                """,
            arguments: [authId, authId.uuidString, user.id, user.id.uuidString]
        )
    }

    private static func ensureNotificationSettings(db: Database) throws {
        // Wipe settings tables for deterministic UI test state regardless of
        // historical UUID storage representation.
        try db.execute(sql: "DELETE FROM notification_settings")

        var settings = NotificationSettings(userId: userId)
        settings.updatedAt = Date()
        try settings.insert(db)
    }

    private static func ensurePrivacySettings(db: Database) throws {
        try db.execute(sql: "DELETE FROM privacy_settings")

        var settings = PrivacySettings(userId: userId)
        settings.updatedAt = Date()
        try settings.insert(db)
    }

    private static func ensureSyncBlocker(db: Database) throws {
        // Keep UI tests deterministic across repeated runs by removing stale blockers
        // from prior executions (for example rows already cancelled by dismiss flow).
        try db.execute(
            sql: "DELETE FROM outbox_events WHERE user_visible_blocker = 1"
        )

        var blocker = OutboxEvent(
            httpMethod: .POST,
            path: "api-food-log",
            bodyJson: Data("{}".utf8),
            priority: 20
        )
        blocker.status = .failedPermanent
        blocker.attemptCount = RetryConfig.maxAttempts
        blocker.userVisibleBlocker = true
        blocker.lastErrorCategory = .validation
        blocker.lastErrorCode = "422"
        blocker.lastErrorMessage = "UI test seeded sync blocker"
        blocker.updatedAtLocal = Date().addingTimeInterval(-60)
        blocker.createdAtLocal = Date().addingTimeInterval(-120)
        try blocker.insert(db)
    }

    private static func ensureNutritionScenarioSeed(db: Database) throws {
        guard try tablesExist(
            db: db,
            names: ["food_logs", "daily_nutrition_targets", "food_catalog_items"]
        ) else {
            return
        }

        try deleteUUIDMatch(db: db, table: "food_logs", column: "id", id: nutritionMealLogId)
        try deleteUUIDMatch(db: db, table: "daily_nutrition_targets", column: "id", id: nutritionTargetId)
        try deleteUUIDMatch(db: db, table: "food_catalog_items", column: "id", id: nutritionCatalogId)

        var target = DailyNutritionTarget(id: nutritionTargetId, userId: userId, date: seedDate)
        target.finalCalories = 1900
        target.finalProteinG = 140
        try target.insert(db)

        var meal = FoodLog(
            id: nutritionMealLogId,
            userId: userId,
            loggedAt: seededDate(hour: 8, minute: 15),
            loggedDate: seedDate,
            inputMethod: .manual,
            calories: 520,
            proteinG: 28,
            fatG: 18,
            carbsG: 54
        )
        meal.mealType = .breakfast
        meal.aiConfidence = 0.95
        try meal.insert(db)

        var catalog = FoodCatalogItem(
            id: nutritionCatalogId,
            provider: .openFoodFacts,
            name: "Banana Bread UITest",
            caloriesPer100g: 310,
            proteinPer100g: 8,
            fatPer100g: 10,
            carbsPer100g: 48
        )
        catalog.brand = "UITest Bakery"
        catalog.barcode = "4601230000001"
        catalog.servingSizeG = 100
        try catalog.insert(db)
    }

    private static func ensureTrainingScenarioSeed(db: Database) throws {
        guard try tablesExist(db: db, names: ["exercise_catalog"]) else {
            return
        }

        try deleteUUIDMatch(db: db, table: "exercise_catalog", column: "id", id: trainingBenchId)
        try deleteUUIDMatch(db: db, table: "exercise_catalog", column: "id", id: trainingSquatId)

        let bench = ExerciseCatalogEntry(id: trainingBenchId, name: "Bench Press UITest", category: .strength)
        let squat = ExerciseCatalogEntry(id: trainingSquatId, name: "Back Squat UITest", category: .strength)
        try bench.insert(db)
        try squat.insert(db)
    }

    private static func ensureSupplementsScenarioSeed(db: Database) throws {
        guard try tablesExist(
            db: db,
            names: ["supplement_catalog", "user_supplements", "supplement_logs"]
        ) else {
            return
        }

        try deleteUUIDMatch(db: db, table: "supplement_logs", column: "user_supplement_id", id: userSupplementId)
        try deleteUUIDMatch(db: db, table: "user_supplements", column: "id", id: userSupplementId)
        try deleteUUIDMatch(db: db, table: "supplement_catalog", column: "id", id: supplementCatalogId)

        let now = Date()
        try db.execute(
            sql: """
                INSERT INTO supplement_catalog
                    (id, name, category, description, best_time, take_with_food,
                     evidence_level, primary_benefits, avoid_with, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                supplementCatalogId.uuidString,
                "Vitamin D3 UITest",
                "vitamin",
                nil,
                nil,
                false,
                nil,
                "[]",
                "[]",
                now,
                now
            ]
        )

        try db.execute(
            sql: """
                INSERT INTO user_supplements
                    (id, user_id, catalog_id, custom_name, dose_amount, dose_unit, frequency,
                     scheduled_times, days_of_week, take_with_food, notes, active,
                     started_at, ended_at, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                userSupplementId.uuidString,
                userId.uuidString,
                supplementCatalogId.uuidString,
                "Vitamin D3 UITest",
                nil,
                "mg",
                "daily",
                "[\"08:00\"]",
                nil,
                false,
                nil,
                true,
                seedDate,
                nil,
                now,
                now
            ]
        )
    }

    private static func ensureInsightsScenarioSeed(db: Database) throws {
        guard try tablesExist(db: db, names: ["insights"]) else {
            return
        }

        try deleteUUIDMatch(db: db, table: "insights", column: "id", id: insightId)

        let now = Date()
        try db.execute(
            sql: """
                INSERT INTO insights
                    (id, user_id, category, title, body, confidence, priority,
                     actionable, description, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                insightId.uuidString,
                userId.uuidString,
                "experiment",
                "Caffeine Timing UITest",
                "Try moving caffeine earlier to protect sleep quality.",
                0.91,
                2,
                true,
                "Shift caffeine before noon and compare sleep quality.",
                now,
                now
            ]
        )
    }

    private static func tablesExist(db: Database, names: [String]) throws -> Bool {
        try names.allSatisfy { name in
            try tableExists(db: db, name: name)
        }
    }

    private static func tableExists(db: Database, name: String) throws -> Bool {
        let exists = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM sqlite_master
                WHERE type = 'table' AND name = ?
                """,
            arguments: [name]
        ) ?? 0
        return exists > 0
    }

    private static func deleteUUIDMatch(db: Database, table: String, column: String, id: UUID) throws {
        try db.execute(
            sql: "DELETE FROM \(table) WHERE \(column) = ? OR \(column) = ?",
            arguments: [id, id.uuidString]
        )
    }

    private static func seededDate(hour: Int, minute: Int) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: "\(seedDate) \(String(format: "%02d:%02d", hour, minute))") ?? Date()
    }

    private static func isLocalDate(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    private static func flag(envKey: String, argumentPrefix: String) -> Bool {
        value(envKey: envKey, argumentPrefix: argumentPrefix) == "1"
    }

    private static func value(envKey: String, argumentPrefix: String) -> String? {
        if let fromEnv = ProcessInfo.processInfo.environment[envKey], !fromEnv.isEmpty {
            return fromEnv
        }

        let matchedArgument = args.first { $0.hasPrefix(argumentPrefix) }
        return matchedArgument.map { String($0.dropFirst(argumentPrefix.count)) }
    }
}

#if DEBUG
extension UITestBootstrap {
    static func _testValue(envKey: String, argumentPrefix: String) -> String? {
        value(envKey: envKey, argumentPrefix: argumentPrefix)
    }
}
#endif
