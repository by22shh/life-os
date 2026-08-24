// MARK: - Nutrition Target Engine
// Dynamic macro/calorie adjustment helpers aligned with API formulas.

import Foundation

enum NutritionTargetEngine {
    struct RecoveryAdjustment: Equatable {
        var proteinDeltaGPerKg: Double
        var carbMultiplier: Double
        var calorieMultiplier: Double
    }

    static func weightFactor(effectiveWeightKg: Double) -> Double {
        let raw = effectiveWeightKg / 70.0
        return min(1.25, max(0.75, raw))
    }

    /// Continuous recovery adjustment from API spec:
    /// 0→50: interpolate to baseline; 50→100: baseline.
    static func recoveryAdjustment(recoveryScore: Double) -> RecoveryAdjustment {
        let clamped = min(100, max(0, recoveryScore))
        if clamped <= 50 {
            return .init(
                proteinDeltaGPerKg: lerp(clamped, inMin: 0, inMax: 50, outMin: 0.30, outMax: 0.0),
                carbMultiplier: lerp(clamped, inMin: 0, inMax: 50, outMin: 0.85, outMax: 1.0),
                calorieMultiplier: lerp(clamped, inMin: 0, inMax: 50, outMin: 0.95, outMax: 1.0)
            )
        }
        return .init(proteinDeltaGPerKg: 0.0, carbMultiplier: 1.0, calorieMultiplier: 1.0)
    }

    static func recoveryAdjustmentFactor(recoveryScore: Double) -> Double {
        recoveryAdjustment(recoveryScore: recoveryScore).calorieMultiplier
    }

    static func adjustedCalories(
        baseCalories: Double,
        effectiveWeightKg: Double,
        recoveryScore: Double
    ) -> Double {
        let weighted = baseCalories * weightFactor(effectiveWeightKg: effectiveWeightKg)
        return weighted * recoveryAdjustmentFactor(recoveryScore: recoveryScore)
    }

    static func trainingAdjustmentKcal(
        activeEnergyKcal: Double?,
        dailyTrimp: Double?,
        effectiveWeightKg: Double
    ) -> Int {
        let factor = weightFactor(effectiveWeightKg: effectiveWeightKg)

        if let activeEnergyKcal {
            let adjusted = activeEnergyKcal * 0.4 * factor
            return Int(min(600, max(0, adjusted)).rounded())
        }

        if let dailyTrimp {
            let adjusted = dailyTrimp * 1.3 * factor
            return Int(min(600, max(0, adjusted)).rounded())
        }

        return 0
    }

    private static func lerp(
        _ value: Double,
        inMin: Double,
        inMax: Double,
        outMin: Double,
        outMax: Double
    ) -> Double {
        guard inMax > inMin else { return outMin }
        let t = min(1, max(0, (value - inMin) / (inMax - inMin)))
        return outMin + t * (outMax - outMin)
    }
}
