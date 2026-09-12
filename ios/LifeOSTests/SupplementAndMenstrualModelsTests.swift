import Foundation
import XCTest
@testable import LifeOS

final class SupplementAndMenstrualModelsTests: XCTestCase {

    @MainActor
    func testSupplementSchedulesRespectFrequencyDateRangeAndWeekdays() {
        XCTAssertTrue(
            SupplementsDayViewTestHarness.scheduleIsDue(
                frequency: "weekly",
                daysOfWeek: [1],
                startedAt: "2026-09-01",
                on: "2026-09-07"
            )
        )
        XCTAssertFalse(
            SupplementsDayViewTestHarness.scheduleIsDue(
                frequency: "weekly",
                daysOfWeek: [1],
                startedAt: "2026-09-01",
                on: "2026-09-08"
            )
        )
        XCTAssertFalse(
            SupplementsDayViewTestHarness.scheduleIsDue(
                frequency: "as_needed",
                startedAt: "2026-09-01",
                on: "2026-09-07"
            )
        )
        XCTAssertFalse(
            SupplementsDayViewTestHarness.scheduleIsDue(
                frequency: "daily",
                startedAt: "2026-09-01",
                endedAt: "2026-09-05",
                on: "2026-09-06"
            )
        )
    }

    func testSupplementModelDefaults() {
        let catalog = SupplementCatalogEntry(name: "Magnesium", category: .mineral)
        XCTAssertEqual(catalog.name, "Magnesium")
        XCTAssertFalse(catalog.takeWithFood)
        XCTAssertEqual(catalog.primaryBenefits, [])

        let userSupplement = UserSupplement(
            userId: UUID(),
            frequency: .twiceDaily,
            doseUnit: "mg"
        )
        XCTAssertEqual(userSupplement.frequency, .twiceDaily)
        XCTAssertEqual(userSupplement.doseUnit, "mg")
        XCTAssertEqual(userSupplement.scheduledTimes, [])
        XCTAssertTrue(userSupplement.active)
        XCTAssertFalse(userSupplement.takeWithFood)

        let log = SupplementLog(
            userId: UUID(),
            supplementName: "Omega-3",
            takenDate: "2026-02-24"
        )
        XCTAssertEqual(log.supplementName, "Omega-3")
        XCTAssertEqual(log.takenDate, "2026-02-24")
        XCTAssertEqual(log.doseUnit, "mg")
        XCTAssertFalse(log.wasScheduled)
    }

    func testMenstrualLogDefaultsAndSyncMetadata() {
        let userId = UUID()
        let log = MenstrualLog(
            userId: userId,
            date: "2026-02-24",
            flow: .medium,
            painLevel: 2
        )
        XCTAssertEqual(log.userId, userId)
        XCTAssertEqual(log.date, "2026-02-24")
        XCTAssertEqual(log.flow, .medium)
        XCTAssertEqual(log.painLevel, 2)
        XCTAssertNil(log.deletedAt)
        XCTAssertEqual(MenstrualLog.databaseTableName, "menstrual_logs")
    }
}
