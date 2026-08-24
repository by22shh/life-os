// MARK: - Sync Engine Models
// Source of truth: life_os_sync_engine_spec.md §4

import Foundation

// MARK: - Outbox Event

/// Queue of write intents for offline-first sync.
/// id is also used as the default Idempotency-Key header.
struct OutboxEvent: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var createdAtLocal: Date
    var updatedAtLocal: Date

    var status: OutboxStatus
    var priority: Int                   // Lower = earlier; default 100
    var dependsOn: UUID?                // Enforce ordering when required

    // Request envelope
    var httpMethod: HTTPMethod
    var path: String                    // e.g., "api-settings-privacy"
    var headersJson: Data               // Must include Idempotency-Key, X-Device-Id
    var bodyJson: Data                  // Must include client-generated IDs for creates
    var idempotencyKey: String

    // Tracking
    var attemptCount: Int
    var nextAttemptAt: Date?
    var lastAttemptAt: Date?
    var lastErrorCategory: ErrorCategory?
    var lastErrorCode: String?
    var lastErrorMessage: String?

    // UX hints
    var userVisibleBlocker: Bool
    var uiHintJson: Data?              // Deep link target + copy_id

    init(
        id: UUID = UUID(),
        httpMethod: HTTPMethod,
        path: String,
        headersJson: Data = Data(),
        bodyJson: Data = Data(),
        priority: Int = 100,
        idempotencyKey: String? = nil
    ) {
        self.id = id
        self.createdAtLocal = Date()
        self.updatedAtLocal = Date()
        self.status = .pending
        self.priority = priority
        self.httpMethod = httpMethod
        self.path = path
        self.headersJson = headersJson
        self.bodyJson = bodyJson
        self.idempotencyKey = idempotencyKey ?? id.uuidString
        self.attemptCount = 0
        self.userVisibleBlocker = false
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createdAtLocal = "created_at_local"
        case updatedAtLocal = "updated_at_local"
        case status
        case priority
        case dependsOn = "depends_on"
        case httpMethod = "http_method"
        case path
        case headersJson = "headers_json"
        case bodyJson = "body_json"
        case idempotencyKey = "idempotency_key"
        case attemptCount = "attempt_count"
        case nextAttemptAt = "next_attempt_at"
        case lastAttemptAt = "last_attempt_at"
        case lastErrorCategory = "last_error_category"
        case lastErrorCode = "last_error_code"
        case lastErrorMessage = "last_error_message"
        case userVisibleBlocker = "user_visible_blocker"
        case uiHintJson = "ui_hint_json"
    }
}

// MARK: - Outbox Status

enum OutboxStatus: String, Codable, Sendable {
    case pending
    case inFlight = "in_flight"
    case succeeded
    case failedRetryable = "failed_retryable"
    case failedPermanent = "failed_permanent"
    case cancelled
}

enum OutboxSLOAlertSeverity: String, Codable, Sendable {
    case none
    case warning
    case critical
}

struct OutboxSLOSnapshot: Sendable, Equatable {
    let totalEvents: Int
    let pendingEvents: Int
    let inFlightEvents: Int
    let succeededEvents: Int
    let retryableFailures: Int
    let permanentFailures: Int
    let windowHours: Int
    let evaluatedAt: Date

    var failureRate: Double {
        guard totalEvents > 0 else { return 0 }
        return Double(retryableFailures + permanentFailures) / Double(totalEvents)
    }

    var deadLetterRate: Double {
        guard totalEvents > 0 else { return 0 }
        return Double(permanentFailures) / Double(totalEvents)
    }
}

struct OutboxSLOEvaluation: Sendable, Equatable {
    let snapshot: OutboxSLOSnapshot
    let severity: OutboxSLOAlertSeverity
}

// MARK: - HTTP Method

enum HTTPMethod: String, Codable, Sendable {
    case POST
    case PUT
    case PATCH
    case DELETE
}

