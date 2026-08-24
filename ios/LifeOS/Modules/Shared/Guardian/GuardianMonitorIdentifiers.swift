@preconcurrency import DeviceActivity
@preconcurrency import ManagedSettings

enum GuardianMonitorIdentifiers {
    static let storeName = ManagedSettingsStore.Name("LifeOSGuardian")
    static let activityName = DeviceActivityName("LifeOSGuardianWindow")

    /// Shared App Group for passing screen-time events between the
    /// GuardianMonitorExtension and the main app.
    static let appGroupSuiteName = "group.com.lifeos.guardian"

    /// UserDefaults key where the extension stores screen-time events.
    static let screenTimeEventsKey = "guardian_screen_time_events"
}
