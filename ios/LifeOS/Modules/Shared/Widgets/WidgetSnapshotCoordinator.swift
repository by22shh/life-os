import Foundation
import GRDB
import OSLog
#if canImport(WidgetKit)
import WidgetKit
#endif

actor WidgetSnapshotCoordinator {
    typealias SnapshotBuilder = @Sendable (
        _ dbQueue: DatabaseQueue,
        _ authId: String?,
        _ now: Date,
        _ privacy: WidgetPrivacySettings
    ) async throws -> WidgetSnapshot?

    private static let logger = Logger(subsystem: "com.lifeos.app", category: "Widgets")
    // Shared builder avoids referencing `Self` inside initializer default arguments.
    private static let defaultSnapshotBuilder: SnapshotBuilder = { dbQueue, authId, now, privacy in
        try await WidgetSnapshotCoordinator.buildSnapshot(
            dbQueue: dbQueue,
            authId: authId,
            now: now,
            privacy: privacy
        )
    }
    private let dbQueue: DatabaseQueue
    private let defaults: UserDefaults?
    private let nowProvider: @Sendable () -> Date
    private let snapshotBuilder: SnapshotBuilder
    private let reloadTimelinesHandler: @Sendable () -> Void

    init(
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue,
        defaults: UserDefaults? = WidgetSnapshotStorage.sharedDefaults(),
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        snapshotBuilder: SnapshotBuilder? = nil,
        reloadTimelinesHandler: @escaping @Sendable () -> Void = WidgetSnapshotCoordinator.reloadAllTimelines
    ) {
        self.dbQueue = dbQueue
        self.defaults = defaults
        self.nowProvider = nowProvider
        self.snapshotBuilder = snapshotBuilder ?? Self.defaultSnapshotBuilder
        self.reloadTimelinesHandler = reloadTimelinesHandler
    }

    func refreshSnapshot() async {
        let privacy = WidgetSnapshotStorage.loadPrivacy(defaults: defaults)
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        let now = nowProvider()

        do {
            let snapshot = try await snapshotBuilder(dbQueue, authId, now, privacy)
            WidgetSnapshotStorage.storeSnapshot(snapshot, defaults: defaults)
        } catch {
            let canPreserve = (try? await dbQueue.read { db in
                guard let user = try UserIdentityLookup.fetchUser(authId: authId, db: db) else { return false }
                return try !NutritionSafetyPolicy.hidesCalories(in: db, userId: user.id)
            }) ?? false
            if !canPreserve { WidgetSnapshotStorage.storeSnapshot(nil, defaults: defaults) }
            let preservedExistingSnapshot = WidgetSnapshotStorage.loadSnapshot(defaults: defaults) != nil
            let errorDescription = String(describing: error)
            Self.logger.error(
                "widgets.snapshot.refresh_failed preserved_existing=\(preservedExistingSnapshot, privacy: .public) error=\(errorDescription, privacy: .public)"
            )
        }
        reloadTimelinesHandler()
    }

    func clearSnapshot() {
        WidgetSnapshotStorage.storeSnapshot(nil, defaults: defaults)
        reloadTimelinesHandler()
    }

    static func buildSnapshot(
        dbQueue: DatabaseQueue,
        authId: String?,
        now: Date,
        privacy: WidgetPrivacySettings
    ) async throws -> WidgetSnapshot? {
        try await dbQueue.read { db in
            guard let user = try UserIdentityLookup.fetchUser(authId: authId, db: db) else {
                return nil
            }

            let timeZone = safeTimeZone(user.timezone)
            let today = localDayString(for: now, timeZone: timeZone)
            let todayDate = date(from: today, timeZone: timeZone)
            var privacy = privacy
            if try NutritionSafetyPolicy.hidesCalories(in: db, userId: user.id) {
                privacy.showNutrition = false
            }

            return WidgetSnapshot(
                generatedAt: now,
                privacy: privacy,
                recovery: privacy.showRecoveryScore
                    ? try buildRecovery(db: db, userId: user.id, today: today)
                    : nil,
                nutrition: privacy.showNutrition
                    ? try buildNutrition(db: db, userId: user.id, today: today)
                    : nil,
                supplements: privacy.showSupplements
                    ? try buildSupplements(
                        db: db,
                        userId: user.id,
                        today: today,
                        todayDate: todayDate,
                        now: now,
                        timeZone: timeZone
                    )
                    : nil,
                training: privacy.showTraining
                    ? try buildTraining(
                        db: db,
                        userId: user.id,
                        today: today,
                        todayDate: todayDate,
                        timeZone: timeZone
                    )
                    : nil
            )
        }
    }

    nonisolated private static func reloadAllTimelines() {
#if canImport(WidgetKit)
        let center = WidgetCenter.shared
        for kind in LifeOSWidgetConstants.allKinds {
            center.reloadTimelines(ofKind: kind)
        }
#endif
    }

    nonisolated private static func buildRecovery(
        db: Database,
        userId: UUID,
        today: String
    ) throws -> WidgetSnapshot.RecoveryPayload? {
        guard let state = try PhysiologicalState.fetchOne(
            db,
            sql: """
                SELECT *
                FROM physiological_states
                WHERE (user_id = ? OR user_id = ?)
                  AND date = ?
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString, today]
        ) else {
            return nil
        }

        let previousScore = try Double.fetchOne(
            db,
            sql: """
                SELECT recovery_score
                FROM physiological_states
                WHERE (user_id = ? OR user_id = ?)
                  AND date < ?
                ORDER BY date DESC
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString, today]
        )

        let currentScore = Int(state.recoveryScore.rounded())
        let delta = previousScore.map { currentScore - Int($0.rounded()) }

        return WidgetSnapshot.RecoveryPayload(
            recoveryScore: currentScore,
            recoveryZone: state.recoveryZone.rawValue,
            recoveryZoneLabel: state.recoveryZone.label,
            recoveryDelta: delta
        )
    }

    nonisolated private static func buildNutrition(
        db: Database,
        userId: UUID,
        today: String
    ) throws -> WidgetSnapshot.NutritionPayload {
        let suppressTargets = try NutritionSafetyPolicy.suppressesTargets(in: db, userId: userId)
        let totals = try Row.fetchOne(
            db,
            sql: """
                SELECT
                    COALESCE(CAST(SUM(calories) AS INTEGER), 0) AS calories,
                    COALESCE(CAST(SUM(protein_g) AS INTEGER), 0) AS protein_g,
                    COALESCE(CAST(SUM(carbs_g) AS INTEGER), 0) AS carbs_g,
                    COALESCE(CAST(SUM(fat_g) AS INTEGER), 0) AS fat_g,
                    COALESCE(CAST(SUM(fiber_g) AS INTEGER), 0) AS fiber_g
                FROM food_logs
                WHERE (user_id = ? OR user_id = ?)
                  AND logged_date = ?
                  AND deleted_at IS NULL
                """,
            arguments: [userId, userId.uuidString, today]
        )

        let targetRow = try Row.fetchOne(
            db,
            sql: """
                SELECT
                    COALESCE(final_calories, base_calories) AS calories,
                    COALESCE(final_protein_g, base_protein_g) AS protein_g,
                    COALESCE(final_carbs_g, base_carbs_g) AS carbs_g,
                    COALESCE(final_fat_g, base_fat_g) AS fat_g
                FROM daily_nutrition_targets
                WHERE (user_id = ? OR user_id = ?)
                  AND date = ?
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString, today]
        )

        let totalWaterMl = try Int.fetchOne(
            db,
            sql: """
                SELECT COALESCE(SUM(water_ml), 0)
                FROM hydration_logs
                WHERE (user_id = ? OR user_id = ?)
                  AND logged_date = ?
                  AND deleted_at IS NULL
                """,
            arguments: [userId, userId.uuidString, today]
        ) ?? 0

        let effectiveWeight = try WeightResolution.getEffectiveWeight(userId: userId, db: db) ?? 70.0
        let waterTarget = max(1_800, Int((effectiveWeight * 35).rounded()))
        let fiberTarget = max(25, Int((effectiveWeight * 0.4).rounded()))

        return WidgetSnapshot.NutritionPayload(
            calories: totals?["calories"] ?? 0,
            targetCalories: suppressTargets ? nil : targetRow?["calories"],
            proteinG: totals?["protein_g"] ?? 0,
            targetProteinG: suppressTargets ? nil : targetRow?["protein_g"],
            carbsG: totals?["carbs_g"] ?? 0,
            targetCarbsG: suppressTargets ? nil : targetRow?["carbs_g"],
            fatG: totals?["fat_g"] ?? 0,
            targetFatG: suppressTargets ? nil : targetRow?["fat_g"],
            fiberG: totals?["fiber_g"] ?? 0,
            targetFiberG: fiberTarget,
            waterMl: totalWaterMl,
            targetWaterMl: waterTarget
        )
    }

    nonisolated private static func buildSupplements(
        db: Database,
        userId: UUID,
        today: String,
        todayDate: Date,
        now: Date,
        timeZone: TimeZone
    ) throws -> WidgetSnapshot.SupplementsPayload {
        let supplements = try loadSupplementRows(db: db, userId: userId)
        guard !supplements.isEmpty else {
            return WidgetSnapshot.SupplementsPayload(
                supplementsTotal: 0,
                supplementsTaken: 0,
                nextSupplement: nil
            )
        }

        let horizonEndDate = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: 7,
            to: todayDate
        ) ?? todayDate
        let horizonEndDay = localDayString(for: horizonEndDate, timeZone: timeZone)
        let logs = try loadSupplementLogs(
            db: db,
            userId: userId,
            startDay: today,
            endDay: horizonEndDay
        )

        let takenLookup = buildSupplementLookup(logs: logs)
        let occurrences = buildSupplementOccurrences(
            supplements: supplements,
            startDay: todayDate,
            now: now,
            timeZone: timeZone,
            horizonDays: 8,
            takenLookup: takenLookup
        )

        let todayOccurrences = occurrences.filter { $0.day == today }
        let nextOccurrence = occurrences.first { !$0.isTaken && $0.scheduledAt >= now }

        return WidgetSnapshot.SupplementsPayload(
            supplementsTotal: todayOccurrences.count,
            supplementsTaken: todayOccurrences.filter(\.isTaken).count,
            nextSupplement: nextOccurrence.map {
                WidgetSnapshot.SupplementEntry(
                    name: $0.name,
                    timeLabel: $0.timeLabel,
                    dayLabel: displayDayLabel(
                        for: $0.day,
                        relativeTo: today,
                        timeZone: timeZone
                    ),
                    scheduledDate: $0.day
                )
            }
        )
    }

    nonisolated private static func buildTraining(
        db: Database,
        userId: UUID,
        today: String,
        todayDate: Date,
        timeZone: TimeZone
    ) throws -> WidgetSnapshot.TrainingPayload {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT
                    tps.title,
                    tps.session_type,
                    tps.planned_date,
                    tps.planned_duration_minutes,
                    tp.name AS plan_name
                FROM training_plan_sessions tps
                LEFT JOIN training_plans tp
                  ON tp.id = tps.training_plan_id
                WHERE (tps.user_id = ? OR tps.user_id = ?)
                  AND tps.planned_date >= ?
                  AND tps.status IN ('planned', 'rescheduled', 'scheduled', 'modified')
                  AND (tp.status IS NULL OR tp.status = 'active')
                ORDER BY
                  tps.planned_date ASC,
                  CASE tps.status
                    WHEN 'planned' THEN 0
                    WHEN 'scheduled' THEN 0
                    ELSE 1
                  END,
                  tps.updated_at DESC
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString, today]
        )

        guard let row,
              let plannedDate: String = row["planned_date"],
              let sessionType: String = row["session_type"] else {
            return WidgetSnapshot.TrainingPayload(nextWorkout: nil)
        }

        let title = ((row["title"] as String?)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? humanizedIdentifier(sessionType)
        let subtitle = ((row["plan_name"] as String?)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        }
        let deepLink = "lifeos://workout?date=\(plannedDate)"

        return WidgetSnapshot.TrainingPayload(
            nextWorkout: WidgetSnapshot.WorkoutEntry(
                title: title,
                subtitle: subtitle,
                dayLabel: displayDayLabel(
                    for: plannedDate,
                    relativeTo: localDayString(for: todayDate, timeZone: timeZone),
                    timeZone: timeZone
                ),
                plannedDate: plannedDate,
                durationMinutes: row["planned_duration_minutes"],
                deepLink: deepLink
            )
        )
    }

    nonisolated private static func loadSupplementRows(
        db: Database,
        userId: UUID
    ) throws -> [WidgetSupplementRow] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT
                    us.id,
                    us.custom_name,
                    us.dose_amount,
                    us.dose_unit,
                    us.frequency,
                    us.scheduled_times,
                    us.days_of_week,
                    us.started_at,
                    us.ended_at,
                    us.active,
                    sc.name AS catalog_name
                FROM user_supplements us
                LEFT JOIN supplement_catalog sc ON sc.id = us.catalog_id
                WHERE us.user_id = ? OR us.user_id = ?
                """,
            arguments: [userId, userId.uuidString]
        )

        return rows.compactMap { row in
            guard let id = MixedUUIDStorage.decode(from: row, column: "id"),
                  let frequency: String = row["frequency"],
                  let startedAt: String = row["started_at"] else {
                return nil
            }

            let customName = (row["custom_name"] as String?)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let catalogName = (row["catalog_name"] as String?)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = {
                if let customName, !customName.isEmpty { return customName }
                if let catalogName, !catalogName.isEmpty { return catalogName }
                return String(localized: "widget.supplement.fallback_name")
            }()

            return WidgetSupplementRow(
                id: id,
                name: name,
                frequency: frequency,
                scheduledTimes: normalizedScheduledTimes(from: row["scheduled_times"]),
                daysOfWeek: normalizedDaysOfWeek(from: row["days_of_week"]),
                startedAt: startedAt,
                endedAt: row["ended_at"],
                active: row["active"] ?? false
            )
        }
    }

    nonisolated private static func loadSupplementLogs(
        db: Database,
        userId: UUID,
        startDay: String,
        endDay: String
    ) throws -> [WidgetSupplementLogRow] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT user_supplement_id, supplement_name, taken_date, scheduled_time
                FROM supplement_logs
                WHERE (user_id = ? OR user_id = ?)
                  AND deleted_at IS NULL
                  AND taken_date >= ?
                  AND taken_date <= ?
                """,
            arguments: [userId, userId.uuidString, startDay, endDay]
        )

        return rows.compactMap { row in
            guard let takenDate: String = row["taken_date"],
                  let supplementName: String = row["supplement_name"] else {
                return nil
            }

            return WidgetSupplementLogRow(
                userSupplementId: MixedUUIDStorage.decode(from: row, column: "user_supplement_id"),
                supplementName: supplementName,
                takenDate: normalizeDay(takenDate),
                scheduledTime: normalizedWallClockTime(from: row["scheduled_time"] as String?)
            )
        }
    }

    nonisolated private static func buildSupplementLookup(
        logs: [WidgetSupplementLogRow]
    ) -> WidgetSupplementLookup {
        var byId = Set<String>()
        var byName = Set<String>()

        for log in logs {
            guard let scheduledTime = log.scheduledTime else { continue }
            if let userSupplementId = log.userSupplementId {
                byId.insert(supplementLookupKey(
                    identifier: userSupplementId.uuidString.lowercased(),
                    day: log.takenDate,
                    scheduledTime: scheduledTime
                ))
            }
            byName.insert(supplementLookupKey(
                identifier: normalizedName(log.supplementName),
                day: log.takenDate,
                scheduledTime: scheduledTime
            ))
        }

        return WidgetSupplementLookup(byId: byId, byName: byName)
    }

    nonisolated private static func buildSupplementOccurrences(
        supplements: [WidgetSupplementRow],
        startDay: Date,
        now: Date,
        timeZone: TimeZone,
        horizonDays: Int,
        takenLookup: WidgetSupplementLookup
    ) -> [WidgetSupplementOccurrence] {
        var occurrences: [WidgetSupplementOccurrence] = []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        for dayOffset in 0..<max(horizonDays, 1) {
            guard let candidateDate = calendar.date(byAdding: .day, value: dayOffset, to: startDay) else {
                continue
            }
            let day = localDayString(for: candidateDate, timeZone: timeZone)

            for supplement in supplements {
                guard isSupplementActive(supplement, on: day) else { continue }
                guard shouldSchedule(supplement, on: candidateDate, timeZone: timeZone) else { continue }

                for scheduledTime in supplement.scheduledTimes {
                    guard let scheduledAt = wallClockDate(
                        on: candidateDate,
                        scheduledTime: scheduledTime,
                        timeZone: timeZone
                    ) else {
                        continue
                    }

                    let isTaken = takenLookup.contains(
                        supplementId: supplement.id,
                        supplementName: supplement.name,
                        day: day,
                        scheduledTime: scheduledTime
                    )

                    occurrences.append(
                        WidgetSupplementOccurrence(
                            id: supplement.id,
                            name: supplement.name,
                            day: day,
                            scheduledAt: scheduledAt,
                            timeLabel: scheduledTime,
                            isTaken: isTaken
                        )
                    )
                }
            }
        }

        return occurrences.sorted { lhs, rhs in
            if lhs.scheduledAt == rhs.scheduledAt {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.scheduledAt < rhs.scheduledAt
        }
    }

    nonisolated private static func isSupplementActive(
        _ supplement: WidgetSupplementRow,
        on day: String
    ) -> Bool {
        guard supplement.active else { return false }
        guard supplement.startedAt <= day else { return false }
        if let endedAt = supplement.endedAt, !endedAt.isEmpty, endedAt < day {
            return false
        }
        return supplement.frequency != SupplementFrequency.asNeeded.rawValue
    }

    nonisolated private static func shouldSchedule(
        _ supplement: WidgetSupplementRow,
        on date: Date,
        timeZone: TimeZone
    ) -> Bool {
        switch supplement.frequency {
        case SupplementFrequency.weekly.rawValue:
            let weekday = weekdayIndex(for: date, timeZone: timeZone)
            if !supplement.daysOfWeek.isEmpty {
                return supplement.daysOfWeek.contains(weekday)
            }
            return weekday == weekdayIndex(for: supplement.startedAt, timeZone: timeZone)
        default:
            if !supplement.daysOfWeek.isEmpty {
                return supplement.daysOfWeek.contains(weekdayIndex(for: date, timeZone: timeZone))
            }
            return true
        }
    }

    nonisolated private static func normalizedScheduledTimes(from rawValue: String?) -> [String] {
        guard let rawValue,
              let data = rawValue.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }

        return Array(Set(values.compactMap(normalizedWallClockTime))).sorted()
    }

    nonisolated private static func normalizedDaysOfWeek(from rawValue: String?) -> [Int] {
        guard let rawValue,
              let data = rawValue.data(using: .utf8),
              let values = try? JSONDecoder().decode([Int].self, from: data) else {
            return []
        }
        return values.filter { (0...6).contains($0) }
    }

    nonisolated private static func normalizedWallClockTime(from rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
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

        return String(format: "%02d:%02d", hour, minute)
    }

    nonisolated private static func wallClockDate(
        on day: Date,
        scheduledTime: String,
        timeZone: TimeZone
    ) -> Date? {
        let parts = scheduledTime.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: day
        )
    }

    nonisolated private static func supplementLookupKey(
        identifier: String,
        day: String,
        scheduledTime: String
    ) -> String {
        "\(identifier)|\(day)|\(scheduledTime)"
    }

    nonisolated private static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    nonisolated private static func displayDayLabel(
        for targetDay: String,
        relativeTo referenceDay: String,
        timeZone: TimeZone
    ) -> String {
        let targetDate = date(from: targetDay, timeZone: timeZone)
        let referenceDate = date(from: referenceDay, timeZone: timeZone)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let delta = calendar.dateComponents([.day], from: referenceDate, to: targetDate).day ?? 0

        if delta == 0 { return String(localized: "widget.relative_day_today") }
        if delta == 1 { return String(localized: "widget.relative_day_tomorrow") }
        if delta == -1 { return String(localized: "widget.relative_day_yesterday") }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale.current
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: targetDate)
    }

    nonisolated private static func humanizedIdentifier(_ value: String) -> String {
        if let sessionType = SessionType(rawValue: value) {
            switch sessionType {
            case .strength:
                return String(localized: "widget.session_type.strength")
            case .cardio:
                return String(localized: "widget.session_type.cardio")
            case .mobility:
                return String(localized: "widget.session_type.mobility")
            case .mixed:
                return String(localized: "widget.session_type.mixed")
            case .recovery:
                return String(localized: "widget.session_type.recovery")
            }
        }

        return value
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    nonisolated private static func safeTimeZone(_ identifier: String) -> TimeZone {
        TimeZone(identifier: identifier) ?? .current
    }

    nonisolated private static func localDayString(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    nonisolated private static func date(from day: String, timeZone: TimeZone) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day) ?? Date()
    }

    nonisolated private static func normalizeDay(_ value: String) -> String {
        let prefix = String(value.prefix(10))
        let pattern = #"^\d{4}-\d{2}-\d{2}$"#
        if prefix.range(of: pattern, options: .regularExpression) != nil {
            return prefix
        }
        return value
    }

    nonisolated private static func weekdayIndex(
        for day: String,
        timeZone: TimeZone
    ) -> Int {
        weekdayIndex(for: date(from: day, timeZone: timeZone), timeZone: timeZone)
    }

    nonisolated private static func weekdayIndex(
        for date: Date,
        timeZone: TimeZone
    ) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.component(.weekday, from: date) - 1
    }
}

private struct WidgetSupplementRow: Sendable {
    let id: UUID
    let name: String
    let frequency: String
    let scheduledTimes: [String]
    let daysOfWeek: [Int]
    let startedAt: String
    let endedAt: String?
    let active: Bool
}

private struct WidgetSupplementLogRow: Sendable {
    let userSupplementId: UUID?
    let supplementName: String
    let takenDate: String
    let scheduledTime: String?
}

private struct WidgetSupplementOccurrence: Sendable {
    let id: UUID
    let name: String
    let day: String
    let scheduledAt: Date
    let timeLabel: String
    let isTaken: Bool
}

private struct WidgetSupplementLookup: Sendable {
    let byId: Set<String>
    let byName: Set<String>

    func contains(
        supplementId: UUID,
        supplementName: String,
        day: String,
        scheduledTime: String
    ) -> Bool {
        let idKey = "\(supplementId.uuidString.lowercased())|\(day)|\(scheduledTime)"
        if byId.contains(idKey) {
            return true
        }
        let nameKey = "\(supplementName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(day)|\(scheduledTime)"
        return byName.contains(nameKey)
    }
}

#if DEBUG
extension WidgetSnapshotCoordinator {
    static func _testBuildSnapshot(
        dbQueue: DatabaseQueue,
        authId: String?,
        now: Date,
        privacy: WidgetPrivacySettings = WidgetPrivacySettings()
    ) async throws -> WidgetSnapshot? {
        try await buildSnapshot(
            dbQueue: dbQueue,
            authId: authId,
            now: now,
            privacy: privacy
        )
    }
}
#endif
