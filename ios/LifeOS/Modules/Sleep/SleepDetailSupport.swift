import SwiftUI
import GRDB
import HealthKit

enum SleepPermissionState: Equatable {
    case unavailable
    case notDetermined
    case denied
    case authorized

    @MainActor
    static func current() -> SleepPermissionState {
        guard HealthKitManager.isAvailable else { return .unavailable }
        // HealthKit conceals read authorization. This state means the request
        // completed, not a claim that the user granted access to their data.
        return UserDefaults.standard.bool(forKey: "healthkit_read_request_completed") ? .authorized : .notDetermined
    }

    var canRequestAccess: Bool {
        switch self {
        case .notDetermined, .denied:
            return true
        case .unavailable, .authorized:
            return false
        }
    }

    var emptyTitle: String {
        switch self {
        case .authorized:
            return NSLocalizedString(
                "sleep.no_data_title",
                value: "No sleep data yet",
                comment: "Sleep detail empty title when HealthKit is connected but no data is available"
            )
        case .notDetermined, .denied:
            return NSLocalizedString(
                "sleep.missing_title",
                value: "Connect Apple Health",
                comment: "Sleep detail empty title when HealthKit sleep access is unavailable"
            )
        case .unavailable:
            return AppCapabilityAvailability.healthKitSummaryText
        }
    }

    var emptyMessage: String {
        switch self {
        case .authorized:
            return NSLocalizedString(
                "sleep.no_data_message",
                value: "Life OS will show sleep quality, stages, and gentle recommendations after your first synced night.",
                comment: "Sleep detail empty message when HealthKit is connected but no data is available"
            )
        case .notDetermined, .denied:
            return NSLocalizedString(
                "sleep.missing_helper",
                value: "Enable Sleep data to see stages, trends, and gentle recommendations.",
                comment: "Sleep detail empty message when HealthKit sleep access is unavailable"
            )
        case .unavailable:
            return AppCapabilityAvailability.healthKitSummaryText
        }
    }

    var actionTitle: String {
        NSLocalizedString(
            "sleep.connect_primary",
            value: "Connect HealthKit",
            comment: "Sleep detail CTA for connecting Apple Health"
        )
    }
}

struct SleepTrendPoint: Identifiable, Equatable {
    let id: String
    let day: String
    let shortLabel: String
    let score: Double?
    let durationHours: Double?
    let isSelected: Bool
}

struct SleepNarrativeItem: Identifiable, Equatable {
    let id: String
    let icon: String
    let text: String
}

enum SleepCalendarDayStatus: Equatable {
    case good
    case low
    case noData
}

struct SleepDetailSnapshot: Equatable {
    let day: String
    let displayDate: String
    let age: Int
    let baselineSleepHours: Double?
    let sleepLog: SleepLog?
    let state: PhysiologicalState?
    let score: Double?
    let confidenceScore: Double?
    let trendPoints: [SleepTrendPoint]
    let factors: [SleepNarrativeItem]
    let tryTonightItems: [SleepNarrativeItem]
    let stageFeedback: String?

    var bedtime: Date? {
        sleepLog?.bedTime ?? sleepLog?.bedtimeActual ?? sleepLog?.bedtimeIntended
    }

    var wakeTime: Date? {
        sleepLog?.wakeTime ?? sleepLog?.waketime
    }

    var durationMinutes: Int? {
        if let totalDurationMinutes = sleepLog?.totalDurationMinutes, totalDurationMinutes > 0 {
            return totalDurationMinutes
        }
        if let sleepDurationHours = state?.sleepDurationHours, sleepDurationHours > 0 {
            return Int((sleepDurationHours * 60).rounded())
        }
        return nil
    }

    var timeInBedMinutes: Int? {
        sleepLog?.timeInBedMinutes
    }

    var sleepEfficiency: Double? {
        sleepLog?.sleepEfficiency
    }

    var awakenings: Int? {
        sleepLog?.numberOfAwakenings ?? sleepLog?.interruptions
    }

    var sleepLatencyMinutes: Int? {
        sleepLog?.timeToFallAsleepMinutes
    }

    var deepPercent: Double? {
        percentage(
            explicitPercent: sleepLog?.deepSleepPercent ?? state?.deepSleepPercent,
            explicitMinutes: sleepLog?.deepSleepMinutes,
            baseMinutes: durationMinutes
        )
    }

    var remPercent: Double? {
        percentage(
            explicitPercent: sleepLog?.remSleepPercent ?? state?.remSleepPercent,
            explicitMinutes: sleepLog?.remSleepMinutes,
            baseMinutes: durationMinutes
        )
    }

    var lightPercent: Double? {
        percentage(
            explicitPercent: state?.lightSleepPercent,
            explicitMinutes: sleepLog?.lightSleepMinutes,
            baseMinutes: durationMinutes
        )
        ?? derivedLightPercent
    }

    var awakePercent: Double? {
        if let explicit = state?.awakePercent {
            return explicit
        }
        guard let awakeMinutes = sleepLog?.awakeMinutes else { return nil }
        let denominator = Double((durationMinutes ?? 0) + awakeMinutes)
        guard denominator > 0 else { return nil }
        return Double(awakeMinutes) / denominator * 100
    }

    var deepMinutes: Int? {
        resolvedMinutes(explicitMinutes: sleepLog?.deepSleepMinutes, percent: deepPercent, baseMinutes: durationMinutes)
    }

    var remMinutes: Int? {
        resolvedMinutes(explicitMinutes: sleepLog?.remSleepMinutes, percent: remPercent, baseMinutes: durationMinutes)
    }

    var lightMinutes: Int? {
        resolvedMinutes(explicitMinutes: sleepLog?.lightSleepMinutes, percent: lightPercent, baseMinutes: durationMinutes)
    }

    var awakeMinutes: Int? {
        if let awakeMinutes = sleepLog?.awakeMinutes {
            return awakeMinutes
        }
        guard let percent = awakePercent, let durationMinutes else { return nil }
        return Int((Double(durationMinutes) * (percent / 100.0)).rounded())
    }

    var hasAnySleepData: Bool {
        durationMinutes != nil || score != nil
    }

    var hasStages: Bool {
        deepPercent != nil || remPercent != nil || lightPercent != nil
    }

    var isPartialData: Bool {
        guard hasAnySleepData else { return false }
        return bedtime == nil || wakeTime == nil || !hasStages
    }

    var shouldShowEstimateBadge: Bool {
        (confidenceScore ?? 1) < LifeOSConstants.lowConfidenceThreshold
    }

