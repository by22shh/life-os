#if os(iOS)
import UIKit

final class LifeOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PushNotificationManager.shared.configureSystemServices()
        Task { @MainActor in
            await PushNotificationManager.shared.syncAuthorizationState()
        }
        return true
    }

    func application(
        _: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            await PushNotificationManager.shared.handleDidRegisterForRemoteNotifications(
                deviceToken: deviceToken
            )
        }
    }

    func application(
        _: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            await PushNotificationManager.shared.handleDidFailToRegisterForRemoteNotifications(
                error: error
            )
        }
    }
}
#endif
