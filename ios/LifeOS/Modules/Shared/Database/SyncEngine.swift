// MARK: - Sync Engine
// Source of truth: life_os_sync_engine_spec.md
// Phases: Pull (§6.1) → Push (§6.2) → Reconcile (§6.3)

import Foundation
import GRDB
import OSLog

/// Protocol for types that expose an `updatedAt` for watermark extraction.
protocol SyncTimestamped {
    var updatedAt: Date { get }
}

/// Main sync engine actor — coordinates offline-first sync with server.loop: Pull → Push → Reconcile.
actor SyncEngine {

    private let dbQueue: DatabaseQueue
    private let apiClient: any SyncAPIClient
    private let deviceId: String
    private let pushTransportOverride: (@Sendable (OutboxEvent) async throws -> Void)?
    private let isRuntimeConfiguredProvider: @Sendable () -> Bool
    private let allowsRemoteOperationsWithoutBundledConfig: Bool
    private let logger = Logger(subsystem: "com.lifeos.app", category: "SyncSLO")
    private static let inFlightRecoveryThreshold: TimeInterval = 10 * 60
    private static let sloTelemetryThrottleSeconds: TimeInterval = 30 * 60
    private static let outboxSLOMinSampleSize = 20
    private static let outboxWarningFailureRate = 0.05
    private static let outboxCriticalFailureRate = 0.10
    private static let outboxWarningDeadLetterRate = 0.01
    private static let outboxCriticalDeadLetterRate = 0.03
    private static let restrictedMedicalPaths: Set<String> = [
        "api-labs",
        "rest/v1/medical_scans",
        "rest/v1/health_measurements",
    ]
    private static let cloudBackupRestrictedPaths: Set<String> = [
        "rest/v1/user_health_flags",
    ]
#if DEBUG
    private static let testEnqueueOutboxSLOAnalyticsOverride = LockedTestOverride<
        @Sendable (OutboxSLOEvaluation, Date) async throws -> Void
    >()
    private static let testEnsureLocalMetaFailureHandler = LockedTestOverride<@Sendable (Error) -> Void>()
#endif
    private var lastOutboxSLOTelemetry: (severity: OutboxSLOAlertSeverity, at: Date)?

    private struct PreparedOutboundRequest: Sendable {
        let path: String
        let body: Data
    }

    private struct EdgeRouteDescriptor: Sendable {
        let functionName: String
        let route: String
    }

    private struct LocalLabScanSyncContext: Sendable {
        let scan: MedicalScan
        let measurements: [HealthMeasurement]
    }

    init(
        dbQueue: DatabaseQueue,
        apiClient: any SyncAPIClient = APIClient(),
        pushTransportOverride: (@Sendable (OutboxEvent) async throws -> Void)? = nil,
        isRuntimeConfiguredProvider: @escaping @Sendable () -> Bool = { SupabaseConfig.isRuntimeConfigured }
    ) {
        self.dbQueue = dbQueue
        self.apiClient = apiClient
        self.deviceId = KeychainHelper.getOrCreateDeviceId()
        self.pushTransportOverride = pushTransportOverride
        self.isRuntimeConfiguredProvider = isRuntimeConfiguredProvider
        // Tests inject either a fake API client or an in-memory push transport. In those
        // cases, the sync engine should exercise its control flow even though the bundled
        // SUPABASE_* build settings intentionally point at placeholders.
        self.allowsRemoteOperationsWithoutBundledConfig =
            pushTransportOverride != nil || !(apiClient is APIClient)
        Self.ensureLocalMetaDeviceId(dbQueue: dbQueue, deviceId: self.deviceId)
    }

    private var isRemoteOperationsEnabled: Bool {
        isRuntimeConfiguredProvider() || allowsRemoteOperationsWithoutBundledConfig
    }

    // MARK: - Sync Loop (§6)

    /// Coalesces overlapping sync cycles (foreground triggers, BGTask, view
    /// refreshes). The actor serializes access but interleaves at suspension
    /// points, so without this flag two cycles could process the same outbox
    /// events concurrently.
    private var isSyncCycleInFlight = false

    /// Runs the full sync cycle: Pull → Push → Reconcile → Cleanup.
    func runSyncLoop() async throws {
        guard !isSyncCycleInFlight else { return }
        guard isRemoteOperationsEnabled else {
            try await cleanupOldOutboxEvents()
            return
        }

        isSyncCycleInFlight = true
        defer { isSyncCycleInFlight = false }

        // Phase 1: Pull server changes
        try await pullAll()

        // Phase 2: Push outbox events
        try await pushPendingEvents()

        // Phase 3: Reconcile — re-pull tables affected by push to get server-computed fields
        try await reconcileAfterPush()

        // Phase 4 (P2 #14): Cleanup old succeeded/cancelled events to prevent unbounded growth
        try await cleanupOldOutboxEvents()

        // Emit SLO alerts for outbox failure/dead-letter rates.
        try await evaluateAndEmitOutboxSLOAlert()

        await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
    }

    /// P2 #14: Remove succeeded/cancelled outbox events older than 7 days.
    private func cleanupOldOutboxEvents() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM outbox_events
                WHERE status IN (?, ?)
                  AND updated_at_local < datetime('now', '-7 days')
                """,
                arguments: [
                    OutboxStatus.succeeded.rawValue,
                    OutboxStatus.cancelled.rawValue
                ]
            )
        }
    }

    // MARK: - Pull Phase (§6.1)

    /// Pull all syncable tables using `updated_at >= watermark`.
    /// Uses parallel TaskGroup batches to reduce total sync time (P2 #9).
    func pullAll() async throws {
        guard isRemoteOperationsEnabled else { return }
        guard try await !hasPendingAccountErasure() else { return }
        if !allowsRemoteOperationsWithoutBundledConfig {
            guard await MainActor.run(body: { AuthManager.activeHasCloudSession }) else { return }
        }

        // Foreign keys require catalogs and parents to exist before their children.
        // Each await is also a barrier between pages of dependent tables.
        try await pullTable("users", type: User.self)
        try await pullTable("food_catalog_items", type: FoodCatalogItem.self)
        try await pullTable("supplement_catalog", type: SupplementCatalogEntry.self)
        try await pullTable("exercise_catalog", type: ExerciseCatalogEntry.self)
        try await pullTable("health_marker_catalog", type: HealthMarkerCatalogEntry.self)
        try await pullTable("training_templates", type: TrainingTemplate.self)
        try await pullTable("physiological_states", type: PhysiologicalState.self)
        try await pullTable("notification_settings", type: NotificationSettings.self)
        try await pullTable("training_loads", type: TrainingLoad.self)
        for table in [SyncableTable.userFoods, .mealTemplates, .batchRecipes,
                      .batchRecipeIngredients, .foodLogs, .foodItems, .userFoodFavorites,
                      .trainingPlans, .workoutSessions, .workoutExercises, .workoutSets,
                      .trainingPlanSessions] {
            try await pullSyncableTable(table)
        }
        for table in SupplementsSyncHandler.pullTables + SleepSyncHandler.pullTables {
            try await pullSyncableTable(table)
        }
        if try await shouldSyncMenstrualData() { try await pullSyncableTable(.menstrualLogs) }
        for table in LabsSyncHandler.pullTables(includeRestrictedMedicalData: try await shouldPullRestrictedMedicalData()) {
            try await pullSyncableTable(table)
        }
        try await pullTable("wellness_checks", type: WellnessCheck.self)
        try await pullTable("body_composition", type: BodyComposition.self)
        try await pullTable("hydration_logs", type: HydrationLog.self)
        try await pullTable("experiments", type: Experiment.self)
        try await pullTable("experiment_measurements", type: ExperimentMeasurement.self)
        try await pullTable("insights", type: Insight.self)
        try await pullTable("recommendations", type: Recommendation.self)
        try await pullTable("weekly_strategy_reports", type: WeeklyStrategyReport.self)
        try await pullTable("daily_nutrition_targets", type: DailyNutritionTarget.self)
        try await pullTable("onboarding_state", type: OnboardingState.self)
        try await pullTable("user_baselines", type: UserBaseline.self)
        try await pullTable("privacy_settings", type: PrivacySettings.self)
        if try await shouldSyncUserHealthFlags() { try await pullTable("user_health_flags", type: UserHealthFlags.self) }
        if try await shouldPullVectorMemory() { try await pullTable("vector_memory", type: VectorMemoryEntry.self) }

        try await reconcileParentChildAggregates()
    }

    private func pullSyncableTable(_ table: SyncableTable) async throws {
        switch table {
        case .foodLogs:
            try await pullTable(table.rawValue, type: FoodLog.self)
        case .foodItems:
            try await pullTable(table.rawValue, type: FoodItem.self)
        case .userFoods:
            try await pullTable(table.rawValue, type: UserFood.self)
        case .userFoodFavorites:
            try await pullTable(table.rawValue, type: UserFoodFavorite.self)
        case .mealTemplates:
            try await pullTable(table.rawValue, type: MealTemplate.self)
        case .batchRecipes:
            try await pullTable(table.rawValue, type: BatchRecipe.self)
        case .batchRecipeIngredients:
            try await pullTable(table.rawValue, type: BatchRecipeIngredient.self)
        case .workoutSessions:
            try await pullTable(table.rawValue, type: WorkoutSession.self)
        case .workoutExercises:
            try await pullTable(table.rawValue, type: WorkoutExercise.self)
        case .workoutSets:
            try await pullTable(table.rawValue, type: WorkoutSet.self)
        case .trainingPlans:
            try await pullTable(table.rawValue, type: TrainingPlan.self)
        case .trainingPlanSessions:
            try await pullTable(table.rawValue, type: TrainingPlanSession.self)
        case .userSupplements:
            try await pullTable(table.rawValue, type: UserSupplement.self)
        case .supplementLogs:
            try await pullTable(table.rawValue, type: SupplementLog.self)
        case .sleepLogs:
            try await pullTable(table.rawValue, type: SleepLog.self)
        case .menstrualLogs:
            try await pullTable(table.rawValue, type: MenstrualLog.self)
        case .medicalScans:
            try await pullTable(table.rawValue, type: MedicalScan.self)
        case .healthMeasurements:
            try await pullTable(table.rawValue, type: HealthMeasurement.self)
        case .healthDiagnoses:
            try await pullTable(table.rawValue, type: HealthDiagnosis.self)
        case .trainingLoads:
            try await pullTable(table.rawValue, type: TrainingLoad.self)
        case .dailyNutritionTargets:
            try await pullTable(table.rawValue, type: DailyNutritionTarget.self)
        case .foodCatalogItems:
            try await pullTable(table.rawValue, type: FoodCatalogItem.self)
        case .supplementCatalog:
            try await pullTable(table.rawValue, type: SupplementCatalogEntry.self)
        case .exerciseCatalog:
            try await pullTable(table.rawValue, type: ExerciseCatalogEntry.self)
        case .healthMarkerCatalog:
            try await pullTable(table.rawValue, type: HealthMarkerCatalogEntry.self)
        default:
            break
        }
    }

    /// Pull a single table via keyset pagination (`updated_at`, `id`), upsert into local, advance watermark.
    /// Uses `>=` on the first page per spec §6.1 to avoid missing same-timestamp updates.
    /// Paginates in batches of ≤ 1000 rows per spec §6.1 to prevent OOM on initial sync.
    private func pullTable<T: FetchableRecord & PersistableRecord & Decodable & Sendable & SyncTimestamped & Identifiable>(
        _ tableName: String,
        type: T.Type
    ) async throws where T.ID: CustomStringConvertible {
        if tableName == User.databaseTableName, T.self == User.self {
            try await pullUsersTable()
            return
        }

        let batchSize = 1000
        let initialWatermark = try await dbQueue.read { db -> Date? in
            let state = try SyncState.fetchOne(db, key: tableName)
            return state?.lastPulledAtServer
        }

        // Apply Sync Window (§6.1.3) to massive granular tables.
        let granularTables: Set<String> = [
            "food_logs", "food_items",
            "workout_sessions", "workout_exercises", "workout_sets",
            "supplement_logs", "hydration_logs", "sleep_logs"
        ]
        let activeWindowDays: Int? = granularTables.contains(tableName) ? 90 : nil

        // Paginated pull loop (keyset by updated_at + id)
        var totalPulled = 0
        var maxUpdatedAtSeen = initialWatermark
        var cursor: APIClient.SyncPageCursor?
        while true {
            let rows: [T] = try await apiClient.fetchSyncPage(
                from: tableName,
                since: initialWatermark,
                cursor: cursor,
                limit: batchSize,
                activeWindowDays: activeWindowDays
            )

            guard !rows.isEmpty else {
                if totalPulled == 0 {
                    // Empty result still means a successful pull cycle.
                    try await updatePullAttempt(table: tableName, markSuccess: true)
                }
                break
            }

            totalPulled += rows.count

            // Upsert into local store — LWW (Last Write Wins) with timestamp comparison.
            // Only overwrite local data if the incoming server timestamp is >= local mirror.
            // This prevents stale pull responses from clobbering fresher local changes
            // that were pushed but not yet reflected in the pull response.
            try await dbQueue.write { db in
                for row in rows {
                    let rowId = String(describing: row.id)
                    // Entity tables store ids in either canonical UUID or
                    // legacy string encoding; resolve both up front.
                    let alternateRowId = UUID(uuidString: rowId)?.uuidString
                    let existingServerTimestamp = try Date.fetchOne(
                        db,
                        sql: """
                            SELECT updated_at_server
                            FROM sync_row_state
                            WHERE table_name = ? AND row_id = ?
                            """,
                        arguments: [tableName, rowId]
                    )

                    // LWW: skip if local mirror has a strictly newer server timestamp.
                    if let existing = existingServerTimestamp, row.updatedAt < existing {
                        continue
                    }

                    // LWW: never let a pull clobber an unpushed local edit.
                    // Pull runs before push in the cycle, so a row modified
                    // locally after the server's last write must survive this
                    // phase; its outbox event will reconcile the conflict.
                    if Self.hasNewerLocalEdit(
                        db: db,
                        tableName: tableName,
                        rowId: rowId,
                        alternateRowId: alternateRowId,
                        incomingServerTimestamp: row.updatedAt
                    ) {
                        continue
                    }

                    if let sleep = row as? SleepLog, sleep.source != .manual,
                       let localSleep = try SleepRecordSelection.daily(userId: sleep.userId, day: sleep.sleepDate ?? sleep.date, includeDeleted: true, db: db),
                       localSleep.overridesImportedSleep {
                        // A pull precedes outbox replay. A newer server import
                        // must not erase a queued manual correction or deletion.
                        continue
                    }
                    try row.save(db)
                    try Self.upsertServerTimestampMirror(
                        db: db,
                        tableName: tableName,
                        rowId: rowId,
                        updatedAtServer: row.updatedAt
                    )
                }
            }

            if let batchMax = rows.map(\.updatedAt).max() {
                if let existingMax = maxUpdatedAtSeen {
                    maxUpdatedAtSeen = max(existingMax, batchMax)
                } else {
                    maxUpdatedAtSeen = batchMax
                }
            }

            // If we got fewer than batchSize, we've reached the end
            if rows.count < batchSize { break }

            guard let lastRow = rows.last else { break }
            cursor = APIClient.SyncPageCursor(
                updatedAt: lastRow.updatedAt,
                rowId: String(describing: lastRow.id)
            )
        }

        if let maxUpdatedAtSeen {
            try await updateSyncWatermark(table: tableName, serverTimestamp: maxUpdatedAtSeen)
        }
    }

    /// Returns true when the local row was modified after the incoming server
    /// write, meaning a pull must not overwrite the local edit.
    private nonisolated static func hasNewerLocalEdit(
        db: Database,
        tableName: String,
        rowId: String,
        alternateRowId: String?,
        incomingServerTimestamp: Date
    ) -> Bool {
        // Table names originate from internal call sites; validate before
        // interpolating into SQL.
        let validIdentifier = !tableName.isEmpty && tableName.allSatisfy { char in
            (char.isLetter && char.isLowercase) || char == "_"
        }
        guard validIdentifier else { return false }

        let arguments: StatementArguments = [rowId, alternateRowId ?? rowId, UUID(uuidString: rowId)]
        guard let localUpdatedAt = try? Date.fetchOne(
            db,
            sql: "SELECT updated_at FROM \(tableName) WHERE id = ? OR id = ? OR id = ? ORDER BY updated_at DESC LIMIT 1",
            arguments: arguments
        ) else {
            return false
        }
        return localUpdatedAt > incomingServerTimestamp
    }

    private func pullUsersTable() async throws {
        let tableName = User.databaseTableName
        let batchSize = 1000
        let initialWatermark = try await dbQueue.read { db -> Date? in
            let state = try SyncState.fetchOne(db, key: tableName)
            return state?.lastPulledAtServer
        }

        var totalPulled = 0
        var maxUpdatedAtSeen = initialWatermark
        var cursor: APIClient.SyncPageCursor?

        while true {
            let rows: [User] = try await apiClient.fetchSyncPage(
                from: tableName,
                since: initialWatermark,
                cursor: cursor,
                limit: batchSize,
                activeWindowDays: nil
            )

            guard !rows.isEmpty else {
                if totalPulled == 0 {
                    try await updatePullAttempt(table: tableName, markSuccess: true)
                }
                break
            }

            totalPulled += rows.count

            try await dbQueue.write { db in
                for row in rows {
                    let rowId = row.id.uuidString
                    let existingServerTimestamp = try Date.fetchOne(
                        db,
                        sql: """
                            SELECT updated_at_server
                            FROM sync_row_state
                            WHERE table_name = ? AND row_id = ?
                            """,
                        arguments: [tableName, rowId]
                    )

                    if let existing = existingServerTimestamp, row.updatedAt < existing {
                        continue
                    }

                    let mergedUser = try UserIdentityReconciler.reconcilePulledServerUser(row, db: db)
                    try Self.upsertServerTimestampMirror(
                        db: db,
                        tableName: tableName,
                        rowId: mergedUser.id.uuidString,
                        updatedAtServer: row.updatedAt
                    )
                }
            }

            if let batchMax = rows.map(\.updatedAt).max() {
                if let existingMax = maxUpdatedAtSeen {
                    maxUpdatedAtSeen = max(existingMax, batchMax)
                } else {
                    maxUpdatedAtSeen = batchMax
                }
            }

            if rows.count < batchSize { break }

            guard let lastRow = rows.last else { break }
            cursor = APIClient.SyncPageCursor(
                updatedAt: lastRow.updatedAt,
                rowId: lastRow.id.uuidString
            )
        }

        if let maxUpdatedAtSeen {
            try await updateSyncWatermark(table: tableName, serverTimestamp: maxUpdatedAtSeen)
        }
    }

    /// Record a pull attempt (even if no rows fetched).
    private func updatePullAttempt(table: String, markSuccess: Bool = false) async throws {
        let now = Date()
        try await dbQueue.write { db in
            if var state = try SyncState.fetchOne(db, key: table) {
                state.lastPullAttemptAt = now
                if markSuccess {
                    state.lastPullSuccessAt = now
                    state.lastErrorCode = nil
                }
                try state.update(db)
            } else {
                var state = SyncState(tableName: table)
                state.lastPullAttemptAt = now
                if markSuccess {
                    state.lastPullSuccessAt = now
                }
                try state.insert(db)
            }
        }
    }

    nonisolated private static func upsertServerTimestampMirror(
        db: Database,
        tableName: String,
        rowId: String,
        updatedAtServer: Date
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO sync_row_state (table_name, row_id, updated_at_server)
                VALUES (?, ?, ?)
                ON CONFLICT(table_name, row_id)
                DO UPDATE SET updated_at_server = excluded.updated_at_server
                """,
            arguments: [tableName, rowId, updatedAtServer]
        )
    }

    // MARK: - Reconcile Phase (§6.3)

    /// After push, re-pull tables that may have server-computed fields.
    /// Goal: local store converges to server authoritative state within the same sync cycle.
    private func reconcileAfterPush() async throws {
        guard isRemoteOperationsEnabled else { return }
        guard try await !hasPendingAccountErasure() else { return }
        if !allowsRemoteOperationsWithoutBundledConfig {
            guard await MainActor.run(body: { AuthManager.activeHasCloudSession }) else { return }
        }

        // These tables may have server-recomputed totals or derived fields after push:
        try await pullTable("food_logs", type: FoodLog.self)                      // total_* re-derived
        try await pullTable("food_items", type: FoodItem.self)                    // server-side snapshots for batch/template logs
        try await pullTable("meal_templates", type: MealTemplate.self)            // authoritative template usage stats / updated_at
        try await pullTable("batch_recipes", type: BatchRecipe.self)              // authoritative batch totals / usage stats
        try await pullTable("batch_recipe_ingredients", type: BatchRecipeIngredient.self)
        try await pullTable("workout_sessions", type: WorkoutSession.self)        // total_volume_kg, total_sets
        try await pullTable("experiments", type: Experiment.self)                 // schedule dates/status from edge routes
        try await pullTable("experiment_measurements", type: ExperimentMeasurement.self) // upserts + protocol adherence
        try await pullTable("daily_nutrition_targets", type: DailyNutritionTarget.self)  // server-set targets
        try await pullTable("insights", type: Insight.self)                       // new AI insights triggered by push
        try await reconcileParentChildAggregates()
    }

    /// Re-derives parent aggregates from child rows to keep hierarchical data consistent.
    private func reconcileParentChildAggregates() async throws {
        try await dbQueue.write { db in
            try NutritionSyncHandler.reconcileParentChild(in: db)
            try TrainingSyncHandler.reconcileParentChild(in: db)
            try SupplementsSyncHandler.reconcileParentChild(in: db)
            try SleepSyncHandler.reconcileParentChild(in: db)
            try LabsSyncHandler.reconcileParentChild(in: db)
        }
    }

    // MARK: - Push Phase (§6.2)

    /// Enqueues a prepared event in the caller's transaction for multi-record writes.
    nonisolated func enqueueMutation(_ event: OutboxEvent, in db: Database) throws {
        try Self.insertPreparedMutation(event, into: db, deviceId: deviceId)
    }

    /// Replay pending outbox events in priority order, respecting `depends_on` chains.
    func pushPendingEvents() async throws {
        guard isRemoteOperationsEnabled else { return }
        if !allowsRemoteOperationsWithoutBundledConfig {
            guard await MainActor.run(body: { AuthManager.activeHasCloudSession }) else { return }
        }

        // Force-update invariant: block mutating traffic until app is updated.
        if await apiClient.shouldBlockMutationsForForceUpdate() {
            return
        }

        try await recoverStaleInFlightEvents()
        try await backfillLegacyNotificationDeliveryModes()
        let events = try await pendingEvents()
        // Track which events have succeeded in this cycle for depends_on resolution
        var succeededIds = try await previouslySucceededIds()

        for event in events {
            if try await hasPendingAccountErasure(), !["api-account-delete", "api-account-delete-cancel"].contains(event.path) { continue }
            if event.path.contains("menstrual"), try await !shouldSyncMenstrualData() {
                try await cancelEvent(event.id)
                continue
            }
            if try await shouldCancelRestrictedMedicalEvent(event) {
                try await cancelEvent(event.id)
                continue
            }
            if try await shouldCancelCloudBackupRestrictedEvent(event) {
                try await cancelEvent(event.id)
                continue
            }
            // P1 #9: Cancel vector_memory events if consent was revoked after enqueue.
            if try await shouldSkipVectorMemoryEnqueue(for: event) {
                try await cancelEvent(event.id)
                continue
            }

            // Skip events whose dependency hasn't been fulfilled yet
            if let dep = event.dependsOn, !succeededIds.contains(dep) {
                continue
            }

            do {
                // Mark in-flight
                try await markInFlight(event.id)

                // Send to server via Supabase Edge Functions
                try await sendToServer(event)

                // Mark succeeded
                try await markSucceeded(event.id)
                succeededIds.insert(event.id)
                if event.path == "api-account-delete" { return }
            } catch let error as NSError {
                // Classify and handle error
                let category = classifyError(error)
                let retryable = category == .network || category == .server || category == .rateLimited

                // P3 #25: Extract Retry-After header value for 429 responses
                let retryAfterSeconds: TimeInterval?
                if category == .rateLimited {
                    if let retryAfter = error.userInfo["retry_after_seconds"] as? TimeInterval {
                        retryAfterSeconds = retryAfter
                    } else {
                        retryAfterSeconds = 60
                    }
                } else {
                    retryAfterSeconds = nil
                }

                try await markFailed(
                    event.id,
                    category: category,
                    code: "\(error.code)",
                    message: String(error.localizedDescription.prefix(500)),
                    retryable: retryable,
                    retryAfterOverride: retryAfterSeconds
                )

                // Stop pushing if auth error or rate limited (need re-auth / back off)
                if category == .auth || category == .rateLimited { break }
            }
        }
    }

    /// Recover outbox rows left in `in_flight` after process termination/interruption.
    private func recoverStaleInFlightEvents() async throws {
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.inFlightRecoveryThreshold)

        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE outbox_events
                    SET status = ?,
                        updated_at_local = ?,
                        next_attempt_at = ?,
                        last_error_category = COALESCE(last_error_category, ?),
                        last_error_code = COALESCE(last_error_code, ?),
                        last_error_message = COALESCE(last_error_message, ?)
                    WHERE status = ?
                      AND (
                        (last_attempt_at IS NOT NULL AND last_attempt_at <= ?)
                        OR (last_attempt_at IS NULL AND updated_at_local <= ?)
                      )
                    """,
                arguments: [
                    OutboxStatus.failedRetryable.rawValue,
                    now,
                    now,
                    ErrorCategory.network.rawValue,
                    "stale_in_flight",
                    "Recovered stale in-flight outbox event after interruption.",
                    OutboxStatus.inFlight.rawValue,
                    cutoff,
                    cutoff
                ]
            )
        }
    }

    /// Returns IDs of previously succeeded outbox events (for depends_on resolution).
    private func previouslySucceededIds() async throws -> Set<UUID> {
        try await dbQueue.read { db in
            let ids = try UUID.fetchAll(db, sql: """
                SELECT id FROM outbox_events WHERE status = ?
                """,
                arguments: [OutboxStatus.succeeded.rawValue]
            )
            return Set(ids)
        }
    }

    private func backfillLegacyNotificationDeliveryModes() async throws {
        let defaultDeliveryMode = await currentDefaultNotificationDeliveryMode()
        let legacyEvents = try await dbQueue.read { db in
            try OutboxEvent.fetchAll(
                db,
                sql: """
                    SELECT
                        id,
                        created_at_local,
                        updated_at_local,
                        status,
                        priority,
                        depends_on,
                        http_method,
                        path,
                        headers_json,
                        body_json,
                        idempotency_key,
                        attempt_count,
                        next_attempt_at,
                        last_attempt_at,
                        last_error_category,
                        last_error_code,
                        last_error_message,
                        user_visible_blocker,
                        ui_hint_json
                    FROM outbox_events
                    WHERE path = ?
                      AND status IN (?, ?, ?)
                    """,
                arguments: [
                    "send-notification",
                    OutboxStatus.pending.rawValue,
                    OutboxStatus.failedRetryable.rawValue,
                    OutboxStatus.inFlight.rawValue,
                ]
            )
        }

        for event in legacyEvents {
            guard Self.notificationDeliveryMode(from: event.bodyJson) == nil,
                  var payload = try? JSONSerialization.jsonObject(with: event.bodyJson) as? [String: Any] else {
                continue
            }

            payload["delivery_mode"] = defaultDeliveryMode.rawValue
            let updatedBody = try JSONSerialization.data(withJSONObject: payload)

            try await dbQueue.write { db in
                try db.execute(
                    sql: """
                        UPDATE outbox_events
                        SET body_json = ?
                        WHERE id = ? OR id = ?
                        """,
                    arguments: [updatedBody, event.id, event.id.uuidString]
                )
            }
        }
    }

    private func currentDefaultNotificationDeliveryMode() async -> NotificationOutboxDeliveryMode {
#if os(iOS)
        let hasCloudSession = await MainActor.run { AuthManager.activeHasCloudSession }
        return hasCloudSession ? .remoteOnly : .localScheduled
#else
        return .remoteOnly
#endif
    }

    private func sendToServer(_ event: OutboxEvent) async throws {
        if !allowsRemoteOperationsWithoutBundledConfig {
            guard await MainActor.run(body: { AuthManager.activeHasCloudSession }) else { throw AuthError.sessionExpired }
        }
        if let pushTransportOverride {
            try await pushTransportOverride(event)
            return
        }

        let preparedRequest = try await prepareOutboundRequest(for: event)
        let sanitizedBody = try sanitizeOutboundBody(preparedRequest.body, path: preparedRequest.path)
        var outboundHeaders = Self.decodeHeaders(event.headersJson)
        outboundHeaders["Idempotency-Key"] = event.idempotencyKey
        outboundHeaders["X-Device-Id"] = deviceId
        outboundHeaders["X-Outbox-Replay"] = "true"
        outboundHeaders["X-Correlation-Id"] = outboundHeaders["X-Correlation-Id"] ?? event.id.uuidString.lowercased()

        if preparedRequest.path == "api-account-delete" {
            guard let authId = await MainActor.run(body: { AuthManager.activeAuthId }) else { throw AuthError.sessionExpired }
            // Persist before the request: the server may delete auth and then
            // lose its HTTP response, leaving receipt polling as the only path.
            outboundHeaders["X-Deletion-Receipt"] = try AccountDeletionReceiptStore.prepare(authId: authId)
            let accepted: AccountDeletionAcceptedResponse = try await apiClient.callEdgeFunction(preparedRequest.path, body: sanitizedBody, headers: outboundHeaders, maxAttempts: 3)
            guard accepted.deletionReceipt != nil || accepted.authDeleted == true else { throw SettingsError.deletionFailed }
            if let token = accepted.deletionReceipt {
                try AccountDeletionReceiptStore.save(.init(token: token, expiresAt: accepted.deletionReceiptExpiresAt, authId: authId, completed: false))
            }
            try await eraseLocalHistoryAfterAcceptedDeletion(event: event)
            if accepted.authDeleted == true {
                try AccountDeletionReceiptStore.save(.init(token: nil, expiresAt: nil, authId: authId, completed: true, localErased: true))
            }
            return
        }

        // INVARIANT: Idempotency-Key and X-Device-Id MUST be headers per sync spec §6.2.
        if preparedRequest.path.starts(with: "rest/v1/") {
            // It's a direct PostgREST table insert (for tables lacking explicit Edge Functions)
            let table = preparedRequest.path.replacingOccurrences(of: "rest/v1/", with: "")
            
            // PostgREST upsert logic via specialized method
            try await apiClient.upsertRow(table: table, bodyJson: sanitizedBody, headers: outboundHeaders)
        } else if preparedRequest.path == "send-notification" {
            let response: NotificationDispatchEdgeResponse = try await apiClient.callEdgeFunction(
                preparedRequest.path,
                body: sanitizedBody,
                headers: outboundHeaders,
                maxAttempts: 3
            )
            try await reconcileNotificationDispatchResponse(
                response,
                eventId: event.id,
                requestBody: sanitizedBody
            )
        } else if let route = Self.edgeRouteDescriptor(for: preparedRequest.path) {
            let _: EmptyResponse = try await apiClient.callEdgeRoute(
                function: route.functionName,
                route: route.route,
                method: event.httpMethod.rawValue,
                queryItems: [],
                body: sanitizedBody,
                headers: outboundHeaders,
                maxAttempts: 3
            )
        } else {
            // Standard edge function routing
            let _: EmptyResponse = try await apiClient.callEdgeFunction(
                preparedRequest.path,
                body: sanitizedBody,
                headers: outboundHeaders,
                maxAttempts: 3
            )
        }
        if preparedRequest.path == "api-account-delete-cancel" {
            try await dbQueue.write { db in try db.execute(sql: "UPDATE users SET deletion_in_progress = 0") }
            try AccountDeletionReceiptStore.clear()
        }
    }

    private func hasPendingAccountErasure() async throws -> Bool {
        try await dbQueue.read { db in
            try Bool.fetchOne(db, sql: "SELECT MAX(deletion_in_progress) FROM users") ?? false
        }
    }

    private func eraseLocalHistoryAfterAcceptedDeletion(event: OutboxEvent) async throws {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        guard let user = try await dbQueue.read({ db in try UserIdentityLookup.fetchUser(authId: authId, db: db) }) else {
            throw AuthError.sessionExpired
        }
        do {
            _ = try await LocalPrivacyErasureExecutor.execute(reason: "cloud_deletion_accepted", user: LocalPrivacyUserContext(userId: user.id, authId: user.authId), dbQueue: dbQueue)
        } catch {
            try await dbQueue.write { db in
                try db.execute(sql: "UPDATE users SET deletion_in_progress = 1")
                try event.save(db)
            }
            throw error
        }
        // Keep only the minimal accepted request/audit while server deletion is pending.
        // It is safe to retry with the same idempotency key after an interrupted cleanup.
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE users SET deletion_in_progress = 1, onboarding_completed = 1")
            try event.save(db)
        }
        if var receipt = try AccountDeletionReceiptStore.load() {
            receipt.localErased = true
            try AccountDeletionReceiptStore.save(receipt)
        }
        await AppContainer.shared?.widgetSnapshotCoordinator.clearSnapshot()
        await MainActor.run { WatchSyncManager.shared.clearSnapshot() }
    }

    private func prepareOutboundRequest(for event: OutboxEvent) async throws -> PreparedOutboundRequest {
        switch event.path {
        case "api-labs", "rest/v1/medical_scans":
            return try await prepareLabScanOutboundRequest(for: event)
        case "rest/v1/sleep_logs":
            // Preserve the original request and idempotency key while routing
            // legacy queued writes through canonical day/source conflict rules.
            return PreparedOutboundRequest(path: "api-sleep-log", body: event.bodyJson)
        case "api-experiments/create":
            var payload = Self.decodeJSONObject(from: event.bodyJson)
            if payload["baseline_start_date"] == nil,
               let rawID = Self.stringValue(in: payload, keys: ["id"]), let id = UUID(uuidString: rawID),
               let startDate = try await dbQueue.read({ db in
                   try Experiment.filter(sql: "id = ? OR id = ?", arguments: [id, id.uuidString]).fetchOne(db)?.baselineStartDate
               }) {
                // Upgrade creates queued by older app versions without moving
                // their already-recorded baseline measurements to another phase.
                payload["baseline_start_date"] = startDate
                return PreparedOutboundRequest(path: event.path, body: try Self.serializeSanitizedBody(payload))
            }
            return PreparedOutboundRequest(path: event.path, body: event.bodyJson)
        default:
            return PreparedOutboundRequest(path: event.path, body: event.bodyJson)
        }
    }

    private nonisolated static func edgeRouteDescriptor(for path: String) -> EdgeRouteDescriptor? {
        guard !path.isEmpty,
              !path.starts(with: "rest/v1/"),
              path != "send-notification" else {
            return nil
        }

        let components = path.split(separator: "/").map(String.init)
        guard let functionName = components.first,
              components.count > 1 else {
            return nil
        }

        return EdgeRouteDescriptor(
            functionName: functionName,
            route: components.dropFirst().joined(separator: "/")
        )
    }

    private func prepareLabScanOutboundRequest(for event: OutboxEvent) async throws -> PreparedOutboundRequest {
        let originalPayload = Self.decodeJSONObject(from: event.bodyJson)
        let explicitScanId = Self.scanId(from: originalPayload)

        var payload = originalPayload
        var resolvedScanId = explicitScanId

        if let explicitScanId,
           let localContext = try await loadLocalLabScanSyncContext(scanId: explicitScanId) {
            resolvedScanId = localContext.scan.id
            let canonicalBody = try LabScanSyncPayloadBuilder.buildBody(
                scan: localContext.scan,
                measurements: localContext.measurements
            )
            payload = Self.decodeJSONObject(from: canonicalBody)
        }

        if resolvedScanId == nil {
            resolvedScanId = Self.scanId(from: payload)
        }

        let uploadedPayload = try await uploadLabScanAssetIfNeeded(payload, scanId: resolvedScanId)
        let preparedBody = try Self.serializeSanitizedBody(uploadedPayload)
        let preparedPath = "api-labs"

        if preparedPath != event.path || preparedBody != event.bodyJson {
            try await persistPreparedOutboxMutation(
                eventId: event.id,
                path: preparedPath,
                bodyJson: preparedBody
            )
        }

        return PreparedOutboundRequest(path: preparedPath, body: preparedBody)
    }

    private func loadLocalLabScanSyncContext(scanId: UUID) async throws -> LocalLabScanSyncContext? {
        try await dbQueue.read { db in
            guard let scan = try MedicalScan
                .filter(sql: "id = ? OR id = ?", arguments: [scanId, scanId.uuidString])
                .fetchOne(db) else {
                return nil
            }

            let measurements = try HealthMeasurement.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM health_measurements
                    WHERE (
                        medical_scan_id = ? OR medical_scan_id = ?
                        OR source_scan_id = ? OR source_scan_id = ?
                    )
                    ORDER BY COALESCE(measured_at, created_at) DESC,
                             COALESCE(NULLIF(biomarker_name, ''), NULLIF(original_label, ''), marker_id) COLLATE NOCASE ASC
                    """,
                arguments: [scanId, scanId.uuidString, scanId, scanId.uuidString]
            )
            return LocalLabScanSyncContext(scan: scan, measurements: measurements)
        }
    }

    private func uploadLabScanAssetIfNeeded(
        _ payload: [String: Any],
        scanId: UUID?
    ) async throws -> [String: Any] {
        var payload = payload
        let restrictedMedicalAllowed = try await shouldPullRestrictedMedicalData()
        let cloudBackupEnabled = try await shouldSyncUserHealthFlags()
        let storeOriginalInCloud = Self.boolValue(
            in: payload,
            keys: ["store_original_in_cloud", "storeOriginalInCloud"]
        ) ?? false
        let shouldStoreOriginalInCloud = restrictedMedicalAllowed && cloudBackupEnabled && storeOriginalInCloud

        guard shouldStoreOriginalInCloud else {
            Self.stripLabScanCloudBackupFields(
                from: &payload,
                forceLocalOnlyStorageMode: !restrictedMedicalAllowed
            )
            return payload
        }

        if let storedAssetPath = Self.stringValue(in: payload, keys: ["stored_asset_path"]),
           !storedAssetPath.isEmpty {
            payload.removeValue(forKey: "original_asset")
            return payload
        }

        guard let scanId else {
            throw NSError(
                domain: "SyncEngine",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Missing lab scan id for cloud backup upload."]
            )
        }

        guard let originalAsset = payload["original_asset"] as? [String: Any] else {
            throw NSError(
                domain: "SyncEngine",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Cloud backup is enabled but no original scan file is available."]
            )
        }

        guard let localFileURLString = Self.stringValue(in: originalAsset, keys: ["local_file_url"]),
              let localFileURL = URL(string: localFileURLString),
              localFileURL.isFileURL else {
            throw NSError(
                domain: "SyncEngine",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Invalid local lab scan file reference for cloud backup."]
            )
        }

        guard FileManager.default.fileExists(atPath: localFileURL.path) else {
            throw NSError(
                domain: "SyncEngine",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Original lab scan file is missing and cannot be uploaded."]
            )
        }

        let fileExtension = Self.stringValue(in: originalAsset, keys: ["file_extension"])
            ?? localFileURL.pathExtension
        let contentType = Self.stringValue(in: originalAsset, keys: ["content_type"])
            ?? LabScanCloudStorage.contentType(forFileExtension: fileExtension)
        let authId = try await apiClient.currentAuthUserId()
        let objectPath = LabScanCloudStorage.objectPath(
            authId: authId,
            scanId: scanId,
            fileExtension: fileExtension
        )

        try await apiClient.uploadStorageObject(
            bucket: LabScanCloudStorage.bucketName,
            path: objectPath,
            fileURL: localFileURL,
            contentType: contentType
        )

        payload["stored_asset_path"] = objectPath
        payload["image_uploaded_at"] = DateFormatting.iso8601FullString(from: Date())
        payload.removeValue(forKey: "original_asset")
        return payload
    }

    private nonisolated static func stripLabScanCloudBackupFields(
        from payload: inout [String: Any],
        forceLocalOnlyStorageMode: Bool
    ) {
        payload["store_original_in_cloud"] = false
        payload["stored_asset_path"] = NSNull()
        payload["image_uploaded_at"] = NSNull()
        payload["scheduled_deletion_at"] = NSNull()
        payload.removeValue(forKey: "original_asset")
        if forceLocalOnlyStorageMode {
            payload["storage_mode"] = "local_only"
        }
    }

    private func persistPreparedOutboxMutation(
        eventId: UUID,
        path: String,
        bodyJson: Data
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE outbox_events
                    SET path = ?, body_json = ?, updated_at_local = ?
                    WHERE id = ? OR id = ?
                    """,
                arguments: [
                    path,
                    bodyJson,
                    Date(),
                    eventId,
                    eventId.uuidString,
                ]
            )
        }
    }

    private nonisolated static func decodeJSONObject(from data: Data) -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private nonisolated static func scanId(from payload: [String: Any]) -> UUID? {
        for key in ["scan_id", "scanId", "id"] {
            guard let rawValue = payload[key] else { continue }
            if let stringValue = rawValue as? String,
               let scanId = UUID(uuidString: stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return scanId
            }
        }
        return nil
    }

    /// Removes restricted fields from outbound payloads.
    /// Privacy invariants: no GPS coordinates or raw medical artifacts are synced by default.
    /// Throws when a parsed payload cannot be re-serialized after sanitization —
    /// falling back to the unsanitized bytes would defeat the whole sanitization step.
    private func sanitizeOutboundBody(_ data: Data, path: String? = nil) throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return data
        }

        let restrictedKeys: Set<String> = [
            "location_lat", "location_lng",
            "locationLat", "locationLng",
            "gps_latitude", "gps_longitude",
            "raw_document", "raw_pdf", "raw_image",
            "ai_extraction_raw", "aiExtractionRaw"
        ]

        func cleanse(_ value: Any) -> Any {
            if let dict = value as? [String: Any] {
                var sanitized: [String: Any] = [:]
                for (key, child) in dict where !restrictedKeys.contains(key) {
                    sanitized[key] = cleanse(child)
                }
                return sanitized
            }
            if let array = value as? [Any] {
                var sanitizedArray: [Any] = []
                sanitizedArray.reserveCapacity(array.count)
                for element in array {
                    sanitizedArray.append(cleanse(element))
                }
                return sanitizedArray
            }
            return value
        }

        let sanitized = cleanse(object)
        // Defence-in-depth: encrypt any sensitive fields that survived the restrictedKeys strip.
        // In normal operation the cleanse() already removes these keys, but if a new sensitive field
        // is added without updating restrictedKeys, encryption ensures plaintext never reaches the wire.
        let encrypted = FieldEncryption.encryptSensitiveFields(in: sanitized)
        let normalizedMedicalScans = Self.normalizeMedicalScanPayloadIfNeeded(encrypted, path: path)
        let normalized = Self.normalizeHealthMeasurementPayloadIfNeeded(normalizedMedicalScans, path: path)
        return try Self.serializeSanitizedBody(normalized)
    }

    /// Keeps legacy medical scan payloads syncable after the contract moved to canonical server values.
    private nonisolated static func normalizeMedicalScanPayloadIfNeeded(_ value: Any, path: String?) -> Any {
        guard path == "rest/v1/medical_scans",
              var object = value as? [String: Any] else {
            return value
        }

        let rawScanType = (object["scan_type"] as? String) ?? (object["scanType"] as? String)
        guard let normalizedScanType = ScanType.canonicalRawValue(for: rawScanType) else {
            return value
        }

        if object["scan_type"] != nil {
            object["scan_type"] = normalizedScanType
        }
        if object["scanType"] != nil {
            object["scanType"] = normalizedScanType
        }
        if object["scan_type"] == nil && object["scanType"] == nil {
            object["scan_type"] = normalizedScanType
        }

        return object
    }

    /// Rewrites legacy health_measurements payloads into the canonical server contract.
    private nonisolated static func normalizeHealthMeasurementPayloadIfNeeded(_ value: Any, path: String?) -> Any {
        guard path == "rest/v1/health_measurements",
              var object = value as? [String: Any] else {
            return value
        }

        let biomarkerName = stringValue(in: object, keys: ["biomarker_name", "biomarkerName"])
        let originalLabel = stringValue(in: object, keys: ["original_label", "originalLabel"]) ?? biomarkerName
        let markerId = HealthMeasurement.canonicalMarkerId(
            markerId: stringValue(in: object, keys: ["marker_id", "markerId"]),
            biomarkerName: biomarkerName,
            originalLabel: originalLabel
        )
        if let markerId {
            object["marker_id"] = markerId
        }

        let sourceScanId = stringValue(in: object, keys: ["source_scan_id", "sourceScanId"])
            ?? stringValue(in: object, keys: ["medical_scan_id", "medicalScanId"])
        if let sourceScanId {
            object["source_scan_id"] = sourceScanId
        }

        if let originalLabel {
            object["original_label"] = originalLabel
        }

        if let userId = stringValue(in: object, keys: ["user_id", "userId"]) {
            object["user_id"] = userId
        }
        if let createdAt = stringValue(in: object, keys: ["created_at", "createdAt"]) {
            object["created_at"] = createdAt
        }
        if let updatedAt = stringValue(in: object, keys: ["updated_at", "updatedAt"]) {
            object["updated_at"] = updatedAt
        }

        let measurementValue = numericValue(in: object, keys: ["value"])
        if let measurementValue {
            object["value"] = measurementValue
        }

        let unit = stringValue(in: object, keys: ["unit"])
        if let unit {
            object["unit"] = unit
            object["original_unit"] = stringValue(in: object, keys: ["original_unit", "originalUnit"]) ?? unit
        }

        if let originalValue = numericValue(in: object, keys: ["original_value", "originalValue"]) ?? measurementValue {
            object["original_value"] = originalValue
        }

        let referenceRangeLow = numericValue(in: object, keys: ["reference_range_low", "referenceRangeLow"])
        let referenceRangeHigh = numericValue(in: object, keys: ["reference_range_high", "referenceRangeHigh"])
        if let referenceRangeLow {
            object["reference_range_low"] = referenceRangeLow
        }
        if let referenceRangeHigh {
            object["reference_range_high"] = referenceRangeHigh
        }

        if let measuredAt = normalizedDateOnlyString(
            stringValue(
                in: object,
                keys: ["measured_at", "measuredAt", "measured_date", "measuredDate", "created_at", "createdAt"]
            )
        ) {
            object["measured_at"] = measuredAt
        }

        let normalizedStatus = HealthMeasurementStatus.canonicalRawValue(
            for: stringValue(in: object, keys: ["status"]),
            value: measurementValue,
            referenceRangeLow: referenceRangeLow,
            referenceRangeHigh: referenceRangeHigh
        )
        if let normalizedStatus {
            object["status"] = normalizedStatus
        } else {
            object.removeValue(forKey: "status")
        }

        if let confidence = numericValue(in: object, keys: ["confidence", "ai_confidence", "aiConfidence"]) {
            object["confidence"] = confidence
        }

        object["source_type"] = HealthMeasurement.normalizedSourceType(
            stringValue(in: object, keys: ["source_type", "sourceType"])
        ) ?? "scan"
        object["manually_verified"] = boolValue(
            in: object,
            keys: ["manually_verified", "manuallyVerified"]
        ) ?? false

        [
            "medical_scan_id", "medicalScanId",
            "biomarker_name", "biomarkerName",
            "measured_date", "measuredDate",
            "ai_confidence", "aiConfidence",
            "user_corrected", "userCorrected",
            "sourceScanId", "markerId", "originalLabel",
            "originalUnit", "originalValue", "referenceRangeLow", "referenceRangeHigh",
            "sourceType", "manuallyVerified", "userId", "createdAt", "updatedAt"
        ].forEach { object.removeValue(forKey: $0) }

        return object
    }

    private nonisolated static func stringValue(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let rawValue = object[key] else { continue }
            if let stringValue = rawValue as? String {
                let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private nonisolated static func numericValue(in object: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            guard let rawValue = object[key] else { continue }
            if let number = rawValue as? NSNumber {
                return number.doubleValue
            }
            if let stringValue = rawValue as? String,
               let number = Double(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return number
            }
        }
        return nil
    }

    private nonisolated static func boolValue(in object: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            guard let rawValue = object[key] else { continue }
            if let boolValue = rawValue as? Bool {
                return boolValue
            }
            if let numberValue = rawValue as? NSNumber {
                return numberValue.boolValue
            }
            if let stringValue = rawValue as? String {
                switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "1":
                    return true
                case "false", "0":
                    return false
                default:
                    break
                }
            }
        }
        return nil
    }

    private nonisolated static func normalizedDateOnlyString(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        if HealthMeasurement.dateOnlyDate(from: rawValue) != nil {
            return rawValue
        }
        if let parsedDate = ISO8601DateFormatter.supabaseDate(from: rawValue) {
            return HealthMeasurement.dateOnlyString(from: parsedDate)
        }
        if let parsedDate = ISO8601DateFormatter.noFractionalDate(from: rawValue) {
            return HealthMeasurement.dateOnlyString(from: parsedDate)
        }
        return nil
    }

    private nonisolated static func serializeSanitizedBody(
        _ sanitized: Any,
        serializer: (Any) throws -> Data = { try JSONSerialization.data(withJSONObject: $0) }
    ) throws -> Data {
        try serializer(sanitized)
    }

    /// Classify an error into the sync engine's error categories.
    private func classifyError(_ error: NSError) -> ErrorCategory {
        if let status = error.userInfo["status"] as? Int {
            return classifyHTTPStatus(status)
        }

        if error.domain != NSURLErrorDomain, (400...599).contains(error.code) {
            return classifyHTTPStatus(error.code)
        }

        if error.domain == NSURLErrorDomain {
            return .network
        }

        return .unknown
    }

    private func classifyHTTPStatus(_ status: Int) -> ErrorCategory {
        if status == 401 || status == 403 {
            return .auth
        } else if status == 429 {
            return .rateLimited
        } else if status >= 400 && status < 500 {
            return .validation
        } else if status >= 500 {
            return .server
        }
        return .unknown
    }

    // MARK: - Outbox Operations

    /// Enqueue a mutation to the outbox for eventual sync.
    func enqueueMutation(_ event: OutboxEvent) async throws {
        if try await shouldSkipRestrictedMedicalEnqueue(for: event) {
            return
        }
        if try await shouldSkipCloudBackupRestrictedEnqueue(for: event) {
            return
        }
        // P1 #9: Block vector_memory push if user has not opted in.
        if try await shouldSkipVectorMemoryEnqueue(for: event) {
            return
        }
        try await dbQueue.write { db in
            try Self.insertPreparedMutation(event, into: db, deviceId: deviceId)
        }
    }

    func enqueueOrRefreshCanonicalUserUpsert(
        bodyJson: Data,
        userId: UUID,
        priority: Int
    ) async throws {
        try await dbQueue.write { db in
            let matchingIds = try Self.findCanonicalUserUpsertEventIds(userId: userId, in: db)
            if let primaryId = matchingIds.first {
                try db.execute(
                    sql: """
                        UPDATE outbox_events
                        SET status = ?, updated_at_local = ?,
                            priority = ?, body_json = ?,
                            attempt_count = 0, next_attempt_at = NULL,
                            last_error_category = NULL, last_error_code = NULL, last_error_message = NULL,
                            user_visible_blocker = 0
                        WHERE id = ? OR id = ?
                        """,
                    arguments: [
                        OutboxStatus.pending.rawValue,
                        Date(),
                        priority,
                        bodyJson,
                        primaryId,
                        primaryId.uuidString
                    ]
                )

                for duplicateId in matchingIds.dropFirst() {
                    try db.execute(
                        sql: "DELETE FROM outbox_events WHERE id = ? OR id = ?",
                        arguments: [duplicateId, duplicateId.uuidString]
                    )
                }
                return
            }

            let event = OutboxEvent(
                httpMethod: .POST,
                path: "rest/v1/users",
                bodyJson: bodyJson,
                priority: priority,
                idempotencyKey: "bootstrap-user-\(userId.uuidString.lowercased())"
            )
            try Self.insertPreparedMutation(event, into: db, deviceId: deviceId)
        }
    }

    func retryFailedPermanentEventsRecoverableFromUserBootstrap() async throws {
        try await dbQueue.write { db in
            let rootIds = try Self.findBootstrapRecoverablePermanentEventIds(in: db)
            guard !rootIds.isEmpty else { return }

            let now = Date()
            for eventId in rootIds {
                try db.execute(
                    sql: """
                        UPDATE outbox_events
                        SET status = ?, updated_at_local = ?,
                            attempt_count = 0, next_attempt_at = NULL,
                            last_error_category = NULL, last_error_code = NULL, last_error_message = NULL,
                            user_visible_blocker = 0
                        WHERE id = ? OR id = ?
                        """,
                    arguments: [
                        OutboxStatus.pending.rawValue,
                        now,
                        eventId,
                        eventId.uuidString
                    ]
                )
            }

            try Self.restoreCancelledDependents(of: rootIds, in: db, now: now)
        }
    }

    func cancelPendingEvents(matchingPaths paths: [String]) async throws {
        guard !paths.isEmpty else { return }

        try await dbQueue.write { db in
            for path in paths {
                try db.execute(
                    sql: """
                        UPDATE outbox_events
                        SET status = ?,
                            updated_at_local = ?,
                            next_attempt_at = NULL
                        WHERE path = ?
                          AND status IN (?, ?, ?)
                    """,
                    arguments: [
                        OutboxStatus.cancelled.rawValue,
                        Date(),
                        path,
                        OutboxStatus.pending.rawValue,
                        OutboxStatus.failedRetryable.rawValue,
                        OutboxStatus.inFlight.rawValue,
                    ]
                )
            }
        }
    }

    /// Perform an optimistic local write and queue the matching outbox event atomically.
    func performOptimisticMutation<T: Sendable>(
        _ operation: @escaping @Sendable (Database) throws -> (value: T, event: OutboxEvent)
    ) async throws -> T {
        try await dbQueue.write { db in
            let result = try operation(db)
            try Self.insertPreparedMutation(result.event, into: db, deviceId: deviceId)
            return result.value
        }
    }

    /// Variant of ``performOptimisticMutation`` for writes whose outbox event is
    /// optional (e.g. upserts that may resolve to a no-op). A returned event is
    /// committed in the SAME transaction as the local write, so a crash can never
    /// leave a local change without its queued sync event.
    func performConditionalOptimisticMutation<T: Sendable>(
        _ operation: @escaping @Sendable (Database) throws -> (value: T, event: OutboxEvent?)
    ) async throws -> T {
        try await dbQueue.write { db in
            let result = try operation(db)
            if let event = result.event {
                try Self.insertPreparedMutation(event, into: db, deviceId: deviceId)
            }
            return result.value
        }
    }

    /// Read from the sync-owned local database using the same queue as outbox operations.
    func readLocal<T: Sendable>(
        _ operation: @escaping @Sendable (Database) throws -> T
    ) async throws -> T {
        try await dbQueue.read(operation)
    }

    nonisolated private static func decodeHeaders(_ data: Data) -> [String: String] {
        guard !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let headers = object as? [String: String] else {
            return [:]
        }
        return headers
    }

    nonisolated private static func notificationDeliveryMode(from bodyJson: Data) -> NotificationOutboxDeliveryMode? {
        guard let object = try? JSONSerialization.jsonObject(with: bodyJson) as? [String: Any],
              let rawValue = object["delivery_mode"] as? String else {
            return nil
        }
        return NotificationOutboxDeliveryMode(rawValue: rawValue)
    }

    nonisolated private static func insertPreparedMutation(
        _ event: OutboxEvent,
        into db: Database,
        deviceId: String
    ) throws {
        let mutableEvent = try preparedMutation(event, deviceId: deviceId)
        try mutableEvent.insert(db)
    }

    nonisolated private static func preparedMutation(
        _ event: OutboxEvent,
        deviceId: String
    ) throws -> OutboxEvent {
        var mutableEvent = event
        if mutableEvent.idempotencyKey.isEmpty {
            mutableEvent.idempotencyKey = mutableEvent.id.uuidString
        }
        var headers = Self.decodeHeaders(mutableEvent.headersJson)
        headers["Idempotency-Key"] = headers["Idempotency-Key"] ?? mutableEvent.idempotencyKey
        headers["X-Device-Id"] = deviceId
        headers["X-Outbox-Replay"] = "true"
        headers["X-Correlation-Id"] = headers["X-Correlation-Id"] ?? mutableEvent.id.uuidString.lowercased()
        mutableEvent.headersJson = try JSONSerialization.data(withJSONObject: headers, options: [])
        return mutableEvent
    }

    private nonisolated static func findCanonicalUserUpsertEventIds(
        userId: UUID,
        in db: Database
    ) throws -> [UUID] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, body_json
                FROM outbox_events
                WHERE path = ?
                  AND status IN (?, ?, ?, ?, ?)
                ORDER BY created_at_local ASC
                """,
            arguments: [
                "rest/v1/users",
                OutboxStatus.pending.rawValue,
                OutboxStatus.failedRetryable.rawValue,
                OutboxStatus.failedPermanent.rawValue,
                OutboxStatus.inFlight.rawValue,
                OutboxStatus.cancelled.rawValue
            ]
        )

        let expectedUserId = userId.uuidString.lowercased()
        return rows.compactMap { row in
            guard let eventId = decodeUUID(from: row, column: "id") else {
                return nil
            }
            let bodyData: Data = row["body_json"]
            guard let object = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                  let bodyUserId = (object["id"] as? String)?.lowercased(),
                  bodyUserId == expectedUserId else {
                return nil
            }
            return eventId
        }
    }

    private nonisolated static func findBootstrapRecoverablePermanentEventIds(
        in db: Database
    ) throws -> [UUID] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, last_error_message
                FROM outbox_events
                WHERE status = ?
                  AND path <> ?
                  AND last_error_category IN (?, ?)
                ORDER BY created_at_local ASC
                """,
            arguments: [
                OutboxStatus.failedPermanent.rawValue,
                "rest/v1/users",
                ErrorCategory.auth.rawValue,
                ErrorCategory.validation.rawValue
            ]
        )

        return rows.compactMap { row in
            guard let eventId = decodeUUID(from: row, column: "id") else {
                return nil
            }
            let message: String = row["last_error_message"]
            let normalizedMessage = message.lowercased()
            let isRecoverable =
                normalizedMessage.contains("user_not_found") ||
                normalizedMessage.contains("row-level security") ||
                normalizedMessage.contains("violates row-level security policy") ||
                normalizedMessage.contains("permission denied") ||
                normalizedMessage.contains("\"code\":\"42501\"")
            return isRecoverable ? eventId : nil
        }
    }

    private nonisolated static func restoreCancelledDependents(
        of rootIds: [UUID],
        in db: Database,
        now: Date
    ) throws {
        var candidates = rootIds
        while !candidates.isEmpty {
            let parentId = candidates.removeFirst()
            let dependents = try UUID.fetchAll(
                db,
                sql: """
                    SELECT id
                    FROM outbox_events
                    WHERE (depends_on = ? OR depends_on = ?)
                      AND status = ?
                    """,
                arguments: [
                    parentId,
                    parentId.uuidString,
                    OutboxStatus.cancelled.rawValue
                ]
            )

            guard !dependents.isEmpty else { continue }

            try db.execute(
                sql: """
                    UPDATE outbox_events
                    SET status = ?, updated_at_local = ?,
                        attempt_count = 0, next_attempt_at = NULL,
                        last_error_category = NULL, last_error_code = NULL, last_error_message = NULL,
                        user_visible_blocker = 0
                    WHERE (depends_on = ? OR depends_on = ?)
                      AND status = ?
                    """,
                arguments: [
                    OutboxStatus.pending.rawValue,
                    now,
                    parentId,
                    parentId.uuidString,
                    OutboxStatus.cancelled.rawValue
                ]
            )

            candidates.append(contentsOf: dependents)
        }
    }

    private func shouldSkipRestrictedMedicalEnqueue(for event: OutboxEvent) async throws -> Bool {
        guard Self.restrictedMedicalPaths.contains(event.path) else {
            return false
        }

        return try await !shouldPullRestrictedMedicalData()
    }

    private func shouldSkipCloudBackupRestrictedEnqueue(for event: OutboxEvent) async throws -> Bool {
        guard Self.cloudBackupRestrictedPaths.contains(event.path) else {
            return false
        }

        return try await !shouldSyncUserHealthFlags()
    }

    /// P1 #9: Block vector_memory outbox events when user has not opted in.
    /// Mirrors the pull-side gate in `shouldPullVectorMemory()`.
    private func shouldSkipVectorMemoryEnqueue(for event: OutboxEvent) async throws -> Bool {
        guard event.path == "rest/v1/vector_memory" else {
            return false
        }
        return try await !shouldPullVectorMemory()
    }

    private func shouldCancelRestrictedMedicalEvent(_ event: OutboxEvent) async throws -> Bool {
        guard Self.restrictedMedicalPaths.contains(event.path) else {
            return false
        }

        return try await !shouldPullRestrictedMedicalData()
    }

    private func shouldCancelCloudBackupRestrictedEvent(_ event: OutboxEvent) async throws -> Bool {
        guard Self.cloudBackupRestrictedPaths.contains(event.path) else {
            return false
        }

        return try await !shouldSyncUserHealthFlags()
    }

    /// Returns count of pending (unsent) outbox events.
    func pendingEventCount() async throws -> Int {
        try await dbQueue.read { db in
            try OutboxEvent
                .filter(
                    Column("status") == OutboxStatus.pending.rawValue ||
                    Column("status") == OutboxStatus.failedRetryable.rawValue
                )
                .fetchCount(db)
        }
    }

    /// Returns all pending events in replay order (priority ASC, created_at_local ASC).
    func pendingEvents() async throws -> [OutboxEvent] {
        try await dbQueue.read { db in
            let now = Date()
            return try OutboxEvent.fetchAll(
                db,
                sql: """
                    SELECT
                        id,
                        created_at_local,
                        updated_at_local,
                        status,
                        priority,
                        depends_on,
                        http_method,
                        path,
                        headers_json,
                        body_json,
                        idempotency_key,
                        attempt_count,
                        next_attempt_at,
                        last_attempt_at,
                        last_error_category,
                        last_error_code,
                        last_error_message,
                        user_visible_blocker,
                        ui_hint_json
                    FROM outbox_events
                    WHERE status = ?
                       OR (
                            status = ?
                        AND (next_attempt_at IS NULL OR next_attempt_at <= ?)
                       )
                    ORDER BY priority ASC, created_at_local ASC
                    """,
                arguments: [
                    OutboxStatus.pending.rawValue,
                    OutboxStatus.failedRetryable.rawValue,
                    now
                ]
            )
        }
    }

    /// Mark an event as in-flight before sending.
    func markInFlight(_ eventId: UUID) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE outbox_events
                    SET status = ?, updated_at_local = ?, last_attempt_at = ?,
                        attempt_count = attempt_count + 1
                    WHERE id = ? OR id = ?
                    """,
                arguments: [
                    OutboxStatus.inFlight.rawValue,
                    Date(),
                    Date(),
                    eventId,
                    eventId.uuidString
                ]
            )
        }
    }

    /// Mark an event as succeeded after server confirms.
    func markSucceeded(_ eventId: UUID) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE outbox_events SET status = ?, updated_at_local = ? WHERE id = ? OR id = ?",
                arguments: [OutboxStatus.succeeded.rawValue, Date(), eventId, eventId.uuidString]
            )
        }
    }

    /// Mark an event as failed with error details.
    ///
    /// Reads `attempt_count`, computes the next attempt, and writes the final
    /// status inside a single write transaction. A read-then-write split would
    /// let an interleaved sync cycle double-increment attempts or clobber
    /// backoff state.
    func markFailed(
        _ eventId: UUID,
        category: ErrorCategory,
        code: String?,
        message: String?,
        retryable: Bool,
        retryAfterOverride: TimeInterval? = nil
    ) async throws {
        let permanentNotificationReconcileNeeded = try await dbQueue.write { db -> Bool in
            // P3 #25: Honor server Retry-After if provided (rate limiting)
            let attemptCount = try Int.fetchOne(
                db,
                sql: "SELECT attempt_count FROM outbox_events WHERE id = ? OR id = ? LIMIT 1",
                arguments: [eventId, eventId.uuidString]
            ) ?? 0

            let nextAttempt: Date? = retryable
                ? Date().addingTimeInterval(
                    retryAfterOverride ?? RetryConfig.delay(forAttempt: max(0, attemptCount - 1))
                )
                : nil

            var finalStatus: OutboxStatus = retryable
                ? .failedRetryable
                : .failedPermanent
            if retryable && attemptCount >= RetryConfig.maxAttempts {
                finalStatus = .failedPermanent
            }

            try db.execute(
                sql: """
                    UPDATE outbox_events
                    SET status = ?, updated_at_local = ?,
                        last_error_category = ?, last_error_code = ?, last_error_message = ?,
                        next_attempt_at = ?,
                        user_visible_blocker = CASE WHEN ? = 'failed_permanent' THEN 1 ELSE user_visible_blocker END
                    WHERE id = ? OR id = ?
                    """,
                arguments: [
                    finalStatus.rawValue, Date(),
                    category.rawValue, code, message,
                    nextAttempt,
                    finalStatus.rawValue,
                    eventId,
                    eventId.uuidString
                ]
            )

            if finalStatus == .failedPermanent {
                try Self.cancelDependentEvents(of: eventId, in: db)
                try Self.reconcilePermanentExperimentCreateFailure(eventId: eventId, in: db)
            }

            return finalStatus == .failedPermanent
        }

        if permanentNotificationReconcileNeeded {
            try await reconcilePermanentNotificationFailure(eventId: eventId)
        }
    }

    private func reconcileNotificationDispatchResponse(
        _ response: NotificationDispatchEdgeResponse,
        eventId: UUID,
        requestBody: Data
    ) async throws {
        guard Self.notificationDeliveryMode(from: requestBody) == .remoteOnly else {
            return
        }

        switch response.status {
        case "dropped":
            try await deleteNotificationLog(id: eventId)
        case "accepted":
            if !response.representsDeliveredNotification {
                try await deleteNotificationLog(id: eventId)
            }
        default:
            break
        }
    }

    private func reconcilePermanentNotificationFailure(eventId: UUID) async throws {
        let shouldDeleteNotificationLog = try await dbQueue.read { db -> Bool in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT path, body_json
                    FROM outbox_events
                    WHERE id = ? OR id = ?
                    LIMIT 1
                    """,
                arguments: [eventId, eventId.uuidString]
            ) else {
                return false
            }

            let path = (row["path"] as String?) ?? ""
            guard path == "send-notification",
                  let bodyJson = row["body_json"] as Data? else {
                return false
            }
            return Self.notificationDeliveryMode(from: bodyJson) == .remoteOnly
        }

        if shouldDeleteNotificationLog {
            try await deleteNotificationLog(id: eventId)
        }
    }

    private func deleteNotificationLog(id: UUID) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM notification_log WHERE id = ? OR id = ?",
                arguments: [id, id.uuidString]
            )
        }
    }

    /// Cancel an outbox event.
    /// P1 #8: Cascading cancel for dependent events (dead-letter prevention).
    func cancelEvent(_ eventId: UUID) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE outbox_events SET status = ?, updated_at_local = ? WHERE id = ? OR id = ?",
                arguments: [OutboxStatus.cancelled.rawValue, Date(), eventId, eventId.uuidString]
            )
            try Self.cancelDependentEvents(of: eventId, in: db)
        }
    }

    private nonisolated static func cancelDependentEvents(of eventId: UUID, in db: Database) throws {
        var candidates = [eventId]
        while !candidates.isEmpty {
            let parentId = candidates.removeFirst()
            let dependents = try UUID.fetchAll(
                db,
                sql: """
                    SELECT id
                    FROM outbox_events
                    WHERE (depends_on = ? OR depends_on = ?)
                      AND status IN (?, ?, ?)
                    """,
                arguments: [
                    parentId,
                    parentId.uuidString,
                    OutboxStatus.pending.rawValue,
                    OutboxStatus.failedRetryable.rawValue,
                    OutboxStatus.inFlight.rawValue,
                ]
            )

            if !dependents.isEmpty {
                try db.execute(
                    sql: """
                        UPDATE outbox_events
                        SET status = ?, updated_at_local = ?
                        WHERE (depends_on = ? OR depends_on = ?)
                          AND status IN (?, ?, ?)
                        """,
                    arguments: [
                        OutboxStatus.cancelled.rawValue,
                        Date(),
                        parentId,
                        parentId.uuidString,
                        OutboxStatus.pending.rawValue,
                        OutboxStatus.failedRetryable.rawValue,
                        OutboxStatus.inFlight.rawValue,
                    ]
                )
                candidates.append(contentsOf: dependents)
            }
        }
    }

    /// Quarantines the local experiment row when its create event dead-letters.
    ///
    /// User-authored records are never destroyed as a sync side effect. The row
    /// stays on device (hidden from lists via `sync_quarantine_reason`) and the
    /// outbox body remains available for bootstrap recovery, so a later
    /// successful replay + pull can restore full server state.
    private nonisolated static func reconcilePermanentExperimentCreateFailure(
        eventId: UUID,
        in db: Database
    ) throws {
        let path = try String.fetchOne(
            db,
            sql: """
                SELECT path
                FROM outbox_events
                WHERE id = ? OR id = ?
                LIMIT 1
                """,
            arguments: [eventId, eventId.uuidString]
        )
        guard path == "api-experiments/create" else { return }

        try db.execute(
            sql: """
                UPDATE experiments
                SET sync_quarantine_reason = ?, updated_at = ?
                WHERE (id = ? OR id = ?)
                  AND sync_quarantine_reason IS NULL
                """,
            arguments: [
                "permanent_create_failure:\(eventId.uuidString)",
                Date(),
                eventId,
                eventId.uuidString
            ]
        )
    }

    /// Returns first user-visible dead-letter blocker (failed_permanent + blocker flag).
    func userVisibleBlocker() async throws -> SyncBlockerSummary? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, path, last_error_category, last_error_message
                    FROM outbox_events
                    WHERE status = ?
                      AND user_visible_blocker = 1
                    ORDER BY updated_at_local ASC
                    LIMIT 1
                    """,
                arguments: [OutboxStatus.failedPermanent.rawValue]
            ) else {
                return nil
            }

            guard let id = Self.decodeUUID(from: row, column: "id") else {
                return nil
            }
            let path: String = row["path"]
            let categoryRaw: String? = row["last_error_category"]
            let category: ErrorCategory?
            if let categoryRaw, let resolvedCategory = ErrorCategory(rawValue: categoryRaw) {
                category = resolvedCategory
            } else {
                category = nil
            }
            let message: String? = row["last_error_message"]
            return SyncBlockerSummary(id: id, path: path, errorCategory: category, errorMessage: message)
        }
    }

    nonisolated private static func decodeUUID(from row: Row, column: String) -> UUID? {
        let value: DatabaseValue = row[column]

        if let uuidString = String.fromDatabaseValue(value), let uuid = UUID(uuidString: uuidString) {
            return uuid
        }
        if let uuid = UUID.fromDatabaseValue(value) {
            return uuid
        }
        if let uuidData = Data.fromDatabaseValue(value) {
            return decodeUUID(from: uuidData)
        }
        return nil
    }

    nonisolated private static func decodeUUID(from data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        let bytes = [UInt8](data)
        let uuidTuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuidTuple)
    }

    /// Re-queues a previously failed permanent event after user-fixed data.
    func retryFailedPermanentEvent(_ eventId: UUID) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE outbox_events
                    SET status = ?, updated_at_local = ?,
                        attempt_count = 0, next_attempt_at = NULL,
                        last_error_category = NULL, last_error_code = NULL, last_error_message = NULL,
                        user_visible_blocker = 0
                    WHERE (id = ? OR id = ?)
                      AND status = ?
                    """,
                arguments: [
                    OutboxStatus.pending.rawValue,
                    Date(),
                    eventId,
                    eventId.uuidString,
                    OutboxStatus.failedPermanent.rawValue
                ]
            )
        }
    }

    func outboxSLOSnapshot(windowHours: Int = 24) async throws -> OutboxSLOSnapshot {
        let boundedWindowHours = max(1, windowHours)
        let cutoff = Date().addingTimeInterval(TimeInterval(-boundedWindowHours * 3600))

        return try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        COUNT(*) AS total,
                        COALESCE(SUM(CASE WHEN status = ? THEN 1 ELSE 0 END), 0) AS pending_count,
                        COALESCE(SUM(CASE WHEN status = ? THEN 1 ELSE 0 END), 0) AS in_flight_count,
                        COALESCE(SUM(CASE WHEN status = ? THEN 1 ELSE 0 END), 0) AS succeeded_count,
                        COALESCE(SUM(CASE WHEN status = ? THEN 1 ELSE 0 END), 0) AS retryable_failed_count,
                        COALESCE(SUM(CASE WHEN status = ? THEN 1 ELSE 0 END), 0) AS permanent_failed_count
                    FROM outbox_events
                    WHERE updated_at_local >= ?
                    """,
                arguments: [
                    OutboxStatus.pending.rawValue,
                    OutboxStatus.inFlight.rawValue,
                    OutboxStatus.succeeded.rawValue,
                    OutboxStatus.failedRetryable.rawValue,
                    OutboxStatus.failedPermanent.rawValue,
                    cutoff
                ]
            ) else {
                throw NSError(
                    domain: "SyncEngine",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Outbox SLO aggregate returned no row; outbox_events schema may be damaged."]
                )
            }

            let total: Int = row["total"]
            let pending: Int = row["pending_count"]
            let inFlight: Int = row["in_flight_count"]
            let succeeded: Int = row["succeeded_count"]
            let retryableFailed: Int = row["retryable_failed_count"]
            let permanentFailed: Int = row["permanent_failed_count"]

            return OutboxSLOSnapshot(
                totalEvents: total,
                pendingEvents: pending,
                inFlightEvents: inFlight,
                succeededEvents: succeeded,
                retryableFailures: retryableFailed,
                permanentFailures: permanentFailed,
                windowHours: boundedWindowHours,
                evaluatedAt: Date()
            )
        }
    }

    func evaluateOutboxSLO(windowHours: Int = 24) async throws -> OutboxSLOEvaluation {
        let snapshot = try await outboxSLOSnapshot(windowHours: windowHours)
        let severity = Self.outboxSLOSeverity(for: snapshot)
        return OutboxSLOEvaluation(snapshot: snapshot, severity: severity)
    }

    private func evaluateAndEmitOutboxSLOAlert() async throws {
        let evaluation = try await evaluateOutboxSLO()
        guard evaluation.severity != .none else { return }

        logger.error(
            "Outbox SLO alert: severity=\\(evaluation.severity.rawValue, privacy: .public) failure_rate=\\(evaluation.snapshot.failureRate, privacy: .public) dead_letter_rate=\\(evaluation.snapshot.deadLetterRate, privacy: .public) total=\\(evaluation.snapshot.totalEvents, privacy: .public)"
        )

        NotificationCenter.default.post(
            name: Notification.Name("OutboxSLOAlert"),
            object: nil,
            userInfo: [
                "severity": evaluation.severity.rawValue,
                "failure_rate": evaluation.snapshot.failureRate,
                "dead_letter_rate": evaluation.snapshot.deadLetterRate,
                "total_events": evaluation.snapshot.totalEvents,
                "window_hours": evaluation.snapshot.windowHours
            ]
        )

        let now = Date()
        if let last = lastOutboxSLOTelemetry,
           last.severity == evaluation.severity,
           now.timeIntervalSince(last.at) < Self.sloTelemetryThrottleSeconds {
            return
        }

        do {
#if DEBUG
            if let override = Self.testEnqueueOutboxSLOAnalyticsOverride.value {
                try await override(evaluation, now)
            } else {
                try await enqueueOutboxSLOAnalyticsEvent(evaluation, observedAt: now)
            }
#else
            try await enqueueOutboxSLOAnalyticsEvent(evaluation, observedAt: now)
#endif
            lastOutboxSLOTelemetry = (severity: evaluation.severity, at: now)
        } catch {
            logger.error("Outbox SLO analytics enqueue failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func enqueueOutboxSLOAnalyticsEvent(
        _ evaluation: OutboxSLOEvaluation,
        observedAt: Date
    ) async throws {
        let properties: [String: Any] = [
            "severity": evaluation.severity.rawValue,
            "failure_rate": evaluation.snapshot.failureRate,
            "dead_letter_rate": evaluation.snapshot.deadLetterRate,
            "total_events": evaluation.snapshot.totalEvents,
            "pending_events": evaluation.snapshot.pendingEvents,
            "in_flight_events": evaluation.snapshot.inFlightEvents,
            "window_hours": evaluation.snapshot.windowHours,
            "source": "ios_sync_engine",
            "device_id": deviceId
        ]

        let payload: [String: Any] = [
            "events": [[
                "name": "sync_queue_slo_alert",
                "timestamp": ISO8601DateFormatter.supabaseString(from: observedAt),
                "properties": properties
            ]]
        ]

        let body = try JSONSerialization.data(withJSONObject: payload, options: [])
        let eventId = UUID()
        let headers: [String: String] = [
            "X-Outbox-Replay": "true",
            "X-Correlation-Id": eventId.uuidString.lowercased()
        ]

        var outboxEvent = OutboxEvent(
            id: eventId,
            httpMethod: .POST,
            path: "api-analytics-batch",
            bodyJson: body,
            priority: 30,
            idempotencyKey: eventId.uuidString.lowercased()
        )
        outboxEvent.headersJson = try JSONSerialization.data(withJSONObject: headers, options: [])
        try await enqueueMutation(outboxEvent)
    }

    nonisolated private static func outboxSLOSeverity(
        for snapshot: OutboxSLOSnapshot
    ) -> OutboxSLOAlertSeverity {
        if snapshot.totalEvents < outboxSLOMinSampleSize {
            return .none
        }
        if snapshot.failureRate >= outboxCriticalFailureRate ||
            snapshot.deadLetterRate >= outboxCriticalDeadLetterRate {
            return .critical
        }
        if snapshot.failureRate >= outboxWarningFailureRate ||
            snapshot.deadLetterRate >= outboxWarningDeadLetterRate {
            return .warning
        }
        return .none
    }

    // MARK: - Sync State

    /// Get sync state for a table.
    func syncState(for table: SyncableTable) async throws -> SyncState? {
        try await dbQueue.read { db in
            try SyncState.fetchOne(db, key: table.rawValue)
        }
    }

    /// Update sync watermark after successful pull.
    func updateSyncWatermark(table: String, serverTimestamp: Date) async throws {
        try await dbQueue.write { db in
            if var state = try SyncState.fetchOne(db, key: table) {
                state.lastPulledAtServer = serverTimestamp
                state.lastPullSuccessAt = Date()
                state.lastPullAttemptAt = Date()
                state.lastErrorCode = nil
                try state.update(db)
            } else {
                var state = SyncState(tableName: table)
                state.lastPulledAtServer = serverTimestamp
                state.lastPullSuccessAt = Date()
                state.lastPullAttemptAt = Date()
                try state.insert(db)
            }
        }
    }

    nonisolated private static func ensureLocalMetaDeviceId(dbQueue: DatabaseQueue, deviceId: String) {
        do {
            try dbQueue.write { db in
                let existingRow = try Row.fetchOne(db, sql: "SELECT device_id, schema_version FROM local_meta LIMIT 1")
                if let existingRow {
                    let existingDeviceId: String = existingRow["device_id"]
                    let existingSchemaVersion: Int = existingRow["schema_version"]
                    if existingDeviceId != deviceId {
                        try db.execute(sql: "DELETE FROM local_meta")
                        try db.execute(
                            sql: "INSERT INTO local_meta (device_id, schema_version) VALUES (?, ?)",
                            arguments: [deviceId, Migrations.latestSchemaVersion]
                        )
                    } else if existingSchemaVersion != Migrations.latestSchemaVersion {
                        try db.execute(
                            sql: "UPDATE local_meta SET schema_version = ? WHERE device_id = ?",
                            arguments: [Migrations.latestSchemaVersion, deviceId]
                        )
                    }
                    return
                }

                try db.execute(
                    sql: "INSERT INTO local_meta (device_id, schema_version) VALUES (?, ?)",
                    arguments: [deviceId, Migrations.latestSchemaVersion]
                )
            }
        } catch {
            handleEnsureLocalMetaDeviceIdFailure(error)
        }
    }

    nonisolated private static func handleEnsureLocalMetaDeviceIdFailure(_ error: Error) {
#if DEBUG
        if let handler = testEnsureLocalMetaFailureHandler.value {
            handler(error)
        }
#else
        assertionFailure("Failed to mirror device_id in local_meta: \(error)")
#endif
    }

    private func shouldPullRestrictedMedicalData() async throws -> Bool {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        guard let authId else { return false }

        return try await dbQueue.read { db in
            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                return false
            }

            // Local-only by default if no settings row exists.
            let isLocalOnly = try Bool.fetchOne(
                db,
                sql: """
                    SELECT medical_scan_local_only
                    FROM privacy_settings
                    WHERE user_id = ? OR user_id = ?
                    ORDER BY updated_at DESC
                    LIMIT 1
                    """,
                arguments: [userId, userId.uuidString]
            ) ?? true
            return !isLocalOnly
        }
    }

    private func shouldPullVectorMemory() async throws -> Bool {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        guard let authId else { return false }

        return try await dbQueue.read { db in
            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                return false
            }

            return try Bool.fetchOne(
                db,
                sql: """
                    SELECT vector_opt_in
                    FROM privacy_settings
                    WHERE user_id = ? OR user_id = ?
                    ORDER BY updated_at DESC
                    LIMIT 1
                    """,
                arguments: [userId, userId.uuidString]
            ) ?? false
        }
    }

    private func shouldSyncUserHealthFlags() async throws -> Bool {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        guard let authId else { return false }

        return try await dbQueue.read { db in
            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                return false
            }

            return try Bool.fetchOne(
                db,
                sql: """
                    SELECT cloud_backup_enabled
                    FROM privacy_settings
                    WHERE user_id = ? OR user_id = ?
                    ORDER BY updated_at DESC
                    LIMIT 1
                    """,
                arguments: [userId, userId.uuidString]
            ) ?? false
        }
    }

    private func shouldSyncMenstrualData() async throws -> Bool {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        guard let authId else { return false }

        return try await dbQueue.read { db in
            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                return false
            }

            // Default to true if not set? No, PrivacySettings init defaults to true (Local Only).
            // So if `menstrual_local_only` is true, we do NOT sync.
            let isLocalOnly = try Bool.fetchOne(
                db,
                sql: """
                    SELECT menstrual_local_only
                    FROM privacy_settings
                    WHERE user_id = ? OR user_id = ?
                    ORDER BY updated_at DESC
                    LIMIT 1
                    """,
                arguments: [userId, userId.uuidString]
            ) ?? true
            return !isLocalOnly
        }
    }

    // MARK: - Health Monitoring (§13)

    /// Returns sync health metrics for diagnostics.
    func healthMetrics() async throws -> SyncHealthMetrics {
        try await dbQueue.read { db in
            let pendingCount = try OutboxEvent
                .filter(
                    Column("status") == OutboxStatus.pending.rawValue ||
                    Column("status") == OutboxStatus.failedRetryable.rawValue
                )
                .fetchCount(db)

            let failedPermanentCount = try OutboxEvent
                .filter(Column("status") == OutboxStatus.failedPermanent.rawValue)
                .fetchCount(db)

            let oldestPendingDate = try Date.fetchOne(db,
                sql: """
                    SELECT MIN(created_at_local) FROM outbox_events
                    WHERE status IN (?, ?)
                    """,
                arguments: [OutboxStatus.pending.rawValue, OutboxStatus.failedRetryable.rawValue]
            )

            let oldestAgeHours: Double? = oldestPendingDate.map {
                Date().timeIntervalSince($0) / 3600
            }

            return SyncHealthMetrics(
                pendingCount: pendingCount,
                failedPermanentCount: failedPermanentCount,
                oldestPendingAgeHours: oldestAgeHours
            )
        }
    }
}

