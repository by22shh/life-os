import XCTest
@testable import LifeOS

final class SyncTableRegistryTests: XCTestCase {
    func testSyncTableRegistryCoversEverySyncableTable() {
        XCTAssertEqual(
            Set(SyncTableRegistry.dateColumnSpecs.keys),
            Set(SyncableTable.allCases),
            "SyncTableRegistry must include every SyncableTable case."
        )
    }

    func testSyncTableRegistryUsesExpectedColumnsForDateWindowedTables() {
        XCTAssertEqual(SyncTableRegistry.dateColumnSpec(for: .foodLogs).column, "logged_date")
        XCTAssertEqual(SyncTableRegistry.dateColumnSpec(for: .hydrationLogs).column, "logged_date")
        XCTAssertEqual(SyncTableRegistry.dateColumnSpec(for: .sleepLogs).column, "sleep_date")
        XCTAssertEqual(SyncTableRegistry.dateColumnSpec(for: .workoutSessions).column, "session_date")
        XCTAssertEqual(SyncTableRegistry.dateColumnSpec(for: .supplementLogs).column, "taken_date")
        XCTAssertEqual(SyncTableRegistry.dateColumnSpec(for: .physiologicalStates).column, "date")
        XCTAssertEqual(SyncTableRegistry.dateColumnSpec(for: .dailyNutritionTargets).column, "date")
        XCTAssertEqual(SyncTableRegistry.dateColumnSpec(for: .trainingLoads).column, "date")
        XCTAssertEqual(SyncTableRegistry.dateColumnSpec(for: .wellnessChecks).column, "date")
    }
}

final class SyncModelContractTests: SyncContractTestCase {
    func testCoreContracts() throws {
        try runCases("Core", [
            makeCase("User", User.self, fixture: SyncContractFixtures.user()),
            makeCase("NotificationSettings", NotificationSettings.self, fixture: SyncContractFixtures.notificationSettings()),
            makeCase("UserHealthFlags", UserHealthFlags.self, fixture: SyncContractFixtures.userHealthFlags()),
            makeCase("PhysiologicalState", PhysiologicalState.self, fixture: SyncContractFixtures.physiologicalState()),
            makeCase("TrainingLoad", TrainingLoad.self, fixture: SyncContractFixtures.trainingLoad())
        ])
    }

    func testNutritionContracts() throws {
        try runCases("Nutrition", [
            makeCase("FoodLog", FoodLog.self, fixture: SyncContractFixtures.foodLog()),
            makeCase("FoodItem", FoodItem.self, fixture: SyncContractFixtures.foodItem()),
            makeCase("UserFood", UserFood.self, fixture: SyncContractFixtures.userFood()),
            makeCase("UserFoodFavorite", UserFoodFavorite.self, fixture: SyncContractFixtures.userFoodFavorite()),
            makeCase("MealTemplate", MealTemplate.self, fixture: SyncContractFixtures.mealTemplate()),
            makeCase("BatchRecipe", BatchRecipe.self, fixture: SyncContractFixtures.batchRecipe()),
            makeCase("BatchRecipeIngredient", BatchRecipeIngredient.self, fixture: SyncContractFixtures.batchRecipeIngredient()),
            makeCase("DailyNutritionTarget", DailyNutritionTarget.self, fixture: SyncContractFixtures.dailyNutritionTarget()),
            makeCase("FoodCatalogItem", FoodCatalogItem.self, fixture: SyncContractFixtures.foodCatalogItem())
        ])
    }

    func testTrainingContracts() throws {
        try runCases("Training", [
            makeCase("WorkoutSession", WorkoutSession.self, fixture: SyncContractFixtures.workoutSession()),
            makeCase("WorkoutExercise", WorkoutExercise.self, fixture: SyncContractFixtures.workoutExercise()),
            makeCase("WorkoutSet", WorkoutSet.self, fixture: SyncContractFixtures.workoutSet()),
            makeCase("TrainingPlan", TrainingPlan.self, fixture: SyncContractFixtures.trainingPlan()),
            makeCase("TrainingPlanSession", TrainingPlanSession.self, fixture: SyncContractFixtures.trainingPlanSession()),
            makeCase("ExerciseCatalogEntry", ExerciseCatalogEntry.self, fixture: SyncContractFixtures.exerciseCatalog()),
            makeCase("TrainingTemplate", TrainingTemplate.self, fixture: SyncContractFixtures.trainingTemplate())
        ])
    }

    func testSupplementsContracts() throws {
        try runCases("Supplements", [
            makeCase("UserSupplement", UserSupplement.self, fixture: SyncContractFixtures.userSupplement()),
            makeCase("SupplementLog", SupplementLog.self, fixture: SyncContractFixtures.supplementLog()),
            makeCase("SupplementCatalogEntry", SupplementCatalogEntry.self, fixture: SyncContractFixtures.supplementCatalog())
        ])
    }

    func testSleepAndCycleContracts() throws {
        try runCases("SleepCycle", [
            makeCase("SleepLog", SleepLog.self, fixture: SyncContractFixtures.sleepLog()),
            makeCase("MenstrualLog", MenstrualLog.self, fixture: SyncContractFixtures.menstrualLog())
        ])
    }

