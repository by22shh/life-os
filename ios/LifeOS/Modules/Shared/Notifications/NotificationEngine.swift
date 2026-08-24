// MARK: - Notification Engine
// Source of truth: life_os_invariants.md §3, §4, §12
// Rules: client enqueues intents only; server is source of truth for quiet-hours,
// dedup, and daily cap enforcement.

import Foundation
import GRDB
import CryptoKit

/// Delays all notification delivery until the user has received their first insight.
enum NotificationDeliveryGate {
    static func isUnlocked(
        authId: String?,
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue
    ) async -> Bool {
        do {
            return try await dbQueue.read { db in
                try isUnlocked(db: db, authId: authId)
            }
        } catch {
            return false
        }
    }

    static func isUnlocked(db: Database, authId: String?) throws -> Bool {
        guard let authId = normalizedAuthId(authId),
              let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
            return false
        }

        let settings = try NotificationSettings.fetchOne(
            db,
            sql: """
                SELECT *
                FROM notification_settings
                WHERE user_id = ? OR user_id = ?
                ORDER BY updated_at DESC
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString]
        ) ?? NotificationSettings(userId: userId)

        guard hasEnabledNotifications(settings.normalizedForInvariants()) else {
            return false
        }

        return try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1
                    FROM insights
                    WHERE user_id = ? OR user_id = ?
                    LIMIT 1
                )
                """,
            arguments: [userId, userId.uuidString]
        ) ?? false
    }

    private static func normalizedAuthId(_ authId: String?) -> String? {
        let trimmed = authId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func hasEnabledNotifications(_ settings: NotificationSettings) -> Bool {
        settings.morningBriefEnabled
            || settings.positiveEnabled
            || settings.nudgesEnabled
            || settings.celebrationEnabled
            || settings.criticalOnly
    }

#if DEBUG
    static func _testIsUnlocked(db: Database, authId: String?) throws -> Bool {
        try isUnlocked(db: db, authId: authId)
    }
#endif
}

