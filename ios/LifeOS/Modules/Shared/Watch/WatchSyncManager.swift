import Foundation
#if os(iOS)
import GRDB
import OSLog
import WatchConnectivity

struct WatchSnapshot: Codable, Sendable {
    struct NextBestAction: Codable, Sendable {
        struct Payload: Codable, Sendable {
            var deepLink: String?
            var supplementName: String?
            var scheduledTime: String?
            var insightId: String?
            var date: String?

            enum CodingKeys: String, CodingKey {
                case deepLink = "deep_link"
                case supplementName = "supplement_name"
                case scheduledTime = "scheduled_time"
                case insightId = "insight_id"
                case date
            }
        }

        var type: String
        var labelCopyId: String
        var payload: Payload?

        enum CodingKeys: String, CodingKey {
            case type
            case labelCopyId = "label_copy_id"
            case payload
        }
    }

    struct SupplementsDueSoon: Codable, Sendable {
        var time: String
        var count: Int
    }

    var date: String?
    var lastUpdatedAt: Date
    var recoveryScore: Double?
    var recoveryZone: String?
    var confidenceScore: Double?
    var nextBestAction: NextBestAction?
    var sleepDurationHours: Double?
    var sleepQualityPercent: Double?
    var nutritionAdherencePercent: Double?
    var supplementsDueSoon: SupplementsDueSoon?
    var wasTruncated: Bool?

    enum CodingKeys: String, CodingKey {
        case date
        case lastUpdatedAt = "last_updated_at"
        case recoveryScore = "recovery_score"
        case recoveryZone = "recovery_zone"
        case confidenceScore = "confidence_score"
        case nextBestAction = "next_best_action"
        case sleepDurationHours = "sleep_duration_hours"
        case sleepQualityPercent = "sleep_quality_percent"
        case nutritionAdherencePercent = "nutrition_adherence_percent"
        case supplementsDueSoon = "supplements_due_soon"
        case wasTruncated = "was_truncated"
    }
}

private struct WatchSnapshotResponse: Codable {
    struct NextBestAction: Codable {
        struct Payload: Codable {
            var deepLink: String?
            var supplementName: String?
            var scheduledTime: String?
            var insightId: String?
            var date: String?

            enum CodingKeys: String, CodingKey {
                case deepLink = "deep_link"
                case supplementName = "supplement_name"
                case scheduledTime = "scheduled_time"
                case insightId = "insight_id"
                case date
            }
        }

        var type: String
        var labelCopyId: String
        var payload: Payload?

        enum CodingKeys: String, CodingKey {
            case type
            case labelCopyId = "label_copy_id"
            case payload
        }
    }

    struct SupplementsDueSoon: Codable {
        var time: String
        var count: Int
    }

    var date: String?
    var lastUpdatedAt: Date
    var recoveryScore: Double?
    var recoveryZone: String?
    var confidenceScore: Double?
    var nextBestAction: NextBestAction?
    var sleepDurationHours: Double?
    var sleepQualityPercent: Double?
    var nutritionAdherencePercent: Double?
    var supplementsDueSoon: SupplementsDueSoon?

    enum CodingKeys: String, CodingKey {
        case date
        case lastUpdatedAt = "last_updated_at"
        case recoveryScore = "recovery_score"
        case recoveryZone = "recovery_zone"
        case confidenceScore = "confidence_score"
        case nextBestAction = "next_best_action"
        case sleepDurationHours = "sleep_duration_hours"
        case sleepQualityPercent = "sleep_quality_percent"
        case nutritionAdherencePercent = "nutrition_adherence_percent"
        case supplementsDueSoon = "supplements_due_soon"
    }
}

private enum WatchActionMutationError: Error {
    case missingUser
    case invalidPayload
}

private struct LocalWatchSnapshotBuild: Sendable {
    let snapshot: WatchSnapshot
    let resolvedDate: String
}

private struct LocalWatchSupplementRow: Sendable {
    let id: UUID
    let name: String
    let doseAmount: Double?
    let doseUnit: String
    let frequency: String
    let scheduledTimes: [String]
    let daysOfWeek: [Int]
    let startedAt: String
    let endedAt: String?
    let active: Bool
}

private struct LocalWatchSupplementLogRow: Sendable {
    let id: UUID
    let userSupplementId: UUID?
    let supplementName: String
    let scheduledTime: String?
}

private struct LocalWatchSupplementScheduleEntry: Sendable {
    let time: String
    let supplements: [LocalWatchSupplementScheduleItem]
}

private struct LocalWatchSupplementScheduleItem: Sendable {
    let name: String
    let taken: Bool
}

private let watchPendingOpenOnIPhoneLinksDefaultsKey = "watch.pending_open_on_iphone_links"
private let watchDeepLinkNotificationSource = "watch"

enum WatchSnapshotRefreshSource: Equatable, Sendable {
    case server
    case local
    case none
}

@MainActor
final class WatchSyncManager: NSObject {
    static let shared = WatchSyncManager()
#if DEBUG
    @MainActor private static var testPushLatestSnapshotOverride: ((String?) async -> Void)?
#endif

    private let logger = Logger(subsystem: "com.lifeos.app", category: "WatchSyncManager")
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let apiClient = APIClient()
    private let maxSnapshotSizeBytes = 4096
    private var lastSnapshot: WatchSnapshot?

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func clearSnapshot() {
        if WCSession.isSupported() {
            for transfer in WCSession.default.outstandingUserInfoTransfers { transfer.cancel() }
        }
        let empty = WatchSnapshot(date: nil, lastUpdatedAt: Date(), recoveryScore: nil, recoveryZone: nil, confidenceScore: nil, nextBestAction: nil, sleepDurationHours: nil, sleepQualityPercent: nil, nutritionAdherencePercent: nil, supplementsDueSoon: nil, wasTruncated: false)
        push(snapshot: empty)
        writeComplicationData(snapshot: empty)
    }

