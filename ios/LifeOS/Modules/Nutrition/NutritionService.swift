// MARK: - Nutrition Service
// Handles data persistence and sync queuing for Nutrition module.

import Foundation
import GRDB

protocol NutritionHistoryAPIClient: Sendable {
    func fetchHistoricalFoodLogs(
        orderBy: String,
        ascending: Bool,
        limit: Int,
        offset: Int,
        exactMatch: [String: String]
    ) async throws -> [FoodLog]
}

protocol NutritionMealManaging: Sendable {
    func persist(log: FoodLog, detectedItems: [NutritionDraftCandidateItem]) async throws
    func persist(log: FoodLog, items: [FoodItem]) async throws
    func loadMealDetail(id: UUID, preferRemote: Bool) async throws -> NutritionMealDetail?
    func updateMeal(_ update: NutritionMealUpdateDraft) async throws
    func deleteMeal(id: UUID) async throws -> Date
    func undoDeleteMeal(id: UUID) async throws
}

protocol NutritionMealDetailAPIClient: Sendable {
    func fetchMealDetail(id: UUID) async throws -> NutritionMealRemoteDetailResponse
}

protocol NutritionMealTemplateManaging: Sendable {
    func loadMealTemplates(includeArchived: Bool, limit: Int?, preferRemote: Bool) async throws -> [NutritionMealTemplateSummary]
    func loadMealTemplateDetail(id: UUID, preferRemote: Bool) async throws -> NutritionMealTemplateDetail?
    func createMealTemplate(_ draft: NutritionMealTemplateCreateDraft) async throws -> UUID
    func updateMealTemplate(_ update: NutritionMealTemplateUpdateDraft) async throws
    func setMealTemplateArchived(id: UUID, archived: Bool) async throws
    func applyMealTemplate(
        id: UUID,
        targetDay: String,
        loggedAt: Date,
        context: MealContext?
    ) async throws -> NutritionMealTemplateApplicationResult
}

protocol NutritionMealTemplateListAPIClient: Sendable {
    func fetchMealTemplates() async throws -> NutritionMealTemplateListResponse
}

protocol NutritionMealTemplateDetailAPIClient: Sendable {
    func fetchMealTemplateDetail(id: UUID) async throws -> NutritionMealTemplateRemoteDetailResponse
}

protocol NutritionBatchRecipeManaging: Sendable {
    func loadBatchRecipes(includeArchived: Bool, limit: Int?, preferRemote: Bool) async throws -> [NutritionBatchRecipeSummary]
    func loadBatchRecipeDetail(id: UUID, preferRemote: Bool) async throws -> NutritionBatchRecipeDetail?
    func createBatchRecipe(_ draft: NutritionBatchRecipeDraft) async throws -> UUID
    func updateBatchRecipe(_ draft: NutritionBatchRecipeDraft) async throws
    func setBatchRecipeArchived(id: UUID, archived: Bool) async throws
    func duplicateBatchRecipe(id: UUID, cookedAt: String?) async throws -> NutritionBatchRecipeDuplicateResult
    func logBatchPortion(_ draft: NutritionBatchPortionLogDraft) async throws -> NutritionBatchPortionLogResult
}

protocol NutritionBatchRecipeListAPIClient: Sendable {
    func fetchBatchRecipes(status: String, limit: Int?) async throws -> NutritionBatchRecipeListResponse
}

protocol NutritionBatchRecipeDetailAPIClient: Sendable {
    func fetchBatchRecipeDetail(id: UUID) async throws -> NutritionBatchRecipeRemoteDetailResponse
}

struct NutritionMealDetail: Equatable, Sendable {
    var log: FoodLog
    var items: [FoodItem]
}

struct NutritionMealTemplateItem: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var brand: String?
    var barcode: String?
    var catalogItemId: UUID?
    var userFoodId: UUID?
    var batchRecipeId: UUID?
    var weightG: Double
    var calories: Double
    var proteinG: Double
    var fatG: Double
    var carbsG: Double
    var fiberG: Double?
    var confidence: Double?

    init(
        id: UUID = UUID(),
        name: String,
        brand: String? = nil,
        barcode: String? = nil,
        catalogItemId: UUID? = nil,
        userFoodId: UUID? = nil,
        batchRecipeId: UUID? = nil,
        weightG: Double,
        calories: Double,
        proteinG: Double,
        fatG: Double,
        carbsG: Double,
        fiberG: Double? = nil,
        confidence: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.brand = brand
        self.barcode = barcode
        self.catalogItemId = catalogItemId
        self.userFoodId = userFoodId
        self.batchRecipeId = batchRecipeId
        self.weightG = weightG
        self.calories = calories
        self.proteinG = proteinG
        self.fatG = fatG
        self.carbsG = carbsG
        self.fiberG = fiberG
        self.confidence = confidence
    }
}

struct NutritionMealTemplateSummary: Decodable, Equatable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let mealType: MealType?
    let calories: Double
    let proteinG: Double
    let fatG: Double
    let carbsG: Double
    let fiberG: Double?
    let timesUsed: Int
    let lastUsedAt: Date?
    let archived: Bool
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case mealType = "meal_type"
        case calories
        case proteinG = "protein_g"
        case fatG = "fat_g"
        case carbsG = "carbs_g"
        case fiberG = "fiber_g"
        case timesUsed = "times_used"
        case lastUsedAt = "last_used_at"
        case archived
        case updatedAt = "updated_at"
    }
}

struct NutritionMealTemplateDetail: Equatable, Sendable {
    var template: MealTemplate
    var items: [NutritionMealTemplateItem]
}

struct NutritionBatchMacroSnapshot: Codable, Equatable, Sendable {
    let weightG: Double
    let calories: Double
    let proteinG: Double
    let fatG: Double
    let carbsG: Double
    let fiberG: Double?

    enum CodingKeys: String, CodingKey {
        case weightG = "weight_g"
        case calories
        case proteinG = "protein_g"
        case fatG = "fat_g"
        case carbsG = "carbs_g"
        case fiberG = "fiber_g"
    }
}

struct NutritionBatchRecipeSummary: Decodable, Equatable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let cookedAt: String?
    let totalWeightG: Double
    let consumedWeightG: Double
    let weightRemainingG: Double
    let totalPortions: Int?
    let portionsRemaining: Double?
    let totalCalories: Double
    let totalProteinG: Double
    let totalFatG: Double
    let totalCarbsG: Double
    let totalFiberG: Double?
    let caloriesPer100g: Double?
    let proteinPer100g: Double?
    let fatPer100g: Double?
    let carbsPer100g: Double?
    let archived: Bool
    let timesUsed: Int
    let lastUsedAt: Date?
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case cookedAt = "cooked_at"
        case totalWeightG = "total_weight_g"
        case consumedWeightG = "consumed_weight_g"
        case weightRemainingG = "weight_remaining_g"
        case totalPortions = "total_portions"
        case portionsRemaining = "portions_remaining"
        case totalCalories = "total_calories"
        case totalProteinG = "total_protein_g"
        case totalFatG = "total_fat_g"
        case totalCarbsG = "total_carbs_g"
        case totalFiberG = "total_fiber_g"
        case caloriesPer100g = "calories_per_100g"
        case proteinPer100g = "protein_per_100g"
        case fatPer100g = "fat_per_100g"
        case carbsPer100g = "carbs_per_100g"
        case archived
        case timesUsed = "times_used"
        case lastUsedAt = "last_used_at"
        case updatedAt = "updated_at"
    }

    var per100g: NutritionBatchMacroSnapshot {
        NutritionBatchMacroSnapshot(
            weightG: 100,
            calories: caloriesPer100g ?? (totalWeightG > 0 ? totalCalories * 100 / totalWeightG : 0),
            proteinG: proteinPer100g ?? (totalWeightG > 0 ? totalProteinG * 100 / totalWeightG : 0),
            fatG: fatPer100g ?? (totalWeightG > 0 ? totalFatG * 100 / totalWeightG : 0),
            carbsG: carbsPer100g ?? (totalWeightG > 0 ? totalCarbsG * 100 / totalWeightG : 0),
            fiberG: totalWeightG > 0 ? totalFiberG.map { $0 * 100 / totalWeightG } : nil
        )
    }

    var perPortion: NutritionBatchMacroSnapshot? {
        guard let totalPortions,
              totalPortions > 0 else {
            return nil
        }
        let weight = totalWeightG / Double(totalPortions)
        return NutritionBatchMacroSnapshot(
            weightG: weight,
            calories: totalCalories / Double(totalPortions),
            proteinG: totalProteinG / Double(totalPortions),
            fatG: totalFatG / Double(totalPortions),
            carbsG: totalCarbsG / Double(totalPortions),
            fiberG: totalFiberG.map { $0 / Double(totalPortions) }
        )
    }
}

struct NutritionBatchRecipeDetail: Equatable, Sendable {
    var recipe: BatchRecipe
    var ingredients: [BatchRecipeIngredient]
    var consumedWeightG: Double
    var weightRemainingG: Double
    var portionsRemaining: Double?

    var per100g: NutritionBatchMacroSnapshot {
        NutritionBatchMacroSnapshot(
            weightG: 100,
            calories: recipe.caloriesPer100g ?? recipe.derivedCaloriesPer100g,
            proteinG: recipe.proteinPer100g ?? recipe.derivedProteinPer100g,
            fatG: recipe.fatPer100g ?? recipe.derivedFatPer100g,
            carbsG: recipe.carbsPer100g ?? recipe.derivedCarbsPer100g,
            fiberG: recipe.totalWeightG > 0 ? recipe.totalFiberG.map { $0 * 100 / recipe.totalWeightG } : nil
        )
    }

    var perPortion: NutritionBatchMacroSnapshot? {
        guard let totalPortions = recipe.totalPortions,
              totalPortions > 0 else {
            return nil
        }
        let weight = recipe.weightPerPortionG ?? (recipe.totalWeightG / Double(totalPortions))
        return NutritionBatchMacroSnapshot(
            weightG: weight,
            calories: recipe.totalCalories / Double(totalPortions),
            proteinG: recipe.totalProteinG / Double(totalPortions),
            fatG: recipe.totalFatG / Double(totalPortions),
            carbsG: recipe.totalCarbsG / Double(totalPortions),
            fiberG: recipe.totalFiberG.map { $0 / Double(totalPortions) }
        )
    }
}

struct NutritionBatchRecipeDraftIngredient: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var brand: String?
    var barcode: String?
    var catalogItemId: UUID?
    var userFoodId: UUID?
    var weightG: Double
    var calories: Double
    var proteinG: Double
    var fatG: Double
    var carbsG: Double
    var fiberG: Double?

    init(
        id: UUID = UUID(),
        name: String,
        brand: String? = nil,
        barcode: String? = nil,
        catalogItemId: UUID? = nil,
        userFoodId: UUID? = nil,
        weightG: Double,
        calories: Double,
        proteinG: Double,
        fatG: Double,
        carbsG: Double,
        fiberG: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.brand = brand
        self.barcode = barcode
        self.catalogItemId = catalogItemId
        self.userFoodId = userFoodId
        self.weightG = weightG
        self.calories = calories
        self.proteinG = proteinG
        self.fatG = fatG
        self.carbsG = carbsG
        self.fiberG = fiberG
    }
}

struct NutritionBatchRecipeDraft: Sendable {
    var id: UUID
    var name: String
    var description: String?
    var cookedAt: String?
    var totalWeightG: Double
    var totalPortions: Int?
    var ingredients: [NutritionBatchRecipeDraftIngredient]
    var archived: Bool

    init(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        cookedAt: String? = nil,
        totalWeightG: Double,
        totalPortions: Int? = nil,
        ingredients: [NutritionBatchRecipeDraftIngredient],
        archived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.cookedAt = cookedAt
        self.totalWeightG = totalWeightG
        self.totalPortions = totalPortions
        self.ingredients = ingredients
        self.archived = archived
    }
}

struct NutritionBatchPortionLogDraft: Sendable {
    var batchId: UUID
    var targetDay: String
    var loggedAt: Date
    var mealType: MealType?
    var context: MealContext?
    var portionWeightG: Double
}

struct NutritionBatchPortionLogResult: Sendable {
    let foodLogId: UUID
    let foodItemId: UUID
    let batchId: UUID
    let weightRemainingG: Double
}

struct NutritionBatchRecipeDuplicateResult: Sendable {
    let batchId: UUID
    let name: String
}

struct NutritionMealUpdateDraft: Sendable {
    var id: UUID
    var loggedAt: Date
    var loggedDate: String
    var mealType: MealType?
    var context: MealContext?
    var userNotes: String?
    var items: [FoodItem]
}

struct NutritionMealTemplateCreateDraft: Sendable {
    var id: UUID
    var name: String
    var mealType: MealType?
    var items: [NutritionMealTemplateItem]
    var archived: Bool

    init(
        id: UUID = UUID(),
        name: String,
        mealType: MealType? = nil,
        items: [NutritionMealTemplateItem],
        archived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.mealType = mealType
        self.items = items
        self.archived = archived
    }
}

