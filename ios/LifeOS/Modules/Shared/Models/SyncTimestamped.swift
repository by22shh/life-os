// MARK: - SyncTimestamped Conformances
// All synced models must expose `updatedAt` so the SyncEngine can extract
// the max server timestamp from pulled batches (P0 fix for watermark).

import Foundation

extension User: SyncTimestamped {}
extension NotificationSettings: SyncTimestamped {}
extension PhysiologicalState: SyncTimestamped {}
extension FoodLog: SyncTimestamped {}
extension FoodItem: SyncTimestamped {}
extension UserFood: SyncTimestamped {}
extension UserFoodFavorite: SyncTimestamped {}
extension MealTemplate: SyncTimestamped {}
extension BatchRecipe: SyncTimestamped {}
extension BatchRecipeIngredient: SyncTimestamped {}
extension WorkoutSession: SyncTimestamped {}
extension WorkoutExercise: SyncTimestamped {}
extension WorkoutSet: SyncTimestamped {}
extension TrainingPlan: SyncTimestamped {}
extension TrainingPlanSession: SyncTimestamped {}
extension TrainingLoad: SyncTimestamped {}
extension UserSupplement: SyncTimestamped {}
extension SupplementLog: SyncTimestamped {}
extension MedicalScan: SyncTimestamped {}
extension HealthMeasurement: SyncTimestamped {}
extension WellnessCheck: SyncTimestamped {}
extension BodyComposition: SyncTimestamped {}
extension HydrationLog: SyncTimestamped {}
extension Experiment: SyncTimestamped {}
extension ExperimentMeasurement: SyncTimestamped {}
extension Insight: SyncTimestamped {}
extension Recommendation: SyncTimestamped {}
extension WeeklyStrategyReport: SyncTimestamped {}
extension HealthMarkerCatalogEntry: SyncTimestamped {}
extension HealthDiagnosis: SyncTimestamped {}
extension VectorMemoryEntry: SyncTimestamped {}
extension TrainingTemplate: SyncTimestamped {}
extension DailyNutritionTarget: SyncTimestamped {}
extension FoodCatalogItem: SyncTimestamped {}
extension SupplementCatalogEntry: SyncTimestamped {}
extension ExerciseCatalogEntry: SyncTimestamped {}
extension OnboardingState: SyncTimestamped {}
extension UserBaseline: SyncTimestamped {}
extension PrivacySettings: SyncTimestamped {}
extension UserHealthFlags: SyncTimestamped {}
