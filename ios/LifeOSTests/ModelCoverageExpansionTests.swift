import Foundation
import XCTest
@testable import LifeOS

final class ModelCoverageExpansionTests: XCTestCase {

    func testOnboardingAndPrivacyModelDefaultsAndComputedFlags() {
        let userId = UUID()

        let notStarted = OnboardingState(userId: userId, step: .notStarted)
        XCTAssertFalse(notStarted.isComplete)
        XCTAssertFalse(notStarted.hasPassedHealthKit)

        let hkSkipped = OnboardingState(userId: userId, step: .healthkitSkipped)
        XCTAssertTrue(hkSkipped.hasPassedHealthKit)

        let completed = OnboardingState(userId: userId, step: .onboardingComplete)
        XCTAssertTrue(completed.isComplete)
        XCTAssertTrue(completed.hasPassedHealthKit)

        let insufficient = UserBaseline(userId: userId, dataDaysAvailable: 4, baselineConfidence: 0.9)
        XCTAssertFalse(insufficient.hasSufficientData)

        let lowConfidence = UserBaseline(userId: userId, dataDaysAvailable: 10, baselineConfidence: 0.2)
        XCTAssertFalse(lowConfidence.hasSufficientData)

        let sufficient = UserBaseline(userId: userId, dataDaysAvailable: 10, baselineConfidence: 0.7)
        XCTAssertTrue(sufficient.hasSufficientData)

        let settings = PrivacySettings(userId: userId)
        XCTAssertTrue(settings.menstrualLocalOnly)
        XCTAssertTrue(settings.medicalScanLocalOnly)
        XCTAssertFalse(settings.cloudBackupEnabled)
        XCTAssertFalse(settings.vectorOptIn)
        XCTAssertFalse(settings.analyticsConsent)
        XCTAssertTrue(settings.cloudOcrEnabled)
    }

    func testTrainingModelInitializersAndSafeACWR() {
        let userId = UUID()
        let session = WorkoutSession(
            userId: userId,
            startedAt: Date(),
            sessionDate: "2026-02-24",
            source: .manual
        )
        XCTAssertEqual(session.userId, userId)
        XCTAssertEqual(session.source, .manual)

        let exercise = WorkoutExercise(sessionId: session.id, orderInSession: 2)
        XCTAssertEqual(exercise.sessionId, session.id)
        XCTAssertEqual(exercise.orderInSession, 2)

        let set = WorkoutSet(exerciseEntryId: exercise.id, userId: userId, setNumber: 1)
        XCTAssertEqual(set.exerciseEntryId, exercise.id)
        XCTAssertFalse(set.isWarmup)
        XCTAssertFalse(set.isFailure)
        XCTAssertFalse(set.isDropset)

        let catalog = ExerciseCatalogEntry(name: "Squat", category: .strength)
        XCTAssertTrue(catalog.primaryMuscles.isEmpty)
        XCTAssertFalse(catalog.unilateral)
        XCTAssertFalse(catalog.isCustom)

        let plan = TrainingPlan(
            userId: userId,
            name: "Plan A",
            goal: .hypertrophy,
            planJson: Data("{}".utf8)
        )
        XCTAssertEqual(plan.status, .active)
        XCTAssertEqual(plan.currentWeek, 1)
        XCTAssertFalse(plan.aiGenerated)

        let planSession = TrainingPlanSession(
            trainingPlanId: plan.id,
            userId: userId,
            plannedDate: "2026-02-24",
            sessionType: .strength
        )
        XCTAssertEqual(planSession.status, .planned)
        XCTAssertEqual(planSession.sessionType, .strength)

        let load = TrainingLoad(userId: userId, date: "2026-02-24")
        XCTAssertEqual(load.workoutCount, 0)
        XCTAssertEqual(load.zone1Minutes, 0)
        XCTAssertEqual(load.zone5Minutes, 0)

        XCTAssertNil(TrainingLoad.safeACWR(acuteLoad7d: 100, chronicLoad28d: 90, daysOfData: 10))
        XCTAssertNil(TrainingLoad.safeACWR(acuteLoad7d: 100, chronicLoad28d: 0, daysOfData: 30))
        let safeAcwr = TrainingLoad.safeACWR(acuteLoad7d: 84, chronicLoad28d: 70, daysOfData: 30)
        XCTAssertEqual(safeAcwr ?? 0, 1.2, accuracy: 0.0001)
    }

