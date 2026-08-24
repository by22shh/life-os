import Foundation
import Observation
import SwiftUI
import GRDB

@MainActor
@Observable
final class DiaryViewModel {
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
            let summary = try await dbQueue.read { db in
                try Self.loadSummary(day: day, authId: authId, db: db)
            }

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
        } catch {
            caloriesValue = "—"
            proteinValue = "—"
            fatValue = "—"
            carbsValue = "—"
            nutritionSubtitle = String(localized: "no_meals_logged")
            targetSummary = nil
        }

        // Load sleep & recovery
        do {
            let sleepData = try await dbQueue.read { db in
                try Self.loadSleepRecovery(day: day, authId: authId, db: db)
            }
            sleepSubtitle = sleepData.sleepSubtitle
            recoveryScoreText = sleepData.recoveryScoreText
            recoveryZoneIcon = sleepData.recoveryZoneIcon
            recoveryZoneColor = sleepData.recoveryZoneColor
        } catch {
            sleepSubtitle = String(localized: "no_sleep_data")
            recoveryScoreText = nil
            recoveryZoneIcon = nil
            recoveryZoneColor = nil
        }

        // Load training
        do {
            let trainingData = try await dbQueue.read { db in
                try Self.loadTraining(day: day, authId: authId, db: db)
            }
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
        } catch {
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

        // Load supplements
        do {
            let suppData = try await dbQueue.read { db in
                try Self.loadSupplements(day: day, authId: authId, db: db)
            }
            supplementsTakenCount = suppData.taken
            supplementsSubtitle = suppData.taken > 0
                ? String(format: String(localized: "diary_supplements_taken_format"), suppData.taken, suppData.total)
                : String(localized: "no_supplements_taken")
            supplementsDetail = suppData.names
        } catch {
            supplementsTakenCount = 0
            supplementsSubtitle = String(localized: "no_supplements_taken")
            supplementsDetail = ""
        }

        // Load labs
        do {
            let labsData = try await dbQueue.read { db in
                try Self.loadLabs(day: day, authId: authId, db: db)
            }
            labsSubtitle = labsData.subtitle
            labsDetail = labsData.detail
            labsMarkerCount = labsData.markerCount
        } catch {
            labsSubtitle = String(localized: "no_recent_labs")
            labsDetail = ""
            labsMarkerCount = 0
        }

        // Load hydration
        do {
            let hydrationData = try await dbQueue.read { db in
                try Self.loadHydration(day: day, authId: authId, db: db)
            }
            hydrationSubtitle = hydrationData.subtitle
            hydrationDetail = hydrationData.detail
            hydrationTotalMl = hydrationData.totalMl
            hydrationTargetMl = hydrationData.targetMl
        } catch {
            hydrationSubtitle = String(localized: "hydration_default_progress")
            hydrationDetail = "0 / 2000 ml"
            hydrationTotalMl = 0
            hydrationTargetMl = 2000
        }

        // Load wellness
        do {
            let wellnessData = try await dbQueue.read { db in
                try Self.loadWellness(day: day, authId: authId, db: db)
            }
            wellnessSubtitle = wellnessData.subtitle
            wellnessDetail = wellnessData.detail
            wellnessScoreText = wellnessData.scoreText
            hasCompletedWellnessCheck = wellnessData.completed
        } catch {
            wellnessSubtitle = String(localized: "not_completed")
            wellnessDetail = ""
            wellnessScoreText = nil
            hasCompletedWellnessCheck = false
        }

        // Load menstrual / cycle tracking
        do {
            let menstrualData = try await dbQueue.read { db in
                try Self.loadMenstrual(day: day, authId: authId, db: db)
            }
            menstrualSubtitle = menstrualData.subtitle
            menstrualDetail = menstrualData.detail
            hasMenstrualLog = menstrualData.hasLog
        } catch {
            menstrualSubtitle = String(localized: "menstrual_tracking_off")
            menstrualDetail = String(localized: "menstrual_diary_enable_personalization")
            hasMenstrualLog = false
        }

        let elapsedMs = Date().timeIntervalSince(start) * 1000
        PerformanceMonitor.trackDiaryLoad(durationMs: elapsedMs)
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
                ORDER BY updated_at DESC
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
                  AND deleted_at IS NULL
                ORDER BY scan_date DESC
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString]
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

        let flow = (row["flow"] as String?).flatMap(MenstrualFlow.init(rawValue:))
        let painLevel: Int? = row["pain_level"]
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
