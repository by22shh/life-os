#if os(iOS)
import Foundation
import UIKit
import UserNotifications

@MainActor
final class PushNotificationManager: NSObject {
    static let shared = PushNotificationManager()

    private let deviceId: String
    private let defaults: UserDefaults
    private let tokenDefaultsKey: String
    private let registrationErrorDefaultsKey: String
    private let registeredPushTokenDefaultsKey: String
    private let notificationAuthorizationStatusProvider: () async -> UNAuthorizationStatus
    private let requestAuthorizationHandler: () async -> Bool
    private let registerForRemoteNotificationsHandler: () -> Void
    private let addNotificationRequestHandler: @MainActor (UNNotificationRequest) async throws -> Void
    private let removePendingNotificationRequestsHandler: ([String]) -> Void
    private let setNotificationCenterDelegateHandler: (UNUserNotificationCenterDelegate?) -> Void
    private let isRunningTestsProvider: () -> Bool
    private let isRemotePushAvailableProvider: () -> Bool
    private let remotePushEnvironmentProvider: () -> String?
    private let isRuntimeConfiguredProvider: () -> Bool
    private let notificationDeliveryUnlockedProvider: () async -> Bool
    private let syncEngineProvider: () -> SyncEngine?
    private let registerDevicePath = "api-notifications-register-device"
    private let unregisterDevicePath = "api-notifications-unregister-device"
    private var isEvaluatingDelayedAuthorizationPrompt = false

    private var isRunningTests: Bool {
        isRunningTestsProvider()
    }

