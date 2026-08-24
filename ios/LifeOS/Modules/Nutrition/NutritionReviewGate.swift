import Foundation

enum NutritionReviewGate {
    static let confidenceThreshold = 0.65

    static func requiresEditFirst(method: NutritionLogMethod?, confidence: Double?) -> Bool {
        if let confidence {
            return confidence < confidenceThreshold
        }
        // Vision flow defaults to explicit review when confidence is unknown.
        return method == .photo
    }
}