    var sourceSummary: String? {
        guard let sleepLog else { return nil }
        let sourceText: String
        switch sleepLog.source {
        case .healthkit:
            sourceText = "HealthKit"
        case .manual:
            sourceText = NSLocalizedString(
                "sleep.source.manual",
                value: "Manual entry",
                comment: "Sleep detail source label for manual logs"
            )
        case .wearable:
            sourceText = NSLocalizedString(
                "sleep.source.wearable",
                value: "Wearable import",
                comment: "Sleep detail source label for wearable imports"
            )
        case .import:
            sourceText = NSLocalizedString(
                "sleep.source.import",
                value: "Imported",
                comment: "Sleep detail source label for imported sleep logs"
            )
        }

        if let deviceName = sleepLog.deviceName, !deviceName.isEmpty {
            return "\(sourceText) • \(deviceName)"
        }
        return sourceText
    }

    var trendSummary: String? {
        let scoredPoints = trendPoints.compactMap(\.score)
        guard !scoredPoints.isEmpty else { return nil }
        let average = scoredPoints.reduce(0, +) / Double(scoredPoints.count)
        return String(
            format: NSLocalizedString(
                "sleep.trend_summary",
                value: "7-day average %.0f",
                comment: "Sleep trend summary average label"
            ),
            average
        )
    }

    private func percentage(
        explicitPercent: Double?,
        explicitMinutes: Int?,
        baseMinutes: Int?
    ) -> Double? {
        if let explicitPercent, explicitPercent > 0 {
            return explicitPercent
        }
        guard let explicitMinutes, let baseMinutes, baseMinutes > 0 else { return nil }
        return Double(explicitMinutes) / Double(baseMinutes) * 100
    }

    private func resolvedMinutes(
        explicitMinutes: Int?,
        percent: Double?,
        baseMinutes: Int?
    ) -> Int? {
        if let explicitMinutes, explicitMinutes > 0 {
            return explicitMinutes
        }
        guard let percent, let baseMinutes, baseMinutes > 0 else { return nil }
        return Int((Double(baseMinutes) * (percent / 100.0)).rounded())
    }

    private var derivedLightPercent: Double? {
        guard let durationMinutes, durationMinutes > 0 else { return nil }
        if let lightSleepMinutes = sleepLog?.lightSleepMinutes, lightSleepMinutes > 0 {
            return Double(lightSleepMinutes) / Double(durationMinutes) * 100
        }
        guard let deepPercent, let remPercent else { return nil }
        let remainder = 100 - deepPercent - remPercent
        guard remainder > 0 else { return nil }
        return remainder
    }
}

enum SleepHealthKitAccessCoordinator {
    @MainActor
    static func currentPermissionState() -> SleepPermissionState {
        SleepPermissionState.current()
    }

    @MainActor
    static func requestAccessAndBackfill(dbQueue: DatabaseQueue) async throws {
        guard HealthKitManager.isAvailable else {
            throw HealthKitError.notAvailable
        }

        let granted = try await HealthKitManager.shared.requestAuthorization()
        guard granted else {
            throw HealthKitError.authorizationDenied
        }

        let authId = AuthManager.activeAuthId?.uuidString
        guard let authId else { return }

        let userId = try await dbQueue.read { db in
            try UserIdentityLookup.resolveUserId(authId: authId, db: db)
        }

        guard let userId else { return }
        try await HealthSyncManager.shared.backfillRecentData(days: 14, userId: userId)
    }
}

enum SleepDetailLoader {
    static func load(day: String, dbQueue: DatabaseQueue) async throws -> SleepDetailSnapshot {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }

        return try await dbQueue.read { db in
            let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db)
            let user = try fetchUser(userId: userId, db: db)
            let age = resolvedAge(for: user)
            let currentLog = try fetchLatestSleepLog(day: day, userId: userId, db: db)
            let currentState = try fetchPhysiologicalState(day: day, userId: userId, db: db)

            let recentDays = orderedDays(endingAt: day, count: 7)
            let fromDay = recentDays.first ?? day
            let logsByDay = try fetchSleepLogs(from: fromDay, to: day, userId: userId, db: db)
            let statesByDay = try fetchPhysiologicalStates(from: fromDay, to: day, userId: userId, db: db)
            let recentLogs = recentDays.compactMap { logsByDay[$0] }

            let score = displayedScore(
                sleepLog: currentLog,
                state: currentState,
                age: age,
                recentLogs: recentLogs
            )

            let trendPoints = recentDays.map { currentDay in
                let pointLog = logsByDay[currentDay]
                let pointState = statesByDay[currentDay]
                let pointScore = displayedScore(
                    sleepLog: pointLog,
                    state: pointState,
                    age: age,
                    recentLogs: recentLogs
                )
                let pointDurationHours = pointLog?.totalDurationMinutes.map { Double($0) / 60.0 } ?? pointState?.sleepDurationHours
                return SleepTrendPoint(
                    id: currentDay,
                    day: currentDay,
                    shortLabel: shortWeekday(for: currentDay),
                    score: pointScore,
                    durationHours: pointDurationHours,
                    isSelected: currentDay == day
                )
            }

            let deepPercent = currentLog?.deepSleepPercent ?? currentState?.deepSleepPercent
            let remPercent = currentLog?.remSleepPercent ?? currentState?.remSleepPercent
            let stageFeedback: String?
            if deepPercent != nil || remPercent != nil {
                stageFeedback = SleepTargetEngine.supportiveStageFeedback(
                    deepPercent: deepPercent,
                    remPercent: remPercent,
                    age: age
                )
            } else {
                stageFeedback = nil
            }

            let factors = deriveFactors(
                sleepLog: currentLog,
                state: currentState,
                age: age,
                baselineSleepHours: user?.baselineSleepHours,
                trendPoints: trendPoints,
                recentLogs: recentLogs
            )
            let tryTonightItems = deriveTryTonightItems(
                sleepLog: currentLog,
                state: currentState,
                age: age,
                trendPoints: trendPoints
            )