/// Manages notification scheduling with invariant guardrails.
actor NotificationEngine {

    private let dbQueue: DatabaseQueue
    private let dispatchLocalNotification: @Sendable (LifeOSNotification, Date) async -> Void

    init(
        dbQueue: DatabaseQueue,
        dispatchLocalNotification: @escaping @Sendable (LifeOSNotification, Date) async -> Void = { notification, scheduledAt in
#if os(iOS)
            guard await NotificationEngine.shouldDispatchLocally() else { return }
            await PushNotificationManager.shared.scheduleLocalNotification(notification, at: scheduledAt)
#else
            _ = (notification, scheduledAt)
#endif
        }
    ) {
        self.dbQueue = dbQueue
        self.dispatchLocalNotification = dispatchLocalNotification
    }

    // MARK: - Public API

    /// Schedules a notification intent.
    /// Returns `true` when queued for APNs dispatch via outbox.
    func scheduleNotification(
        _ notification: LifeOSNotification,
        settings: NotificationSettings,
        scheduledAt: Date = Date()
    ) async throws -> Bool {
        let normalizedSettings = settings.normalizedForInvariants()
        let deliveryMode: NotificationOutboxDeliveryMode = await Self.shouldDispatchLocally()
            ? .localScheduled
            : .remoteOnly

        if normalizedSettings.criticalOnly && !notification.isCriticalHealth {
            return false
        }

        guard isCategoryEnabled(notification.category, settings: normalizedSettings) else {
            return false
        }

        guard let effectiveScheduledAt = resolveScheduledDate(
            notification,
            settings: normalizedSettings,
            requestedAt: scheduledAt
        ) else {
            return false
        }

        let queued: Bool
        do {
            queued = try await dbQueue.write { db in
                let alreadyScheduled = try NotificationLog.fetchOne(db, key: notification.id) != nil

                // P0 #2: Client-side Daily Cap Enforcement
                // P2 #16: Critical health alerts bypass daily cap (spec §3)
                if !alreadyScheduled,
                   !notification.isCriticalHealth,
                   !Self.checkDailyCap(
                        db: db,
                        settings: normalizedSettings,
                        userId: normalizedSettings.userId,
                        scheduledAt: effectiveScheduledAt
                   ) {
                    return false
                }

                // P0 #4: Client-side Dedup (≥ 2h)
                if !alreadyScheduled,
                   !Self.checkDedup(
                    notification,
                    db: db,
                    userId: normalizedSettings.userId,
                    scheduledAt: effectiveScheduledAt
                ) {
                    return false
                }

                try Self.enqueueDispatch(
                    db: db,
                    notification: notification,
                    scheduledAt: effectiveScheduledAt,
                    deliveryMode: deliveryMode
                )

                let log = NotificationLog(
                    id: notification.id,
                    userId: normalizedSettings.userId,
                    category: notification.category,
                    priority: notification.priority,
                    title: notification.title,
                    deliveredAt: effectiveScheduledAt
                )
                try log.save(db)

                return true
            }
        } catch {
            return false
        }

        if queued {
            if deliveryMode == .localScheduled {
                await dispatchLocalNotification(notification, effectiveScheduledAt)
            }
        }

        return queued
    }
    
    // MARK: - Invariant Checks

    private func checkQuietHours(
        _ notification: LifeOSNotification,
        settings: NotificationSettings,
        now: Date
    ) -> Bool {
        resolveScheduledDate(notification, settings: settings, requestedAt: now) != nil
    }

    private static func shouldDispatchLocally() async -> Bool {
#if os(iOS)
        await MainActor.run { !AuthManager.activeHasCloudSession }
#else
        false
#endif
    }

    private static func checkQuietHours(
        _ notification: LifeOSNotification,
        settings: NotificationSettings,
        now: Date
    ) -> Bool {
        resolveScheduledDate(notification, settings: settings, requestedAt: now) != nil
    }

    private func resolveScheduledDate(
        _ notification: LifeOSNotification,
        settings: NotificationSettings,
        requestedAt: Date
    ) -> Date? {
        Self.resolveScheduledDate(notification, settings: settings, requestedAt: requestedAt)
    }

    private static func resolveScheduledDate(
        _ notification: LifeOSNotification,
        settings: NotificationSettings,
        requestedAt: Date
    ) -> Date? {
        NotificationQuietHoursResolver.resolveScheduledDate(
            notification,
            settings: settings,
            requestedAt: requestedAt
        )
    }

    nonisolated private static func checkDailyCap(
        db: Database,
        settings: NotificationSettings,
        userId: UUID,
        scheduledAt: Date
    ) -> Bool {
        // Count today's notifications
        let calendar = Calendar.current
        let startOfScheduledDay = calendar.startOfDay(for: scheduledAt)
        guard let endOfScheduledDay = calendar.date(byAdding: .day, value: 1, to: startOfScheduledDay) else {
            return false
        }
        
        // Using raw SQL for speed/simplicity or GRDB query
        do {
            let count = try NotificationLog
                .filter(NotificationLog.Columns.userId == userId)
                .filter(NotificationLog.Columns.deliveredAt >= startOfScheduledDay)
                .filter(NotificationLog.Columns.deliveredAt < endOfScheduledDay)
                .fetchCount(db)
            
            return count < settings.maxTotalPerDay
        } catch {
            // Fail-closed: deny notifications if cap check fails (invariant §3)
            return false
        }
    }

    nonisolated private static func checkDedup(
        _ notification: LifeOSNotification,
        db: Database,
        userId: UUID,
        scheduledAt: Date
    ) -> Bool {
        // Find last notification of same category
        do {
            guard let lastLog = try NotificationLog
                .filter(NotificationLog.Columns.userId == userId)
                .filter(NotificationLog.Columns.category == notification.category.rawValue)
                .order(NotificationLog.Columns.deliveredAt.desc)
                .fetchOne(db)
            else {
                return true
            }

            // Check if 2 hours passed
            let twoHours: TimeInterval = 2 * 3600
            return scheduledAt.timeIntervalSince(lastLog.deliveredAt) >= twoHours
        } catch {
            // Fail-closed: deny if dedup check fails (invariant §4)
            return false
        }
    }
    
    private static func parseTime(_ timeStr: String) -> (hour: Int, minute: Int)? {
        let trimmed = timeStr.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: ":")
        guard components.count == 2 || components.count == 3,
              let h = Int(components[0]),
              let m = Int(components[1]),
              (0...23).contains(h),
              (0...59).contains(m) else {
            return nil
        }
        if components.count == 3 {
            guard let s = Int(components[2]), (0...59).contains(s) else {
                return nil
            }
        }
        return (h, m)
    }

    // MARK: - Category Rules

    private func isCategoryEnabled(_ category: NotificationCategory, settings: NotificationSettings) -> Bool {
        switch category {
        case .morningBrief:
            return settings.morningBriefEnabled
        case .supplementReminder, .mealReminder:
            return settings.nudgesEnabled
        case .insight, .experiment:
            return settings.positiveEnabled
        case .celebration:
            return settings.celebrationEnabled
        case .recoveryAlert:
            return true
        }
    }

    // MARK: - Edge Dispatch

    nonisolated private static func enqueueDispatch(
        db: Database,
        notification: LifeOSNotification,
        scheduledAt: Date,
        deliveryMode: NotificationOutboxDeliveryMode
    ) throws {
        let payload: [String: Any] = [
            "title": notification.title,
            "body": notification.body,
            "category": notification.category.rawValue,
            "priority": notification.priority.rawValue,
            "interruption_level": notification.priority.interruptionLevelName, // P2 #15
            "deep_link": notification.deepLink ?? "",
            "scheduled_at_local": ISO8601DateFormatter.supabaseString(from: scheduledAt),
            "delivery_mode": deliveryMode.rawValue,
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)

        var event = OutboxEvent(
            id: notification.id,
            httpMethod: .POST,
            path: "send-notification",
            bodyJson: payloadData,
            priority: 20
        )

        let headers: [String: String] = [
            "Content-Type": "application/json",
            "X-Outbox-Replay": "true"
        ]
        event.headersJson = try JSONSerialization.data(withJSONObject: headers)
        try event.save(db)
    }
}

