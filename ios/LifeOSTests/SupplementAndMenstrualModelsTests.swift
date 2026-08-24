import Foundation
import XCTest
@testable import LifeOS

final class SupplementAndMenstrualModelsTests: XCTestCase {

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
