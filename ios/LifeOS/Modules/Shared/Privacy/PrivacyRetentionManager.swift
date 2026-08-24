// MARK: - Privacy Retention Manager
// Enforces storage retention windows from life_os_privacy_architecture.md.

import Foundation
import GRDB

actor PrivacyRetentionManager {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// Categories / priorities considered critical for long-term health audit trail.
    /// These notification logs are retained for 1 year instead of 7 days.
    private static let criticalAuditCategories: Set<String> = [
        NotificationCategory.recoveryAlert.rawValue,
    ]
    private static let criticalAuditPriorities: Set<String> = [
        NotificationPriority.timeSensitive.rawValue,
    ]

    /// Applies retention cleanup:
    /// - food photos: 90 days (DB refs + file system)
    /// - raw medical scan artifacts: 90 days
    /// - AI cache: 7 days
    /// - notification/session logs: 7 days (non-critical), 1 year (critical health alerts)
    /// - analytics events: 90 days
    /// - insights: 1 year
    /// - completed/dead-letter outbox events: 7 days
    func runMaintenance(now: Date = Date()) async throws {
        let foodPhotoCutoff = Calendar.current.date(byAdding: .day, value: -90, to: now)!
        let rawMedicalCutoff = Calendar.current.date(byAdding: .day, value: -90, to: now)!
        let aiCacheCutoff = Calendar.current.date(byAdding: .day, value: -7, to: now)!
        let notificationLogCutoff = Calendar.current.date(byAdding: .day, value: -7, to: now)!
        let criticalNotificationCutoff = Calendar.current.date(byAdding: .year, value: -1, to: now)!
        let analyticsCutoff = Calendar.current.date(byAdding: .day, value: -90, to: now)!
        let insightsCutoff = Calendar.current.date(byAdding: .year, value: -1, to: now)!
        let outboxCutoff = Calendar.current.date(byAdding: .day, value: -7, to: now)!

        try await dbQueue.write { db in
            // 1. Food photo DB references (90 days)
            try db.execute(
                sql: """
                    UPDATE food_logs
                    SET image_url = NULL, image_uploaded_at = NULL
                    WHERE image_uploaded_at IS NOT NULL
                      AND image_uploaded_at < ?
                    """,
                arguments: [foodPhotoCutoff]
            )

            // 2. Medical scan artifacts (90 days, respect pinned)
            try db.execute(
                sql: """
                    UPDATE medical_scans
                    SET image_url = NULL,
                        original_image_url = NULL,
                        image_uploaded_at = NULL,
                        ai_extraction_raw = NULL
                    WHERE created_at < ?
                      AND COALESCE(pinned_by_user, 0) = 0
                    """,
                arguments: [rawMedicalCutoff]
            )

            // 3. AI cache (7 days)
            try db.execute(
                sql: """
                    DELETE FROM ai_cache
                    WHERE expires_at <= ?
                       OR created_at < ?
                    """,
                arguments: [now, aiCacheCutoff]
            )

            // 4. Completed/dead-letter outbox events (7 days)
            try db.execute(
                sql: """
                    DELETE FROM outbox_events
                    WHERE status IN ('succeeded', 'failed_permanent', 'cancelled')
                      AND updated_at_local < ?
                    """,
                arguments: [outboxCutoff]
            )

            // 5a. Non-critical notification logs (7 days)
            try db.execute(
                sql: """
                    DELETE FROM notification_log
                    WHERE COALESCE(created_at, delivered_at) < ?
                      AND category NOT IN (\(Self.criticalAuditCategories.map { "'\($0)'" }.joined(separator: ",")))
                      AND priority NOT IN (\(Self.criticalAuditPriorities.map { "'\($0)'" }.joined(separator: ",")))
                    """,
                arguments: [notificationLogCutoff]
            )

            // 5b. Critical health notification logs (1 year audit retention)
            try db.execute(
                sql: """
                    DELETE FROM notification_log
                    WHERE COALESCE(created_at, delivered_at) < ?
                      AND (
                        category IN (\(Self.criticalAuditCategories.map { "'\($0)'" }.joined(separator: ",")))
                        OR priority IN (\(Self.criticalAuditPriorities.map { "'\($0)'" }.joined(separator: ",")))
                      )
                    """,
                arguments: [criticalNotificationCutoff]
            )

            // 6. Analytics events (90 days)
            try db.execute(
                sql: """
                    DELETE FROM analytics_events
                    WHERE created_at < ?
                    """,
                arguments: [analyticsCutoff]
            )

            // 7. Insights (1 year)
            try db.execute(
                sql: """
                    DELETE FROM insights
                    WHERE created_at < ?
                    """,
                arguments: [insightsCutoff]
            )
        }

        // 8. Coordinate: prune actual image files from disk (matches DB cleanup above)
        await LabsCleanupService.pruneStaleAssets(dbQueue: dbQueue)
        await NutritionCleanupService.pruneOldPhotos()
    }
}