            return SleepDetailSnapshot(
                day: day,
                displayDate: displayDate(for: day),
                age: age,
                baselineSleepHours: user?.baselineSleepHours,
                sleepLog: currentLog,
                state: currentState,
                score: score,
                confidenceScore: currentState?.confidenceScore,
                trendPoints: trendPoints,
                factors: factors,
                tryTonightItems: tryTonightItems,
                stageFeedback: stageFeedback
            )
        }
    }

    static func loadMonthStatuses(month: Date, dbQueue: DatabaseQueue) async throws -> [String: SleepCalendarDayStatus] {
        do {
            return try await loadRemoteMonthStatuses(month: month)
        } catch {
            return try await loadLocalMonthStatuses(month: month, dbQueue: dbQueue)
        }
    }

    private static func fetchUser(userId: UUID?, db: Database) throws -> User? {
        guard let userId else { return nil }
        return try User.fetchOne(
            db,
            sql: """
                SELECT *
                FROM users
                WHERE id = ? OR id = ?
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString]
        )
    }

    private static func fetchLatestSleepLog(day: String, userId: UUID?, db: Database) throws -> SleepLog? {
        guard let userId else { return nil }
        return try SleepRecordSelection.daily(userId: userId, day: day, db: db)
    }

    private static func fetchPhysiologicalState(day: String, userId: UUID?, db: Database) throws -> PhysiologicalState? {
        guard let userId else { return nil }
        return try PhysiologicalState.fetchOne(
            db,
            sql: """
                SELECT *
                FROM physiological_states
                WHERE (user_id = ? OR user_id = ?)
                  AND date = ?
                ORDER BY updated_at DESC
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString, day]
        )
    }

    private static func fetchSleepLogs(
        from fromDay: String,
        to toDay: String,
        userId: UUID?,
        db: Database
    ) throws -> [String: SleepLog] {
        guard let userId else { return [:] }
        let logs = try SleepLog.fetchAll(
            db,
            sql: """
                SELECT *
                FROM sleep_logs
                WHERE (user_id = ? OR user_id = ?)
                  AND COALESCE(sleep_date, date) BETWEEN ? AND ?
                  AND deleted_at IS NULL
                ORDER BY (source = 'manual') DESC, updated_at DESC, created_at DESC
                """,
            arguments: [userId, userId.uuidString, fromDay, toDay]
        )

        var byDay: [String: SleepLog] = [:]
        for log in logs {
            let day = log.sleepDate ?? log.date
            if byDay[day] == nil {
                byDay[day] = log
            }
        }
        return byDay
    }

    private static func fetchPhysiologicalStates(
        from fromDay: String,
        to toDay: String,
        userId: UUID?,
        db: Database
    ) throws -> [String: PhysiologicalState] {
        guard let userId else { return [:] }
        let states = try PhysiologicalState.fetchAll(
            db,
            sql: """
                SELECT *
                FROM physiological_states
                WHERE (user_id = ? OR user_id = ?)
                  AND date BETWEEN ? AND ?
                ORDER BY updated_at DESC
                """,
            arguments: [userId, userId.uuidString, fromDay, toDay]
        )

        var byDay: [String: PhysiologicalState] = [:]
        for state in states where byDay[state.date] == nil {
            byDay[state.date] = state
        }
        return byDay
    }

    private static func displayedScore(
        sleepLog: SleepLog?,
        state: PhysiologicalState?,
        age: Int,
        recentLogs: [SleepLog]
    ) -> Double? {
        SleepScorer.compositeScore(
            sleepLog: sleepLog,
            physiologicalState: state,
            age: age,
            recentLogs: recentLogs
        )
        ?? sleepLog?.sleepQualityScore
        ?? state?.sleepScore
        ?? state?.sleepQualityPercent
    }

    private static func resolvedAge(for user: User?) -> Int {
        if let dateOfBirth = user?.dateOfBirth {
            let years = Calendar.current.dateComponents([.year], from: dateOfBirth, to: Date()).year ?? 30
            return max(18, years)
        }
        if let ageRange = user?.ageRange {
            return ageRange.representativeAge
        }
        return 30
    }

    private static func orderedDays(endingAt day: String, count: Int) -> [String] {
        guard let endDate = DiaryDateFormatter.parseDate(day) else { return [day] }
        return (0..<count).compactMap { offset in
            guard let value = Calendar.current.date(byAdding: .day, value: -(count - 1 - offset), to: endDate) else {
                return nil
            }
            return DiaryDateFormatter.formatDate(value)
        }
    }

    private static func displayDate(for day: String) -> String {
        guard let date = DiaryDateFormatter.parseDate(day) else { return day }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    private static func shortWeekday(for day: String) -> String {
        guard let date = DiaryDateFormatter.parseDate(day) else { return day }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    private static func loadRemoteMonthStatuses(
        month: Date,
        apiClient: any SleepCalendarRouteAPIClient = APIClient()
    ) async throws -> [String: SleepCalendarDayStatus] {
        let hasCloudSession = await MainActor.run {
            SupabaseConfig.isRuntimeConfigured && AuthManager.activeHasCloudSession
        }
        guard hasCloudSession else {
            throw NSError(domain: "SleepCalendar", code: 1)
        }

        let range = monthBounds(for: month)
        let response = try await apiClient.fetchSleepCalendar(from: range.from, to: range.to)
        return Dictionary(uniqueKeysWithValues: response.days.map { day in
            (day.date, remoteStatus(day.status))
        })
    }

    private static func loadLocalMonthStatuses(
        month: Date,
        dbQueue: DatabaseQueue
    ) async throws -> [String: SleepCalendarDayStatus] {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }

        return try await dbQueue.read { db in
            let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db)
            guard let userId else { return [:] }
            let user = try fetchUser(userId: userId, db: db)
            let age = resolvedAge(for: user)

            let range = monthBounds(for: month)
            let fromDay = range.from
            let toDay = range.to
            let monthStart = DiaryDateFormatter.parseDate(fromDay) ?? month
            let monthEnd = DiaryDateFormatter.parseDate(toDay) ?? month

            let logsByDay = try fetchSleepLogs(from: fromDay, to: toDay, userId: userId, db: db)
            let statesByDay = try fetchPhysiologicalStates(from: fromDay, to: toDay, userId: userId, db: db)

            var statuses: [String: SleepCalendarDayStatus] = [:]
            var dayCursor = monthStart
            while dayCursor <= monthEnd {
                let dayString = DiaryDateFormatter.formatDate(dayCursor)
                let score = displayedScore(
                    sleepLog: logsByDay[dayString],
                    state: statesByDay[dayString],
                    age: age,
                    recentLogs: []
                )
                if let score {
                    statuses[dayString] = score >= 70 ? .good : .low
                } else {
                    statuses[dayString] = .noData
                }
                dayCursor = Calendar.current.date(byAdding: .day, value: 1, to: dayCursor) ?? monthEnd.addingTimeInterval(1)
            }
            return statuses
        }
    }

    private static func monthBounds(for month: Date) -> (from: String, to: String) {
        let calendar = Calendar.current
        guard
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
            let monthRange = calendar.range(of: .day, in: .month, for: monthStart),
            let monthEnd = calendar.date(byAdding: .day, value: monthRange.count - 1, to: monthStart)
        else {
            let day = DiaryDateFormatter.formatDate(month)
            return (day, day)
        }

        return (
            DiaryDateFormatter.formatDate(monthStart),
            DiaryDateFormatter.formatDate(monthEnd)
        )
    }

    private static func remoteStatus(_ value: String) -> SleepCalendarDayStatus {
        switch value.lowercased() {
        case "good":
            return .good
        case "low":
            return .low
        default:
            return .noData
        }
    }

    private static func deriveFactors(
        sleepLog: SleepLog?,
        state: PhysiologicalState?,
        age: Int,
        baselineSleepHours: Double?,
        trendPoints: [SleepTrendPoint],
        recentLogs: [SleepLog]
    ) -> [SleepNarrativeItem] {
        struct Candidate {
            let score: Int
            let item: SleepNarrativeItem
        }

        var candidates: [Candidate] = []
        let optimalRange = SleepScorer.optimalDurationRange(age: age)
        let durationHours = sleepLog?.totalDurationMinutes.map { Double($0) / 60.0 } ?? state?.sleepDurationHours
        let currentScore = displayedScore(sleepLog: sleepLog, state: state, age: age, recentLogs: recentLogs)
        let weekAverage = trendPoints.compactMap(\.score).average

        if let durationHours, durationHours < optimalRange.lowerBound {
            let deficit = optimalRange.lowerBound - durationHours
            let deficitText = String(format: "%.1f", deficit)
            candidates.append(
                Candidate(
                    score: Int((deficit * 30).rounded()) + 70,
                    item: SleepNarrativeItem(
                        id: "duration",
                        icon: "moon.zzz.fill",
                        text: String(
                            format: NSLocalizedString(
                                "sleep.factor.short_duration",
                                value: "Sleep duration ran about %@h below your age-adjusted target window.",
                                comment: "Sleep factor for short sleep duration"
                            ),
                            deficitText
                        )
                    )
                )
            )
        } else if let baselineSleepHours, let durationHours, durationHours + 0.75 < baselineSleepHours {
            candidates.append(
                Candidate(
                    score: 74,
                    item: SleepNarrativeItem(
                        id: "below_baseline",
                        icon: "clock.badge.exclamationmark",
                        text: NSLocalizedString(
                            "sleep.factor.below_baseline",
                            value: "This night landed below your usual baseline, which can make the next day feel flatter.",
                            comment: "Sleep factor for nights below the user's baseline"
                        )
                    )
                )
            )
        }

        if let sleepEfficiency = sleepLog?.sleepEfficiency, sleepEfficiency < 85 {
            candidates.append(
                Candidate(
                    score: Int((85 - sleepEfficiency).rounded()) + 60,
                    item: SleepNarrativeItem(
                        id: "efficiency",
                        icon: "waveform.path.badge.minus",
                        text: String(
                            format: NSLocalizedString(
                                "sleep.factor.efficiency",
                                value: "Sleep efficiency was %.0f%%, which usually means the night felt more fragmented.",
                                comment: "Sleep factor for low sleep efficiency"
                            ),
                            sleepEfficiency
                        )
                    )
                )
            )
        }

        if let awakenings = sleepLog?.numberOfAwakenings, awakenings >= 3 {
            candidates.append(
                Candidate(
                    score: awakenings * 14 + 40,
                    item: SleepNarrativeItem(
                        id: "awakenings",
                        icon: "bell.badge",
                        text: String(
                            format: NSLocalizedString(
                                "sleep.factor.awakenings",
                                value: "There were %d notable awakenings, which likely reduced sleep continuity.",
                                comment: "Sleep factor for multiple awakenings"
                            ),
                            awakenings
                        )
                    )
                )
            )
        }

        if let latency = sleepLog?.timeToFallAsleepMinutes, latency >= 30 {
            candidates.append(
                Candidate(
                    score: latency + 25,
                    item: SleepNarrativeItem(
                        id: "latency",
                        icon: "hourglass",
                        text: String(
                            format: NSLocalizedString(
                                "sleep.factor.latency",
                                value: "It took about %d minutes to fall asleep, which can shrink total recovery time.",
                                comment: "Sleep factor for prolonged sleep onset"
                            ),
                            latency
                        )
                    )
                )
            )
        }

        if sleepLog?.caffeineAfter14 == true {
            candidates.append(
                Candidate(
                    score: 78,
                    item: SleepNarrativeItem(
                        id: "caffeine",
                        icon: "cup.and.saucer.fill",
                        text: NSLocalizedString(
                            "sleep.factor.caffeine",
                            value: "Late caffeine was logged yesterday, which can delay sleep and lighten deep sleep.",
                            comment: "Sleep factor for late caffeine"
                        )
                    )
                )
            )
        }

        if let alcohol = sleepLog?.alcohol, alcohol > 0 {
            candidates.append(
                Candidate(
                    score: Int((alcohol * 18).rounded()) + 52,
                    item: SleepNarrativeItem(
                        id: "alcohol",
                        icon: "wineglass.fill",
                        text: NSLocalizedString(
                            "sleep.factor.alcohol",
                            value: "Alcohol was logged, which often increases overnight fragmentation even when you fall asleep quickly.",
                            comment: "Sleep factor for alcohol"
                        )
                    )
                )
            )
        }

        if sleepLog?.heavyMealLate == true {
            candidates.append(
                Candidate(
                    score: 64,
                    item: SleepNarrativeItem(
                        id: "meal",
                        icon: "fork.knife.circle.fill",
                        text: NSLocalizedString(
                            "sleep.factor.meal",
                            value: "A late heavy meal was logged, which can push wakefulness later into the night.",
                            comment: "Sleep factor for late heavy meal"
                        )
                    )
                )
            )
        }

        if sleepLog?.screenBeforeBed == true {
            candidates.append(
                Candidate(
                    score: 58,
                    item: SleepNarrativeItem(
                        id: "screen",
                        icon: "iphone.gen3",
                        text: NSLocalizedString(
                            "sleep.factor.screen",
                            value: "Screen time close to bedtime was logged, which can make it harder to settle quickly.",
                            comment: "Sleep factor for screen time before bed"
                        )
                    )
                )
            )
        }

        if sleepLog?.stressfulDay == true {
            candidates.append(
                Candidate(
                    score: 56,
                    item: SleepNarrativeItem(
                        id: "stress",
                        icon: "brain.head.profile",
                        text: NSLocalizedString(
                            "sleep.factor.stress",
                            value: "Stress was marked yesterday, which often shows up as longer sleep latency or lighter sleep.",
                            comment: "Sleep factor for stressful day"
                        )
                    )
                )
            )
        }

        if sleepLog?.exerciseEvening == true {
            candidates.append(
                Candidate(
                    score: 48,
                    item: SleepNarrativeItem(
                        id: "evening_training",
                        icon: "figure.run",
                        text: NSLocalizedString(
                            "sleep.factor.training",
                            value: "An evening workout may have kept arousal elevated closer to bedtime.",
                            comment: "Sleep factor for evening training"
                        )
                    )
                )
            )
        }

        let deepPercent = sleepLog?.deepSleepPercent ?? state?.deepSleepPercent
        let remPercent = sleepLog?.remSleepPercent ?? state?.remSleepPercent
        let deepOutside = deepPercent.map { !SleepTargetEngine.deepSleepTargetRange(age: age).contains($0) } ?? false
        let remOutside = remPercent.map { !SleepTargetEngine.remSleepTargetRange(age: age).contains($0) } ?? false
        if deepOutside || remOutside {
            candidates.append(
                Candidate(
                    score: 54,
                    item: SleepNarrativeItem(
                        id: "stage_balance",
                        icon: "waveform.path.ecg",
                        text: NSLocalizedString(
                            "sleep.factor.stage_balance",
                            value: "Your stage balance sat a little outside its usual target range, so recovery may feel less complete today.",
                            comment: "Sleep factor for stage balance outside target ranges"
                        )
                    )
                )
            )
        }

        if let currentScore, let weekAverage, currentScore + 8 < weekAverage {
            candidates.append(
                Candidate(
                    score: 62,
                    item: SleepNarrativeItem(
                        id: "trend_drop",
                        icon: "chart.line.downtrend.xyaxis",
                        text: NSLocalizedString(
                            "sleep.factor.trend",
                            value: "Last night came in below your recent trend, so it may take a calmer day to fully bounce back.",
                            comment: "Sleep factor for nights below recent trend"
                        )
                    )
                )
            )
        }

        var seen: Set<String> = []
        return candidates
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.item.id < rhs.item.id
                }
                return lhs.score > rhs.score
            }
            .compactMap { candidate in
                guard seen.insert(candidate.item.id).inserted else { return nil }
                return candidate.item
            }
            .prefix(3)
            .map { $0 }
    }

    private static func deriveTryTonightItems(
        sleepLog: SleepLog?,
        state: PhysiologicalState?,
        age: Int,
        trendPoints: [SleepTrendPoint]
    ) -> [SleepNarrativeItem] {
        struct Candidate {
            let score: Int
            let item: SleepNarrativeItem
        }

        var candidates: [Candidate] = []
        let durationHours = sleepLog?.totalDurationMinutes.map { Double($0) / 60.0 } ?? state?.sleepDurationHours
        let targetRange = SleepScorer.optimalDurationRange(age: age)

        if let durationHours, durationHours < targetRange.lowerBound {
            candidates.append(
                Candidate(
                    score: 90,
                    item: SleepNarrativeItem(
                        id: "protect_window",
                        icon: "bed.double.fill",
                        text: NSLocalizedString(
                            "sleep.try.protect_window",
                            value: "Protect a slightly earlier bedtime tonight so your sleep window has more room.",
                            comment: "Sleep action to protect the bedtime window"
                        )
                    )
                )
            )
        }

        if sleepLog?.caffeineAfter14 == true {
            candidates.append(
                Candidate(
                    score: 86,
                    item: SleepNarrativeItem(
                        id: "caffeine_cutoff",
                        icon: "cup.and.saucer",
                        text: NSLocalizedString(
                            "sleep.try.caffeine",
                            value: "Keep caffeine to earlier in the day tomorrow and leave a longer buffer before bed.",
                            comment: "Sleep action to move caffeine earlier"
                        )
                    )
                )
            )
        }

        if sleepLog?.screenBeforeBed == true || (sleepLog?.timeToFallAsleepMinutes ?? 0) >= 30 || sleepLog?.stressfulDay == true {
            candidates.append(
                Candidate(
                    score: 82,
                    item: SleepNarrativeItem(
                        id: "wind_down",
                        icon: "lightbulb.slash",
                        text: NSLocalizedString(
                            "sleep.try.wind_down",
                            value: "Aim for a calmer final 30–60 minutes with dimmer light and less phone time.",
                            comment: "Sleep action for a calmer wind-down"
                        )
                    )
                )
            )
        }

        if sleepLog?.heavyMealLate == true {
            candidates.append(
                Candidate(
                    score: 74,
                    item: SleepNarrativeItem(
                        id: "lighter_dinner",
                        icon: "fork.knife",
                        text: NSLocalizedString(
                            "sleep.try.dinner",
                            value: "Keep dinner a little lighter and finish it earlier if you can.",
                            comment: "Sleep action for earlier lighter dinner"
                        )
                    )
                )
            )
        }

        if let awakenings = sleepLog?.numberOfAwakenings, awakenings >= 3 || (sleepLog?.sleepEfficiency ?? 100) < 85 {
            candidates.append(
                Candidate(
                    score: 72,
                    item: SleepNarrativeItem(
                        id: "environment",
                        icon: "moon.stars.fill",
                        text: NSLocalizedString(
                            "sleep.try.environment",
                            value: "Make the room a touch cooler, darker, and quieter to reduce overnight disruptions.",
                            comment: "Sleep action for sleep environment improvements"
                        )
                    )
                )
            )
        }

        if sleepLog?.exerciseEvening == true {
            candidates.append(
                Candidate(
                    score: 62,
                    item: SleepNarrativeItem(
                        id: "training_timing",
                        icon: "figure.cooldown",
                        text: NSLocalizedString(
                            "sleep.try.training",
                            value: "If possible, finish hard training a bit earlier and keep the evening wind-down gentler.",
                            comment: "Sleep action for earlier hard training"
                        )
                    )
                )
            )
        }

        if candidates.isEmpty {
            let averageScore = trendPoints.compactMap(\.score).average
            if let averageScore, averageScore < 75 {
                candidates.append(
                    Candidate(
                        score: 55,
                        item: SleepNarrativeItem(
                            id: "consistency",
                            icon: "clock.arrow.circlepath",
                            text: NSLocalizedString(
                                "sleep.try.consistency",
                                value: "The most helpful move tonight is consistency: protect your usual bedtime and wake time.",
                                comment: "Fallback sleep action for consistency"
                            )
                        )
                    )
                )
            }
        }

        var seen: Set<String> = []
        return candidates
            .sorted { lhs, rhs in lhs.score > rhs.score }
            .compactMap { candidate in
                guard seen.insert(candidate.item.id).inserted else { return nil }
                return candidate.item
            }
            .prefix(2)
            .map { $0 }
    }
}

