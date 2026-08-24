import Foundation
import GRDB
import XCTest
@testable import LifeOS

final class PrivacyRetentionManagerTests: XCTestCase {

    func testRunMaintenancePrunesExpiredAndKeepsFreshRecords() async throws {
        let manager = try DatabaseManager.inMemory()
        let retentionManager = PrivacyRetentionManager(dbQueue: manager.dbQueue)
        let userId = UUID()
        let authId = UUID()
        let now = ISO8601DateFormatter().date(from: "2026-02-24T12:00:00Z")!
        let oldDate = now.addingTimeInterval(-91 * 86_400)
        let recentDate = now.addingTimeInterval(-2 * 86_400)

        let oldFoodId = UUID()
        let recentFoodId = UUID()
        let oldScanId = UUID()
        let pinnedScanId = UUID()
        let oldCacheId = UUID()
        let freshCacheId = UUID()
        let oldNotificationId = UUID()
        let freshNotificationId = UUID()
        let oldAnalyticsId = UUID()
        let freshAnalyticsId = UUID()
        let oldInsightId = UUID()
        let freshInsightId = UUID()
        let oldSucceededOutboxId = UUID()
        let oldPermanentOutboxId = UUID()
        let oldPendingOutboxId = UUID()
        let recentSucceededOutboxId = UUID()

        try await manager.dbQueue.write { db in
            var user = User(id: userId, authId: authId, timezone: "UTC", units: .metric)
            try user.insert(db)

            var oldFood = FoodLog(
                id: oldFoodId,
                userId: userId,
                loggedAt: oldDate,
                loggedDate: "2025-11-25",
                inputMethod: .manual,
                calories: 500,
                proteinG: 25,
                fatG: 20,
                carbsG: 50
            )
            oldFood.imageUrl = "https://example.com/old-food.jpg"
            oldFood.imageUploadedAt = oldDate
            oldFood.createdAt = oldDate
            oldFood.updatedAt = oldDate
            try oldFood.insert(db)

            var recentFood = FoodLog(
                id: recentFoodId,
                userId: userId,
                loggedAt: recentDate,
                loggedDate: "2026-02-22",
                inputMethod: .manual,
                calories: 600,
                proteinG: 30,
                fatG: 25,
                carbsG: 60
            )
            recentFood.imageUrl = "https://example.com/recent-food.jpg"
            recentFood.imageUploadedAt = recentDate
            try recentFood.insert(db)

            var oldScan = MedicalScan(id: oldScanId, userId: userId, scanType: .bloodTest)
            oldScan.createdAt = oldDate
            oldScan.updatedAt = oldDate
            oldScan.imageUrl = "https://example.com/scan.jpg"
            oldScan.originalImageUrl = "https://example.com/scan-original.jpg"
            oldScan.imageUploadedAt = oldDate
            oldScan.aiExtractionRaw = Data("{\"parsed\":true}".utf8)
            oldScan.pinnedByUser = false
            try oldScan.insert(db)

            var pinnedScan = MedicalScan(id: pinnedScanId, userId: userId, scanType: .bloodTest)
            pinnedScan.createdAt = oldDate
            pinnedScan.updatedAt = oldDate
            pinnedScan.imageUrl = "https://example.com/pinned-scan.jpg"
            pinnedScan.originalImageUrl = "https://example.com/pinned-scan-original.jpg"
            pinnedScan.imageUploadedAt = oldDate
            pinnedScan.aiExtractionRaw = Data("{\"parsed\":true}".utf8)
            pinnedScan.pinnedByUser = true
            try pinnedScan.insert(db)

            let oldCache = AICacheEntry(
                id: oldCacheId,
                cacheKey: "cache-old",
                payload: Data("{}".utf8),
                createdAt: oldDate,
                expiresAt: oldDate
            )
            try oldCache.insert(db)

            let freshCache = AICacheEntry(
                id: freshCacheId,
                cacheKey: "cache-fresh",
                payload: Data("{}".utf8),
                createdAt: recentDate,
                expiresAt: now.addingTimeInterval(86_400)
            )
            try freshCache.insert(db)

            try db.execute(
                sql: """
                    INSERT INTO notification_log (id, category, priority, title, delivered_at, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [oldNotificationId.uuidString, "nudge", "medium", "Old notification", oldDate, oldDate]
            )
            try db.execute(
                sql: """
                    INSERT INTO notification_log (id, category, priority, title, delivered_at, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [freshNotificationId.uuidString, "nudge", "medium", "Fresh notification", recentDate, recentDate]
            )

            try db.execute(
                sql: """
                    INSERT INTO analytics_events (id, user_id, event_name, created_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [oldAnalyticsId.uuidString, userId.uuidString, "sync_queue_slo_alert", oldDate]
            )
            try db.execute(
                sql: """
                    INSERT INTO analytics_events (id, user_id, event_name, created_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [freshAnalyticsId.uuidString, userId.uuidString, "sync_queue_slo_alert", recentDate]
            )

            try db.execute(
                sql: """
                    INSERT INTO insights (id, user_id, category, title, body, confidence, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    oldInsightId.uuidString,
                    userId.uuidString,
                    "recovery",
                    "Old insight",
                    "Retain nothing past one year.",
                    0.91,
                    oldDate.addingTimeInterval(-280 * 86_400),
                    oldDate.addingTimeInterval(-280 * 86_400)
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO insights (id, user_id, category, title, body, confidence, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    freshInsightId.uuidString,
                    userId.uuidString,
                    "recovery",
                    "Fresh insight",
                    "Recent data should remain.",
                    0.88,
                    recentDate,
                    recentDate
                ]
            )

            var oldSucceeded = OutboxEvent(
                id: oldSucceededOutboxId,
                httpMethod: .POST,
                path: "api-test",
                bodyJson: Data("{}".utf8)
            )
            oldSucceeded.status = .succeeded
            oldSucceeded.createdAtLocal = oldDate
            oldSucceeded.updatedAtLocal = oldDate
            try oldSucceeded.insert(db)

            var oldPermanent = OutboxEvent(
                id: oldPermanentOutboxId,
                httpMethod: .POST,
                path: "api-test",
                bodyJson: Data("{}".utf8)
            )
            oldPermanent.status = .failedPermanent
            oldPermanent.createdAtLocal = oldDate
            oldPermanent.updatedAtLocal = oldDate
            try oldPermanent.insert(db)

            var oldPending = OutboxEvent(
                id: oldPendingOutboxId,
                httpMethod: .POST,
                path: "api-test",
                bodyJson: Data("{}".utf8)
            )
            oldPending.status = .pending
            oldPending.createdAtLocal = oldDate
            oldPending.updatedAtLocal = oldDate
            try oldPending.insert(db)

            var recentSucceeded = OutboxEvent(
                id: recentSucceededOutboxId,
                httpMethod: .POST,
                path: "api-test",
                bodyJson: Data("{}".utf8)
            )
            recentSucceeded.status = .succeeded
            recentSucceeded.createdAtLocal = recentDate
            recentSucceeded.updatedAtLocal = recentDate
            try recentSucceeded.insert(db)
        }

        try await retentionManager.runMaintenance(now: now)

        try await manager.dbQueue.read { db in
            XCTAssertNil(
                try String.fetchOne(
                    db,
                    sql: "SELECT image_url FROM food_logs WHERE id = ?",
                    arguments: [oldFoodId.uuidString]
                )
            )
            XCTAssertNil(
                try Date.fetchOne(
                    db,
                    sql: "SELECT image_uploaded_at FROM food_logs WHERE id = ?",
                    arguments: [oldFoodId.uuidString]
                )
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT image_url FROM food_logs WHERE id = ?",
                    arguments: [recentFoodId.uuidString]
                ),
                "https://example.com/recent-food.jpg"
            )
            XCTAssertNotNil(
                try Date.fetchOne(
                    db,
                    sql: "SELECT image_uploaded_at FROM food_logs WHERE id = ?",
                    arguments: [recentFoodId.uuidString]
                )
            )

            XCTAssertNil(
                try String.fetchOne(
                    db,
                    sql: "SELECT image_url FROM medical_scans WHERE id = ?",
                    arguments: [oldScanId.uuidString]
                )
            )
            XCTAssertNil(
                try String.fetchOne(
                    db,
                    sql: "SELECT original_image_url FROM medical_scans WHERE id = ?",
                    arguments: [oldScanId.uuidString]
                )
            )
            XCTAssertNil(
                try Date.fetchOne(
                    db,
                    sql: "SELECT image_uploaded_at FROM medical_scans WHERE id = ?",
                    arguments: [oldScanId.uuidString]
                )
            )
            XCTAssertNil(
                try Data.fetchOne(
                    db,
                    sql: "SELECT ai_extraction_raw FROM medical_scans WHERE id = ?",
                    arguments: [oldScanId.uuidString]
                )
            )

            let storedPinnedScanImageURL = try XCTUnwrap(
                String.fetchOne(
                    db,
                    sql: "SELECT image_url FROM medical_scans WHERE id = ?",
                    arguments: [pinnedScanId.uuidString]
                )
            )
            XCTAssertTrue(FieldEncryption.isStorageEncrypted(storedPinnedScanImageURL))

            let pinnedScan = try XCTUnwrap(
                MedicalScan.fetchOne(
                    db,
                    sql: "SELECT * FROM medical_scans WHERE id = ?",
                    arguments: [pinnedScanId.uuidString]
                )
            )
            XCTAssertEqual(pinnedScan.imageUrl, "https://example.com/pinned-scan.jpg")
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM ai_cache WHERE id = ?",
                    arguments: [oldCacheId.uuidString]
                ) ?? 0,
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM ai_cache WHERE id = ?",
                    arguments: [freshCacheId.uuidString]
                ) ?? 0,
                1
            )

            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM notification_log WHERE id = ?",
                    arguments: [oldNotificationId.uuidString]
                ) ?? 0,
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM notification_log WHERE id = ?",
                    arguments: [freshNotificationId.uuidString]
                ) ?? 0,
                1
            )

            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM analytics_events WHERE id = ?",
                    arguments: [oldAnalyticsId.uuidString]
                ) ?? 0,
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM analytics_events WHERE id = ?",
                    arguments: [freshAnalyticsId.uuidString]
                ) ?? 0,
                1
            )

            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM insights WHERE id = ?",
                    arguments: [oldInsightId.uuidString]
                ) ?? 0,
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM insights WHERE id = ?",
                    arguments: [freshInsightId.uuidString]
                ) ?? 0,
                1
            )

            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM outbox_events WHERE id = ?",
                    arguments: [oldSucceededOutboxId.uuidString]
                ) ?? 0,
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM outbox_events WHERE id = ?",
                    arguments: [oldPermanentOutboxId.uuidString]
                ) ?? 0,
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM outbox_events WHERE id = ?",
                    arguments: [oldPendingOutboxId.uuidString]
                ) ?? 0,
                1
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM outbox_events WHERE id = ?",
                    arguments: [recentSucceededOutboxId.uuidString]
                ) ?? 0,
                1
            )
        }
    }
}
