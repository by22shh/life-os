import Foundation
import Observation
import GRDB

func localizedNutritionMealType(_ mealType: MealType?, emptyKey: String = "nutrition_not_set") -> String {
    guard let mealType else {
        return NSLocalizedString(emptyKey, comment: "")
    }
    switch mealType {
    case .breakfast:
        return String(localized: "nutrition_breakfast")
    case .lunch:
        return String(localized: "nutrition_lunch")
    case .dinner:
        return String(localized: "nutrition_dinner")
    case .snack:
        return String(localized: "nutrition_snack")
    }
}

func localizedNutritionMealContext(_ context: MealContext?, emptyKey: String = "nutrition_not_set") -> String {
    guard let context else {
        return NSLocalizedString(emptyKey, comment: "")
    }
    switch context {
    case .home:
        return String(localized: "nutrition_home")
    case .restaurant:
        return String(localized: "nutrition_restaurant")
    case .party:
        return String(localized: "nutrition_party")
    case .work:
        return String(localized: "nutrition_work")
    case .other:
        return String(localized: "nutrition_other")
    case .unknown:
        return String(localized: "nutrition_unknown")
    }
}

func localizedNutritionDefaultItemName(for mealType: MealType?) -> String {
    if let mealType {
        return localizedNutritionMealType(mealType)
    }
    return String(localized: "nutrition_default_item_name")
}

func localizedNutritionDeletedAt(_ date: Date) -> String {
    String(
        format: String(localized: "nutrition_deleted_at_format"),
        date.formatted(date: .abbreviated, time: .shortened)
    )
}

protocol NutritionMealLogging: Sendable {
    func logMeal(_ log: FoodLog) async throws
}

extension NutritionService: NutritionMealLogging {}

struct NutritionEditableMealItem: Equatable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var brand: String
    var barcode: String
    var catalogItemId: UUID?
    var userFoodId: UUID?
    var batchRecipeId: UUID?
    var weightG: Double
    var calories: Double
    var proteinG: Double
    var fatG: Double
    var carbsG: Double
    var fiberG: Double
    var confidence: Double?
    var detectedByAi: Bool
    var userAdjusted: Bool

    init(
        id: UUID = UUID(),
        name: String,
        brand: String = "",
        barcode: String = "",
        catalogItemId: UUID? = nil,
        userFoodId: UUID? = nil,
        batchRecipeId: UUID? = nil,
        weightG: Double = 100,
        calories: Double = 0,
        proteinG: Double = 0,
        fatG: Double = 0,
        carbsG: Double = 0,
        fiberG: Double = 0,
        confidence: Double? = nil,
        detectedByAi: Bool = false,
        userAdjusted: Bool = true
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
        self.detectedByAi = detectedByAi
        self.userAdjusted = userAdjusted
    }

    init(foodItem: FoodItem) {
        self.init(
            id: foodItem.id,
            name: foodItem.name,
            brand: foodItem.brand ?? "",
            barcode: foodItem.barcode ?? "",
            catalogItemId: foodItem.catalogItemId,
            userFoodId: foodItem.userFoodId,
            batchRecipeId: foodItem.batchRecipeId,
            weightG: foodItem.weightG,
            calories: foodItem.calories,
            proteinG: foodItem.proteinG,
            fatG: foodItem.fatG,
            carbsG: foodItem.carbsG,
            fiberG: foodItem.fiberG ?? 0,
            confidence: foodItem.confidence,
            detectedByAi: foodItem.detectedByAi,
            userAdjusted: foodItem.userAdjusted
        )
    }
}

@MainActor
@Observable
final class NutritionLogViewModel {
    let draft: NutritionLogDraft?
    let existingMealId: UUID?

