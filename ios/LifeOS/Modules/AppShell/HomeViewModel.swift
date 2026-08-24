import Foundation
import Observation
import GRDB
#if os(iOS)
import UIKit
import HealthKit
#endif
import ComposableArchitecture
import OSLog

// MARK: - Next Best Action

/// Deterministic priority chain for the home screen's primary action card.
/// Priority order (first match wins):
///   1. Needs review (insights or food logs)
///   2. Supplement due soon (within 2 hours)
///   3. Nutrition under target
///   4. Sleep permission missing
///   5. Unread insights
///   6. Fallback → open diary
enum NextBestAction: Equatable, Sendable {
    case needsReview(count: Int)
    case supplementDueSoon(count: Int, nextTime: String?)
    case nutritionUnderTarget(caloriesRemaining: Int)
    case sleepPermissionMissing
    case unreadInsights(count: Int)
    case fallbackOpenDiary

    var title: String {
        switch self {
        case .needsReview:
            return String(localized: "nba_needs_review_title")
        case .supplementDueSoon:
            return String(localized: "nba_supplement_due_title")
        case .nutritionUnderTarget:
            return String(localized: "nba_nutrition_under_target_title")
        case .sleepPermissionMissing:
            return String(localized: "nba_sleep_permission_title")
        case .unreadInsights:
            return String(localized: "nba_unread_insights_title")
        case .fallbackOpenDiary:
            return String(localized: "nba_fallback_diary_title")
        }
    }

    var message: String {
        switch self {
        case .needsReview(let count):
            return String(
                format: String(localized: "nba_needs_review_message_format"),
                count
            )
        case .supplementDueSoon(let count, let nextTime):
            if let nextTime {
                return String(
                    format: String(localized: "nba_supplement_due_message_time_format"),
                    count, nextTime
                )
            }
            return String(
                format: String(localized: "nba_supplement_due_message_format"),
                count
            )
        case .nutritionUnderTarget(let caloriesRemaining):
            return String(
                format: String(localized: "nba_nutrition_under_target_message_format"),
                caloriesRemaining
            )
        case .sleepPermissionMissing:
            return String(localized: "nba_sleep_permission_message")
        case .unreadInsights(let count):
            return String(
                format: String(localized: "nba_unread_insights_message_format"),
                count
            )
        case .fallbackOpenDiary:
            return String(localized: "nba_fallback_diary_message")
        }
    }

    var buttonTitle: String {
        switch self {
        case .needsReview:
            return String(localized: "nba_needs_review_cta")
        case .supplementDueSoon:
            return String(localized: "nba_supplement_due_cta")
        case .nutritionUnderTarget:
            return String(localized: "nba_nutrition_under_target_cta")
        case .sleepPermissionMissing:
            return String(localized: "nba_sleep_permission_cta")
        case .unreadInsights:
            return String(localized: "nba_unread_insights_cta")
        case .fallbackOpenDiary:
            return String(localized: "nba_fallback_diary_cta")
        }
    }

    var deepLink: URL {
        switch self {
        case .needsReview:
            return URL(string: "lifeos://diary?mode=review")!
        case .supplementDueSoon:
            return URL(string: "lifeos://supplements/log")!
        case .nutritionUnderTarget:
            return URL(string: "lifeos://nutrition/log")!
        case .sleepPermissionMissing:
            return URL(string: "lifeos://sleep")!
        case .unreadInsights:
            return URL(string: "lifeos://insights")!
        case .fallbackOpenDiary:
            return URL(string: "lifeos://diary")!
        }
    }

    var iconName: String {
        switch self {
        case .needsReview:
            return "exclamationmark.bubble"
        case .supplementDueSoon:
            return "pill"
        case .nutritionUnderTarget:
            return "fork.knife"
        case .sleepPermissionMissing:
            return "bed.double"
        case .unreadInsights:
            return "lightbulb"
        case .fallbackOpenDiary:
            return "book"
        }
    }

    /// Whether this action is considered "risky" for one-tap execution.
    /// Risky actions are suppressed when confidence is low (< 0.65).
    var isRiskyOneTap: Bool {
        switch self {
        case .supplementDueSoon:
            return true
        case .needsReview, .nutritionUnderTarget, .sleepPermissionMissing,
             .unreadInsights, .fallbackOpenDiary:
            return false
        }
    }
}

