import XCTest
@testable import LifeOS

final class UserHealthFlagsCoverageTests: XCTestCase {
    func testInitializerSetsExpectedDefaultsAndDerivedFlags() {
        let userId = UUID(uuidString: "00000000-0000-4000-8000-0000000000F1")!
        let flags = UserHealthFlags(userId: userId)

        XCTAssertEqual(flags.userId, userId)
        XCTAssertFalse(flags.hasCardiacCondition)
        XCTAssertFalse(flags.hasPacemaker)
        XCTAssertFalse(flags.onBetaBlockers)
        XCTAssertFalse(flags.isPregnant)
        XCTAssertFalse(flags.menstrualTrackingEnabled)
        XCTAssertFalse(flags.hasEatingDisorderHistory)
        XCTAssertFalse(flags.hasChronicFatigue)
        XCTAssertFalse(flags.disableHrv)
        XCTAssertFalse(flags.hideCalories)
        XCTAssertFalse(flags.pregnancyMode)
    }

    func testDerivedFlagsReactToDidSetMutations() {
        var flags = UserHealthFlags(userId: UUID())

        flags.hasCardiacCondition = true
        XCTAssertTrue(flags.disableHrv)

        // Ensures `||` right branch is evaluated when first operand is false.
        flags.hasCardiacCondition = false
        flags.hasPacemaker = true
        XCTAssertTrue(flags.disableHrv)

        flags.hasPacemaker = false
        XCTAssertFalse(flags.disableHrv)

        flags.hasEatingDisorderHistory = true
        XCTAssertTrue(flags.hideCalories)
        flags.hasEatingDisorderHistory = false
        XCTAssertFalse(flags.hideCalories)

        flags.isPregnant = true
        XCTAssertTrue(flags.pregnancyMode)
        flags.isPregnant = false
        XCTAssertFalse(flags.pregnancyMode)

        // Non-didSet field path still refreshes via explicit call.
        flags.hasChronicFatigue = true
        flags.refreshDerivedFlags()
        XCTAssertFalse(flags.disableHrv)
    }
}
