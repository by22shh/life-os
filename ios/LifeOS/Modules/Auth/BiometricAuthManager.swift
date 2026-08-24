// MARK: - Biometric Authentication Manager
// Provides optional app-lock protection for returning users.
//
// Flow:
// 1. Once the user reaches the main app, we can offer an app-lock opt-in.
// 2. When enabled, cold launches and background returns arm a local lock.
// 3. Unlock uses Face ID / Touch ID when available, with device passcode fallback.
// 4. Preferences live in UserDefaults; the actual auth challenge is handled by
//    the LocalAuthentication framework.

import Foundation
import LocalAuthentication
import OSLog

@MainActor
@Observable
final class BiometricAuthManager {
    static let shared = BiometricAuthManager()
    private let logger = Logger(subsystem: "com.lifeos.app", category: "BiometricAuth")
    private let userDefaults: UserDefaults

    // MARK: - State

    /// Whether the app is currently locked behind biometric challenge.
    private(set) var isLocked: Bool = false

    /// Whether app-lock is enabled by the user.
    private(set) var isBiometricEnabled: Bool

    /// The type of biometric available on this device.
    var biometricType: LABiometryType {
        if !isBiometricAvailable {
            return .none
        }
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }

    /// Whether the device supports biometric authentication at all.
    var isBiometricAvailable: Bool {
#if DEBUG
        if let override = Self.testBiometricAvailableOverride.value {
            return override
        }
#endif
        let context = LAContext()
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// Whether the device can authenticate the device owner at all
    /// (biometrics or passcode).
    var isDeviceAuthenticationAvailable: Bool {
#if DEBUG
        if let override = Self.testDeviceAuthenticationAvailableOverride.value {
            return override
        }
#endif
        let context = LAContext()
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Human-readable label for the biometric type ("Face ID", "Touch ID", or "Biometric").
    var biometricLabel: String {
        switch biometricType {
        case .none: return String(localized: "biometric_auth_generic")
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        @unknown default: return String(localized: "biometric_auth_generic")
        }
    }

    // MARK: - Keys

    private static let biometricEnabledKey = "biometric_auth_enabled"
    private static let biometricOfferedKey = "biometric_auth_offered"

    /// Whether we've already offered the user the biometric opt-in prompt.
    private(set) var hasOfferedBiometric: Bool

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.isBiometricEnabled = userDefaults.bool(forKey: Self.biometricEnabledKey)
        self.hasOfferedBiometric = userDefaults.bool(forKey: Self.biometricOfferedKey)
    }

    // MARK: - Lock / Unlock

    /// Records that the user has seen the biometric opt-in.
    func markBiometricOffered() {
        hasOfferedBiometric = true
        userDefaults.set(true, forKey: Self.biometricOfferedKey)
    }

    /// Enables biometric protection after confirming device owner auth.
    @discardableResult
    func enableBiometrics() async -> Bool {
        markBiometricOffered()

        guard isBiometricAvailable else {
            logger.warning("Attempted to enable biometric app lock on a device without biometry")
            return false
        }

        let success = await authenticate()
        if success {
            setBiometricEnabled(true)
        }
        return success
    }

    func disableBiometrics() {
        setBiometricEnabled(false)
    }

    /// Arms the app lock for the next protected session.
    func lockIfEnabled() {
        guard isBiometricEnabled else {
            isLocked = false
            return
        }

        guard isDeviceAuthenticationAvailable else {
            logger.error("Disabling biometric app lock because device authentication is unavailable")
            disableBiometrics()
            return
        }

        isLocked = true
    }

    func unlock() {
        isLocked = false
    }

    /// Presents the system biometric prompt. Returns `true` if authentication succeeded.
    @discardableResult
    func authenticate() async -> Bool {
#if DEBUG
        if let override = Self.testAuthenticateOverride.value {
            let success = await override()
            if success {
                unlock()
                logger.info("Biometric authentication override succeeded")
            }
            return success
        }
#endif
        if isBiometricAvailable {
            let context = LAContext()
            context.localizedCancelTitle = String(localized: "cancel")

            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: String(localized: "biometric_auth_reason")
                )
                if success {
                    unlock()
                    logger.info("Biometric authentication succeeded")
                }
                return success
            } catch {
                logger.warning("Biometric authentication failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        return await authenticateWithPasscode()
    }

    /// Fallback: device passcode authentication.
    private func authenticateWithPasscode() async -> Bool {
        guard isDeviceAuthenticationAvailable else {
            logger.error("Device passcode authentication unavailable")
            return false
        }

        let context = LAContext()
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: String(localized: "biometric_auth_passcode_reason")
            )
            if success {
                unlock()
                logger.info("Device authentication succeeded")
            }
            return success
        } catch {
            logger.error("Device authentication failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Resets biometric preference (used during sign-out / account deletion).
    func reset() {
        userDefaults.removeObject(forKey: Self.biometricEnabledKey)
        userDefaults.removeObject(forKey: Self.biometricOfferedKey)
        isBiometricEnabled = false
        hasOfferedBiometric = false
        isLocked = false
    }

    private func setBiometricEnabled(_ enabled: Bool) {
        isBiometricEnabled = enabled
        if enabled {
            userDefaults.set(true, forKey: Self.biometricEnabledKey)
        } else {
            userDefaults.removeObject(forKey: Self.biometricEnabledKey)
            isLocked = false
        }
    }

#if DEBUG
    static let testBiometricAvailableOverride = LockedTestOverride<Bool>()
    static let testDeviceAuthenticationAvailableOverride = LockedTestOverride<Bool>()
    static let testAuthenticateOverride = LockedTestOverride<@Sendable () async -> Bool>()

    static func _testResetOverrides() {
        testBiometricAvailableOverride.value = nil
        testDeviceAuthenticationAvailableOverride.value = nil
        testAuthenticateOverride.value = nil
    }

    func _testSetBiometricEnabled(_ value: Bool) {
        setBiometricEnabled(value)
    }

    func _testSetHasOfferedBiometric(_ value: Bool) {
        hasOfferedBiometric = value
        if value {
            userDefaults.set(true, forKey: Self.biometricOfferedKey)
        } else {
            userDefaults.removeObject(forKey: Self.biometricOfferedKey)
        }
    }

    func _testSetLocked(_ value: Bool) {
        isLocked = value
    }

    func _testResetState() {
        reset()
    }
#endif
}