private enum NotificationQuietHoursResolver {
    static func resolveScheduledDate(
        _ notification: LifeOSNotification,
        settings: NotificationSettings,
        requestedAt: Date
    ) -> Date? {
        resolveScheduledDate(
            category: notification.category,
            priority: notification.priority,
            settings: settings,
            requestedAt: requestedAt
        )
    }

    static func resolveScheduledDate(
        category: NotificationCategory,
        priority: NotificationPriority,
        settings: NotificationSettings,
        requestedAt: Date
    ) -> Date? {
        if category == .recoveryAlert && priority == .timeSensitive {
            return requestedAt
        }

        guard let quietStart = parseTime(settings.quietHoursStart),
              let quietEnd = parseTime(settings.quietHoursEnd) else {
            return nil
        }

        guard isInQuietHours(requestedAt, quietStart: quietStart, quietEnd: quietEnd) else {
            return requestedAt
        }

        guard category == .morningBrief else {
            return nil
        }

        return moveToQuietEnd(
            after: requestedAt,
            quietEndHour: quietEnd.hour,
            quietEndMinute: quietEnd.minute
        )
    }

    private static func parseTime(_ timeStr: String) -> (hour: Int, minute: Int)? {
        let trimmed = timeStr.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: ":")
        guard components.count == 2 || components.count == 3,
              let h = Int(components[0]),
              let m = Int(components[1]),
              (0...23).contains(h),
              (0...59).contains(m) else {
            return nil
        }
        if components.count == 3 {
            guard let s = Int(components[2]), (0...59).contains(s) else {
                return nil
            }
        }
        return (h, m)
    }

    private static func isInQuietHours(
        _ date: Date,
        quietStart: (hour: Int, minute: Int),
        quietEnd: (hour: Int, minute: Int)
    ) -> Bool {
        // The settings UI has minute precision and cannot express 24:00.
        // Treat 00:00 -> 23:59 as an intentional all-day quiet-hours window.
        if quietStart.hour == 0,
           quietStart.minute == 0,
           quietEnd.hour == 23,
           quietEnd.minute == 59 {
            return true
        }

        let calendar = Calendar.current
        guard let startDate = calendar.date(
                bySettingHour: quietStart.hour,
                minute: quietStart.minute,
                second: 0,
                of: date
              ),
              let endDate = calendar.date(
                bySettingHour: quietEnd.hour,
                minute: quietEnd.minute,
                second: 0,
                of: date
              ) else {
            return false
        }

        if startDate > endDate {
            return date >= startDate || date < endDate
        }

        return date >= startDate && date < endDate
    }

    private static func moveToQuietEnd(
        after date: Date,
        quietEndHour: Int,
        quietEndMinute: Int
    ) -> Date? {
        let calendar = Calendar.current
        var candidate = calendar.date(byAdding: .minute, value: 1, to: date) ?? date.addingTimeInterval(60)

        for _ in 0..<(48 * 60) {
            let components = calendar.dateComponents([.hour, .minute], from: candidate)
            if components.hour == quietEndHour && components.minute == quietEndMinute {
                var rounded = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: candidate)
                rounded.calendar = calendar
                rounded.timeZone = calendar.timeZone
                rounded.second = 0
                return calendar.date(from: rounded) ?? candidate
            }
            candidate = calendar.date(byAdding: .minute, value: 1, to: candidate) ?? candidate.addingTimeInterval(60)
        }

        return calendar.date(byAdding: .hour, value: 8, to: date)
    }
}

