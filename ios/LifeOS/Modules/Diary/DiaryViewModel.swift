import Foundation
import Observation
import SwiftUI
import GRDB
import os

/// Life area that contributed data to a day in the unified diary calendar.
enum DiaryRecordDomain: String, CaseIterable, Sendable, Hashable {
    case nutrition
    case training
    case sleep
    case recovery
    case supplements
    case hydration
    case wellness
    case body
    case labs
    case menstrual
    case experiments

    var title: String {
        switch self {
        case .nutrition: return String(localized: "diary_domain_nutrition")
        case .training: return String(localized: "diary_domain_training")
        case .sleep: return String(localized: "diary_domain_sleep")
        case .recovery: return String(localized: "diary_domain_recovery")
        case .supplements: return String(localized: "diary_domain_supplements")
        case .hydration: return String(localized: "diary_domain_hydration")
        case .wellness: return String(localized: "diary_domain_wellness")
        case .body: return String(localized: "diary_domain_body")
        case .labs: return String(localized: "diary_domain_labs")
        case .menstrual: return String(localized: "diary_domain_menstrual")
        case .experiments: return String(localized: "diary_domain_experiments")
        }
    }

    var color: Color {
        switch self {
        case .nutrition: return LifeOSColors.Semantic.primary
        case .training: return LifeOSColors.Semantic.warning
        case .sleep: return Color.indigo
        case .recovery: return LifeOSColors.Semantic.success
        case .supplements: return Color.purple
        case .hydration: return Color.teal
        case .wellness: return Color.pink
        case .body: return Color.brown
        case .labs: return Color.blue
        case .menstrual: return Color.red
        case .experiments: return Color.orange
        }
    }
}

@MainActor
@Observable
final class DiaryViewModel {
    private static let logger = Logger(subsystem: "com.lifeos.app", category: "DiaryViewModel")

    private(set) var recordedDomainsByDay: [String: Set<DiaryRecordDomain>] = [:]
    private(set) var monthDomains: [DiaryRecordDomain] = []
    var recordedDays: Set<String> { Set(recordedDomainsByDay.keys) }
    var hideCalories = false
    var caloriesValue = "—"
    var proteinValue = "—"
    var fatValue = "—"
    var carbsValue = "—"
    var nutritionSubtitle = String(localized: "no_meals_logged")
    var targetSummary: String?

    // Sleep & Recovery
    var sleepSubtitle = String(localized: "no_sleep_data")
    var recoveryScoreText: String?
    var recoveryZoneIcon: String?
    var recoveryZoneColor: Color?

    // Training
    var trainingSubtitle = String(localized: "no_workouts_today")
    var trainingDetail = ""
    var workoutCount: Int = 0

    // Training Load (ACWR)
    var acwrText: String?
    var trainingZoneLabel: String?
    var trainingZoneIcon: String?
    var trainingZoneColor: Color?
    var weeklyTrendLabel: String?
    var weeklyTrendIcon: String?

    // Supplements
    var supplementsSubtitle = String(localized: "no_supplements_taken")
    var supplementsDetail = ""
    var supplementsTakenCount: Int = 0

    // Labs
    var labsSubtitle = String(localized: "no_recent_labs")
    var labsDetail = ""
    var labsMarkerCount = 0

    // Hydration
    var hydrationSubtitle = String(localized: "hydration_default_progress")
    var hydrationDetail = "0 / 2000 ml"
    var hydrationTotalMl = 0
    var hydrationTargetMl = 2000

    // Wellness
    var wellnessSubtitle = String(localized: "not_completed")
    var wellnessDetail = ""
    var wellnessScoreText: String?
    var hasCompletedWellnessCheck = false

