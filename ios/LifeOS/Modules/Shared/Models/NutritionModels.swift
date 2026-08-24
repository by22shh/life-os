// MARK: - Nutrition Models
// Source of truth: life_os_api_specification.md
// Tables: food_logs, food_items, daily_nutrition_targets,
//         food_catalog_items, user_foods, user_food_favorites,
//         batch_recipes, batch_recipe_ingredients, meal_templates

import Foundation

// MARK: - Food Log

/// Individual meal entry (parent of food_items).
struct FoodLog: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var createdAt: Date
    var updatedAt: Date
    var loggedAt: Date               // When meal was actually eaten
    var loggedDate: String           // YYYY-MM-DD user-local date (authoritative)
    var loggedTimezone: String?      // IANA timezone at log time
    var loggedUtcOffsetMinutes: Int? // UTC offset at log time
    var locationLat: Double?
    var locationLng: Double?

    // Input method
    var inputMethod: NutritionInputMethod

    // Context
    var mealType: MealType?
    var context: MealContext?

    // Timing context
    var preWorkout: Bool
    var postWorkout: Bool
    var minutesSinceWorkout: Int?

    // Macros (totals for the meal)
    var calories: Double
    var proteinG: Double
    var fatG: Double
    var carbsG: Double
    var fiberG: Double?
    var sugarG: Double?

    // Recovery-related
    var alcoholUnits: Double?        // 1 unit = 10g ethanol
    var caffeineMg: Int?

    // Micronutrients (optional)
    var sodiumMg: Double?
    var potassiumMg: Double?
    var calciumMg: Double?
    var ironMg: Double?
    var vitaminDMcg: Double?
    var vitaminB12Mcg: Double?

    // AI data
    var imageUrl: String?
    var imageUploadedAt: Date?
    var aiDetectedItems: Data?       // JSON blob
    var aiConfidence: Double?        // 0-1
    var aiContextAnalysis: String?
    var needsReview: Bool

    // User feedback
    var userCorrected: Bool
    var userNotes: String?
    var aiFeedback: AIFeedback?
    var aiFeedbackDetails: String?
    var aiFeedbackAt: Date?

    // Soft delete
    var deletedAt: Date?
    var deletedReason: DeletedReason?

    // Vector sync
    var syncedToVectorDb: Bool
    var vectorId: String?

    init(
        id: UUID = UUID(),
        userId: UUID,
        loggedAt: Date = Date(),
        loggedDate: String,
        inputMethod: NutritionInputMethod,
        calories: Double,
        proteinG: Double,
        fatG: Double,
        carbsG: Double
    ) {
        self.id = id
        self.userId = userId
        self.createdAt = Date()
        self.updatedAt = Date()
        self.loggedAt = loggedAt
        self.loggedDate = loggedDate
        self.inputMethod = inputMethod
        self.calories = calories
        self.proteinG = proteinG
        self.fatG = fatG
        self.carbsG = carbsG
        self.preWorkout = false
        self.postWorkout = false
        self.needsReview = false
        self.userCorrected = false
        self.syncedToVectorDb = false
    }

    /// Invariant: confidence < 0.65 requires review.
    var requiresReview: Bool {
        guard let aiConfidence else { return false }
        return aiConfidence < 0.65
    }

    /// Keeps persisted review gate aligned with current confidence.
    mutating func applyReviewGate() {
        needsReview = requiresReview
    }
}

// MARK: - Food Item

/// Individual food item within a meal.
struct FoodItem: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var foodLogId: UUID
    var userId: UUID
    var createdAt: Date
    var updatedAt: Date

    var name: String
    var brand: String?
    var barcode: String?
    var catalogItemId: UUID?
    var userFoodId: UUID?
    var batchRecipeId: UUID?
    var weightG: Double

    // Macros (per item)
    var calories: Double
    var proteinG: Double
    var fatG: Double
    var carbsG: Double
    var fiberG: Double?

    // AI
    var confidence: Double?
    var detectedByAi: Bool

    // User edit
    var userAdjusted: Bool

    init(
        id: UUID = UUID(),
        foodLogId: UUID,
        userId: UUID,
        name: String,
        weightG: Double,
        calories: Double,
        proteinG: Double,
        fatG: Double,
        carbsG: Double
    ) {
        self.id = id
        self.foodLogId = foodLogId
        self.userId = userId
        self.createdAt = Date()
        self.updatedAt = Date()
        self.name = name
        self.weightG = weightG
        self.calories = calories
        self.proteinG = proteinG
        self.fatG = fatG
        self.carbsG = carbsG
        self.detectedByAi = false
        self.userAdjusted = false
    }
}

