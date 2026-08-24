// MARK: - Recovery Zone Model
// Source of truth: life_os_invariants.md
// Boundaries: inclusive on low end, exclusive on high (except Optimal includes 100).
// Recovery zones: critical 0–24, caution 25–49, ready 50–74, optimal 75–100.

import SwiftUI

/// The 4-bucket recovery zone model.
/// INVARIANT: These boundaries are locked and must not change without a spec version bump.
enum RecoveryZone: String, Codable, Equatable, Sendable, CaseIterable {
    case critical
    case caution
    case ready
    case optimal

    // MARK: - Score Factory

    /// Determines the recovery zone for a given score (0–100).
    /// Scores outside [0, 100] are clamped.
    /// Boundaries: Critical < 25 <= Caution < 50 <= Ready < 75 <= Optimal
    static func from(score: Double) -> RecoveryZone {
        let clamped = min(max(score, 0), 100)
        switch clamped {
        case 75...100:
            return .optimal
        case 50..<75:
            return .ready
        case 25..<50:
            return .caution
        default:
            // Covers 0..<25 (including 24.999...)
            return .critical
        }
    }

    /// The score range for this zone. Boundaries match `from(score:)`:
    /// critical=[0,25), caution=[25,50), ready=[50,75), optimal=[75,100].
    var scoreRange: Range<Double> {
        switch self {
        case .critical: return 0..<25
        case .caution:  return 25..<50
        case .ready:    return 50..<75
        case .optimal:  return 75..<101 // Visual aid, practically 100 inclusive
        }
    }

    // MARK: - Display Properties

    /// User-visible label for the recovery zone.
    var label: String {
        switch self {
        case .critical: return String(localized: "recovery_zone_critical")
        case .caution:  return String(localized: "recovery_zone_caution")
        case .ready:    return String(localized: "recovery_zone_ready")
        case .optimal:  return String(localized: "recovery_zone_optimal")
        }
    }

    /// SF Symbol icon name per design_system.md §Icons.
    /// RULE: Always display icon alongside color and text label (triple indicator).
    var iconName: String {
        switch self {
        case .critical: return "xmark.circle.fill"
        case .caution:  return "exclamationmark.triangle.fill"
        case .ready:    return "arrow.up.right.circle.fill"
        case .optimal:  return "checkmark.circle.fill"
        }
    }

    /// User-visible description (per design_system.md §Recovery Zones).
    var description: String {
        switch self {
        case .critical: return String(localized: "recovery_zone_desc_critical")
        case .caution:  return String(localized: "recovery_zone_desc_caution")
        case .ready:    return String(localized: "recovery_zone_desc_ready")
        case .optimal:  return String(localized: "recovery_zone_desc_optimal")
        }
    }

    /// Light-mode zone color (Okabe-Ito palette).
    var colorLight: Color {
        switch self {
        case .critical: return LifeOSColors.Recovery.Hex.criticalLight
        case .caution:  return LifeOSColors.Recovery.Hex.cautionLight
        case .ready:    return LifeOSColors.Recovery.Hex.readyLight
        case .optimal:  return LifeOSColors.Recovery.Hex.optimalLight
        }
    }

    /// Dark-mode zone color (Okabe-Ito palette).
    var colorDark: Color {
        switch self {
        case .critical: return LifeOSColors.Recovery.Hex.criticalDark
        case .caution:  return LifeOSColors.Recovery.Hex.cautionDark
        case .ready:    return LifeOSColors.Recovery.Hex.readyDark
        case .optimal:  return LifeOSColors.Recovery.Hex.optimalDark
        }
    }

    /// Adaptive color using asset catalog (automatically switches light/dark).
    var color: Color {
        switch self {
        case .critical: return LifeOSColors.Recovery.critical
        case .caution:  return LifeOSColors.Recovery.caution
        case .ready:    return LifeOSColors.Recovery.ready
        case .optimal:  return LifeOSColors.Recovery.optimal
        }
    }

    // MARK: - Accessibility

    /// VoiceOver description including zone name.
    var accessibilityLabel: String {
        "\(String(localized: "recovery_zone_accessibility_prefix")) \(label)"
    }

    /// VoiceOver announcement string including numeric percentage.
    func accessibilityAnnouncement(score: Double) -> String {
        let percent = Int(min(max(score, 0), 100).rounded())
        return "\(String(localized: "recovery_announcement_prefix")) \(label), \(percent) \(String(localized: "recovery_percent_label"))"
    }

    /// Short description for complications and compact UI.
    var shortLabel: String {
        switch self {
        case .critical: return "CRIT"
        case .caution:  return "CAUT"
        case .ready:    return "RDY"
        case .optimal:  return "OPT"
        }
    }
}

// MARK: - Micro Zone (Pro/Athlete feature)

/// Optional micro-zone within the 'optimal' zone.
enum MicroZone: String, Codable, Equatable, Sendable {
    case solid
    case strong
    case peak

    static func from(score: Double) -> MicroZone? {
        guard score >= 75 else { return nil }
        switch score {
        case 90...100: return .peak
        case 80..<90:  return .strong
        default:       return .solid
        }
    }

    var label: String {
        switch self {
        case .solid:  return String(localized: "micro_zone_solid")
        case .strong: return String(localized: "micro_zone_strong")
        case .peak:   return String(localized: "micro_zone_peak")
        }
    }
}
