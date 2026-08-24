import Foundation
import GRDB

protocol WeeklyStrategyManaging: Sendable {
    func refreshCurrentWeekReport() async throws -> WeeklyStrategyReport?
}

protocol WeeklyStrategyRouteAPIClient: Sendable {
    func fetchWeeklyStrategyReport(weekStart: String) async throws -> WeeklyStrategyEdgeResponse
}

struct WeeklyStrategyEdgeResponse: Decodable, Sendable {
    let reportId: UUID
    let createdAt: Date
    let updatedAt: Date
    let weekStart: String
    let weekEnd: String
    let reportMarkdown: String
    let summaryStats: Data
    let modelUsed: String?
    let promptVersion: String?

    enum CodingKeys: String, CodingKey {
        case reportId = "report_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case weekStart = "week_start"
        case weekEnd = "week_end"
        case reportMarkdown = "report_markdown"
        case summaryStats = "summary_stats"
        case modelUsed = "model_used"
        case promptVersion = "prompt_version"
    }
}

private struct WeeklyStrategySummaryStats: Codable, Equatable, Sendable {
    let avgRecoveryScore: Double
    let recoveryTrend: String
    let daysInOptimalZone: Int
    let daysInCriticalZone: Int
    let avgSleepDuration: Double
    let sleepConsistency: Double
    let nutritionAdherence: Double
    let trainingVolume: Double
    let allostaticLoad: Double

    enum CodingKeys: String, CodingKey {
        case avgRecoveryScore = "avg_recovery_score"
        case recoveryTrend = "recovery_trend"
        case daysInOptimalZone = "days_in_optimal_zone"
        case daysInCriticalZone = "days_in_critical_zone"
        case avgSleepDuration = "avg_sleep_duration"
        case sleepConsistency = "sleep_consistency"
        case nutritionAdherence = "nutrition_adherence"
        case trainingVolume = "training_volume"
        case allostaticLoad = "allostatic_load"
    }
}

private struct WeeklyStrategyRecoveryRow: FetchableRecord, Decodable, Sendable {
    let date: String
    let recoveryScore: Double?
    let recoveryZone: String?
    let allostaticLoad: Double?
}

private struct WeeklyStrategySleepRow: FetchableRecord, Decodable, Sendable {
    let date: String
    let sleepDurationHours: Double?
}

private struct WeeklyStrategyNutritionRow: FetchableRecord, Decodable, Sendable {
    let loggedDate: String
}

private struct WeeklyStrategyWorkoutRow: FetchableRecord, Decodable, Sendable {
    let sessionDate: String
    let trimpScore: Double?
}