// MARK: - Draft Logging Models

struct NutritionLogDraft: Equatable, Sendable, Identifiable {
    let id: UUID
    var method: NutritionLogMethod
    var confidence: Double?
    var loggedAt: Date
    var loggedDate: String
    var summary: String?
    var sourceText: String?
    var analysisSource: NutritionAnalysisSource?
    var totalMacros: NutritionDraftMacroSummary?
    var suggestions: [String]
    var warnings: [String]
    var mealType: MealType?
    var recognizedBarcodes: [String]
    var candidateItems: [NutritionDraftCandidateItem]

    init(
        id: UUID = UUID(),
        method: NutritionLogMethod,
        confidence: Double?,
        loggedAt: Date,
        loggedDate: String,
        summary: String? = nil,
        sourceText: String? = nil,
        analysisSource: NutritionAnalysisSource? = nil,
        totalMacros: NutritionDraftMacroSummary? = nil,
        suggestions: [String] = [],
        warnings: [String] = [],
        mealType: MealType? = nil,
        recognizedBarcodes: [String] = [],
        candidateItems: [NutritionDraftCandidateItem] = []
    ) {
        self.id = id
        self.method = method
        self.confidence = confidence
        self.loggedAt = loggedAt
        self.loggedDate = loggedDate
        self.summary = summary
        self.sourceText = sourceText
        self.analysisSource = analysisSource
        self.totalMacros = totalMacros
        self.suggestions = suggestions
        self.warnings = warnings
        self.mealType = mealType
        self.recognizedBarcodes = recognizedBarcodes
        self.candidateItems = candidateItems
    }

    var hasStructuredContent: Bool {
        let hasSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasSourceText = sourceText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return hasSummary ||
            hasSourceText ||
            analysisSource != nil ||
            totalMacros != nil ||
            !suggestions.isEmpty ||
            !warnings.isEmpty ||
            mealType != nil ||
            !recognizedBarcodes.isEmpty ||
            !candidateItems.isEmpty
    }

    var aiDetectedPayload: NutritionAIDetectedPayload {
        NutritionAIDetectedPayload(
            analysisSource: analysisSource,
            sourceText: sourceText,
            totalMacros: totalMacros,
            suggestions: suggestions.isEmpty ? nil : suggestions,
            warnings: warnings.isEmpty ? nil : warnings,
            mealType: mealType,
            recognizedBarcodes: recognizedBarcodes,
            candidateItems: candidateItems
        )
    }
}

enum NutritionAnalysisSource: String, Codable, Equatable, Sendable {
    case aiVision = "ai_vision"
    case onDeviceFallback = "on_device_fallback"
}

enum NutritionDetectedFoodCategory: String, Codable, Equatable, Sendable {
    case protein
    case carbs
    case fat
    case vegetable
    case fruit
    case mixed
}

struct NutritionDraftMacroSummary: Codable, Equatable, Sendable {
    var calories: Double
    var proteinG: Double
    var fatG: Double
    var carbsG: Double
    var fiberG: Double?

    var hasContent: Bool {
        calories > 0 || proteinG > 0 || fatG > 0 || carbsG > 0 || (fiberG ?? 0) > 0
    }
}

struct NutritionAIDetectedPayload: Codable, Equatable, Sendable {
    var analysisSource: NutritionAnalysisSource?
    var sourceText: String?
    var totalMacros: NutritionDraftMacroSummary?
    var suggestions: [String]?
    var warnings: [String]?
    var mealType: MealType?
    var recognizedBarcodes: [String]
    var candidateItems: [NutritionDraftCandidateItem]

