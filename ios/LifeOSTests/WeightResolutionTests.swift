import XCTest
@testable import LifeOS

final class WeightResolutionTests: XCTestCase {

    // MARK: - Divergence Detection (P3 #24)

    func testDivergenceAboveThreshold() {
        // 80 vs 70 → ~14% divergence → should trigger
        XCTAssertTrue(
            WeightResolution.divergenceExceedsThreshold(resolved: 80, profileWeight: 70),
            "14% divergence should exceed 5% threshold"
        )
    }

    func testDivergenceBelowThreshold() {
        // 71 vs 70 → ~1.4% divergence → should NOT trigger
        XCTAssertFalse(
            WeightResolution.divergenceExceedsThreshold(resolved: 71, profileWeight: 70),
            "1.4% divergence should not exceed 5% threshold"
        )
    }

    func testDivergenceExactlyAtThreshold() {
        // 73.5 vs 70 → exactly 5% relative, but absolute diff is 3.5kg (>2kg) so it triggers.
        XCTAssertTrue(
            WeightResolution.divergenceExceedsThreshold(resolved: 73.5, profileWeight: 70),
            "Absolute divergence > 2kg should trigger even when relative divergence is exactly 5%"
        )
    }

    func testDivergenceNegativeDirection() {
        // 65 vs 70 → ~7.1% below → should trigger
        XCTAssertTrue(
            WeightResolution.divergenceExceedsThreshold(resolved: 65, profileWeight: 70),
            "7.1% negative divergence should exceed 5% threshold"
        )
    }

    func testDivergenceZeroProfileWeight() {
        // Profile weight 0 → should return false (guard)
        XCTAssertFalse(
            WeightResolution.divergenceExceedsThreshold(resolved: 80, profileWeight: 0),
            "Zero profile weight should not trigger divergence"
        )
    }

    func testDivergenceCustomThreshold() {
        // 72 vs 70 → ~2.8% → below 5% but above 2%
        XCTAssertTrue(
            WeightResolution.divergenceExceedsThreshold(resolved: 72, profileWeight: 70, relativeThreshold: 0.02),
            "2.8% divergence should exceed custom 2% threshold"
        )
        XCTAssertFalse(
            WeightResolution.divergenceExceedsThreshold(resolved: 72, profileWeight: 70, relativeThreshold: 0.05),
            "2.8% divergence should not exceed 5% threshold"
        )
    }
}
