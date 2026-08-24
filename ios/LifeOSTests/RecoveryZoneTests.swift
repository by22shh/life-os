// MARK: - Recovery Zone Tests
// Verifies locked zone boundaries per life_os_invariants.md.

import XCTest
@testable import LifeOS

final class RecoveryZoneTests: XCTestCase {

    // MARK: - Boundary Tests (Locked)

    func testCriticalZone() {
        XCTAssertEqual(RecoveryZone.from(score: 0), .critical)
        XCTAssertEqual(RecoveryZone.from(score: 12), .critical)
        XCTAssertEqual(RecoveryZone.from(score: 24), .critical)
        XCTAssertEqual(RecoveryZone.from(score: 24.9), .critical)
    }

    func testCautionZone() {
        XCTAssertEqual(RecoveryZone.from(score: 25), .caution)
        XCTAssertEqual(RecoveryZone.from(score: 37), .caution)
        XCTAssertEqual(RecoveryZone.from(score: 49), .caution)
        XCTAssertEqual(RecoveryZone.from(score: 49.9), .caution)
    }

    func testReadyZone() {
        XCTAssertEqual(RecoveryZone.from(score: 50), .ready)
        XCTAssertEqual(RecoveryZone.from(score: 62), .ready)
        XCTAssertEqual(RecoveryZone.from(score: 74), .ready)
        XCTAssertEqual(RecoveryZone.from(score: 74.9), .ready)
    }

    func testOptimalZone() {
        XCTAssertEqual(RecoveryZone.from(score: 75), .optimal)
        XCTAssertEqual(RecoveryZone.from(score: 87), .optimal)
        XCTAssertEqual(RecoveryZone.from(score: 100), .optimal)
    }

    // MARK: - Clamping

    func testNegativeScoreClampsToZero() {
        XCTAssertEqual(RecoveryZone.from(score: -10), .critical)
    }

    func testOverHundredClampsToMax() {
        XCTAssertEqual(RecoveryZone.from(score: 150), .optimal)
    }

    // MARK: - MicroZone

    func testMicroZoneNilBelowOptimal() {
        XCTAssertNil(MicroZone.from(score: 60))
        XCTAssertNil(MicroZone.from(score: 74.9))
    }

    func testMicroZoneSolid() {
        XCTAssertEqual(MicroZone.from(score: 75), .solid)
        XCTAssertEqual(MicroZone.from(score: 79.9), .solid)
    }

    func testMicroZoneStrong() {
        XCTAssertEqual(MicroZone.from(score: 80), .strong)
        XCTAssertEqual(MicroZone.from(score: 89.9), .strong)
    }

    func testMicroZonePeak() {
        XCTAssertEqual(MicroZone.from(score: 90), .peak)
        XCTAssertEqual(MicroZone.from(score: 100), .peak)
    }

    // MARK: - Display Properties

    func testLabels() {
        XCTAssertEqual(RecoveryZone.critical.label, String(localized: "recovery_zone_critical"))
        XCTAssertEqual(RecoveryZone.caution.label, String(localized: "recovery_zone_caution"))
        XCTAssertEqual(RecoveryZone.ready.label, String(localized: "recovery_zone_ready"))
        XCTAssertEqual(RecoveryZone.optimal.label, String(localized: "recovery_zone_optimal"))
    }

    func testIconsAreNotEmpty() {
        for zone in RecoveryZone.allCases {
            XCTAssertFalse(zone.iconName.isEmpty, "\(zone) icon should not be empty")
        }
    }