// MARK: - Error Category

enum ErrorCategory: String, Codable, Sendable {
    case network
    case auth
    case validation
    case server
    case rateLimited = "rate_limited" // P3 #25: HTTP 429 with Retry-After
    case unknown
}

// MARK: - Sync State

/// Per-table pull cursor. Tracks sync watermarks.
struct SyncState: Codable, Equatable, Sendable, Identifiable {
    var id: String { tableName }        // tableName is the PK
    var tableName: String
    var lastPulledAtServer: Date?       // Last server updated_at watermark
    var lastPullAttemptAt: Date?
    var lastPullSuccessAt: Date?
    var lastErrorCode: String?

    init(tableName: String) {
        self.tableName = tableName
    }

    enum CodingKeys: String, CodingKey {
        case tableName = "table_name"
        case lastPulledAtServer = "last_pulled_at_server"
        case lastPullAttemptAt = "last_pull_attempt_at"
        case lastPullSuccessAt = "last_pull_success_at"
        case lastErrorCode = "last_error_code"
    }
}

// MARK: - Local Meta

/// Device-level metadata. device_id is persisted in Keychain.
struct LocalMeta: Codable, Equatable, Sendable {
    var deviceId: UUID
    var schemaVersion: Int

    init(deviceId: UUID, schemaVersion: Int = 1) {
        self.deviceId = deviceId
        self.schemaVersion = schemaVersion
    }

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case schemaVersion = "schema_version"
    }
}

// MARK: - Server Timestamp Mirror

/// Per-row mirror of the latest server `updated_at` seen by the client.
/// Keeps server-authoritative merge cursors outside domain tables.
struct SyncRowCursor: Codable, Equatable, Sendable, Identifiable {
    var id: String { "\(tableName):\(rowId)" }
    var tableName: String
    var rowId: String
    var updatedAtServer: Date

    init(tableName: String, rowId: String, updatedAtServer: Date) {
        self.tableName = tableName
        self.rowId = rowId
        self.updatedAtServer = updatedAtServer
    }

    enum CodingKeys: String, CodingKey {
        case tableName = "table_name"
        case rowId = "row_id"
        case updatedAtServer = "updated_at_server"
    }
}

// MARK: - Retry Configuration

/// Backoff configuration per sync engine spec §8.2
enum RetryConfig {
    /// Base delay: 10 seconds
    static let baseDelaySeconds: TimeInterval = 10
    /// Multiplier: ×2
    static let multiplier: Double = 2.0
    /// Max delay: 30 minutes
    static let maxDelaySeconds: TimeInterval = 30 * 60
    /// Jitter: ±20%
    static let jitterRange: ClosedRange<Double> = 0.8...1.2
    /// Attempt cap: 10
    static let maxAttempts: Int = 10

    /// Calculate next retry delay with exponential backoff + jitter.
    static func delay(forAttempt attempt: Int) -> TimeInterval {
        let exponential = baseDelaySeconds * pow(multiplier, Double(attempt))
        let capped = min(exponential, maxDelaySeconds)
        let jitter = Double.random(in: jitterRange)
        return capped * jitter
    }
}

// MARK: - Syncable Tables

/// List of tables involved in sync, per sync engine spec §6.1
enum SyncableTable: String, CaseIterable, Sendable {
    // Core
    case users = "users"
    case physiologicalStates = "physiological_states"
    case sleepLogs = "sleep_logs"

    // Nutrition
    case foodLogs = "food_logs"
    case foodItems = "food_items"
    case userFoods = "user_foods"
    case userFoodFavorites = "user_food_favorites"
    case mealTemplates = "meal_templates"
    case batchRecipes = "batch_recipes"
    case batchRecipeIngredients = "batch_recipe_ingredients"

    // Training
    case workoutSessions = "workout_sessions"
    case workoutExercises = "workout_exercises"
    case workoutSets = "workout_sets"
    case trainingPlans = "training_plans"
    case trainingPlanSessions = "training_plan_sessions"
    case trainingLoads = "training_loads"

