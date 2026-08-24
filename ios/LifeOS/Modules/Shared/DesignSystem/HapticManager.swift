// MARK: - Haptic Manager
// Source of truth: life_os_design_system.md §Haptics
// Light tap, medium confirm, notification for zone change.
// Platform-guarded: UIKit haptics are only available on iOS.

#if os(iOS)
import UIKit

@MainActor
enum HapticManager {

    // MARK: - Predefined Feedback

    /// Light tap — for selection changes, toggle switches, tab switches.
    static func lightTap() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }

    /// Medium — for confirming actions (save, submit, log).
    static func mediumConfirm() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
    }

    /// Heavy — for destructive actions (delete, cancel workout).
    static func heavyImpact() {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        generator.impactOccurred()
    }

    /// Success — for completed goals, targets hit.
    static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

    /// Warning — for approaching limits, caution zone entry.
    static func warning() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
    }

    /// Error — for failed actions, critical zone entry.
    static func error() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.error)
    }

    /// Recovery zone change notification.
    /// Uses appropriate haptic based on the zone entered.
    static func zoneChange(_ zone: RecoveryZone) {
        switch zone {
        case .critical:
            error()
        case .caution:
            warning()
        case .ready:
            mediumConfirm()
        case .optimal:
            success()
        }
    }

    /// Selection changed in a picker or segmented control.
    static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }
}
#elseif os(watchOS)
import WatchKit

@MainActor
enum HapticManager {
    static func lightTap() {
        WKInterfaceDevice.current().play(.click)
    }
    static func mediumConfirm() {
        WKInterfaceDevice.current().play(.click)
    }
    static func heavyImpact() {
        WKInterfaceDevice.current().play(.directionDown)
    }
    static func success() {
        WKInterfaceDevice.current().play(.success)
    }
    static func warning() {
        WKInterfaceDevice.current().play(.retry)
    }
    static func error() {
        WKInterfaceDevice.current().play(.failure)
    }
    static func zoneChange(_ zone: RecoveryZone) {
        switch zone {
        case .critical:
            error()
        case .caution:
            warning()
        case .ready:
            mediumConfirm()
        case .optimal:
            success()
        }
    }
    static func selection() {
        WKInterfaceDevice.current().play(.click)
    }
}
#else
// macOS stub — no haptics.
@MainActor
enum HapticManager {
    static func lightTap() {}
    static func mediumConfirm() {}
    static func heavyImpact() {}
    static func success() {}
    static func warning() {}
    static func error() {}
    static func zoneChange(_ zone: RecoveryZone) {}
    static func selection() {}
}
#endif
