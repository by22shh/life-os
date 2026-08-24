import XCTest
@testable import LifeOS

final class NutritionTargetEngineTests: XCTestCase {

    func testWeightFactorClamp() {
        XCTAssertEqual(NutritionTargetEngine.weightFactor(effectiveWeightKg: 30), 0.75, accuracy: 0.0001)
        XCTAssertEqual(NutritionTargetEngine.weightFactor(effectiveWeightKg: 70), 1.0, accuracy: 0.0001)
        XCTAssertEqual(NutritionTargetEngine.weightFactor(effectiveWeightKg: 200), 1.25, accuracy: 0.0001)
    }

    func testRecoveryAdjustmentIsContinuous() {
        let low = NutritionTargetEngine.recoveryAdjustmentFactor(recoveryScore: 40)
        let high = NutritionTargetEngine.recoveryAdjustmentFactor(recoveryScore: 41)
        XCTAssertGreaterThan(high, low)
        XCTAssertLessThan(high - low, 0.01)
    }

    func testRecoveryAdjustmentReturnsBaselineAboveFifty() {
        XCTAssertEqual(
            NutritionTargetEngine.recoveryAdjustmentFactor(recoveryScore: 75),
            1.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            NutritionTargetEngine.recoveryAdjustment(recoveryScore: 75).proteinDeltaGPerKg,
            0.0,
            accuracy: 0.0001
        )
    }

    func testTrainingAdjustmentFollowsApiFormula() {
        XCTAssertEqual(
            NutritionTargetEngine.trainingAdjustmentKcal(
                activeEnergyKcal: 800,
                dailyTrimp: nil,
                effectiveWeightKg: 70
            ),
            320
        )

        XCTAssertEqual(
            NutritionTargetEngine.trainingAdjustmentKcal(
                activeEnergyKcal: nil,
                dailyTrimp: 100,
                effectiveWeightKg: 70
            ),
            130
        )

        XCTAssertEqual(
            NutritionTargetEngine.trainingAdjustmentKcal(
                activeEnergyKcal: nil,
                dailyTrimp: nil,
                effectiveWeightKg: 70
            ),
            0
        )
    }

    func testAdjustedCaloriesAppliesWeightAndRecoveryFactors() {
        XCTAssertEqual(
            NutritionTargetEngine.adjustedCalories(
                baseCalories: 2000,
                effectiveWeightKg: 70,
                recoveryScore: 75
            ),
            2000,
            accuracy: 0.0001
        )

        XCTAssertEqual(
            NutritionTargetEngine.adjustedCalories(
                baseCalories: 2000,
                effectiveWeightKg: 30,
                recoveryScore: 0
            ),
            1425,
            accuracy: 0.0001
        )

        XCTAssertEqual(
            NutritionTargetEngine.adjustedCalories(
                baseCalories: 2000,
                effectiveWeightKg: 200,
                recoveryScore: 50
            ),
            2500,
            accuracy: 0.0001
        )
    }
}