    // Menstrual / cycle tracking
    var menstrualSubtitle = String(localized: "menstrual_tracking_off")
    var menstrualDetail = String(localized: "menstrual_diary_enable_personalization")
    var hasMenstrualLog = false

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue) {
        self.dbQueue = dbQueue
    }

    func refresh(for selectedDate: Date) async {
        let start = Date()
        let day = DiaryDateFormatter.formatDate(selectedDate)
        let authId = AuthManager.activeAuthId?.uuidString

        do {
            let month = String(day.prefix(7))
            let context = try await dbQueue.read { db -> ([String: Set<DiaryRecordDomain>], Bool) in
                guard let userId = try Self.latestUserId(authId: authId, db: db) else { return ([:], false) }
                let flags = try UserHealthFlags.filter(Column("user_id") == userId.uuidString).fetchOne(db)
                var sources: [(table: String, column: String, softDelete: Bool, domain: DiaryRecordDomain)] = [
                    ("food_logs", "logged_date", true, .nutrition),
                    ("workout_sessions", "session_date", true, .training),
                    ("sleep_logs", "date", true, .sleep),
                    ("physiological_states", "date", false, .recovery),
                    ("supplement_logs", "taken_date", true, .supplements),
                    ("medical_scans", "scan_date", true, .labs),
                    ("hydration_logs", "logged_date", true, .hydration),
                    ("wellness_checks", "date", true, .wellness),
                    ("body_composition", "measured_date", true, .body),
                    ("experiment_measurements", "date", false, .experiments)
                ]
                if flags?.menstrualTrackingEnabled == true {
                    sources.append(("menstrual_logs", "date", true, .menstrual))
                }
                var domainsByDay: [String: Set<DiaryRecordDomain>] = [:]
                for source in sources {
                    let sql = "SELECT DISTINCT \(source.column) FROM \(source.table) WHERE (user_id = ? OR user_id = ?) AND \(source.column) BETWEEN ? AND ?" + (source.softDelete ? " AND deleted_at IS NULL" : "")
                    let days = try String.fetchAll(
                        db,
                        sql: sql,
                        arguments: [userId, userId.uuidString, month + "-01", month + "-31"]
                    )
                    for recordedDay in days {
                        domainsByDay[recordedDay, default: []].insert(source.domain)
                    }
                }
                return (domainsByDay, flags?.hideCalories ?? false)
            }
            recordedDomainsByDay = context.0
            monthDomains = DiaryRecordDomain.allCases.filter { domain in
                context.0.values.contains { $0.contains(domain) }
            }
            hideCalories = context.1
        } catch {
            recordedDomainsByDay = [:]
            monthDomains = []
            hideCalories = true
            Self.logger.error("Diary calendar load failed: \(error.localizedDescription)")
        }

        // All eight sections are independent reads: run them concurrently so
        // screen latency is the slowest query, not the sum of all queries.
        async let summarySection = Self.loadSection(Self.logger) {
            try await self.dbQueue.read { db in
                try Self.loadSummary(day: day, authId: authId, db: db)
            }
        }
        async let sleepSection = Self.loadSection(Self.logger) {
            try await self.dbQueue.read { db in
                try Self.loadSleepRecovery(day: day, authId: authId, db: db)
            }
        }
        async let trainingSection = Self.loadSection(Self.logger) {
            try await self.dbQueue.read { db in
                try Self.loadTraining(day: day, authId: authId, db: db)
            }
        }
        async let supplementsSection = Self.loadSection(Self.logger) {
            try await self.dbQueue.read { db in
                try Self.loadSupplements(day: day, authId: authId, db: db)
            }
        }
        async let labsSection = Self.loadSection(Self.logger) {
            try await self.dbQueue.read { db in
                try Self.loadLabs(day: day, authId: authId, db: db)
            }
        }
        async let hydrationSection = Self.loadSection(Self.logger) {
            try await self.dbQueue.read { db in
                try Self.loadHydration(day: day, authId: authId, db: db)
            }
        }
        async let wellnessSection = Self.loadSection(Self.logger) {
            try await self.dbQueue.read { db in
                try Self.loadWellness(day: day, authId: authId, db: db)
            }
        }
        async let menstrualSection = Self.loadSection(Self.logger) {
            try await self.dbQueue.read { db in
                try Self.loadMenstrual(day: day, authId: authId, db: db)
            }
        }

        let (summary, sleepData, trainingData, suppData, labsData, hydrationData, wellnessData, menstrualData) =
            await (summarySection, sleepSection, trainingSection, supplementsSection, labsSection, hydrationSection, wellnessSection, menstrualSection)

        if let summary {
            if summary.foodCount > 0 {
                caloriesValue = "\(Int(summary.calories.rounded()))"
                proteinValue = "\(Int(summary.protein.rounded()))"
                fatValue = "\(Int(summary.fat.rounded()))"
                carbsValue = "\(Int(summary.carbs.rounded()))"
                nutritionSubtitle = String(format: String(localized: "diary_meals_logged_format"), summary.foodCount)
            } else {
                caloriesValue = "—"
                proteinValue = "—"
                fatValue = "—"
                carbsValue = "—"
                nutritionSubtitle = String(localized: "no_meals_logged")
            }

            if let target = summary.target {
                targetSummary = String(
                    format: String(localized: "diary_target_summary_format"),
                    target.calories,
                    target.protein,
                    target.fat,
                    target.carbs
                )
            } else {
                targetSummary = nil
            }
        } else {
            caloriesValue = "—"
            proteinValue = "—"
            fatValue = "—"
            carbsValue = "—"
            nutritionSubtitle = String(localized: "no_meals_logged")
            targetSummary = nil
        }

        // Sleep & recovery
        if let sleepData {
            sleepSubtitle = sleepData.sleepSubtitle
            recoveryScoreText = sleepData.recoveryScoreText
            recoveryZoneIcon = sleepData.recoveryZoneIcon
            recoveryZoneColor = sleepData.recoveryZoneColor
        } else {
            sleepSubtitle = String(localized: "no_sleep_data")
            recoveryScoreText = nil
            recoveryZoneIcon = nil
            recoveryZoneColor = nil
        }

        // Training
        if let trainingData {
            workoutCount = trainingData.count
            trainingSubtitle = trainingData.count > 0
                ? String(format: String(localized: "diary_workouts_format"), trainingData.count)
                : String(localized: "no_workouts_today")
            trainingDetail = trainingData.detail
            acwrText = trainingData.acwrText
            trainingZoneLabel = trainingData.zoneLabel
            trainingZoneIcon = trainingData.zoneIcon
            trainingZoneColor = trainingData.zoneColor
            weeklyTrendLabel = trainingData.trendLabel
            weeklyTrendIcon = trainingData.trendIcon
        } else {
            workoutCount = 0
            trainingSubtitle = String(localized: "no_workouts_today")
            trainingDetail = ""
            acwrText = nil
            trainingZoneLabel = nil
            trainingZoneIcon = nil
            trainingZoneColor = nil
            weeklyTrendLabel = nil
            weeklyTrendIcon = nil
        }

        // Supplements
        if let suppData {
            supplementsTakenCount = suppData.taken
            supplementsSubtitle = suppData.taken > 0
                ? String(format: String(localized: "diary_supplements_taken_format"), suppData.taken, suppData.total)
                : String(localized: "no_supplements_taken")
            supplementsDetail = suppData.names
        } else {
            supplementsTakenCount = 0
            supplementsSubtitle = String(localized: "no_supplements_taken")
            supplementsDetail = ""
        }

        // Labs
        if let labsData {
            labsSubtitle = labsData.subtitle
            labsDetail = labsData.detail
            labsMarkerCount = labsData.markerCount
        } else {
            labsSubtitle = String(localized: "no_recent_labs")
            labsDetail = ""
            labsMarkerCount = 0
        }

        // Hydration
        if let hydrationData {
            hydrationSubtitle = hydrationData.subtitle
            hydrationDetail = hydrationData.detail
            hydrationTotalMl = hydrationData.totalMl
            hydrationTargetMl = hydrationData.targetMl
        } else {
            hydrationSubtitle = String(localized: "hydration_default_progress")
            hydrationDetail = "0 / 2000 ml"
            hydrationTotalMl = 0
            hydrationTargetMl = 2000
        }

        // Wellness
        if let wellnessData {
            wellnessSubtitle = wellnessData.subtitle
            wellnessDetail = wellnessData.detail
            wellnessScoreText = wellnessData.scoreText
            hasCompletedWellnessCheck = wellnessData.completed
        } else {
            wellnessSubtitle = String(localized: "not_completed")
            wellnessDetail = ""
            wellnessScoreText = nil
            hasCompletedWellnessCheck = false
        }

        // Menstrual / cycle tracking
        if let menstrualData {
            menstrualSubtitle = menstrualData.subtitle
            menstrualDetail = menstrualData.detail
            hasMenstrualLog = menstrualData.hasLog
        } else {
            menstrualSubtitle = String(localized: "menstrual_tracking_off")
            menstrualDetail = String(localized: "menstrual_diary_enable_personalization")
            hasMenstrualLog = false
        }

        let elapsedMs = Date().timeIntervalSince(start) * 1000
        PerformanceMonitor.trackDiaryLoad(durationMs: elapsedMs)
    }

    /// Runs one diary section query; a failure degrades that section to its
    /// empty state but is always logged so database issues stay diagnosable.
    private static func loadSection<T: Sendable>(
        _ logger: Logger,
        _ operation: @escaping @Sendable () async throws -> T
    ) async -> T? {
        do {
            return try await operation()
        } catch {
            logger.error("Diary section load failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    nonisolated private static func loadSummary(day: String, authId: String?, db: Database) throws -> DiarySummary {
        guard let userId = try latestUserId(authId: authId, db: db) else {
            return DiarySummary(
                foodCount: 0,
                calories: 0,
                protein: 0,
                fat: 0,
                carbs: 0,
                target: nil
            )
        }

        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT
                    COUNT(*) AS food_count,
                    COALESCE(SUM(calories), 0) AS calories,
                    COALESCE(SUM(protein_g), 0) AS protein_g,
                    COALESCE(SUM(fat_g), 0) AS fat_g,
                    COALESCE(SUM(carbs_g), 0) AS carbs_g
                FROM food_logs
                WHERE (user_id = ? OR user_id = ?)
                  AND logged_date = ?
                  AND deleted_at IS NULL
                """,
            arguments: [userId, userId.uuidString, day]
        )!

        let foodCount: Int = row["food_count"]
        let calories: Double = row["calories"]
        let protein: Double = row["protein_g"]
        let fat: Double = row["fat_g"]
        let carbs: Double = row["carbs_g"]

        let target = try resolvedTarget(for: day, userId: userId, db: db)
        return DiarySummary(
            foodCount: foodCount,
            calories: calories,
            protein: protein,
            fat: fat,
            carbs: carbs,
            target: target
        )
    }

    nonisolated private static func resolvedTarget(for day: String, userId: UUID, db: Database) throws -> DiaryTarget? {
        if let existing = try DailyNutritionTarget.fetchOne(
            db,
            sql: """
                SELECT *
                FROM daily_nutrition_targets
                WHERE (user_id = ? OR user_id = ?)
                  AND date = ?
                ORDER BY updated_at DESC
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString, day]
        ) {
            if let calories = existing.finalCalories,
               let protein = existing.finalProteinG,
               let fat = existing.finalFatG,
               let carbs = existing.finalCarbsG {
                return DiaryTarget(calories: calories, protein: protein, fat: fat, carbs: carbs)
            }
        }

        let effectiveWeight = try WeightResolution.getEffectiveWeight(userId: userId, db: db) ?? 70.0
        let recoveredScore = try Double.fetchOne(
            db,
            sql: """
                SELECT recovery_score
                FROM physiological_states
                WHERE (user_id = ? OR user_id = ?)
                  AND date = ?
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString, day]
        )
        let recoveryScore: Double
        if let recoveredScore {
            recoveryScore = recoveredScore
        } else {
            recoveryScore = 50.0
        }
        let activeCalories = try Int.fetchOne(
            db,
            sql: "SELECT daily_active_calories FROM training_loads WHERE (user_id = ? OR user_id = ?) AND date = ? LIMIT 1",
            arguments: [userId, userId.uuidString, day]
        )
        let dailyTrimp = try Double.fetchOne(
            db,
            sql: "SELECT daily_trimp FROM training_loads WHERE (user_id = ? OR user_id = ?) AND date = ? LIMIT 1",
            arguments: [userId, userId.uuidString, day]
        )

        let baseCalories = 2_200.0
        let baseProtein = 1.6 * effectiveWeight
        let baseFat = 0.8 * effectiveWeight
        let baseCarbs = max(120, (baseCalories - ((baseProtein * 4) + (baseFat * 9))) / 4)

        let weightFactor = NutritionTargetEngine.weightFactor(effectiveWeightKg: effectiveWeight)
        let recoveryAdjustment = NutritionTargetEngine.recoveryAdjustment(recoveryScore: recoveryScore)
        let trainingKcal = NutritionTargetEngine.trainingAdjustmentKcal(
            activeEnergyKcal: activeCalories.map(Double.init),
            dailyTrimp: dailyTrimp,
            effectiveWeightKg: effectiveWeight
        )

        let adjustedCalories = NutritionTargetEngine.adjustedCalories(
            baseCalories: baseCalories,
            effectiveWeightKg: effectiveWeight,
            recoveryScore: recoveryScore
        ) + Double(trainingKcal)
        let adjustedProtein = (baseProtein * weightFactor) + (recoveryAdjustment.proteinDeltaGPerKg * effectiveWeight)
        let adjustedFat = baseFat * weightFactor
        let adjustedCarbs = baseCarbs * recoveryAdjustment.carbMultiplier * weightFactor

        return DiaryTarget(
            calories: Int(adjustedCalories.rounded()),
            protein: Int(adjustedProtein.rounded()),
            fat: Int(adjustedFat.rounded()),
            carbs: Int(adjustedCarbs.rounded())
        )
    }

    nonisolated private static func latestUserId(authId: String?, db: Database) throws -> UUID? {
        try UserIdentityLookup.resolveUserId(authId: authId, db: db)
    }

    // MARK: - Sleep & Recovery

    private struct SleepRecoveryData {
        var sleepSubtitle: String
        var recoveryScoreText: String?
        var recoveryZoneIcon: String?
        var recoveryZoneColor: Color?
    }

    nonisolated private static func loadSleepRecovery(day: String, authId: String?, db: Database) throws -> SleepRecoveryData {
        guard let userId = try latestUserId(authId: authId, db: db) else {
            return SleepRecoveryData(sleepSubtitle: String(localized: "no_sleep_data"))
        }

        // Sleep
        let sleepRow = try Row.fetchOne(
            db,
            sql: """
                SELECT total_duration_minutes, sleep_efficiency
                FROM sleep_logs
                WHERE (user_id = ? OR user_id = ?)
                  AND COALESCE(sleep_date, date) = ?
                  AND deleted_at IS NULL
                ORDER BY (source = 'manual') DESC, updated_at DESC, created_at DESC
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString, day]
        )
        var sleepSubtitle = String(localized: "no_sleep_data")
        if let sleepRow, let durationMinutes: Int = sleepRow["total_duration_minutes"], durationMinutes > 0 {
            let hours = durationMinutes / 60
            let mins = durationMinutes % 60
            sleepSubtitle = "\(hours)h \(mins)m"
        }

        // Recovery
        let recoveryRow = try Row.fetchOne(
            db,
            sql: """
                SELECT recovery_score, confidence_score
                FROM physiological_states
                WHERE (user_id = ? OR user_id = ?) AND date = ?
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString, day]
        )

        var recoveryScoreText: String?
        var recoveryZoneIcon: String?
        var recoveryZoneColor: Color?
        if let recoveryRow, let score: Double = recoveryRow["recovery_score"] {
            let zone = RecoveryZone.from(score: score)
            recoveryScoreText = "\(Int(score.rounded()))%"
            recoveryZoneIcon = zone.iconName
            recoveryZoneColor = zone.color
        }

        return SleepRecoveryData(
            sleepSubtitle: sleepSubtitle,
            recoveryScoreText: recoveryScoreText,
            recoveryZoneIcon: recoveryZoneIcon,
            recoveryZoneColor: recoveryZoneColor
        )
    }

    // MARK: - Training

    private struct TrainingData {
        var count: Int
        var detail: String
        // ACWR
        var acwrText: String?
        var zoneLabel: String?
        var zoneIcon: String?
        var zoneColor: Color?
        var trendLabel: String?
        var trendIcon: String?
    }

    nonisolated private static func loadTraining(day: String, authId: String?, db: Database) throws -> TrainingData {
        guard let userId = try latestUserId(authId: authId, db: db) else {
            return TrainingData(count: 0, detail: "")
        }

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT workout_type, duration_minutes
                FROM workout_sessions
                WHERE (user_id = ? OR user_id = ?)
                  AND session_date = ?
                  AND deleted_at IS NULL
                ORDER BY started_at DESC
                """,
            arguments: [userId, userId.uuidString, day]
        )

        let count = rows.count
        if count == 0 {
            return TrainingData(count: 0, detail: "")
        }

        let parts = rows.prefix(3).compactMap { row -> String? in
            let workoutType: String? = row["workout_type"]
            let durationMinutes: Int? = row["duration_minutes"]
            var label = workoutType?.capitalized ?? String(localized: "workout")
            if let durationMinutes, durationMinutes > 0 {
                label += " – \(durationMinutes) min"
            }
            return label
        }

        // Load ACWR data from training_loads
        var acwrText: String?
        var zoneLabel: String?
        var zoneIcon: String?
        var zoneColor: Color?
        var trendLabel: String?
        var trendIcon: String?

        let loadRow = try Row.fetchOne(
            db,
            sql: """
                SELECT acute_load_7d, chronic_load_28d, training_zone, weekly_trend
                FROM training_loads
                WHERE (user_id = ? OR user_id = ?)
                  AND date = ?
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString, day]
        )

        if let loadRow {
            let acuteLoad: Double? = loadRow["acute_load_7d"]
            let chronicLoad: Double? = loadRow["chronic_load_28d"]

            // Count total days for cold-start gating
            let daysOfData = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(DISTINCT date)
                    FROM training_loads
                    WHERE (user_id = ? OR user_id = ?)
                      AND daily_trimp IS NOT NULL
                    """,
                arguments: [userId, userId.uuidString]
            ) ?? 0

            if let safeAcwr = TrainingLoad.safeACWR(
                acuteLoad7d: acuteLoad,
                chronicLoad28d: chronicLoad,
                daysOfData: daysOfData
            ) {
                acwrText = String(format: "%.2f", safeAcwr)
            }

            if let zoneRaw: String = loadRow["training_zone"],
               let zone = TrainingZoneState(rawValue: zoneRaw) {
                zoneLabel = zone.label
                zoneIcon = zone.iconName
                zoneColor = zone.color
            }

            if let trendRaw: String = loadRow["weekly_trend"],
               let trend = WeeklyTrend(rawValue: trendRaw) {
                trendLabel = trend.label
                trendIcon = trend.iconName
            }
        }

        return TrainingData(
            count: count,
            detail: parts.joined(separator: ", "),
            acwrText: acwrText,
            zoneLabel: zoneLabel,
            zoneIcon: zoneIcon,
            zoneColor: zoneColor,
            trendLabel: trendLabel,
            trendIcon: trendIcon
        )
    }

    // MARK: - Supplements

    private struct SupplementsData {
        var taken: Int
        var total: Int
        var names: String
    }

    nonisolated private static func loadSupplements(day: String, authId: String?, db: Database) throws -> SupplementsData {
        guard let userId = try latestUserId(authId: authId, db: db) else {
            return SupplementsData(taken: 0, total: 0, names: "")
        }

        let takenCount = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM supplement_logs
                WHERE (user_id = ? OR user_id = ?)
                  AND taken_date = ?
                  AND deleted_at IS NULL
                """,
            arguments: [userId, userId.uuidString, day]
        )!

        let totalActive = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM user_supplements
                WHERE (user_id = ? OR user_id = ?)
                  AND active = 1
                """,
            arguments: [userId, userId.uuidString]
        )!

        let names = try String.fetchAll(
            db,
            sql: """
                SELECT supplement_name
                FROM supplement_logs
                WHERE (user_id = ? OR user_id = ?)
                  AND taken_date = ?
                  AND deleted_at IS NULL
                ORDER BY taken_at DESC
                LIMIT 5
                """,
            arguments: [userId, userId.uuidString, day]
        ).joined(separator: ", ")

        return SupplementsData(taken: takenCount, total: max(totalActive, takenCount), names: names)
    }

    // MARK: - Labs

    private struct LabsData {
        var subtitle: String
        var detail: String
        var markerCount: Int
    }

    nonisolated private static func loadLabs(day: String, authId: String?, db: Database) throws -> LabsData {
        guard let userId = try latestUserId(authId: authId, db: db) else {
            return LabsData(subtitle: String(localized: "no_recent_labs"), detail: "", markerCount: 0)
        }

        let latestScan = try Row.fetchOne(
            db,
            sql: """
                SELECT id, scan_date, status, markers_extracted
                FROM medical_scans
                WHERE (user_id = ? OR user_id = ?)
                  AND scan_date = ?
                  AND deleted_at IS NULL
                ORDER BY scan_date DESC
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString, day]
        )

        if let latestScan, let scanDate: String = latestScan["scan_date"] {
            let markerCount = (latestScan["markers_extracted"] as Int?) ?? 0
            let status: String = (latestScan["status"] as String?) ?? ScanStatus.completed.rawValue
            let detail = markerCount > 0 ? "\(markerCount) markers • \(status.replacingOccurrences(of: "_", with: " ").capitalized)" : status.replacingOccurrences(of: "_", with: " ").capitalized
            return LabsData(
                subtitle: String(format: String(localized: "labs_latest_date_format"), scanDate),
                detail: detail,
                markerCount: markerCount
            )
        }
        return LabsData(subtitle: String(localized: "no_recent_labs"), detail: "", markerCount: 0)
    }

    // MARK: - Hydration

    private struct HydrationData {
        var subtitle: String
        var detail: String
        var totalMl: Int
        var targetMl: Int
    }

    nonisolated private static func loadHydration(day: String, authId: String?, db: Database) throws -> HydrationData {
        guard let userId = try latestUserId(authId: authId, db: db) else {
            return HydrationData(
                subtitle: String(localized: "hydration_default_progress"),
                detail: "0 / 2000 ml",
                totalMl: 0,
                targetMl: 2000
            )
        }

        let totalMl = try Int.fetchOne(
            db,
            sql: """
                SELECT COALESCE(SUM(water_ml), 0)
                FROM hydration_logs
                WHERE (user_id = ? OR user_id = ?)
                  AND logged_date = ?
                  AND deleted_at IS NULL
                """,
            arguments: [userId, userId.uuidString, day]
        ) ?? 0

        let effectiveWeight = try WeightResolution.getEffectiveWeight(userId: userId, db: db) ?? 70.0
        let targetMl = max(1_800, Int((effectiveWeight * 35).rounded()))
        let progressPercent = min(100, Int((Double(totalMl) / Double(max(targetMl, 1)) * 100).rounded()))

        return HydrationData(
            subtitle: totalMl == 0 ? String(localized: "hydration_default_progress") : "\(progressPercent)% of target",
            detail: "\(totalMl) / \(targetMl) ml",
            totalMl: totalMl,
            targetMl: targetMl
        )
    }

    // MARK: - Wellness

    private struct WellnessData {
        var subtitle: String
        var detail: String
        var scoreText: String?
        var completed: Bool
    }

    nonisolated private static func loadWellness(day: String, authId: String?, db: Database) throws -> WellnessData {
        guard let userId = try latestUserId(authId: authId, db: db) else {
            return WellnessData(
                subtitle: String(localized: "not_completed"),
                detail: "",
                scoreText: nil,
                completed: false
            )
        }

        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT wellness_score, feeling_ill, headache, digestive_issues
                FROM wellness_checks
                WHERE (user_id = ? OR user_id = ?)
                  AND date = ?
                  AND deleted_at IS NULL
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString, day]
        ) else {
            return WellnessData(
                subtitle: String(localized: "not_completed"),
                detail: "",
                scoreText: nil,
                completed: false
            )
        }

        let score = (row["wellness_score"] as Double?) ?? 0
        let scoreText = "\(Int(score.rounded()))%"
        let hasIllness: Bool = row["feeling_ill"] ?? false
        let hasHeadache: Bool = row["headache"] ?? false
        let hasDigestiveIssues: Bool = row["digestive_issues"] ?? false
        let flags = [
            hasIllness ? "illness" : nil,
            hasHeadache ? "headache" : nil,
            hasDigestiveIssues ? "digestive" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: ", ")

        return WellnessData(
            subtitle: "Completed",
            detail: flags.isEmpty ? "Score \(scoreText)" : "Score \(scoreText) • \(flags)",
            scoreText: scoreText,
            completed: true
        )
    }

    // MARK: - Menstrual / Cycle Tracking

    private struct MenstrualData {
        var subtitle: String
        var detail: String
        var hasLog: Bool
    }

    nonisolated private static func loadMenstrual(day: String, authId: String?, db: Database) throws -> MenstrualData {
        guard let userId = try latestUserId(authId: authId, db: db) else {
            return MenstrualData(
                subtitle: String(localized: "menstrual_tracking_off"),
                detail: String(localized: "menstrual_diary_enable_personalization"),
                hasLog: false
            )
        }

        let trackingEnabled = try Bool.fetchOne(
            db,
            sql: """
                SELECT menstrual_tracking_enabled
                FROM user_health_flags
                WHERE (user_id = ? OR user_id = ?)
                ORDER BY updated_at DESC
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString]
        ) ?? false

        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT flow, pain_level
                FROM menstrual_logs
                WHERE (user_id = ? OR user_id = ?)
                  AND date = ?
                  AND deleted_at IS NULL
                ORDER BY updated_at DESC
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString, day]
        ) else {
            return MenstrualData(
                subtitle: trackingEnabled
                    ? String(localized: "menstrual_diary_empty")
                    : String(localized: "menstrual_tracking_off"),
                detail: trackingEnabled
                    ? String(localized: "menstrual_diary_open_to_log")
                    : String(localized: "menstrual_diary_enable_personalization"),
                hasLog: false
            )
        }

        let flow = (row["flow"] as String?)
            .flatMap(FieldEncryption.decryptStoredString)
            .flatMap(MenstrualFlow.init(rawValue:))
        let painLevel = GRDBRecordDecoder.encryptedDouble(row, column: "pain_level")
            .map { Int($0.rounded()) }
        let summary = MenstrualDayViewModel.sharedSummary(flow: flow, painLevel: painLevel)

        return MenstrualData(
            subtitle: summary,
            detail: trackingEnabled
                ? String(localized: "menstrual_diary_review_detail")
                : String(localized: "menstrual_diary_tracking_logged_off"),
            hasLog: true
        )
    }
}