    func push(snapshot: WatchSnapshot) {
        var safeSnapshot = snapshot
        if NutritionSafetyPolicy.suppressesTargets {
            safeSnapshot.nutritionAdherencePercent = nil
            if safeSnapshot.nextBestAction?.type == "log_meal" || safeSnapshot.nextBestAction?.type == "nutrition_under_target" || safeSnapshot.nextBestAction?.payload?.deepLink?.hasPrefix("lifeos://nutrition") == true {
                safeSnapshot.nextBestAction = nil
            }
        }
        let prepared = truncateIfNeeded(safeSnapshot)
        lastSnapshot = prepared

        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        if NutritionSafetyPolicy.suppressesTargets {
            for transfer in session.outstandingUserInfoTransfers { transfer.cancel() }
        }

        guard let data = try? encoder.encode(prepared) else { return }

        session.transferUserInfo(["snapshot": data])
        session.transferCurrentComplicationUserInfo(["snapshot": data])
        try? session.updateApplicationContext(["snapshot": data])

        // Write to shared UserDefaults for WidgetKit complications (§4)
        writeComplicationData(snapshot: prepared)
    }

    /// Writes minimal snapshot data to shared UserDefaults for WidgetKit complication access.
    private func writeComplicationData(
        snapshot: WatchSnapshot,
        defaults: UserDefaults? = UserDefaults(suiteName: "group.com.lifeos.watchkit")
    ) {
        guard let defaults else { return }
        var payload: [String: Any] = [
            "last_updated_at": ISO8601DateFormatter.supabaseString(from: snapshot.lastUpdatedAt)
        ]
        if let date = snapshot.date {
            payload["date"] = date
        }
        if let recoveryScore = snapshot.recoveryScore {
            payload["recovery_score"] = recoveryScore
        }
        if let recoveryZone = snapshot.recoveryZone {
            payload["recovery_zone"] = recoveryZone
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            defaults.set(data, forKey: "latestSnapshot")
        }
    }