#if DEBUG
extension NotificationEngine {
    static func _testShouldDispatchLocally() async -> Bool {
        await shouldDispatchLocally()
    }

    nonisolated static func _testCheckQuietHours(
        _ notification: LifeOSNotification,
        settings: NotificationSettings,
        now: Date
    ) -> Bool {
        checkQuietHours(notification, settings: settings, now: now)
    }

    nonisolated static func _testResolveScheduledDate(
        _ notification: LifeOSNotification,
        settings: NotificationSettings,
        requestedAt: Date
    ) -> Date? {
        resolveScheduledDate(notification, settings: settings, requestedAt: requestedAt)
    }
}
#endif

// MARK: - Notification Model

struct LifeOSNotification: Sendable {
    let id: UUID
    let category: NotificationCategory
    let priority: NotificationPriority
    let title: String
    let body: String
    let subtitle: String?
    let deepLink: String?

    init(
        id: UUID = UUID(),
        category: NotificationCategory,
        priority: NotificationPriority = .active,
        title: String,
        body: String,
        subtitle: String? = nil,
        deepLink: String? = nil
    ) {
        self.id = id
        self.category = category
        self.priority = priority
        self.title = title
        self.subtitle = subtitle
        self.deepLink = deepLink

        let disclaimer = String(localized: "clinician_disclaimer")
        if category.requiresClinicianCaveat && !body.localizedCaseInsensitiveContains(disclaimer) {
            self.body = "\(body) \(disclaimer)"
        } else {
            self.body = body
        }
    }

    var isCriticalHealth: Bool {
        category == .recoveryAlert && priority == .timeSensitive
    }
}

enum NotificationCategory: String, Codable, Sendable, DatabaseValueConvertible {
    case morningBrief = "MORNING_BRIEF"
    case supplementReminder = "SUPPLEMENT_REMINDER"
    case mealReminder = "MEAL_REMINDER"
    case recoveryAlert = "RECOVERY_ALERT"
    case insight = "INSIGHT"
    case celebration = "CELEBRATION"
    case experiment = "EXPERIMENT"

    fileprivate var requiresClinicianCaveat: Bool {
        switch self {
        case .recoveryAlert, .insight, .experiment, .morningBrief:
            return true
        case .supplementReminder, .mealReminder, .celebration:
            return false
        }
    }
}