#if DEBUG
extension SyncEngine {
    func _testPullUsersTable() async throws {
        try await pullTable("users", type: User.self)
    }

    func _testPullSyncableTable(_ table: SyncableTable) async throws {
        try await pullSyncableTable(table)
    }

    func _testUpdatePullAttempt(table: String) async throws {
        try await updatePullAttempt(table: table)
    }

    func _testSendToServer(_ event: OutboxEvent) async throws {
        try await sendToServer(event)
    }

    func _testSanitizeOutboundBody(_ data: Data, path: String? = nil) throws -> Data {
        try sanitizeOutboundBody(data, path: path)
    }

    nonisolated static func _testSerializeSanitizedBodyFailure(
        sanitized: Any
    ) -> Error {
        struct SerializerError: LocalizedError { var errorDescription: String? { "forced" } }
        let forcedError = SerializerError()
        do {
            _ = try serializeSanitizedBody(sanitized) { _ in throw forcedError }
            return NSError(domain: "SyncEngineCoverage", code: -1, userInfo: [NSLocalizedDescriptionKey: "expected throw"])
        } catch {
            return error
        }
    }

    func _testClassifyError(_ error: NSError) -> ErrorCategory {
        classifyError(error)
    }

    func _testClassifyHTTPStatus(_ status: Int) -> ErrorCategory {
        classifyHTTPStatus(status)
    }

