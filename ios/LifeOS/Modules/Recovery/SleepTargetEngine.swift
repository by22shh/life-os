// MARK: - Sleep Target Engine
// Age-adjusted stage targets with supportive wording (anti-orthosomnia).

import Foundation

enum SleepTargetEngine {
    static func deepSleepTargetRange(age: Int) -> ClosedRange<Double> {
        switch age {
        case ..<20: return 15...22
        case 20..<30: return 13...20
        case 30..<40: return 12...18
        case 40..<50: return 10...15
        case 50..<60: return 8...12
        case 60..<70: return 5...10
        default: return 3...8
        }
    }

    static func remSleepTargetRange(age: Int) -> ClosedRange<Double> {
        switch age {
        case ..<20: return 20...25
        case 20..<40: return 18...24
        case 40..<60: return 17...23
        case 60..<70: return 15...22
        default: return 13...20
        }
    }

    /// Supportive stage feedback that avoids fear-based or diagnostic language.
    static func supportiveStageFeedback(
        deepPercent: Double?,
        remPercent: Double?,
        age: Int
    ) -> String {
        guard let deepPercent, let remPercent else {
            return String(localized: "sleep_supportive_more_data")
        }

        let deepTarget = deepSleepTargetRange(age: age)
        let remTarget = remSleepTargetRange(age: age)
        let deepInRange = deepTarget.contains(deepPercent)
        let remInRange = remTarget.contains(remPercent)

        if deepInRange && remInRange {
            return "\(String(localized: "sleep_supportive_in_range")) \(String(localized: "clinician_disclaimer"))"
        }
        if !deepInRange && !remInRange {
            return "\(String(localized: "sleep_supportive_both_outside")) \(String(localized: "clinician_disclaimer"))"
        }
        if !deepInRange {
            return "\(String(localized: "sleep_supportive_deep_outside")) \(String(localized: "clinician_disclaimer"))"
        }
        return "\(String(localized: "sleep_supportive_rem_outside")) \(String(localized: "clinician_disclaimer"))"
    }
}