// MARK: - Home View Model

@Observable
@MainActor
final class HomeViewModel {
    private let dbQueue: DatabaseQueue
    private let dailyInsightsService: any DailyInsightsManaging
    private(set) var recoveryScore: Double?
    private(set) var recoveryZone: RecoveryZone?
    private(set) var recoveryConfidence: Double?
    private(set) var contextualRecoveryAction: RecoveryContextualAction?
    private(set) var recommendations: [Recommendation] = []
    private var lastAnnouncedZone: RecoveryZone?

    // MARK: - Next Best Action State

    private(set) var nextBestAction: NextBestAction?
    private(set) var supplementsDueSoon: Int = 0
    private(set) var nutritionUnderTarget: Int?
    private(set) var unreadInsightsCount: Int = 0
    private(set) var sleepPermissionMissing: Bool = false

    private let logger = Logger(subsystem: "com.lifeos.app", category: "HomeViewModel")
    private let pushLatestWatchSnapshot: @Sendable (String?) async -> Void

    /// Setup checklist for progressive disclosure (new users).
    let setupChecklistStore = Store(initialState: SetupChecklistFeature.State()) {
        SetupChecklistFeature()
    }

    init(
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue,
        dailyInsightsService: any DailyInsightsManaging = DailyInsightsService(),
        pushLatestWatchSnapshot: @escaping @Sendable (String?) async -> Void = {
#if os(iOS)
            guard !UITestBootstrap.disableBackgroundWork else { return }
            await WatchSyncManager.shared.pushLatestSnapshotWithLocalFallback(date: $0)
#else
            _ = $0
#endif
        }
    ) {
        self.dbQueue = dbQueue
        self.dailyInsightsService = dailyInsightsService
        self.pushLatestWatchSnapshot = pushLatestWatchSnapshot
    }

    /// Whether to show the setup card on the home screen.
    var showsSetupCard: Bool {
        !setupChecklistStore.isFullyComplete
    }

    func refresh() async {
        do {
            let currentDailySnapshot: DailyInsightsSnapshot?
            do {
                currentDailySnapshot = try await dailyInsightsService.refreshCurrentDaySnapshot()
            } catch {
                logger.error("Daily insights refresh failed: \(error.localizedDescription)")
                currentDailySnapshot = nil
            }

            let authId = AuthManager.activeAuthId?.uuidString
            let snapshot = try await dbQueue.read { db in
                try RecoverySnapshot.fetchLatest(db, authId: authId)
            }

            recoveryScore = snapshot?.state.recoveryScore
            recoveryZone = snapshot.map { RecoveryZone.from(score: $0.state.recoveryScore) }
            recoveryConfidence = snapshot?.state.confidenceScore
            contextualRecoveryAction = snapshot.flatMap {
                Self.makeContextualAction(state: $0.state, sleepBaselineHours: $0.sleepBaselineHours)
            }

            await pushLatestWatchSnapshot(snapshot?.state.date)
            await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()

            if let zone = recoveryZone,
               zone != lastAnnouncedZone,
               let score = recoveryScore {
                HapticManager.zoneChange(zone)
#if os(iOS)
                UIAccessibility.post(
                    notification: .announcement,
                    argument: zone.accessibilityAnnouncement(score: score)
                )
#endif
                lastAnnouncedZone = zone
            }

            // Compute NBA after recovery data is loaded.
            let nba = try await Self.computeNextBestAction(
                db: dbQueue,
                confidenceScore: recoveryConfidence
            )
            nextBestAction = nba.action
            supplementsDueSoon = nba.supplementsDue
            nutritionUnderTarget = nba.caloriesRemaining
            unreadInsightsCount = nba.unreadInsights
            sleepPermissionMissing = nba.sleepMissing
            let storedRecommendations = try await Self.loadRecommendations(db: dbQueue)
            recommendations = storedRecommendations.isEmpty
                ? (currentDailySnapshot?.recommendations ?? [])
                : storedRecommendations
        } catch {
            logger.error("Failed to refresh home screen data from DB: \(error.localizedDescription)")
            recoveryScore = nil
            recoveryZone = nil
            recoveryConfidence = nil
            contextualRecoveryAction = nil
            recommendations = []
            nextBestAction = nil
            supplementsDueSoon = 0
            nutritionUnderTarget = nil
            unreadInsightsCount = 0
            sleepPermissionMissing = false
        }

        // Refresh setup checklist (progressive disclosure for new users)
        setupChecklistStore.send(.refresh)
    }