    func _testShouldPullRestrictedMedicalData() async throws -> Bool {
        try await shouldPullRestrictedMedicalData()
    }

    func _testShouldPullVectorMemory() async throws -> Bool {
        try await shouldPullVectorMemory()
    }

    func _testShouldSyncUserHealthFlags() async throws -> Bool {
        try await shouldSyncUserHealthFlags()
    }

    func _testShouldSyncMenstrualData() async throws -> Bool {
        try await shouldSyncMenstrualData()
    }

    func _testEvaluateAndEmitOutboxSLOAlert() async throws {
        try await evaluateAndEmitOutboxSLOAlert()
    }

    nonisolated static func _testDecodeHeaders(_ data: Data) -> [String: String] {
        decodeHeaders(data)
    }

    nonisolated static func _testDecodeUUID(from data: Data) -> UUID? {
        decodeUUID(from: data)
    }

    func _testDecodeUUIDFromRowVariants() async throws -> (uuid: UUID?, string: UUID?, data: UUID?, nilValue: UUID?) {
        try await dbQueue.read { db in
            let probe = UUID()
            let probeData = withUnsafeBytes(of: probe.uuid) { Data($0) }

            let uuidRow = try Row.fetchOne(db, sql: "SELECT ? AS id", arguments: [probe])
            let stringRow = try Row.fetchOne(db, sql: "SELECT ? AS id", arguments: [probe.uuidString])
            let dataRow = try Row.fetchOne(db, sql: "SELECT ? AS id", arguments: [probeData])
            let nilRow = try Row.fetchOne(db, sql: "SELECT NULL AS id")

            return (
                uuid: uuidRow.flatMap { Self.decodeUUID(from: $0, column: "id") },
                string: stringRow.flatMap { Self.decodeUUID(from: $0, column: "id") },
                data: dataRow.flatMap { Self.decodeUUID(from: $0, column: "id") },
                nilValue: nilRow.flatMap { Self.decodeUUID(from: $0, column: "id") }
            )
        }
    }

