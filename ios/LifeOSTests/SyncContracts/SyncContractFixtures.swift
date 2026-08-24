import Foundation

enum SyncContractFixtures {
    private static let fixtureDirectory = "Fixtures/SyncContracts"

    private final class FixtureBundleToken {}

    private static func loadFixture(named fileStem: String) -> [String: Any] {
        let bundle = Bundle(for: FixtureBundleToken.self)

        if let url = bundle.url(forResource: fileStem, withExtension: "json", subdirectory: fixtureDirectory)
            ?? bundle.url(forResource: fileStem, withExtension: "json")
        {
            return parseFixture(at: url)
        }

        let fallbackURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("SyncContracts")
            .appendingPathComponent("\(fileStem).json")

        if FileManager.default.fileExists(atPath: fallbackURL.path) {
            return parseFixture(at: fallbackURL)
        }

        fatalError("Missing sync fixture: \(fileStem).json")
    }

    private static func parseFixture(at url: URL) -> [String: Any] {
        do {
            let data = try Data(contentsOf: url)
            let object = try JSONSerialization.jsonObject(with: data, options: [])
            guard let dictionary = object as? [String: Any] else {
                fatalError("Sync fixture must decode to JSON object: \(url.path)")
            }
            return dictionary
        } catch {
            fatalError("Failed to load sync fixture at \(url.path): \(error)")
        }
    }

    static func user() -> [String: Any] {
        loadFixture(named: "user")
    }

    static func userHealthFlags() -> [String: Any] {
        loadFixture(named: "user_health_flags")
    }

    static func notificationSettings() -> [String: Any] {
        loadFixture(named: "notification_settings")
    }

    static func physiologicalState() -> [String: Any] {
        loadFixture(named: "physiological_state")
    }

    static func trainingLoad() -> [String: Any] {
        loadFixture(named: "training_load")
    }

    static func foodLog() -> [String: Any] {
        loadFixture(named: "food_log")
    }

    static func foodItem() -> [String: Any] {
        loadFixture(named: "food_item")
    }

    static func userFood() -> [String: Any] {
        loadFixture(named: "user_food")
    }

    static func userFoodFavorite() -> [String: Any] {
        loadFixture(named: "user_food_favorite")
    }

    static func mealTemplate() -> [String: Any] {
        loadFixture(named: "meal_template")
    }

    static func batchRecipe() -> [String: Any] {
        loadFixture(named: "batch_recipe")
    }

    static func batchRecipeIngredient() -> [String: Any] {
        loadFixture(named: "batch_recipe_ingredient")
    }

    static func workoutSession() -> [String: Any] {
        loadFixture(named: "workout_session")
    }

    static func workoutExercise() -> [String: Any] {
        loadFixture(named: "workout_exercise")
    }

    static func workoutSet() -> [String: Any] {
        loadFixture(named: "workout_set")
    }

    static func trainingPlan() -> [String: Any] {
        loadFixture(named: "training_plan")
    }

    static func trainingPlanSession() -> [String: Any] {
        loadFixture(named: "training_plan_session")
    }

    static func userSupplement() -> [String: Any] {
        loadFixture(named: "user_supplement")
    }

    static func supplementLog() -> [String: Any] {
        loadFixture(named: "supplement_log")
    }

    static func sleepLog() -> [String: Any] {
        loadFixture(named: "sleep_log")
    }

    static func menstrualLog() -> [String: Any] {
        loadFixture(named: "menstrual_log")
    }

    static func medicalScan() -> [String: Any] {
        loadFixture(named: "medical_scan")
    }

    static func healthMeasurement() -> [String: Any] {
        loadFixture(named: "health_measurement")
    }

    static func healthDiagnosis() -> [String: Any] {
        loadFixture(named: "health_diagnosis")
    }

    static func dailyNutritionTarget() -> [String: Any] {
        loadFixture(named: "daily_nutrition_target")
    }

    static func foodCatalogItem() -> [String: Any] {
        loadFixture(named: "food_catalog_item")
    }

    static func supplementCatalog() -> [String: Any] {
        loadFixture(named: "supplement_catalog")
    }

    static func exerciseCatalog() -> [String: Any] {
        loadFixture(named: "exercise_catalog")
    }

    static func healthMarkerCatalog() -> [String: Any] {
        loadFixture(named: "health_marker_catalog")
    }

    static func wellnessCheck() -> [String: Any] {
        loadFixture(named: "wellness_check")
    }

    static func bodyComposition() -> [String: Any] {
        loadFixture(named: "body_composition")
    }

    static func hydrationLog() -> [String: Any] {
        loadFixture(named: "hydration_log")
    }

    static func experiment() -> [String: Any] {
        loadFixture(named: "experiment")
    }

    static func experimentMeasurement() -> [String: Any] {
        loadFixture(named: "experiment_measurement")
    }

    static func insight() -> [String: Any] {
        loadFixture(named: "insight")
    }

    static func recommendation() -> [String: Any] {
        loadFixture(named: "recommendation")
    }

    static func weeklyStrategyReport() -> [String: Any] {
        loadFixture(named: "weekly_strategy_report")
    }

    static func trainingTemplate() -> [String: Any] {
        loadFixture(named: "training_template")
    }

    static func onboardingState() -> [String: Any] {
        loadFixture(named: "onboarding_state")
    }

    static func userBaseline() -> [String: Any] {
        loadFixture(named: "user_baseline")
    }

    static func privacySettings() -> [String: Any] {
        loadFixture(named: "privacy_settings")
    }

    static func vectorMemory() -> [String: Any] {
        loadFixture(named: "vector_memory")
    }
}
