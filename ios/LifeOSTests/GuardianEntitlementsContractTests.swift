import Foundation
import XCTest
@testable import LifeOS

final class GuardianEntitlementsContractTests: XCTestCase {
    func testMainAppEntitlementsDeclareCoreHealthAndAuthenticationCapabilities() throws {
        let entitlements = try Self.loadEntitlements(at: "LifeOS/App/LifeOS.entitlements")

        XCTAssertEqual(
            entitlements["com.apple.developer.healthkit"] as? Bool,
            true,
            "Main app must retain HealthKit entitlement for Apple Health sync."
        )
        XCTAssertEqual(
            Set(entitlements["com.apple.developer.applesignin"] as? [String] ?? []),
            Set(["Default"]),
            "Main app must retain Apple Sign In entitlement for account linking."
        )
        XCTAssertEqual(
            entitlements["com.apple.developer.family-controls"] as? Bool,
            true,
            "Main app must retain Family Controls entitlement for Guardian mode."
        )
        XCTAssertEqual(
            entitlements["aps-environment"] as? String,
            "$(APS_ENVIRONMENT)",
            "Main app entitlements must keep the APNs environment build setting binding."
        )
    }

    func testMainAppInfoPlistRetainsRemoteNotificationBackgroundMode() throws {
        let info = try Self.loadPropertyList(at: "LifeOS/App/Info.plist")
        let backgroundModes = try XCTUnwrap(
            info["UIBackgroundModes"] as? [String],
            "Main app Info.plist must declare UIBackgroundModes."
        )

        XCTAssertTrue(
            backgroundModes.contains("remote-notification"),
            "Main app must retain remote-notification background mode for push delivery."
        )
    }

    func testGuardianExtensionEntitlementsIncludeExpectedCapabilities() throws {
        let entitlements = try Self.loadEntitlements(
            at: "GuardianMonitorExtension/GuardianMonitorExtension.entitlements"
        )

        XCTAssertEqual(
            entitlements["com.apple.developer.family-controls"] as? Bool,
            true,
            "Guardian monitor extension must retain Family Controls authorization."
        )

        let groups = try XCTUnwrap(
            entitlements["com.apple.security.application-groups"] as? [String],
            "Guardian monitor extension must declare App Group entitlements."
        )

        XCTAssertEqual(
            Set(groups),
            Set([GuardianMonitorIdentifiers.appGroupSuiteName]),
            "Guardian monitor extension should request only the shared Guardian App Group."
        )
    }

    func testMainAppEntitlementsShareGuardianAppGroupWithExtension() throws {
        let appEntitlements = try Self.loadEntitlements(at: "LifeOS/App/LifeOS.entitlements")
        let extensionEntitlements = try Self.loadEntitlements(
            at: "GuardianMonitorExtension/GuardianMonitorExtension.entitlements"
        )

        let appGroups = try XCTUnwrap(
            appEntitlements["com.apple.security.application-groups"] as? [String],
            "Main app must declare App Group entitlements."
        )
        let extensionGroups = try XCTUnwrap(
            extensionEntitlements["com.apple.security.application-groups"] as? [String],
            "Guardian monitor extension must declare App Group entitlements."
        )

        XCTAssertTrue(
            appGroups.contains(GuardianMonitorIdentifiers.appGroupSuiteName),
            "Main app must include the Guardian App Group to drain screen-time events."
        )
        XCTAssertEqual(
            Set(extensionGroups),
            Set([GuardianMonitorIdentifiers.appGroupSuiteName]),
            "Guardian monitor extension must publish events into the same Guardian App Group."
        )
    }

    private static func loadEntitlements(at relativePath: String) throws -> [String: Any] {
        try loadPropertyList(at: relativePath)
    }

    private static func loadPropertyList(at relativePath: String) throws -> [String: Any] {
        let iosRootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fileURL = iosRootURL.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: fileURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(
            plist as? [String: Any],
            "Expected dictionary property list at \(fileURL.path)"
        )
    }
}

final class AppCapabilityAvailabilityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppCapabilityAvailability._testResetOverrides()
    }

    override func tearDown() {
        AppCapabilityAvailability._testResetOverrides()
        super.tearDown()
    }

    func testAppleSignInAvailabilityRequiresEntitlement() {
        AppCapabilityAvailability._testSetEntitlementsOverride([:])

        XCTAssertFalse(AppCapabilityAvailability.isAppleSignInAvailable)

        AppCapabilityAvailability._testSetEntitlementsOverride([
            "com.apple.developer.applesignin": ["Default"]
        ])

        XCTAssertTrue(AppCapabilityAvailability.isAppleSignInAvailable)
    }

    func testHealthKitEntitlementRequiresRealEntitlement() {
        AppCapabilityAvailability._testSetEntitlementsOverride([:])

        XCTAssertFalse(AppCapabilityAvailability.isHealthKitEntitled)

        AppCapabilityAvailability._testSetEntitlementsOverride([
            "com.apple.developer.healthkit": true
        ])

        XCTAssertTrue(AppCapabilityAvailability.isHealthKitEntitled)
    }

    func testFamilyControlsAvailabilityRequiresFullProvisioningChain() {
        AppCapabilityAvailability._testSetIsSimulatorOverride(false)
        AppCapabilityAvailability._testSetEntitlementsOverride([
            "com.apple.developer.family-controls": true,
            "com.apple.security.application-groups": [GuardianMonitorIdentifiers.appGroupSuiteName]
        ])
        AppCapabilityAvailability._testSetEmbeddedGuardianExtensionOverride(false)

        XCTAssertFalse(AppCapabilityAvailability.isFamilyControlsAvailable)

        AppCapabilityAvailability._testSetEmbeddedGuardianExtensionOverride(true)
        XCTAssertTrue(AppCapabilityAvailability.isFamilyControlsAvailable)

        AppCapabilityAvailability._testSetEntitlementsOverride([
            "com.apple.developer.family-controls": true,
            "com.apple.security.application-groups": ["group.com.lifeos.missing"]
        ])
        XCTAssertFalse(AppCapabilityAvailability.isFamilyControlsAvailable)

        AppCapabilityAvailability._testSetIsSimulatorOverride(true)
        XCTAssertFalse(AppCapabilityAvailability.isFamilyControlsAvailable)
    }

    func testRemotePushEnvironmentRejectsPlaceholderAndMissingBackgroundMode() {
        AppCapabilityAvailability._testSetIsSimulatorOverride(false)
        AppCapabilityAvailability._testSetBackgroundModesOverride(["remote-notification"])
        AppCapabilityAvailability._testSetEntitlementsOverride([
            "aps-environment": "$(APS_ENVIRONMENT)"
        ])

        XCTAssertNil(AppCapabilityAvailability.remotePushEnvironment)
        XCTAssertFalse(AppCapabilityAvailability.isRemotePushAvailable)

        AppCapabilityAvailability._testSetEntitlementsOverride([
            "aps-environment": "production"
        ])
        XCTAssertEqual(AppCapabilityAvailability.remotePushEnvironment, "production")
        XCTAssertTrue(AppCapabilityAvailability.isRemotePushAvailable)

        AppCapabilityAvailability._testSetBackgroundModesOverride([])
        XCTAssertNil(AppCapabilityAvailability.remotePushEnvironment)
        XCTAssertFalse(AppCapabilityAvailability.isRemotePushAvailable)
    }
}