    func testZoneRangesAndShortLabels() {
        XCTAssertEqual(RecoveryZone.critical.scoreRange.lowerBound, 0)
        XCTAssertEqual(RecoveryZone.critical.scoreRange.upperBound, 25)
        XCTAssertEqual(RecoveryZone.caution.scoreRange.lowerBound, 25)
        XCTAssertEqual(RecoveryZone.caution.scoreRange.upperBound, 50)
        XCTAssertEqual(RecoveryZone.ready.scoreRange.lowerBound, 50)
        XCTAssertEqual(RecoveryZone.ready.scoreRange.upperBound, 75)
        XCTAssertEqual(RecoveryZone.optimal.scoreRange.lowerBound, 75)
        XCTAssertEqual(RecoveryZone.optimal.scoreRange.upperBound, 101)

        XCTAssertEqual(RecoveryZone.critical.shortLabel, "CRIT")
        XCTAssertEqual(RecoveryZone.caution.shortLabel, "CAUT")
        XCTAssertEqual(RecoveryZone.ready.shortLabel, "RDY")
        XCTAssertEqual(RecoveryZone.optimal.shortLabel, "OPT")
    }

    func testDescriptionsColorsAndAccessibilityStringsArePopulated() {
        for zone in RecoveryZone.allCases {
            XCTAssertFalse(zone.description.isEmpty)
            XCTAssertFalse(zone.accessibilityLabel.isEmpty)
            XCTAssertFalse(zone.accessibilityAnnouncement(score: 87).isEmpty)
            _ = zone.color
            _ = zone.colorLight
            _ = zone.colorDark
        }
    }

    func testMicroZoneLabels() {
        XCTAssertFalse(MicroZone.solid.label.isEmpty)
        XCTAssertFalse(MicroZone.strong.label.isEmpty)
        XCTAssertFalse(MicroZone.peak.label.isEmpty)
    }

    // MARK: - Recovery Score Value

    func testLowConfidenceThreshold() {
        let low = RecoveryScoreValue(
            score: 80,
            confidence: 0.5,
            components: .init()
        )
        XCTAssertTrue(low.isLowConfidence)

        let high = RecoveryScoreValue(
            score: 80,
            confidence: 0.8,
            components: .init()
        )
        XCTAssertFalse(high.isLowConfidence)
    }

    func testRecoveryScoreClamps() {
        let overMax = RecoveryScoreValue(
            score: 120,
            confidence: 1.0,
            components: .init()
        )
        XCTAssertEqual(overMax.score, 100)
        XCTAssertEqual(overMax.zone, .optimal)

        let underMin = RecoveryScoreValue(
            score: -5,
            confidence: 1.0,
            components: .init()
        )
        XCTAssertEqual(underMin.score, 0)
        XCTAssertEqual(underMin.zone, .critical)
    }

    func testRecoveryScoreConfidenceClampAndNeedsReviewAlias() {
        let overConf = RecoveryScoreValue(
            score: 80,
            confidence: 2.0,
            components: .init()
        )
        XCTAssertEqual(overConf.confidence, 1)
        XCTAssertFalse(overConf.needsReview)

        let underConf = RecoveryScoreValue(
            score: 80,
            confidence: -0.2,
            components: .init()
        )
        XCTAssertEqual(underConf.confidence, 0)
        XCTAssertTrue(underConf.needsReview)
    }

    func testPhysiologicalStateInitializerClampsAndSetsZoneAndMicroZone() {
        let userId = UUID()
        let high = PhysiologicalState(userId: userId, date: "2026-02-24", recoveryScore: 140)
        XCTAssertEqual(high.recoveryScore, 100)
        XCTAssertEqual(high.recoveryZone, .optimal)
        XCTAssertEqual(high.microZone, .peak)
        XCTAssertEqual(high.date, "2026-02-24")

        let low = PhysiologicalState(userId: userId, date: "2026-02-24", recoveryScore: -10)
        XCTAssertEqual(low.recoveryScore, 0)
        XCTAssertEqual(low.recoveryZone, .critical)
        XCTAssertNil(low.microZone)
    }

    func testAutonomicStateRawValues() {
        XCTAssertEqual(AutonomicState.sympathetic.rawValue, "sympathetic")
        XCTAssertEqual(AutonomicState.parasympathetic.rawValue, "parasympathetic")
        XCTAssertEqual(AutonomicState.balanced.rawValue, "balanced")
    }
}
