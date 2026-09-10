import XCTest
@testable import LifeOS
import GRDB

final class NotificationEngineTests: XCTestCase {

    var manager: DatabaseManager!
    var engine: NotificationEngine!
    var settings: NotificationSettings!

    override func setUp() async throws {
        manager = try DatabaseManager.inMemory()
        engine = NotificationEngine(dbQueue: manager.dbQueue, dispatchExperimentNotification: { _, _ in true })
        settings = NotificationSettings(userId: UUID())
        // Keep non-quiet-hour tests deterministic regardless of wall-clock time.
        settings.quietHoursStart = "00:00"
        settings.quietHoursEnd = "00:00"
        await MainActor.run {
            AuthManager._testSetActiveHasCloudSession(false)
        }
    }

    // MARK: - Quiet Hours

    @MainActor
    func testExperimentPhaseAnalysisUsesMeansMetricAndAdherence() {
        let experiment = Experiment(userId: UUID(), title: "Test", variable: "Routine", metric: "stress", durationDays: 21)
        func sample(_ value: Double, _ phase: ExperimentPhase, metric: String = "stress", unit: String? = nil) -> ExperimentMeasurement {
            ExperimentMeasurement(experimentId: experiment.id, userId: experiment.userId, date: "2024-01-01", value: value, unit: unit, measurementPhase: phase, metricName: metric)
        }
        let insufficient = ExperimentDescriptiveAnalysis(experiment: experiment, measurements: [sample(1, .baseline), sample(100, .baseline), sample(100, .intervention), sample(2, .intervention)])
        XCTAssertEqual(insufficient.baselineMean, 50.5)
        XCTAssertEqual(insufficient.interventionMean, 51)
        XCTAssertNil(insufficient.percentChange)
        XCTAssertNil(insufficient.isImprovement)
        var excluded = sample(10000, .baseline)
        excluded.protocolFollowed = false
        let rows = [sample(1, .baseline), sample(2, .baseline), sample(3, .baseline), sample(3, .intervention), sample(4, .intervention), sample(5, .intervention)]
        let analysis = ExperimentDescriptiveAnalysis(experiment: experiment, measurements: rows + [excluded, sample(30000, .washout), sample(10000, .baseline, metric: "other")])
        XCTAssertEqual(analysis.baselineMean, 2)
        XCTAssertEqual(analysis.interventionMean, 4)
        XCTAssertEqual(analysis.baselineCount, 3)
        XCTAssertEqual(analysis.interventionCount, 3)
        XCTAssertEqual(analysis.percentChange, 100)
        XCTAssertEqual(analysis.isImprovement, false, "Increasing stress is not improvement")
        let mixed = ExperimentDescriptiveAnalysis(experiment: experiment, measurements: rows + [sample(1, .baseline, unit: "hours")])
        XCTAssertNil(mixed.baselineMean)
        XCTAssertNil(mixed.percentChange)
        XCTAssertTrue(mixed.summary.contains("Единицы"))
    }

    func testExperimentNotificationReportsPermissionFailureWithoutLeavingPendingIntent() async throws {
        let deniedEngine = NotificationEngine(dbQueue: manager.dbQueue, dispatchExperimentNotification: { _, _ in false })
        let notification = LifeOSNotification(category: .experiment, priority: .active, title: "Log", body: "Value")
        let result = try await deniedEngine.scheduleNotification(notification, settings: settings)
        XCTAssertFalse(result)
        try await manager.dbQueue.read { db in
            XCTAssertEqual(try NotificationLog.fetchCount(db), 0)
            XCTAssertEqual(try OutboxEvent.fetchCount(db), 0)
        }
    }

