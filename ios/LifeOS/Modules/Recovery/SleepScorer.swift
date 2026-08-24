// MARK: - Sleep Scorer
// Source of truth: life_os_recovery_algorithms.md §3.5 — Sleep Score (30% Weight)
// Composite: Duration 20%, Efficiency 15%, Deep 30%, REM 25%, Continuity 10%
// Age-adjusted targets via SleepTargetEngine (Ohayon et al. 2004, Walker 2017).
// INVARIANT: Output clamped to [0, 100].

import Foundation
import GRDB

enum SleepScorer {

    // MARK: - Sub-component Weights (per spec)

    private enum Weight {
        static let duration: Double = 0.20
        static let efficiency: Double = 0.15
        static let deep: Double = 0.30
        static let rem: Double = 0.25
        static let continuity: Double = 0.10
    }

    // MARK: - Optimal Duration by Age (hours, per Ohayon / Walker)

    static func optimalDurationRange(age: Int) -> ClosedRange<Double> {
        switch age {
        case ..<20:  return 7.5...9.0
        case 20..<30: return 7.0...8.5
        case 30..<40: return 7.0...8.0
        case 40..<50: return 6.5...7.5
        case 50..<60: return 6.5...7.5
        case 60..<70: return 6.0...7.0
        default:      return 5.5...7.0
        }
    }

    // MARK: - Composite Score

    /// Compute weighted sleep composite from a `SleepLog` and user context.
    /// Missing sub-components are proportionally reweighted.
    static func compositeScore(
        sleepLog: SleepLog?,
        physiologicalState: PhysiologicalState?,
        age: Int,
        recentLogs: [SleepLog] = []
    ) -> Double? {
        // Need at least one source of sleep data
        guard sleepLog != nil || physiologicalState != nil else { return nil }

        var components: [(weight: Double, score: Double)] = []

        // 1. Duration Score (20%)
        if let durationScore = durationScore(sleepLog: sleepLog, state: physiologicalState, age: age) {
            components.append((Weight.duration, durationScore))
        }

        // 2. Efficiency Score (15%)
        if let effScore = efficiencyScore(sleepLog: sleepLog) {
            components.append((Weight.efficiency, effScore))
        }

        // 3. Deep Sleep Score (30%)
        if let deepScore = deepSleepScore(sleepLog: sleepLog, state: physiologicalState, age: age) {
            components.append((Weight.deep, deepScore))
        }

        // 4. REM Score (25%)
        if let remScore = remSleepScore(sleepLog: sleepLog, state: physiologicalState, age: age) {
            components.append((Weight.rem, remScore))
        }

        // 5. Continuity Score (10%)
        if let contScore = continuityScore(sleepLog: sleepLog) {
            components.append((Weight.continuity, contScore))
        }

        guard !components.isEmpty else { return nil }

        // Proportional reweighting
        let totalWeight = components.reduce(0) { $0 + $1.weight }
        let raw = components.reduce(0) { $0 + ($1.score * $1.weight) } / totalWeight

        // Sleep debt penalty
        let penalty = sleepDebtPenalty(recentLogs: recentLogs, age: age)

        return min(100, max(0, raw - penalty))
    }

    // MARK: - Duration Sub-Score (20%)

    /// Ratio of actual vs optimal duration → piecewise scoring.
    private static func durationScore(sleepLog: SleepLog?, state: PhysiologicalState?, age: Int) -> Double? {
        let hours: Double
        if let totalMin = sleepLog?.totalDurationMinutes {
            hours = Double(totalMin) / 60.0
        } else if let h = state?.sleepDurationHours {
            hours = h
        } else {
            return nil
        }

        let optimal = optimalDurationRange(age: age)
        let target = (optimal.lowerBound + optimal.upperBound) / 2.0

        guard target > 0 else { return 50 }
        let ratio = hours / target

        if ratio >= 1.0 { return 100 }
        if ratio >= 0.85 { return 70 + (ratio - 0.85) / 0.15 * 30 }  // 85-100% → 70-100
        if ratio >= 0.70 { return 40 + (ratio - 0.70) / 0.15 * 30 }  // 70-85% → 40-70
        return max(0, ratio / 0.70 * 40)                               // <70% → 0-40
    }

    // MARK: - Efficiency Sub-Score (15%)

    /// Sleep efficiency = time asleep / time in bed × 100.
    /// ≥90% → 100, 85–90% → 80–100, 80–85% → 60–80, <80% → linear down.
    private static func efficiencyScore(sleepLog: SleepLog?) -> Double? {
        guard let efficiency = sleepLog?.sleepEfficiency else { return nil }

        if efficiency >= 90 { return 100 }
        if efficiency >= 85 { return 80 + (efficiency - 85) / 5 * 20 }
        if efficiency >= 80 { return 60 + (efficiency - 80) / 5 * 20 }
        return max(0, efficiency / 80 * 60)
    }