enum NotificationPriority: String, Codable, Sendable, DatabaseValueConvertible {
    case passive
    case active
    case timeSensitive = "time_sensitive"

    var rank: Int {
        switch self {
        case .passive: return 1
        case .active: return 2
        case .timeSensitive: return 3
        }
    }

    /// Maps to UNNotificationInterruptionLevel name for the outbox payload (P2 #15).
    var interruptionLevelName: String {
        switch self {
        case .passive: return "passive"
        case .active: return "active"
        case .timeSensitive: return "time-sensitive"
        }
    }
}

enum NotificationOutboxDeliveryMode: String, Codable, Sendable {
    case remoteOnly = "remote_only"
    case localScheduled = "local_scheduled"
}

actor NotificationScheduleCoordinator {
    private struct ScheduledIntent: Sendable {
        let notification: LifeOSNotification
        let scheduledAt: Date
    }

    private struct ScheduleSnapshot: Sendable {
        let userId: UUID
        let settings: NotificationSettings
        let scheduledIntents: [ScheduledIntent]
    }

    private struct SupplementScheduleRow: Sendable {
        let userSupplementId: UUID
        let name: String
        let frequency: String
        let scheduledTimes: [String]
        let daysOfWeek: [Int]?
        let startedAt: String
        let endedAt: String?
    }

    private struct ScheduledSupplementSlot: Sendable {
        let scheduledAt: Date
        let timeLabel: String
        let supplementNames: [String]
    }

    private let dbQueue: DatabaseQueue
    private let engine: NotificationEngine
    private let nowProvider: @Sendable () -> Date
    private let horizonDays: Int

    init(
        dbQueue: DatabaseQueue,
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        horizonDays: Int = 3
    ) {
        self.dbQueue = dbQueue
        self.engine = NotificationEngine(dbQueue: dbQueue)
        self.nowProvider = nowProvider
        self.horizonDays = max(1, horizonDays)
    }

    func refreshSchedules() async {
        let now = nowProvider()

        do {
            guard let snapshot = try await loadSnapshot(now: now) else {
                let removedIds = try await removeManagedScheduledNotifications(userId: nil, now: now)
                await cancelPendingLocalNotifications(removedIds)
                return
            }

            let removedIds = try await removeManagedScheduledNotifications(
                userId: snapshot.userId,
                now: now
            )
            await cancelPendingLocalNotifications(removedIds)

            for scheduledIntent in snapshot.scheduledIntents.sorted(by: { $0.scheduledAt < $1.scheduledAt }) {
                _ = try await engine.scheduleNotification(
                    scheduledIntent.notification,
                    settings: snapshot.settings,
                    scheduledAt: scheduledIntent.scheduledAt
                )
            }
        } catch {
            return
        }
    }

    private func loadSnapshot(now: Date) async throws -> ScheduleSnapshot? {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        guard await NotificationDeliveryGate.isUnlocked(authId: authId, dbQueue: dbQueue) else {
            return nil
        }
        let horizonDays = self.horizonDays
        return try await dbQueue.read { db in
            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                return nil
            }

            let settings = try NotificationSettings.fetchOne(
                db,
                sql: """
                    SELECT *
                    FROM notification_settings
                    WHERE user_id = ? OR user_id = ?
                    ORDER BY updated_at DESC
                    LIMIT 1
                    """,
                arguments: [userId, userId.uuidString]
            ) ?? NotificationSettings(userId: userId)

            let intents = Self.buildMorningBriefIntents(
                userId: userId,
                settings: settings,
                horizonDays: horizonDays,
                now: now
            ) + (try Self.buildSupplementReminderIntents(
                db: db,
                userId: userId,
                settings: settings,
                horizonDays: horizonDays,
                now: now
            ))

            return ScheduleSnapshot(
                userId: userId,
                settings: settings,
                scheduledIntents: intents
            )
        }
    }

    nonisolated private static func buildMorningBriefIntents(
        userId: UUID,
        settings: NotificationSettings,
        horizonDays: Int,
        now: Date
    ) -> [ScheduledIntent] {
        let normalizedSettings = settings.normalizedForInvariants()
        guard normalizedSettings.morningBriefEnabled else { return [] }
        guard let timeComponents = Self.parseWallClockTime(normalizedSettings.morningBriefTimeLocal) else { return [] }

        var intents: [ScheduledIntent] = []
        for dayOffset in 0..<horizonDays {
            guard let requestedAt = Self.wallClockDate(
                dayOffset: dayOffset,
                hour: timeComponents.hour,
                minute: timeComponents.minute,
                from: now
            ) else {
                continue
            }
            guard let scheduledAt = NotificationQuietHoursResolver.resolveScheduledDate(
                category: .morningBrief,
                priority: .passive,
                settings: normalizedSettings,
                requestedAt: requestedAt
            ) else {
                continue
            }
            guard scheduledAt > now else { continue }

            let scheduleKey = "morning-brief:\(userId.uuidString):\(Self.dayString(for: scheduledAt)):\(normalizedSettings.morningBriefTimeLocal)"
            intents.append(
                ScheduledIntent(
                    notification: LifeOSNotification(
                        id: NotificationScheduleKey.stableUUID(for: scheduleKey),
                        category: .morningBrief,
                        priority: .passive,
                        title: String(localized: "notification_morning_brief_title"),
                        body: String(localized: "notification_morning_brief_body"),
                        deepLink: "lifeos://home"
                    ),
                    scheduledAt: scheduledAt
                )
            )
        }
        return intents
    }

    nonisolated private static func buildSupplementReminderIntents(
        db: Database,
        userId: UUID,
        settings: NotificationSettings,
        horizonDays: Int,
        now: Date
    ) throws -> [ScheduledIntent] {
        guard settings.nudgesEnabled else { return [] }

        let supplementRows = try Row.fetchAll(
            db,
            sql: """
                SELECT
                    user_supplements.id,
                    user_supplements.custom_name,
                    supplement_catalog.name AS catalog_name,
                    user_supplements.frequency,
                    user_supplements.scheduled_times,
                    user_supplements.days_of_week,
                    user_supplements.started_at,
                    user_supplements.ended_at
                FROM user_supplements
                LEFT JOIN supplement_catalog
                  ON supplement_catalog.id = user_supplements.catalog_id
                WHERE (user_supplements.user_id = ? OR user_supplements.user_id = ?)
                  AND user_supplements.active = 1
                """,
            arguments: [userId, userId.uuidString]
        )

        guard !supplementRows.isEmpty else { return [] }

        let supplementSchedules = supplementRows.compactMap(Self.makeSupplementScheduleRow(from:))
        guard !supplementSchedules.isEmpty else { return [] }

        let horizonDates = (0..<horizonDays).compactMap { dayOffset in
            Calendar.current.date(byAdding: .day, value: dayOffset, to: Calendar.current.startOfDay(for: now))
        }
        let horizonDateStrings = horizonDates.map(Self.dayString(for:))

        var takenLookup: Set<String> = []
        if let firstDay = horizonDateStrings.first,
           let lastDay = horizonDateStrings.last {
            let rows = try Row.fetchAll(
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

            for row in rows {
                guard let rawUserSupplementId = MixedUUIDStorage.decode(from: row, column: "user_supplement_id"),
                      let takenDate = row["taken_date"] as String? else {
                    continue
                }
                let scheduledTime = (row["scheduled_time"] as String?) ?? ""
                takenLookup.insert(Self.takenLookupKey(
                    userSupplementId: rawUserSupplementId,
                    date: takenDate,
                    scheduledTime: scheduledTime
                ))
            }
        }

        var groupedSlots: [String: ScheduledSupplementSlot] = [:]
        for supplement in supplementSchedules {
            for dayOffset in 0..<horizonDays {
                guard let dayDate = Calendar.current.date(byAdding: .day, value: dayOffset, to: Calendar.current.startOfDay(for: now)) else {
                    continue
                }
                let dayString = Self.dayString(for: dayDate)

                guard Self.isSupplementActive(supplement, on: dayString) else { continue }
                guard Self.shouldScheduleSupplement(supplement, on: dayDate) else { continue }

                for scheduledTime in supplement.scheduledTimes {
                    guard let timeComponents = Self.parseWallClockTime(scheduledTime),
                          let scheduledAt = Self.wallClockDate(
                            dayOffset: dayOffset,
                            hour: timeComponents.hour,
                            minute: timeComponents.minute,
                            from: now
                          ) else {
                        continue
                    }
                    guard scheduledAt > now else { continue }

                    let lookupKey = Self.takenLookupKey(
                        userSupplementId: supplement.userSupplementId,
                        date: dayString,
                        scheduledTime: scheduledTime
                    )
                    guard !takenLookup.contains(lookupKey) else { continue }

                    let groupKey = "\(dayString)|\(scheduledTime)"
                    let existingNames = groupedSlots[groupKey]?.supplementNames ?? []
                    groupedSlots[groupKey] = ScheduledSupplementSlot(
                        scheduledAt: scheduledAt,
                        timeLabel: scheduledTime,
                        supplementNames: (existingNames + [supplement.name]).sorted()
                    )
                }
            }
        }

        return groupedSlots.values.sorted(by: { $0.scheduledAt < $1.scheduledAt }).map { slot in
            let scheduleKey = "supplement-reminder:\(userId.uuidString):\(Self.dayString(for: slot.scheduledAt)):\(slot.timeLabel)"
            let body: String
            if slot.supplementNames.count == 1, let name = slot.supplementNames.first {
                body = String(
                    format: String(localized: "notification_supplement_body_single_format"),
                    name,
                    slot.timeLabel
                )
            } else {
                body = String(
                    format: String(localized: "notification_supplement_body_multiple_format"),
                    slot.supplementNames.count,
                    slot.timeLabel
                )
            }

            return ScheduledIntent(
                notification: LifeOSNotification(
                    id: NotificationScheduleKey.stableUUID(for: scheduleKey),
                    category: .supplementReminder,
                    priority: .active,
                    title: String(localized: "notification_supplement_title"),
                    body: body,
                    deepLink: "lifeos://supplements/log?date=\(Self.dayString(for: slot.scheduledAt))"
                ),
                scheduledAt: slot.scheduledAt
            )
        }
    }

    private func removeManagedScheduledNotifications(
        userId: UUID?,
        now: Date
    ) async throws -> [UUID] {
        try await dbQueue.write { db in
            let futureLogs = try NotificationLog.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM notification_log
                    WHERE category IN (?, ?)
                      AND delivered_at >= ?
                    """,
                arguments: [
                    NotificationCategory.morningBrief.rawValue,
                    NotificationCategory.supplementReminder.rawValue,
                    now
                ]
            )

            let removedIds = futureLogs.compactMap { log -> UUID? in
                if let userId, log.userId != userId {
                    return nil
                }
                return log.id
            }

            guard !removedIds.isEmpty else { return [] }

            for removedId in removedIds {
                try db.execute(
                    sql: "DELETE FROM notification_log WHERE id = ? OR id = ?",
                    arguments: [removedId, removedId.uuidString]
                )
                try db.execute(
                    sql: "DELETE FROM outbox_events WHERE id = ? OR id = ?",
                    arguments: [removedId, removedId.uuidString]
                )
            }
            return removedIds
        }
    }

    private func cancelPendingLocalNotifications(_ ids: [UUID]) async {
        guard !ids.isEmpty else { return }
#if os(iOS)
        await MainActor.run {
            PushNotificationManager.shared.cancelPendingNotifications(
                identifiers: ids.map(\.uuidString)
            )
        }
#endif
    }

    private static func makeSupplementScheduleRow(from row: Row) -> SupplementScheduleRow? {
        guard let userSupplementId = MixedUUIDStorage.decode(from: row, column: "id") else { return nil }
        let customName: String? = row["custom_name"]
        let catalogName: String? = row["catalog_name"]
        let rawName = customName ?? catalogName ?? ""
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let frequency: String = row["frequency"] ?? SupplementFrequency.daily.rawValue
        let startedAt: String = row["started_at"] ?? dayString(for: Date())
        let endedAt: String? = row["ended_at"]
        let scheduledTimes = Self.decodeJSONStringArray(row["scheduled_times"] as String?) ?? []
        let daysOfWeek = Self.decodeJSONIntArray(row["days_of_week"] as String?)

        return SupplementScheduleRow(
            userSupplementId: userSupplementId,
            name: name,
            frequency: frequency,
            scheduledTimes: scheduledTimes,
            daysOfWeek: daysOfWeek,
            startedAt: startedAt,
            endedAt: endedAt,
        )
    }

    private static func shouldScheduleSupplement(
        _ supplement: SupplementScheduleRow,
        on date: Date
    ) -> Bool {
        switch supplement.frequency {
        case SupplementFrequency.asNeeded.rawValue:
            return false
        case SupplementFrequency.weekly.rawValue:
            let weekday = Calendar.current.component(.weekday, from: date) - 1
            if let daysOfWeek = supplement.daysOfWeek, !daysOfWeek.isEmpty {
                return daysOfWeek.contains(weekday)
            }
            return weekday == (weekdayIndex(for: supplement.startedAt) ?? weekday)
        default:
            return true
        }
    }

    private static func isSupplementActive(
        _ supplement: SupplementScheduleRow,
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

    private static func takenLookupKey(
        userSupplementId: UUID,
        date: String,
        scheduledTime: String
    ) -> String {
        "\(userSupplementId.uuidString)|\(date)|\(scheduledTime)"
    }

    private static func sqlPlaceholders(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private static func parseWallClockTime(_ value: String) -> (hour: Int, minute: Int)? {
        let components = value.split(separator: ":")
        guard components.count >= 2,
              let hour = Int(components[0]),
              let minute = Int(components[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return (hour, minute)
    }

    private static func wallClockDate(
        dayOffset: Int,
        hour: Int,
        minute: Int,
        from referenceDate: Date
    ) -> Date? {
        // Pin timezone explicitly to handle DST transitions correctly.
        // Calendar.current inherits the system timezone but caching a snapshot
        // is safer when computing dates across day boundaries.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let dayDate = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: referenceDate)) else {
            return nil
        }
        return calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: dayDate
        )
    }

    private static func decodeJSONStringArray(_ raw: String?) -> [String]? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    private static func decodeJSONIntArray(_ raw: String?) -> [Int]? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([Int].self, from: data)
    }

    private static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func weekdayIndex(for dayString: String) -> Int? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dayString) else { return nil }
        return Calendar.current.component(.weekday, from: date) - 1
    }
}

#if DEBUG
extension NotificationScheduleCoordinator {
    nonisolated static func _testBuildMorningBriefScheduledDates(
        userId: UUID,
        settings: NotificationSettings,
        horizonDays: Int,
        now: Date
    ) -> [Date] {
        buildMorningBriefIntents(
            userId: userId,
            settings: settings,
            horizonDays: horizonDays,
            now: now
        ).map(\.scheduledAt)
    }
}
#endif

private enum NotificationScheduleKey {
    static func stableUUID(for value: String) -> UUID {
        let digest = SHA256.hash(data: Data(value.utf8))
        let bytes = Array(digest)
        let uuidBytes: [UInt8] = Array(bytes.prefix(16))
        return UUID(uuid: (
            uuidBytes[0],
            uuidBytes[1],
            uuidBytes[2],
            uuidBytes[3],
            uuidBytes[4],
            uuidBytes[5],
            (uuidBytes[6] & 0x0F) | 0x50,
            uuidBytes[7],
            (uuidBytes[8] & 0x3F) | 0x80,
            uuidBytes[9],
            uuidBytes[10],
            uuidBytes[11],
            uuidBytes[12],
            uuidBytes[13],
            uuidBytes[14],
            uuidBytes[15]
        ))
    }
}