    func testHealthContracts() throws {
        try runCases("Health", [
            makeCase("WellnessCheck", WellnessCheck.self, fixture: SyncContractFixtures.wellnessCheck()),
            makeCase("BodyComposition", BodyComposition.self, fixture: SyncContractFixtures.bodyComposition()),
            makeCase("HydrationLog", HydrationLog.self, fixture: SyncContractFixtures.hydrationLog()),
            makeCase("MedicalScan", MedicalScan.self, fixture: SyncContractFixtures.medicalScan()),
            makeCase("HealthMeasurement", HealthMeasurement.self, fixture: SyncContractFixtures.healthMeasurement()),
            makeCase("HealthDiagnosis", HealthDiagnosis.self, fixture: SyncContractFixtures.healthDiagnosis()),
            makeCase("HealthMarkerCatalogEntry", HealthMarkerCatalogEntry.self, fixture: SyncContractFixtures.healthMarkerCatalog())
        ])
    }

    func testAIContracts() throws {
        try runCases("AI", [
            makeCase("Experiment", Experiment.self, fixture: SyncContractFixtures.experiment()),
            makeCase("ExperimentMeasurement", ExperimentMeasurement.self, fixture: SyncContractFixtures.experimentMeasurement()),
            makeCase("Insight", Insight.self, fixture: SyncContractFixtures.insight()),
            makeCase("Recommendation", Recommendation.self, fixture: SyncContractFixtures.recommendation()),
            makeCase("WeeklyStrategyReport", WeeklyStrategyReport.self, fixture: SyncContractFixtures.weeklyStrategyReport()),
            makeCase("VectorMemoryEntry", VectorMemoryEntry.self, fixture: SyncContractFixtures.vectorMemory())
        ])
    }

    func testOnboardingAndPrivacyContracts() throws {
        try runCases("OnboardingPrivacy", [
            makeCase("OnboardingState", OnboardingState.self, fixture: SyncContractFixtures.onboardingState()),
            makeCase("UserBaseline", UserBaseline.self, fixture: SyncContractFixtures.userBaseline()),
            makeCase("PrivacySettings", PrivacySettings.self, fixture: SyncContractFixtures.privacySettings())
        ])
    }
}

final class SyncFixtureContractGateTests: XCTestCase {
    private let canonicalStatuses: Set<String> = [
        "critical_low",
        "low",
        "optimal",
        "high",
        "critical_high",
    ]

    private let requiredHealthMeasurementKeys: Set<String> = [
        "id",
        "user_id",
        "created_at",
        "updated_at",
        "marker_id",
        "value",
        "unit",
        "measured_at",
        "source_scan_id",
        "source_type",
        "confidence",
        "manually_verified",
    ]

    private let forbiddenHealthMeasurementKeys: Set<String> = [
        "medical_scan_id",
        "biomarker_name",
        "measured_date",
        "ai_confidence",
        "user_corrected",
    ]

    func testHealthMeasurementFixtureUsesCanonicalServerShape() throws {
        let fixture = SyncContractFixtures.healthMeasurement()
        assertCanonicalHealthMeasurementShape(fixture)
    }

    func testHealthMeasurementFixtureRoundTripSanitizesToCanonicalServerShape() async throws {
        let fixture = SyncContractFixtures.healthMeasurement()
        let sourceData = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])
        let measurement = try decodeHealthMeasurementFixture(from: sourceData)
        let encoded = try JSONEncoder.supabase.encode(measurement)

        let manager = try DatabaseManager.inMemory()
        let syncEngine = SyncEngine(dbQueue: manager.dbQueue)
        let sanitized = await syncEngine._testSanitizeOutboundBody(
            encoded,
            path: "rest/v1/health_measurements"
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sanitized) as? [String: Any])

        assertCanonicalHealthMeasurementShape(object)
    }

    private func assertCanonicalHealthMeasurementShape(
        _ object: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let missingKeys = requiredHealthMeasurementKeys.subtracting(object.keys)
        XCTAssertTrue(
            missingKeys.isEmpty,
            "health_measurement fixture is missing canonical keys: \(missingKeys.sorted())",
            file: file,
            line: line
        )

        let legacyKeys = forbiddenHealthMeasurementKeys.intersection(object.keys)
        XCTAssertTrue(
            legacyKeys.isEmpty,
            "health_measurement fixture still contains legacy keys: \(legacyKeys.sorted())",
            file: file,
            line: line
        )

        XCTAssertTrue(
            (object["measured_at"] as? String)?
                .range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
            "health_measurement must use date-only measured_at",
            file: file,
            line: line
        )

        if let status = object["status"] as? String {
            XCTAssertTrue(
                canonicalStatuses.contains(status),
                "health_measurement status must be canonical, got \(status)",
                file: file,
                line: line
            )
        }
    }

    private func decodeHealthMeasurementFixture(from data: Data) throws -> HealthMeasurement {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { nestedDecoder in
            let container = try nestedDecoder.singleValueContainer()
            let rawValue = try container.decode(String.self)

            if let parsed = ISO8601DateFormatter.supabaseDate(from: rawValue) {
                return parsed
            }

            let noFraction = ISO8601DateFormatter()
            noFraction.formatOptions = [.withInternetDateTime]
            if let parsed = noFraction.date(from: rawValue) {
                return parsed
            }

            if let parsed = HealthMeasurement.dateOnlyDate(from: rawValue) {
                return parsed
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unparseable date fixture value: \(rawValue)"
            )
        }
        return try decoder.decode(HealthMeasurement.self, from: data)
    }
}
