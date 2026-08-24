import XCTest
import SwiftUI
@testable import LifeOS

final class BiometricProtectionTests: XCTestCase {

    override func tearDown() async throws {
        await MainActor.run {
            BiometricAuthManager.shared._testResetState()
            BiometricAuthManager._testResetOverrides()
        }
        try await super.tearDown()
    }

    @MainActor
    func testEnableBiometricsPersistsStateAndArmsAppLock() async {
        let manager = BiometricAuthManager.shared
        manager._testResetState()
        BiometricAuthManager.testBiometricAvailableOverride.value = true
        BiometricAuthManager.testDeviceAuthenticationAvailableOverride.value = true
        BiometricAuthManager.testAuthenticateOverride.value = { true }

        let didEnable = await manager.enableBiometrics()

        XCTAssertTrue(didEnable)
        XCTAssertTrue(manager.isBiometricEnabled)
        XCTAssertTrue(manager.hasOfferedBiometric)
        XCTAssertFalse(manager.isLocked)

        manager.lockIfEnabled()
        XCTAssertTrue(manager.isLocked)
    }

    @MainActor
    func testLockIfEnabledDisablesProtectionWhenDeviceAuthenticationIsUnavailable() {
        let manager = BiometricAuthManager.shared
        manager._testResetState()
        manager._testSetBiometricEnabled(true)
        BiometricAuthManager.testDeviceAuthenticationAvailableOverride.value = false

        manager.lockIfEnabled()

        XCTAssertFalse(manager.isBiometricEnabled)
        XCTAssertFalse(manager.isLocked)
    }

    func testRootContentKindShowsBiometricLockForProtectedSessions() {
        XCTAssertEqual(
            RootView._testRootContentKind(for: .authenticated, isBiometricLocked: true),
            "biometricLocked"
        )
        XCTAssertEqual(
            RootView._testRootContentKind(for: .anonymous, isBiometricLocked: true),
            "biometricLocked"
        )
        XCTAssertEqual(
            RootView._testRootContentKind(for: .needsOnboarding, isBiometricLocked: true),
            "needsOnboarding"
        )
    }

    func testSnapshotShieldOnlyShowsForProtectedOffscreenContent() {
        XCTAssertTrue(
            RootView._testShouldShowBiometricSnapshotShield(
                authState: .authenticated,
                scenePhase: .background,
                biometricEnabled: true
            )
        )
        XCTAssertFalse(
            RootView._testShouldShowBiometricSnapshotShield(
                authState: .authenticated,
                scenePhase: .active,
                biometricEnabled: true
            )
        )
        XCTAssertFalse(
            RootView._testShouldShowBiometricSnapshotShield(
                authState: .signedOut,
                scenePhase: .background,
                biometricEnabled: true
            )
        )
    }

    @MainActor
    func testBiometricLockAndSecurityViewsRenderAcrossAvailabilityStates() {
        let manager = BiometricAuthManager.shared
        manager._testResetState()

        BiometricAuthManager.testBiometricAvailableOverride.value = true
        BiometricAuthManager.testDeviceAuthenticationAvailableOverride.value = true
        manager._testSetLocked(true)
        BiometricLockView()._testEvaluateBody()
        SettingsSecurityView()._testEvaluateBody()

        manager._testSetBiometricEnabled(true)
        manager._testSetLocked(false)
        BiometricLockView()._testEvaluateBody()
        SettingsSecurityView()._testEvaluateBody()

        BiometricAuthManager.testBiometricAvailableOverride.value = false
        BiometricLockView()._testEvaluateBody()
        SettingsSecurityView()._testEvaluateBody()
    }
}