struct NutritionMealTemplateUpdateDraft: Sendable {
    var id: UUID
    var name: String
    var mealType: MealType?
    var items: [NutritionMealTemplateItem]
    var archived: Bool
}

struct NutritionMealRemoteDetailResponse: Decodable, Sendable {
    struct Macros: Decodable, Sendable {
        let calories: Double
        let proteinG: Double
        let fatG: Double
        let carbsG: Double
        let fiberG: Double?

        enum CodingKeys: String, CodingKey {
            case calories
            case proteinG = "protein_g"
            case fatG = "fat_g"
            case carbsG = "carbs_g"
            case fiberG = "fiber_g"
        }
    }

    struct Item: Decodable, Sendable {
        let id: UUID
        var createdAt: Date? = nil
        var updatedAt: Date? = nil
        let name: String
        let brand: String?
        let barcode: String?
        let catalogItemId: UUID?
        let userFoodId: UUID?
        let batchRecipeId: UUID?
        let weightG: Double
        let macros: Macros
        let confidence: Double?
        let detectedByAi: Bool
        let userAdjusted: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case name
            case brand
            case barcode
            case catalogItemId = "catalog_item_id"
            case userFoodId = "user_food_id"
            case batchRecipeId = "batch_recipe_id"
            case weightG = "weight_g"
            case macros
            case confidence
            case detectedByAi = "detected_by_ai"
            case userAdjusted = "user_adjusted"
        }
    }

    let id: UUID
    var createdAt: Date? = nil
    let loggedAt: Date
    let loggedDate: String
    let mealType: MealType?
    let context: MealContext?
    let inputMethod: NutritionInputMethod
    let macros: Macros
    let aiConfidence: Double?
    let userCorrected: Bool
    let userNotes: String?
    let items: [Item]
    var updatedAt: Date? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case loggedAt = "logged_at"
        case loggedDate = "logged_date"
        case mealType = "meal_type"
        case context
        case inputMethod = "input_method"
        case macros
        case aiConfidence = "ai_confidence"
        case userCorrected = "user_corrected"
        case userNotes = "user_notes"
        case items
        case updatedAt = "updated_at"
    }
}

struct NutritionMealTemplateListResponse: Decodable, Sendable {
    let templates: [NutritionMealTemplateSummary]
}

struct NutritionMealTemplateRemoteDetailResponse: Decodable, Sendable {
    let id: UUID
    let name: String
    let mealType: MealType?
    let templateItems: [NutritionMealTemplateItem]
    let calories: Double
    let proteinG: Double
    let fatG: Double
    let carbsG: Double
    let fiberG: Double?
    let timesUsed: Int
    let lastUsedAt: Date?
    let archived: Bool
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case mealType = "meal_type"
        case templateItems = "template_items"
        case calories
        case proteinG = "protein_g"
        case fatG = "fat_g"
        case carbsG = "carbs_g"
        case fiberG = "fiber_g"
        case timesUsed = "times_used"
        case lastUsedAt = "last_used_at"
        case archived
        case updatedAt = "updated_at"
    }
}

struct NutritionBatchRecipeListResponse: Decodable, Sendable {
    let results: [NutritionBatchRecipeSummary]
}

struct NutritionBatchRecipeRemoteDetailResponse: Decodable, Sendable {
    let id: UUID
    let name: String
    let description: String?
    let cookedAt: String?
    let totalWeightG: Double
    let consumedWeightG: Double
    let weightRemainingG: Double
    let totalPortions: Int?
    let portionsRemaining: Double?
    let totalCalories: Double
    let totalProteinG: Double
    let totalFatG: Double
    let totalCarbsG: Double
    let totalFiberG: Double?
    let caloriesPer100g: Double?
    let proteinPer100g: Double?
    let fatPer100g: Double?
    let carbsPer100g: Double?
    let archived: Bool
    let timesUsed: Int
    let lastUsedAt: Date?
    let updatedAt: Date
    let ingredients: [NutritionBatchRecipeDraftIngredient]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case cookedAt = "cooked_at"
        case totalWeightG = "total_weight_g"
        case consumedWeightG = "consumed_weight_g"
        case weightRemainingG = "weight_remaining_g"
        case totalPortions = "total_portions"
        case portionsRemaining = "portions_remaining"
        case totalCalories = "total_calories"
        case totalProteinG = "total_protein_g"
        case totalFatG = "total_fat_g"
        case totalCarbsG = "total_carbs_g"
        case totalFiberG = "total_fiber_g"
        case caloriesPer100g = "calories_per_100g"
        case proteinPer100g = "protein_per_100g"
        case fatPer100g = "fat_per_100g"
        case carbsPer100g = "carbs_per_100g"
        case archived
        case timesUsed = "times_used"
        case lastUsedAt = "last_used_at"
        case updatedAt = "updated_at"
        case ingredients
    }
}

private struct NutritionMealPatchPayload: Encodable {
    let loggedAt: Date
    let loggedDate: String
    let mealType: String?
    let context: String?
    let userNotes: String?
    let items: [NutritionMealPatchItemPayload]

    enum CodingKeys: String, CodingKey {
        case loggedAt = "logged_at"
        case loggedDate = "logged_date"
        case mealType = "meal_type"
        case context
        case userNotes = "user_notes"
        case items
    }
}

private struct NutritionMealTemplatePatchPayload: Encodable {
    let name: String
    let mealType: String?
    let templateItems: [NutritionMealTemplateItem]
    let calories: Double
    let proteinG: Double
    let fatG: Double
    let carbsG: Double
    let fiberG: Double?
    let archived: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case mealType = "meal_type"
        case templateItems = "template_items"
        case calories
        case proteinG = "protein_g"
        case fatG = "fat_g"
        case carbsG = "carbs_g"
        case fiberG = "fiber_g"
        case archived
    }
}

private struct NutritionMealTemplateCreatePayload: Encodable {
    let id: UUID
    let name: String
    let mealType: String?
    let templateItems: [NutritionMealTemplateItem]
    let calories: Double
    let proteinG: Double
    let fatG: Double
    let carbsG: Double
    let fiberG: Double?
    let archived: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case mealType = "meal_type"
        case templateItems = "template_items"
        case calories
        case proteinG = "protein_g"
        case fatG = "fat_g"
        case carbsG = "carbs_g"
        case fiberG = "fiber_g"
        case archived
    }
}

private struct NutritionMealTemplateArchivePayload: Encodable {
    let archived: Bool
}

private struct NutritionMealTemplateLogPayload: Encodable {
    let loggedAt: Date
    let loggedDate: String
    let mealType: String?
    let context: String?

    enum CodingKeys: String, CodingKey {
        case loggedAt = "logged_at"
        case loggedDate = "logged_date"
        case mealType = "meal_type"
        case context
    }
}

private struct NutritionBatchRecipeIngredientPayload: Encodable {
    let id: UUID
    let name: String
    let brand: String?
    let barcode: String?
    let catalogItemId: UUID?
    let userFoodId: UUID?
    let weightG: Double
    let macrosTotal: NutritionBatchMacroSnapshot

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case brand
        case barcode
        case catalogItemId = "catalog_item_id"
        case userFoodId = "user_food_id"
        case weightG = "weight_g"
        case macrosTotal = "macros_total"
    }
}

private struct NutritionBatchRecipePayload: Encodable {
    let id: UUID
    let name: String
    let description: String?
    let cookedAt: String?
    let totalWeightG: Double
    let totalPortions: Int?
    let ingredients: [NutritionBatchRecipeIngredientPayload]
    let archived: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case cookedAt = "cooked_at"
        case totalWeightG = "total_weight_g"
        case totalPortions = "total_portions"
        case ingredients
        case archived
    }
}

private struct NutritionBatchPortionLogPayload: Encodable {
    let foodLogId: UUID
    let foodItemId: UUID
    let loggedAt: Date
    let loggedDate: String
    let loggedTimezone: String
    let loggedUtcOffsetMinutes: Int
    let mealType: String?
    let context: String?
    let portionWeightG: Double
    let itemMacrosOverride: NutritionBatchMacroSnapshot

    enum CodingKeys: String, CodingKey {
        case foodLogId = "food_log_id"
        case foodItemId = "food_item_id"
        case loggedAt = "logged_at"
        case loggedDate = "logged_date"
        case loggedTimezone = "logged_timezone"
        case loggedUtcOffsetMinutes = "logged_utc_offset_minutes"
        case mealType = "meal_type"
        case context
        case portionWeightG = "portion_weight_g"
        case itemMacrosOverride = "item_macros_override"
    }
}

private struct NutritionBatchRecipeArchivePayload: Encodable {
    let archived: Bool
}

struct NutritionMealTemplateApplicationResult: Sendable {
    let foodLogId: UUID
    let templateName: String
    let itemCount: Int
}

private struct NutritionMealPatchItemPayload: Encodable {
    let id: UUID
    let name: String
    let brand: String?
    let barcode: String?
    let catalogItemId: UUID?
    let userFoodId: UUID?
    let batchRecipeId: UUID?
    let weightG: Double
    let calories: Double
    let proteinG: Double
    let fatG: Double
    let carbsG: Double
    let fiberG: Double?
    let confidence: Double?
    let detectedByAi: Bool
    let userAdjusted: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case brand
        case barcode
        case catalogItemId = "catalog_item_id"
        case userFoodId = "user_food_id"
        case batchRecipeId = "batch_recipe_id"
        case weightG = "weight_g"
        case calories
        case proteinG = "protein_g"
        case fatG = "fat_g"
        case carbsG = "carbs_g"
        case fiberG = "fiber_g"
        case confidence
        case detectedByAi = "detected_by_ai"
        case userAdjusted = "user_adjusted"
    }
}