struct DiaryDateFormatter {
    static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct DiarySummary {
    let foodCount: Int
    let calories: Double
    let protein: Double
    let fat: Double
    let carbs: Double
    let target: DiaryTarget?
}

struct DiaryTarget {
    let calories: Int
    let protein: Int
    let fat: Int
    let carbs: Int
}

#if DEBUG
extension DiaryViewModel {
    nonisolated static func _testLoadSummary(day: String, authId: String?, db: Database) throws -> DiarySummary {
        try loadSummary(day: day, authId: authId, db: db)
    }

    nonisolated static func _testResolvedTarget(for day: String, userId: UUID, db: Database) throws -> DiaryTarget? {
        try resolvedTarget(for: day, userId: userId, db: db)
    }

    nonisolated static func _testLatestUserId(authId: String?, db: Database) throws -> UUID? {
        try latestUserId(authId: authId, db: db)
    }

    nonisolated static func _testLoadSleepRecovery(day: String, authId: String?, db: Database) throws -> (sleepSubtitle: String, recoveryScoreText: String?, recoveryZoneIcon: String?, recoveryZoneColor: Color?) {
        let data = try loadSleepRecovery(day: day, authId: authId, db: db)
        return (data.sleepSubtitle, data.recoveryScoreText, data.recoveryZoneIcon, data.recoveryZoneColor)
    }

