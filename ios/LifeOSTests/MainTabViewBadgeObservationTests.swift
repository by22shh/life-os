import Foundation
import XCTest
@testable import LifeOS

final class MainTabViewBadgeObservationTests: XCTestCase {
    @MainActor
    func testDismissedDestinationSheetInvalidatesDiaryRefreshKey() {
        XCTAssertEqual(MainTabView._testNextContentRefreshToken(0), 1)
        XCTAssertEqual(MainTabView._testNextContentRefreshToken(41), 42)

        let initialDiary = DiaryView(
            initialDateString: "2026-02-24",
            externalRefreshToken: 0,
            viewModel: DiaryViewModel()
        )
        let refreshedDiary = DiaryView(
            initialDateString: "2026-02-24",
            externalRefreshToken: 1,
            viewModel: DiaryViewModel()
        )

        let initialKey = initialDiary._testRefreshKey()
        let refreshedKey = refreshedDiary._testRefreshKey()

        XCTAssertEqual(initialKey.day, "2026-02-24")
        XCTAssertEqual(refreshedKey.day, "2026-02-24")
        XCTAssertEqual(initialKey.externalRefreshToken, 0)
        XCTAssertEqual(refreshedKey.externalRefreshToken, 1)
    }

    func testNeedsReviewCountObservationEmitsFreshCountsAfterDatabaseMutations() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let insightId = UUID()
        let foodLogId = UUID()
        let now = Date()

        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (
                        id, auth_id, timezone, units, notification_enabled,
                        onboarding_completed, calibration_days_remaining, deletion_in_progress,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    userId.uuidString,
                    authId.uuidString,
                    "UTC",
                    "metric",
                    true,
                    false,
                    3,
                    false,
                    now,
                    now
                ]
            )

            try db.execute(
                sql: """
                    INSERT INTO insights (
                        id, user_id, category, title, body, confidence, priority,
                        actionable, read, acknowledged, dismissed, needs_review,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    insightId.uuidString,
                    userId.uuidString,
                    "recovery",
                    "Needs review",
                    "Body",
                    0.4,
                    1,
                    false,
                    false,
                    false,
                    false,
                    true,
                    now,
                    now
                ]
            )

            try db.execute(
                sql: """
                    INSERT INTO food_logs (
                        id, user_id, logged_at, logged_date, input_method,
                        calories, protein_g, fat_g, carbs_g, ai_confidence, needs_review,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    foodLogId.uuidString,
                    userId.uuidString,
                    now,
                    "2026-03-17",
                    "photo",
                    420.0,
                    22.0,
                    15.0,
                    48.0,
                    0.51,
                    true,
                    now,
                    now
                ]
            )
        }

        var iterator = MainTabView
            ._testMakeNeedsReviewCountObservation(
                authId: authId.uuidString,
                reader: manager.dbQueue
            )
            .makeAsyncIterator()

        let initialUpdate = try await iterator.next()
        let initial = try XCTUnwrap(initialUpdate)
        XCTAssertEqual(initial, 2)

        try await manager.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE insights SET dismissed = 1, updated_at = ? WHERE id = ?",
                arguments: [Date(), insightId.uuidString]
            )
        }

        let insightReviewUpdate = try await iterator.next()
        let afterInsightReview = try XCTUnwrap(insightReviewUpdate)
        XCTAssertEqual(afterInsightReview, 1)

        try await manager.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE food_logs SET needs_review = 0, updated_at = ? WHERE id = ?",
                arguments: [Date(), foodLogId.uuidString]
            )
        }

        let foodReviewUpdate = try await iterator.next()
        let afterFoodReview = try XCTUnwrap(foodReviewUpdate)
        XCTAssertEqual(afterFoodReview, 0)
    }
}
