// MARK: - Menstrual cycle phase
// Source of truth: life_os_recovery_algorithms.md §Menstrual Cycle Integration.
// All derivation is on-device; only the derived phase is used locally and is
// never uploaded.

import Foundation

enum MenstrualPhase: String, Codable, Sendable, CaseIterable {
    case menstrual = "MENSTRUAL"
    case follicular = "FOLLICULAR"
    case ovulation = "OVULATION"
    case luteal = "LUTEAL"

    /// Spec adjustment applied to the recovery score to compensate for
    /// physiologically expected hormonal effects.
    var scoreAdjustment: Double {
        switch self {
        case .menstrual: return 3
        case .follicular, .ovulation: return 0
        case .luteal: return 5
        }
    }

    var noteKey: String {
        switch self {
        case .menstrual: return "recovery_cycle_phase_menstrual"
        case .follicular: return "recovery_cycle_phase_follicular"
        case .ovulation: return "recovery_cycle_phase_ovulation"
        case .luteal: return "recovery_cycle_phase_luteal"
        }
    }
}

struct MenstrualPhaseDerivation: Equatable, Sendable {
    let phase: MenstrualPhase
    let cycleDay: Int?
    let cycleLength: Int
    let lastPeriodStart: String
}

enum MenstrualCycleAdjustment {
    /// Expected luteal-phase wrist-temperature elevation in °C. Subtracted
    /// before temperature scoring so the natural rise is not read as illness.
    static let lutealTemperatureCompensation = 0.3

    /// Derives the current phase from local flow dates.
    ///
    /// - Parameter flowDates: distinct local day strings (`yyyy-MM-dd`) with
    ///   recorded bleeding (spotting excluded).
    /// - Returns: `nil` until at least two period starts establish a cycle.
    static func derivePhase(flowDates: [String], on date: String) -> MenstrualPhaseDerivation? {
        let bleedingDays = Set(flowDates)
        guard !bleedingDays.isEmpty else { return nil }

        let starts = periodStarts(from: bleedingDays).sorted()
        guard starts.count >= 2 else { return nil }

        let recentStarts = Array(starts.suffix(7))
        var lengths: [Int] = []
        for index in 1..<recentStarts.count {
            if let diff = daysBetween(recentStarts[index - 1], recentStarts[index]),
               (18...45).contains(diff) {
                lengths.append(diff)
            }
        }
        guard !lengths.isEmpty else { return nil }

        let cycleLength = Int((Double(lengths.reduce(0, +)) / Double(lengths.count)).rounded())
        guard cycleLength > 0 else { return nil }

        guard let lastStart = recentStarts.last,
              let elapsed = daysBetween(lastStart, date),
              elapsed >= 0 else { return nil }
        let cycleDay = elapsed + 1

        let menstrualEnd = max(1, Int((Double(cycleLength) * 5 / 28).rounded()))
        let follicularEnd = max(menstrualEnd, Int((Double(cycleLength) * 13 / 28).rounded()))
        let ovulationEnd = max(follicularEnd, Int((Double(cycleLength) * 16 / 28).rounded()))

        let phase: MenstrualPhase
        if cycleDay <= menstrualEnd {
            phase = .menstrual
        } else if cycleDay <= follicularEnd {
            phase = .follicular
        } else if cycleDay <= ovulationEnd {
            phase = .ovulation
        } else {
            // Includes days past the expected cycle length (late luteal).
            phase = .luteal
        }

        return MenstrualPhaseDerivation(
            phase: phase,
            cycleDay: cycleDay <= cycleLength ? cycleDay : nil,
            cycleLength: cycleLength,
            lastPeriodStart: lastStart
        )
    }

    /// A day starts a period when it has bleeding and the previous calendar
    /// day does not.
    static func periodStarts(from bleedingDays: Set<String>) -> [String] {
        bleedingDays.filter { day in
            guard let previous = dayBefore(day) else { return true }
            return !bleedingDays.contains(previous)
        }
    }

    private static nonisolated(unsafe) let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func parseDay(_ value: String) -> Date? {
        dayFormatter.date(from: value)
    }

    static func dayBefore(_ value: String) -> String? {
        guard let date = parseDay(value) else { return nil }
        guard let previous = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -1, to: date) else { return nil }
        return dayFormatter.string(from: previous)
    }

    static func daysBetween(_ start: String, _ end: String) -> Int? {
        guard let startDate = parseDay(start), let endDate = parseDay(end) else { return nil }
        let days = Calendar(identifier: .gregorian)
            .dateComponents([.day], from: startDate, to: endDate).day
        return days
    }
}