    nonisolated static func _testLoadTraining(day: String, authId: String?, db: Database) throws -> (count: Int, detail: String) {
        let data = try loadTraining(day: day, authId: authId, db: db)
        return (data.count, data.detail)
    }

    nonisolated static func _testLoadSupplements(day: String, authId: String?, db: Database) throws -> (taken: Int, total: Int, names: String) {
        let data = try loadSupplements(day: day, authId: authId, db: db)
        return (data.taken, data.total, data.names)
    }

    nonisolated static func _testLoadLabs(day: String, authId: String?, db: Database) throws -> String {
        let data = try loadLabs(day: day, authId: authId, db: db)
        return data.subtitle
    }

    nonisolated static func _testLoadTrainingLoad(day: String, authId: String?, db: Database) throws -> (acwrText: String?, zoneLabel: String?, trendLabel: String?) {
        let data = try loadTraining(day: day, authId: authId, db: db)
        return (data.acwrText, data.zoneLabel, data.trendLabel)
    }

    nonisolated static func _testLoadMenstrual(day: String, authId: String?, db: Database) throws -> (subtitle: String, detail: String, hasLog: Bool) {
        let data = try loadMenstrual(day: day, authId: authId, db: db)
        return (data.subtitle, data.detail, data.hasLog)
    }
}
#endif