    // MARK: - Deep Sleep Sub-Score (30%)

    /// Deep sleep % vs age-optimal target → ratio-based scoring (per spec).
    /// Uses explicit linear interpolation between piecewise boundaries.
    private static func deepSleepScore(sleepLog: SleepLog?, state: PhysiologicalState?, age: Int) -> Double? {
        let deepPct: Double
        if let pct = sleepLog?.deepSleepPercent {
            deepPct = pct
        } else if let pct = state?.deepSleepPercent {
            deepPct = pct
        } else {
            return nil
        }

        let targetRange = SleepTargetEngine.deepSleepTargetRange(age: age)
        let optimalTarget = targetRange.upperBound // targetRange represents minimum...optimal
        guard optimalTarget > 0 else { return 50 }

        let ratio = deepPct / optimalTarget

        if ratio >= 1.0 { return 100 }
        if ratio >= 0.7 { return interpolate(ratio, fromLo: 0.7, fromHi: 1.0, toLo: 70, toHi: 100) }
        if ratio >= 0.4 { return interpolate(ratio, fromLo: 0.4, fromHi: 0.7, toLo: 40, toHi: 70) }
        return max(0, interpolate(ratio, fromLo: 0.0, fromHi: 0.4, toLo: 0, toHi: 40))
    }

    // MARK: - REM Sleep Sub-Score (25%)

    /// REM % vs age-adjusted target band → deviation-based scoring (per spec).
    /// Within range → 100; deviation ≤5% → 100-(dev×3); deviation >5% → 85-((dev-5)×4)
    private static func remSleepScore(sleepLog: SleepLog?, state: PhysiologicalState?, age: Int) -> Double? {
        let remPct: Double
        if let pct = sleepLog?.remSleepPercent {
            remPct = pct
        } else if let pct = state?.remSleepPercent {
            remPct = pct
        } else {
            return nil
        }

        let targetRange = SleepTargetEngine.remSleepTargetRange(age: age)

        if targetRange.contains(remPct) { return 100 }

        let deviation = remPct < targetRange.lowerBound
            ? targetRange.lowerBound - remPct
            : remPct - targetRange.upperBound

        if deviation <= 5 { return max(0, 100 - (deviation * 3)) }
        return max(0, 85 - ((deviation - 5) * 4))
    }

    // MARK: - Continuity Sub-Score (10%)

    /// Fewer awakenings → higher score. 0 awakenings → 100, each reduces score.
    private static func continuityScore(sleepLog: SleepLog?) -> Double? {
        guard let awakenings = sleepLog?.numberOfAwakenings else { return nil }
        // Per spec: based on ratio of uninterrupted sleep
        // Simplified: 0 → 100, 1 → 90, 2 → 75, 3 → 55, 4+ → max(0, 40-10*(n-4))
        switch awakenings {
        case 0:     return 100
        case 1:     return 90
        case 2:     return 75
        case 3:     return 55
        case 4:     return 40
        default:    return max(0, 40 - Double(awakenings - 4) * 10)
        }
    }

    // MARK: - Sleep Debt Penalty

    /// Cumulative sleep debt over the last 7 days.
    /// Severity: NONE ≤5h → 0, MILD 5-10h → 3, MODERATE 10-20h → 8, SEVERE 20-35h → 15, CRITICAL >35h → 25
    private static func sleepDebtPenalty(recentLogs: [SleepLog], age: Int) -> Double {
        guard !recentLogs.isEmpty else { return 0 }

        let optimal = optimalDurationRange(age: age)
        let optimalHours = (optimal.lowerBound + optimal.upperBound) / 2.0

        var totalDebtHours: Double = 0
        for log in recentLogs.prefix(7) {
            if let totalMin = log.totalDurationMinutes {
                let actual = Double(totalMin) / 60.0
                let deficit = max(0, optimalHours - actual)
                totalDebtHours += deficit
            }
        }

        switch totalDebtHours {
        case ..<5:   return 0
        case 5..<10: return 3
        case 10..<20: return 8
        case 20..<35: return 15
        default:      return 25
        }
    }

    // MARK: - Helpers

    /// Linear interpolation: maps `value` from `[fromLo, fromHi]` → `[toLo, toHi]`.
    private static func interpolate(_ value: Double, fromLo: Double, fromHi: Double, toLo: Double, toHi: Double) -> Double {
        guard fromHi != fromLo else { return toLo }
        return toLo + (value - fromLo) / (fromHi - fromLo) * (toHi - toLo)
    }
}