    var isLoading = false
    var isSaving = false
    var isDeleting = false
    var isUndoing = false
    var didReviewLowConfidence = false
    var errorMessage: String?
    var dynamicHint: String = ""
    var loggedAt: Date
    var mealType: MealType?
    var mealContext: MealContext?
    var userNotes: String = ""
    var mealItems: [NutritionEditableMealItem] = []
    var isDeleted = false
    var deletedAt: Date?

    private var didLoadExistingMeal = false
    private var currentMethod: NutritionLogMethod?
    private var currentAIConfidence: Double?

    private let nutritionService: any NutritionMealLogging
    private let mealManager: any NutritionMealManaging
    private let dbQueue: DatabaseQueue

    init(
        method: NutritionLogMethod?,
        aiConfidence: Double?,
        draft: NutritionLogDraft? = nil,
        existingMealId: UUID? = nil,
        nutritionService: (any NutritionMealLogging)? = nil,
        mealManager: (any NutritionMealManaging)? = nil,
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue
    ) {
        self.draft = draft
        self.existingMealId = existingMealId
        self.loggedAt = draft?.loggedAt ?? Date()
        self.mealType = draft?.mealType
        self.currentMethod = method
        self.currentAIConfidence = aiConfidence
        self.nutritionService = nutritionService ?? NutritionService(dbQueue: dbQueue)
        self.mealManager = mealManager ?? NutritionService(dbQueue: dbQueue)
        self.dbQueue = dbQueue
        self.mealItems = Self.prefilledMealItems(from: draft, method: method)
    }

    var hasExistingMeal: Bool {
        existingMealId != nil
    }

    var hasEditableMealItems: Bool {
        !mealItems.isEmpty
    }

    var methodLabel: String {
        switch currentMethod {
        case .photo: return String(localized: "nutrition_method_vision")
        case .barcode: return String(localized: "nutrition_method_barcode")
        case .voice: return String(localized: "nutrition_method_voice")
        case .manual: return String(localized: "nutrition_method_manual")
        case .batch: return String(localized: "nutrition_method_batch")
        case .template: return String(localized: "nutrition_method_template")
        case .none: return String(localized: "continue")
        }
    }

    var displayConfidence: Double? {
        currentAIConfidence ?? draft?.confidence
    }

    var requiresEditFirst: Bool {
        NutritionReviewGate.requiresEditFirst(method: currentMethod, confidence: currentAIConfidence)
    }

    var canSave: Bool {
        !isBusy &&
            hasValidMealItems &&
            (!requiresEditFirst || didReviewLowConfidence) &&
            (hasSavableContent || canPersistReviewedPhotoPlaceholder)
    }

    var hasSavableContent: Bool {
        if !mealItems.isEmpty {
            return true
        }
        if let draftTotalMacros, draftTotalMacros.hasContent {
            return true
        }
        if persistableDraftItemsCount > 0 {
            return true
        }
        return false
    }

    private var canPersistReviewedPhotoPlaceholder: Bool {
        currentMethod == .photo &&
            didReviewLowConfidence &&
            !hasExistingMeal &&
            mealItems.isEmpty &&
            draftTotalMacros == nil &&
            persistableDraftItemsCount == 0
    }

    var hasValidMealItems: Bool {
        guard !mealItems.isEmpty else { return true }
        return mealItems.allSatisfy { item in
            Self.normalizedText(item.name) != nil &&
                item.weightG > 0 &&
                item.calories >= 0 &&
                item.proteinG >= 0 &&
                item.fatG >= 0 &&
                item.carbsG >= 0 &&
                item.fiberG >= 0
        }
    }

    var canDelete: Bool {
        hasExistingMeal && !isBusy && !isDeleted
    }

    var canUndoDelete: Bool {
        hasExistingMeal &&
            isDeleted &&
            !isBusy &&
            (deletedAt?.addingTimeInterval(24 * 60 * 60) ?? .distantPast) > Date()
    }

    var canEditMeal: Bool {
        hasExistingMeal && !isDeleted
    }

    var canRemoveItems: Bool {
        mealItems.count > 1
    }

