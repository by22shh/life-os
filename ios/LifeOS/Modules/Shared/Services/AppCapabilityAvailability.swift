#if os(iOS)
import Foundation
import HealthKit

enum AppCapabilityAvailability {
    private static let appleSignInEntitlementKey = "com.apple.developer.applesignin"
    private static let healthKitEntitlementKey = "com.apple.developer.healthkit"
    private static let familyControlsEntitlementKey = "com.apple.developer.family-controls"
    private static let applicationGroupsEntitlementKey = "com.apple.security.application-groups"
    private static let apsEnvironmentEntitlementKey = "aps-environment"
    private static let remoteNotificationBackgroundMode = "remote-notification"
    private static let guardianMonitorExtensionPointIdentifier = "com.apple.deviceactivity.monitor-extension"

#if DEBUG
    private static let testAppleSignInOverride = LockedTestOverride<Bool>()
    private static let testHealthKitEntitlementOverride = LockedTestOverride<Bool>()
    private static let testFamilyControlsOverride = LockedTestOverride<Bool>()
    private static let testRemotePushOverride = LockedTestOverride<Bool>()
    private static let testRemotePushEnvironmentOverride = LockedTestOverride<String>()
    private static let testEntitlementsOverride = LockedTestOverride<[String: Any]>()
    private static let testBackgroundModesOverride = LockedTestOverride<[String]>()
    private static let testEmbeddedGuardianExtensionOverride = LockedTestOverride<Bool>()
    private static let testIsSimulatorOverride = LockedTestOverride<Bool>()

    static func _testSetAppleSignInAvailableOverride(_ value: Bool?) {
        testAppleSignInOverride.value = value
    }

    static func _testSetHealthKitEntitlementOverride(_ value: Bool?) {
        testHealthKitEntitlementOverride.value = value
    }

    static func _testSetFamilyControlsAvailableOverride(_ value: Bool?) {
        testFamilyControlsOverride.value = value
    }

    static func _testSetRemotePushAvailableOverride(_ value: Bool?) {
        testRemotePushOverride.value = value
    }

    static func _testSetRemotePushEnvironmentOverride(_ value: String?) {
        testRemotePushEnvironmentOverride.value = value
    }

    static func _testSetEntitlementsOverride(_ value: [String: Any]?) {
        testEntitlementsOverride.value = value
    }

    static func _testSetBackgroundModesOverride(_ value: [String]?) {
        testBackgroundModesOverride.value = value
    }

    static func _testSetEmbeddedGuardianExtensionOverride(_ value: Bool?) {
        testEmbeddedGuardianExtensionOverride.value = value
    }

    static func _testSetIsSimulatorOverride(_ value: Bool?) {
        testIsSimulatorOverride.value = value
    }

    static func _testResetOverrides() {
        testAppleSignInOverride.value = nil
        testHealthKitEntitlementOverride.value = nil
        testFamilyControlsOverride.value = nil
        testRemotePushOverride.value = nil
        testRemotePushEnvironmentOverride.value = nil
        testEntitlementsOverride.value = nil
        testBackgroundModesOverride.value = nil
        testEmbeddedGuardianExtensionOverride.value = nil
        testIsSimulatorOverride.value = nil
    }
#endif

    static var isAppleSignInAvailable: Bool {
#if DEBUG
        if let override = testAppleSignInOverride.value {
            return override
        }
#endif
        return !entitlementStrings(appleSignInEntitlementKey).isEmpty
    }

    static var appleSignInUnavailableMessage: String {
        String(localized: "auth_apple_sign_in_unavailable_build")
    }

    static var isHealthKitEntitled: Bool {
#if DEBUG
        if let override = testHealthKitEntitlementOverride.value {
            return override
        }
#endif
        return entitlementBool(healthKitEntitlementKey)
    }

    static var isHealthKitAvailable: Bool {
        isHealthKitEntitled && HKHealthStore.isHealthDataAvailable()
    }