    @discardableResult
    func pushLatestSnapshotFromServer(date: String? = nil) async -> Bool {
#if DEBUG
        if let override = Self.testPushLatestSnapshotOverride {
            await override(date)
            return true
        }
#endif
        do {
            let body: Data
            if let date {
                body = try JSONSerialization.data(withJSONObject: ["date": date], options: [])
            } else {
                body = Data("{}".utf8)
            }
            let response: WatchSnapshotResponse = try await apiClient.callEdgeFunction(
                "api-watch-snapshot",
                body: body
            )

            let snapshot = Self.snapshot(from: response)

            push(snapshot: snapshot)
            return true
        } catch {
            logger.error(
                "Watch snapshot server refresh failed for date \(date ?? "latest", privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            // Non-blocking path: callers may fall back to local snapshot data.
            return false
        }
    }

    @discardableResult
    func pushLatestSnapshotWithLocalFallback(
        date: String? = nil,
        syncEngine: SyncEngine? = nil,
        now: Date = Date()
    ) async -> WatchSnapshotRefreshSource {
        if await pushLatestSnapshotFromServer(date: date) {
            return .server
        }

        let resolvedSyncEngine = syncEngine ?? AppContainer.shared?.syncEngine
        guard let resolvedSyncEngine else {
            logger.error(
                "Watch snapshot local fallback unavailable for date \(date ?? "latest", privacy: .public): missing sync engine"
            )
            return .none
        }

        guard let resolvedDate = await pushLatestSnapshotFromLocalStore(
            date: date,
            syncEngine: resolvedSyncEngine,
            now: now
        ) else {
            logger.error(
                "Watch snapshot local fallback failed for date \(date ?? "latest", privacy: .public)"
            )
            return .none
        }

        logger.notice(
            "Watch snapshot refreshed from local store fallback for date \(resolvedDate, privacy: .public)"
        )
        return .local
    }

    func pushLatestSnapshotFromLocalStore(
        date: String? = nil,
        syncEngine: SyncEngine,
        now: Date = Date()
    ) async -> String? {
        do {
            guard let build = try await Self.buildLocalSnapshot(
                syncEngine: syncEngine,
                date: date ?? lastSnapshot?.date,
                now: now
            ) else {
                return nil
            }
            push(snapshot: build.snapshot)
            return build.resolvedDate
        } catch {
            return nil
        }
    }

    private func scheduleBestEffortServerReconciliation(
        syncEngine: SyncEngine,
        preferredDate: String?
    ) {
        Task { [weak self] in
            try? await syncEngine.runSyncLoop()
            await self?.pushLatestSnapshotFromServer(date: preferredDate)
        }
    }

    private static func buildLocalSnapshot(
        syncEngine: SyncEngine,
        date: String?,
        now: Date
    ) async throws -> LocalWatchSnapshotBuild? {
        let authId = AuthManager.activeAuthId?.uuidString

        return try await syncEngine.readLocal { db in
            guard let user = try UserIdentityLookup.fetchUser(authId: authId, db: db) else {
                return nil
            }

            let timeZone = safeTimeZone(user.timezone)
            let resolvedDate = date ?? localDayString(for: now, timeZone: timeZone)
            let today = localDayString(for: now, timeZone: timeZone)
            let isToday = resolvedDate == today

            let physiologicalState = try PhysiologicalState.fetchOne(
                db,
                sql: """
                    SELECT *
                    FROM physiological_states
                    WHERE (user_id = ? OR user_id = ?)
                      AND date = ?
                    LIMIT 1
                    """,
                arguments: [user.id, user.id.uuidString, resolvedDate]
            )

            let foodRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT logged_at, calories, protein_g, needs_review, ai_confidence
                    FROM food_logs
                    WHERE (user_id = ? OR user_id = ?)
                      AND logged_date = ?
                      AND deleted_at IS NULL
                    ORDER BY logged_at ASC
                    """,
                arguments: [user.id, user.id.uuidString, resolvedDate]
            )

            let targetRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT final_calories, final_protein_g
                    FROM daily_nutrition_targets
                    WHERE (user_id = ? OR user_id = ?)
                      AND date = ?
                    LIMIT 1
                """,
                arguments: [user.id, user.id.uuidString, resolvedDate]
            )
            let suppressNutritionTargets = try NutritionSafetyPolicy.suppressesTargets(in: db, userId: user.id)
            let finalCalories: Int? = suppressNutritionTargets ? nil : targetRow?["final_calories"]
            let finalProteinG: Int? = targetRow?["final_protein_g"]

            let supplements = try loadLocalSupplementRows(db: db, userId: user.id)
            let supplementLogs = try loadLocalSupplementLogs(db: db, userId: user.id, date: resolvedDate)
            let supplementSchedule = buildSupplementSchedule(
                date: resolvedDate,
                supplements: supplements,
                logs: supplementLogs
            )

            let unreadInsightRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT id
                    FROM insights
                    WHERE (user_id = ? OR user_id = ?)
                      AND dismissed = 0
                      AND acknowledged = 0
                      AND read = 0
                    ORDER BY created_at DESC
                    LIMIT 1
                    """,
                arguments: [user.id, user.id.uuidString]
            )
            let unreadInsightId = unreadInsightRow.flatMap {
                MixedUUIDStorage.decode(from: $0, column: "id")
            }

            let pendingMedicalScans = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM medical_scans
                    WHERE (user_id = ? OR user_id = ?)
                      AND deleted_at IS NULL
                      AND (
                        needs_review = 1
                        OR status = 'review_required'
                        OR extraction_status IN ('pending', 'processing', 'needs_review', 'review_required')
                      )
                    """,
                arguments: [user.id, user.id.uuidString]
            ) ?? 0

            var currentCalories = 0.0
            var currentProteinG = 0.0
            var mealNeedsReview = false
            var lastMealAt: Date?

            for row in foodRows {
                let calories: Double = row["calories"] ?? 0
                let proteinG: Double = row["protein_g"] ?? 0
                currentCalories += calories
                currentProteinG += proteinG
                let needsReview: Bool = row["needs_review"] ?? false
                let aiConfidence: Double = row["ai_confidence"] ?? 1
                mealNeedsReview = mealNeedsReview || needsReview || aiConfidence < 0.65

                if let loggedAt: Date = row["logged_at"] {
                    if let currentLastMeal = lastMealAt {
                        lastMealAt = max(currentLastMeal, loggedAt)
                    } else {
                        lastMealAt = loggedAt
                    }
                }
            }

            let confidenceScore = physiologicalState?.confidenceScore
            let lowConfidence = (confidenceScore ?? 1) < 0.65
            let nextBestAction = nextBestAction(
                date: resolvedDate,
                isToday: isToday,
                timeZone: timeZone,
                now: now,
                needsReview: mealNeedsReview || pendingMedicalScans > 0,
                lowConfidence: lowConfidence,
                supplementSchedule: supplementSchedule,
                nutritionCurrentCalories: currentCalories,
                nutritionTargetCalories: finalCalories,
                lastMealAt: lastMealAt,
                sleepNeedsPermission: physiologicalState?.sleepDurationHours == nil,
                unreadInsightId: unreadInsightId
            )

            let nutritionAdherencePercent = suppressNutritionTargets ? nil : computeNutritionAdherencePercent(
                currentCalories: currentCalories,
                targetCalories: finalCalories,
                currentProteinG: currentProteinG,
                targetProteinG: finalProteinG
            )

            return LocalWatchSnapshotBuild(
                snapshot: WatchSnapshot(
                    date: physiologicalState?.date ?? resolvedDate,
                    lastUpdatedAt: now,
                    recoveryScore: physiologicalState?.recoveryScore,
                    recoveryZone: physiologicalState?.recoveryZone.rawValue,
                    confidenceScore: confidenceScore,
                    nextBestAction: nextBestAction,
                    sleepDurationHours: physiologicalState?.sleepDurationHours,
                    sleepQualityPercent: physiologicalState?.sleepQualityPercent,
                    nutritionAdherencePercent: nutritionAdherencePercent,
                    supplementsDueSoon: isToday
                        ? dueSupplementsSummary(for: supplementSchedule, now: now, timeZone: timeZone)
                        : nil,
                    wasTruncated: false
                ),
                resolvedDate: resolvedDate
            )
        }
    }

    nonisolated private static func loadLocalSupplementRows(
        db: Database,
        userId: UUID
    ) throws -> [LocalWatchSupplementRow] {
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
            let doseUnit: String = row["dose_unit"] ?? "mg"
            let active: Bool = row["active"] ?? false

            return LocalWatchSupplementRow(
                id: id,
                name: name,
                doseAmount: row["dose_amount"],
                doseUnit: doseUnit,
                frequency: frequency,
                scheduledTimes: normalizedScheduledTimes(from: row["scheduled_times"]),
                daysOfWeek: normalizedDaysOfWeek(from: row["days_of_week"]),
                startedAt: startedAt,
                endedAt: row["ended_at"],
                active: active
            )
        }
    }

    nonisolated private static func loadLocalSupplementLogs(
        db: Database,
        userId: UUID,
        date: String
    ) throws -> [LocalWatchSupplementLogRow] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, user_supplement_id, supplement_name, scheduled_time
                FROM supplement_logs
                WHERE (user_id = ? OR user_id = ?)
                  AND taken_date = ?
                  AND deleted_at IS NULL
                ORDER BY taken_at ASC
                """,
            arguments: [userId, userId.uuidString, date]
        )

        return rows.compactMap { row in
            guard let id = MixedUUIDStorage.decode(from: row, column: "id"),
                  let supplementName: String = row["supplement_name"] else {
                return nil
            }

            return LocalWatchSupplementLogRow(
                id: id,
                userSupplementId: MixedUUIDStorage.decode(from: row, column: "user_supplement_id"),
                supplementName: supplementName,
                scheduledTime: row["scheduled_time"]
            )
        }
    }

    nonisolated private static func buildSupplementSchedule(
        date: String,
        supplements: [LocalWatchSupplementRow],
        logs: [LocalWatchSupplementLogRow]
    ) -> [LocalWatchSupplementScheduleEntry] {
        let plannedSupplements = supplements.filter { isSupplementScheduled(on: date, supplement: $0) }
        var slotMap: [String: [(id: UUID, name: String)]] = [:]

        for supplement in plannedSupplements {
            for time in supplement.scheduledTimes {
                slotMap[time, default: []].append((supplement.id, supplement.name))
            }
        }

        var usedLogIds = Set<UUID>()
        return slotMap
            .keys
            .sorted()
            .map { time in
                let supplementsAtTime = slotMap[time] ?? []
                let items = supplementsAtTime.map { entry in
                    let matchingLog = logs.first { log in
                        guard !usedLogIds.contains(log.id) else { return false }
                        guard normalizeDbTime(log.scheduledTime) == time else { return false }
                        let byId = log.userSupplementId == entry.id
                        let byName = normalizeName(log.supplementName) == normalizeName(entry.name)
                        return byId || byName
                    }
                    if let matchingLog {
                        usedLogIds.insert(matchingLog.id)
                    }
                    return LocalWatchSupplementScheduleItem(
                        name: entry.name,
                        taken: matchingLog != nil
                    )
                }
                return LocalWatchSupplementScheduleEntry(time: time, supplements: items)
            }
    }

    nonisolated private static func isSupplementScheduled(
        on date: String,
        supplement: LocalWatchSupplementRow
    ) -> Bool {
        guard supplement.active else { return false }
        guard supplement.startedAt <= date else { return false }
        if let endedAt = supplement.endedAt, endedAt < date {
            return false
        }

        let dayOfWeek = dayOfWeek(for: date)
        if supplement.frequency == "weekly" {
            return !supplement.daysOfWeek.isEmpty && supplement.daysOfWeek.contains(dayOfWeek)
        }

        if !supplement.daysOfWeek.isEmpty && !supplement.daysOfWeek.contains(dayOfWeek) {
            return false
        }

        return supplement.frequency != "as_needed"
    }

    nonisolated private static func nextBestAction(
        date: String,
        isToday: Bool,
        timeZone: TimeZone,
        now: Date,
        needsReview: Bool,
        lowConfidence: Bool,
        supplementSchedule: [LocalWatchSupplementScheduleEntry],
        nutritionCurrentCalories: Double,
        nutritionTargetCalories: Int?,
        lastMealAt: Date?,
        sleepNeedsPermission: Bool,
        unreadInsightId: UUID?
    ) -> WatchSnapshot.NextBestAction {
        if needsReview || lowConfidence {
            return openOnIPhoneAction(deepLink: "lifeos://diary?date=\(date)")
        }

        if let dueSupplement = dueSupplementInWindow(for: supplementSchedule, now: now, timeZone: timeZone) {
            return WatchSnapshot.NextBestAction(
                type: "supplement_taken",
                labelCopyId: "supplements.log_primary",
                payload: .init(
                    deepLink: nil,
                    supplementName: dueSupplement.name,
                    scheduledTime: dueSupplement.time,
                    insightId: nil,
                    date: nil
                )
            )
        }

        let noMealForFourHours = lastMealAt.map { now.timeIntervalSince($0) >= 4 * 60 * 60 } ?? true
        if isToday,
           let nutritionTargetCalories,
           nutritionTargetCalories > 0,
           nutritionCurrentCalories < Double(nutritionTargetCalories),
           noMealForFourHours {
            return openOnIPhoneAction(deepLink: "lifeos://nutrition?date=\(date)")
        }

        if sleepNeedsPermission {
            return openOnIPhoneAction(deepLink: "lifeos://sleep?date=\(date)")
        }

        if let unreadInsightId {
            return WatchSnapshot.NextBestAction(
                type: "insight_acknowledge",
                labelCopyId: "insights.acknowledge",
                payload: .init(
                    deepLink: nil,
                    supplementName: nil,
                    scheduledTime: nil,
                    insightId: unreadInsightId.uuidString,
                    date: nil
                )
            )
        }

        return openOnIPhoneAction(deepLink: "lifeos://diary?date=\(date)")
    }

    nonisolated private static func dueSupplementInWindow(
        for schedule: [LocalWatchSupplementScheduleEntry],
        now: Date,
        timeZone: TimeZone
    ) -> (name: String, time: String)? {
        let nowMinutes = minutesOfDay(for: now, timeZone: timeZone)

        for slot in schedule {
            guard let slotMinutes = wallClockMinutes(from: slot.time) else { continue }
            let delta = slotMinutes - nowMinutes
            guard delta >= 0, delta <= 120 else { continue }

            if let dueSupplement = slot.supplements.first(where: { !$0.taken }) {
                return (dueSupplement.name, slot.time)
            }
        }

        return nil
    }

    nonisolated private static func dueSupplementsSummary(
        for schedule: [LocalWatchSupplementScheduleEntry],
        now: Date,
        timeZone: TimeZone
    ) -> WatchSnapshot.SupplementsDueSoon? {
        let nowMinutes = minutesOfDay(for: now, timeZone: timeZone)

        for slot in schedule {
            guard let slotMinutes = wallClockMinutes(from: slot.time) else { continue }
            let delta = slotMinutes - nowMinutes
            guard delta >= 0, delta <= 120 else { continue }

            let dueCount = slot.supplements.filter { !$0.taken }.count
            if dueCount > 0 {
                return .init(time: slot.time, count: dueCount)
            }
        }

        return nil
    }

    nonisolated private static func computeNutritionAdherencePercent(
        currentCalories: Double,
        targetCalories: Int?,
        currentProteinG: Double,
        targetProteinG: Int?
    ) -> Double? {
        let ratios = [
            boundedCompletionRatio(currentCalories, target: targetCalories.map(Double.init)),
            boundedCompletionRatio(currentProteinG, target: targetProteinG.map(Double.init))
        ].compactMap { $0 }

        guard !ratios.isEmpty else { return nil }
        let average = ratios.reduce(0, +) / Double(ratios.count)
        return Double(Int((average * 100).rounded()))
    }

    nonisolated private static func boundedCompletionRatio(_ current: Double, target: Double?) -> Double? {
        guard let target, target.isFinite, target > 0 else { return nil }
        guard current.isFinite, current > 0 else { return 0 }
        return max(0, min(current / target, 1))
    }

    nonisolated private static func openOnIPhoneAction(deepLink: String) -> WatchSnapshot.NextBestAction {
        WatchSnapshot.NextBestAction(
            type: "open_on_iphone",
            labelCopyId: "global.open_on_iphone",
            payload: .init(
                deepLink: deepLink,
                supplementName: nil,
                scheduledTime: nil,
                insightId: nil,
                date: nil
            )
        )
    }

    nonisolated private static func safeTimeZone(_ identifier: String) -> TimeZone {
        TimeZone(identifier: identifier) ?? TimeZone(secondsFromGMT: 0) ?? .current
    }

    nonisolated private static func localDayString(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    nonisolated private static func normalizedScheduledTimes(from rawValue: String?) -> [String] {
        guard let rawValue,
              let data = rawValue.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }

        return Array(Set(values.compactMap(normalizeDbTime))).sorted()
    }

    nonisolated private static func normalizedDaysOfWeek(from rawValue: String?) -> [Int] {
        guard let rawValue,
              let data = rawValue.data(using: .utf8),
              let values = try? JSONDecoder().decode([Int].self, from: data) else {
            return []
        }

        return values.filter { (0...6).contains($0) }
    }

    nonisolated private static func dayOfWeek(for date: String) -> Int {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"

        guard let parsed = formatter.date(from: date) else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.component(.weekday, from: parsed) - 1
    }

    nonisolated private static func normalizeDbTime(_ value: String?) -> String? {
        guard let value else { return nil }
        return normalizedWallClockTime(from: value)
    }

    nonisolated private static func normalizeName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    nonisolated private static func minutesOfDay(for date: Date, timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    nonisolated private static func wallClockMinutes(from value: String) -> Int? {
        guard let normalized = normalizedWallClockTime(from: value) else { return nil }
        let parts = normalized.split(separator: ":")
        guard parts.count == 2,
              let hours = Int(parts[0]),
              let minutes = Int(parts[1]) else {
            return nil
        }
        return (hours * 60) + minutes
    }

    nonisolated private static func resolveLocalSupplement(
        named name: String,
        scheduledTime: String?,
        on date: String,
        supplements: [LocalWatchSupplementRow]
    ) -> LocalWatchSupplementRow? {
        let normalizedName = normalizeName(name)
        if let scheduledTime {
            if let exactMatch = supplements.first(where: {
                isSupplementScheduled(on: date, supplement: $0) &&
                normalizeName($0.name) == normalizedName &&
                $0.scheduledTimes.contains(scheduledTime)
            }) {
                return exactMatch
            }
        }

        return supplements.first(where: {
            isSupplementScheduled(on: date, supplement: $0) &&
            normalizeName($0.name) == normalizedName
        })
    }

    private func optimisticSnapshotAfterSupplementTaken(
        name: String,
        scheduledTime: String?,
        fallbackDate: String,
        now: Date
    ) -> WatchSnapshot {
        var snapshot = lastSnapshot ?? WatchSnapshot(
            date: fallbackDate,
            lastUpdatedAt: now,
            recoveryScore: nil,
            recoveryZone: nil,
            confidenceScore: nil,
            nextBestAction: nil,
            sleepDurationHours: nil,
            sleepQualityPercent: nil,
            nutritionAdherencePercent: nil,
            supplementsDueSoon: nil,
            wasTruncated: false
        )

        let snapshotDate = snapshot.date ?? fallbackDate
        snapshot.date = snapshotDate
        snapshot.lastUpdatedAt = now

        if let action = snapshot.nextBestAction,
           action.type == "supplement_taken",
           let payload = action.payload,
           Self.normalizeName(payload.supplementName ?? "") == Self.normalizeName(name),
           Self.normalizeDbTime(payload.scheduledTime) == scheduledTime {
            snapshot.nextBestAction = Self.openOnIPhoneAction(
                deepLink: "lifeos://diary?date=\(snapshotDate)"
            )
        }

        if var dueSoon = snapshot.supplementsDueSoon,
           Self.normalizeDbTime(dueSoon.time) == scheduledTime {
            dueSoon.count -= 1
            snapshot.supplementsDueSoon = dueSoon.count > 0 ? dueSoon : nil
        }

        return snapshot
    }

    private func optimisticSnapshotAfterInsightAcknowledged(
        insightId: String,
        fallbackDate: String,
        now: Date
    ) -> WatchSnapshot {
        var snapshot = lastSnapshot ?? WatchSnapshot(
            date: fallbackDate,
            lastUpdatedAt: now,
            recoveryScore: nil,
            recoveryZone: nil,
            confidenceScore: nil,
            nextBestAction: nil,
            sleepDurationHours: nil,
            sleepQualityPercent: nil,
            nutritionAdherencePercent: nil,
            supplementsDueSoon: nil,
            wasTruncated: false
        )

        let snapshotDate = snapshot.date ?? fallbackDate
        snapshot.date = snapshotDate
        snapshot.lastUpdatedAt = now

        if let action = snapshot.nextBestAction,
           action.type == "insight_acknowledge",
           action.payload?.insightId == insightId {
            snapshot.nextBestAction = Self.openOnIPhoneAction(
                deepLink: "lifeos://diary?date=\(snapshotDate)"
            )
        }

        return snapshot
    }

    private func truncateIfNeeded(_ snapshot: WatchSnapshot) -> WatchSnapshot {
        guard encodedSize(snapshot) > maxSnapshotSizeBytes else { return snapshot }

        var reduced = snapshot
        reduced.wasTruncated = true

        // Truncation priority from watch spec (lowest priority dropped first).
        reduced.nutritionAdherencePercent = nil
        if encodedSize(reduced) <= maxSnapshotSizeBytes { return reduced }

        reduced.sleepQualityPercent = nil
        if encodedSize(reduced) <= maxSnapshotSizeBytes { return reduced }

        reduced.supplementsDueSoon = nil
        if encodedSize(reduced) <= maxSnapshotSizeBytes { return reduced }

        reduced.sleepDurationHours = nil
        return reduced
    }

    private func encodedSize(_ snapshot: WatchSnapshot) -> Int {
        do {
            return try encoder.encode(snapshot).count
        } catch {
            return Int.max
        }
    }

    private static func snapshot(from response: WatchSnapshotResponse) -> WatchSnapshot {
        WatchSnapshot(
            date: response.date,
            lastUpdatedAt: response.lastUpdatedAt,
            recoveryScore: response.recoveryScore,
            recoveryZone: response.recoveryZone,
            confidenceScore: response.confidenceScore,
            nextBestAction: response.nextBestAction.map { action in
                .init(
                    type: action.type,
                    labelCopyId: action.labelCopyId,
                    payload: action.payload.map { payload in
                        .init(
                            deepLink: payload.deepLink,
                            supplementName: payload.supplementName,
                            scheduledTime: payload.scheduledTime,
                            insightId: payload.insightId,
                            date: payload.date
                        )
                    }
                )
            },
            sleepDurationHours: response.sleepDurationHours,
            sleepQualityPercent: response.sleepQualityPercent,
            nutritionAdherencePercent: response.nutritionAdherencePercent,
            supplementsDueSoon: response.supplementsDueSoon.map { .init(time: $0.time, count: $0.count) },
            wasTruncated: false
        )
    }
}

extension WatchSyncManager: WCSessionDelegate {
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {}

    // MARK: - Receive Lightweight Actions from Watch (§1.3)

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let action = message["action"] as? String
        let actionId = message["action_id"] as? String
        let supplementName = message["supplement_name"] as? String ?? ""
        let supplementScheduledTime = message["scheduled_time"] as? String ?? ""
        let insightId = message["insight_id"] as? String ?? ""
        let deepLink = message["deep_link"] as? String

        Task { @MainActor in
            await handleIncomingWatchAction(
                action: action,
                actionId: actionId,
                supplementName: supplementName,
                supplementScheduledTime: supplementScheduledTime,
                insightId: insightId,
                deepLink: deepLink
            )
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let action = userInfo["action"] as? String
        let actionId = userInfo["action_id"] as? String
        let supplementName = userInfo["supplement_name"] as? String ?? ""
        let supplementScheduledTime = userInfo["scheduled_time"] as? String ?? ""
        let insightId = userInfo["insight_id"] as? String ?? ""
        let deepLink = userInfo["deep_link"] as? String

        Task { @MainActor in
            await handleIncomingWatchAction(
                action: action,
                actionId: actionId,
                supplementName: supplementName,
                supplementScheduledTime: supplementScheduledTime,
                insightId: insightId,
                deepLink: deepLink
            )
        }
    }

    @MainActor
    private func handleIncomingWatchAction(
        action: String?,
        actionId: String?,
        supplementName: String,
        supplementScheduledTime: String,
        insightId: String,
        deepLink: String?
    ) async {
        guard let action else { return }

        switch action {
        case "supplement_taken":
            await handleSupplementTaken(
                name: supplementName,
                scheduledTime: supplementScheduledTime,
                actionId: actionId
            )

        case "insight_acknowledge":
            await handleInsightAcknowledge(insightId: insightId, actionId: actionId)

        case "open_on_iphone":
            handleOpenOnIPhone(deepLink: Self.resolvedWatchDeepLink(from: deepLink))

        default:
            break
        }
    }

    @MainActor
    private func handleOpenOnIPhone(deepLink: String) {
        Self.enqueuePendingWatchDeepLink(deepLink)
        NotificationCenter.default.post(
            name: .watchDeepLink,
            object: nil,
            userInfo: [
                "deep_link": deepLink,
                "source": watchDeepLinkNotificationSource
            ]
        )
    }

    /// Mark a supplement as taken via outbox (watch → server).
    @MainActor
    private func handleSupplementTaken(name: String, scheduledTime: String, actionId: String?) async {
        guard let syncEngine = AppContainer.shared?.syncEngine else { return }
        let supplementName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !supplementName.isEmpty else { return }
        let normalizedScheduledTime = Self.normalizedWallClockTime(from: scheduledTime)
        let resolvedActionId = Self.normalizedWatchActionId(from: actionId)
        let now = Date()
        let authId = AuthManager.activeAuthId?.uuidString

        do {
            var resolvedDate: String?
            if let resolvedActionId {
                resolvedDate = try await syncEngine.readLocal { db in
                    guard try Self.watchActionEventExists(id: resolvedActionId, db: db) else {
                        return nil
                    }
                    return try String.fetchOne(
                        db,
                        sql: "SELECT taken_date FROM supplement_logs WHERE id = ? OR id = ? LIMIT 1",
                        arguments: [resolvedActionId, resolvedActionId.uuidString]
                    )
                }
            }
            if resolvedDate == nil {
                resolvedDate = try await syncEngine.performOptimisticMutation { db in
                    guard let user = try UserIdentityLookup.fetchUser(authId: authId, db: db) else {
                        throw WatchActionMutationError.missingUser
                    }

                    let timeZone = Self.safeTimeZone(user.timezone)
                    let takenDate = Self.localDayString(for: now, timeZone: timeZone)
                    let supplements = try Self.loadLocalSupplementRows(db: db, userId: user.id)
                    let matchedSupplement = Self.resolveLocalSupplement(
                        named: supplementName,
                        scheduledTime: normalizedScheduledTime,
                        on: takenDate,
                        supplements: supplements
                    )

                    var localLog = SupplementLog(
                        id: resolvedActionId ?? UUID(),
                        userId: user.id,
                        supplementName: matchedSupplement?.name ?? supplementName,
                        takenAt: now,
                        takenDate: takenDate,
                        doseUnit: matchedSupplement?.doseUnit ?? "mg"
                    )
                    localLog.userSupplementId = matchedSupplement?.id
                    localLog.takenTimezone = timeZone.identifier
                    localLog.takenUtcOffsetMinutes = timeZone.secondsFromGMT(for: now) / 60
                    localLog.doseAmount = matchedSupplement?.doseAmount
                    localLog.wasScheduled = normalizedScheduledTime != nil
                    localLog.scheduledTime = normalizedScheduledTime
                    localLog.createdAt = now
                    localLog.updatedAt = now
                    try localLog.insert(db)

                    var body: [String: Any] = [
                        "supplement_name": localLog.supplementName,
                        "taken_at": ISO8601DateFormatter.supabaseString(from: now),
                        "source": "watch"
                    ]
                    if let normalizedScheduledTime {
                        body["scheduled_time"] = normalizedScheduledTime
                    }

                    guard JSONSerialization.isValidJSONObject(body) else {
                        throw WatchActionMutationError.invalidPayload
                    }

                    let event = OutboxEvent(
                        id: localLog.id,
                        httpMethod: .POST,
                        path: "api-supplements-log",
                        bodyJson: try JSONSerialization.data(withJSONObject: body),
                        priority: 80
                    )
                    return (value: takenDate, event: event)
                }
            }
            let finalResolvedDate = resolvedDate ?? Self.localDayString(for: now, timeZone: .current)

            _ = await pushLatestSnapshotFromLocalStore(date: finalResolvedDate, syncEngine: syncEngine, now: now)
            push(
                snapshot: optimisticSnapshotAfterSupplementTaken(
                    name: supplementName,
                    scheduledTime: normalizedScheduledTime,
                    fallbackDate: finalResolvedDate,
                    now: now
                )
            )
            await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
            scheduleBestEffortServerReconciliation(syncEngine: syncEngine, preferredDate: finalResolvedDate)
        } catch {
            let fallbackDate = lastSnapshot?.date
            await pushLatestSnapshotFromServer(date: fallbackDate)
            await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
            scheduleBestEffortServerReconciliation(syncEngine: syncEngine, preferredDate: fallbackDate)
        }
    }

    /// Acknowledge an insight via outbox (watch → server).
    @MainActor
    private func handleInsightAcknowledge(insightId: String, actionId: String?) async {
        guard let syncEngine = AppContainer.shared?.syncEngine else { return }
        let normalizedInsightId = insightId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let insightUUID = UUID(uuidString: normalizedInsightId) else { return }
        let resolvedActionId = Self.normalizedWatchActionId(from: actionId)
        let now = Date()
        let authId = AuthManager.activeAuthId?.uuidString
        let preferredSnapshotDate = lastSnapshot?.date

        do {
            var resolvedDate = preferredSnapshotDate ?? lastSnapshot?.date ?? Self.localDayString(for: now, timeZone: .current)
            if let resolvedActionId {
                let isDuplicateAction = try await syncEngine.readLocal { db in
                    try Self.watchActionEventExists(id: resolvedActionId, db: db)
                }
                if isDuplicateAction {
                    _ = await pushLatestSnapshotFromLocalStore(date: resolvedDate, syncEngine: syncEngine, now: now)
                    push(
                        snapshot: optimisticSnapshotAfterInsightAcknowledged(
                            insightId: normalizedInsightId,
                            fallbackDate: resolvedDate,
                            now: now
                        )
                    )
                    scheduleBestEffortServerReconciliation(syncEngine: syncEngine, preferredDate: resolvedDate)
                    return
                }
            }
            resolvedDate = try await syncEngine.performOptimisticMutation { db in
                guard let user = try UserIdentityLookup.fetchUser(authId: authId, db: db) else {
                    throw WatchActionMutationError.missingUser
                }

                if var localInsight = try Insight.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM insights
                        WHERE (user_id = ? OR user_id = ?)
                          AND (id = ? OR id = ?)
                        LIMIT 1
                        """,
                    arguments: [user.id, user.id.uuidString, insightUUID, insightUUID.uuidString]
                ) {
                    localInsight.acknowledged = true
                    localInsight.acknowledgedAt = now
                    localInsight.updatedAt = now
                    try localInsight.update(db)
                }

                let body: [String: Any] = [
                    "insight_id": normalizedInsightId,
                    "acknowledged_at": ISO8601DateFormatter.supabaseString(from: now),
                    "source": "watch"
                ]
                guard JSONSerialization.isValidJSONObject(body) else {
                    throw WatchActionMutationError.invalidPayload
                }

                let event = OutboxEvent(
                    id: resolvedActionId ?? UUID(),
                    httpMethod: .POST,
                    path: "api-insight-acknowledge",
                    bodyJson: try JSONSerialization.data(withJSONObject: body),
                    priority: 80
                )
                let fallbackDate = preferredSnapshotDate ?? Self.localDayString(
                    for: now,
                    timeZone: Self.safeTimeZone(user.timezone)
                )
                return (value: fallbackDate, event: event)
            }

            _ = await pushLatestSnapshotFromLocalStore(date: resolvedDate, syncEngine: syncEngine, now: now)
            push(
                snapshot: optimisticSnapshotAfterInsightAcknowledged(
                    insightId: normalizedInsightId,
                    fallbackDate: resolvedDate,
                    now: now
                )
            )
            scheduleBestEffortServerReconciliation(syncEngine: syncEngine, preferredDate: resolvedDate)
        } catch {
            let fallbackDate = lastSnapshot?.date
            await pushLatestSnapshotFromServer(date: fallbackDate)
            scheduleBestEffortServerReconciliation(syncEngine: syncEngine, preferredDate: fallbackDate)
        }
    }

    nonisolated private static func normalizedWallClockTime(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let components = trimmed.split(separator: ":")
        guard components.count == 2 || components.count == 3,
              let hours = Int(components[0]),
              let minutes = Int(components[1]),
              (0...23).contains(hours),
              (0...59).contains(minutes) else {
            return nil
        }

        if components.count == 3 {
            guard let seconds = Int(components[2]), (0...59).contains(seconds) else {
                return nil
            }
        }

        return String(format: "%02d:%02d", hours, minutes)
    }

    nonisolated private static func normalizedWatchActionId(from value: String?) -> UUID? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return UUID(uuidString: trimmed)
    }

    nonisolated private static func watchActionEventExists(id: UUID, db: Database) throws -> Bool {
        let supplementLogExists = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM supplement_logs WHERE id = ? OR id = ?",
            arguments: [id, id.uuidString]
        ) ?? 0
        if supplementLogExists > 0 {
            return true
        }

        let outboxEventExists = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM outbox_events WHERE id = ? OR id = ?",
            arguments: [id, id.uuidString]
        ) ?? 0
        return outboxEventExists > 0
    }

    nonisolated private static func resolvedWatchDeepLink(from deepLink: String?) -> String {
        let trimmed = deepLink?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }

        return "lifeos://home"
    }

    nonisolated private static func pendingWatchDeepLinks(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: watchPendingOpenOnIPhoneLinksDefaultsKey) ?? []
    }

    nonisolated private static func writePendingWatchDeepLinks(
        _ deepLinks: [String],
        defaults: UserDefaults = .standard
    ) {
        if deepLinks.isEmpty {
            defaults.removeObject(forKey: watchPendingOpenOnIPhoneLinksDefaultsKey)
            return
        }

        defaults.set(deepLinks, forKey: watchPendingOpenOnIPhoneLinksDefaultsKey)
    }

    nonisolated static func enqueuePendingWatchDeepLink(_ deepLink: String, defaults: UserDefaults = .standard) {
        var deepLinks = pendingWatchDeepLinks(defaults: defaults)
        if deepLinks.last != deepLink {
            deepLinks.append(deepLink)
        }
        writePendingWatchDeepLinks(deepLinks, defaults: defaults)
    }

    nonisolated static func removePendingWatchDeepLink(_ deepLink: String, defaults: UserDefaults = .standard) {
        var deepLinks = pendingWatchDeepLinks(defaults: defaults)
        if let index = deepLinks.firstIndex(of: deepLink) {
            deepLinks.remove(at: index)
            writePendingWatchDeepLinks(deepLinks, defaults: defaults)
        }
    }

    nonisolated static func clearPendingWatchDeepLinks(defaults: UserDefaults = .standard) {
        writePendingWatchDeepLinks([], defaults: defaults)
    }

    nonisolated static func consumePendingWatchDeepLinkURL(defaults: UserDefaults = .standard) -> URL? {
        var deepLinks = pendingWatchDeepLinks(defaults: defaults)

        while !deepLinks.isEmpty {
            let next = deepLinks.removeFirst()
            writePendingWatchDeepLinks(deepLinks, defaults: defaults)

            if let url = URL(string: next) {
                return url
            }
        }

        return nil
    }

    nonisolated static func isWatchDeepLinkNotification(_ userInfo: [AnyHashable: Any]?) -> Bool {
        (userInfo?["source"] as? String) == watchDeepLinkNotificationSource
    }
}