    func testNutritionModelInitializersAndDerivedFields() {
        let userId = UUID()
        var log = FoodLog(
            userId: userId,
            loggedDate: "2026-02-24",
            inputMethod: .manual,
            calories: 500,
            proteinG: 30,
            fatG: 15,
            carbsG: 60
        )
        XCTAssertFalse(log.preWorkout)
        XCTAssertFalse(log.postWorkout)
        XCTAssertFalse(log.needsReview)
        XCTAssertFalse(log.userCorrected)
        XCTAssertFalse(log.syncedToVectorDb)
        XCTAssertFalse(log.requiresReview)

        log.aiConfidence = 0.4
        XCTAssertTrue(log.requiresReview)
        log.applyReviewGate()
        XCTAssertTrue(log.needsReview)

        let item = FoodItem(
            foodLogId: log.id,
            userId: userId,
            name: "Chicken",
            weightG: 150,
            calories: 240,
            proteinG: 35,
            fatG: 4,
            carbsG: 0
        )
        XCTAssertFalse(item.detectedByAi)
        XCTAssertFalse(item.userAdjusted)

        let target = DailyNutritionTarget(userId: userId, date: "2026-02-24")
        XCTAssertEqual(target.userId, userId)

        let catalog = FoodCatalogItem(
            provider: .usda,
            name: "Apple",
            caloriesPer100g: 52,
            proteinPer100g: 0.3,
            fatPer100g: 0.2,
            carbsPer100g: 14
        )
        XCTAssertEqual(catalog.provider, .usda)

        let userFood = UserFood(
            userId: userId,
            name: "Oats",
            caloriesPer100g: 389,
            proteinPer100g: 16.9,
            fatPer100g: 6.9,
            carbsPer100g: 66.3
        )
        XCTAssertEqual(userFood.userId, userId)

        let favorite = UserFoodFavorite(userId: userId, refType: .custom, refId: userFood.id)
        XCTAssertEqual(favorite.refType, .custom)

        let batch = BatchRecipe(
            userId: userId,
            name: "Chili",
            totalWeightG: 1000,
            totalCalories: 1800,
            totalProteinG: 120,
            totalFatG: 60,
            totalCarbsG: 180
        )
        XCTAssertFalse(batch.archived)
        XCTAssertEqual(batch.timesUsed, 0)
        XCTAssertEqual(batch.caloriesPer100g ?? 0, 180, accuracy: 0.0001)
        XCTAssertEqual(batch.derivedProteinPer100g, 12, accuracy: 0.0001)

        let zeroWeightBatch = BatchRecipe(
            userId: userId,
            name: "Zero",
            totalWeightG: 0,
            totalCalories: 100,
            totalProteinG: 10,
            totalFatG: 10,
            totalCarbsG: 10
        )
        XCTAssertNil(zeroWeightBatch.caloriesPer100g)
        XCTAssertEqual(zeroWeightBatch.derivedCaloriesPer100g, 0)
        XCTAssertEqual(zeroWeightBatch.derivedFatPer100g, 0)
        XCTAssertEqual(zeroWeightBatch.derivedCarbsPer100g, 0)

        let ingredient = BatchRecipeIngredient(
            batchRecipeId: batch.id,
            name: "Beans",
            weightG: 200,
            calories: 220,
            proteinG: 15,
            fatG: 1,
            carbsG: 40
        )
        XCTAssertEqual(ingredient.sortOrder, 0)

        let template = MealTemplate(
            userId: userId,
            name: "Breakfast",
            templateItems: Data("[]".utf8),
            calories: 420,
            proteinG: 25,
            fatG: 14,
            carbsG: 48
        )
        XCTAssertFalse(template.archived)
        XCTAssertEqual(template.timesUsed, 0)
    }

