import XCTest
@testable import LifeOS

final class AccessibilityContractTests: XCTestCase {

    func testTouchTargetsAndListRowsMeetMinimums() {
        XCTAssertGreaterThanOrEqual(LayoutConstants.minTouchTarget, 44)
        XCTAssertGreaterThanOrEqual(LayoutConstants.listRowMinHeight, 56)
    }

    func testRecoveryAnnouncementsContainTextAndPercent() {
        for zone in RecoveryZone.allCases {
            let announcement = zone.accessibilityAnnouncement(score: 78)
            XCTAssertTrue(announcement.contains(zone.label))
            XCTAssertTrue(announcement.contains("78"))
        }
    }

    func testHealthNotificationCategoriesAlwaysAppendClinicianDisclaimer() {
        let disclaimer = String(localized: "clinician_disclaimer")
        let categories: [NotificationCategory] = [.recoveryAlert, .insight, .experiment]

        for category in categories {
            let notification = LifeOSNotification(
                category: category,
                priority: .active,
                title: "t",
                body: "b"
            )
            XCTAssertTrue(notification.body.localizedCaseInsensitiveContains(disclaimer))
        }
    }
}