    static var healthKitSummaryText: String {
        if !isHealthKitEntitled {
            return String(localized: "settings_apple_health_status_capability_unavailable")
        }
        return String(localized: "settings_apple_health_status_not_available")
    }

    static var healthKitCapabilityWarning: String? {
        guard !isHealthKitEntitled else { return nil }
        return String(localized: "settings_apple_health_status_capability_unavailable")
    }

    static var isFamilyControlsAvailable: Bool {
#if DEBUG
        if let override = testFamilyControlsOverride.value {
            return override
        }
#endif
        guard supportsFamilyControlsPlatform else { return false }
        guard entitlementBool(familyControlsEntitlementKey) else { return false }
        guard entitlementStrings(applicationGroupsEntitlementKey)
            .contains(GuardianMonitorIdentifiers.appGroupSuiteName) else {
            return false
        }
        return isGuardianMonitorExtensionEmbedded
    }

    static var familyControlsUnavailableMessage: String {
        String(localized: "settings_notifications_guardian_capability_unavailable")
    }

    static var remotePushEnvironment: String? {
#if DEBUG
        if let override = testRemotePushEnvironmentOverride.value {
            return validatedRemotePushEnvironment(override)
        }
        if let availableOverride = testRemotePushOverride.value, !availableOverride {
            return nil
        }
        if let availableOverride = testRemotePushOverride.value, availableOverride {
            return "development"
        }
#endif
        guard !isSimulator else {
            return nil
        }
        guard backgroundModes.contains(remoteNotificationBackgroundMode) else {
            return nil
        }
        return validatedRemotePushEnvironment(entitlementString(apsEnvironmentEntitlementKey))
    }

    static var isRemotePushAvailable: Bool {
#if DEBUG
        if let override = testRemotePushOverride.value {
            return override
        }
#endif
        return remotePushEnvironment != nil
    }

    static var remotePushUnavailableMessage: String {
        String(localized: "settings_notifications_remote_push_unavailable")
    }

