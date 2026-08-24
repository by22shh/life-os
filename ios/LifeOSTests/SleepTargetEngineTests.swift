import XCTest
@testable import LifeOS

final class SleepTargetEngineTests: XCTestCase {

    func testAgeAdjustedTargetsShiftWithAge() {
        let youngDeep = SleepTargetEngine.deepSleepTargetRange(age: 25)
        let olderDeep = SleepTargetEngine.deepSleepTargetRange(age: 65)
        XCTAssertGreaterThan(youngDeep.lowerBound, olderDeep.lowerBound)
        XCTAssertGreaterThan(youngDeep.upperBound, olderDeep.upperBound)
    }

    func testDeepAndRemTargetsMatchSpecBands() {
        XCTAssertEqual(SleepTargetEngine.deepSleepTargetRange(age: 25), 13...20)
        XCTAssertEqual(SleepTargetEngine.deepSleepTargetRange(age: 72), 3...8)

        XCTAssertEqual(SleepTargetEngine.remSleepTargetRange(age: 25), 18...24)
        XCTAssertEqual(SleepTargetEngine.remSleepTargetRange(age: 72), 13...20)
    }

    func testSupportiveCopyAvoidsAlarmLanguage() {
        let message = SleepTargetEngine.supportiveStageFeedback(
            deepPercent: 8,
            remPercent: 12,
            age: 32
        ).lowercased()

        XCTAssertFalse(message.contains("danger"))
        XCTAssertFalse(message.contains("critical"))
        XCTAssertFalse(message.contains("diagnosis"))
    }
}
