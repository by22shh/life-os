// MARK: - Training Zone Display Properties
// Mirrors RecoveryZone pattern for consistent UI across the app.
// Colors reuse Okabe-Ito palette (LifeOSColors.Recovery) — no new assets needed.

import SwiftUI

// MARK: - TrainingZoneState Display

extension TrainingZoneState {

    /// User-visible label for the training zone.
    var label: String {
        switch self {
        case .undertraining: return String(localized: "training_zone_undertraining")
        case .optimal:       return String(localized: "training_zone_optimal")
        case .overreaching:  return String(localized: "training_zone_overreaching")
        case .injuryRisk:    return String(localized: "training_zone_injury_risk")
        }
    }

    /// SF Symbol icon name — always display alongside color and text (triple indicator rule).
    var iconName: String {
        switch self {
        case .undertraining: return "arrow.down.circle.fill"
        case .optimal:       return "checkmark.circle.fill"
        case .overreaching:  return "exclamationmark.triangle.fill"
        case .injuryRisk:    return "xmark.circle.fill"
        }
    }

    /// Adaptive zone color using existing Okabe-Ito recovery palette.
    var color: Color {
        switch self {
        case .undertraining: return LifeOSColors.Recovery.caution
        case .optimal:       return LifeOSColors.Recovery.optimal
        case .overreaching:  return LifeOSColors.Recovery.caution
        case .injuryRisk:    return LifeOSColors.Recovery.critical
        }
    }

    /// VoiceOver description including zone name.
    var accessibilityLabel: String {
        "\(String(localized: "training_zone_accessibility_prefix")) \(label)"
    }

    /// Short label for compact UI and complications.
    var shortLabel: String {
        switch self {
        case .undertraining: return "UND"
        case .optimal:       return "OPT"
        case .overreaching:  return "OVR"
        case .injuryRisk:    return "INJ"
        }
    }

    /// User-facing description with actionable guidance.
    var description: String {
        switch self {
        case .undertraining: return String(localized: "training_zone_desc_undertraining")
        case .optimal:       return String(localized: "training_zone_desc_optimal")
        case .overreaching:  return String(localized: "training_zone_desc_overreaching")
        case .injuryRisk:    return String(localized: "training_zone_desc_injury_risk")
        }
    }
}

// MARK: - WeeklyTrend Display

extension WeeklyTrend {

    /// User-visible label for the weekly trend.
    var label: String {
        switch self {
        case .increasing: return String(localized: "trend_increasing")
        case .stable:     return String(localized: "trend_stable")
        case .decreasing: return String(localized: "trend_decreasing")
        }
    }

    /// SF Symbol arrow icon for the trend direction.
    var iconName: String {
        switch self {
        case .increasing: return "arrow.up.right"
        case .stable:     return "arrow.right"
        case .decreasing: return "arrow.down.right"
        }
    }

    /// Color for the trend direction.
    var color: Color {
        switch self {
        case .increasing: return LifeOSColors.Semantic.success
        case .stable:     return .secondary
        case .decreasing: return LifeOSColors.Semantic.warning
        }
    }

    /// VoiceOver-friendly description.
    var accessibilityLabel: String {
        "\(String(localized: "weekly_trend")): \(label)"
    }
}