    var isBusy: Bool {
        isLoading || isSaving || isDeleting || isUndoing
    }

    var saveButtonTitle: String {
        hasExistingMeal ? String(localized: "nutrition_save_changes") : String(localized: "nutrition_save_meal_cta")
    }

    var screenTitle: String {
        if isDeleted {
            return String(localized: "nutrition_meal_deleted")
        }
        return hasExistingMeal ? String(localized: "nutrition_meal_detail_title") : String(localized: "log_food")
    }

    var deletedStatusText: String? {
        guard let deletedAt else { return nil }
        return localizedNutritionDeletedAt(deletedAt)
    }

    var visibleMealTitle: String {
        if let mealType {
            return localizedNutritionMealType(mealType)
        }
        if let firstItemName = Self.normalizedText(mealItems.first?.name) {
            return firstItemName
        }
        if let summary = draftSummary {
            return summary
        }
        return String(localized: "nutrition_meal")
    }

    var mealTotals: (calories: Double, protein: Double, fat: Double, carbs: Double, fiber: Double?) {
        if !mealItems.isEmpty {
            let fiber = mealItems.reduce(0) { $0 + $1.fiberG }
            return (
                calories: mealItems.reduce(0) { $0 + $1.calories },
                protein: mealItems.reduce(0) { $0 + $1.proteinG },
                fat: mealItems.reduce(0) { $0 + $1.fatG },
                carbs: mealItems.reduce(0) { $0 + $1.carbsG },
                fiber: fiber > 0 ? fiber : nil
            )
        }
        if let totalMacros = draftTotalMacros, totalMacros.hasContent {
            return (
                calories: totalMacros.calories,
                protein: totalMacros.proteinG,
                fat: totalMacros.fatG,
                carbs: totalMacros.carbsG,
                fiber: totalMacros.fiberG
            )
        }
        return (0, 0, 0, 0, nil)
    }

    var draftSummary: String? {
        Self.normalizedText(draft?.summary)
    }

    var draftSourceText: String? {
        let normalized = Self.normalizedText(draft?.sourceText)
        guard normalized != draftSummary else { return nil }
        return normalized
    }

    var draftAnalysisSource: NutritionAnalysisSource? {
        draft?.analysisSource
    }

    var draftTotalMacros: NutritionDraftMacroSummary? {
        draft?.totalMacros
    }

    var draftSuggestions: [String] {
        draft?.suggestions ?? []
    }

    var draftWarnings: [String] {
        draft?.warnings ?? []
    }

    var draftMealType: MealType? {
        draft?.mealType
    }

    var draftCandidateItems: [NutritionDraftCandidateItem] {
        draft?.candidateItems ?? []
    }

    var recognizedBarcodes: [String] {
        draft?.recognizedBarcodes ?? []
    }

    var hasDraftPreview: Bool {
        draftSummary != nil ||
            draftSourceText != nil ||
            draftTotalMacros != nil ||
            !draftSuggestions.isEmpty ||
            !draftWarnings.isEmpty ||
            !draftCandidateItems.isEmpty ||
            !recognizedBarcodes.isEmpty
    }

    var persistableDraftItemsCount: Int {
        draftCandidateItems.filter(\.isPersistable).count
    }

    func loadMealDetailIfNeeded() async {
        guard let existingMealId, !didLoadExistingMeal else { return }
        isLoading = true
        defer {
            isLoading = false
            didLoadExistingMeal = true
        }

        do {
            let shouldFetchRemote = SupabaseConfig.isRuntimeConfigured && AuthManager.activeHasCloudSession
            guard let detail = try await mealManager.loadMealDetail(
                id: existingMealId,
                preferRemote: shouldFetchRemote
            ) else {
                throw NutritionError.mealNotFound
            }
            apply(detail: detail)
            errorMessage = nil
        } catch {
            errorMessage = Self.localizedErrorDescription(for: error)
        }
    }