actor NutritionService {
    private let dbQueue: DatabaseQueue
    private let timeZoneHistoryStore: TimeZoneHistoryStore
    private let detailAPIClient: any NutritionMealDetailAPIClient
    private let templateListAPIClient: any NutritionMealTemplateListAPIClient
    private let templateDetailAPIClient: any NutritionMealTemplateDetailAPIClient
    private let batchListAPIClient: any NutritionBatchRecipeListAPIClient
    private let batchDetailAPIClient: any NutritionBatchRecipeDetailAPIClient

    init(
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue,
        timeZoneHistoryStore: TimeZoneHistoryStore? = nil,
        detailAPIClient: any NutritionMealDetailAPIClient = APIClient(),
        templateListAPIClient: any NutritionMealTemplateListAPIClient = APIClient(),
        templateDetailAPIClient: any NutritionMealTemplateDetailAPIClient = APIClient(),
        batchListAPIClient: any NutritionBatchRecipeListAPIClient = APIClient(),
        batchDetailAPIClient: any NutritionBatchRecipeDetailAPIClient = APIClient()
    ) {
        self.dbQueue = dbQueue
        self.timeZoneHistoryStore = timeZoneHistoryStore ?? TimeZoneHistoryStore(dbQueue: dbQueue)
        self.detailAPIClient = detailAPIClient
        self.templateListAPIClient = templateListAPIClient
        self.templateDetailAPIClient = templateDetailAPIClient
        self.batchListAPIClient = batchListAPIClient
        self.batchDetailAPIClient = batchDetailAPIClient
    }

    /// Persists a food log and queues it for sync.
    /// - Parameter log: The FoodLog entry to save.
    /// - Throws: Database errors.
    func logMeal(_ log: FoodLog) async throws {
        let userId = try await resolvedUserId(fallback: log.userId)
        let normalizedLog = try await normalizedFoodLog(log, userId: userId)
        try await persistNewMeal(log: normalizedLog, items: [])
        await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
    }

    /// Fetches historical logs on-demand when the user scrolls beyond the 90-day active Sync Window.
    /// Data is pulled directly from the server for the specific date and cached locally.
    /// - Parameter date: The specific local date to fetch history for.
    func fetchHistoricalFoodLogs(
        for date: Date,
        apiClient: any NutritionHistoryAPIClient = APIClient()
    ) async throws -> [FoodLog] {
        // Calculate if the requested date is outside the 90 day window
        let now = Date()
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -90, to: now)!
        
        let targetDateStr = DateFormatting.dateOnlyString(from: date)
        
        // If the date is within the active Sync Window, return local data — no server call needed
        if date >= cutoffDate {
            return try await dbQueue.read { db in
                try FoodLog
                    .filter(Column("logged_date") == targetDateStr)
                    .order(Column("logged_at").asc)
                    .fetchAll(db)
            }
        }
        
        // Make targeted on-demand fetch using exact match to minimize payload
        let logs = try await apiClient.fetchHistoricalFoodLogs(
            orderBy: "logged_at",
            ascending: true,
            limit: 1000,
            offset: 0,
            exactMatch: ["logged_date": targetDateStr]
        )
        
        // Cache locally
        try await dbQueue.write { db in
            for log in logs {
                try log.save(db)
            }
        }

        await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()

        return logs
    }

    func persist(log: FoodLog, detectedItems: [NutritionDraftCandidateItem]) async throws {
        let userId = try await resolvedUserId(fallback: log.userId)
        let normalizedLog = try await normalizedFoodLog(log, userId: userId)
        let timestamp = Date()
        let items = detectedItems.compactMap {
            $0.makeFoodItem(foodLogId: normalizedLog.id, userId: normalizedLog.userId, timestamp: timestamp)
        }
        try await persist(log: normalizedLog, items: items)
    }

    func persist(log: FoodLog, items: [FoodItem]) async throws {
        let userId = try await resolvedUserId(fallback: log.userId)
        let normalizedLog = try await normalizedFoodLog(log, userId: userId)
        let normalizedItems = items.map { item in
            var normalizedItem = item
            normalizedItem.foodLogId = normalizedLog.id
            normalizedItem.userId = normalizedLog.userId
            return normalizedItem
        }
        try await persistNewMeal(log: normalizedLog, items: normalizedItems)
        await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
    }

    func loadMealDetail(id: UUID, preferRemote: Bool = true) async throws -> NutritionMealDetail? {
        let localDetail = try await loadLocalMealDetail(id: id)
        let hasCloudSession = await MainActor.run { AuthManager.activeHasCloudSession }
        let shouldFetchRemote = preferRemote && hasCloudSession

        guard shouldFetchRemote else {
            return localDetail
        }

        do {
            guard let remoteDetail = try await loadRemoteMealDetail(id: id, localDetail: localDetail) else {
                return localDetail
            }
            try await cacheMealDetail(remoteDetail)
            return try await loadLocalMealDetail(id: id)
        } catch {
            if localDetail == nil {
                throw error
            }
            return localDetail
        }
    }

    func updateMeal(_ update: NutritionMealUpdateDraft) async throws {
        try await dbQueue.write { db in
            var log = try Self.requireFoodLog(id: update.id, in: db)
            let now = Date()

            log.loggedAt = update.loggedAt
            log.loggedDate = update.loggedDate
            log.mealType = update.mealType
            log.context = update.context
            log.userNotes = Self.normalizedText(update.userNotes)
            log.updatedAt = now

            if !update.items.isEmpty {
                log.calories = update.items.reduce(0) { $0 + $1.calories }
                log.proteinG = update.items.reduce(0) { $0 + $1.proteinG }
                log.fatG = update.items.reduce(0) { $0 + $1.fatG }
                log.carbsG = update.items.reduce(0) { $0 + $1.carbsG }
                let totalFiber = update.items.reduce(0) { $0 + ($1.fiberG ?? 0) }
                log.fiberG = totalFiber > 0 ? totalFiber : nil
                log.userCorrected = true
                log.needsReview = false
                log.aiConfidence = nil
            }

            try log.update(db)

            try db.execute(
                sql: """
                    DELETE FROM food_items
                    WHERE food_log_id = ? OR food_log_id = ?
                    """,
                arguments: [update.id, update.id.uuidString]
            )

            let storedItems = update.items.enumerated().map { index, rawItem in
                Self.normalizedFoodItem(
                    rawItem,
                    foodLogId: log.id,
                    userId: log.userId,
                    fallbackCreatedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    updatedAt: now
                )
            }

            for item in storedItems {
                try item.insert(db)
            }

            let payload = NutritionMealPatchPayload(
                loggedAt: log.loggedAt,
                loggedDate: log.loggedDate,
                mealType: log.mealType?.rawValue,
                context: log.context?.rawValue,
                userNotes: log.userNotes,
                items: storedItems.map(Self.makePatchPayloadItem(_:))
            )

            var event = OutboxEvent(
                id: UUID(),
                httpMethod: .PATCH,
                path: "api-food-log/\(log.id.uuidString)",
                bodyJson: try JSONEncoder.supabase.encode(payload),
                priority: 110
            )
            event.headersJson = try Self.headersJson()
            event.dependsOn = Self.latestMutationDependency(for: log.id, in: db)
            try event.insert(db)
        }

        await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
    }

    func deleteMeal(id: UUID) async throws -> Date {
        let deletedAt = Date()
        try await dbQueue.write { db in
            var log = try Self.requireFoodLog(id: id, in: db)
            guard log.deletedAt == nil else {
                throw NutritionError.mealNotFound
            }

            log.deletedAt = deletedAt
            log.deletedReason = .userDeleted
            log.updatedAt = deletedAt
            try log.update(db)

            var event = OutboxEvent(
                id: UUID(),
                httpMethod: .DELETE,
                path: "api-food-log/\(id.uuidString)",
                bodyJson: Data("{}".utf8),
                priority: 120
            )
            event.headersJson = try Self.headersJson()
            event.dependsOn = Self.latestMutationDependency(for: id, in: db)
            try event.insert(db)
        }

        await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
        return deletedAt
    }

    func undoDeleteMeal(id: UUID) async throws {
        try await dbQueue.write { db in
            var log = try Self.requireFoodLog(id: id, in: db)
            guard let deletedAt = log.deletedAt else {
                throw NutritionError.mealNotFound
            }
            guard deletedAt >= Date().addingTimeInterval(-24 * 60 * 60) else {
                throw NutritionError.undoExpired
            }

            log.deletedAt = nil
            log.deletedReason = nil
            log.updatedAt = Date()
            try log.update(db)

            var event = OutboxEvent(
                id: UUID(),
                httpMethod: .POST,
                path: "api-food-log/\(id.uuidString)/undo",
                bodyJson: Data("{}".utf8),
                priority: 130
            )
            event.headersJson = try Self.headersJson()
            event.dependsOn = Self.latestMutationDependency(for: id, in: db)
            try event.insert(db)
        }

        await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
    }

    func loadMealTemplates(
        includeArchived: Bool = false,
        limit: Int? = nil,
        preferRemote: Bool = true
    ) async throws -> [NutritionMealTemplateSummary] {
        let localSummaries = try await loadLocalMealTemplates(includeArchived: includeArchived, limit: limit)
        let hasCloudSession = await MainActor.run { AuthManager.activeHasCloudSession }
        let shouldFetchRemote = preferRemote &&
            SupabaseConfig.isRuntimeConfigured &&
            hasCloudSession

        guard shouldFetchRemote else {
            return localSummaries
        }

        do {
            let response = try await templateListAPIClient.fetchMealTemplates()
            try await cacheMealTemplateSummaries(response.templates)
            return try await loadLocalMealTemplates(includeArchived: includeArchived, limit: limit)
        } catch {
            if !localSummaries.isEmpty {
                return localSummaries
            }
            throw error
        }
    }

    func loadMealTemplateDetail(
        id: UUID,
        preferRemote: Bool = true
    ) async throws -> NutritionMealTemplateDetail? {
        let localDetail = try await loadLocalMealTemplateDetail(id: id)
        let hasCloudSession = await MainActor.run { AuthManager.activeHasCloudSession }
        let shouldFetchRemote = preferRemote &&
            SupabaseConfig.isRuntimeConfigured &&
            hasCloudSession

        guard shouldFetchRemote else {
            return localDetail
        }

        if localDetail != nil,
           try await hasPendingTemplateMutation(for: id) {
            return localDetail
        }

        do {
            guard let remoteDetail = try await loadRemoteMealTemplateDetail(id: id, localDetail: localDetail) else {
                return localDetail
            }
            try await cacheMealTemplateDetail(remoteDetail)
            return try await loadLocalMealTemplateDetail(id: id) ?? remoteDetail
        } catch {
            if localDetail == nil {
                throw error
            }
            return localDetail
        }
    }

    func createMealTemplate(_ draft: NutritionMealTemplateCreateDraft) async throws -> UUID {
        let normalized = try Self.normalizedMealTemplateCreateDraft(draft)
        let payload = Self.makeMealTemplateCreatePayload(from: normalized)
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }

        try await dbQueue.write { db in
            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                throw SyncError.networkUnavailable
            }

            let template = Self.makeMealTemplate(from: normalized, userId: userId)
            try template.insert(db)

            var event = OutboxEvent(
                id: template.id,
                httpMethod: .POST,
                path: "api-nutrition-templates",
                bodyJson: try JSONEncoder.supabase.encode(payload),
                priority: 100
            )
            event.headersJson = try Self.headersJson()
            try event.insert(db)
        }

        try await verifyMealTemplatePersistence(for: normalized)
        await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
        return normalized.id
    }

    func updateMealTemplate(_ update: NutritionMealTemplateUpdateDraft) async throws {
        let normalizedName = Self.normalizedText(update.name) ?? ""
        guard !normalizedName.isEmpty else {
            throw NutritionError.invalidMealItem(reason: "Template name is required")
        }
        let normalizedItems = try Self.normalizedTemplateItems(update.items)
        guard !normalizedItems.isEmpty else {
            throw NutritionError.templateEmpty
        }

        let totals = Self.templateTotals(for: normalizedItems)
        let payload = NutritionMealTemplatePatchPayload(
            name: normalizedName,
            mealType: update.mealType?.rawValue,
            templateItems: normalizedItems,
            calories: totals.calories,
            proteinG: totals.protein,
            fatG: totals.fat,
            carbsG: totals.carbs,
            fiberG: totals.fiber,
            archived: update.archived
        )

        try await dbQueue.write { db in
            var template = try Self.requireMealTemplate(id: update.id, in: db)
            template.name = normalizedName
            template.mealType = update.mealType
            template.templateItems = try JSONEncoder.supabase.encode(normalizedItems)
            template.calories = totals.calories
            template.proteinG = totals.protein
            template.fatG = totals.fat
            template.carbsG = totals.carbs
            template.fiberG = totals.fiber
            template.archived = update.archived
            template.updatedAt = Date()
            try template.update(db)

            var event = OutboxEvent(
                id: UUID(),
                httpMethod: .PATCH,
                path: "api-nutrition-templates/\(template.id.uuidString)",
                bodyJson: try JSONEncoder.supabase.encode(payload),
                priority: 110
            )
            event.headersJson = try Self.headersJson()
            event.dependsOn = Self.latestTemplateMutationDependency(for: template.id, in: db)
            try event.insert(db)
        }
    }

    func setMealTemplateArchived(id: UUID, archived: Bool) async throws {
        try await dbQueue.write { db in
            var template = try Self.requireMealTemplate(id: id, in: db)
            template.archived = archived
            template.updatedAt = Date()
            try template.update(db)

            var event = OutboxEvent(
                id: UUID(),
                httpMethod: .PATCH,
                path: "api-nutrition-templates/\(id.uuidString)",
                bodyJson: try JSONEncoder.supabase.encode(NutritionMealTemplateArchivePayload(archived: archived)),
                priority: 115
            )
            event.headersJson = try Self.headersJson()
            event.dependsOn = Self.latestTemplateMutationDependency(for: id, in: db)
            try event.insert(db)
        }
    }

    func applyMealTemplate(
        id: UUID,
        targetDay: String,
        loggedAt: Date,
        context: MealContext? = nil
    ) async throws -> NutritionMealTemplateApplicationResult {
        let userId = try await resolvedUserId(fallback: nil)
        let dayContext = try await resolveManualLocalDayContext(
            forDayString: targetDay,
            referenceDate: loggedAt,
            userId: userId
        )
        let result = try await dbQueue.write { db in
            let detail = try Self.requireMealTemplateDetail(id: id, userId: userId, db: db)
            let now = Date()
            let logId = UUID()

            var log = FoodLog(
                id: logId,
                userId: userId,
                loggedAt: loggedAt,
                loggedDate: dayContext.dayString,
                inputMethod: .template,
                calories: detail.template.calories,
                proteinG: detail.template.proteinG,
                fatG: detail.template.fatG,
                carbsG: detail.template.carbsG
            )
            log.createdAt = now
            log.updatedAt = now
            log.loggedTimezone = dayContext.timeZoneIdentifier
            log.loggedUtcOffsetMinutes = dayContext.utcOffsetMinutes
            log.mealType = detail.template.mealType
            log.context = context
            log.fiberG = detail.template.fiberG
            log.applyReviewGate()
            try log.insert(db)

            let createPayload = NutritionMealTemplateLogPayload(
                loggedAt: loggedAt,
                loggedDate: dayContext.dayString,
                mealType: detail.template.mealType?.rawValue,
                context: context?.rawValue
            )

            var createEvent = OutboxEvent(
                id: logId,
                httpMethod: .POST,
                path: "api-nutrition-templates/\(id.uuidString)/log",
                bodyJson: try JSONEncoder.supabase.encode(createPayload),
                priority: 100
            )
            createEvent.headersJson = try Self.headersJson()
            createEvent.dependsOn = Self.latestTemplateMutationDependency(for: id, in: db)
            try createEvent.insert(db)

            for templateItem in detail.items {
                let item = Self.makeFoodItem(
                    from: templateItem,
                    foodLogId: log.id,
                    userId: userId,
                    timestamp: now
                )
                try item.insert(db)

                var itemEvent = OutboxEvent(
                    id: item.id,
                    httpMethod: .POST,
                    path: "rest/v1/food_items",
                    bodyJson: try JSONEncoder.supabase.encode(item),
                    priority: 101
                )
                itemEvent.dependsOn = createEvent.id
                itemEvent.headersJson = try Self.headersJson()
                try itemEvent.insert(db)
            }

            var template = detail.template
            template.timesUsed += 1
            template.lastUsedAt = now
            template.updatedAt = now
            try template.update(db)

            return NutritionMealTemplateApplicationResult(
                foodLogId: log.id,
                templateName: template.name,
                itemCount: detail.items.count
            )
        }
        await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
        return result
    }

    func loadBatchRecipes(
        includeArchived: Bool = false,
        limit: Int? = nil,
        preferRemote: Bool = true
    ) async throws -> [NutritionBatchRecipeSummary] {
        let localSummaries = try await loadLocalBatchRecipes(includeArchived: includeArchived, limit: limit)
        let hasCloudSession = await MainActor.run { AuthManager.activeHasCloudSession }
        let shouldFetchRemote = preferRemote &&
            SupabaseConfig.isRuntimeConfigured &&
            hasCloudSession

        guard shouldFetchRemote else {
            return localSummaries
        }

        do {
            let response = try await batchListAPIClient.fetchBatchRecipes(
                status: includeArchived ? "archived" : "active",
                limit: limit
            )
            try await cacheBatchRecipeSummaries(response.results)
            return try await loadLocalBatchRecipes(includeArchived: includeArchived, limit: limit)
        } catch {
            if !localSummaries.isEmpty {
                return localSummaries
            }
            throw error
        }
    }

    func loadBatchRecipeDetail(
        id: UUID,
        preferRemote: Bool = true
    ) async throws -> NutritionBatchRecipeDetail? {
        let localDetail = try await loadLocalBatchRecipeDetail(id: id)
        let hasCloudSession = await MainActor.run { AuthManager.activeHasCloudSession }
        let shouldFetchRemote = preferRemote &&
            SupabaseConfig.isRuntimeConfigured &&
            hasCloudSession

        guard shouldFetchRemote else {
            return localDetail
        }

        if localDetail != nil,
           try await hasPendingBatchMutation(id: id) {
            return localDetail
        }

        do {
            guard let remoteDetail = try await loadRemoteBatchRecipeDetail(id: id, localDetail: localDetail) else {
                return localDetail
            }
            try await cacheBatchRecipeDetail(remoteDetail)
            return try await loadLocalBatchRecipeDetail(id: id) ?? remoteDetail
        } catch {
            if localDetail == nil {
                throw error
            }
            return localDetail
        }
    }

    func createBatchRecipe(_ draft: NutritionBatchRecipeDraft) async throws -> UUID {
        let normalized = try Self.normalizedBatchRecipeDraft(draft)
        let payload = Self.makeBatchRecipePayload(from: normalized, includeArchived: false)
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }

        try await dbQueue.write { db in
            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                throw SyncError.networkUnavailable
            }

            let recipe = Self.makeBatchRecipe(from: normalized, userId: userId)
            try recipe.insert(db)

            for ingredient in Self.makeBatchRecipeIngredients(from: normalized, batchRecipeId: recipe.id) {
                try ingredient.insert(db)
            }

            var event = OutboxEvent(
                id: recipe.id,
                httpMethod: .POST,
                path: "api-nutrition-batches",
                bodyJson: try JSONEncoder.supabase.encode(payload),
                priority: 100
            )
            event.headersJson = try Self.headersJson()
            try event.insert(db)
        }

        try await verifyBatchRecipePersistence(for: normalized)
        await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
        return normalized.id
    }

    func updateBatchRecipe(_ draft: NutritionBatchRecipeDraft) async throws {
        let normalized = try Self.normalizedBatchRecipeDraft(draft)
        let payload = Self.makeBatchRecipePayload(from: normalized, includeArchived: true)

        try await dbQueue.write { db in
            var recipe = try Self.requireBatchRecipe(id: normalized.id, in: db)
            let totals = Self.batchTotals(for: normalized.ingredients)
            let now = Date()

            recipe.name = normalized.name
            recipe.description = Self.normalizedText(normalized.description)
            recipe.cookedAt = normalized.cookedAt
            recipe.totalWeightG = normalized.totalWeightG
            recipe.totalPortions = normalized.totalPortions
            recipe.totalCalories = totals.calories
            recipe.totalProteinG = totals.protein
            recipe.totalFatG = totals.fat
            recipe.totalCarbsG = totals.carbs
            recipe.totalFiberG = totals.fiber
            recipe.caloriesPer100g = Self.per100g(total: totals.calories, weight: normalized.totalWeightG)
            recipe.proteinPer100g = Self.per100g(total: totals.protein, weight: normalized.totalWeightG)
            recipe.fatPer100g = Self.per100g(total: totals.fat, weight: normalized.totalWeightG)
            recipe.carbsPer100g = Self.per100g(total: totals.carbs, weight: normalized.totalWeightG)
            recipe.weightPerPortionG = normalized.totalPortions.map { normalized.totalWeightG / Double($0) }
            recipe.archived = normalized.archived
            recipe.updatedAt = now
            try recipe.update(db)

            try db.execute(
                sql: """
                    DELETE FROM batch_recipe_ingredients
                    WHERE batch_recipe_id = ? OR batch_recipe_id = ?
                    """,
                arguments: [normalized.id, normalized.id.uuidString]
            )

            for ingredient in Self.makeBatchRecipeIngredients(from: normalized, batchRecipeId: normalized.id, updatedAt: now) {
                try ingredient.insert(db)
            }

            var event = OutboxEvent(
                httpMethod: .PATCH,
                path: "api-nutrition-batches/\(normalized.id.uuidString)",
                bodyJson: try JSONEncoder.supabase.encode(payload),
                priority: 110
            )
            event.headersJson = try Self.headersJson()
            event.dependsOn = Self.latestBatchMutationDependency(for: normalized.id, in: db)
            try event.insert(db)
        }

        try await verifyBatchRecipePersistence(for: normalized)
        await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
    }

    func setBatchRecipeArchived(id: UUID, archived: Bool) async throws {
        try await dbQueue.write { db in
            var recipe = try Self.requireBatchRecipe(id: id, in: db)
            recipe.archived = archived
            recipe.updatedAt = Date()
            try recipe.update(db)

            var event = OutboxEvent(
                httpMethod: .PATCH,
                path: "api-nutrition-batches/\(id.uuidString)",
                bodyJson: try JSONEncoder.supabase.encode(NutritionBatchRecipeArchivePayload(archived: archived)),
                priority: 115
            )
            event.headersJson = try Self.headersJson()
            event.dependsOn = Self.latestBatchMutationDependency(for: id, in: db)
            try event.insert(db)
        }

        await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
    }

    func duplicateBatchRecipe(id: UUID, cookedAt: String? = nil) async throws -> NutritionBatchRecipeDuplicateResult {
        let localDetail = try await loadBatchRecipeDetail(id: id, preferRemote: false)
        let detail: NutritionBatchRecipeDetail?
        if let localDetail {
            detail = localDetail
        } else {
            detail = try await loadBatchRecipeDetail(id: id, preferRemote: true)
        }
        guard let detail else {
            throw NutritionError.batchRecipeNotFound
        }

        let duplicateDraft = NutritionBatchRecipeDraft(
            name: detail.recipe.name,
            description: detail.recipe.description,
            cookedAt: cookedAt ?? DateFormatting.dateOnlyString(from: Date()),
            totalWeightG: detail.recipe.totalWeightG,
            totalPortions: detail.recipe.totalPortions,
            ingredients: detail.ingredients.map(Self.makeBatchDraftIngredient(from:)),
            archived: false
        )
        let batchId = try await createBatchRecipe(duplicateDraft)
        return NutritionBatchRecipeDuplicateResult(batchId: batchId, name: duplicateDraft.name)
    }

    func logBatchPortion(_ draft: NutritionBatchPortionLogDraft) async throws -> NutritionBatchPortionLogResult {
        guard draft.portionWeightG > 0 else {
            throw NutritionError.invalidBatchRecipe(reason: "Portion weight must be greater than zero")
        }
        let userId = try await resolvedUserId(fallback: nil)
        let dayContext = try await resolveManualLocalDayContext(
            forDayString: draft.targetDay,
            referenceDate: draft.loggedAt,
            userId: userId
        )

        let result = try await dbQueue.write { db in
            let detail = try Self.requireBatchRecipeDetail(id: draft.batchId, userId: userId, db: db)
            guard draft.portionWeightG <= detail.weightRemainingG + 0.001 else {
                throw NutritionError.batchPortionExceedsRemaining(maxGrams: detail.weightRemainingG)
            }

            let now = Date()
            let foodLogId = UUID()
            let foodItemId = UUID()
            let snapshot = Self.batchMacroSnapshot(recipe: detail.recipe, weightG: draft.portionWeightG)

            var log = FoodLog(
                id: foodLogId,
                userId: userId,
                loggedAt: draft.loggedAt,
                loggedDate: dayContext.dayString,
                inputMethod: .batch,
                calories: snapshot.calories,
                proteinG: snapshot.proteinG,
                fatG: snapshot.fatG,
                carbsG: snapshot.carbsG
            )
            log.createdAt = now
            log.updatedAt = now
            log.loggedTimezone = dayContext.timeZoneIdentifier
            log.loggedUtcOffsetMinutes = dayContext.utcOffsetMinutes
            log.mealType = draft.mealType
            log.context = draft.context
            log.fiberG = snapshot.fiberG
            log.applyReviewGate()
            try log.insert(db)

            var item = FoodItem(
                id: foodItemId,
                foodLogId: foodLogId,
                userId: userId,
                name: detail.recipe.name,
                weightG: draft.portionWeightG,
                calories: snapshot.calories,
                proteinG: snapshot.proteinG,
                fatG: snapshot.fatG,
                carbsG: snapshot.carbsG
            )
            item.createdAt = now
            item.updatedAt = now
            item.batchRecipeId = draft.batchId
            item.fiberG = snapshot.fiberG
            item.detectedByAi = false
            item.userAdjusted = false
            try item.insert(db)

            var recipe = detail.recipe
            recipe.timesUsed += 1
            recipe.lastUsedAt = now
            recipe.updatedAt = now
            try recipe.update(db)

            let payload = NutritionBatchPortionLogPayload(
                foodLogId: foodLogId,
                foodItemId: foodItemId,
                loggedAt: draft.loggedAt,
                loggedDate: dayContext.dayString,
                loggedTimezone: dayContext.timeZoneIdentifier,
                loggedUtcOffsetMinutes: dayContext.utcOffsetMinutes,
                mealType: draft.mealType?.rawValue,
                context: draft.context?.rawValue,
                portionWeightG: draft.portionWeightG,
                itemMacrosOverride: snapshot
            )

            var event = OutboxEvent(
                id: foodLogId,
                httpMethod: .POST,
                path: "api-nutrition-batches/\(draft.batchId.uuidString)/log",
                bodyJson: try JSONEncoder.supabase.encode(payload),
                priority: 105
            )
            event.headersJson = try Self.headersJson()
            event.dependsOn = Self.latestBatchMutationDependency(for: draft.batchId, in: db)
            try event.insert(db)

            return NutritionBatchPortionLogResult(
                foodLogId: foodLogId,
                foodItemId: foodItemId,
                batchId: draft.batchId,
                weightRemainingG: max(detail.weightRemainingG - draft.portionWeightG, 0)
            )
        }

        await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
        return result
    }

    private func persistNewMeal(log: FoodLog, items: [FoodItem]) async throws {
        try await dbQueue.write { db in
            let storedLog = log
            try storedLog.insert(db)

            var logEvent = OutboxEvent(
                id: storedLog.id,
                httpMethod: .POST,
                path: "api-food-log",
                bodyJson: try JSONEncoder.supabase.encode(storedLog),
                priority: 100
            )
            logEvent.headersJson = try Self.headersJson()
            try logEvent.insert(db)

            for item in items {
                try item.insert(db)

                var itemEvent = OutboxEvent(
                    id: item.id,
                    httpMethod: .POST,
                    path: "rest/v1/food_items",
                    bodyJson: try JSONEncoder.supabase.encode(item),
                    priority: 101
                )
                itemEvent.dependsOn = storedLog.id
                itemEvent.headersJson = try Self.headersJson()
                try itemEvent.insert(db)
            }
        }
    }

    private func loadLocalMealDetail(id: UUID) async throws -> NutritionMealDetail? {
        try await dbQueue.read { db -> NutritionMealDetail? in
            guard let log = try FoodLog.fetchOne(
                db,
                sql: """
                    SELECT *
                    FROM food_logs
                    WHERE id = ? OR id = ?
                    LIMIT 1
                    """,
                arguments: [id, id.uuidString]
            ) else {
                return nil
            }

            let items = try FoodItem.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM food_items
                    WHERE food_log_id = ? OR food_log_id = ?
                    ORDER BY created_at ASC
                    """,
                arguments: [id, id.uuidString]
            )
            return NutritionMealDetail(log: log, items: items)
        }
    }

    private func loadRemoteMealDetail(
        id: UUID,
        localDetail: NutritionMealDetail?
    ) async throws -> NutritionMealDetail? {
        let response = try await detailAPIClient.fetchMealDetail(id: id)
        let userId = try await resolvedUserId(fallback: localDetail?.log.userId)

        var log = localDetail?.log ?? FoodLog(
            id: response.id,
            userId: userId,
            loggedAt: response.loggedAt,
            loggedDate: response.loggedDate,
            inputMethod: response.inputMethod,
            calories: response.macros.calories,
            proteinG: response.macros.proteinG,
            fatG: response.macros.fatG,
            carbsG: response.macros.carbsG
        )

        log.userId = userId
        log.loggedAt = response.loggedAt
        log.loggedDate = response.loggedDate
        log.inputMethod = response.inputMethod
        log.mealType = response.mealType
        log.context = response.context
        log.calories = response.macros.calories
        log.proteinG = response.macros.proteinG
        log.fatG = response.macros.fatG
        log.carbsG = response.macros.carbsG
        log.fiberG = response.macros.fiberG
        log.aiConfidence = response.aiConfidence
        log.needsReview = response.aiConfidence.map { $0 < NutritionReviewGate.confidenceThreshold } ?? false
        log.userCorrected = response.userCorrected
        log.userNotes = response.userNotes
        log.deletedAt = nil
        log.deletedReason = nil
        log.createdAt = response.createdAt ?? .distantPast
        log.updatedAt = response.updatedAt ?? .distantPast

        let items = response.items.map { item in
            var existing = localDetail?.items.first(where: { $0.id == item.id }) ?? FoodItem(
                id: item.id,
                foodLogId: response.id,
                userId: userId,
                name: item.name,
                weightG: item.weightG,
                calories: item.macros.calories,
                proteinG: item.macros.proteinG,
                fatG: item.macros.fatG,
                carbsG: item.macros.carbsG
            )
            existing.foodLogId = response.id
            existing.userId = userId
            existing.name = item.name
            existing.brand = item.brand
            existing.barcode = item.barcode
            existing.catalogItemId = item.catalogItemId
            existing.userFoodId = item.userFoodId
            existing.batchRecipeId = item.batchRecipeId
            existing.weightG = item.weightG
            existing.calories = item.macros.calories
            existing.proteinG = item.macros.proteinG
            existing.fatG = item.macros.fatG
            existing.carbsG = item.macros.carbsG
            existing.fiberG = item.macros.fiberG
            existing.confidence = item.confidence
            existing.detectedByAi = item.detectedByAi
            existing.userAdjusted = item.userAdjusted
            existing.createdAt = item.createdAt ?? .distantPast
            existing.updatedAt = item.updatedAt ?? .distantPast
            return existing
        }

        return NutritionMealDetail(log: log, items: items)
    }

    private func cacheMealDetail(_ detail: NutritionMealDetail) async throws {
        try await dbQueue.write { db in
            // Recheck in the write transaction: an edit may occur during the GET.
            let entityId = detail.log.id
            let pending = try OutboxEvent.fetchAll(db, sql: "SELECT * FROM outbox_events WHERE status IN (?, ?, ?, ?)", arguments: [OutboxStatus.pending.rawValue, OutboxStatus.inFlight.rawValue, OutboxStatus.failedRetryable.rawValue, OutboxStatus.failedPermanent.rawValue])
            guard !pending.contains(where: { event in
                event.id == entityId || event.path.lowercased().contains(entityId.uuidString.lowercased()) ||
                String(data: event.bodyJson, encoding: .utf8)?.lowercased().contains(entityId.uuidString.lowercased()) == true
            }) else { return }
            if let existing = try FoodLog.fetchOne(db, sql: "SELECT * FROM food_logs WHERE id = ? OR id = ?", arguments: [entityId, entityId.uuidString]),
               existing.updatedAt > detail.log.updatedAt { return }
            try detail.log.save(db)
            try db.execute(
                sql: """
                    DELETE FROM food_items
                    WHERE food_log_id = ? OR food_log_id = ?
                    """,
                arguments: [detail.log.id, detail.log.id.uuidString]
            )
            for item in detail.items {
                try item.insert(db)
            }
        }
    }

    private func loadLocalMealTemplates(
        includeArchived: Bool,
        limit: Int?
    ) async throws -> [NutritionMealTemplateSummary] {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        return try await dbQueue.read { db -> [NutritionMealTemplateSummary] in
            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                return []
            }

            var sql = """
                SELECT id, name, meal_type, calories, protein_g, fat_g, carbs_g, fiber_g,
                       times_used, last_used_at, archived, updated_at
                FROM meal_templates
                WHERE (user_id = ? OR user_id = ?)
                  AND deleted_at IS NULL
            """
            var arguments: StatementArguments = [userId, userId.uuidString]
            if !includeArchived {
                sql += "\n  AND archived = 0"
            }
            sql += "\nORDER BY archived ASC, COALESCE(last_used_at, updated_at) DESC, name ASC"
            if let limit {
                sql += "\nLIMIT ?"
                arguments += [limit]
            }

            return try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap(Self.makeTemplateSummary(from:))
        }
    }

    private func loadLocalMealTemplateDetail(id: UUID) async throws -> NutritionMealTemplateDetail? {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        return try await dbQueue.read { db -> NutritionMealTemplateDetail? in
            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                return nil
            }
            guard let template = try MealTemplate.fetchOne(
                db,
                sql: """
                    SELECT *
                    FROM meal_templates
                    WHERE (id = ? OR id = ?)
                      AND (user_id = ? OR user_id = ?)
                      AND deleted_at IS NULL
                    LIMIT 1
                    """,
                arguments: [id, id.uuidString, userId, userId.uuidString]
            ) else {
                return nil
            }
            let items = try Self.decodeTemplateItems(template.templateItems)
            return NutritionMealTemplateDetail(template: template, items: items)
        }
    }

    private func loadRemoteMealTemplateDetail(
        id: UUID,
        localDetail: NutritionMealTemplateDetail?
    ) async throws -> NutritionMealTemplateDetail? {
        let response = try await templateDetailAPIClient.fetchMealTemplateDetail(id: id)
        let userId = try await resolvedUserId(fallback: localDetail?.template.userId)

        var template = localDetail?.template ?? MealTemplate(
            id: response.id,
            userId: userId,
            name: response.name,
            templateItems: Data("[]".utf8),
            calories: response.calories,
            proteinG: response.proteinG,
            fatG: response.fatG,
            carbsG: response.carbsG
        )
        template.userId = userId
        template.name = response.name
        template.mealType = response.mealType
        template.templateItems = try JSONEncoder.supabase.encode(response.templateItems)
        template.calories = response.calories
        template.proteinG = response.proteinG
        template.fatG = response.fatG
        template.carbsG = response.carbsG
        template.fiberG = response.fiberG
        template.timesUsed = response.timesUsed
        template.lastUsedAt = response.lastUsedAt
        template.archived = response.archived
        template.updatedAt = response.updatedAt

        return NutritionMealTemplateDetail(template: template, items: response.templateItems)
    }

    private func cacheMealTemplateSummaries(_ templates: [NutritionMealTemplateSummary]) async throws {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        try await dbQueue.write { db in
            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                return
            }

            for summary in templates {
                if Self.hasPendingTemplateMutation(for: summary.id, in: db) {
                    continue
                }

                var existing = try MealTemplate.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM meal_templates
                        WHERE (id = ? OR id = ?)
                        LIMIT 1
                        """,
                    arguments: [summary.id, summary.id.uuidString]
                ) ?? MealTemplate(
                    id: summary.id,
                    userId: userId,
                    name: summary.name,
                    templateItems: Data("[]".utf8),
                    calories: summary.calories,
                    proteinG: summary.proteinG,
                    fatG: summary.fatG,
                    carbsG: summary.carbsG
                )

                existing.userId = userId
                existing.name = summary.name
                existing.mealType = summary.mealType
                existing.calories = summary.calories
                existing.proteinG = summary.proteinG
                existing.fatG = summary.fatG
                existing.carbsG = summary.carbsG
                existing.fiberG = summary.fiberG
                existing.timesUsed = summary.timesUsed
                existing.lastUsedAt = summary.lastUsedAt
                existing.archived = summary.archived
                existing.updatedAt = summary.updatedAt
                try existing.save(db)
            }
        }
    }

    private func cacheMealTemplateDetail(_ detail: NutritionMealTemplateDetail) async throws {
        try await dbQueue.write { db in
            if Self.hasPendingTemplateMutation(for: detail.template.id, in: db) {
                return
            }
            var template = detail.template
            template.templateItems = try JSONEncoder.supabase.encode(detail.items)
            try template.save(db)
        }
    }

    private func loadLocalBatchRecipes(
        includeArchived: Bool,
        limit: Int?
    ) async throws -> [NutritionBatchRecipeSummary] {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        return try await dbQueue.read { db -> [NutritionBatchRecipeSummary] in
            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                return []
            }

            var sql = """
                SELECT br.*,
                       COALESCE(consumed.consumed_weight_g, 0) AS consumed_weight_g,
                       MAX(br.total_weight_g - COALESCE(consumed.consumed_weight_g, 0), 0) AS weight_remaining_g
                FROM batch_recipes br
                LEFT JOIN (
                    SELECT fi.batch_recipe_id AS batch_recipe_id,
                           SUM(fi.weight_g) AS consumed_weight_g
                    FROM food_items fi
                    JOIN food_logs fl
                      ON fl.id = fi.food_log_id
                    WHERE fi.batch_recipe_id IS NOT NULL
                      AND fl.deleted_at IS NULL
                    GROUP BY fi.batch_recipe_id
                ) consumed
                  ON consumed.batch_recipe_id = br.id
                WHERE (br.user_id = ? OR br.user_id = ?)
                  AND br.deleted_at IS NULL
            """
            var arguments: StatementArguments = [userId, userId.uuidString]

            if includeArchived {
                sql += "\n  AND br.archived = 1"
                sql += "\nORDER BY br.updated_at DESC, br.name COLLATE NOCASE ASC"
            } else {
                sql += "\n  AND br.archived = 0"
                sql += "\nORDER BY CASE WHEN br.cooked_at IS NULL THEN 1 ELSE 0 END, br.cooked_at DESC, br.updated_at DESC"
            }

            if let limit {
                sql += "\nLIMIT ?"
                arguments += [limit]
            }

            return try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap(Self.makeBatchRecipeSummary(from:))
        }
    }

    private func loadLocalBatchRecipeDetail(id: UUID) async throws -> NutritionBatchRecipeDetail? {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        return try await dbQueue.read { db -> NutritionBatchRecipeDetail? in
            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                return nil
            }

            guard let recipe = try BatchRecipe.fetchOne(
                db,
                sql: """
                    SELECT *
                    FROM batch_recipes
                    WHERE (id = ? OR id = ?)
                      AND (user_id = ? OR user_id = ?)
                      AND deleted_at IS NULL
                    LIMIT 1
                    """,
                arguments: [id, id.uuidString, userId, userId.uuidString]
            ) else {
                return nil
            }

            let ingredients = try BatchRecipeIngredient.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM batch_recipe_ingredients
                    WHERE batch_recipe_id = ? OR batch_recipe_id = ?
                    ORDER BY sort_order ASC, created_at ASC
                    """,
                arguments: [id, id.uuidString]
            )

            let consumedWeightG = try Self.loadLocalConsumedWeight(for: id, db: db)
            let consumption = Self.batchConsumption(recipe: recipe, consumedWeightG: consumedWeightG)
            return NutritionBatchRecipeDetail(
                recipe: recipe,
                ingredients: ingredients,
                consumedWeightG: consumedWeightG,
                weightRemainingG: consumption.weightRemainingG,
                portionsRemaining: consumption.portionsRemaining
            )
        }
    }

    private func loadRemoteBatchRecipeDetail(
        id: UUID,
        localDetail: NutritionBatchRecipeDetail?
    ) async throws -> NutritionBatchRecipeDetail? {
        let response = try await batchDetailAPIClient.fetchBatchRecipeDetail(id: id)
        let userId = try await resolvedUserId(fallback: localDetail?.recipe.userId)
        let recipe = Self.makeBatchRecipe(from: response, userId: userId, existing: localDetail?.recipe)
        let ingredients = response.ingredients.enumerated().map { index, ingredient in
            Self.makeBatchRecipeIngredient(
                from: ingredient,
                batchRecipeId: response.id,
                sortOrder: index,
                updatedAt: response.updatedAt
            )
        }

        return NutritionBatchRecipeDetail(
            recipe: recipe,
            ingredients: ingredients,
            consumedWeightG: response.consumedWeightG,
            weightRemainingG: response.weightRemainingG,
            portionsRemaining: response.portionsRemaining
        )
    }

    private func cacheBatchRecipeSummaries(_ recipes: [NutritionBatchRecipeSummary]) async throws {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        try await dbQueue.write { db in
            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                return
            }

            for summary in recipes {
                if Self.hasPendingBatchMutation(for: summary.id, in: db) {
                    continue
                }

                var existing = try BatchRecipe.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM batch_recipes
                        WHERE (id = ? OR id = ?)
                        LIMIT 1
                        """,
                    arguments: [summary.id, summary.id.uuidString]
                ) ?? BatchRecipe(
                    id: summary.id,
                    userId: userId,
                    name: summary.name,
                    totalWeightG: summary.totalWeightG,
                    totalCalories: summary.totalCalories,
                    totalProteinG: summary.totalProteinG,
                    totalFatG: summary.totalFatG,
                    totalCarbsG: summary.totalCarbsG
                )

                existing.userId = userId
                existing.name = summary.name
                existing.cookedAt = summary.cookedAt
                existing.totalWeightG = summary.totalWeightG
                existing.totalPortions = summary.totalPortions
                existing.totalCalories = summary.totalCalories
                existing.totalProteinG = summary.totalProteinG
                existing.totalFatG = summary.totalFatG
                existing.totalCarbsG = summary.totalCarbsG
                existing.totalFiberG = summary.totalFiberG
                existing.caloriesPer100g = summary.caloriesPer100g ?? Self.per100g(total: summary.totalCalories, weight: summary.totalWeightG)
                existing.proteinPer100g = summary.proteinPer100g ?? Self.per100g(total: summary.totalProteinG, weight: summary.totalWeightG)
                existing.fatPer100g = summary.fatPer100g ?? Self.per100g(total: summary.totalFatG, weight: summary.totalWeightG)
                existing.carbsPer100g = summary.carbsPer100g ?? Self.per100g(total: summary.totalCarbsG, weight: summary.totalWeightG)
                existing.weightPerPortionG = summary.totalPortions.map { summary.totalWeightG / Double($0) }
                existing.archived = summary.archived
                existing.timesUsed = summary.timesUsed
                existing.lastUsedAt = summary.lastUsedAt
                existing.updatedAt = summary.updatedAt
                try existing.save(db)
            }
        }
    }

    private func cacheBatchRecipeDetail(_ detail: NutritionBatchRecipeDetail) async throws {
        try await dbQueue.write { db in
            var recipe = detail.recipe
            if Self.hasPendingBatchMutation(for: recipe.id, in: db) {
                return
            }
            recipe.caloriesPer100g = recipe.caloriesPer100g ?? Self.per100g(total: recipe.totalCalories, weight: recipe.totalWeightG)
            recipe.proteinPer100g = recipe.proteinPer100g ?? Self.per100g(total: recipe.totalProteinG, weight: recipe.totalWeightG)
            recipe.fatPer100g = recipe.fatPer100g ?? Self.per100g(total: recipe.totalFatG, weight: recipe.totalWeightG)
            recipe.carbsPer100g = recipe.carbsPer100g ?? Self.per100g(total: recipe.totalCarbsG, weight: recipe.totalWeightG)
            recipe.weightPerPortionG = recipe.weightPerPortionG ?? recipe.totalPortions.map { recipe.totalWeightG / Double($0) }
            try recipe.save(db)
            try db.execute(
                sql: """
                    DELETE FROM batch_recipe_ingredients
                    WHERE batch_recipe_id = ? OR batch_recipe_id = ?
                    """,
                arguments: [recipe.id, recipe.id.uuidString]
            )
            for ingredient in detail.ingredients {
                try ingredient.insert(db)
            }
        }
    }

    private func resolvedUserId(fallback: UUID?) async throws -> UUID {
        if let fallback {
            return fallback
        }
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        guard let authId else {
            throw SyncError.networkUnavailable
        }
        return try await dbQueue.read { db in
            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                throw SyncError.networkUnavailable
            }
            return userId
        }
    }

    private func resolveManualLocalDayContext(
        forDayString dayString: String,
        referenceDate: Date,
        userId: UUID
    ) async throws -> HistoricalLocalDayContext {
        _ = try await timeZoneHistoryStore.captureCurrentTimeZoneIfNeeded(
            userId: userId,
            recordedAt: referenceDate,
            source: .manualEntry
        )
        return try await timeZoneHistoryStore.resolveLocalDayContext(
            forDayString: dayString,
            userId: userId,
            preferredDate: referenceDate
        )
    }

    private func normalizedFoodLog(_ log: FoodLog, userId: UUID) async throws -> FoodLog {
        let dayContext = try await resolveManualLocalDayContext(
            forDayString: log.loggedDate,
            referenceDate: log.loggedAt,
            userId: userId
        )
        var normalizedLog = log
        normalizedLog.userId = userId
        normalizedLog.loggedDate = dayContext.dayString
        normalizedLog.loggedTimezone = dayContext.timeZoneIdentifier
        normalizedLog.loggedUtcOffsetMinutes = dayContext.utcOffsetMinutes
        return normalizedLog
    }

    private func hasPendingBatchMutation(id: UUID) async throws -> Bool {
        try await dbQueue.read { db in
            Self.hasPendingBatchMutation(for: id, in: db)
        }
    }

    private func verifyBatchRecipePersistence(for draft: NutritionBatchRecipeDraft) async throws {
        guard let detail = try await loadLocalBatchRecipeDetail(id: draft.id),
              Self.batchRecipe(detail, matches: draft) else {
            throw NutritionError.batchRecipeSaveFailed
        }
    }

    private func verifyMealTemplatePersistence(for draft: NutritionMealTemplateCreateDraft) async throws {
        guard let detail = try await loadLocalMealTemplateDetail(id: draft.id),
              Self.mealTemplate(detail, matches: draft) else {
            throw NutritionError.templateNotFound
        }
    }

    private nonisolated static func requireFoodLog(id: UUID, in db: Database) throws -> FoodLog {
        guard let log = try FoodLog.fetchOne(
            db,
            sql: """
                SELECT *
                FROM food_logs
                WHERE id = ? OR id = ?
                LIMIT 1
                """,
            arguments: [id, id.uuidString]
        ) else {
            throw NutritionError.mealNotFound
        }
        return log
    }

    private nonisolated static func requireMealTemplate(id: UUID, in db: Database) throws -> MealTemplate {
        guard let template = try MealTemplate.fetchOne(
            db,
            sql: """
                SELECT *
                FROM meal_templates
                WHERE (id = ? OR id = ?)
                  AND deleted_at IS NULL
                LIMIT 1
                """,
            arguments: [id, id.uuidString]
        ) else {
            throw NutritionError.templateNotFound
        }
        return template
    }

    private nonisolated static func requireBatchRecipe(id: UUID, in db: Database) throws -> BatchRecipe {
        guard let recipe = try BatchRecipe.fetchOne(
            db,
            sql: """
                SELECT *
                FROM batch_recipes
                WHERE (id = ? OR id = ?)
                  AND deleted_at IS NULL
                LIMIT 1
                """,
            arguments: [id, id.uuidString]
        ) else {
            throw NutritionError.batchRecipeNotFound
        }
        return recipe
    }

    private nonisolated static func requireMealTemplateDetail(
        id: UUID,
        userId: UUID,
        db: Database
    ) throws -> NutritionMealTemplateDetail {
        guard let template = try MealTemplate.fetchOne(
            db,
            sql: """
                SELECT *
                FROM meal_templates
                WHERE (id = ? OR id = ?)
                  AND (user_id = ? OR user_id = ?)
                  AND deleted_at IS NULL
                LIMIT 1
                """,
            arguments: [id, id.uuidString, userId, userId.uuidString]
        ) else {
            throw NutritionError.templateNotFound
        }

        let items = try decodeTemplateItems(template.templateItems)
        guard !items.isEmpty else {
            throw NutritionError.templateEmpty
        }
        return NutritionMealTemplateDetail(template: template, items: items)
    }

    private nonisolated static func requireBatchRecipeDetail(
        id: UUID,
        userId: UUID,
        db: Database
    ) throws -> NutritionBatchRecipeDetail {
        guard let recipe = try BatchRecipe.fetchOne(
            db,
            sql: """
                SELECT *
                FROM batch_recipes
                WHERE (id = ? OR id = ?)
                  AND (user_id = ? OR user_id = ?)
                  AND deleted_at IS NULL
                LIMIT 1
                """,
            arguments: [id, id.uuidString, userId, userId.uuidString]
        ) else {
            throw NutritionError.batchRecipeNotFound
        }

        let ingredients = try BatchRecipeIngredient.fetchAll(
            db,
            sql: """
                SELECT *
                FROM batch_recipe_ingredients
                WHERE batch_recipe_id = ? OR batch_recipe_id = ?
                ORDER BY sort_order ASC, created_at ASC
                """,
            arguments: [id, id.uuidString]
        )
        guard !ingredients.isEmpty else {
            throw NutritionError.batchRecipeEmpty
        }

        let consumedWeightG = try loadLocalConsumedWeight(for: id, db: db)
        let consumption = batchConsumption(recipe: recipe, consumedWeightG: consumedWeightG)
        return NutritionBatchRecipeDetail(
            recipe: recipe,
            ingredients: ingredients,
            consumedWeightG: consumedWeightG,
            weightRemainingG: consumption.weightRemainingG,
            portionsRemaining: consumption.portionsRemaining
        )
    }

    private nonisolated static func makeTemplateSummary(from row: Row) -> NutritionMealTemplateSummary? {
        guard let id = MixedUUIDStorage.decode(from: row, column: "id"),
              let name: String = row["name"] else {
            return nil
        }
        return NutritionMealTemplateSummary(
            id: id,
            name: name,
            mealType: (row["meal_type"] as String?).flatMap(MealType.init(rawValue:)),
            calories: row["calories"] ?? 0,
            proteinG: row["protein_g"] ?? 0,
            fatG: row["fat_g"] ?? 0,
            carbsG: row["carbs_g"] ?? 0,
            fiberG: row["fiber_g"],
            timesUsed: row["times_used"] ?? 0,
            lastUsedAt: row["last_used_at"],
            archived: row["archived"] ?? false,
            updatedAt: row["updated_at"] ?? Date.distantPast
        )
    }

    private nonisolated static func makeBatchRecipeSummary(from row: Row) -> NutritionBatchRecipeSummary? {
        guard let id = MixedUUIDStorage.decode(from: row, column: "id"),
              let name: String = row["name"] else {
            return nil
        }

        let totalWeightG: Double = row["total_weight_g"] ?? 0
        let totalPortions: Int? = row["total_portions"]
        let consumedWeightG: Double = row["consumed_weight_g"] ?? 0
        let weightRemainingG: Double = row["weight_remaining_g"] ?? max(totalWeightG - consumedWeightG, 0)
        let portionsRemaining = totalPortions.flatMap { portions -> Double? in
            guard portions > 0, totalWeightG > 0 else { return nil }
            return weightRemainingG / (totalWeightG / Double(portions))
        }

        return NutritionBatchRecipeSummary(
            id: id,
            name: name,
            cookedAt: row["cooked_at"],
            totalWeightG: totalWeightG,
            consumedWeightG: consumedWeightG,
            weightRemainingG: weightRemainingG,
            totalPortions: totalPortions,
            portionsRemaining: portionsRemaining,
            totalCalories: row["total_calories"] ?? 0,
            totalProteinG: row["total_protein_g"] ?? 0,
            totalFatG: row["total_fat_g"] ?? 0,
            totalCarbsG: row["total_carbs_g"] ?? 0,
            totalFiberG: row["total_fiber_g"],
            caloriesPer100g: row["calories_per_100g"],
            proteinPer100g: row["protein_per_100g"],
            fatPer100g: row["fat_per_100g"],
            carbsPer100g: row["carbs_per_100g"],
            archived: row["archived"] ?? false,
            timesUsed: row["times_used"] ?? 0,
            lastUsedAt: row["last_used_at"],
            updatedAt: row["updated_at"] ?? Date.distantPast
        )
    }

    private nonisolated static func decodeTemplateItems(_ data: Data) throws -> [NutritionMealTemplateItem] {
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([NutritionMealTemplateItem].self, from: data)
    }

    private nonisolated static func normalizedTemplateItems(
        _ items: [NutritionMealTemplateItem]
    ) throws -> [NutritionMealTemplateItem] {
        try items.map { item in
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw NutritionError.invalidMealItem(reason: "Template item name is required")
            }
            guard item.weightG > 0 else {
                throw NutritionError.invalidMealItem(reason: "Template item weight must be greater than zero")
            }

            var normalized = item
            normalized.name = name
            normalized.brand = normalizedText(item.brand)
            normalized.barcode = normalizedText(item.barcode)
            if normalized.fiberG == 0 {
                normalized.fiberG = nil
            }
            return normalized
        }
    }

    private nonisolated static func normalizedMealTemplateCreateDraft(
        _ draft: NutritionMealTemplateCreateDraft
    ) throws -> NutritionMealTemplateCreateDraft {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw NutritionError.invalidMealItem(reason: "Template name is required")
        }

        let normalizedItems = try normalizedTemplateItems(draft.items)
        guard !normalizedItems.isEmpty else {
            throw NutritionError.templateEmpty
        }

        var normalized = draft
        normalized.name = name
        normalized.items = normalizedItems
        return normalized
    }

    private nonisolated static func normalizedBatchRecipeDraft(
        _ draft: NutritionBatchRecipeDraft
    ) throws -> NutritionBatchRecipeDraft {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw NutritionError.invalidBatchRecipe(reason: "Name is required")
        }
        guard draft.totalWeightG > 0 else {
            throw NutritionError.invalidBatchRecipe(reason: "Total cooked weight must be greater than zero")
        }
        if let portions = draft.totalPortions, portions <= 0 {
            throw NutritionError.invalidBatchRecipe(reason: "Portions must be greater than zero")
        }
        guard !draft.ingredients.isEmpty else {
            throw NutritionError.batchRecipeEmpty
        }

        let normalizedIngredients = try draft.ingredients.map { ingredient in
            let ingredientName = ingredient.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ingredientName.isEmpty else {
                throw NutritionError.invalidBatchRecipe(reason: "Ingredient name is required")
            }
            guard ingredient.weightG > 0 else {
                throw NutritionError.invalidBatchRecipe(reason: "Ingredient weight must be greater than zero")
            }
            guard ingredient.calories >= 0,
                  ingredient.proteinG >= 0,
                  ingredient.fatG >= 0,
                  ingredient.carbsG >= 0,
                  (ingredient.fiberG ?? 0) >= 0 else {
                throw NutritionError.invalidBatchRecipe(reason: "Ingredient macros cannot be negative")
            }

            var normalized = ingredient
            normalized.name = ingredientName
            normalized.brand = normalizedText(ingredient.brand)
            normalized.barcode = normalizedText(ingredient.barcode)
            if normalized.fiberG == 0 {
                normalized.fiberG = nil
            }
            return normalized
        }

        var normalized = draft
        normalized.name = name
        normalized.description = normalizedText(draft.description)
        normalized.cookedAt = normalizedText(draft.cookedAt)
        normalized.ingredients = normalizedIngredients
        return normalized
    }

    private nonisolated static func templateTotals(
        for items: [NutritionMealTemplateItem]
    ) -> (calories: Double, protein: Double, fat: Double, carbs: Double, fiber: Double?) {
        let calories = items.reduce(0) { $0 + $1.calories }
        let protein = items.reduce(0) { $0 + $1.proteinG }
        let fat = items.reduce(0) { $0 + $1.fatG }
        let carbs = items.reduce(0) { $0 + $1.carbsG }
        let fiber = items.reduce(0) { $0 + ($1.fiberG ?? 0) }
        return (calories, protein, fat, carbs, fiber > 0 ? fiber : nil)
    }

    private nonisolated static func batchTotals(
        for ingredients: [NutritionBatchRecipeDraftIngredient]
    ) -> (calories: Double, protein: Double, fat: Double, carbs: Double, fiber: Double?) {
        let calories = ingredients.reduce(0) { $0 + $1.calories }
        let protein = ingredients.reduce(0) { $0 + $1.proteinG }
        let fat = ingredients.reduce(0) { $0 + $1.fatG }
        let carbs = ingredients.reduce(0) { $0 + $1.carbsG }
        let fiber = ingredients.reduce(0) { $0 + ($1.fiberG ?? 0) }
        return (calories, protein, fat, carbs, fiber > 0 ? fiber : nil)
    }

    private nonisolated static func per100g(total: Double, weight: Double) -> Double? {
        guard weight > 0 else { return nil }
        return total * 100 / weight
    }

    private nonisolated static func makeFoodItem(
        from templateItem: NutritionMealTemplateItem,
        foodLogId: UUID,
        userId: UUID,
        timestamp: Date
    ) -> FoodItem {
        var item = FoodItem(
            foodLogId: foodLogId,
            userId: userId,
            name: templateItem.name,
            weightG: templateItem.weightG,
            calories: templateItem.calories,
            proteinG: templateItem.proteinG,
            fatG: templateItem.fatG,
            carbsG: templateItem.carbsG
        )
        item.createdAt = timestamp
        item.updatedAt = timestamp
        item.brand = templateItem.brand
        item.barcode = templateItem.barcode
        item.catalogItemId = templateItem.catalogItemId
        item.userFoodId = templateItem.userFoodId
        item.batchRecipeId = templateItem.batchRecipeId
        item.fiberG = templateItem.fiberG
        item.confidence = templateItem.confidence
        item.detectedByAi = false
        item.userAdjusted = false
        return item
    }

    private nonisolated static func makeMealTemplate(
        from draft: NutritionMealTemplateCreateDraft,
        userId: UUID
    ) -> MealTemplate {
        let totals = templateTotals(for: draft.items)
        var template = MealTemplate(
            id: draft.id,
            userId: userId,
            name: draft.name,
            templateItems: (try? JSONEncoder.supabase.encode(draft.items)) ?? Data("[]".utf8),
            calories: totals.calories,
            proteinG: totals.protein,
            fatG: totals.fat,
            carbsG: totals.carbs
        )
        template.mealType = draft.mealType
        template.fiberG = totals.fiber
        template.archived = draft.archived
        return template
    }

    private nonisolated static func makeBatchRecipe(
        from draft: NutritionBatchRecipeDraft,
        userId: UUID
    ) -> BatchRecipe {
        let totals = batchTotals(for: draft.ingredients)
        var recipe = BatchRecipe(
            id: draft.id,
            userId: userId,
            name: draft.name,
            totalWeightG: draft.totalWeightG,
            totalCalories: totals.calories,
            totalProteinG: totals.protein,
            totalFatG: totals.fat,
            totalCarbsG: totals.carbs
        )
        recipe.description = draft.description
        recipe.totalPortions = draft.totalPortions
        recipe.totalFiberG = totals.fiber
        recipe.cookedAt = draft.cookedAt
        recipe.archived = draft.archived
        recipe.weightPerPortionG = draft.totalPortions.map { draft.totalWeightG / Double($0) }
        return recipe
    }

    private nonisolated static func makeBatchRecipe(
        from response: NutritionBatchRecipeRemoteDetailResponse,
        userId: UUID,
        existing: BatchRecipe?
    ) -> BatchRecipe {
        var recipe = existing ?? BatchRecipe(
            id: response.id,
            userId: userId,
            name: response.name,
            totalWeightG: response.totalWeightG,
            totalCalories: response.totalCalories,
            totalProteinG: response.totalProteinG,
            totalFatG: response.totalFatG,
            totalCarbsG: response.totalCarbsG
        )
        recipe.userId = userId
        recipe.name = response.name
        recipe.description = response.description
        recipe.totalWeightG = response.totalWeightG
        recipe.totalPortions = response.totalPortions
        recipe.totalCalories = response.totalCalories
        recipe.totalProteinG = response.totalProteinG
        recipe.totalFatG = response.totalFatG
        recipe.totalCarbsG = response.totalCarbsG
        recipe.totalFiberG = response.totalFiberG
        recipe.caloriesPer100g = response.caloriesPer100g ?? per100g(total: response.totalCalories, weight: response.totalWeightG)
        recipe.proteinPer100g = response.proteinPer100g ?? per100g(total: response.totalProteinG, weight: response.totalWeightG)
        recipe.fatPer100g = response.fatPer100g ?? per100g(total: response.totalFatG, weight: response.totalWeightG)
        recipe.carbsPer100g = response.carbsPer100g ?? per100g(total: response.totalCarbsG, weight: response.totalWeightG)
        recipe.weightPerPortionG = response.totalPortions.map { response.totalWeightG / Double($0) }
        recipe.cookedAt = response.cookedAt
        recipe.archived = response.archived
        recipe.timesUsed = response.timesUsed
        recipe.lastUsedAt = response.lastUsedAt
        recipe.updatedAt = response.updatedAt
        return recipe
    }

    private nonisolated static func makeBatchRecipeIngredients(
        from draft: NutritionBatchRecipeDraft,
        batchRecipeId: UUID,
        updatedAt: Date? = nil
    ) -> [BatchRecipeIngredient] {
        draft.ingredients.enumerated().map { index, ingredient in
            makeBatchRecipeIngredient(
                from: ingredient,
                batchRecipeId: batchRecipeId,
                sortOrder: index,
                updatedAt: updatedAt
            )
        }
    }

    private nonisolated static func makeBatchRecipeIngredient(
        from ingredient: NutritionBatchRecipeDraftIngredient,
        batchRecipeId: UUID,
        sortOrder: Int,
        updatedAt: Date? = nil
    ) -> BatchRecipeIngredient {
        var item = BatchRecipeIngredient(
            id: ingredient.id,
            batchRecipeId: batchRecipeId,
            name: ingredient.name,
            weightG: ingredient.weightG,
            calories: ingredient.calories,
            proteinG: ingredient.proteinG,
            fatG: ingredient.fatG,
            carbsG: ingredient.carbsG
        )
        item.brand = ingredient.brand
        item.barcode = ingredient.barcode
        item.catalogItemId = ingredient.catalogItemId
        item.userFoodId = ingredient.userFoodId
        item.fiberG = ingredient.fiberG
        item.sortOrder = sortOrder
        if let updatedAt {
            item.createdAt = updatedAt
            item.updatedAt = updatedAt
        }
        return item
    }

    private nonisolated static func makeBatchDraftIngredient(
        from ingredient: BatchRecipeIngredient
    ) -> NutritionBatchRecipeDraftIngredient {
        NutritionBatchRecipeDraftIngredient(
            id: ingredient.id,
            name: ingredient.name,
            brand: ingredient.brand,
            barcode: ingredient.barcode,
            catalogItemId: ingredient.catalogItemId,
            userFoodId: ingredient.userFoodId,
            weightG: ingredient.weightG,
            calories: ingredient.calories,
            proteinG: ingredient.proteinG,
            fatG: ingredient.fatG,
            carbsG: ingredient.carbsG,
            fiberG: ingredient.fiberG
        )
    }

    private nonisolated static func makeBatchRecipePayload(
        from draft: NutritionBatchRecipeDraft,
        includeArchived: Bool
    ) -> NutritionBatchRecipePayload {
        NutritionBatchRecipePayload(
            id: draft.id,
            name: draft.name,
            description: draft.description,
            cookedAt: draft.cookedAt,
            totalWeightG: draft.totalWeightG,
            totalPortions: draft.totalPortions,
            ingredients: draft.ingredients.map { ingredient in
                NutritionBatchRecipeIngredientPayload(
                    id: ingredient.id,
                    name: ingredient.name,
                    brand: ingredient.brand,
                    barcode: ingredient.barcode,
                    catalogItemId: ingredient.catalogItemId,
                    userFoodId: ingredient.userFoodId,
                    weightG: ingredient.weightG,
                    macrosTotal: NutritionBatchMacroSnapshot(
                        weightG: ingredient.weightG,
                        calories: ingredient.calories,
                        proteinG: ingredient.proteinG,
                        fatG: ingredient.fatG,
                        carbsG: ingredient.carbsG,
                        fiberG: ingredient.fiberG
                    )
                )
            },
            archived: includeArchived ? draft.archived : nil
        )
    }

    private nonisolated static func makeMealTemplateCreatePayload(
        from draft: NutritionMealTemplateCreateDraft
    ) -> NutritionMealTemplateCreatePayload {
        let totals = templateTotals(for: draft.items)
        return NutritionMealTemplateCreatePayload(
            id: draft.id,
            name: draft.name,
            mealType: draft.mealType?.rawValue,
            templateItems: draft.items,
            calories: totals.calories,
            proteinG: totals.protein,
            fatG: totals.fat,
            carbsG: totals.carbs,
            fiberG: totals.fiber,
            archived: draft.archived
        )
    }

    private nonisolated static func batchMacroSnapshot(
        recipe: BatchRecipe,
        weightG: Double
    ) -> NutritionBatchMacroSnapshot {
        let factor = weightG / 100
        let caloriesPer100g = recipe.caloriesPer100g ?? recipe.derivedCaloriesPer100g
        let proteinPer100g = recipe.proteinPer100g ?? recipe.derivedProteinPer100g
        let fatPer100g = recipe.fatPer100g ?? recipe.derivedFatPer100g
        let carbsPer100g = recipe.carbsPer100g ?? recipe.derivedCarbsPer100g
        let fiberPer100g = recipe.totalWeightG > 0 ? recipe.totalFiberG.map { $0 * 100 / recipe.totalWeightG } : nil

        return NutritionBatchMacroSnapshot(
            weightG: weightG,
            calories: caloriesPer100g * factor,
            proteinG: proteinPer100g * factor,
            fatG: fatPer100g * factor,
            carbsG: carbsPer100g * factor,
            fiberG: fiberPer100g.map { $0 * factor }
        )
    }

    private nonisolated static func batchConsumption(
        recipe: BatchRecipe,
        consumedWeightG: Double
    ) -> (weightRemainingG: Double, portionsRemaining: Double?) {
        let weightRemainingG = max(recipe.totalWeightG - consumedWeightG, 0)
        let portionsRemaining = recipe.totalPortions.flatMap { portions -> Double? in
            guard portions > 0, recipe.totalWeightG > 0 else { return nil }
            return weightRemainingG / (recipe.totalWeightG / Double(portions))
        }
        return (weightRemainingG, portionsRemaining)
    }

    private nonisolated static func loadLocalConsumedWeight(for batchId: UUID, db: Database) throws -> Double {
        try Double.fetchOne(
            db,
            sql: """
                SELECT COALESCE(SUM(fi.weight_g), 0)
                FROM food_items fi
                JOIN food_logs fl
                  ON fl.id = fi.food_log_id
                WHERE (fi.batch_recipe_id = ? OR fi.batch_recipe_id = ?)
                  AND fl.deleted_at IS NULL
                """,
            arguments: [batchId, batchId.uuidString]
        ) ?? 0
    }

    private nonisolated static func batchRecipe(
        _ detail: NutritionBatchRecipeDetail,
        matches draft: NutritionBatchRecipeDraft
    ) -> Bool {
        guard detail.recipe.name == draft.name,
              normalizedText(detail.recipe.description) == normalizedText(draft.description),
              normalizedText(detail.recipe.cookedAt) == normalizedText(draft.cookedAt),
              detail.recipe.totalPortions == draft.totalPortions,
              detail.recipe.archived == draft.archived,
              numbersMatch(detail.recipe.totalWeightG, draft.totalWeightG),
              detail.ingredients.count == draft.ingredients.count else {
            return false
        }

        let expectedTotals = batchTotals(for: draft.ingredients)
        guard numbersMatch(detail.recipe.totalCalories, expectedTotals.calories),
              numbersMatch(detail.recipe.totalProteinG, expectedTotals.protein),
              numbersMatch(detail.recipe.totalFatG, expectedTotals.fat),
              numbersMatch(detail.recipe.totalCarbsG, expectedTotals.carbs),
              optionalNumbersMatch(detail.recipe.totalFiberG, expectedTotals.fiber) else {
            return false
        }

        for (stored, expected) in zip(detail.ingredients, draft.ingredients) {
            guard stored.name == expected.name,
                  normalizedText(stored.brand) == normalizedText(expected.brand),
                  normalizedText(stored.barcode) == normalizedText(expected.barcode),
                  stored.catalogItemId == expected.catalogItemId,
                  stored.userFoodId == expected.userFoodId,
                  numbersMatch(stored.weightG, expected.weightG),
                  numbersMatch(stored.calories, expected.calories),
                  numbersMatch(stored.proteinG, expected.proteinG),
                  numbersMatch(stored.fatG, expected.fatG),
                  numbersMatch(stored.carbsG, expected.carbsG),
                  optionalNumbersMatch(stored.fiberG, expected.fiberG) else {
                return false
            }
        }

        return true
    }

    private nonisolated static func mealTemplate(
        _ detail: NutritionMealTemplateDetail,
        matches draft: NutritionMealTemplateCreateDraft
    ) -> Bool {
        guard detail.template.name == draft.name,
              detail.template.mealType == draft.mealType,
              detail.template.archived == draft.archived,
              detail.items.count == draft.items.count else {
            return false
        }

        let expectedTotals = templateTotals(for: draft.items)
        guard numbersMatch(detail.template.calories, expectedTotals.calories),
              numbersMatch(detail.template.proteinG, expectedTotals.protein),
              numbersMatch(detail.template.fatG, expectedTotals.fat),
              numbersMatch(detail.template.carbsG, expectedTotals.carbs),
              optionalNumbersMatch(detail.template.fiberG, expectedTotals.fiber) else {
            return false
        }

        return detail.items == draft.items
    }

    private nonisolated static func numbersMatch(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.001) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    private nonisolated static func optionalNumbersMatch(
        _ lhs: Double?,
        _ rhs: Double?,
        tolerance: Double = 0.001
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return numbersMatch(lhs, rhs, tolerance: tolerance)
        default:
            return false
        }
    }

    private nonisolated static func normalizedFoodItem(
        _ item: FoodItem,
        foodLogId: UUID,
        userId: UUID,
        fallbackCreatedAt: Date,
        updatedAt: Date
    ) -> FoodItem {
        var normalized = item
        normalized.foodLogId = foodLogId
        normalized.userId = userId
        normalized.name = normalized.name.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.brand = normalized.brand?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        normalized.barcode = normalized.barcode?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        normalized.createdAt = normalized.createdAt == .distantPast ? fallbackCreatedAt : normalized.createdAt
        normalized.updatedAt = updatedAt
        normalized.userAdjusted = true
        return normalized
    }

    private nonisolated static func makePatchPayloadItem(_ item: FoodItem) -> NutritionMealPatchItemPayload {
        NutritionMealPatchItemPayload(
            id: item.id,
            name: item.name,
            brand: normalizedText(item.brand),
            barcode: normalizedText(item.barcode),
            catalogItemId: item.catalogItemId,
            userFoodId: item.userFoodId,
            batchRecipeId: item.batchRecipeId,
            weightG: item.weightG,
            calories: item.calories,
            proteinG: item.proteinG,
            fatG: item.fatG,
            carbsG: item.carbsG,
            fiberG: item.fiberG,
            confidence: item.confidence,
            detectedByAi: item.detectedByAi,
            userAdjusted: item.userAdjusted
        )
    }

    private nonisolated static func pendingCreateDependency(for logId: UUID, in db: Database) -> UUID? {
        return try? UUID.fetchOne(
            db,
            sql: """
                SELECT id
                FROM outbox_events
                WHERE (id = ? OR id = ?)
                  AND path = 'api-food-log'
                  AND status IN (?, ?, ?)
                LIMIT 1
                """,
            arguments: [
                logId,
                logId.uuidString,
                OutboxStatus.pending.rawValue,
                OutboxStatus.failedRetryable.rawValue,
                OutboxStatus.inFlight.rawValue
            ]
        )
    }

    private nonisolated static func latestMutationDependency(for logId: UUID, in db: Database) -> UUID? {
        return try? UUID.fetchOne(
            db,
            sql: """
                SELECT id
                FROM outbox_events
                WHERE (
                        id = ? OR id = ?
                     OR path = ?
                     OR path = ?
                  )
                  AND status IN (?, ?, ?)
                ORDER BY created_at_local DESC
                LIMIT 1
                """,
            arguments: [
                logId,
                logId.uuidString,
                "api-food-log/\(logId.uuidString)",
                "api-food-log/\(logId.uuidString)/undo",
                OutboxStatus.pending.rawValue,
                OutboxStatus.failedRetryable.rawValue,
                OutboxStatus.inFlight.rawValue
            ]
        ) ?? pendingCreateDependency(for: logId, in: db)
    }

    private nonisolated static func latestTemplateMutationDependency(
        for templateId: UUID,
        in db: Database
    ) -> UUID? {
        try? UUID.fetchOne(
            db,
            sql: """
                SELECT id
                FROM outbox_events
                WHERE (
                        id = ? OR id = ?
                     OR path = ?
                     OR path = ?
                  )
                  AND status IN (?, ?, ?)
                ORDER BY created_at_local DESC
                LIMIT 1
                """,
            arguments: [
                templateId,
                templateId.uuidString,
                "api-nutrition-templates/\(templateId.uuidString)",
                "api-nutrition-templates/\(templateId.uuidString)/log",
                OutboxStatus.pending.rawValue,
                OutboxStatus.failedRetryable.rawValue,
                OutboxStatus.inFlight.rawValue
            ]
        )
    }

    private nonisolated static func latestBatchMutationDependency(
        for batchId: UUID,
        in db: Database
    ) -> UUID? {
        try? UUID.fetchOne(
            db,
            sql: """
                SELECT id
                FROM outbox_events
                WHERE (
                        id = ? OR id = ?
                     OR path = ?
                     OR path = ?
                  )
                  AND status IN (?, ?, ?)
                ORDER BY created_at_local DESC
                LIMIT 1
                """,
            arguments: [
                batchId,
                batchId.uuidString,
                "api-nutrition-batches/\(batchId.uuidString)",
                "api-nutrition-batches/\(batchId.uuidString)/log",
                OutboxStatus.pending.rawValue,
                OutboxStatus.failedRetryable.rawValue,
                OutboxStatus.inFlight.rawValue
            ]
        )
    }

    private nonisolated static func hasPendingBatchMutation(
        for batchId: UUID,
        in db: Database
    ) -> Bool {
        ((try? Int.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1
                    FROM outbox_events
                    WHERE (
                            id = ? OR id = ?
                         OR path = ?
                         OR path = ?
                      )
                      AND status IN (?, ?, ?)
                )
                """,
            arguments: [
                batchId,
                batchId.uuidString,
                "api-nutrition-batches/\(batchId.uuidString)",
                "api-nutrition-batches/\(batchId.uuidString)/log",
                OutboxStatus.pending.rawValue,
                OutboxStatus.failedRetryable.rawValue,
                OutboxStatus.inFlight.rawValue
            ]
        )) ?? 0) > 0
    }

    private func hasPendingTemplateMutation(for templateId: UUID) async throws -> Bool {
        try await dbQueue.read { db in
            Self.hasPendingTemplateMutation(for: templateId, in: db)
        }
    }

    private nonisolated static func hasPendingTemplateMutation(
        for templateId: UUID,
        in db: Database
    ) -> Bool {
        ((try? Int.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1
                    FROM outbox_events
                    WHERE (
                            id = ? OR id = ?
                         OR path = ?
                         OR path = ?
                      )
                      AND status IN (?, ?, ?)
                )
                """,
            arguments: [
                templateId,
                templateId.uuidString,
                "api-nutrition-templates/\(templateId.uuidString)",
                "api-nutrition-templates/\(templateId.uuidString)/log",
                OutboxStatus.pending.rawValue,
                OutboxStatus.failedRetryable.rawValue,
                OutboxStatus.inFlight.rawValue
            ]
        )) ?? 0) > 0
    }

    private nonisolated static func headersJson() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
    }

    private nonisolated static func normalizedText(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

extension NutritionService: NutritionMealManaging {}
extension NutritionService: NutritionMealTemplateManaging {}
extension NutritionService: NutritionBatchRecipeManaging {}

extension APIClient: NutritionHistoryAPIClient,
    NutritionMealDetailAPIClient,
    NutritionMealTemplateListAPIClient,
    NutritionMealTemplateDetailAPIClient,
    NutritionBatchRecipeListAPIClient,
    NutritionBatchRecipeDetailAPIClient {
    func fetchHistoricalFoodLogs(
        orderBy: String,
        ascending: Bool,
        limit: Int,
        offset: Int,
        exactMatch: [String: String]
    ) async throws -> [FoodLog] {
        try await fetch(
            from: "food_logs",
            since: nil,
            orderBy: orderBy,
            ascending: ascending,
            limit: limit,
            offset: offset,
            activeWindowDays: nil,
            exactMatch: exactMatch
        )
    }

    func fetchMealDetail(id: UUID) async throws -> NutritionMealRemoteDetailResponse {
        try await callEdgeRoute(
            function: "api-food-log",
            route: id.uuidString,
            method: "GET",
            queryItems: [],
            body: nil,
            headers: [:],
            maxAttempts: 3
        )
    }

    func fetchMealTemplates() async throws -> NutritionMealTemplateListResponse {
        try await callEdgeRoute(
            function: "api-nutrition-templates",
            route: "",
            method: "GET",
            queryItems: [],
            body: nil,
            headers: [:],
            maxAttempts: 3
        )
    }

    func fetchMealTemplateDetail(id: UUID) async throws -> NutritionMealTemplateRemoteDetailResponse {
        try await callEdgeRoute(
            function: "api-nutrition-templates",
            route: id.uuidString,
            method: "GET",
            queryItems: [],
            body: nil,
            headers: [:],
            maxAttempts: 3
        )
    }

    func fetchBatchRecipes(status: String, limit: Int?) async throws -> NutritionBatchRecipeListResponse {
        var queryItems = [URLQueryItem(name: "status", value: status)]
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        return try await callEdgeRoute(
            function: "api-nutrition-batches",
            route: "",
            method: "GET",
            queryItems: queryItems,
            body: nil,
            headers: [:],
            maxAttempts: 3
        )
    }

    func fetchBatchRecipeDetail(id: UUID) async throws -> NutritionBatchRecipeRemoteDetailResponse {
        try await callEdgeRoute(
            function: "api-nutrition-batches",
            route: id.uuidString,
            method: "GET",
            queryItems: [],
            body: nil,
            headers: [:],
            maxAttempts: 3
        )
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension NutritionDraftCandidateItem {
    func makeFoodItem(foodLogId: UUID, userId: UUID, timestamp: Date) -> FoodItem? {
        guard let weightG,
              let calories,
              let proteinG,
              let fatG,
              let carbsG else {
            return nil
        }

        var item = FoodItem(
            foodLogId: foodLogId,
            userId: userId,
            name: name,
            weightG: weightG,
            calories: calories,
            proteinG: proteinG,
            fatG: fatG,
            carbsG: carbsG
        )
        item.createdAt = timestamp
        item.updatedAt = timestamp
        item.brand = brand
        item.barcode = barcode
        item.catalogItemId = catalogItemId
        item.userFoodId = userFoodId
        item.fiberG = fiberG
        item.confidence = confidence
        item.detectedByAi = detectedByAi
        item.userAdjusted = false
        return item
    }
}
