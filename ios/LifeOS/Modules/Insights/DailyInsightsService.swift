import CryptoKit
import Foundation
import GRDB

protocol DailyInsightsManaging: Sendable {
    func refreshCurrentDaySnapshot() async throws -> DailyInsightsSnapshot?
}

protocol DailyInsightsRouteAPIClient: Sendable {
    func fetchDailyInsightsSnapshot(date: String) async throws -> DailyInsightsEdgeResponse
}

struct DailyInsightsSnapshot: Sendable {
    let date: String
    let insights: [Insight]
    let recommendations: [Recommendation]
}

struct DailyInsightsEdgeResponse: Decodable, Sendable {
    let date: String
    let insights: [Insight]
    let recommendations: [Recommendation]
}

private struct DailyInsightRecoveryRow: FetchableRecord, Decodable, Sendable {
    let date: String
    let recoveryScore: Double?
    let recoveryZone: String?
    let sleepDurationHours: Double?
    let allostaticLoad: Double?
    let confidenceScore: Double?
}

private struct DailyInsightNutritionTargetRow: FetchableRecord, Decodable, Sendable {
    let finalCalories: Int?
    let finalProteinG: Int?
}

private struct DailyInsightNutritionTotalsRow: FetchableRecord, Decodable, Sendable {
    let mealCount: Int
    let totalCalories: Double
    let totalProteinG: Double
}

private struct DailyInsightWorkoutTotalsRow: FetchableRecord, Decodable, Sendable {
    let workoutCount: Int
    let totalTrimp: Double
    let totalDurationMinutes: Int
}

private enum DailyInsightKind: String, CaseIterable {
    case recoveryStatus = "recovery_status"
    case sleepDebt = "sleep_debt"
    case nutritionGap = "nutrition_gap"
    case trainingLoad = "training_load"
    case setupPrompt = "setup_prompt"
}

private enum DailyRecommendationKind: String, CaseIterable {
    case recoveryRest = "recovery_rest"
    case sleepExtension = "sleep_extension"
    case proteinAnchor = "protein_anchor"
    case trainingCap = "training_cap"
    case steadyDay = "steady_day"
    case setupPrompt = "setup_prompt"
}