    func loadDynamicHint() async {
        do {
            let target = try await resolvedDynamicTarget()
            guard let target else {
                dynamicHint = ""
                return
            }
            dynamicHint = String(
                format: String(localized: "nutrition_dynamic_adjustment_hint_format"),
                Int(target.calories.rounded()),
                Int(target.protein.rounded()),
                Int(target.fat.rounded()),
                Int(target.carbs.rounded())
            )
        } catch {
            dynamicHint = ""
        }
    }

    func addMealItem() {
        let defaultName = localizedNutritionDefaultItemName(for: mealType)
        mealItems.append(NutritionEditableMealItem(name: defaultName, calories: 100, proteinG: 0, fatG: 0, carbsG: 0))
    }

    func removeMealItem(id: UUID) {
        guard mealItems.count > 1 else {
            errorMessage = NutritionError.invalidMealItem(
                reason: String(localized: "nutrition_validation_at_least_one_item_required")
            ).errorDescription
            return
        }
        mealItems.removeAll { $0.id == id }
    }

    func save() async -> Bool {
        guard canSave else { return false }
        if hasExistingMeal {
            return await updateExistingMeal()
        }
        return await createNewMeal()
    }

    func deleteMeal() async -> Bool {
        guard let existingMealId, canDelete else { return false }
        isDeleting = true
        defer { isDeleting = false }

        do {
            deletedAt = try await mealManager.deleteMeal(id: existingMealId)
            isDeleted = true
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.localizedErrorDescription(for: error)
            return false
        }
    }

    func undoDeleteMeal() async -> Bool {
        guard let existingMealId, canUndoDelete else { return false }
        isUndoing = true
        defer { isUndoing = false }

        do {
            try await mealManager.undoDeleteMeal(id: existingMealId)
            isDeleted = false
            deletedAt = nil
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.localizedErrorDescription(for: error)
            return false
        }
    }

    private func createNewMeal() async -> Bool {
        isSaving = true
        defer { isSaving = false }

        do {
            let now = Date()
            let userId = try await latestUserId()

            let inputMethod = currentMethod?.asInputMethod ?? .manual
            let loggedAt = draft?.loggedAt ?? now
            let loggedDate = draft?.loggedDate ?? Self.localDateString(loggedAt)

            var log = FoodLog(
                userId: userId,
                loggedAt: loggedAt,
                loggedDate: loggedDate,
                inputMethod: inputMethod,
                calories: 0,
                proteinG: 0,
                fatG: 0,
                carbsG: 0
            )
            log.loggedTimezone = TimeZone.current.identifier
            log.loggedUtcOffsetMinutes = TimeZone.current.secondsFromGMT(for: loggedAt) / 60
            if let currentAIConfidence {
                log.aiConfidence = currentAIConfidence
            } else {
                log.aiConfidence = currentMethod == .photo ? 0.0 : nil
            }
            if let summary = draftSummary {
                log.aiContextAnalysis = summary
            } else if let sourceText = draftSourceText {
                log.aiContextAnalysis = sourceText
            }
            log.mealType = mealType ?? draftMealType
            log.context = mealContext
            log.userNotes = Self.normalizedText(userNotes)
            if let draft, draft.hasStructuredContent, currentMethod != .manual {
                let payload = draft.aiDetectedPayload
                if payload.hasContent {
                    log.aiDetectedItems = try JSONEncoder().encode(payload)
                }
            }
            let persistedMealItems = try mealItems.map {
                try Self.makeFoodItem(
                    from: $0,
                    mealId: log.id,
                    userId: userId,
                    createdAt: now
                )
            }

            let persistableItems = draftCandidateItems.filter(\.isPersistable)
            if !persistedMealItems.isEmpty {
                log.calories = persistedMealItems.reduce(0) { $0 + $1.calories }
                log.proteinG = persistedMealItems.reduce(0) { $0 + $1.proteinG }
                log.fatG = persistedMealItems.reduce(0) { $0 + $1.fatG }
                log.carbsG = persistedMealItems.reduce(0) { $0 + $1.carbsG }
                let totalFiber = persistedMealItems.reduce(0) { $0 + ($1.fiberG ?? 0) }
                log.fiberG = totalFiber > 0 ? totalFiber : nil
            } else if !persistableItems.isEmpty {
                log.calories = persistableItems.compactMap(\.calories).reduce(0, +)
                log.proteinG = persistableItems.compactMap(\.proteinG).reduce(0, +)
                log.fatG = persistableItems.compactMap(\.fatG).reduce(0, +)
                log.carbsG = persistableItems.compactMap(\.carbsG).reduce(0, +)
                let totalFiber = persistableItems.compactMap(\.fiberG).reduce(0, +)
                log.fiberG = totalFiber > 0 ? totalFiber : nil
            } else if let totalMacros = draftTotalMacros, totalMacros.hasContent {
                log.calories = totalMacros.calories
                log.proteinG = totalMacros.proteinG
                log.fatG = totalMacros.fatG
                log.carbsG = totalMacros.carbsG
                log.fiberG = totalMacros.fiberG
            }
            log.applyReviewGate()
            if draftAnalysisSource == .onDeviceFallback || !draftWarnings.isEmpty {
                log.needsReview = true
            }

            if !persistedMealItems.isEmpty {
                try await mealManager.persist(log: log, items: persistedMealItems)
            } else if persistableItems.isEmpty {
                try await nutritionService.logMeal(log)
            } else {
                try await mealManager.persist(log: log, detectedItems: persistableItems)
            }

            errorMessage = nil
            return true
        } catch {
#if DEBUG
            fputs("NutritionLogViewModel.save failed: \(error)\n", stderr)
#endif
            errorMessage = Self.localizedErrorDescription(for: error)
            return false
        }
    }