    nonisolated static func _testEnsureLocalMetaDeviceId(dbQueue: DatabaseQueue, deviceId: String) {
        ensureLocalMetaDeviceId(dbQueue: dbQueue, deviceId: deviceId)
    }

    nonisolated static func _testOutboxSLOSeverity(for snapshot: OutboxSLOSnapshot) -> OutboxSLOAlertSeverity {
        outboxSLOSeverity(for: snapshot)
    }

    nonisolated static func _testSetEnqueueOutboxSLOAnalyticsOverride(
        _ override: (@Sendable (OutboxSLOEvaluation, Date) async throws -> Void)?
    ) {
        testEnqueueOutboxSLOAnalyticsOverride.value = override
    }

    nonisolated static func _testSetEnsureLocalMetaFailureHandler(
        _ handler: (@Sendable (Error) -> Void)?
    ) {
        testEnsureLocalMetaFailureHandler.value = handler
    }
}
#endif

// MARK: - Sync Health Metrics

struct SyncHealthMetrics: Equatable, Sendable {
    let pendingCount: Int
    let failedPermanentCount: Int
    let oldestPendingAgeHours: Double?

    /// Whether the sync queue needs user attention.
    var needsAttention: Bool {
        if failedPermanentCount > 0 {
            return true
        }
        if let oldestPendingAgeHours {
            return oldestPendingAgeHours > 24
        }
        return false
    }