actor DailyInsightsService: DailyInsightsManaging {
    private struct LocalContext: Sendable {
        let userId: UUID
        let date: String
        let generatedAt: Date
        let localHour: Int
        let baselineSleepHours: Double?
        let recoveryRows: [DailyInsightRecoveryRow]
        let nutritionTarget: DailyInsightNutritionTargetRow?
        let nutritionTotals: DailyInsightNutritionTotalsRow
        let workoutTotals: DailyInsightWorkoutTotalsRow
    }

    private let dbQueue: DatabaseQueue
    private let apiClient: any DailyInsightsRouteAPIClient
    private let nowProvider: @Sendable () -> Date

    init(
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue,
        apiClient: any DailyInsightsRouteAPIClient = APIClient(),
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.dbQueue = dbQueue
        self.apiClient = apiClient
        self.nowProvider = nowProvider
    }

    func refreshCurrentDaySnapshot() async throws -> DailyInsightsSnapshot? {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        guard let authId else { return nil }

        let generatedAt = nowProvider()
        let context = try await dbQueue.read { db -> LocalContext? in
            guard let user = try UserIdentityLookup.fetchUser(authId: authId, db: db) else {
                return nil
            }

            let timeZone = Self.resolvedTimeZone(identifier: user.timezone)
            let date = Self.dateString(generatedAt, timeZone: timeZone)
            let lookbackStart = Self.dateString(
                Calendar(identifier: .gregorian).date(byAdding: .day, value: -6, to: Self.startOfDay(generatedAt, timeZone: timeZone)) ?? generatedAt,
                timeZone: timeZone
            )

            let recoveryRows = try DailyInsightRecoveryRow.fetchAll(
                db,
                sql: """
                    SELECT
                        date,
                        recovery_score AS recoveryScore,
                        recovery_zone AS recoveryZone,
                        sleep_duration_hours AS sleepDurationHours,
                        allostatic_load AS allostaticLoad,
                        confidence_score AS confidenceScore
                    FROM physiological_states
                    WHERE (user_id = ? OR user_id = ?)
                      AND date >= ?
                      AND date <= ?
                    ORDER BY date ASC
                    """,
                arguments: [user.id, user.id.uuidString, lookbackStart, date]
            )

            let nutritionTarget = try DailyInsightNutritionTargetRow.fetchOne(
                db,
                sql: """
                    SELECT
                        final_calories AS finalCalories,
                        final_protein_g AS finalProteinG
                    FROM daily_nutrition_targets
                    WHERE (user_id = ? OR user_id = ?)
                      AND date = ?
                    LIMIT 1
                    """,
                arguments: [user.id, user.id.uuidString, date]
            )

            let nutritionTotals = try DailyInsightNutritionTotalsRow.fetchOne(
                db,
                sql: """
                    SELECT
                        COUNT(*) AS mealCount,
                        COALESCE(SUM(calories), 0) AS totalCalories,
                        COALESCE(SUM(protein_g), 0) AS totalProteinG
                    FROM food_logs
                    WHERE (user_id = ? OR user_id = ?)
                      AND logged_date = ?
                      AND deleted_at IS NULL
                    """,
                arguments: [user.id, user.id.uuidString, date]
            ) ?? DailyInsightNutritionTotalsRow(mealCount: 0, totalCalories: 0, totalProteinG: 0)

            let workoutTotals = try DailyInsightWorkoutTotalsRow.fetchOne(
                db,
                sql: """
                    SELECT
                        COUNT(*) AS workoutCount,
                        COALESCE(SUM(trimp_score), 0) AS totalTrimp,
                        COALESCE(SUM(duration_minutes), 0) AS totalDurationMinutes
                    FROM workout_sessions
                    WHERE (user_id = ? OR user_id = ?)
                      AND session_date = ?
                      AND deleted_at IS NULL
                    """,
                arguments: [user.id, user.id.uuidString, date]
            ) ?? DailyInsightWorkoutTotalsRow(workoutCount: 0, totalTrimp: 0, totalDurationMinutes: 0)

            return LocalContext(
                userId: user.id,
                date: date,
                generatedAt: generatedAt,
                localHour: Self.localHour(for: generatedAt, timeZone: timeZone),
                baselineSleepHours: user.baselineSleepHours,
                recoveryRows: recoveryRows,
                nutritionTarget: nutritionTarget,
                nutritionTotals: nutritionTotals,
                workoutTotals: workoutTotals
            )
        }

        guard let context else { return nil }

        let localSnapshot = try Self.makeLocalSnapshot(from: context)
        let persistedLocal = try await dbQueue.write { db in
            try Self.persist(snapshot: localSnapshot, userId: context.userId, in: db)
        }

        let hasCloudSession = await MainActor.run { AuthManager.activeHasCloudSession }
        guard hasCloudSession else {
            return persistedLocal
        }

        do {
            let response = try await apiClient.fetchDailyInsightsSnapshot(date: context.date)
            let remoteSnapshot = DailyInsightsSnapshot(
                date: response.date,
                insights: response.insights,
                recommendations: response.recommendations
            )
            return try await dbQueue.write { db in
                try Self.persist(snapshot: remoteSnapshot, userId: context.userId, in: db)
            }
        } catch {
            return persistedLocal
        }
    }

    private nonisolated static func persist(
        snapshot: DailyInsightsSnapshot,
        userId: UUID,
        in db: Database
    ) throws -> DailyInsightsSnapshot {
        let insightPrefix = managedInsightPrefix(for: snapshot.date)
        let recommendationPrefix = managedRecommendationPrefix(for: snapshot.date)

        let existingInsights = try Insight.fetchAll(
            db,
            sql: """
                SELECT *
                FROM insights
                WHERE (user_id = ? OR user_id = ?)
                  AND type LIKE ?
                """,
            arguments: [userId, userId.uuidString, "\(insightPrefix)%"]
        )
        let existingRecommendations = try Recommendation.fetchAll(
            db,
            sql: """
                SELECT *
                FROM recommendations
                WHERE (user_id = ? OR user_id = ?)
                  AND trigger_condition LIKE ?
                """,
            arguments: [userId, userId.uuidString, "\(recommendationPrefix)%"]
        )

        let existingInsightById = Dictionary(uniqueKeysWithValues: existingInsights.map { ($0.id, $0) })
        let existingRecommendationById = Dictionary(uniqueKeysWithValues: existingRecommendations.map { ($0.id, $0) })

        let persistedInsights = try snapshot.insights.map { generated in
            let record = mergeInsight(existing: existingInsightById[generated.id], generated: generated)
            try record.save(db)
            return record
        }
        let persistedRecommendations = try snapshot.recommendations.map { generated in
            let record = mergeRecommendation(existing: existingRecommendationById[generated.id], generated: generated)
            try record.save(db)
            return record
        }

        let activeInsightIds = Set(persistedInsights.map(\.id))
        for var stale in existingInsights where !activeInsightIds.contains(stale.id) {
            stale.dismissed = true
            stale.dismissedAt = stale.dismissedAt ?? snapshot.insights.first?.updatedAt ?? Date()
            stale.updatedAt = snapshot.insights.first?.updatedAt ?? Date()
            try stale.save(db)
        }

        let activeRecommendationIds = Set(persistedRecommendations.map(\.id))
        for var stale in existingRecommendations where !activeRecommendationIds.contains(stale.id) {
            stale.dismissed = true
            stale.updatedAt = snapshot.recommendations.first?.updatedAt ?? Date()
            try stale.save(db)
        }

        try db.execute(
            sql: """
                UPDATE insights
                SET dismissed = 1,
                    dismissed_at = COALESCE(dismissed_at, ?),
                    updated_at = ?
                WHERE (user_id = ? OR user_id = ?)
                  AND type LIKE 'daily/%'
                  AND substr(type, 7, 10) < ?
                  AND dismissed = 0
                """,
            arguments: [
                snapshot.insights.first?.updatedAt ?? Date(),
                snapshot.insights.first?.updatedAt ?? Date(),
                userId,
                userId.uuidString,
                snapshot.date
            ]
        )

        try db.execute(
            sql: """
                UPDATE recommendations
                SET dismissed = 1,
                    updated_at = ?
                WHERE (user_id = ? OR user_id = ?)
                  AND trigger_condition LIKE 'daily/%'
                  AND recommendation_date < ?
                  AND dismissed = 0
                """,
            arguments: [
                snapshot.recommendations.first?.updatedAt ?? Date(),
                userId,
                userId.uuidString,
                snapshot.date
            ]
        )

        return DailyInsightsSnapshot(
            date: snapshot.date,
            insights: persistedInsights.filter { !$0.dismissed },
            recommendations: persistedRecommendations.filter { !$0.dismissed }
        )
    }

    private nonisolated static func mergeInsight(existing: Insight?, generated: Insight) -> Insight {
        guard var existing else { return generated }
        let createdAt = existing.createdAt
        let shownToUser = existing.shownToUser
        let shownAt = existing.shownAt
        let read = existing.read
        let readAt = existing.readAt
        let acknowledged = existing.acknowledged
        let acknowledgedAt = existing.acknowledgedAt
        let dismissed = existing.dismissed
        let dismissedAt = existing.dismissedAt
        let actedUpon = existing.actedUpon
        let actionTaken = existing.actionTaken

        existing = generated
        existing.createdAt = createdAt
        existing.shownToUser = shownToUser
        existing.shownAt = shownAt
        existing.read = read
        existing.readAt = readAt
        existing.acknowledged = acknowledged
        existing.acknowledgedAt = acknowledgedAt
        existing.dismissed = dismissed
        existing.dismissedAt = dismissedAt
        existing.actedUpon = actedUpon
        existing.actionTaken = actionTaken
        return existing
    }

    private nonisolated static func mergeRecommendation(existing: Recommendation?, generated: Recommendation) -> Recommendation {
        guard var existing else { return generated }
        let createdAt = existing.createdAt
        let dismissed = existing.dismissed
        let followed = existing.followed
        let userFeedback = existing.userFeedback

        existing = generated
        existing.createdAt = createdAt
        existing.dismissed = dismissed
        existing.followed = followed
        existing.userFeedback = userFeedback
        return existing
    }

    private nonisolated static func makeLocalSnapshot(from context: LocalContext) throws -> DailyInsightsSnapshot {
        let todayState = context.recoveryRows.last(where: { $0.date == context.date })
        let priorRecoveryScores = context.recoveryRows
            .filter { $0.date != context.date }
            .compactMap(\.recoveryScore)
            .filter { $0.isFinite }
        let avgPriorRecovery = average(priorRecoveryScores)
        let localTimeOfDay = recommendationTimeOfDay(forHour: context.localHour)

        var insights: [Insight] = []
        var recommendations: [Recommendation] = []

        if let todayState, let recoveryScore = todayState.recoveryScore {
            let delta = avgPriorRecovery > 0 ? recoveryScore - avgPriorRecovery : 0
            let roundedScore = Int(recoveryScore.rounded())
            let roundedDelta = Int(abs(delta).rounded())
            let zone = (todayState.recoveryZone ?? "ready").replacingOccurrences(of: "_", with: " ")

            let recoveryTitle: String
            let recoveryBody: String
            let recoveryPriority: Int
            if recoveryScore < 45 {
                recoveryTitle = "Recovery is below your recent range"
                recoveryBody = roundedDelta > 0
                    ? "Today's recovery score is \(roundedScore) in the \(zone) zone, about \(roundedDelta) points below your recent pattern."
                    : "Today's recovery score is \(roundedScore) in the \(zone) zone, so it is a better day to protect bandwidth than chase intensity."
                recoveryPriority = recoveryScore < 25 ? 1 : 2
            } else if recoveryScore >= 75 {
                recoveryTitle = "Recovery is supporting a steady day"
                recoveryBody = roundedDelta > 0
                    ? "Today's recovery score is \(roundedScore), about \(roundedDelta) points above your recent range, which supports normal training and workload."
                    : "Today's recovery score is \(roundedScore), which supports a normal training and work rhythm today."
                recoveryPriority = 4
            } else {
                recoveryTitle = "Recovery is stable but not fully topped up"
                recoveryBody = "Today's recovery score is \(roundedScore) in the \(zone) zone, so consistency should pay off better than adding extra strain."
                recoveryPriority = 3
            }

            let recoveryInsight = try makeInsight(
                userId: context.userId,
                date: context.date,
                generatedAt: context.generatedAt,
                kind: .recoveryStatus,
                category: .recovery,
                title: recoveryTitle,
                body: recoveryBody,
                confidence: clampedConfidence(todayState.confidenceScore ?? 0.86),
                priority: recoveryPriority,
                actionable: recoveryScore < 60,
                actionType: recoveryScore < 60 ? "rest" : nil,
                description: "Daily recovery guidance",
                reasoning: "Life OS compared today's recovery state with your last week of physiological data.",
                inputsUsed: "physiological_states",
                relatedMetrics: ["recovery_score", "sleep_duration_hours", "stress_level"],
                relatedDates: [context.date],
                expiresAt: Calendar(identifier: .gregorian).date(byAdding: .day, value: 7, to: context.generatedAt)
            )
            insights.append(recoveryInsight)

            if recoveryScore < 55 || (todayState.allostaticLoad ?? 0) >= 4 {
                let reason: String
                if context.workoutTotals.totalTrimp >= 60 {
                    reason = "Recovery is muted while today's training load is already substantial."
                } else {
                    reason = "Recovery and load signals both point to a lighter day paying off."
                }
                recommendations.append(
                    try makeRecommendation(
                        userId: context.userId,
                        date: context.date,
                        generatedAt: context.generatedAt,
                        kind: .recoveryRest,
                        category: "recovery",
                        priority: recoveryScore < 25 ? "critical" : "high",
                        title: recoveryScore < 25 ? "Make today a restoration day" : "Keep today's load restorative",
                        description: context.workoutTotals.totalTrimp >= 60
                            ? "You already have meaningful load on the board. Skip extra intensity and bias toward mobility, walking, or rest."
                            : "Favor mobility, walking, or easy zone-1 work over extra intensity today.",
                        reasoning: reason,
                        timeOfDay: localTimeOfDay,
                        insightId: recoveryInsight.id,
                        actionType: "rest",
                        actionParameters: [
                            "max_trimp": String(Int(max(context.workoutTotals.totalTrimp.rounded(), 20))),
                            "mode": "restorative"
                        ]
                    )
                )
            }
        }

        if let todayState,
           let sleepDuration = todayState.sleepDurationHours,
           let baselineSleep = context.baselineSleepHours,
           baselineSleep - sleepDuration >= 0.75 {
            let deficitHours = max(0, baselineSleep - sleepDuration)
            let sleepInsight = try makeInsight(
                userId: context.userId,
                date: context.date,
                generatedAt: context.generatedAt,
                kind: .sleepDebt,
                category: .sleep,
                title: "Sleep came in below your baseline",
                body: "You logged \(formatHours(sleepDuration)) hours of sleep versus a usual \(formatHours(baselineSleep)), so today's recovery ceiling is lower than usual.",
                confidence: 0.84,
                priority: 2,
                actionable: true,
                actionType: "increase_sleep",
                description: "Sleep debt signal",
                reasoning: "Life OS compares today's sleep duration with your stored baseline sleep need.",
                inputsUsed: "physiological_states,users",
                relatedMetrics: ["sleep_duration_hours", "recovery_score"],
                relatedDates: [context.date],
                expiresAt: Calendar(identifier: .gregorian).date(byAdding: .day, value: 5, to: context.generatedAt)
            )
            insights.append(sleepInsight)

            recommendations.append(
                try makeRecommendation(
                    userId: context.userId,
                    date: context.date,
                    generatedAt: context.generatedAt,
                    kind: .sleepExtension,
                    category: "sleep",
                    priority: deficitHours >= 1.5 ? "high" : "medium",
                    title: "Buy back sleep tonight",
                    description: "Protect bedtime and pull \(Int((deficitHours * 60).rounded())) minutes of extra sleep into tonight's plan.",
                    reasoning: "Closing the sleep gap is the cleanest way to improve tomorrow's readiness.",
                    timeOfDay: localTimeOfDay,
                    insightId: sleepInsight.id,
                    actionType: "increase_sleep",
                    actionParameters: [
                        "minutes": String(Int((deficitHours * 60).rounded())),
                        "focus": "bedtime"
                    ]
                )
            )
        }

        if let targetProtein = context.nutritionTarget?.finalProteinG,
           targetProtein > 0 {
            let proteinShortfall = Double(targetProtein) - context.nutritionTotals.totalProteinG
            let shouldPushProtein = proteinShortfall >= 25 || (context.localHour >= 15 && proteinShortfall >= 15)
            if shouldPushProtein {
                let nutritionInsight = try makeInsight(
                    userId: context.userId,
                    date: context.date,
                    generatedAt: context.generatedAt,
                    kind: .nutritionGap,
                    category: .nutrition,
                    title: "Protein is trailing today's target",
                    body: "You're at \(Int(context.nutritionTotals.totalProteinG.rounded()))g of \(targetProtein)g protein today, so the next meal is the best place to close the gap.",
                    confidence: context.nutritionTotals.mealCount == 0 ? 0.74 : 0.82,
                    priority: context.localHour >= 17 ? 2 : 3,
                    actionable: true,
                    actionType: "eat_protein",
                    description: "Daily protein gap",
                    reasoning: "Life OS compares today's food logs with your personalized protein target.",
                    inputsUsed: "food_logs,daily_nutrition_targets",
                    relatedMetrics: ["protein_g", "calories"],
                    relatedDates: [context.date],
                    expiresAt: Calendar(identifier: .gregorian).date(byAdding: .day, value: 3, to: context.generatedAt)
                )
                insights.append(nutritionInsight)

                recommendations.append(
                    try makeRecommendation(
                        userId: context.userId,
                        date: context.date,
                        generatedAt: context.generatedAt,
                        kind: .proteinAnchor,
                        category: "nutrition",
                        priority: context.localHour >= 17 ? "high" : "medium",
                        title: "Anchor the next meal around protein",
                        description: "Aim to close roughly \(Int(proteinShortfall.rounded()))g of protein with your next meal or snack.",
                        reasoning: "Protein intake is the biggest nutrition gap remaining in today's plan.",
                        timeOfDay: localTimeOfDay,
                        insightId: nutritionInsight.id,
                        actionType: "eat_protein",
                        actionParameters: [
                            "remaining_protein_g": String(Int(max(proteinShortfall.rounded(), 0))),
                            "meal_count": String(context.nutritionTotals.mealCount)
                        ]
                    )
                )
            }
        }

        if context.workoutTotals.workoutCount > 0,
           context.workoutTotals.totalTrimp >= 75,
           let recoveryScore = todayState?.recoveryScore,
           recoveryScore < 65 {
            let trainingInsight = try makeInsight(
                userId: context.userId,
                date: context.date,
                generatedAt: context.generatedAt,
                kind: .trainingLoad,
                category: .training,
                title: "Today's load is heavy relative to readiness",
                body: "You've already accumulated \(Int(context.workoutTotals.totalTrimp.rounded())) TRIMP today while recovery is still moderate, so adding more intensity is likely to cost more than it returns.",
                confidence: 0.87,
                priority: 2,
                actionable: true,
                actionType: "rest",
                description: "Training load check",
                reasoning: "Life OS combines today's workout load with today's recovery state to estimate marginal fatigue cost.",
                inputsUsed: "workout_sessions,physiological_states",
                relatedMetrics: ["training_trimp", "recovery_score"],
                relatedDates: [context.date],
                expiresAt: Calendar(identifier: .gregorian).date(byAdding: .day, value: 3, to: context.generatedAt)
            )
            insights.append(trainingInsight)

            recommendations.append(
                try makeRecommendation(
                    userId: context.userId,
                    date: context.date,
                    generatedAt: context.generatedAt,
                    kind: .trainingCap,
                    category: "recovery",
                    priority: "high",
                    title: "Cap the day here",
                    description: "Treat any additional movement as cooldown, mobility, or easy aerobic work instead of stacking more intensity.",
                    reasoning: "The best adaptation move now is recovering from the work you've already done.",
                    timeOfDay: localTimeOfDay,
                    insightId: trainingInsight.id,
                    actionType: "rest",
                    actionParameters: [
                        "max_trimp": String(Int(context.workoutTotals.totalTrimp.rounded())),
                        "mode": "cap_day"
                    ]
                )
            )
        }

        if insights.isEmpty {
            let setupInsight = try makeInsight(
                userId: context.userId,
                date: context.date,
                generatedAt: context.generatedAt,
                kind: .setupPrompt,
                category: .general,
                title: "One more signal unlocks a sharper daily read",
                body: "Log a meal, a workout, or a wellness check today and Life OS will turn it into more specific guidance.",
                confidence: 0.78,
                priority: 4,
                actionable: true,
                actionType: nil,
                description: "Setup nudge",
                reasoning: "Today's diary is still too sparse for a more specific pattern match.",
                inputsUsed: "food_logs,workout_sessions,wellness_checks",
                relatedMetrics: [],
                relatedDates: [context.date],
                expiresAt: Calendar(identifier: .gregorian).date(byAdding: .day, value: 2, to: context.generatedAt)
            )
            insights.append(setupInsight)
        }

        if recommendations.isEmpty {
            let steadyKind: DailyRecommendationKind = insights.first?.type == managedInsightKey(date: context.date, kind: .setupPrompt)
                ? .setupPrompt
                : .steadyDay
            recommendations.append(
                try makeRecommendation(
                    userId: context.userId,
                    date: context.date,
                    generatedAt: context.generatedAt,
                    kind: steadyKind,
                    category: "recovery",
                    priority: "low",
                    title: steadyKind == .setupPrompt ? "Add one signal to today's diary" : "Keep today's plan steady",
                    description: steadyKind == .setupPrompt
                        ? "A quick meal log or wellness check is enough to unlock more tailored guidance for the rest of the day."
                        : "Recovery, nutrition, and training signals do not show a major risk right now, so consistency is the highest-value move.",
                    reasoning: steadyKind == .setupPrompt
                        ? "More context is the fastest way to personalize today's guidance."
                        : "No major recovery, sleep, or nutrition risks surfaced in the current daily snapshot.",
                    timeOfDay: localTimeOfDay,
                    insightId: nil,
                    actionType: nil,
                    actionParameters: steadyKind == .setupPrompt
                        ? ["focus": "log_signal"]
                        : ["focus": "consistency"]
                )
            )
        }

        insights = Array(
            Dictionary(uniqueKeysWithValues: insights.map { ($0.id, $0) }).values
        ).sorted {
            if $0.priority != $1.priority {
                return $0.priority < $1.priority
            }
            return $0.updatedAt > $1.updatedAt
        }

        recommendations = Array(
            Dictionary(uniqueKeysWithValues: recommendations.map { ($0.id, $0) }).values
        ).sorted {
            let lhsPriority = recommendationPriorityRank($0.priority)
            let rhsPriority = recommendationPriorityRank($1.priority)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return $0.updatedAt > $1.updatedAt
        }

        return DailyInsightsSnapshot(
            date: context.date,
            insights: Array(insights.prefix(4)),
            recommendations: Array(recommendations.prefix(3))
        )
    }

    private nonisolated static func makeInsight(
        userId: UUID,
        date: String,
        generatedAt: Date,
        kind: DailyInsightKind,
        category: InsightCategory,
        title: String,
        body: String,
        confidence: Double,
        priority: Int,
        actionable: Bool,
        actionType: String?,
        description: String?,
        reasoning: String?,
        inputsUsed: String?,
        relatedMetrics: [String],
        relatedDates: [String],
        expiresAt: Date?
    ) throws -> Insight {
        var insight = Insight(
            id: stableUUID(seed: "insight:\(userId.uuidString.lowercased()):\(managedInsightKey(date: date, kind: kind))"),
            userId: userId,
            category: category,
            title: title,
            body: body,
            confidence: clampedConfidence(confidence)
        )
        insight.createdAt = generatedAt
        insight.updatedAt = generatedAt
        insight.type = managedInsightKey(date: date, kind: kind)
        insight.description = description
        insight.reasoning = reasoning
        insight.inputsUsed = inputsUsed
        insight.priority = priority
        insight.actionable = actionable
        insight.actionType = actionType
        insight.relatedMetrics = try encodeJSONStringArray(relatedMetrics)
        insight.relatedDates = try encodeJSONStringArray(relatedDates)
        insight.needsReview = insight.confidence < 0.65
        insight.expiresAt = expiresAt
        return insight
    }

    private nonisolated static func makeRecommendation(
        userId: UUID,
        date: String,
        generatedAt: Date,
        kind: DailyRecommendationKind,
        category: String,
        priority: String,
        title: String,
        description: String,
        reasoning: String,
        timeOfDay: String,
        insightId: UUID?,
        actionType: String?,
        actionParameters: [String: String]?
    ) throws -> Recommendation {
        var recommendation = Recommendation(
            id: stableUUID(seed: "recommendation:\(userId.uuidString.lowercased()):\(managedRecommendationKey(date: date, kind: kind))"),
            userId: userId,
            recommendationDate: date,
            category: category,
            priority: priority,
            title: title,
            description: description,
            reasoning: reasoning
        )
        recommendation.createdAt = generatedAt
        recommendation.updatedAt = generatedAt
        recommendation.timeOfDay = timeOfDay
        recommendation.insightId = insightId
        recommendation.actionType = actionType
        recommendation.actionParameters = try actionParameters.map(encodeJSONObject)
        recommendation.triggerCondition = managedRecommendationKey(date: date, kind: kind)
        return recommendation
    }

    private nonisolated static func encodeJSONStringArray(_ values: [String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(values)
    }

    private nonisolated static func encodeJSONObject(_ dictionary: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
    }

    private nonisolated static func stableUUID(seed: String) -> UUID {
        let digest = SHA256.hash(data: Data(seed.utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            bytes[4],
            bytes[5],
            (bytes[6] & 0x0F) | 0x50,
            bytes[7],
            (bytes[8] & 0x3F) | 0x80,
            bytes[9],
            bytes[10],
            bytes[11],
            bytes[12],
            bytes[13],
            bytes[14],
            bytes[15]
        ))
    }

    private nonisolated static func managedInsightKey(date: String, kind: DailyInsightKind) -> String {
        "\(managedInsightPrefix(for: date))\(kind.rawValue)"
    }

    private nonisolated static func managedInsightPrefix(for date: String) -> String {
        "daily/\(date)/"
    }

    private nonisolated static func managedRecommendationKey(date: String, kind: DailyRecommendationKind) -> String {
        "\(managedRecommendationPrefix(for: date))\(kind.rawValue)"
    }

    private nonisolated static func managedRecommendationPrefix(for date: String) -> String {
        "daily/\(date)/"
    }

    private nonisolated static func resolvedTimeZone(identifier: String?) -> TimeZone {
        guard let identifier, let timeZone = TimeZone(identifier: identifier) else {
            return .current
        }
        return timeZone
    }

    private nonisolated static func dateString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private nonisolated static func startOfDay(_ date: Date, timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.startOfDay(for: date)
    }

    private nonisolated static func localHour(for date: Date, timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.component(.hour, from: date)
    }

    private nonisolated static func recommendationTimeOfDay(forHour hour: Int) -> String {
        switch hour {
        case ..<11:
            return "morning"
        case ..<14:
            return "midday"
        case ..<18:
            return "afternoon"
        case ..<22:
            return "evening"
        default:
            return "night"
        }
    }

    private nonisolated static func clampedConfidence(_ value: Double) -> Double {
        max(0.67, min(value, 0.95))
    }

    private nonisolated static func formatHours(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded.rounded() == rounded {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }

    private nonisolated static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private nonisolated static func recommendationPriorityRank(_ priority: String) -> Int {
        switch priority.lowercased() {
        case "critical":
            return 0
        case "high":
            return 1
        case "medium":
            return 2
        default:
            return 3
        }
    }
}

extension APIClient: DailyInsightsRouteAPIClient {
    func fetchDailyInsightsSnapshot(date: String) async throws -> DailyInsightsEdgeResponse {
        try await callEdgeRoute(
            function: "api-insights-daily",
            route: "",
            method: "GET",
            queryItems: [URLQueryItem(name: "date", value: date)],
            body: nil,
            headers: [:],
            maxAttempts: 3
        )
    }
}