    private func updateExistingMeal() async -> Bool {
        guard let existingMealId else { return false }
        isSaving = true
        defer { isSaving = false }

        do {
            let userId = try latestUserIdSync()
            let updatedItems = try mealItems.map { editable in
                try Self.makeFoodItem(
                    from: editable,
                    mealId: existingMealId,
                    userId: userId
                )
            }
            let update = NutritionMealUpdateDraft(
                id: existingMealId,
                loggedAt: loggedAt,
                loggedDate: Self.localDateString(loggedAt),
                mealType: mealType,
                context: mealContext,
                userNotes: Self.normalizedText(userNotes),
                items: updatedItems
            )
            try await mealManager.updateMeal(update)

            currentAIConfidence = nil
            didReviewLowConfidence = true
            errorMessage = nil
            mealItems = updatedItems.map(NutritionEditableMealItem.init(foodItem:))
            return true
        } catch {
            errorMessage = Self.localizedErrorDescription(for: error)
            return false
        }
    }

    private func apply(detail: NutritionMealDetail) {
        currentMethod = detail.log.inputMethod.asLogMethod
        currentAIConfidence = detail.log.aiConfidence
        loggedAt = detail.log.loggedAt
        mealType = detail.log.mealType
        mealContext = detail.log.context
        userNotes = detail.log.userNotes ?? ""
        isDeleted = detail.log.deletedAt != nil
        deletedAt = detail.log.deletedAt
        didReviewLowConfidence = !NutritionReviewGate.requiresEditFirst(
            method: currentMethod,
            confidence: currentAIConfidence
        ) || detail.log.userCorrected

        if !detail.items.isEmpty {
            mealItems = detail.items.map(NutritionEditableMealItem.init(foodItem:))
        } else {
            mealItems = [Self.syntheticMealItem(from: detail.log)]
        }
    }