    var hasContent: Bool {
        let hasSourceText = sourceText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasSuggestions = !(suggestions ?? []).isEmpty
        let hasWarnings = !(warnings ?? []).isEmpty
        return analysisSource != nil ||
            hasSourceText ||
            (totalMacros?.hasContent ?? false) ||
            hasSuggestions ||
            hasWarnings ||
            mealType != nil ||
            !recognizedBarcodes.isEmpty ||
            !candidateItems.isEmpty
    }
}

struct NutritionDraftCandidateItem: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var category: NutritionDetectedFoodCategory?
    var brand: String?
    var barcode: String?
    var notes: String?
    var catalogItemId: UUID?
    var userFoodId: UUID?
    var weightG: Double?
    var calories: Double?
    var proteinG: Double?
    var fatG: Double?
    var carbsG: Double?
    var fiberG: Double?
    var confidence: Double?
    var detectedByAi: Bool

    init(
        id: UUID = UUID(),
        name: String,
        category: NutritionDetectedFoodCategory? = nil,
        brand: String? = nil,
        barcode: String? = nil,
        notes: String? = nil,
        catalogItemId: UUID? = nil,
        userFoodId: UUID? = nil,
        weightG: Double? = nil,
        calories: Double? = nil,
        proteinG: Double? = nil,
        fatG: Double? = nil,
        carbsG: Double? = nil,
        fiberG: Double? = nil,
        confidence: Double? = nil,
        detectedByAi: Bool = true
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.brand = brand
        self.barcode = barcode
        self.notes = notes
        self.catalogItemId = catalogItemId
        self.userFoodId = userFoodId
        self.weightG = weightG
        self.calories = calories
        self.proteinG = proteinG
        self.fatG = fatG
        self.carbsG = carbsG
        self.fiberG = fiberG
        self.confidence = confidence
        self.detectedByAi = detectedByAi
    }

    var isPersistable: Bool {
        guard let weightG,
              let calories,
              let proteinG,
              let fatG,
              let carbsG else {
            return false
        }
        return weightG > 0 &&
            calories >= 0 &&
            proteinG >= 0 &&
            fatG >= 0 &&
            carbsG >= 0
    }
}

// MARK: - Daily Nutrition Target

