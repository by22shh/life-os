import XCTest
@testable import LifeOS

@MainActor
final class HapticManagerTests: XCTestCase {
    func testHapticCallsDoNotCrash() {
        HapticManager.lightTap()
        HapticManager.mediumConfirm()
        HapticManager.heavyImpact()
        HapticManager.success()
        HapticManager.warning()
        HapticManager.error()
        HapticManager.selection()
        HapticManager.zoneChange(.critical)
        HapticManager.zoneChange(.caution)
        HapticManager.zoneChange(.ready)
        HapticManager.zoneChange(.optimal)
    }
}