    // MARK: - Contextual Recovery Action (existing)

    private static func makeContextualAction(
        state: PhysiologicalState,
        sleepBaselineHours: Double?
    ) -> RecoveryContextualAction? {
        let zone = RecoveryZone.from(score: state.recoveryScore)
        guard zone == .critical || zone == .caution else { return nil }
        let day = normalizedDay(state.date)

        let recoveryDeepLink = deepLink(host: "recovery", date: day)

        guard let sleepDurationHours = state.sleepDurationHours,
              let sleepBaselineHours,
              sleepBaselineHours > 0,
              sleepDurationHours + 0.25 < sleepBaselineHours else {
            return RecoveryContextualAction(
                title: String(localized: "home_recovery_action_general_title"),
                message: String(localized: "home_recovery_action_general_message"),
                buttonTitle: String(localized: "home_recovery_action_general_cta"),
                deepLink: recoveryDeepLink
            )
        }

        let format = String(localized: "home_recovery_action_sleep_message_format")
        let message = String.localizedStringWithFormat(
            format,
            sleepDurationHours,
            sleepBaselineHours
        )
        return RecoveryContextualAction(
            title: String(localized: "home_recovery_action_sleep_title"),
            message: message,
            buttonTitle: String(localized: "home_recovery_action_sleep_cta"),
            deepLink: deepLink(host: "sleep", date: day)
        )
    }

    // MARK: - Next Best Action Computation

    /// Internal result container for NBA computation.
    private struct NBAResult: Sendable {
        let action: NextBestAction
        let supplementsDue: Int
        let caloriesRemaining: Int?
        let unreadInsights: Int
        let sleepMissing: Bool
    }

    /// Low-confidence threshold. Matches `RecoveryScoreValue.isLowConfidence`.
    private static let lowConfidenceThreshold: Double = 0.65

    /// Deterministic NBA priority chain. Returns the first matching action.
    private static func computeNextBestAction(
        db: DatabaseQueue,
        confidenceScore: Double?
    ) async throws -> NBAResult {
        let authId = AuthManager.activeAuthId?.uuidString
        let referenceDate = Date()

        let dbResult = try await db.read { db -> (
            needsReviewCount: Int,
            supplementsDue: Int,
            nextSupplementTime: String?,
            caloriesRemaining: Int?,
            unreadInsightsCount: Int
        ) in
            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                return (0, 0, nil, nil, 0)
            }

            let today = Self.dayString(for: referenceDate)

            // 1. Needs review: insights + food logs flagged for review
            let insightReviewCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM insights
                    WHERE (user_id = ? OR user_id = ?)
                      AND needs_review = 1
                      AND dismissed = 0
                    """,
                arguments: [userId, userId.uuidString]
            ) ?? 0

            let foodLogReviewCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM food_logs
                    WHERE (user_id = ? OR user_id = ?)
                      AND needs_review = 1
                      AND deleted_at IS NULL
                    """,
                arguments: [userId, userId.uuidString]
            ) ?? 0

            let needsReviewCount = insightReviewCount + foodLogReviewCount

            // 2. Supplements due within next 2 hours
            let (suppDue, nextTime) = try Self.querySupplementsDueSoon(
                db: db,
                userId: userId,
                referenceDate: referenceDate
            )

            // 3. Nutrition: daily calories consumed vs target
            let caloriesRemaining = try Self.queryCaloriesRemaining(
                db: db,
                userId: userId,
                today: today
            )