struct SleepDetailSections: View {
    let snapshot: SleepDetailSnapshot
    let permissionState: SleepPermissionState
    let isRequestingAccess: Bool
    let statusMessage: String?
    let onRequestAccess: (() -> Void)?

    var body: some View {
        VStack(spacing: Spacing.m) {
            if let statusMessage, !statusMessage.isEmpty {
                infoBanner(
                    title: NSLocalizedString(
                        "sleep.status_title",
                        value: "HealthKit status",
                        comment: "Sleep detail status banner title"
                    ),
                    message: statusMessage,
                    systemImage: "heart.text.square"
                )
            }

            if !snapshot.hasAnySleepData {
                emptyStateCard
            } else {
                if snapshot.isPartialData {
                    infoBanner(
                        title: NSLocalizedString(
                            "sleep.partial_title",
                            value: "Some sleep data is missing",
                            comment: "Sleep detail partial data banner title"
                        ),
                        message: NSLocalizedString(
                            "sleep.partial_helper",
                            value: "Grant full Sleep access and keep a few nights synced for more accurate stages and timing.",
                            comment: "Sleep detail partial data banner message"
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                }

                if snapshot.shouldShowEstimateBadge {
                    infoBanner(
                        title: NSLocalizedString(
                            "global.estimate_badge",
                            value: "Estimate",
                            comment: "Low confidence estimate badge"
                        ),
                        message: NSLocalizedString(
                            "sleep.estimate_helper",
                            value: "This night is based on partial data. Verify bedtime and wake time in Apple Health for sharper insights.",
                            comment: "Sleep detail estimate message"
                        ),
                        systemImage: "waveform.path.ecg.rectangle"
                    )
                }

                scoreCard
                summaryCard
                stagesCard
                trendCard

                if !snapshot.factors.isEmpty {
                    narrativeCard(
                        title: NSLocalizedString(
                            "sleep.what_affected_title",
                            value: "What affected sleep",
                            comment: "Sleep detail section title for factors"
                        ),
                        systemImage: "magnifyingglass",
                        items: snapshot.factors
                    )
                }

                if !snapshot.tryTonightItems.isEmpty {
                    narrativeCard(
                        title: NSLocalizedString(
                            "sleep.try_tonight",
                            value: "Try tonight",
                            comment: "Sleep detail section title for gentle actions"
                        ),
                        systemImage: "sparkles",
                        items: snapshot.tryTonightItems
                    )
                }

                if let notes = snapshot.sleepLog?.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Label(
                            NSLocalizedString(
                                "sleep.notes_title",
                                value: "Notes",
                                comment: "Sleep detail notes section title"
                            ),
                            systemImage: "text.bubble"
                        )
                        .font(LifeOSTypography.subheadline.weight(.semibold))

                        Text(notes)
                            .font(LifeOSTypography.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.m)
                    .background(LifeOSColors.Surface.card)
                    .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
                }

                if let sourceSummary = snapshot.sourceSummary {
                    Text(sourceSummary)
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(permissionState.emptyTitle, systemImage: "bed.double")
                .font(LifeOSTypography.headline)

            Text(permissionState.emptyMessage)
                .font(LifeOSTypography.body)
                .foregroundStyle(.secondary)

            if permissionState.canRequestAccess, let onRequestAccess {
                Button(action: onRequestAccess) {
                    if isRequestingAccess {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(permissionState.actionTitle)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(LifeOSColors.Semantic.primary)
                .disabled(isRequestingAccess)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
    }

    private var scoreCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Label(String(localized: "sleep_title"), systemImage: "bed.double.fill")
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                Spacer()
                Text(
                    NSLocalizedString(
                        "sleep.score_non_medical",
                        value: "Quality score, not medical",
                        comment: "Sleep detail caption describing the sleep score"
                    )
                )
                .font(LifeOSTypography.caption2)
                .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(scoreValueText)
                    .font(LifeOSTypography.metricMedium)
                    .foregroundStyle(scoreBand.color)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(scoreBand.title)
                        .font(LifeOSTypography.headline)
                    if let confidenceScore = snapshot.confidenceScore {
                        Text(
                            String(
                                format: NSLocalizedString(
                                    "sleep.confidence_format",
                                    value: "Confidence %.0f%%",
                                    comment: "Sleep detail confidence format"
                                ),
                                confidenceScore * 100
                            )
                        )
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(
                NSLocalizedString(
                    "sleep.helper",
                    value: "Your sleep, explained.",
                    comment: "Sleep detail helper text"
                )
            )
            .font(LifeOSTypography.subheadline)
            .foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.s), count: 3), spacing: Spacing.s) {
                metricTile(
                    title: NSLocalizedString(
                        "sleep.metric.duration",
                        value: "Duration",
                        comment: "Sleep detail duration metric title"
                    ),
                    value: durationValueText
                )
                metricTile(
                    title: NSLocalizedString(
                        "sleep.metric.bedtime",
                        value: "Bedtime",
                        comment: "Sleep detail bedtime metric title"
                    ),
                    value: timeText(snapshot.bedtime)
                )
                metricTile(
                    title: NSLocalizedString(
                        "sleep.metric.wake",
                        value: "Wake time",
                        comment: "Sleep detail wake time metric title"
                    ),
                    value: timeText(snapshot.wakeTime)
                )
                metricTile(
                    title: NSLocalizedString(
                        "sleep.metric.efficiency",
                        value: "Efficiency",
                        comment: "Sleep detail efficiency metric title"
                    ),
                    value: percentageText(snapshot.sleepEfficiency)
                )
                metricTile(
                    title: NSLocalizedString(
                        "sleep.metric.awakenings",
                        value: "Awakenings",
                        comment: "Sleep detail awakenings metric title"
                    ),
                    value: countText(snapshot.awakenings)
                )
                metricTile(
                    title: NSLocalizedString(
                        "sleep.metric.latency",
                        value: "Sleep onset",
                        comment: "Sleep detail latency metric title"
                    ),
                    value: minutesText(snapshot.sleepLatencyMinutes)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
    }

    private var stagesCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(
                NSLocalizedString(
                    "sleep.stages_title",
                    value: "Sleep stages",
                    comment: "Sleep detail sleep stages title"
                ),
                systemImage: "waveform.path.ecg"
            )
            .font(LifeOSTypography.subheadline.weight(.semibold))

            if snapshot.hasStages {
                stageRow(
                    title: NSLocalizedString("sleep.stage.deep", value: "Deep", comment: "Sleep stage title for deep sleep"),
                    minutes: snapshot.deepMinutes,
                    percent: snapshot.deepPercent,
                    tint: LifeOSColors.Recovery.optimal,
                    targetText: targetText(for: .deep)
                )
                stageRow(
                    title: NSLocalizedString("sleep.stage.rem", value: "REM", comment: "Sleep stage title for REM sleep"),
                    minutes: snapshot.remMinutes,
                    percent: snapshot.remPercent,
                    tint: LifeOSColors.Recovery.ready,
                    targetText: targetText(for: .rem)
                )
                stageRow(
                    title: NSLocalizedString("sleep.stage.light", value: "Light", comment: "Sleep stage title for light sleep"),
                    minutes: snapshot.lightMinutes,
                    percent: snapshot.lightPercent,
                    tint: Color.secondary,
                    targetText: nil
                )
                stageRow(
                    title: NSLocalizedString("sleep.stage.awake", value: "Awake", comment: "Sleep stage title for awake time"),
                    minutes: snapshot.awakeMinutes,
                    percent: snapshot.awakePercent,
                    tint: LifeOSColors.Recovery.caution,
                    targetText: nil
                )

                if let stageFeedback = snapshot.stageFeedback, !stageFeedback.isEmpty {
                    Text(stageFeedback)
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, Spacing.xxs)
                }
            } else {
                Text(
                    NSLocalizedString(
                        "sleep.stages_unavailable",
                        value: "Sleep stages unavailable.",
                        comment: "Sleep detail fallback when sleep stages are unavailable"
                    )
                )
                .font(LifeOSTypography.body)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
    }

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(
                NSLocalizedString(
                    "sleep.trend_title",
                    value: "7-day trend",
                    comment: "Sleep detail trend title"
                ),
                systemImage: "chart.line.uptrend.xyaxis"
            )
            .font(LifeOSTypography.subheadline.weight(.semibold))

            if snapshot.trendPoints.contains(where: { $0.score != nil }) {
                SleepSparklineView(points: snapshot.trendPoints)
                    .frame(height: 112)

                HStack(alignment: .top) {
                    ForEach(snapshot.trendPoints) { point in
                        VStack(spacing: Spacing.xxs) {
                            Text(point.shortLabel)
                                .font(LifeOSTypography.caption2)
                                .foregroundStyle(point.isSelected ? .primary : .secondary)
                            Text(point.score.map { String(Int($0.rounded())) } ?? "–")
                                .font(LifeOSTypography.caption.weight(point.isSelected ? .semibold : .regular))
                                .foregroundStyle(point.isSelected ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                if let trendSummary = snapshot.trendSummary {
                    Text(trendSummary)
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(String(localized: "sleep_supportive_more_data"))
                    .font(LifeOSTypography.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
    }

    private func narrativeCard(title: String, systemImage: String, items: [SleepNarrativeItem]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(title, systemImage: systemImage)
                .font(LifeOSTypography.subheadline.weight(.semibold))

            ForEach(items) { item in
                HStack(alignment: .top, spacing: Spacing.s) {
                    Image(systemName: item.icon)
                        .foregroundStyle(LifeOSColors.Semantic.primary)
                        .frame(width: 18)

                    Text(item.text)
                        .font(LifeOSTypography.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
    }

    private func stageRow(
        title: String,
        minutes: Int?,
        percent: Double?,
        tint: Color,
        targetText: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.s) {
                Text(title)
                    .font(LifeOSTypography.body.weight(.semibold))
                Spacer()
                Text("\(minutes.map(String.init) ?? "–")m")
                    .font(LifeOSTypography.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(percent.map { String(format: "%.0f%%", $0) } ?? "–")
                    .font(LifeOSTypography.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 42, alignment: .trailing)
            }

            ProgressView(value: max(0, min(1, (percent ?? 0) / 100.0)))
                .tint(tint)

            if let targetText {
                Text(targetText)
                    .font(LifeOSTypography.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func targetText(for stage: SleepTargetStage) -> String? {
        switch stage {
        case .deep:
            let range = SleepTargetEngine.deepSleepTargetRange(age: snapshot.age)
            return String(
                format: NSLocalizedString(
                    "sleep.stage.target_format",
                    value: "Target %.0f–%.0f%%",
                    comment: "Sleep stage target format"
                ),
                range.lowerBound,
                range.upperBound
            )
        case .rem:
            let range = SleepTargetEngine.remSleepTargetRange(age: snapshot.age)
            return String(
                format: NSLocalizedString(
                    "sleep.stage.target_format",
                    value: "Target %.0f–%.0f%%",
                    comment: "Sleep stage target format"
                ),
                range.lowerBound,
                range.upperBound
            )
        }
    }

    private func infoBanner(title: String, message: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: systemImage)
                .foregroundStyle(LifeOSColors.Recovery.caution)
                .frame(width: LayoutConstants.iconSize, height: LayoutConstants.iconSize)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                Text(message)
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private func metricTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title)
                .font(LifeOSTypography.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(LifeOSTypography.body.weight(.semibold))
                .minimumScaleFactor(0.8)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.elevated)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private func timeText(_ date: Date?) -> String {
        guard let date else { return "–" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func durationText(_ minutes: Int?) -> String {
        guard let minutes else { return "–" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours > 0 {
            return "\(hours)h \(remainder)m"
        }
        return "\(remainder)m"
    }

    private func percentageText(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.0f%%", value)
    }

    private func countText(_ value: Int?) -> String {
        guard let value else { return "–" }
        return "\(value)"
    }

    private func minutesText(_ value: Int?) -> String {
        guard let value else { return "–" }
        return "\(value)m"
    }

    private var durationValueText: String {
        durationText(snapshot.durationMinutes)
    }

    private var scoreValueText: String {
        guard let score = snapshot.score else { return "–" }
        return "\(Int(score.rounded()))"
    }

    private var scoreBand: SleepScoreBand {
        SleepScoreBand(score: snapshot.score ?? 0)
    }
}

private enum SleepTargetStage {
    case deep
    case rem
}

private enum SleepScoreBand {
    case restorative
    case solid
    case mixed
    case restless

    init(score: Double) {
        switch score {
        case 85...:
            self = .restorative
        case 70..<85:
            self = .solid
        case 55..<70:
            self = .mixed
        default:
            self = .restless
        }
    }

    var title: String {
        switch self {
        case .restorative:
            return NSLocalizedString(
                "sleep.score_band.restorative",
                value: "Restorative",
                comment: "Sleep score band title for strong sleep"
            )
        case .solid:
            return NSLocalizedString(
                "sleep.score_band.solid",
                value: "Solid",
                comment: "Sleep score band title for good sleep"
            )
        case .mixed:
            return NSLocalizedString(
                "sleep.score_band.mixed",
                value: "Mixed",
                comment: "Sleep score band title for middling sleep"
            )
        case .restless:
            return NSLocalizedString(
                "sleep.score_band.restless",
                value: "Restless",
                comment: "Sleep score band title for weak sleep"
            )
        }
    }

    var color: Color {
        switch self {
        case .restorative:
            return LifeOSColors.Recovery.optimal
        case .solid:
            return LifeOSColors.Recovery.ready
        case .mixed:
            return LifeOSColors.Recovery.caution
        case .restless:
            return LifeOSColors.Recovery.critical
        }
    }
}

struct SleepSparklineView: View {
    let points: [SleepTrendPoint]

    var body: some View {
        GeometryReader { proxy in
            let plotted = points.enumerated().compactMap { index, point -> SparklinePoint? in
                guard let score = point.score else { return nil }
                return SparklinePoint(
                    index: index,
                    score: score,
                    isSelected: point.isSelected
                )
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius)
                    .fill(LifeOSColors.Surface.elevated)

                if plotted.count >= 2 {
                    let path = sparklinePath(points: plotted, size: proxy.size)
                    path
                        .stroke(LifeOSColors.Semantic.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                    path
                        .trimmedPath(from: 0, to: 1)
                        .stroke(LifeOSColors.Semantic.primary.opacity(0.15), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                }

                ForEach(plotted) { point in
                    Circle()
                        .fill(point.isSelected ? LifeOSColors.Semantic.primary : LifeOSColors.Surface.card)
                        .frame(width: point.isSelected ? 10 : 8, height: point.isSelected ? 10 : 8)
                        .overlay(
                            Circle()
                                .stroke(LifeOSColors.Semantic.primary, lineWidth: 2)
                        )
                        .position(position(for: point, size: proxy.size))
                }
            }
        }
    }

    private func sparklinePath(points: [SparklinePoint], size: CGSize) -> Path {
        var path = Path()
        for (offset, point) in points.enumerated() {
            let position = position(for: point, size: size)
            if offset == 0 {
                path.move(to: position)
            } else {
                path.addLine(to: position)
            }
        }
        return path
    }

    private func position(for point: SparklinePoint, size: CGSize) -> CGPoint {
        let horizontalPadding: CGFloat = 16
        let verticalPadding: CGFloat = 14
        let usableWidth = max(1, size.width - (horizontalPadding * 2))
        let usableHeight = max(1, size.height - (verticalPadding * 2))
        let xDenominator = max(1, CGFloat(max(points.count - 1, 1)))
        let x = horizontalPadding + (CGFloat(point.index) / xDenominator) * usableWidth
        let normalizedScore = max(0, min(1, point.score / 100))
        let y = verticalPadding + (1 - normalizedScore) * usableHeight
        return CGPoint(x: x, y: y)
    }

    private struct SparklinePoint: Identifiable {
        let id = UUID()
        let index: Int
        let score: Double
        let isSelected: Bool
    }
}

struct SleepCalendarView: View {
    @Binding var selectedDate: Date

    @State private var displayedMonth: Date
    @State private var statuses: [String: SleepCalendarDayStatus] = [:]
    @State private var isLoading = false

    @Environment(\.dismiss) private var dismiss
    private let dbQueue: DatabaseQueue
    private let calendar = Calendar.current

    init(
        selectedDate: Binding<Date>,
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue
    ) {
        self._selectedDate = selectedDate
        self._displayedMonth = State(initialValue: selectedDate.wrappedValue)
        self.dbQueue = dbQueue
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.m) {
                monthHeader
                weekdayHeader
                monthGrid

                if isLoading {
                    ProgressView()
                        .padding(.top, Spacing.s)
                }

                Spacer(minLength: 0)
            }
            .padding(LayoutConstants.contentPadding)
            .background(LifeOSColors.Surface.background)
            .navigationTitle(
                NSLocalizedString(
                    "sleep.history_title",
                    value: "Sleep history",
                    comment: "Sleep calendar sheet title"
                )
            )
            .task(id: displayedMonth) {
                await loadStatuses()
            }
        }
    }

    private var monthHeader: some View {
        HStack {
            Button {
                displayedMonth = calendar.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: LayoutConstants.minTouchTarget, height: LayoutConstants.minTouchTarget)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(displayedMonth, format: .dateTime.month(.wide).year())
                .font(LifeOSTypography.headline)

            Spacer()

            Button {
                displayedMonth = calendar.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: LayoutConstants.minTouchTarget, height: LayoutConstants.minTouchTarget)
            }
            .buttonStyle(.plain)
        }
    }

    private var weekdayHeader: some View {
        let weekdaySymbols = calendar.shortWeekdaySymbols
        return HStack {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var monthGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.xs), count: 7), spacing: Spacing.xs) {
            ForEach(Array(daysInMonth().enumerated()), id: \.offset) { _, date in
                if let date {
                    let dayString = DiaryDateFormatter.formatDate(date)
                    let status = statuses[dayString] ?? .noData
                    let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
                    let isToday = calendar.isDateInToday(date)

                    Button {
                        selectedDate = date
                        dismiss()
                    } label: {
                        VStack(spacing: Spacing.xxs) {
                            Text("\(calendar.component(.day, from: date))")
                                .font(LifeOSTypography.body.weight(isSelected ? .semibold : .regular))

                            statusIcon(for: status)
                                .font(.caption2)
                                .foregroundStyle(statusColor(for: status))
                                .opacity(status == .noData ? 0 : 1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .padding(.vertical, Spacing.xxs)
                        .background(
                            RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius)
                                .fill(isSelected ? LifeOSColors.Semantic.primary.opacity(0.14) : LifeOSColors.Surface.card)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius)
                                .stroke(isToday ? LifeOSColors.Semantic.primary.opacity(0.5) : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                        .frame(height: 46)
                }
            }
        }
    }

    private func loadStatuses() async {
        isLoading = true
        defer { isLoading = false }
        do {
            statuses = try await SleepDetailLoader.loadMonthStatuses(month: displayedMonth, dbQueue: dbQueue)
        } catch {
            statuses = [:]
        }
    }

    private func daysInMonth() -> [Date?] {
        guard
            let firstDay = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)),
            let range = calendar.range(of: .day, in: .month, for: displayedMonth)
        else {
            return []
        }

        let firstWeekday = calendar.component(.weekday, from: firstDay)
        let leadingSpaces = (firstWeekday - calendar.firstWeekday + 7) % 7
        var days = Array(repeating: Optional<Date>.none, count: leadingSpaces)

        for dayNumber in range {
            if let date = calendar.date(byAdding: .day, value: dayNumber - 1, to: firstDay) {
                days.append(date)
            }
        }
        return days
    }

    @ViewBuilder
    private func statusIcon(for status: SleepCalendarDayStatus) -> some View {
        switch status {
        case .good:
            Image(systemName: "checkmark.circle.fill")
        case .low:
            Image(systemName: "arrow.down.right.circle.fill")
        case .noData:
            Image(systemName: "circle")
        }
    }

    private func statusColor(for status: SleepCalendarDayStatus) -> Color {
        switch status {
        case .good:
            return LifeOSColors.Recovery.ready
        case .low:
            return LifeOSColors.Recovery.caution
        case .noData:
            return .clear
        }
    }
}

private extension Array where Element == Double {
    var average: Double? {
        guard !isEmpty else { return nil }
        return reduce(0, +) / Double(count)
    }
}