struct DailyNutritionTarget: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var date: String  // YYYY-MM-DD

    // Base targets
    var baseCalories: Int?
    var baseProteinG: Int?
    var baseFatG: Int?
    var baseCarbsG: Int?

    // Adjustments
    var trainingAdjustmentKcal: Int?
    var recoveryAdjustmentKcal: Int?

    // Final targets
    var finalCalories: Int?
    var finalProteinG: Int?
    var finalFatG: Int?
    var finalCarbsG: Int?

    var adjustmentReason: String?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), userId: UUID, date: String) {
        self.id = id
        self.userId = userId
        self.date = date
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Food Catalog Item

/// Cached food database item (barcode/search results).
struct FoodCatalogItem: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var provider: FoodProvider
    var providerItemId: String?
    var barcode: String?
    var createdByUserId: UUID?

    var name: String
    var brand: String?
    var locale: String?
    var imageUrl: String?

    var servingSizeG: Double?
    var caloriesPer100g: Double
    var proteinPer100g: Double
    var fatPer100g: Double
    var carbsPer100g: Double
    var fiberPer100g: Double?
    var sugarPer100g: Double?
    var sodiumMgPer100g: Double?
    var sourceConfidence: Double?

    var fetchedAt: Date
    var expiresAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        provider: FoodProvider,
        name: String,
        caloriesPer100g: Double,
        proteinPer100g: Double,
        fatPer100g: Double,
        carbsPer100g: Double
    ) {
        self.id = id
        self.provider = provider
        self.name = name
        self.caloriesPer100g = caloriesPer100g
        self.proteinPer100g = proteinPer100g
        self.fatPer100g = fatPer100g
        self.carbsPer100g = carbsPer100g
        self.fetchedAt = Date()
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    enum CodingKeys: String, CodingKey {
        case id
        case provider
        case providerItemId = "provider_item_id"
        case barcode
        case createdByUserId = "created_by_user_id"
        case name
        case brand
        case locale
        case imageUrl = "image_url"
        case servingSizeG = "serving_size_g"
        case caloriesPer100g = "calories_per_100g"
        case proteinPer100g = "protein_per_100g"
        case fatPer100g = "fat_per_100g"
        case carbsPer100g = "carbs_per_100g"
        case fiberPer100g = "fiber_per_100g"
        case sugarPer100g = "sugar_per_100g"
        case sodiumMgPer100g = "sodium_mg_per_100g"
        case sourceConfidence = "source_confidence"
        case fetchedAt = "fetched_at"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - User Food

/// User-created custom food.
struct UserFood: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var name: String
    var brand: String?
    var barcode: String?
    var defaultServingG: Double?

    var caloriesPer100g: Double
    var proteinPer100g: Double
    var fatPer100g: Double
    var carbsPer100g: Double
    var fiberPer100g: Double?

    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        userId: UUID,
        name: String,
        caloriesPer100g: Double,
        proteinPer100g: Double,
        fatPer100g: Double,
        carbsPer100g: Double
    ) {
        self.id = id
        self.userId = userId
        self.name = name
        self.caloriesPer100g = caloriesPer100g
        self.proteinPer100g = proteinPer100g
        self.fatPer100g = fatPer100g
        self.carbsPer100g = carbsPer100g
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name
        case brand
        case barcode
        case defaultServingG = "default_serving_g"
        case caloriesPer100g = "calories_per_100g"
        case proteinPer100g = "protein_per_100g"
        case fatPer100g = "fat_per_100g"
        case carbsPer100g = "carbs_per_100g"
        case fiberPer100g = "fiber_per_100g"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - User Food Favorite

struct UserFoodFavorite: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var refType: FoodRefType
    var refId: UUID
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), userId: UUID, refType: FoodRefType, refId: UUID) {
        self.id = id
        self.userId = userId
        self.refType = refType
        self.refId = refId
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Batch Recipe

struct BatchRecipe: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var createdAt: Date
    var updatedAt: Date

    var name: String
    var description: String?
    var imageUrl: String?
    var totalWeightG: Double
    var totalPortions: Int?

    // Total macros (entire batch)
    var totalCalories: Double
    var totalProteinG: Double
    var totalFatG: Double
    var totalCarbsG: Double
    var totalFiberG: Double?
    var caloriesPer100g: Double?
    var proteinPer100g: Double?
    var fatPer100g: Double?
    var carbsPer100g: Double?
    var weightPerPortionG: Double?

    // Backward-compatible calculated fallbacks.
    var derivedCaloriesPer100g: Double { totalWeightG > 0 ? (totalCalories / totalWeightG) * 100 : 0 }
    var derivedProteinPer100g: Double { totalWeightG > 0 ? (totalProteinG / totalWeightG) * 100 : 0 }
    var derivedFatPer100g: Double { totalWeightG > 0 ? (totalFatG / totalWeightG) * 100 : 0 }
    var derivedCarbsPer100g: Double { totalWeightG > 0 ? (totalCarbsG / totalWeightG) * 100 : 0 }

    var cookedAt: String?  // YYYY-MM-DD
    var archived: Bool
    var timesUsed: Int
    var lastUsedAt: Date?

    var deletedAt: Date?
    var deletedReason: String?

    init(
        id: UUID = UUID(),
        userId: UUID,
        name: String,
        totalWeightG: Double,
        totalCalories: Double,
        totalProteinG: Double,
        totalFatG: Double,
        totalCarbsG: Double
    ) {
        self.id = id
        self.userId = userId
        self.createdAt = Date()
        self.updatedAt = Date()
        self.name = name
        self.totalWeightG = totalWeightG
        self.totalCalories = totalCalories
        self.totalProteinG = totalProteinG
        self.totalFatG = totalFatG
        self.totalCarbsG = totalCarbsG
        self.caloriesPer100g = totalWeightG > 0 ? (totalCalories / totalWeightG) * 100 : nil
        self.proteinPer100g = totalWeightG > 0 ? (totalProteinG / totalWeightG) * 100 : nil
        self.fatPer100g = totalWeightG > 0 ? (totalFatG / totalWeightG) * 100 : nil
        self.carbsPer100g = totalWeightG > 0 ? (totalCarbsG / totalWeightG) * 100 : nil
        self.archived = false
        self.timesUsed = 0
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case name
        case description
        case imageUrl = "image_url"
        case totalWeightG = "total_weight_g"
        case totalPortions = "total_portions"
        case totalCalories = "total_calories"
        case totalProteinG = "total_protein_g"
        case totalFatG = "total_fat_g"
        case totalCarbsG = "total_carbs_g"
        case totalFiberG = "total_fiber_g"
        case caloriesPer100g = "calories_per_100g"
        case proteinPer100g = "protein_per_100g"
        case fatPer100g = "fat_per_100g"
        case carbsPer100g = "carbs_per_100g"
        case weightPerPortionG = "weight_per_portion_g"
        case cookedAt = "cooked_at"
        case archived
        case timesUsed = "times_used"
        case lastUsedAt = "last_used_at"
        case deletedAt = "deleted_at"
        case deletedReason = "deleted_reason"
    }
}