    // Supplements
    case userSupplements = "user_supplements"
    case supplementLogs = "supplement_logs"

    // Health
    case menstrualLogs = "menstrual_logs"
    case wellnessChecks = "wellness_checks"
    case bodyComposition = "body_composition"
    case hydrationLogs = "hydration_logs"

    // Labs
    case medicalScans = "medical_scans"
    case healthMeasurements = "health_measurements"
    case healthDiagnoses = "health_diagnoses"
    case healthMarkerCatalog = "health_marker_catalog"

    // AI
    case experiments = "experiments"
    case experimentMeasurements = "experiment_measurements"
    case recommendations = "recommendations"
    case weeklyStrategyReports = "weekly_strategy_reports"
    case vectorMemory = "vector_memory"

    // Note: deletion_audit_log, deletion_failures, consent_records are intentionally
    // excluded from SyncableTable. They are write-once audit/operational records
    // (push-only via outbox or server-only) with no `updatedAt` field, so they
    // cannot participate in watermark-based pull sync.

    // Settings & Onboarding
    case notificationSettings = "notification_settings"
    case userHealthFlags = "user_health_flags"
    case onboardingState = "onboarding_state"
    case userBaselines = "user_baselines"
    case privacySettings = "privacy_settings"

    // Pull-only (server → client, never written by client)
    case insights = "insights"
    case dailyNutritionTargets = "daily_nutrition_targets"
    case trainingTemplates = "training_templates"

    // Reference catalogs (pull-only, server-managed)
    case foodCatalogItems = "food_catalog_items"
    case supplementCatalog = "supplement_catalog"
    case exerciseCatalog = "exercise_catalog"

    /// Whether this table is pull-only (server-generated, never written by client).
    var isPullOnly: Bool {
        switch self {
        case .insights, .dailyNutritionTargets,
             .foodCatalogItems, .supplementCatalog, .exerciseCatalog,
             .recommendations, .weeklyStrategyReports, .healthMarkerCatalog,
             .vectorMemory:
            return true
        default:
            return false
        }
    }
}

// MARK: - Sync Table Registry

/// Centralized sync metadata for table-level pull filters.
enum SyncTableRegistry {
    enum DateValueKind: Sendable {
        case dateOnly   // YYYY-MM-DD
        case timestamp  // ISO-8601 timestamp
    }

    struct DateColumnSpec: Sendable, Equatable {
        let column: String
        let valueKind: DateValueKind

        init(_ column: String, _ valueKind: DateValueKind) {
            self.column = column
            self.valueKind = valueKind
        }
    }