            // 4. Unread insights
            let unreadInsightsCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM insights
                    WHERE (user_id = ? OR user_id = ?)
                      AND read = 0
                      AND dismissed = 0
                    """,
                arguments: [userId, userId.uuidString]
            ) ?? 0

            return (needsReviewCount, suppDue, nextTime, caloriesRemaining, unreadInsightsCount)
        }

        // 4 (async). Sleep permission check — must run outside DB read.
        let sleepMissing = await Self.checkSleepPermissionMissing()

        let isLowConfidence = (confidenceScore ?? 1.0) < lowConfidenceThreshold

        // Priority chain: first match wins.
        let action: NextBestAction

        if dbResult.needsReviewCount > 0 {
            // P1: Needs review
            action = .needsReview(count: dbResult.needsReviewCount)
        } else if dbResult.supplementsDue > 0 && !isLowConfidence {
            // P2: Supplement due soon (risky one-tap — gated by confidence)
            action = .supplementDueSoon(
                count: dbResult.supplementsDue,
                nextTime: dbResult.nextSupplementTime
            )
        } else if let remaining = dbResult.caloriesRemaining, remaining > 0 {
            // P3: Nutrition under target
            action = .nutritionUnderTarget(caloriesRemaining: remaining)
        } else if sleepMissing {
            // P4: Sleep permission missing
            action = .sleepPermissionMissing
        } else if dbResult.unreadInsightsCount > 0 {
            // P5: Unread insights
            action = .unreadInsights(count: dbResult.unreadInsightsCount)
        } else {
            // P6: Fallback
            action = .fallbackOpenDiary
        }

        return NBAResult(
            action: action,
            supplementsDue: dbResult.supplementsDue,
            caloriesRemaining: dbResult.caloriesRemaining,
            unreadInsights: dbResult.unreadInsightsCount,
            sleepMissing: sleepMissing
        )
    }

    private static func loadRecommendations(db: DatabaseQueue) async throws -> [Recommendation] {
        let authId = AuthManager.activeAuthId?.uuidString
        return try await db.read { db in
            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                return []
            }

            let today = todayDateString()
            return try Recommendation.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM recommendations
                    WHERE (user_id = ? OR user_id = ?)
                      AND dismissed = 0
                    ORDER BY
                      CASE
                        WHEN recommendation_date = ? THEN 0
                        WHEN recommendation_date > ? THEN 1
                        ELSE 2
                      END,
                      updated_at DESC,
                      created_at DESC
                    LIMIT 3
                    """,
                arguments: [userId, userId.uuidString, today, today]
            )
        }
    }

    // MARK: - NBA Queries

    /// Query supplement schedule occurrences within the next 2 hours, including rollover past midnight.
    nonisolated private static func querySupplementsDueSoon(
        db: Database,
        userId: UUID,
        referenceDate: Date
    ) throws -> (count: Int, nextTime: String?) {
        let windowStart = minuteFloor(for: referenceDate)
        // Use calendar-based addition to correctly handle DST transitions.
        // addingTimeInterval(7200) adds absolute seconds, which may overshoot or undershoot
        // by 1h when clocks spring forward / fall back during the 2h window.
        var dstSafeCalendar = Calendar(identifier: .gregorian)
        dstSafeCalendar.timeZone = .current
        let windowEnd = dstSafeCalendar.date(byAdding: .hour, value: 2, to: windowStart)
            ?? windowStart.addingTimeInterval(2 * 60 * 60)
        let horizonDayStarts = dueSoonDayStarts(from: windowStart, to: windowEnd)
        let horizonDays = horizonDayStarts.map(dayString(for:))
        let defaultStartDay = horizonDays.first ?? dayString(for: windowStart)

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT us.id, us.frequency, us.scheduled_times, us.days_of_week,
                       us.started_at, us.ended_at
                FROM user_supplements us
                WHERE (us.user_id = ? OR us.user_id = ?)
                  AND us.active = 1
                  AND us.scheduled_times IS NOT NULL
                  AND us.scheduled_times != '[]'
                """,
            arguments: [userId, userId.uuidString]
        )

        guard !rows.isEmpty else { return (0, nil) }

        let supplementSchedules = rows.compactMap {
            makeDueSoonSupplementSchedule(from: $0, defaultStartDay: defaultStartDay)
        }
        guard !supplementSchedules.isEmpty else { return (0, nil) }

        var takenLookup: Set<String> = []
        if let firstDay = horizonDays.first,
           let lastDay = horizonDays.last {
            let takenRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT user_supplement_id, taken_date, scheduled_time
                    FROM supplement_logs
                    WHERE (user_id = ? OR user_id = ?)
                      AND deleted_at IS NULL
                      AND taken_date >= ?
                      AND taken_date <= ?
                    """,
                arguments: [userId, userId.uuidString, firstDay, lastDay]
            )

            for row in takenRows {
                guard let supplementId = MixedUUIDStorage.decode(from: row, column: "user_supplement_id"),
                      let takenDate = row["taken_date"] as String? else {
                    continue
                }
                let normalizedTakenDate = normalizedDay(takenDate)
                let normalizedScheduledTime = normalizedWallClockTime(from: row["scheduled_time"] as String?) ?? ""
                takenLookup.insert(
                    dueSoonTakenLookupKey(
                        userSupplementId: supplementId,
                        date: normalizedTakenDate,
                        scheduledTime: normalizedScheduledTime
                    )
                )
            }
        }

        var dueCount = 0
        var earliestOccurrence: HomeSupplementOccurrence?

        for supplement in supplementSchedules {
            for dayStart in horizonDayStarts {
                let day = dayString(for: dayStart)
                guard isDueSoonSupplementActive(supplement, on: day) else { continue }
                guard shouldScheduleDueSoonSupplement(supplement, on: dayStart) else { continue }

                for scheduledTime in supplement.scheduledTimes {
                    guard let scheduledAt = wallClockDate(on: dayStart, scheduledTime: scheduledTime) else {
                        continue
                    }
                    guard scheduledAt >= windowStart && scheduledAt <= windowEnd else {
                        continue
                    }

                    let lookupKey = dueSoonTakenLookupKey(
                        userSupplementId: supplement.userSupplementId,
                        date: day,
                        scheduledTime: scheduledTime.label
                    )
                    guard !takenLookup.contains(lookupKey) else { continue }

                    dueCount += 1
                    let occurrence = HomeSupplementOccurrence(
                        scheduledAt: scheduledAt,
                        timeLabel: scheduledTime.label
                    )
                    if let earliestScheduledAt = earliestOccurrence?.scheduledAt {
                        if occurrence.scheduledAt < earliestScheduledAt {
                            earliestOccurrence = occurrence
                        }
                    } else {
                        earliestOccurrence = occurrence
                    }
                }
            }
        }

        return (dueCount, earliestOccurrence?.timeLabel)
    }

    /// Query today's calorie consumption vs daily target. Returns remaining calories (positive = under target).
    nonisolated private static func queryCaloriesRemaining(
        db: Database,
        userId: UUID,
        today: String
    ) throws -> Int? {
        // Get daily target
        let targetCalories = try Int.fetchOne(
            db,
            sql: """
                SELECT COALESCE(final_calories, base_calories)
                FROM daily_nutrition_targets
                WHERE (user_id = ? OR user_id = ?)
                  AND date = ?
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString, today]
        )

        guard let targetCalories, targetCalories > 0 else {
            return nil // No target set — cannot determine "under target"
        }

        // Sum today's food logs
        let consumedCalories = try Int.fetchOne(
            db,
            sql: """
                SELECT COALESCE(CAST(SUM(calories) AS INTEGER), 0)
                FROM food_logs
                WHERE (user_id = ? OR user_id = ?)
                  AND logged_date = ?
                  AND deleted_at IS NULL
                """,
            arguments: [userId, userId.uuidString, today]
        ) ?? 0

        let remaining = targetCalories - consumedCalories
        return remaining > 0 ? remaining : nil
    }

    /// Check whether HealthKit sleep analysis permission is missing.
    private static func checkSleepPermissionMissing() async -> Bool {
#if os(iOS)
        guard HealthKitManager.isAvailable else { return false }
        let store = HKHealthStore()
        let sleepType = HKCategoryType(.sleepAnalysis)
        let status = store.authorizationStatus(for: sleepType)
        return status == .notDetermined
#else
        return false
#endif
    }

    /// Today's date as YYYY-MM-DD in the user's local timezone.
    nonisolated private static func todayDateString(referenceDate: Date = Date()) -> String {
        dayString(for: referenceDate)
    }

    nonisolated private static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    nonisolated private static func minuteFloor(for date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return calendar.date(from: components) ?? date
    }

    nonisolated private static func dueSoonDayStarts(from start: Date, to end: Date) -> [Date] {
        let calendar = Calendar.current
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        if first == last {
            return [first]
        }
        return [first, last]
    }

    nonisolated private static func makeDueSoonSupplementSchedule(
        from row: Row,
        defaultStartDay: String
    ) -> HomeSupplementScheduleRow? {
        guard let userSupplementId = MixedUUIDStorage.decode(from: row, column: "id") else {
            return nil
        }

        let scheduledTimes = decodeJSONStringArray(row["scheduled_times"] as String?)?
            .compactMap(parseDueSoonScheduledTime)
            .reduce(into: [HomeScheduledTime]()) { partialResult, value in
                if !partialResult.contains(where: { $0.label == value.label }) {
                    partialResult.append(value)
                }
            }
            .sorted(by: {
                ($0.hour, $0.minute) < ($1.hour, $1.minute)
            }) ?? []

        guard !scheduledTimes.isEmpty else { return nil }

        let daysOfWeek = decodeJSONIntArray(row["days_of_week"] as String?)?
            .filter { (0...6).contains($0) }
        let frequency: String = row["frequency"] ?? SupplementFrequency.daily.rawValue
        let startedAt = normalizedDay((row["started_at"] as String?) ?? defaultStartDay)
        let endedAt = (row["ended_at"] as String?).map(normalizedDay)

        return HomeSupplementScheduleRow(
            userSupplementId: userSupplementId,
            frequency: frequency,
            scheduledTimes: scheduledTimes,
            daysOfWeek: daysOfWeek,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    nonisolated private static func parseDueSoonScheduledTime(_ value: String) -> HomeScheduledTime? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let components = trimmed.split(separator: ":")
        guard components.count == 2 || components.count == 3,
              let hour = Int(components[0]),
              let minute = Int(components[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        if components.count == 3 {
            guard let second = Int(components[2]), (0...59).contains(second) else {
                return nil
            }
        }

        return HomeScheduledTime(
            label: String(format: "%02d:%02d", hour, minute),
            hour: hour,
            minute: minute
        )
    }

    nonisolated private static func normalizedWallClockTime(from rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        return parseDueSoonScheduledTime(rawValue)?.label
    }

    nonisolated private static func wallClockDate(
        on dayStart: Date,
        scheduledTime: HomeScheduledTime
    ) -> Date? {
        // Pin timezone explicitly so the resolved Date is stable across DST transitions.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(
            bySettingHour: scheduledTime.hour,
            minute: scheduledTime.minute,
            second: 0,
            of: dayStart
        )
    }

    nonisolated private static func shouldScheduleDueSoonSupplement(
        _ supplement: HomeSupplementScheduleRow,
        on date: Date
    ) -> Bool {
        switch supplement.frequency {
        case SupplementFrequency.asNeeded.rawValue:
            return false
        case SupplementFrequency.weekly.rawValue:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let weekday = calendar.component(.weekday, from: date) - 1
            if let daysOfWeek = supplement.daysOfWeek, !daysOfWeek.isEmpty {
                return daysOfWeek.contains(weekday)
            }
            return weekday == (weekdayIndex(for: supplement.startedAt) ?? weekday)
        default:
            return true
        }
    }

    nonisolated private static func isDueSoonSupplementActive(
        _ supplement: HomeSupplementScheduleRow,
        on dayString: String
    ) -> Bool {
        if supplement.startedAt > dayString {
            return false
        }
        if let endedAt = supplement.endedAt, !endedAt.isEmpty, endedAt < dayString {
            return false
        }
        return true
    }

    nonisolated private static func dueSoonTakenLookupKey(
        userSupplementId: UUID,
        date: String,
        scheduledTime: String
    ) -> String {
        "\(userSupplementId.uuidString)|\(date)|\(scheduledTime)"
    }

    nonisolated private static func decodeJSONStringArray(_ raw: String?) -> [String]? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    nonisolated private static func decodeJSONIntArray(_ raw: String?) -> [Int]? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([Int].self, from: data)
    }

    nonisolated private static func weekdayIndex(for dayString: String) -> Int? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dayString) else { return nil }
        return Calendar.current.component(.weekday, from: date) - 1
    }

    // MARK: - Helpers

    private static func deepLink(host: String, date: String) -> URL {
        var components = URLComponents()
        components.scheme = "lifeos"
        components.host = host
        components.queryItems = [URLQueryItem(name: "date", value: date)]
        if let url = components.url {
            return url
        }
        return URL(string: "lifeos://\(host)")!
    }

    nonisolated private static func normalizedDay(_ value: String) -> String {
        let dayPrefix = String(value.prefix(10))
        let pattern = #"^\d{4}-\d{2}-\d{2}$"#
        if dayPrefix.range(of: pattern, options: .regularExpression) != nil {
            return dayPrefix
        }
        return value
    }
}

// MARK: - DEBUG Test Extensions

#if DEBUG
extension HomeViewModel {
    func _testOverrideState(
        recoveryScore: Double?,
        recoveryZone: RecoveryZone?,
        recoveryConfidence: Double?,
        contextualAction: RecoveryContextualAction?,
        setupItems: [SetupChecklistFeature.Item],
        setupComplete: Bool,
        baselineDaysCollected: Int
    ) {
        self.recoveryScore = recoveryScore
        self.recoveryZone = recoveryZone
        self.recoveryConfidence = recoveryConfidence
        self.contextualRecoveryAction = contextualAction
        setupChecklistStore.send(
            .refreshResponse(
                .success(
                    SetupChecklistFeature.State(
                        items: setupItems,
                        isFullyComplete: setupComplete,
                        baselineDaysCollected: baselineDaysCollected
                    )
                )
            )
        )
    }

    func _testOverrideNBA(
        nextBestAction: NextBestAction?,
        supplementsDueSoon: Int = 0,
        nutritionUnderTarget: Int? = nil,
        unreadInsightsCount: Int = 0,
        sleepPermissionMissing: Bool = false
    ) {
        self.nextBestAction = nextBestAction
        self.supplementsDueSoon = supplementsDueSoon
        self.nutritionUnderTarget = nutritionUnderTarget
        self.unreadInsightsCount = unreadInsightsCount
        self.sleepPermissionMissing = sleepPermissionMissing
    }

    static func _testDeepLink(host: String, date: String) -> URL {
        deepLink(host: host, date: date)
    }

    static func _testComputeNextBestAction(
        db: DatabaseQueue,
        confidenceScore: Double?
    ) async throws -> NextBestAction {
        let result = try await computeNextBestAction(db: db, confidenceScore: confidenceScore)
        return result.action
    }

    static func _testQuerySupplementsDueSoon(
        db: DatabaseQueue,
        userId: UUID,
        referenceDate: Date
    ) async throws -> (count: Int, nextTime: String?) {
        try await db.read { db in
            try querySupplementsDueSoon(db: db, userId: userId, referenceDate: referenceDate)
        }
    }

    static func _testTodayDateString() -> String {
        todayDateString()
    }
}
#endif

// MARK: - Recovery Contextual Action

struct RecoveryContextualAction: Equatable, Sendable {
    let title: String
    let message: String
    let buttonTitle: String
    let deepLink: URL
}

// MARK: - Recovery Snapshot (DB Query)

private struct RecoverySnapshot {
    let state: PhysiologicalState
    let sleepBaselineHours: Double?

    static func fetchLatest(_ db: Database, authId: String?) throws -> RecoverySnapshot? {
        guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
            return nil
        }

        guard let latestState = try PhysiologicalState.fetchOne(
            db,
            sql: """
                SELECT *
                FROM physiological_states
                WHERE user_id = ? OR user_id = ?
                ORDER BY date DESC
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString]
        ) else {
            return nil
        }

        let baselineFromUserBaselines = try Double.fetchOne(
            db,
            sql: """
                SELECT sleep_baseline_hours
                FROM user_baselines
                WHERE (user_id = ? OR user_id = ?)
                  AND sleep_baseline_hours IS NOT NULL
                LIMIT 1
                """,
            arguments: [latestState.userId, latestState.userId.uuidString]
        )
        let baselineFromUsers = try Double.fetchOne(
            db,
            sql: """
                SELECT baseline_sleep_hours
                FROM users
                WHERE (id = ? OR id = ?)
                  AND baseline_sleep_hours IS NOT NULL
                LIMIT 1
                """,
                arguments: [latestState.userId, latestState.userId.uuidString]
        )

        return RecoverySnapshot(
            state: latestState,
            sleepBaselineHours: baselineFromUserBaselines ?? baselineFromUsers
        )
    }
}

private struct HomeScheduledTime: Hashable, Sendable {
    let label: String
    let hour: Int
    let minute: Int
}

private struct HomeSupplementScheduleRow: Sendable {
    let userSupplementId: UUID
    let frequency: String
    let scheduledTimes: [HomeScheduledTime]
    let daysOfWeek: [Int]?
    let startedAt: String
    let endedAt: String?
}

private struct HomeSupplementOccurrence: Sendable {
    let scheduledAt: Date
    let timeLabel: String
}