    private func resolvedDynamicTarget() async throws -> (calories: Double, protein: Double, fat: Double, carbs: Double)? {
        guard let authId = AuthManager.activeAuthId?.uuidString else {
            return nil
        }

        return try await dbQueue.read { db -> (calories: Double, protein: Double, fat: Double, carbs: Double)? in
            guard let userId = try Self.latestUserId(authId: authId, db: db) else { return nil }

            let effectiveWeight = try WeightResolution.getEffectiveWeight(userId: userId, db: db) ?? 70.0
            let recoveryScore = try Double.fetchOne(
                db,
                sql: """
                    SELECT recovery_score
                    FROM physiological_states
                    WHERE user_id = ? OR user_id = ?
                    ORDER BY date DESC
                    LIMIT 1
                    """,
                arguments: [userId, userId.uuidString]
            ) ?? 50.0
            let activeEnergy = try Int.fetchOne(
                db,
                sql: """
                    SELECT daily_active_calories
                    FROM training_loads
                    WHERE user_id = ? OR user_id = ?
                    ORDER BY date DESC
                    LIMIT 1
                    """,
                arguments: [userId, userId.uuidString]
            )
            let dailyTrimp = try Double.fetchOne(
                db,
                sql: """
                    SELECT daily_trimp
                    FROM training_loads
                    WHERE user_id = ? OR user_id = ?
                    ORDER BY date DESC
                    LIMIT 1
                    """,
                arguments: [userId, userId.uuidString]
            )

            let baseCalories = 500.0
            let baseProtein = 30.0
            let baseFat = 20.0
            let baseCarbs = 50.0
            let weightFactor = NutritionTargetEngine.weightFactor(effectiveWeightKg: effectiveWeight)
            let recoveryAdjustment = NutritionTargetEngine.recoveryAdjustment(recoveryScore: recoveryScore)
            let trainingAdjustment = NutritionTargetEngine.trainingAdjustmentKcal(
                activeEnergyKcal: activeEnergy.map(Double.init),
                dailyTrimp: dailyTrimp,
                effectiveWeightKg: effectiveWeight
            )

            let calories = max(
                100,
                (baseCalories * weightFactor * recoveryAdjustment.calorieMultiplier) + Double(trainingAdjustment)
            )
            let protein = max(
                10,
                (baseProtein * weightFactor) + (recoveryAdjustment.proteinDeltaGPerKg * effectiveWeight)
            )
            let fat = max(5, baseFat * weightFactor)
            let carbs = max(5, baseCarbs * recoveryAdjustment.carbMultiplier * weightFactor)

            return (calories, protein, fat, carbs)
        }
    }

    private func latestUserId() async throws -> UUID {
        guard let authId = AuthManager.activeAuthId?.uuidString else {
            throw SyncError.networkUnavailable
        }

        return try await dbQueue.read { db in
            guard let userId = try Self.latestUserId(authId: authId, db: db) else {
                throw SyncError.networkUnavailable
            }
            return userId
        }
    }

    private func latestUserIdSync() throws -> UUID {
        guard let authId = AuthManager.activeAuthId?.uuidString else {
            throw SyncError.networkUnavailable
        }

        return try dbQueue.read { db in
            guard let userId = try Self.latestUserId(authId: authId, db: db) else {
                throw SyncError.networkUnavailable
            }
            return userId
        }
    }

    nonisolated private static func latestUserId(authId: String, db: Database) throws -> UUID? {
        try UserIdentityLookup.resolveUserId(authId: authId, db: db)
    }

