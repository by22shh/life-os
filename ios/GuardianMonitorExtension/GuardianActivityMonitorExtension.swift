import Foundation
import DeviceActivity
import ManagedSettings
import OSLog

final class GuardianActivityMonitorExtension: DeviceActivityMonitor {
    private let logger = Logger(subsystem: "com.lifeos.app", category: "GuardianMonitorExtension")
    private let store = ManagedSettingsStore(named: GuardianMonitorIdentifiers.storeName)

    /// Shared App Group defaults for passing screen-time events to the main app.
    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: GuardianMonitorIdentifiers.appGroupSuiteName)
    }

    // MARK: - Interval Callbacks

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        guard activity == GuardianMonitorIdentifiers.activityName else { return }
        logger.info("Guardian monitor interval started")
        recordEvent(.intervalStarted)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        guard activity == GuardianMonitorIdentifiers.activityName else { return }
        store.clearAllSettings()
        logger.info("Guardian monitor interval ended and shields were cleared")
        recordEvent(.intervalEnded)
    }

    override func intervalWillStartWarning(for activity: DeviceActivityName) {
        super.intervalWillStartWarning(for: activity)
        guard activity == GuardianMonitorIdentifiers.activityName else { return }
        logger.info("Guardian monitor interval will start soon (warning)")
        recordEvent(.intervalWillStart)
    }

    override func intervalWillEndWarning(for activity: DeviceActivityName) {
        super.intervalWillEndWarning(for: activity)
        guard activity == GuardianMonitorIdentifiers.activityName else { return }
        logger.info("Guardian monitor interval will end soon (warning)")
        recordEvent(.intervalWillEnd)
    }

    // MARK: - Threshold Callbacks (passive usage tracking)

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        logger.info("Guardian threshold reached: \(event.rawValue, privacy: .public) for \(activity.rawValue, privacy: .public)")
        recordEvent(.thresholdReached(event: event.rawValue))
    }

    // MARK: - Passive Screen Time Event Recording

    /// Lightweight screen-time event stored in shared UserDefaults.
    /// The main app reads + flushes these into the local GRDB database on foreground.
    private enum ScreenTimeEventType: Codable {
        case intervalStarted
        case intervalEnded
        case intervalWillStart
        case intervalWillEnd
        case thresholdReached(event: String)
    }

    private struct ScreenTimeEvent: Codable {
        let type: ScreenTimeEventType
        let timestamp: Date
    }

    private func recordEvent(_ type: ScreenTimeEventType) {
        guard let defaults = sharedDefaults else {
            logger.warning("No shared defaults available for screen time tracking")
            return
        }

        let event = ScreenTimeEvent(type: type, timestamp: Date())

        // Read existing events, append new one, write back.
        // The main app is responsible for draining this array on foreground.
        var events: [ScreenTimeEvent] = []
        if let data = defaults.data(forKey: GuardianMonitorIdentifiers.screenTimeEventsKey) {
            if let decoded = try? JSONDecoder().decode([ScreenTimeEvent].self, from: data) {
                events = decoded
            } else {
                logger.warning("Discarded malformed buffered screen-time events before appending a new one")
            }
        }

        events.append(event)

        // Cap at 500 events to prevent unbounded growth if main app isn't reading.
        if events.count > 500 {
            events = Array(events.suffix(500))
        }

        do {
            let encoded = try JSONEncoder().encode(events)
            defaults.set(encoded, forKey: GuardianMonitorIdentifiers.screenTimeEventsKey)
        } catch {
            logger.error("Failed to encode buffered screen-time events: \(error.localizedDescription, privacy: .public)")
        }
    }
}
