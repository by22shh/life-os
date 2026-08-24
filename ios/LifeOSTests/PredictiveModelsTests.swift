import Foundation
import XCTest
@testable import LifeOS

final class PredictiveModelsTests: XCTestCase {

    func testPredictiveScenarioRequestEncodesSnakeCaseKeys() throws {
        let request = PredictiveScenarioRequest(
            targetDate: "2026-02-24",
            scenarioText: "Sleep at 01:00 after workout",
            scenarioType: .sleep,
            environmentalContext: nil
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["target_date"] as? String, "2026-02-24")
        XCTAssertEqual(json?["scenario_text"] as? String, "Sleep at 01:00 after workout")
        XCTAssertEqual(json?["scenario_type"] as? String, "sleep")
    }

    func testPredictiveScenarioResponseUsesExplicitRangeAndZone() throws {
        let json = """
        {
          "predicted_recovery_range": [110, -10],
          "predicted_zone": "  READY ",
          "explanation": "stable",
          "confidence_score": 2.0
        }
        """

        let response = try JSONDecoder().decode(
            PredictiveScenarioResponse.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(response.predictedRecoveryRange, [0, 100])
        XCTAssertEqual(response.predictedZone, .ready)
        XCTAssertEqual(response.explanation, "stable")
        XCTAssertEqual(response.confidenceScore, 1.0)
    }

    func testPredictiveScenarioResponseFallsBackToPredictedScoreAndDerivedZone() throws {
        let json = """
        {
          "predicted_score": 20,
          "predicted_zone": "not_a_zone",
          "confidence": -5
        }
        """

        let response = try JSONDecoder().decode(
            PredictiveScenarioResponse.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(response.predictedRecoveryRange, [15, 25])
        XCTAssertEqual(response.predictedZone, .critical)
        XCTAssertEqual(response.explanation, "")
        XCTAssertEqual(response.confidenceScore, 0.0)
    }

    func testPredictiveScenarioResponseDefaultsWhenFieldsMissing() throws {
        let response = try JSONDecoder().decode(
            PredictiveScenarioResponse.self,
            from: Data("{}".utf8)
        )
        XCTAssertEqual(response.predictedRecoveryRange, [45, 55])
        XCTAssertEqual(response.predictedZone, .ready)
        XCTAssertEqual(response.confidenceScore, 0.5)
    }
}