// MARK: - Batch Recipe Ingredient

struct BatchRecipeIngredient: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var batchRecipeId: UUID
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
    var sugarG: Double?
    var sodiumMg: Double?
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        batchRecipeId: UUID,
        name: String,
        weightG: Double,
        calories: Double,
        proteinG: Double,
        fatG: Double,
        carbsG: Double
    ) {
        self.id = id
        self.batchRecipeId = batchRecipeId
        self.name = name
        self.weightG = weightG
        self.calories = calories
        self.proteinG = proteinG
        self.fatG = fatG
        self.carbsG = carbsG
        self.sortOrder = 0
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Meal Template

struct MealTemplate: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var createdAt: Date
    var updatedAt: Date

    var name: String
    var mealType: MealType?
    var templateItems: Data  // JSON blob of items

    // Totals for quick display
    var calories: Double
    var proteinG: Double
    var fatG: Double
    var carbsG: Double
    var fiberG: Double?

    var timesUsed: Int
    var lastUsedAt: Date?
    var archived: Bool

    var deletedAt: Date?
    var deletedReason: String?

    init(
        id: UUID = UUID(),
        userId: UUID,
        name: String,
        templateItems: Data,
        calories: Double,
        proteinG: Double,
        fatG: Double,
        carbsG: Double
    ) {
        self.id = id
        self.userId = userId
        self.createdAt = Date()
        self.updatedAt = Date()
        self.name = name
        self.templateItems = templateItems
        self.calories = calories
        self.proteinG = proteinG
        self.fatG = fatG
        self.carbsG = carbsG
        self.timesUsed = 0
        self.archived = false
    }
}

// MARK: - Supporting Enums

enum NutritionInputMethod: String, Codable, Sendable {
    case vision
    case barcode
    case batch
    case manual
    case voice
    case template
}

enum MealType: String, Codable, Sendable {
    case breakfast
    case lunch
    case dinner
    case snack
}

enum MealContext: String, Codable, Sendable {
    case home
    case restaurant
    case party
    case work
    case other
    case unknown
}

enum AIFeedback: String, Codable, Sendable {
    case accurate
    case slightlyOff = "slightly_off"
    case veryWrong = "very_wrong"
}

enum DeletedReason: String, Codable, Sendable {
    case userDeleted = "user_deleted"
    case merged
    case duplicate
}

enum FoodProvider: String, Codable, Sendable {
    case openFoodFacts = "open_food_facts"
    case lifeosLabelOcr = "lifeos_label_ocr"
    case usda
    case edamam
    case manualImport = "manual_import"
    case other
}

enum FoodRefType: String, Codable, Sendable {
    case catalog
    case custom
}