    private static var supportsFamilyControlsPlatform: Bool {
        guard !isSimulator else { return false }
        if #available(iOS 16.0, *) {
            return true
        }
        return false
    }

    private static var isSimulator: Bool {
#if DEBUG
        if let override = testIsSimulatorOverride.value {
            return override
        }
#endif
#if targetEnvironment(simulator)
        return true
#else
        return false
#endif
    }

    private static var backgroundModes: [String] {
#if DEBUG
        if let override = testBackgroundModesOverride.value {
            return override
        }
#endif
        return infoStrings("UIBackgroundModes")
    }

    private static var isGuardianMonitorExtensionEmbedded: Bool {
#if DEBUG
        if let override = testEmbeddedGuardianExtensionOverride.value {
            return override
        }
#endif
        guard let plugInsURL = Bundle.main.builtInPlugInsURL else {
            return false
        }
        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: plugInsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        return candidates.contains { candidate in
            guard candidate.pathExtension == "appex",
                  let bundle = Bundle(url: candidate),
                  let extensionInfo = bundle.infoDictionary?["NSExtension"] as? [String: Any],
                  let extensionPointIdentifier = extensionInfo["NSExtensionPointIdentifier"] as? String else {
                return false
            }
            return extensionPointIdentifier == guardianMonitorExtensionPointIdentifier
        }
    }

    private static func validatedRemotePushEnvironment(_ value: String?) -> String? {
        guard let rawValue = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              rawValue == "development" || rawValue == "production" else {
            return nil
        }
        return rawValue
    }

    private static func entitlementValue(for key: String) -> Any? {
#if DEBUG
        if let override = testEntitlementsOverride.value {
            return override[key]
        }
#endif
        return runtimeEntitlements[key]
    }

    private static func infoValue(for key: String) -> Any? {
        Bundle.main.object(forInfoDictionaryKey: key)
    }

    private static var runtimeEntitlements: [String: Any] {
        loadRuntimeEntitlements()
    }

    private static func loadRuntimeEntitlements() -> [String: Any] {
        if let entitlements = loadSimulatorEntitlements() {
            return entitlements
        }

        if let entitlements = loadEmbeddedProvisioningEntitlements() {
            return entitlements
        }

        // App Store installs omit the provisioning profile. This signed resource
        // is generated from CODE_SIGN_ENTITLEMENTS, never a user preference.
        // It declares build support; each framework still requests actual access.
        if let url = Bundle.main.url(forResource: "RuntimeCapabilities", withExtension: "plist"),
           let capabilities = loadPropertyListDictionary(at: url) {
            return capabilities
        }
        return [:]
    }

    private static func loadSimulatorEntitlements() -> [String: Any]? {
#if targetEnvironment(simulator)
        let bundleURL = Bundle.main.bundleURL
        let configurationURL = bundleURL.deletingLastPathComponent()
        let productsURL = configurationURL.deletingLastPathComponent()
        let buildURL = productsURL.deletingLastPathComponent()

        guard productsURL.lastPathComponent == "Products",
              buildURL.lastPathComponent == "Build" else {
            return nil
        }

        let intermediatesURL = buildURL.appendingPathComponent("Intermediates.noindex")
        let productName = bundleURL.deletingPathExtension().lastPathComponent
        let configurationName = configurationURL.lastPathComponent
        let fileManager = FileManager.default

        guard let projectBuildDirectories = try? fileManager.contentsOfDirectory(
            at: intermediatesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for projectBuildDirectory in projectBuildDirectories where projectBuildDirectory.pathExtension == "build" {
            let targetBuildDirectory = projectBuildDirectory
                .appendingPathComponent(configurationName)
                .appendingPathComponent("\(productName).build")

            for xcentName in ["\(productName).app-Simulated.xcent", "\(productName).app.xcent"] {
                let xcentURL = targetBuildDirectory.appendingPathComponent(xcentName)
                if let entitlements = loadPropertyListDictionary(at: xcentURL) {
                    return entitlements
                }
            }
        }
#endif

        return nil
    }

    private static func loadEmbeddedProvisioningEntitlements() -> [String: Any]? {
        guard let provisionURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let provisionData = try? Data(contentsOf: provisionURL),
              let plistData = extractProvisioningPlist(from: provisionData),
              let plist = try? PropertyListSerialization.propertyList(
                from: plistData,
                options: [],
                format: nil
              ) as? [String: Any] else {
            return nil
        }

        return plist["Entitlements"] as? [String: Any]
    }

    private static func extractProvisioningPlist(from data: Data) -> Data? {
        let startMarker = Data("<plist".utf8)
        let endMarker = Data("</plist>".utf8)

        guard let startRange = data.range(of: startMarker),
              let endRange = data.range(of: endMarker),
              endRange.upperBound <= data.endIndex else {
            return nil
        }

        return data[startRange.lowerBound..<endRange.upperBound]
    }

    private static func loadPropertyListDictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else {
            return nil
        }

        return plist
    }

    private static func entitlementBool(_ key: String) -> Bool {
        if let boolValue = entitlementValue(for: key) as? Bool {
            return boolValue
        }
        if let numberValue = entitlementValue(for: key) as? NSNumber {
            return numberValue.boolValue
        }
        return false
    }

    private static func entitlementString(_ key: String) -> String? {
        if let stringValue = entitlementValue(for: key) as? String,
           !stringValue.isEmpty {
            return stringValue
        }
        if let stringValue = entitlementValue(for: key) as? NSString,
           !stringValue.isEqual(to: "") {
            return stringValue as String
        }
        return nil
    }

    private static func entitlementStrings(_ key: String) -> [String] {
        if let values = entitlementValue(for: key) as? [String] {
            return values
        }
        if let values = entitlementValue(for: key) as? NSArray {
            return values.compactMap { $0 as? String }
        }
        return []
    }

    private static func infoStrings(_ key: String) -> [String] {
        if let values = infoValue(for: key) as? [String] {
            return values
        }
        if let values = infoValue(for: key) as? NSArray {
            return values.compactMap { $0 as? String }
        }
        return []
    }
}
#endif