    /// Whether the sync is critically blocked (> 7 days).
    var isBlocked: Bool {
        if let oldestPendingAgeHours {
            return oldestPendingAgeHours > 168
        }
        return false
    }
}

struct SyncBlockerSummary: Equatable, Sendable {
    let id: UUID
    let path: String
    let errorCategory: ErrorCategory?
    let errorMessage: String?
}

private struct NotificationDispatchEdgeResponse: Decodable, Sendable {
    let status: String
    let reason: String?
    let dispatch: NotificationDispatchSummary?
    let deliveryState: String?

    var representsDeliveredNotification: Bool {
        if let dispatch {
            return dispatch.representsDeliveredNotification
        }

        if let deliveryState {
            switch deliveryState {
            case "sent", "partial":
                return true
            default:
                return false
            }
        }

        return false
    }

    enum CodingKeys: String, CodingKey {
        case status
        case reason
        case dispatch
        case deliveryState = "delivery_state"
    }
}

private struct NotificationDispatchSummary: Decodable, Sendable {
    let configured: Bool
    let attempted: Int
    let sent: Int
    let failed: Int
    let invalidTokens: [String]
    let deliveryState: String?

    var representsDeliveredNotification: Bool {
        if let deliveryState {
            switch deliveryState {
            case "sent", "partial":
                return true
            default:
                return false
            }
        }
        return configured && sent > 0
    }

    enum CodingKeys: String, CodingKey {
        case configured
        case attempted
        case sent
        case failed
        case invalidTokens = "invalid_tokens"
        case deliveryState = "delivery_state"
    }
}

// MARK: - Empty Response (for Edge Function calls that return nothing)

struct EmptyResponse: Decodable, Sendable {}
