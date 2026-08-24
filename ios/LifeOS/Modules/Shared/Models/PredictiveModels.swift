import Foundation

/// Defines the type of predictive simulation scenario
enum PredictiveScenarioType: String, Codable, Sendable {
    case sleep
    case workout
    case nutrition
    case general
}

/// Request model for the predictive simulation edge function
struct PredictiveScenarioRequest: Codable, Sendable {
    /// The target date for the prediction (e.g., "2026-02-22")
    let targetDate: String
    /// The hypothetical scenario text (e.g., "If I sleep at 01:00 today after my workout")
    let scenarioText: String
    /// The category of the scenario
    let scenarioType: PredictiveScenarioType
    /// Current environmental context for simulation
    let environmentalContext: EnvironmentalContext?
    
    init(targetDate: String, scenarioText: String, scenarioType: PredictiveScenarioType, environmentalContext: EnvironmentalContext? = nil) {
        self.targetDate = targetDate
        self.scenarioText = scenarioText
        self.scenarioType = scenarioType
        self.environmentalContext = environmentalContext
    }
    
    enum CodingKeys: String, CodingKey {
        case targetDate = "target_date"
        case scenarioText = "scenario_text"
        case scenarioType = "scenario_type"
        case environmentalContext = "environmental_context"
    }
}

/// Response model from the predictive simulation edge function
struct PredictiveScenarioResponse: Decodable, Sendable {
    /// The lower and upper bounds of the predicted recovery score [min, max]
    let predictedRecoveryRange: [Int]
    /// The predicted zone based on the simulated score
    let predictedZone: RecoveryZone
    /// AI-generated text explaining the prediction based on historical N=1 data
    let explanation: String
    /// The confidence score of the simulation (0.0 - 1.0)
    let confidenceScore: Double

    init(
        predictedRecoveryRange: [Int],
        predictedZone: RecoveryZone,
        explanation: String,
        confidenceScore: Double
    ) {
        self.predictedRecoveryRange = predictedRecoveryRange
        self.predictedZone = predictedZone
        self.explanation = explanation
        self.confidenceScore = confidenceScore
    }

    enum CodingKeys: String, CodingKey {
        case predictedRecoveryRange = "predicted_recovery_range"
        case predictedZone = "predicted_zone"
        case explanation
        case confidenceScore = "confidence_score"
        case predictedScore = "predicted_score"
        case confidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let explicitRange = try container.decodeIfPresent([Int].self, forKey: .predictedRecoveryRange),
           explicitRange.count >= 2 {
            let lower = min(explicitRange[0], explicitRange[1])
            let upper = max(explicitRange[0], explicitRange[1])
            self.predictedRecoveryRange = [max(0, lower), min(100, upper)]
        } else {
            let score = try container.decodeIfPresent(Int.self, forKey: .predictedScore) ?? 50
            let clamped = min(max(score, 0), 100)
            self.predictedRecoveryRange = [max(0, clamped - 5), min(100, clamped + 5)]
        }

        let fallbackZone = RecoveryZone.from(score: Double(predictedRecoveryRange[0] + predictedRecoveryRange[1]) / 2.0)
        if let rawZone = try container.decodeIfPresent(String.self, forKey: .predictedZone)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           let zone = RecoveryZone(rawValue: rawZone) {
            self.predictedZone = zone
        } else {
            self.predictedZone = fallbackZone
        }

        self.explanation = try container.decodeIfPresent(String.self, forKey: .explanation) ?? ""
        let confidence = try container.decodeIfPresent(Double.self, forKey: .confidenceScore)
            ?? (try container.decodeIfPresent(Double.self, forKey: .confidence))
            ?? 0.5
        self.confidenceScore = min(max(confidence, 0), 1)
    }
}