    /// Source of truth for `table -> sync cutoff column`.
    /// Must stay in sync with `SyncableTable`.
    static let dateColumnSpecs: [SyncableTable: DateColumnSpec] = [
        // Core
        .users: DateColumnSpec("created_at", .timestamp),
        .physiologicalStates: DateColumnSpec("date", .dateOnly),
        .sleepLogs: DateColumnSpec("sleep_date", .dateOnly),

        // Nutrition
        .foodLogs: DateColumnSpec("logged_date", .dateOnly),
        .foodItems: DateColumnSpec("created_at", .timestamp),
        .userFoods: DateColumnSpec("created_at", .timestamp),
        .userFoodFavorites: DateColumnSpec("created_at", .timestamp),
        .mealTemplates: DateColumnSpec("created_at", .timestamp),
        .batchRecipes: DateColumnSpec("created_at", .timestamp),
        .batchRecipeIngredients: DateColumnSpec("created_at", .timestamp),

        // Training
        .workoutSessions: DateColumnSpec("session_date", .dateOnly),
        .workoutExercises: DateColumnSpec("created_at", .timestamp),
        .workoutSets: DateColumnSpec("created_at", .timestamp),
        .trainingPlans: DateColumnSpec("created_at", .timestamp),
        .trainingPlanSessions: DateColumnSpec("planned_date", .dateOnly),
        .trainingLoads: DateColumnSpec("date", .dateOnly),

        // Supplements
        .userSupplements: DateColumnSpec("created_at", .timestamp),
        .supplementLogs: DateColumnSpec("taken_date", .dateOnly),

        // Health
        .menstrualLogs: DateColumnSpec("date", .dateOnly),
        .wellnessChecks: DateColumnSpec("date", .dateOnly),
        .bodyComposition: DateColumnSpec("measured_date", .dateOnly),
        .hydrationLogs: DateColumnSpec("logged_date", .dateOnly),

        // Labs
        .medicalScans: DateColumnSpec("created_at", .timestamp),
        .healthMeasurements: DateColumnSpec("created_at", .timestamp),
        .healthDiagnoses: DateColumnSpec("created_at", .timestamp),
        .healthMarkerCatalog: DateColumnSpec("created_at", .timestamp),

        // AI
        .experiments: DateColumnSpec("created_at", .timestamp),
        .experimentMeasurements: DateColumnSpec("date", .dateOnly),
        .recommendations: DateColumnSpec("recommendation_date", .dateOnly),
        .weeklyStrategyReports: DateColumnSpec("week_start", .dateOnly),
        .vectorMemory: DateColumnSpec("event_date", .dateOnly),

        // Settings & Onboarding
        .notificationSettings: DateColumnSpec("created_at", .timestamp),
        .userHealthFlags: DateColumnSpec("created_at", .timestamp),
        .onboardingState: DateColumnSpec("created_at", .timestamp),
        .userBaselines: DateColumnSpec("last_computed_at", .timestamp),
        .privacySettings: DateColumnSpec("created_at", .timestamp),

        // Pull-only
        .insights: DateColumnSpec("created_at", .timestamp),
        .dailyNutritionTargets: DateColumnSpec("date", .dateOnly),
        .trainingTemplates: DateColumnSpec("created_at", .timestamp),

        // Reference catalogs
        .foodCatalogItems: DateColumnSpec("created_at", .timestamp),
        .supplementCatalog: DateColumnSpec("created_at", .timestamp),
        .exerciseCatalog: DateColumnSpec("created_at", .timestamp)
    ]

    static func dateColumnSpec(for table: SyncableTable) -> DateColumnSpec {
        resolvedDateColumnSpec(for: table, specs: dateColumnSpecs, assertOnMissing: false)
    }

    static func dateColumnSpec(forTableName tableName: String) -> DateColumnSpec {
        guard let table = SyncableTable(rawValue: tableName) else {
            return DateColumnSpec("created_at", .timestamp)
        }
        return dateColumnSpec(for: table)
    }

    private static func resolvedDateColumnSpec(
        for table: SyncableTable,
        specs: [SyncableTable: DateColumnSpec],
        assertOnMissing: Bool,
        missingSpecHandler: ((String) -> Void)? = nil
    ) -> DateColumnSpec {
        if let spec = specs[table] {
            return spec
        }
        if assertOnMissing {
            let message = "Missing sync date-column mapping for table: \(table.rawValue)"
            if let missingSpecHandler {
                missingSpecHandler(message)
            } else {
                // Explicit no-op for test hooks that want to validate fallback without trapping.
                _ = message
            }
        }
        return DateColumnSpec("created_at", .timestamp)
    }
}

#if DEBUG
extension SyncTableRegistry {
    static func _testDateColumnSpec(
        for table: SyncableTable,
        specs: [SyncableTable: DateColumnSpec],
        assertOnMissing: Bool = false,
        missingSpecHandler: ((String) -> Void)? = nil
    ) -> DateColumnSpec {
        resolvedDateColumnSpec(
            for: table,
            specs: specs,
            assertOnMissing: assertOnMissing,
            missingSpecHandler: missingSpecHandler
        )
    }
}
#endif