    internal init(
        defaults: UserDefaults = .standard,
        deviceId: String = KeychainHelper.getOrCreateDeviceId(),
        tokenDefaultsKey: String = "lifeos.push.apns_token",
        registrationErrorDefaultsKey: String = "lifeos.push.apns_registration_error",
        registeredPushTokenDefaultsKey: String = "lifeos.push.server_registered_token",
        notificationAuthorizationStatusProvider: (() async -> UNAuthorizationStatus)? = nil,
        requestAuthorizationHandler: (() async -> Bool)? = nil,
        registerForRemoteNotificationsHandler: (() -> Void)? = nil,
        addNotificationRequestHandler: (@MainActor (UNNotificationRequest) async throws -> Void)? = nil,
        removePendingNotificationRequestsHandler: (([String]) -> Void)? = nil,
        setNotificationCenterDelegateHandler: ((UNUserNotificationCenterDelegate?) -> Void)? = nil,
        isRunningTestsProvider: (() -> Bool)? = nil,
        isRemotePushAvailableProvider: (() -> Bool)? = nil,
        remotePushEnvironmentProvider: (() -> String?)? = nil,
        isRuntimeConfiguredProvider: (() -> Bool)? = nil,
        notificationDeliveryUnlockedProvider: (() async -> Bool)? = nil,
        syncEngineProvider: (() -> SyncEngine?)? = nil
    ) {
        let center = UNUserNotificationCenter.current()
        let resolvedRemotePushEnvironmentProvider = remotePushEnvironmentProvider ?? {
            AppCapabilityAvailability.remotePushEnvironment
        }
        self.deviceId = deviceId
        self.defaults = defaults
        self.tokenDefaultsKey = tokenDefaultsKey
        self.registrationErrorDefaultsKey = registrationErrorDefaultsKey
        self.registeredPushTokenDefaultsKey = registeredPushTokenDefaultsKey
        self.notificationAuthorizationStatusProvider = notificationAuthorizationStatusProvider ?? {
            await center.notificationSettings().authorizationStatus
        }
        self.requestAuthorizationHandler = requestAuthorizationHandler ?? {
            (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        }
        self.registerForRemoteNotificationsHandler = registerForRemoteNotificationsHandler ?? {
            UIApplication.shared.registerForRemoteNotifications()
        }
        self.addNotificationRequestHandler = addNotificationRequestHandler ?? { request in
            try await center.add(request)
        }
        self.removePendingNotificationRequestsHandler = removePendingNotificationRequestsHandler ?? { identifiers in
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
        self.setNotificationCenterDelegateHandler = setNotificationCenterDelegateHandler ?? { delegate in
            center.delegate = delegate
        }
        self.isRunningTestsProvider = isRunningTestsProvider ?? {
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                || ProcessInfo.processInfo.environment["LIFEOS_UI_TEST_BOOTSTRAP"] == "1"
        }
        self.isRemotePushAvailableProvider = isRemotePushAvailableProvider ?? {
            resolvedRemotePushEnvironmentProvider() != nil
        }
        self.remotePushEnvironmentProvider = resolvedRemotePushEnvironmentProvider
        self.isRuntimeConfiguredProvider = isRuntimeConfiguredProvider ?? {
            SupabaseConfig.isRuntimeConfigured
        }
        self.notificationDeliveryUnlockedProvider = notificationDeliveryUnlockedProvider ?? {
            let authId = AuthManager.activeAuthId?.uuidString
            return await NotificationDeliveryGate.isUnlocked(authId: authId)
        }
        self.syncEngineProvider = syncEngineProvider ?? {
            AppContainer.shared?.syncEngine
        }
        super.init()
    }

    var remotePushStatusMessage: String? {
        if !canUseRemotePush {
            return AppCapabilityAvailability.remotePushUnavailableMessage
        }
        guard let registrationError = defaults.string(forKey: registrationErrorDefaultsKey),
              !registrationError.isEmpty else {
            return nil
        }
        return String(
            format: String(localized: "settings_notifications_remote_push_registration_failed_format"),
            registrationError
        )
    }

    func configureSystemServices() {
        guard !isRunningTests else { return }
        setNotificationCenterDelegateHandler(self)
    }

    func syncAuthorizationState() async {
        guard !isRunningTests else { return }
        guard canUseRemotePush else {
            await handleRemotePushUnavailableState()
            return
        }
        let authorizationStatus = await notificationAuthorizationStatusProvider()
        if authorizationStatus == .denied {
            await handleDeniedState()
            return
        }
        guard await notificationDeliveryUnlockedProvider() else { return }
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            await handleAuthorizedState()
        case .denied, .notDetermined:
            break
        @unknown default:
            break
        }
    }

    func evaluateDelayedAuthorizationPromptIfEligible() async {
        guard !isRunningTests else { return }
        guard !isEvaluatingDelayedAuthorizationPrompt else { return }
        isEvaluatingDelayedAuthorizationPrompt = true
        defer { isEvaluatingDelayedAuthorizationPrompt = false }

        guard await notificationDeliveryUnlockedProvider() else { return }

        await requestAuthorizationIfNeeded()
    }

    private func requestAuthorizationIfNeeded() async {
        guard !isRunningTests else { return }
        // Local notifications do not require the APNs entitlement. Always
        // request OS authorization; remote registration stays capability-gated
        // inside handleAuthorizedState().
        let authorizationStatus = await notificationAuthorizationStatusProvider()

        switch authorizationStatus {
        case .notDetermined:
            let granted = await requestAuthorizationHandler()
            if granted {
                await handleAuthorizedState()
            } else {
                await handleDeniedState()
            }
        case .authorized, .provisional, .ephemeral:
            await handleAuthorizedState()
        case .denied:
            await handleDeniedState()
        @unknown default:
            break
        }
    }

    /// Local reminders do not require an APNs entitlement. Called after a user
    /// explicitly starts an experiment; the delayed first-insight gate still applies.
    func requestLocalReminderAuthorizationIfNeeded() async -> Bool {
        guard !isRunningTests, await notificationDeliveryUnlockedProvider() else { return false }
        switch await notificationAuthorizationStatusProvider() {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined: return await requestAuthorizationHandler()
        case .denied: return false
        @unknown default: return false
        }
    }

    @discardableResult
    func scheduleLocalNotification(_ notification: LifeOSNotification, at scheduledAt: Date) async -> Bool {
        guard !isRunningTests else { return false }

        let authorizationStatus = await notificationAuthorizationStatusProvider()
        guard authorizationStatus == .authorized
                || authorizationStatus == .provisional
                || authorizationStatus == .ephemeral else {
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.userInfo = localNotificationUserInfo(for: notification)

        if let subtitle = notification.subtitle, !subtitle.isEmpty {
            content.subtitle = subtitle
        }

        if let interruptionLevel = interruptionLevel(for: notification.priority) {
            content.interruptionLevel = interruptionLevel
        }

        let trigger: UNNotificationTrigger
        let now = Date()
        if scheduledAt <= now.addingTimeInterval(1) {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        } else {
            let components = Calendar.autoupdatingCurrent.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: scheduledAt
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        }

        let request = UNNotificationRequest(
            identifier: notification.id.uuidString,
            content: content,
            trigger: trigger
        )
        do {
            try await addNotificationRequestHandler(request)
            return true
        } catch {
            return false
        }
    }

    func handleDidRegisterForRemoteNotifications(deviceToken: Data) async {
        guard !isRunningTests else { return }
        defaults.set(hexString(from: deviceToken), forKey: tokenDefaultsKey)
        clearRegistrationError()
        await cancelPendingDeviceUnregistrationIfPossible()
        await cancelPendingDeviceRegistrationIfPossible()
        _ = await enqueuePushRegistrationIfPossible()
    }

    func handleDidFailToRegisterForRemoteNotifications(error: Error) async {
        guard !isRunningTests else { return }
        defaults.set(error.localizedDescription, forKey: registrationErrorDefaultsKey)
    }

    @discardableResult
    func unregisterCurrentDevice() async -> Bool {
        guard !isRunningTests else { return false }
        await cancelPendingDeviceRegistrationIfPossible()
        guard isRuntimeConfiguredProvider() else { return false }
        guard let token = tokenEligibleForUnregistration else { return false }
        guard let syncEngine = syncEngineProvider() else { return false }

        let payload: [String: Any] = [
            "device_id": deviceId,
            "push_token": token
        ]
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        let event = OutboxEvent(
            httpMethod: .POST,
            path: unregisterDevicePath,
            bodyJson: body,
            priority: 35
        )
        do {
            try await syncEngine.enqueueMutation(event)
            setTrackedRegisteredPushToken(nil)
            return true
        } catch {
            return false
        }
    }

    func cancelPendingNotifications(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        removePendingNotificationRequestsHandler(identifiers)
    }

    private func handleAuthorizedState() async {
        guard canUseRemotePush else {
            await handleRemotePushUnavailableState()
            return
        }
        await cancelPendingDeviceUnregistrationIfPossible()
        await cancelPendingDeviceRegistrationIfPossible()
        registerForRemoteNotificationsHandler()
        _ = await enqueuePushRegistrationIfPossible()
    }

    private func handleDeniedState() async {
        clearRegistrationError()
        _ = await unregisterCurrentDevice()
    }

    private func handleRemotePushUnavailableState() async {
        clearRegistrationError()
        _ = await unregisterCurrentDevice()
    }

    private func clearRegistrationError() {
        defaults.removeObject(forKey: registrationErrorDefaultsKey)
    }

    private var currentPushToken: String? {
        normalizedDefaultsString(forKey: tokenDefaultsKey)
    }

    private var trackedRegisteredPushToken: String? {
        normalizedDefaultsString(forKey: registeredPushTokenDefaultsKey)
    }

    private var hasTrackedServerRegistrationState: Bool {
        defaults.object(forKey: registeredPushTokenDefaultsKey) != nil
    }

    private var tokenEligibleForUnregistration: String? {
        if hasTrackedServerRegistrationState {
            return trackedRegisteredPushToken
        }
        return trackedRegisteredPushToken ?? currentPushToken
    }

    private func normalizedDefaultsString(forKey key: String) -> String? {
        guard let value = defaults.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            return nil
        }
        return value
    }

    private func setTrackedRegisteredPushToken(_ token: String?) {
        defaults.set(token ?? "", forKey: registeredPushTokenDefaultsKey)
    }

    private func cancelPendingDeviceRegistrationIfPossible() async {
        await cancelPendingPushLifecycleEvents(paths: [registerDevicePath])
    }

    private func cancelPendingDeviceUnregistrationIfPossible() async {
        await cancelPendingPushLifecycleEvents(paths: [unregisterDevicePath])
    }

    private func cancelPendingPushLifecycleEvents(paths: [String]) async {
        guard let syncEngine = syncEngineProvider() else { return }
        try? await syncEngine.cancelPendingEvents(matchingPaths: paths)
    }

    @discardableResult
    private func enqueuePushRegistrationIfPossible() async -> Bool {
        guard canUseRemotePush else { return false }
        guard isRuntimeConfiguredProvider() else { return false }
        guard let pushToken = currentPushToken else { return false }
        guard let pushEnvironment = remotePushEnvironment else { return false }
        guard let syncEngine = syncEngineProvider() else { return false }

        let payload: [String: Any] = [
            "device_id": deviceId,
            "push_token": pushToken,
            "platform": "ios",
            "environment": pushEnvironment,
            "locale": Locale.autoupdatingCurrent.identifier,
            "timezone": TimeZone.autoupdatingCurrent.identifier,
            "app_version": appVersion,
            "build_number": buildNumber
        ]
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        let event = OutboxEvent(
            httpMethod: .POST,
            path: registerDevicePath,
            bodyJson: body,
            priority: 30
        )
        do {
            try await syncEngine.enqueueMutation(event)
            setTrackedRegisteredPushToken(pushToken)
            return true
        } catch {
            return false
        }
    }

    private var canUseRemotePush: Bool {
        isRemotePushAvailableProvider() && remotePushEnvironment != nil
    }

    private var remotePushEnvironment: String? {
        guard let environment = remotePushEnvironmentProvider()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              (environment.caseInsensitiveCompare("development") == .orderedSame
                || environment.caseInsensitiveCompare("production") == .orderedSame),
              !environment.isEmpty else {
            return nil
        }
        return environment.lowercased()
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    private func localNotificationUserInfo(for notification: LifeOSNotification) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            "id": notification.id.uuidString,
            "category": notification.category.rawValue,
            "priority": notification.priority.rawValue
        ]
        if let deepLink = notification.deepLink, !deepLink.isEmpty {
            userInfo["deep_link"] = deepLink
        }
        return userInfo
    }

    private func interruptionLevel(for priority: NotificationPriority) -> UNNotificationInterruptionLevel? {
        switch priority {
        case .passive:
            return .passive
        case .active:
            return .active
        case .timeSensitive:
            return .timeSensitive
        }
    }

    private func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func postDeepLinkIfPresent(userInfo: [AnyHashable: Any]) {
        guard let deepLink = userInfo["deep_link"] as? String, !deepLink.isEmpty else { return }
        postDeepLink(deepLink)
    }

    private func postDeepLink(_ deepLink: String) {
        NotificationCenter.default.post(name: .watchDeepLink, object: nil, userInfo: ["deep_link": deepLink])
    }
}

extension PushNotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .badge, .sound]
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let deepLink = response.notification.request.content.userInfo["deep_link"] as? String
        await MainActor.run {
            guard let deepLink, !deepLink.isEmpty else { return }
            postDeepLink(deepLink)
        }
    }
}
#endif