    func testHealthModelComputedPropertiesAndDefaults() {
        let userId = UUID()

        var wellness = WellnessCheck(userId: userId, date: "2026-02-24")
        XCTAssertFalse(wellness.feelingIll)
        XCTAssertNil(wellness.derivedPss4Total)
        wellness.pss4Q1 = 2
        wellness.pss4Q2 = 1
        wellness.pss4Q3 = 4
        wellness.pss4Q4 = 3
        XCTAssertEqual(wellness.derivedPss4Total, 8)
        wellness.refreshPss4Total()
        XCTAssertEqual(wellness.pss4Total, 8)

        let bodyComp = BodyComposition(userId: userId, weightKg: 80)
        XCTAssertEqual(bodyComp.weightKg, 80)
        XCTAssertFalse(bodyComp.userCorrected)

        let hydration = HydrationLog(userId: userId, loggedDate: "2026-02-24", waterMl: 600)
        XCTAssertEqual(hydration.source, .manual)
        XCTAssertEqual(hydration.waterMl, 600)

        var scan = MedicalScan(userId: userId, scanType: .bloodTest)
        XCTAssertEqual(scan.status, .pending)
        XCTAssertFalse(scan.requiresReview)
        XCTAssertEqual(ScanType(normalizedRawValue: "bloodwork"), .bloodTest)
        XCTAssertEqual(ScanType(normalizedRawValue: "blood_test"), .bloodTest)
        XCTAssertEqual(ScanType(normalizedRawValue: "urine"), .other)
        XCTAssertEqual(ScanType(normalizedRawValue: "body_composition"), .other)
        scan.aiConfidence = 0.3
        XCTAssertTrue(scan.requiresReview)
        scan.applyReviewGate()
        XCTAssertTrue(scan.needsReview)

        let measurement = HealthMeasurement(
            userId: userId,
            biomarkerName: "Vitamin D",
            value: 32,
            unit: "ng/mL"
        )
        XCTAssertEqual(measurement.sourceType, "scan")
        XCTAssertFalse(measurement.userCorrected)
        XCTAssertFalse(measurement.manuallyVerified)

        let disclaimer = String(localized: "clinician_disclaimer")
        let healthInsight = Insight(
            userId: userId,
            category: .health,
            title: "Trend",
            body: "Marker trend is improving",
            confidence: 0.4
        )
        XCTAssertTrue(healthInsight.needsReview)
        XCTAssertTrue(healthInsight.body.contains(disclaimer))
        XCTAssertEqual(healthInsight.bodyWithClinicianCaveat, healthInsight.body)

        let genericInsight = Insight(
            userId: userId,
            category: .nutrition,
            title: "Meal timing",
            body: "Keep protein at breakfast",
            confidence: 0.9
        )
        XCTAssertFalse(genericInsight.needsReview)
        XCTAssertEqual(genericInsight.bodyWithClinicianCaveat, genericInsight.body)

        var experiment = Experiment(
            userId: userId,
            title: "Caffeine timing",
            variable: "cutoff hour",
            metric: "sleep score",
            durationDays: 14
        )
        XCTAssertEqual(experiment.status, .design)
        XCTAssertEqual(experiment.primaryMetric, "sleep score")
        XCTAssertNil(experiment.aiAnalysisWithClinicianCaveat)
        experiment.aiAnalysis = "Late caffeine correlates with worse sleep"
        XCTAssertTrue(experiment.aiAnalysisWithClinicianCaveat?.contains(disclaimer) == true)
        experiment.aiAnalysis = "Late caffeine correlates with worse sleep \(disclaimer)"
        XCTAssertEqual(experiment.aiAnalysisWithClinicianCaveat, experiment.aiAnalysis)

        let measurementRow = ExperimentMeasurement(
            experimentId: experiment.id,
            userId: userId,
            date: "2026-02-24",
            value: 78,
            unit: "score",
            measurementPhase: .intervention,
            metricName: "sleep_score"
        )
        XCTAssertEqual(measurementRow.metricValue, 78)
        XCTAssertEqual(measurementRow.metricUnit, "score")
        XCTAssertEqual(measurementRow.measurementPhase, .intervention)
        XCTAssertTrue(measurementRow.protocolFollowed)
    }
}