    private static func localDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func normalizedText(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func localizedErrorDescription(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        return SyncError.serverError(code: 0, message: nil).errorDescription ?? String(localized: "error.unknown")
    }

    private static func syntheticMealItem(from log: FoodLog) -> NutritionEditableMealItem {
        NutritionEditableMealItem(
            name: localizedNutritionMealType(log.mealType, emptyKey: "nutrition_meal"),
            weightG: 100,
            calories: max(log.calories, 0),
            proteinG: max(log.proteinG, 0),
            fatG: max(log.fatG, 0),
            carbsG: max(log.carbsG, 0),
            fiberG: max(log.fiberG ?? 0, 0),
            confidence: log.aiConfidence,
            detectedByAi: log.inputMethod != .manual,
            userAdjusted: log.userCorrected
        )
    }

    private static func prefilledMealItems(
        from draft: NutritionLogDraft?,
        method: NutritionLogMethod?
    ) -> [NutritionEditableMealItem] {
        guard method == .manual, let draft else { return [] }

        return draft.candidateItems.compactMap { item in
            guard item.isPersistable,
                  let weightG = item.weightG,
                  let calories = item.calories,
                  let proteinG = item.proteinG,
                  let fatG = item.fatG,
                  let carbsG = item.carbsG else {
                return nil
            }

            return NutritionEditableMealItem(
                id: item.id,
                name: item.name,
                brand: item.brand ?? "",
                barcode: item.barcode ?? "",
                catalogItemId: item.catalogItemId,
                userFoodId: item.userFoodId,
                weightG: weightG,
                calories: calories,
                proteinG: proteinG,
                fatG: fatG,
                carbsG: carbsG,
                fiberG: item.fiberG ?? 0,
                confidence: item.confidence,
                detectedByAi: item.detectedByAi,
                userAdjusted: false
            )
        }
    }

    private static func makeFoodItem(
        from editable: NutritionEditableMealItem,
        mealId: UUID,
        userId: UUID,
        createdAt: Date? = nil
    ) throws -> FoodItem {
        let name = editable.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw NutritionError.invalidMealItem(reason: String(localized: "nutrition_validation_name_required"))
        }
        guard editable.weightG > 0 else {
            throw NutritionError.invalidMealItem(reason: String(localized: "nutrition_validation_weight_positive"))
        }
        guard editable.calories >= 0,
              editable.proteinG >= 0,
              editable.fatG >= 0,
              editable.carbsG >= 0,
              editable.fiberG >= 0 else {
            throw NutritionError.invalidMealItem(reason: String(localized: "nutrition_validation_macros_non_negative"))
        }

        var item = FoodItem(
            id: editable.id,
            foodLogId: mealId,
            userId: userId,
            name: name,
            weightG: editable.weightG,
            calories: editable.calories,
            proteinG: editable.proteinG,
            fatG: editable.fatG,
            carbsG: editable.carbsG
        )
        item.brand = normalizedText(editable.brand)
        item.barcode = normalizedText(editable.barcode)
        item.catalogItemId = editable.catalogItemId
        item.userFoodId = editable.userFoodId
        item.batchRecipeId = editable.batchRecipeId
        item.fiberG = editable.fiberG > 0 ? editable.fiberG : nil
        item.confidence = editable.confidence
        item.detectedByAi = editable.detectedByAi
        item.userAdjusted = true
        item.createdAt = createdAt ?? .distantPast
        item.updatedAt = createdAt ?? item.updatedAt
        return item
    }
}

#if DEBUG
extension NutritionLogViewModel {
    typealias TestDynamicTarget = (calories: Double, protein: Double, fat: Double, carbs: Double)

    func _testOverrideState(
        isSaving: Bool,
        didReviewLowConfidence: Bool,
        errorMessage: String?,
        dynamicHint: String
    ) {
        self.isSaving = isSaving
        self.didReviewLowConfidence = didReviewLowConfidence
        self.errorMessage = errorMessage
        self.dynamicHint = dynamicHint
    }

    func _testResolvedDynamicTarget() async throws -> TestDynamicTarget? {
        try await resolvedDynamicTarget()
    }

    nonisolated static func _testLatestUserId(authId: String, db: Database) throws -> UUID? {
        try latestUserId(authId: authId, db: db)
    }

    static func _testLocalDateString(_ date: Date) -> String {
        localDateString(date)
    }
}
#endif