actor WeeklyStrategyService: WeeklyStrategyManaging {
    private struct LocalContext: Sendable {
        let userId: UUID
        let weekStart: String
        let weekEnd: String
        let generatedAt: Date
        let recoveryRows: [WeeklyStrategyRecoveryRow]
        let sleepRows: [WeeklyStrategySleepRow]
        let nutritionRows: [WeeklyStrategyNutritionRow]
        let workoutRows: [WeeklyStrategyWorkoutRow]
    }

    private let dbQueue: DatabaseQueue
    private let apiClient: any WeeklyStrategyRouteAPIClient
    private let nowProvider: @Sendable () -> Date

    init(
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue,
        apiClient: any WeeklyStrategyRouteAPIClient = APIClient(),
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.dbQueue = dbQueue
        self.apiClient = apiClient
        self.nowProvider = nowProvider
    }

    func refreshCurrentWeekReport() async throws -> WeeklyStrategyReport? {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        guard let authId else { return nil }
        let generatedAt = nowProvider()

        let context = try await dbQueue.read { db -> LocalContext? in
            guard let user = try UserIdentityLookup.fetchUser(authId: authId, db: db) else {
                return nil
            }

            let timeZone = Self.resolvedTimeZone(identifier: user.timezone)
            let weekRange = Self.weekRange(containing: generatedAt, timeZone: timeZone)
            let arguments: StatementArguments = [
                user.id,
                user.id.uuidString,
                weekRange.start,
                weekRange.end
            ]

            let recoveryRows = try WeeklyStrategyRecoveryRow.fetchAll(
                db,
                sql: """
                    SELECT
                        date,
                        recovery_score AS recoveryScore,
                        recovery_zone AS recoveryZone,
                        allostatic_load AS allostaticLoad
                    FROM physiological_states
                    WHERE (user_id = ? OR user_id = ?)
                      AND date >= ?
                      AND date <= ?
                    ORDER BY date ASC
                    """,
                arguments: arguments
            )

            let sleepRows = try WeeklyStrategySleepRow.fetchAll(
                db,
                sql: """
                    SELECT
                        date,
                        sleep_duration_hours AS sleepDurationHours
                    FROM physiological_states
                    WHERE (user_id = ? OR user_id = ?)
                      AND date >= ?
                      AND date <= ?
                    ORDER BY date ASC
                    """,
                arguments: arguments
            )

            let nutritionRows = try WeeklyStrategyNutritionRow.fetchAll(
                db,
                sql: """
                    SELECT logged_date AS loggedDate
                    FROM food_logs
                    WHERE (user_id = ? OR user_id = ?)
                      AND logged_date >= ?
                      AND logged_date <= ?
                      AND deleted_at IS NULL
                    """,
                arguments: arguments
            )

            let workoutRows = try WeeklyStrategyWorkoutRow.fetchAll(
                db,
                sql: """
                    SELECT
                        session_date AS sessionDate,
                        trimp_score AS trimpScore
                    FROM workout_sessions
                    WHERE (user_id = ? OR user_id = ?)
                      AND session_date >= ?
                      AND session_date <= ?
                      AND deleted_at IS NULL
                    """,
                arguments: arguments
            )

            return LocalContext(
                userId: user.id,
                weekStart: weekRange.start,
                weekEnd: weekRange.end,
                generatedAt: generatedAt,
                recoveryRows: recoveryRows,
                sleepRows: sleepRows,
                nutritionRows: nutritionRows,
                workoutRows: workoutRows
            )
        }

        guard let context else { return nil }

        let fallbackReport = try Self.makeLocalFallbackReport(from: context)
        let hasCloudSession = await MainActor.run { AuthManager.activeHasCloudSession }
        guard hasCloudSession else {
            return fallbackReport
        }

        do {
            let response = try await apiClient.fetchWeeklyStrategyReport(weekStart: context.weekStart)
            return try await dbQueue.write { db in
                try Self.upsertRemoteReport(response, userId: context.userId, in: db)
            }
        } catch {
            return fallbackReport
        }
    }

    private nonisolated static func upsertRemoteReport(
        _ response: WeeklyStrategyEdgeResponse,
        userId: UUID,
        in db: Database
    ) throws -> WeeklyStrategyReport {
        try db.execute(
            sql: """
                INSERT INTO weekly_strategy_reports (
                    id,
                    user_id,
                    created_at,
                    updated_at,
                    week_start,
                    week_end,
                    summary_stats,
                    report_markdown,
                    model_used,
                    prompt_version
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(user_id, week_start) DO UPDATE SET
                    id = excluded.id,
                    created_at = excluded.created_at,
                    updated_at = excluded.updated_at,
                    week_end = excluded.week_end,
                    summary_stats = excluded.summary_stats,
                    report_markdown = excluded.report_markdown,
                    model_used = excluded.model_used,
                    prompt_version = excluded.prompt_version
                """,
            arguments: [
                response.reportId.uuidString,
                userId.uuidString,
                response.createdAt,
                response.updatedAt,
                response.weekStart,
                response.weekEnd,
                response.summaryStats,
                response.reportMarkdown,
                response.modelUsed,
                response.promptVersion
            ]
        )

        guard let report = try WeeklyStrategyReport.fetchOne(
            db,
            sql: """
                SELECT *
                FROM weekly_strategy_reports
                WHERE (user_id = ? OR user_id = ?)
                  AND week_start = ?
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString, response.weekStart]
        ) else {
            throw SyncError.serverError(code: 0, message: "Weekly strategy report was not stored locally.")
        }

        return report
    }

    private nonisolated static func makeLocalFallbackReport(
        from context: LocalContext
    ) throws -> WeeklyStrategyReport {
        let recoveryScores = context.recoveryRows
            .map { $0.recoveryScore ?? 0 }
            .filter { $0.isFinite && $0 > 0 }

        let sleepValues = context.sleepRows
            .map { $0.sleepDurationHours ?? 0 }
            .filter { $0.isFinite && $0 > 0 }

        let nutritionDays = Set(context.nutritionRows.map(\.loggedDate))
        let trainingVolume = context.workoutRows.reduce(0.0) { partialResult, row in
            partialResult + (row.trimpScore ?? 0)
        }

        let summaryStats = WeeklyStrategySummaryStats(
            avgRecoveryScore: round2(average(recoveryScores)),
            recoveryTrend: trendLabel(recoveryScores),
            daysInOptimalZone: context.recoveryRows.filter { $0.recoveryZone == "optimal" }.count,
            daysInCriticalZone: context.recoveryRows.filter { $0.recoveryZone == "critical" }.count,
            avgSleepDuration: round2(average(sleepValues)),
            sleepConsistency: round2(consistency(sleepValues)),
            nutritionAdherence: round2(Double(nutritionDays.count) / 7),
            trainingVolume: round2(trainingVolume),
            allostaticLoad: round2(average(
                context.recoveryRows
                    .map { $0.allostaticLoad ?? 0 }
                    .filter { $0.isFinite && $0 > 0 }
            ))
        )

        let markdown = makeMarkdown(
            weekStart: context.weekStart,
            weekEnd: context.weekEnd,
            summaryStats: summaryStats
        )

        var report = WeeklyStrategyReport(
            userId: context.userId,
            weekStart: context.weekStart,
            weekEnd: context.weekEnd,
            summaryStats: try encodeSummaryStats(summaryStats),
            reportMarkdown: markdown
        )
        report.createdAt = context.generatedAt
        report.updatedAt = context.generatedAt
        report.modelUsed = "local_heuristic"
        report.promptVersion = "v1"
        return report
    }

    private nonisolated static func makeMarkdown(
        weekStart: String,
        weekEnd: String,
        summaryStats: WeeklyStrategySummaryStats
    ) -> String {
        [
            "# Week \(weekStart) to \(weekEnd)",
            "",
            "## Summary",
            "- Avg recovery score: \(summaryStats.avgRecoveryScore)",
            "- Recovery trend: \(summaryStats.recoveryTrend)",
            "- Avg sleep: \(summaryStats.avgSleepDuration)h",
            "- Nutrition adherence: \(Int((summaryStats.nutritionAdherence * 100).rounded()))%",
            "- Training volume (TRIMP): \(summaryStats.trainingVolume)",
            "",
            "## Focus",
            summaryStats.avgRecoveryScore < 60
                ? "Prioritize rest days and sleep quality this week."
                : "Maintain current load while preserving sleep consistency."
        ].joined(separator: "\n")
    }

    private nonisolated static func encodeSummaryStats(_ summaryStats: WeeklyStrategySummaryStats) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(summaryStats)
    }

    private nonisolated static func weekRange(
        containing now: Date,
        timeZone: TimeZone
    ) -> (start: String, end: String) {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")

        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let startDate = calendar.date(from: components) ?? now
        let endDate = calendar.date(byAdding: .day, value: 6, to: startDate) ?? startDate
        return (
            start: dateString(startDate, timeZone: timeZone),
            end: dateString(endDate, timeZone: timeZone)
        )
    }

    private nonisolated static func dateString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private nonisolated static func resolvedTimeZone(identifier: String?) -> TimeZone {
        guard let identifier, let timeZone = TimeZone(identifier: identifier) else {
            return .current
        }
        return timeZone
    }

    private nonisolated static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private nonisolated static func consistency(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 1 }
        let avg = average(values)
        let variance = values.reduce(0.0) { partialResult, value in
            partialResult + ((value - avg) * (value - avg))
        } / Double(values.count)
        let stdDev = sqrt(variance)
        return max(0, min(1, 1 - (stdDev / 2)))
    }

    private nonisolated static func trendLabel(_ values: [Double]) -> String {
        guard let first = values.first, let last = values.last, values.count >= 2 else {
            return "stable"
        }
        if last - first > 3 {
            return "increasing"
        }
        if first - last > 3 {
            return "decreasing"
        }
        return "stable"
    }

    private nonisolated static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}

extension APIClient: WeeklyStrategyRouteAPIClient {
    func fetchWeeklyStrategyReport(weekStart: String) async throws -> WeeklyStrategyEdgeResponse {
        try await callEdgeRoute(
            function: "api-weekly-strategy",
            route: "",
            method: "GET",
            queryItems: [URLQueryItem(name: "week_start", value: weekStart)],
            body: nil,
            headers: [:],
            maxAttempts: 3
        )
    }
}