    func testCloudExperimentReminderUsesLocalDeliveryAndStillRespectsDailyCap() async throws {
        await MainActor.run { AuthManager._testSetActiveHasCloudSession(true) }
        defer { Task { @MainActor in AuthManager._testSetActiveHasCloudSession(false) } }
        let notification = LifeOSNotification(category: .experiment, priority: .active, title: "Log", body: "Value")
        let result = try await engine.scheduleNotification(notification, settings: settings)
        XCTAssertTrue(result)
        try await manager.dbQueue.read { db in
            let event = try XCTUnwrap(OutboxEvent.fetchOne(db, key: notification.id))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: event.bodyJson) as? [String: Any])
            XCTAssertEqual(payload["delivery_mode"] as? String, "local_scheduled")
        }
        settings.maxTotalPerDay = 1
        let blocked = try await engine.scheduleNotification(LifeOSNotification(category: .experiment, priority: .active, title: "Second", body: "Value"), settings: settings)
        XCTAssertFalse(blocked)
    }

    func testExperimentReminderScheduleSkipsLoggedDaysAndCompletedOrAbandonedRuns() async throws {
        let userId = settings.userId
        let now = localDate(year: 2026, month: 3, day: 15, hour: 10, minute: 0)
        try await manager.dbQueue.write { db in
            var user = User(id: userId, authId: UUID(), timezone: "UTC", units: .metric)
            try user.insert(db)
            var experiment = Experiment(userId: userId, title: "Test", variable: "Routine", metric: "stress", durationDays: 3)
            experiment.status = .baseline
            experiment.baselineStartDate = "2026-03-15"
            experiment.baselineEndDate = "2026-03-15"
            experiment.interventionStartDate = "2026-03-16"
            experiment.interventionEndDate = "2026-03-17"
            experiment.reminderTime = "18:00"
            try experiment.insert(db)
            var measurement = ExperimentMeasurement(experimentId: experiment.id, userId: userId, date: "2026-03-15", value: 4, metricName: "stress")
            try measurement.insert(db)
            let configured = NotificationSettings(userId: userId)
            let intents = try NotificationScheduleCoordinator._testBuildExperimentReminders(db: db, userId: userId, settings: configured, now: now)
            XCTAssertEqual(intents.count, 2)
            XCTAssertEqual(intents.map { DiaryDateFormatter.formatDate($0.scheduledAt) }, ["2026-03-16", "2026-03-17"])
            XCTAssertTrue(intents.allSatisfy { $0.notification.deepLink == "lifeos://experiments/\(experiment.id.uuidString)" })
            experiment.status = .abandoned
            try experiment.update(db)
            XCTAssertTrue(try NotificationScheduleCoordinator._testBuildExperimentReminders(db: db, userId: userId, settings: configured, now: now).isEmpty)
            experiment.status = .completed
            try experiment.update(db)
            XCTAssertTrue(try NotificationScheduleCoordinator._testBuildExperimentReminders(db: db, userId: userId, settings: configured, now: now).isEmpty)
        }
    }

    func testExperimentCancellationRemovesSystemRequestAndBothLocalRecords() async throws {
        actor CancelledIDs {
            var ids: [UUID] = []
            func record(_ values: [UUID]) { ids.append(contentsOf: values) }
            func snapshot() -> [UUID] { ids }
        }
        let cancelled = CancelledIDs()
        let now = Date()
        let notification = LifeOSNotification(category: .experiment, priority: .active, title: "Log", body: "Value")
        let queued = try await engine.scheduleNotification(notification, settings: settings, scheduledAt: now.addingTimeInterval(3600))
        XCTAssertTrue(queued)
        let coordinator = NotificationScheduleCoordinator(dbQueue: manager.dbQueue, cancelLocalNotifications: { await cancelled.record($0) })
        let removed = try await coordinator._testRemoveManagedScheduledNotifications(userId: settings.userId, now: now)
        XCTAssertEqual(removed, [notification.id])
        let systemIDs = await cancelled.snapshot()
        XCTAssertEqual(systemIDs, [notification.id])
        try await manager.dbQueue.read { db in
            XCTAssertEqual(try NotificationLog.fetchCount(db), 0)
            XCTAssertEqual(try OutboxEvent.fetchCount(db), 0)
        }
    }

    func testQuietHoursBlocksNormalNotifications() async throws {
        // Quiet hours all day
        settings.quietHoursStart = "00:00"
        settings.quietHoursEnd = "23:59"

        let allowed = try await engine.scheduleNotification(
            LifeOSNotification(
                category: .insight,
                priority: .active,
                title: "insight",
                body: "should be blocked"
            ),
            settings: settings
        )
        
        XCTAssertFalse(allowed, "Normal notification should be blocked during quiet hours")
        
        let outboxCount = try await manager.dbQueue.read { try OutboxEvent.fetchCount($0) }
        XCTAssertEqual(outboxCount, 0)
    }

    func testQuietHoursAllowsCriticalAlerts() async throws {
        // Quiet hours all day
        settings.quietHoursStart = "00:00"
        settings.quietHoursEnd = "23:59"
        settings.criticalOnly = false // Ensure it's not blocked by criticalOnly check

        let allowed = try await engine.scheduleNotification(
            LifeOSNotification(
                category: .recoveryAlert,
                priority: .timeSensitive, // Critical Health
                title: "Warning",
                body: "Critical recovery"
            ),
            settings: settings
        )

        XCTAssertTrue(allowed, "Critical alert should bypass quiet hours")
        
        let outboxCount = try await manager.dbQueue.read { try OutboxEvent.fetchCount($0) }
        XCTAssertEqual(outboxCount, 1)
    }

    func testQuietHoursAcceptsHHMMSSConfiguration() async throws {
        // "00:00:00" -> "00:00:00" means no quiet hours; should allow delivery.
        settings.quietHoursStart = "00:00:00"
        settings.quietHoursEnd = "00:00:00"

        let allowed = try await engine.scheduleNotification(
            LifeOSNotification(
                category: .insight,
                priority: .active,
                title: "insight",
                body: "should be allowed"
            ),
            settings: settings
        )

        XCTAssertTrue(allowed, "HH:mm:ss quiet-hours format should be accepted")

        let outboxCount = try await manager.dbQueue.read { try OutboxEvent.fetchCount($0) }
        XCTAssertEqual(outboxCount, 1)
    }

    func testMorningBriefInQuietHoursResolvesToQuietHoursEnd() {
        settings.quietHoursStart = "22:00"
        settings.quietHoursEnd = "07:00"

        let requestedAt = localDate(year: 2026, month: 3, day: 15, hour: 6, minute: 0)
        let resolved = NotificationEngine._testResolveScheduledDate(
            LifeOSNotification(
                category: .morningBrief,
                priority: .passive,
                title: "Morning Brief",
                body: "Body"
            ),
            settings: settings,
            requestedAt: requestedAt
        )

        XCTAssertEqual(resolved, localDate(year: 2026, month: 3, day: 15, hour: 7, minute: 0))
    }

    func testMorningBriefBuilderKeepsTodayBriefWhenQuietHoursShiftMovesItIntoFuture() {
        settings.quietHoursStart = "22:00"
        settings.quietHoursEnd = "07:00"
        settings.morningBriefTimeLocal = "06:00"

        let now = localDate(year: 2026, month: 3, day: 15, hour: 6, minute: 30)
        let scheduledDates = NotificationScheduleCoordinator._testBuildMorningBriefScheduledDates(
            userId: settings.userId,
            settings: settings,
            horizonDays: 2,
            now: now
        )

        XCTAssertEqual(scheduledDates.first, localDate(year: 2026, month: 3, day: 15, hour: 7, minute: 0))
    }

    func testMorningBriefDuringQuietHoursUsesMovedTimeForQueueAndLocalDispatch() async throws {
        settings.quietHoursStart = "22:00"
        settings.quietHoursEnd = "07:00"

        let capture = LocalDispatchCapture()
        let engine = NotificationEngine(
            dbQueue: manager.dbQueue,
            dispatchLocalNotification: { _, scheduledAt in
                await capture.record(scheduledAt)
            }
        )

        let requestedAt = localDate(year: 2026, month: 3, day: 15, hour: 6, minute: 15)
        let allowed = try await engine.scheduleNotification(
            LifeOSNotification(
                category: .morningBrief,
                priority: .passive,
                title: "Morning Brief",
                body: "Digest"
            ),
            settings: settings,
            scheduledAt: requestedAt
        )

        XCTAssertTrue(allowed)

        let logTime = try await manager.dbQueue.read { db in
            try NotificationLog.fetchOne(db)?.deliveredAt
        }
        let expected = localDate(year: 2026, month: 3, day: 15, hour: 7, minute: 0)
        let outboxScheduledAt = try await manager.dbQueue.read { db -> String? in
            guard let event = try OutboxEvent.fetchOne(db) else { return nil }
            let payload = try JSONSerialization.jsonObject(with: event.bodyJson) as? [String: Any]
            return payload?["scheduled_at_local"] as? String
        }
        let localDispatchTime = await capture.value()
        XCTAssertEqual(logTime, expected)
        XCTAssertEqual(localDispatchTime, expected)
        XCTAssertEqual(outboxScheduledAt, ISO8601DateFormatter.supabaseString(from: expected))
    }

    func testScheduleNotificationMarksLocalScheduledDeliveryModeWhenCloudSessionIsInactive() async throws {
        let allowed = try await engine.scheduleNotification(
            LifeOSNotification(
                category: .insight,
                priority: .active,
                title: "Insight",
                body: "Body"
            ),
            settings: settings
        )

        XCTAssertTrue(allowed)

        let deliveryMode = try await manager.dbQueue.read { db -> String? in
            guard let event = try OutboxEvent.fetchOne(db) else { return nil }
            let payload = try JSONSerialization.jsonObject(with: event.bodyJson) as? [String: Any]
            return payload?["delivery_mode"] as? String
        }
        XCTAssertEqual(deliveryMode, NotificationOutboxDeliveryMode.localScheduled.rawValue)
    }

    func testScheduleNotificationMarksRemoteOnlyDeliveryModeWhenCloudSessionIsActive() async throws {
        await MainActor.run {
            AuthManager._testSetActiveHasCloudSession(true)
        }

        let capture = LocalDispatchCapture()
        let engine = NotificationEngine(
            dbQueue: manager.dbQueue,
            dispatchLocalNotification: { _, scheduledAt in
                await capture.record(scheduledAt)
            }
        )

        let allowed = try await engine.scheduleNotification(
            LifeOSNotification(
                category: .insight,
                priority: .active,
                title: "Insight",
                body: "Body"
            ),
            settings: settings
        )

        XCTAssertTrue(allowed)

        let deliveryMode = try await manager.dbQueue.read { db -> String? in
            guard let event = try OutboxEvent.fetchOne(db) else { return nil }
            let payload = try JSONSerialization.jsonObject(with: event.bodyJson) as? [String: Any]
            return payload?["delivery_mode"] as? String
        }
        XCTAssertEqual(deliveryMode, NotificationOutboxDeliveryMode.remoteOnly.rawValue)
        let localDispatchTime = await capture.value()
        XCTAssertNil(localDispatchTime)
    }

    func testMorningBriefQuietHoursCanMoveToNextDayQuietEnd() {
        settings.quietHoursStart = "22:00"
        settings.quietHoursEnd = "07:00"

        let requestedAt = localDate(year: 2026, month: 3, day: 15, hour: 23, minute: 30)
        let resolved = NotificationEngine._testResolveScheduledDate(
            LifeOSNotification(
                category: .morningBrief,
                priority: .passive,
                title: "Morning Brief",
                body: "Body"
            ),
            settings: settings,
            requestedAt: requestedAt
        )

        XCTAssertEqual(resolved, localDate(year: 2026, month: 3, day: 16, hour: 7, minute: 0))
    }

    // MARK: - Daily Cap

    func testDailyCapEnforcement() async throws {
        settings.maxTotalPerDay = 3
        let initialCategories: [NotificationCategory] = [.insight, .celebration, .mealReminder]
        
        // Schedule 3 allowed
        for (index, category) in initialCategories.enumerated() {
            let allowed = try await engine.scheduleNotification(
                LifeOSNotification(
                    category: category,
                    title: "Note \(index + 1)",
                    body: "Body \(index + 1)"
                ),
                settings: settings
            )
            XCTAssertTrue(allowed, "Notification \(index + 1) should be allowed")
        }
        
        // 4th should be blocked
        let blocked = try await engine.scheduleNotification(
            LifeOSNotification(
                category: .morningBrief,
                title: "Note 4",
                body: "Blocked"
            ),
            settings: settings
        )
        XCTAssertFalse(blocked, "4th notification should be blocked by daily cap")
    }

    // MARK: - Dedup

    func testDedupBlocksRecentDuplicates() async throws {
        // 1. Schedule first
        let first = try await engine.scheduleNotification(
            LifeOSNotification(category: .morningBrief, title: "Brief 1", body: "First"),
            settings: settings
        )
        XCTAssertTrue(first)

        // 2. Schedule immediate duplicate (same category)
        let duplicate = try await engine.scheduleNotification(
            LifeOSNotification(category: .morningBrief, title: "Brief 2", body: "Second"),
            settings: settings
        )
        XCTAssertFalse(duplicate, "Immediate duplicate should be blocked")
        
        // 3. Fake time travel: update deliveredAt to 3 hours ago
        try await manager.dbQueue.write { db in
            try db.execute(sql: "UPDATE notification_log SET delivered_at = ?", arguments: [Date().addingTimeInterval(-3 * 3600)])
        }
        
        // 4. Schedule again -> Should allow
        let allowedNow = try await engine.scheduleNotification(
            LifeOSNotification(category: .morningBrief, title: "Brief 3", body: "Allowed after delay"),
            settings: settings
        )
        XCTAssertTrue(allowedNow, "Notification should be allowed after cooldown")
    }

    // MARK: - Critical Alert Bypass (P2 #16)

    func testTimeSensitiveBypassesDailyCap() async throws {
        settings.maxTotalPerDay = 2
        let initialCategories: [NotificationCategory] = [.insight, .celebration]

        // Fill up the daily cap
        for (index, category) in initialCategories.enumerated() {
            let allowed = try await engine.scheduleNotification(
                LifeOSNotification(
                    category: category,
                    title: "Note \(index + 1)",
                    body: "Body \(index + 1)"
                ),
                settings: settings
            )
            XCTAssertTrue(allowed)
        }

        // Normal notification should be blocked
        let blocked = try await engine.scheduleNotification(
            LifeOSNotification(
                category: .mealReminder,
                title: "Blocked",
                body: "Over cap"
            ),
            settings: settings
        )
        XCTAssertFalse(blocked, "Normal notification should be blocked by daily cap")

        // Critical health alert should bypass the cap
        let critical = try await engine.scheduleNotification(
            LifeOSNotification(
                category: .recoveryAlert,
                priority: .timeSensitive,
                title: "Critical Recovery",
                body: "Your recovery score dropped significantly"
            ),
            settings: settings
        )
        XCTAssertTrue(critical, "Critical health alert should bypass daily cap")
    }

    func testCriticalOnlyAndCategoryDisabledPaths() async throws {
        settings.criticalOnly = true

        let blockedByCriticalOnly = try await engine.scheduleNotification(
            LifeOSNotification(
                category: .insight,
                priority: .active,
                title: "Blocked",
                body: "Non-critical"
            ),
            settings: settings
        )
        XCTAssertFalse(blockedByCriticalOnly)

        settings.criticalOnly = false
        settings.positiveEnabled = false
        let blockedByCategory = try await engine.scheduleNotification(
            LifeOSNotification(
                category: .insight,
                priority: .active,
                title: "Blocked",
                body: "Category off"
            ),
            settings: settings
        )
        XCTAssertFalse(blockedByCategory)
    }

    func testInvalidQuietHoursFailClosedAndOvernightBranch() async throws {
        settings.quietHoursStart = "99:00"
        settings.quietHoursEnd = "00:00"
        let invalidHourBlocked = try await engine.scheduleNotification(
            LifeOSNotification(category: .insight, priority: .active, title: "Bad hour", body: "body"),
            settings: settings
        )
        XCTAssertFalse(invalidHourBlocked)

        settings.quietHoursStart = "12:00:99"
        settings.quietHoursEnd = "00:00"
        let invalidSecondsBlocked = try await engine.scheduleNotification(
            LifeOSNotification(category: .insight, priority: .active, title: "Bad seconds", body: "body"),
            settings: settings
        )
        XCTAssertFalse(invalidSecondsBlocked)

        let now = Date()
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .hour, value: -1, to: now) ?? now
        let end = calendar.date(byAdding: .hour, value: -2, to: now) ?? now
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        settings.quietHoursStart = formatter.string(from: start)
        settings.quietHoursEnd = formatter.string(from: end)

        let overnightBlocked = try await engine.scheduleNotification(
            LifeOSNotification(category: .insight, priority: .active, title: "Overnight", body: "body"),
            settings: settings
        )
        XCTAssertFalse(overnightBlocked)
    }

    func testDailyCapAndDedupFailClosedWhenLogUnavailable() async throws {
        try await manager.dbQueue.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS notification_log")
        }

        let blockedByDailyCapFailure = try await engine.scheduleNotification(
            LifeOSNotification(category: .insight, priority: .active, title: "Fail closed", body: "body"),
            settings: settings
        )
        XCTAssertFalse(blockedByDailyCapFailure)

        let blockedByDedupFailure = try await engine.scheduleNotification(
            LifeOSNotification(
                category: .recoveryAlert,
                priority: .timeSensitive,
                title: "Critical dedup failure",
                body: "body"
            ),
            settings: settings
        )
        XCTAssertFalse(blockedByDedupFailure)
    }

    func testNotificationPriorityRankMapping() {
        XCTAssertEqual(NotificationPriority.passive.rank, 1)
        XCTAssertEqual(NotificationPriority.active.rank, 2)
        XCTAssertEqual(NotificationPriority.timeSensitive.rank, 3)
    }

    func testNotificationPriorityAndDisclaimerMetadataBranches() async throws {
        XCTAssertEqual(NotificationPriority.passive.interruptionLevelName, "passive")
        XCTAssertEqual(NotificationPriority.active.interruptionLevelName, "active")
        XCTAssertEqual(NotificationPriority.timeSensitive.interruptionLevelName, "time-sensitive")

        let disclaimer = String(localized: "clinician_disclaimer")
        let appended = LifeOSNotification(
            category: .insight,
            priority: .active,
            title: "Insight",
            body: "Body without disclaimer"
        )
        XCTAssertTrue(appended.body.contains(disclaimer))

        let originalBody = "Already contains \(disclaimer)"
        let preserved = LifeOSNotification(
            category: .recoveryAlert,
            priority: .timeSensitive,
            title: "Recovery",
            body: originalBody
        )
        XCTAssertEqual(preserved.body, originalBody)

        settings.criticalOnly = false
        settings.quietHoursStart = "00:00"
        settings.quietHoursEnd = "00:00"
        let scheduled = try await engine.scheduleNotification(
            LifeOSNotification(
                category: .experiment,
                priority: .active,
                title: "Experiment",
                body: "Category switch coverage"
            ),
            settings: settings
        )
        XCTAssertTrue(scheduled)
    }

    func testLocalDispatchRunsOnlyWithoutCloudSession() async {
        await MainActor.run {
            AuthManager._testSetActiveHasCloudSession(false)
        }
        let offlineDispatch = await NotificationEngine._testShouldDispatchLocally()
        XCTAssertTrue(offlineDispatch)

        await MainActor.run {
            AuthManager._testSetActiveHasCloudSession(true)
        }
        let cloudDispatch = await NotificationEngine._testShouldDispatchLocally()
        XCTAssertFalse(cloudDispatch)

        await MainActor.run {
            AuthManager._testSetActiveHasCloudSession(false)
        }
    }

    private func localDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }
}

private actor LocalDispatchCapture {
    private var scheduledAt: Date?

    func record(_ date: Date) {
        scheduledAt = date
    }

    func value() -> Date? {
        scheduledAt
    }
}