#if DEBUG
extension WatchSyncManager {
    static func _testSetPushLatestSnapshotOverride(_ value: ((String?) async -> Void)?) {
        testPushLatestSnapshotOverride = value
    }

    func _testLastPushedSnapshot() -> WatchSnapshot? {
        lastSnapshot
    }

    func _testTruncateIfNeeded(_ snapshot: WatchSnapshot) -> WatchSnapshot {
        truncateIfNeeded(snapshot)
    }

    func _testEncodedSize(_ snapshot: WatchSnapshot) -> Int {
        encodedSize(snapshot)
    }

    func _testWriteComplicationData(snapshot: WatchSnapshot, suiteName: String) {
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.removePersistentDomain(forName: suiteName)
        writeComplicationData(snapshot: snapshot, defaults: defaults)
    }

    static func _testSnapshot(from data: Data) throws -> WatchSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(WatchSnapshotResponse.self, from: data)
        return snapshot(from: response)
    }

    static func _testNormalizedWallClockTime(from value: String) -> String? {
        normalizedWallClockTime(from: value)
    }

    static func _testBuildLocalSnapshot(
        syncEngine: SyncEngine,
        date: String?,
        now: Date
    ) async throws -> WatchSnapshot? {
        try await buildLocalSnapshot(syncEngine: syncEngine, date: date, now: now)?.snapshot
    }

    nonisolated static func _testPendingWatchDeepLinks(defaults: UserDefaults = .standard) -> [String] {
        pendingWatchDeepLinks(defaults: defaults)
    }

    nonisolated static func _testResetPendingWatchDeepLinks(defaults: UserDefaults = .standard) {
        clearPendingWatchDeepLinks(defaults: defaults)
    }
}
#endif

extension Notification.Name {
    static let watchDeepLink = Notification.Name("WatchDeepLink")
}
#endif
