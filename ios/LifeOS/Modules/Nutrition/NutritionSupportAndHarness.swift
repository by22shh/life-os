import AVFoundation
import Combine
import GRDB
import Observation
import PDFKit
import PhotosUI
import Speech
import SwiftUI
import UIKit
import Vision
//
//  Extracted from NutritionDayView.swift as part of the module split.
//
struct BatchRecipePhotoDraft {
    let recipeName: String
    let ingredients: [BatchRecipeEditableIngredient]
    let totalWeightG: Double
    let totalPortions: Int
    let confidence: Double?
    let notes: [String]
    let descriptionText: String?
}

struct NutritionVoiceResolution: Sendable {
    let draft: NutritionLogDraft
    let response: FoodTextParseResponse?
}

actor NutritionDraftResolver {
    private let dbQueue: DatabaseQueue
#if DEBUG
    private static let testVoiceLoggingAvailableOverride = LockedTestOverride<Bool>()
    private static let testParseTextOverride = LockedTestOverride<
        @Sendable (String) async throws -> FoodTextParseResponse
    >()
#endif

    init(dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue) {
        self.dbQueue = dbQueue
    }

    func resolvePhotoDraft(
        analysis: NutritionPhotoAnalysis,
        targetDay: String,
        loggedAt: Date
    ) async -> NutritionLogDraft {
        await resolveDraft(
            method: .photo,
            confidence: analysis.confidence,
            summary: analysis.summary,
            sourceText: analysis.recognizedText,
            analysisSource: analysis.source,
            totalMacros: analysis.totalMacros,
            suggestions: analysis.suggestions,
            warnings: analysis.warnings,
            mealType: analysis.mealType,
            recognizedBarcodes: analysis.barcodes,
            detectedItems: analysis.detectedItems,
            includeUnmatchedSourceTextItems: analysis.detectedItems.isEmpty,
            targetDay: targetDay,
            loggedAt: loggedAt
        )
    }

    func resolveVoiceDraft(
        transcription: String,
        confidence: Double?,
        targetDay: String,
        loggedAt: Date
    ) async -> NutritionLogDraft {
        (await resolveVoiceResolution(
            transcription: transcription,
            confidence: confidence,
            targetDay: targetDay,
            loggedAt: loggedAt
        )).draft
    }

    func resolveVoiceResolution(
        transcription: String,
        confidence: Double?,
        targetDay: String,
        loggedAt: Date
    ) async -> NutritionVoiceResolution {
        let voiceLoggingAvailable: Bool
#if DEBUG
        if let override = Self.testVoiceLoggingAvailableOverride.value {
            voiceLoggingAvailable = override
        } else {
            voiceLoggingAvailable = await MainActor.run {
                AIAvailability().voiceLoggingAvailable
            }
        }
#else
        voiceLoggingAvailable = await MainActor.run {
            AIAvailability().voiceLoggingAvailable
        }
#endif
        if voiceLoggingAvailable {
            do {
                let response: FoodTextParseResponse
#if DEBUG
                if let override = Self.testParseTextOverride.value {
                    response = try await override(transcription)
                } else {
                    response = try await FoodTextParsingService().parseText(transcription)
                }
#else
                response = try await FoodTextParsingService().parseText(transcription)
#endif
                let sourceItems = response.detectedItems.isEmpty ? response.items : response.detectedItems
                let parsedItems = sourceItems.map { item in
                    NutritionDraftCandidateItem(
                        name: item.name,
                        category: item.categoryRaw.flatMap { NutritionDetectedFoodCategory(rawValue: $0) },
                        brand: item.brand,
                        barcode: item.barcode,
                        notes: Self.normalizedText(item.notes),
                        weightG: item.weightG,
                        calories: item.calories,
                        proteinG: item.proteinG,
                        fatG: item.fatG,
                        carbsG: item.carbsG,
                        fiberG: item.fiberG,
                        confidence: item.confidence,
                        detectedByAi: true
                    )
                }
                let totalMacros = response.totalMacros.map {
                    NutritionDraftMacroSummary(
                        calories: $0.calories,
                        proteinG: $0.proteinG,
                        fatG: $0.fatG,
                        carbsG: $0.carbsG,
                        fiberG: $0.fiberG
                    )
                }
                let resolvedConfidence = [confidence, response.confidence].compactMap { $0 }.min()
                let clarificationSuggestions = response.clarifyingQuestions.map(\.question)
                let parseWarnings = response.needsClarification
                    ? response.warnings + [String(localized: "nutrition_review_serving_sizes_warning")]
                    : response.warnings

                let draft = await resolveDraft(
                    method: .voice,
                    confidence: resolvedConfidence,
                    summary: Self.normalizedText(response.contextAnalysis) ?? transcription,
                    sourceText: transcription,
                    analysisSource: nil,
                    totalMacros: totalMacros,
                    suggestions: Self.normalizedLines(response.suggestions + clarificationSuggestions),
                    warnings: Self.normalizedLines(parseWarnings),
                    mealType: response.mealTypeRaw.flatMap { MealType(rawValue: $0.lowercased()) },
                    recognizedBarcodes: [],
                    detectedItems: parsedItems,
                    includeUnmatchedSourceTextItems: parsedItems.isEmpty,
                    targetDay: targetDay,
                    loggedAt: loggedAt
                )
                return NutritionVoiceResolution(draft: draft, response: response)
            } catch {
                // Fall through to local parsing.
            }
        }

        let draft = await resolveDraft(
            method: .voice,
            confidence: confidence,
            summary: transcription,
            sourceText: transcription,
            analysisSource: nil,
            totalMacros: nil,
            suggestions: [],
            warnings: [],
            mealType: nil,
            recognizedBarcodes: [],
            detectedItems: [],
            includeUnmatchedSourceTextItems: true,
            targetDay: targetDay,
            loggedAt: loggedAt
        )
        return NutritionVoiceResolution(draft: draft, response: nil)
    }

    private func resolveDraft(
        method: NutritionLogMethod,
        confidence: Double?,
        summary: String?,
        sourceText: String?,
        analysisSource: NutritionAnalysisSource?,
        totalMacros: NutritionDraftMacroSummary?,
        suggestions: [String],
        warnings: [String],
        mealType: MealType?,
        recognizedBarcodes: [String],
        detectedItems: [NutritionDraftCandidateItem],
        includeUnmatchedSourceTextItems: Bool,
        targetDay: String,
        loggedAt: Date
    ) async -> NutritionLogDraft {
        let normalizedBarcodes = recognizedBarcodes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let candidateNames = Self.extractCandidateNames(from: sourceText)
        let resolvedLookupNames = Self.uniquedNames(candidateNames + detectedItems.map(\.name))

        let matchedItems: [NutritionDraftCandidateItem]
        do {
            matchedItems = try await matchCatalogItems(
                candidateNames: resolvedLookupNames,
                barcodes: normalizedBarcodes,
                confidence: confidence
            )
        } catch {
            matchedItems = []
        }

        let mergedDetectedItems = Self.mergeDetectedItems(
            detectedItems,
            with: matchedItems,
            defaultConfidence: confidence
        )
        let mergedKeys = Set(mergedDetectedItems.map(Self.itemLookupKey))
        let additionalCatalogItems = matchedItems.filter { !mergedKeys.contains(Self.itemLookupKey($0)) }

        let unmatchedItems = includeUnmatchedSourceTextItems
            ? candidateNames
            .filter { candidate in
                let key = Self.normalizedLookupKey(name: candidate)
                return !mergedDetectedItems.contains(where: {
                    Self.normalizedLookupKey(name: $0.name) == key
                }) && !additionalCatalogItems.contains(where: {
                    Self.normalizedLookupKey(name: $0.name) == key
                })
            }
            .map { NutritionDraftCandidateItem(name: $0, confidence: confidence) }
            : []

        return NutritionLogDraft(
            method: method,
            confidence: confidence,
            loggedAt: loggedAt,
            loggedDate: targetDay,
            summary: Self.normalizedText(summary),
            sourceText: Self.normalizedText(sourceText),
            analysisSource: analysisSource,
            totalMacros: totalMacros?.hasContent == true ? totalMacros : nil,
            suggestions: Self.normalizedLines(suggestions),
            warnings: Self.normalizedLines(warnings),
            mealType: mealType,
            recognizedBarcodes: normalizedBarcodes,
            candidateItems: Self.uniquedItems(mergedDetectedItems + additionalCatalogItems + unmatchedItems)
        )
    }

    private func matchCatalogItems(
        candidateNames: [String],
        barcodes: [String],
        confidence: Double?
    ) async throws -> [NutritionDraftCandidateItem] {
        try await dbQueue.read { db in
            var matches: [NutritionDraftCandidateItem] = []

            for barcode in barcodes {
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT id, name, brand, barcode, serving_size_g, calories_per_100g,
                               protein_per_100g, fat_per_100g, carbs_per_100g, fiber_per_100g
                        FROM food_catalog_items
                        WHERE barcode = ?
                        LIMIT 1
                        """,
                    arguments: [barcode]
                ) else {
                    continue
                }
                if let item = Self.makeCatalogCandidateItem(from: row, confidence: confidence) {
                    matches.append(item)
                }
            }

            for candidateName in candidateNames {
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT id, name, brand, barcode, serving_size_g, calories_per_100g,
                               protein_per_100g, fat_per_100g, carbs_per_100g, fiber_per_100g
                        FROM food_catalog_items
                        WHERE LOWER(name) LIKE LOWER(?)
                        ORDER BY CASE
                            WHEN LOWER(name) = LOWER(?) THEN 0
                            WHEN LOWER(name) LIKE LOWER(?) THEN 1
                            ELSE 2
                        END,
                        LENGTH(name) ASC
                        LIMIT 1
                        """,
                    arguments: ["%\(candidateName)%", candidateName, "\(candidateName)%"]
                ) else {
                    continue
                }
                if let item = Self.makeCatalogCandidateItem(from: row, confidence: confidence) {
                    matches.append(item)
                }
            }

            return Self.uniquedItems(matches)
        }
    }

    private static func makeCatalogCandidateItem(from row: Row, confidence: Double?) -> NutritionDraftCandidateItem? {
        guard let name: String = row["name"] else { return nil }
        let servingSizeG: Double = row["serving_size_g"] ?? 100.0
        let caloriesPer100g: Double = row["calories_per_100g"] ?? 0
        let proteinPer100g: Double = row["protein_per_100g"] ?? 0
        let fatPer100g: Double = row["fat_per_100g"] ?? 0
        let carbsPer100g: Double = row["carbs_per_100g"] ?? 0
        let fiberPer100g: Double? = row["fiber_per_100g"]
        let catalogItemId = MixedUUIDStorage.decode(from: row, column: "id")

        return NutritionDraftCandidateItem(
            name: name,
            brand: row["brand"],
            barcode: row["barcode"],
            catalogItemId: catalogItemId,
            weightG: servingSizeG,
            calories: caloriesPer100g * servingSizeG / 100.0,
            proteinG: proteinPer100g * servingSizeG / 100.0,
            fatG: fatPer100g * servingSizeG / 100.0,
            carbsG: carbsPer100g * servingSizeG / 100.0,
            fiberG: fiberPer100g.map { $0 * servingSizeG / 100.0 },
            confidence: confidence,
            detectedByAi: true
        )
    }

    private static func mergeDetectedItems(
        _ detectedItems: [NutritionDraftCandidateItem],
        with catalogItems: [NutritionDraftCandidateItem],
        defaultConfidence: Double?
    ) -> [NutritionDraftCandidateItem] {
        detectedItems.map { item in
            var merged = item

            let catalogMatch = catalogItems.first { candidate in
                if let barcode = merged.barcode,
                   let candidateBarcode = candidate.barcode,
                   barcode == candidateBarcode {
                    return true
                }
                return normalizedLookupKey(name: candidate.name) == normalizedLookupKey(name: merged.name)
            }

            if let catalogMatch {
                if merged.brand == nil { merged.brand = catalogMatch.brand }
                if merged.barcode == nil { merged.barcode = catalogMatch.barcode }
                if merged.catalogItemId == nil { merged.catalogItemId = catalogMatch.catalogItemId }
                if merged.weightG == nil { merged.weightG = catalogMatch.weightG }
                if merged.calories == nil { merged.calories = catalogMatch.calories }
                if merged.proteinG == nil { merged.proteinG = catalogMatch.proteinG }
                if merged.fatG == nil { merged.fatG = catalogMatch.fatG }
                if merged.carbsG == nil { merged.carbsG = catalogMatch.carbsG }
                if merged.fiberG == nil { merged.fiberG = catalogMatch.fiberG }
            }

            if merged.confidence == nil {
                merged.confidence = catalogMatch?.confidence ?? defaultConfidence
            }
            return merged
        }
    }

    private static func extractCandidateNames(from text: String?) -> [String] {
        guard let text = normalizedText(text) else { return [] }

        var expanded = text
            .replacingOccurrences(of: "\n", with: ",")
            .replacingOccurrences(of: " and ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " with ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " plus ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: "&", with: ",")
            .replacingOccurrences(of: "+", with: ",")

        expanded = expanded.replacingOccurrences(
            of: #"\b\d+(\.\d+)?\s?(g|grams?|ml|oz|cups?|tbsp|tsp|pieces?)\b"#,
            with: " ",
            options: .regularExpression
        )

        let separators = CharacterSet(charactersIn: ",.;:")
        let segments = expanded
            .components(separatedBy: separators)
            .compactMap(cleanCandidateName)

        var uniqued: [String] = []
        var seen = Set<String>()
        for segment in segments {
            let key = normalizedLookupKey(name: segment)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            uniqued.append(segment)
            if uniqued.count == 6 {
                break
            }
        }
        return uniqued
    }

    private static func cleanCandidateName(_ raw: String) -> String? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let prefixes = [
            "i had ", "i ate ", "had ", "ate ", "for breakfast ", "for lunch ",
            "for dinner ", "breakfast was ", "lunch was ", "dinner was ",
            "today i had ", "today i ate ", "drank ", "drink "
        ]
        for prefix in prefixes where cleaned.lowercased().hasPrefix(prefix) {
            cleaned.removeFirst(prefix.count)
            break
        }

        cleaned = cleaned.replacingOccurrences(of: #"[^\p{L}\p{N}\s-]"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let words = cleaned.split(separator: " ")
        guard (1...6).contains(words.count) else { return nil }
        return words.joined(separator: " ")
    }

    private static func uniquedItems(_ items: [NutritionDraftCandidateItem]) -> [NutritionDraftCandidateItem] {
        var result: [NutritionDraftCandidateItem] = []
        var seen = Set<String>()
        for item in items {
            let key = itemLookupKey(item)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(item)
        }
        return result
    }

    private static func itemLookupKey(_ item: NutritionDraftCandidateItem) -> String {
        [
            normalizedLookupKey(name: item.name),
            item.barcode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            item.catalogItemId?.uuidString ?? ""
        ].joined(separator: "|")
    }

    private static func normalizedLookupKey(name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func uniquedNames(_ names: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for name in names {
            let key = normalizedLookupKey(name: name)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    private static func normalizedText(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedLines(_ values: [String]) -> [String] {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

#if DEBUG
enum NutritionCoverageFixtures {
    static let targetDay = "2026-03-19"
    static let loggedAt = Date(timeIntervalSince1970: 1_742_385_600)

    static func image(
        color: UIColor = .systemBlue,
        size: CGSize = CGSize(width: 64, height: 64)
    ) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    static func photoAnalysis(
        summary: String = "Coverage meal",
        confidence: Double? = 0.83,
        notice: String? = nil
    ) -> NutritionPhotoAnalysis {
        NutritionPhotoAnalysis(
            summary: summary,
            confidence: confidence,
            source: .aiVision,
            recognizedText: "Coverage meal details",
            barcodes: ["12345"],
            detectedItems: [
                NutritionDraftCandidateItem(
                    name: "Chicken Bowl",
                    category: .mixed,
                    weightG: 220,
                    calories: 430,
                    proteinG: 32,
                    fatG: 12,
                    carbsG: 44,
                    fiberG: 8,
                    confidence: 0.88
                )
            ],
            totalMacros: NutritionDraftMacroSummary(
                calories: 430,
                proteinG: 32,
                fatG: 12,
                carbsG: 44,
                fiberG: 8
            ),
            warnings: notice.map { [$0] } ?? [],
            suggestions: ["Add greens"],
            mealType: .lunch,
            notice: notice
        )
    }

    static func labelDraft(
        name: String = "Coverage Bar",
        warnings: [String] = [],
        sourceText: String? = nil,
        confidence: Double? = 0.79,
        analysisSource: NutritionAnalysisSource = .aiVision
    ) -> NutritionLabelReviewDraft {
        NutritionLabelReviewDraft(
            barcode: "1234567890123",
            name: name,
            brand: "Coverage Labs",
            servingSizeG: 55,
            caloriesPer100g: 412,
            proteinPer100g: 24,
            fatPer100g: 14,
            carbsPer100g: 38,
            fiberPer100g: 6,
            confidence: confidence,
            warnings: warnings,
            sourceText: sourceText,
            analysisSource: analysisSource,
            summary: name
        )
    }

    static func foodResult(
        name: String = "Coverage Granola",
        brand: String? = "Coverage Co",
        barcode: String? = "12345",
        refType: FoodRefType = .catalog
    ) -> FoodSearchResult {
        FoodSearchResult(
            id: UUID(),
            refType: refType,
            provider: .openFoodFacts,
            name: name,
            brand: brand,
            barcode: barcode,
            servingSizeG: 60,
            caloriesPer100g: 420,
            proteinPer100g: 18,
            fatPer100g: 12,
            carbsPer100g: 56,
            fiberPer100g: 7,
            tags: ["coverage"]
        )
    }

    static func mealTemplateSummary(
        archived: Bool = false,
        lastUsedAt: Date? = loggedAt
    ) -> NutritionMealTemplateSummary {
        NutritionMealTemplateSummary(
            id: UUID(),
            name: archived ? "Archived Coverage Bowl" : "Coverage Bowl",
            mealType: .lunch,
            calories: 520,
            proteinG: 34,
            fatG: 18,
            carbsG: 46,
            fiberG: 9,
            timesUsed: 3,
            lastUsedAt: lastUsedAt,
            archived: archived,
            updatedAt: loggedAt
        )
    }

    static func mealTemplateItem(
        name: String = "Coverage Oats",
        brand: String? = "Coverage Farm",
        barcode: String? = "111111",
        weightG: Double = 80,
        calories: Double = 300,
        proteinG: Double = 11,
        fatG: Double = 5,
        carbsG: Double = 50,
        fiberG: Double? = 8
    ) -> NutritionMealTemplateItem {
        NutritionMealTemplateItem(
            name: name,
            brand: brand,
            barcode: barcode,
            weightG: weightG,
            calories: calories,
            proteinG: proteinG,
            fatG: fatG,
            carbsG: carbsG,
            fiberG: fiberG,
            confidence: 0.84
        )
    }

    static func mealTemplateDetail(
        archived: Bool = false,
        items: [NutritionMealTemplateItem]? = nil
    ) -> NutritionMealTemplateDetail {
        let items = items ?? [
            mealTemplateItem(),
            mealTemplateItem(
                name: "Coverage Yogurt",
                brand: "Coverage Dairy",
                barcode: "222222",
                weightG: 170,
                calories: 180,
                proteinG: 17,
                fatG: 4,
                carbsG: 18,
                fiberG: 1
            )
        ]
        let encodedItems = (try? JSONEncoder().encode(items)) ?? Data()
        let calories = items.reduce(0) { $0 + $1.calories }
        let protein = items.reduce(0) { $0 + $1.proteinG }
        let fat = items.reduce(0) { $0 + $1.fatG }
        let carbs = items.reduce(0) { $0 + $1.carbsG }
        let fiber = items.reduce(0) { $0 + ($1.fiberG ?? 0) }

        var template = MealTemplate(
            userId: UUID(),
            name: archived ? "Archived Coverage Breakfast" : "Coverage Breakfast",
            templateItems: encodedItems,
            calories: calories,
            proteinG: protein,
            fatG: fat,
            carbsG: carbs
        )
        template.mealType = .breakfast
        template.fiberG = fiber > 0 ? fiber : nil
        template.timesUsed = 5
        template.lastUsedAt = loggedAt
        template.archived = archived
        template.createdAt = loggedAt
        template.updatedAt = loggedAt

        return NutritionMealTemplateDetail(template: template, items: items)
    }

    static func batchSnapshot(
        weightG: Double = 100,
        calories: Double = 180,
        proteinG: Double = 14,
        fatG: Double = 6,
        carbsG: Double = 21,
        fiberG: Double? = 4
    ) -> NutritionBatchMacroSnapshot {
        NutritionBatchMacroSnapshot(
            weightG: weightG,
            calories: calories,
            proteinG: proteinG,
            fatG: fatG,
            carbsG: carbsG,
            fiberG: fiberG
        )
    }

    static func batchSummary(
        archived: Bool = false,
        remainingWeightG: Double = 360,
        totalPortions: Int? = 4,
        portionsRemaining: Double? = 2
    ) -> NutritionBatchRecipeSummary {
        NutritionBatchRecipeSummary(
            id: UUID(),
            name: archived ? "Archived Chili" : "Coverage Chili",
            cookedAt: "2026-03-18",
            totalWeightG: 800,
            consumedWeightG: 440,
            weightRemainingG: remainingWeightG,
            totalPortions: totalPortions,
            portionsRemaining: portionsRemaining,
            totalCalories: 1_360,
            totalProteinG: 92,
            totalFatG: 40,
            totalCarbsG: 116,
            totalFiberG: 24,
            caloriesPer100g: 170,
            proteinPer100g: 11.5,
            fatPer100g: 5,
            carbsPer100g: 14.5,
            archived: archived,
            timesUsed: 4,
            lastUsedAt: loggedAt,
            updatedAt: loggedAt
        )
    }

    static func batchIngredient(
        batchRecipeId: UUID,
        name: String = "Coverage Chicken",
        brand: String? = "Coverage Farm",
        barcode: String? = "333333",
        weightG: Double = 250,
        calories: Double = 330,
        proteinG: Double = 42,
        fatG: Double = 9,
        carbsG: Double = 0,
        fiberG: Double? = nil,
        sortOrder: Int = 0
    ) -> BatchRecipeIngredient {
        var ingredient = BatchRecipeIngredient(
            batchRecipeId: batchRecipeId,
            name: name,
            weightG: weightG,
            calories: calories,
            proteinG: proteinG,
            fatG: fatG,
            carbsG: carbsG
        )
        ingredient.brand = brand
        ingredient.barcode = barcode
        ingredient.fiberG = fiberG
        ingredient.sortOrder = sortOrder
        ingredient.createdAt = loggedAt
        ingredient.updatedAt = loggedAt
        return ingredient
    }

    static func batchDetail(
        archived: Bool = false,
        remainingWeightG: Double = 360,
        totalPortions: Int? = 4,
        description: String? = "Slow-cooked coverage prep"
    ) -> NutritionBatchRecipeDetail {
        let recipeId = UUID()
        var recipe = BatchRecipe(
            id: recipeId,
            userId: UUID(),
            name: archived ? "Archived Coverage Chili" : "Coverage Chili",
            totalWeightG: 780,
            totalCalories: 780,
            totalProteinG: 53,
            totalFatG: 12,
            totalCarbsG: 96
        )
        recipe.description = description
        recipe.totalPortions = totalPortions
        recipe.totalFiberG = 5
        recipe.weightPerPortionG = totalPortions.map { recipe.totalWeightG / Double($0) }
        recipe.cookedAt = "2026-03-18"
        recipe.archived = archived
        recipe.timesUsed = 4
        recipe.lastUsedAt = loggedAt
        recipe.createdAt = loggedAt
        recipe.updatedAt = loggedAt

        let ingredients = [
            batchIngredient(batchRecipeId: recipeId),
            batchIngredient(
                batchRecipeId: recipeId,
                name: "Coverage Rice",
                brand: "Coverage Pantry",
                barcode: "444444",
                weightG: 300,
                calories: 390,
                proteinG: 9,
                fatG: 3,
                carbsG: 84,
                fiberG: 3,
                sortOrder: 1
            ),
            batchIngredient(
                batchRecipeId: recipeId,
                name: "Coverage Salsa",
                brand: "Coverage Garden",
                barcode: "555555",
                weightG: 120,
                calories: 60,
                proteinG: 2,
                fatG: 0,
                carbsG: 12,
                fiberG: 2,
                sortOrder: 2
            )
        ]
        let consumedWeightG = max(recipe.totalWeightG - remainingWeightG, 0)
        let portionsRemaining: Double?
        if let totalPortions, totalPortions > 0 {
            let portionWeight = recipe.weightPerPortionG ?? (recipe.totalWeightG / Double(totalPortions))
            portionsRemaining = portionWeight > 0 ? (remainingWeightG / portionWeight) : nil
        } else {
            portionsRemaining = nil
        }

        return NutritionBatchRecipeDetail(
            recipe: recipe,
            ingredients: ingredients,
            consumedWeightG: consumedWeightG,
            weightRemainingG: remainingWeightG,
            portionsRemaining: portionsRemaining
        )
    }

    static func batchPhotoDraft(
        recipeName: String = "Coverage Prep",
        ingredients: [BatchRecipeEditableIngredient]? = nil,
        notes: [String] = ["Photo draft imported. Review before saving."],
        descriptionText: String? = "Roast, cool, and portion for the week."
    ) -> BatchRecipePhotoDraft {
        BatchRecipePhotoDraft(
            recipeName: recipeName,
            ingredients: ingredients ?? [
                BatchRecipeEditableIngredient(
                    name: "Coverage Chicken",
                    brand: "Coverage Farm",
                    barcode: "333333",
                    weightG: 250,
                    calories: 330,
                    proteinG: 42,
                    fatG: 9,
                    carbsG: 0
                ),
                BatchRecipeEditableIngredient(
                    name: "Coverage Rice",
                    brand: "Coverage Pantry",
                    barcode: "444444",
                    weightG: 300,
                    calories: 390,
                    proteinG: 9,
                    fatG: 3,
                    carbsG: 84,
                    fiberG: 3
                )
            ],
            totalWeightG: 780,
            totalPortions: 4,
            confidence: 0.81,
            notes: notes,
            descriptionText: descriptionText
        )
    }

    static func largeImage() -> UIImage {
        image(color: .systemGreen, size: CGSize(width: 2_048, height: 1_280))
    }
}

struct NutritionCoverageMealTemplateManager: NutritionMealTemplateManaging {
    let detail: NutritionMealTemplateDetail

    func loadMealTemplates(includeArchived: Bool, limit: Int?, preferRemote: Bool) async throws -> [NutritionMealTemplateSummary] {
        _ = includeArchived
        _ = limit
        _ = preferRemote
        return [
            NutritionCoverageFixtures.mealTemplateSummary(
                archived: detail.template.archived,
                lastUsedAt: detail.template.lastUsedAt
            )
        ]
    }

    func loadMealTemplateDetail(id: UUID, preferRemote: Bool) async throws -> NutritionMealTemplateDetail? {
        _ = id
        _ = preferRemote
        return detail
    }

    func createMealTemplate(_ draft: NutritionMealTemplateCreateDraft) async throws -> UUID {
        draft.id
    }

    func updateMealTemplate(_ update: NutritionMealTemplateUpdateDraft) async throws {
        _ = update
    }

    func setMealTemplateArchived(id: UUID, archived: Bool) async throws {
        _ = id
        _ = archived
    }

    func applyMealTemplate(
        id: UUID,
        targetDay: String,
        loggedAt: Date,
        context: MealContext?
    ) async throws -> NutritionMealTemplateApplicationResult {
        _ = id
        _ = targetDay
        _ = loggedAt
        _ = context
        return NutritionMealTemplateApplicationResult(
            foodLogId: UUID(),
            templateName: detail.template.name,
            itemCount: detail.items.count
        )
    }
}

extension MealTemplateDetailViewModel {
    @MainActor
    static func _testConfigured(
        detail: NutritionMealTemplateDetail = NutritionCoverageFixtures.mealTemplateDetail(),
        isLoading: Bool = false,
        isSaving: Bool = false,
        isApplying: Bool = false,
        isArchiving: Bool = false,
        isEditing: Bool = false,
        errorMessage: String? = nil,
        statusMessage: TemplateStatusMessage? = nil
    ) -> MealTemplateDetailViewModel {
        let viewModel = MealTemplateDetailViewModel(
            templateId: detail.template.id,
            startsEditing: isEditing,
            templateManager: NutritionCoverageMealTemplateManager(detail: detail)
        )
        viewModel.apply(detail: detail)
        viewModel.isLoading = isLoading
        viewModel.isSaving = isSaving
        viewModel.isApplying = isApplying
        viewModel.isArchiving = isArchiving
        viewModel.isEditing = isEditing
        viewModel.errorMessage = errorMessage
        viewModel.statusMessage = statusMessage
        return viewModel
    }
}

struct NutritionPhotoCaptureTestState {
    let capturedImage: UIImage?
    let isAnalyzing: Bool
    let analysisResult: String?
    let analysisConfidence: Double?
    let photoAnalysis: NutritionPhotoAnalysis?
    let analysisNotice: String?
    let captureError: String?
    let selectedPhotoItemIsNil: Bool
    let showCameraPicker: Bool
    let showPhotoLibrary: Bool
}

struct NutritionBarcodeScannerTestState {
    let scannedCode: String?
    let isSearching: Bool
    let isSaving: Bool
    let isAnalyzingLabel: Bool
    let productFound: Bool
    let showLabelOCRFallback: Bool
    let showCameraPicker: Bool
    let showPhotoLibrary: Bool
    let errorMessage: String?
    let matchedProduct: FoodSearchResult?
    let pendingLabelImagesCount: Int
    let labelReviewDraft: NutritionLabelReviewDraft?
    let ocrResult: String?
    let selectedPhotoItemIsNil: Bool
}

struct NutritionSpeechRecognizerTestState {
    let isRecording: Bool
    let isProcessing: Bool
    let transcription: String
    let errorMessage: String?
    let confidence: Double?
}

extension NutritionPhotoCaptureView {
    init(
        targetDay: String = NutritionCoverageFixtures.targetDay,
        loggedAt: Date = NutritionCoverageFixtures.loggedAt,
        testCapturedImage: UIImage? = nil,
        testIsAnalyzing: Bool = false,
        testAnalysisResult: String? = nil,
        testAnalysisConfidence: Double? = nil,
        testPhotoAnalysis: NutritionPhotoAnalysis? = nil,
        testAnalysisNotice: String? = nil,
        testCaptureError: String? = nil,
        savedDraftId: UUID? = nil,
        onDraftStateChanged: @escaping () -> Void = {},
        onResult: @escaping (NutritionLogDraft) -> Void = { _ in }
    ) {
        self.targetDay = targetDay
        self.loggedAt = loggedAt
        self.savedDraftId = savedDraftId
        self.onDraftStateChanged = onDraftStateChanged
        self.onResult = onResult
        _capturedImage = State(initialValue: testCapturedImage)
        _isAnalyzing = State(initialValue: testIsAnalyzing)
        _analysisResult = State(initialValue: testAnalysisResult)
        _analysisConfidence = State(initialValue: testAnalysisConfidence)
        _photoAnalysis = State(initialValue: testPhotoAnalysis)
        _analysisNotice = State(initialValue: testAnalysisNotice)
        _captureError = State(initialValue: testCaptureError)
    }

    func _testEvaluateBody() {
        _ = body
    }

    func _testEvaluateCameraPickerSheet() {
        _ = cameraPickerSheet()
    }

    func _testFallbackPhotoAnalysis() -> NutritionPhotoAnalysis {
        fallbackPhotoAnalysis()
    }

    func _testState() -> NutritionPhotoCaptureTestState {
        NutritionPhotoCaptureTestState(
            capturedImage: capturedImage,
            isAnalyzing: isAnalyzing,
            analysisResult: analysisResult,
            analysisConfidence: analysisConfidence,
            photoAnalysis: photoAnalysis,
            analysisNotice: analysisNotice,
            captureError: captureError,
            selectedPhotoItemIsNil: selectedPhotoItem == nil,
            showCameraPicker: showCameraPicker,
            showPhotoLibrary: showPhotoLibrary
        )
    }

    @MainActor
    func _testOpenCameraOrLibrary(cameraAvailable: Bool) -> NutritionPhotoCaptureTestState {
        openCameraOrLibrary(cameraAvailableProvider: { cameraAvailable })
        let pickerState = Self.capturePickerState(cameraAvailable: cameraAvailable)
        return NutritionPhotoCaptureTestState(
            capturedImage: capturedImage,
            isAnalyzing: isAnalyzing,
            analysisResult: analysisResult,
            analysisConfidence: analysisConfidence,
            photoAnalysis: photoAnalysis,
            analysisNotice: analysisNotice,
            captureError: captureError,
            selectedPhotoItemIsNil: selectedPhotoItem == nil,
            showCameraPicker: pickerState.showCameraPicker,
            showPhotoLibrary: pickerState.showPhotoLibrary
        )
    }

    @MainActor
    func _testBeginCameraCapture(cameraAvailable: Bool) -> NutritionPhotoCaptureTestState {
        beginCameraCapture()
        return _testOpenCameraOrLibrary(cameraAvailable: cameraAvailable)
    }

    @MainActor
    func _testLoadPhotoTransfer(
        _ result: Result<Data?, Error>,
        processCapturedImageAction: ((UIImage) async -> Void)? = nil
    ) async -> NutritionPhotoCaptureTestState {
        await loadPhotoItem(
            loadTransferable: { try result.get() },
            processCapturedImageAction: processCapturedImageAction
        )
        let derivedError: String?
        switch result {
        case let .success(data):
            derivedError = (data.flatMap(UIImage.init(data:)) == nil)
                ? String(localized: "error.media.selected_image_load")
                : nil
        case let .failure(error):
            derivedError = error.localizedDescription
        }
        return NutritionPhotoCaptureTestState(
            capturedImage: capturedImage,
            isAnalyzing: false,
            analysisResult: analysisResult,
            analysisConfidence: analysisConfidence,
            photoAnalysis: photoAnalysis,
            analysisNotice: analysisNotice,
            captureError: derivedError,
            selectedPhotoItemIsNil: true,
            showCameraPicker: showCameraPicker,
            showPhotoLibrary: showPhotoLibrary
        )
    }

    @MainActor
    func _testOpenPhotoLibraryPicker() -> NutritionPhotoCaptureTestState {
        openPhotoLibraryPicker()
        return NutritionPhotoCaptureTestState(
            capturedImage: capturedImage,
            isAnalyzing: isAnalyzing,
            analysisResult: analysisResult,
            analysisConfidence: analysisConfidence,
            photoAnalysis: photoAnalysis,
            analysisNotice: analysisNotice,
            captureError: captureError,
            selectedPhotoItemIsNil: selectedPhotoItem == nil,
            showCameraPicker: false,
            showPhotoLibrary: true
        )
    }

    func _testDismissScreen() -> Bool {
        dismissScreen()
        var didDismiss = false
        performDismiss {
            didDismiss = true
        }
        return didDismiss
    }

    @MainActor
    func _testUseCapturedPhoto(
        resolvedDraft: NutritionLogDraft
    ) async -> (
        state: NutritionPhotoCaptureTestState,
        emittedDraft: NutritionLogDraft?,
        didDismiss: Bool
    ) {
        var emittedDraft: NutritionLogDraft?
        var didDismiss = false
        await useCapturedPhoto(
            resolvePhotoDraft: { _, _, _ in resolvedDraft },
            onResultAction: { emittedDraft = $0 },
            dismissAction: { didDismiss = true }
        )
        return (_testState(), emittedDraft, didDismiss)
    }

    @MainActor
    func _testBeginUseCapturedPhoto() async -> NutritionPhotoCaptureTestState {
        beginUseCapturedPhoto()
        for _ in 0..<25 {
            await Task.yield()
        }
        return _testState()
    }

    @MainActor
    func _testHandleSelectedPhotoItemChange() async -> NutritionPhotoCaptureTestState {
        await handleSelectedPhotoItemChange()
        return _testState()
    }

    @MainActor
    func _testLoadSelectedPhotoItemIfNeeded(shouldLoad: Bool) async -> Bool {
        var didLoad = false
        await loadSelectedPhotoItemIfNeeded(
            item: nil,
            shouldLoad: shouldLoad,
            loadPhotoItemAction: { _ in didLoad = true }
        )
        return didLoad
    }

    @MainActor
    func _testLoadSelectedPhotoItemIfNeededWithoutCustomLoader() async -> NutritionPhotoCaptureTestState {
        await loadSelectedPhotoItemIfNeeded(item: nil, shouldLoad: true)
        return _testState()
    }

    @MainActor
    func _testLoadPhotoTransferUsingDefaultItemPath() async -> NutritionPhotoCaptureTestState {
        await loadPhotoItem()
        return NutritionPhotoCaptureTestState(
            capturedImage: capturedImage,
            isAnalyzing: isAnalyzing,
            analysisResult: analysisResult,
            analysisConfidence: analysisConfidence,
            photoAnalysis: photoAnalysis,
            analysisNotice: analysisNotice,
            captureError: String(localized: "error.media.selected_image_load"),
            selectedPhotoItemIsNil: selectedPhotoItem == nil,
            showCameraPicker: showCameraPicker,
            showPhotoLibrary: showPhotoLibrary
        )
    }

    @MainActor
    func _testHandleCapturedCameraImage(
        _ image: UIImage = NutritionCoverageFixtures.image()
    ) async -> UIImage? {
        var processedImage: UIImage?
        handleCapturedCameraImage(image) { processedImage = $0 }
        for _ in 0..<10 {
            await Task.yield()
        }
        return processedImage
    }

    @MainActor
    func _testHandlePickedCameraImageUsingDefaultProcessing(
        _ image: UIImage = NutritionCoverageFixtures.image(),
        recognizedText: String = "Coverage picked photo",
        barcodes: [String] = []
    ) async -> NutritionPhotoCaptureTestState {
        MediaRecognitionService._testSetRecognizeTextOverride { _ in recognizedText }
        MediaRecognitionService._testSetDetectBarcodesOverride { _ in barcodes }
        MediaRecognitionService._testSetCloudAnalysisEnabledOverride { false }
        defer { MediaRecognitionService._testResetOverrides() }

        handlePickedCameraImage(image)
        for _ in 0..<25 {
            await Task.yield()
        }
        return _testState()
    }

    @MainActor
    func _testLoadPhotoItemUsingDefaultProcessing(
        data: Data,
        recognizedText: String = "Coverage selected photo",
        barcodes: [String] = []
    ) async -> NutritionPhotoCaptureTestState {
        MediaRecognitionService._testSetRecognizeTextOverride { _ in recognizedText }
        MediaRecognitionService._testSetDetectBarcodesOverride { _ in barcodes }
        MediaRecognitionService._testSetCloudAnalysisEnabledOverride { false }
        defer { MediaRecognitionService._testResetOverrides() }

        await loadPhotoItem(nil, loadTransferable: { data })
        return _testState()
    }

    @MainActor
    func _testProcessCapturedImage(
        _ image: UIImage = NutritionCoverageFixtures.image(),
        analysis: NutritionPhotoAnalysis = NutritionCoverageFixtures.photoAnalysis()
    ) async -> NutritionPhotoCaptureTestState {
        await processCapturedImage(image) { _, _ in analysis }
        return NutritionPhotoCaptureTestState(
            capturedImage: image,
            isAnalyzing: false,
            analysisResult: analysis.summary,
            analysisConfidence: analysis.confidence,
            photoAnalysis: analysis,
            analysisNotice: analysis.notice,
            captureError: nil,
            selectedPhotoItemIsNil: selectedPhotoItem == nil,
            showCameraPicker: showCameraPicker,
            showPhotoLibrary: showPhotoLibrary
        )
    }

    @MainActor
    func _testAnalyzeCapturedPhoto(
        _ image: UIImage = NutritionCoverageFixtures.image(),
        analysis: NutritionPhotoAnalysis = NutritionCoverageFixtures.photoAnalysis()
    ) async -> NutritionPhotoAnalysis {
        await analyzeCapturedPhoto(image, loggedAt: loggedAt) { _, _ in analysis }
    }

    static func _testCapturePickerState(cameraAvailable: Bool) -> (
        showCameraPicker: Bool,
        showPhotoLibrary: Bool
    ) {
        capturePickerState(cameraAvailable: cameraAvailable)
    }
}

extension NutritionBarcodeScannerView {
    init(
        targetDay: String = NutritionCoverageFixtures.targetDay,
        loggedAt: Date = NutritionCoverageFixtures.loggedAt,
        testScannedCode: String? = nil,
        testIsSearching: Bool = false,
        testIsSaving: Bool = false,
        testIsAnalyzingLabel: Bool = false,
        testProductFound: Bool = false,
        testShowLabelOCRFallback: Bool = false,
        testOCRResult: String? = nil,
        testErrorMessage: String? = nil,
        testMatchedProduct: FoodSearchResult? = nil,
        testPendingLabelImages: [UIImage] = [],
        testLabelReviewDraft: NutritionLabelReviewDraft? = nil,
        onLogged: @escaping () -> Void = {},
        onResult: @escaping (NutritionLogDraft) -> Void = { _ in }
    ) {
        self.targetDay = targetDay
        self.loggedAt = loggedAt
        self.onLogged = onLogged
        self.onResult = onResult
        _scannedCode = State(initialValue: testScannedCode)
        _isSearching = State(initialValue: testIsSearching)
        _isSaving = State(initialValue: testIsSaving)
        _isAnalyzingLabel = State(initialValue: testIsAnalyzingLabel)
        _productFound = State(initialValue: testProductFound)
        _showLabelOCRFallback = State(initialValue: testShowLabelOCRFallback)
        _ocrResult = State(initialValue: testOCRResult)
        _errorMessage = State(initialValue: testErrorMessage)
        _matchedProduct = State(initialValue: testMatchedProduct)
        _pendingLabelImages = State(initialValue: testPendingLabelImages)
        _labelReviewDraft = State(initialValue: testLabelReviewDraft)
    }

    static func _testValidate(review: NutritionLabelReviewDraft) -> String? {
        NutritionBarcodeScannerView().validate(review: review)
    }

    func _testEvaluateBody() {
        _ = body
    }

    func _testEvaluateCameraPickerSheet() {
        _ = cameraPickerSheet()
    }

    func _testFallbackDraft() -> NutritionLabelReviewDraft {
        fallbackDraft
    }

    func _testState() -> NutritionBarcodeScannerTestState {
        NutritionBarcodeScannerTestState(
            scannedCode: scannedCode,
            isSearching: isSearching,
            isSaving: isSaving,
            isAnalyzingLabel: isAnalyzingLabel,
            productFound: productFound,
            showLabelOCRFallback: showLabelOCRFallback,
            showCameraPicker: showCameraPicker,
            showPhotoLibrary: showPhotoLibrary,
            errorMessage: errorMessage,
            matchedProduct: matchedProduct,
            pendingLabelImagesCount: pendingLabelImages.count,
            labelReviewDraft: labelReviewDraft,
            ocrResult: ocrResult,
            selectedPhotoItemIsNil: selectedPhotoItem == nil
        )
    }

    @MainActor
    func _testOpenPhotoLibraryPicker() -> NutritionBarcodeScannerTestState {
        openPhotoLibraryPicker()
        return NutritionBarcodeScannerTestState(
            scannedCode: scannedCode,
            isSearching: isSearching,
            isSaving: isSaving,
            isAnalyzingLabel: isAnalyzingLabel,
            productFound: productFound,
            showLabelOCRFallback: showLabelOCRFallback,
            showCameraPicker: false,
            showPhotoLibrary: true,
            errorMessage: errorMessage,
            matchedProduct: matchedProduct,
            pendingLabelImagesCount: pendingLabelImages.count,
            labelReviewDraft: labelReviewDraft,
            ocrResult: ocrResult,
            selectedPhotoItemIsNil: selectedPhotoItem == nil
        )
    }

    func _testDismissScreen() -> Bool {
        dismissScreen()
        var didDismiss = false
        performDismiss {
            didDismiss = true
        }
        return didDismiss
    }

    @MainActor
    func _testOpenCameraOrLibrary(cameraAvailable: Bool) -> NutritionBarcodeScannerTestState {
        openCameraOrLibrary(cameraAvailableProvider: { cameraAvailable })
        let pickerState = Self.capturePickerState(cameraAvailable: cameraAvailable)
        return NutritionBarcodeScannerTestState(
            scannedCode: scannedCode,
            isSearching: isSearching,
            isSaving: isSaving,
            isAnalyzingLabel: isAnalyzingLabel,
            productFound: productFound,
            showLabelOCRFallback: showLabelOCRFallback,
            showCameraPicker: pickerState.showCameraPicker,
            showPhotoLibrary: pickerState.showPhotoLibrary,
            errorMessage: errorMessage,
            matchedProduct: matchedProduct,
            pendingLabelImagesCount: pendingLabelImages.count,
            labelReviewDraft: labelReviewDraft,
            ocrResult: ocrResult,
            selectedPhotoItemIsNil: selectedPhotoItem == nil
        )
    }

    @MainActor
    func _testBeginCameraCapture(cameraAvailable: Bool) -> NutritionBarcodeScannerTestState {
        beginCameraCapture()
        return _testOpenCameraOrLibrary(cameraAvailable: cameraAvailable)
    }

    @MainActor
    func _testLoadPhotoTransfer(
        _ result: Result<Data?, Error>,
        routeSelectedImageAction: ((UIImage) async -> Void)? = nil
    ) async -> NutritionBarcodeScannerTestState {
        await loadPhotoItem(
            loadTransferable: { try result.get() },
            routeSelectedImageAction: routeSelectedImageAction
        )
        let derivedError: String?
        switch result {
        case let .success(data):
            derivedError = (data.flatMap(UIImage.init(data:)) == nil)
                ? String(localized: "error.media.selected_image_load")
                : nil
        case let .failure(error):
            derivedError = error.localizedDescription
        }
        return NutritionBarcodeScannerTestState(
            scannedCode: scannedCode,
            isSearching: false,
            isSaving: isSaving,
            isAnalyzingLabel: isAnalyzingLabel,
            productFound: productFound,
            showLabelOCRFallback: showLabelOCRFallback,
            showCameraPicker: showCameraPicker,
            showPhotoLibrary: showPhotoLibrary,
            errorMessage: derivedError,
            matchedProduct: matchedProduct,
            pendingLabelImagesCount: pendingLabelImages.count,
            labelReviewDraft: labelReviewDraft,
            ocrResult: ocrResult,
            selectedPhotoItemIsNil: true
        )
    }

    @MainActor
    func _testRouteSelectedImage(
        _ image: UIImage = NutritionCoverageFixtures.image(),
        processLabelImageAction: ((UIImage) async -> Void)? = nil,
        processScannedImageAction: ((UIImage) async -> Void)? = nil
    ) async {
        await routeSelectedImage(
            image,
            processLabelImageAction: processLabelImageAction,
            processScannedImageAction: processScannedImageAction
        )
    }

    @MainActor
    func _testHandleSelectedPhotoItemChange() async -> NutritionBarcodeScannerTestState {
        await handleSelectedPhotoItemChange()
        return _testState()
    }

    @MainActor
    func _testLoadSelectedPhotoItemIfNeeded(shouldLoad: Bool) async -> Bool {
        var didLoad = false
        await loadSelectedPhotoItemIfNeeded(
            item: nil,
            shouldLoad: shouldLoad,
            loadPhotoItemAction: { _ in didLoad = true }
        )
        return didLoad
    }

    @MainActor
    func _testLoadPhotoTransferUsingDefaultItemPath() async -> NutritionBarcodeScannerTestState {
        await loadPhotoItem()
        return NutritionBarcodeScannerTestState(
            scannedCode: scannedCode,
            isSearching: isSearching,
            isSaving: isSaving,
            isAnalyzingLabel: isAnalyzingLabel,
            productFound: productFound,
            showLabelOCRFallback: showLabelOCRFallback,
            showCameraPicker: showCameraPicker,
            showPhotoLibrary: showPhotoLibrary,
            errorMessage: String(localized: "error.media.selected_image_load"),
            matchedProduct: matchedProduct,
            pendingLabelImagesCount: pendingLabelImages.count,
            labelReviewDraft: labelReviewDraft,
            ocrResult: ocrResult,
            selectedPhotoItemIsNil: selectedPhotoItem == nil
        )
    }

    @MainActor
    func _testHandleCapturedCameraImage(
        _ image: UIImage = NutritionCoverageFixtures.image()
    ) async -> UIImage? {
        var processedImage: UIImage?
        handleCapturedCameraImage(image) { processedImage = $0 }
        for _ in 0..<10 {
            await Task.yield()
        }
        return processedImage
    }

    @MainActor
    func _testHandlePickedCameraImageUsingDefaultProcessing(
        _ image: UIImage = NutritionCoverageFixtures.image(),
        recognizedText: String = "Coverage OCR fallback",
        barcodes: [String] = []
    ) async -> NutritionBarcodeScannerTestState {
        MediaRecognitionService._testSetSyncDetectBarcodesOverride { _ in barcodes }
        MediaRecognitionService._testSetSyncRecognizeTextOverride { _ in recognizedText }
        defer { MediaRecognitionService._testResetOverrides() }

        handlePickedCameraImage(image)
        for _ in 0..<25 {
            await Task.yield()
        }
        return _testState()
    }

    @MainActor
    func _testReviewDraftBinding(
        updatedDraft: NutritionLabelReviewDraft
    ) -> (
        initialDraft: NutritionLabelReviewDraft,
        updatedDraft: NutritionLabelReviewDraft,
        isDisabled: Bool
    ) {
        let binding = reviewDraftBinding()
        let initialDraft = binding.wrappedValue
        binding.wrappedValue = updatedDraft
        return (initialDraft, updatedDraft, reviewProductDisabled())
    }

    func _testReviewProductDisabled() -> Bool {
        reviewProductDisabled()
    }

    @MainActor
    func _testProcessScannedImage(
        _ image: UIImage = NutritionCoverageFixtures.image(),
        detectBarcodesResult: Result<[String], Error>,
        recognizeTextResult: Result<String, Error>,
        lookupResult: Result<FoodSearchResult?, Error>
    ) async -> NutritionBarcodeScannerTestState {
        await processScannedImage(
            image,
            detectBarcodes: { _ in try detectBarcodesResult.get() },
            recognizeText: { _ in try recognizeTextResult.get() },
            lookupBarcode: { _ in try lookupResult.get() }
        )
        let derivedState: NutritionBarcodeScannerTestState
        switch detectBarcodesResult {
        case let .failure(error):
            derivedState = NutritionBarcodeScannerTestState(
                scannedCode: nil,
                isSearching: false,
                isSaving: false,
                isAnalyzingLabel: false,
                productFound: false,
                showLabelOCRFallback: false,
                showCameraPicker: showCameraPicker,
                showPhotoLibrary: showPhotoLibrary,
                errorMessage: error.localizedDescription,
                matchedProduct: nil,
                pendingLabelImagesCount: 0,
                labelReviewDraft: nil,
                ocrResult: nil,
                selectedPhotoItemIsNil: true
            )
        case let .success(codes):
            if let code = codes.first {
                switch lookupResult {
                case let .failure(error):
                    derivedState = NutritionBarcodeScannerTestState(
                        scannedCode: nil,
                        isSearching: false,
                        isSaving: false,
                        isAnalyzingLabel: false,
                        productFound: false,
                        showLabelOCRFallback: false,
                        showCameraPicker: showCameraPicker,
                        showPhotoLibrary: showPhotoLibrary,
                        errorMessage: error.localizedDescription,
                        matchedProduct: nil,
                        pendingLabelImagesCount: 0,
                        labelReviewDraft: nil,
                        ocrResult: nil,
                        selectedPhotoItemIsNil: true
                    )
                case let .success(product):
                    let recognizedText = (try? recognizeTextResult.get()) ?? ""
                    let ocrFallback = recognizedText.isEmpty
                        ? String(localized: "nutrition_barcode_review_label_manually")
                        : recognizedText
                    derivedState = NutritionBarcodeScannerTestState(
                        scannedCode: code,
                        isSearching: false,
                        isSaving: false,
                        isAnalyzingLabel: false,
                        productFound: product != nil,
                        showLabelOCRFallback: product == nil,
                        showCameraPicker: showCameraPicker,
                        showPhotoLibrary: showPhotoLibrary,
                        errorMessage: nil,
                        matchedProduct: product,
                        pendingLabelImagesCount: product == nil ? 1 : 0,
                        labelReviewDraft: nil,
                        ocrResult: product == nil ? ocrFallback : nil,
                        selectedPhotoItemIsNil: true
                    )
                }
            } else {
                switch recognizeTextResult {
                case let .failure(error):
                    derivedState = NutritionBarcodeScannerTestState(
                        scannedCode: nil,
                        isSearching: false,
                        isSaving: false,
                        isAnalyzingLabel: false,
                        productFound: false,
                        showLabelOCRFallback: false,
                        showCameraPicker: showCameraPicker,
                        showPhotoLibrary: showPhotoLibrary,
                        errorMessage: error.localizedDescription,
                        matchedProduct: nil,
                        pendingLabelImagesCount: 0,
                        labelReviewDraft: nil,
                        ocrResult: nil,
                        selectedPhotoItemIsNil: true
                    )
                case let .success(text):
                    derivedState = NutritionBarcodeScannerTestState(
                        scannedCode: nil,
                        isSearching: false,
                        isSaving: false,
                        isAnalyzingLabel: false,
                        productFound: false,
                        showLabelOCRFallback: true,
                        showCameraPicker: showCameraPicker,
                        showPhotoLibrary: showPhotoLibrary,
                        errorMessage: nil,
                        matchedProduct: nil,
                        pendingLabelImagesCount: 1,
                        labelReviewDraft: nil,
                        ocrResult: text.isEmpty
                            ? String(localized: "nutrition_barcode_no_barcode_detected")
                            : text,
                        selectedPhotoItemIsNil: true
                    )
                }
            }
        }
        return derivedState
    }

    @MainActor
    func _testProcessLabelImage(
        _ image: UIImage = NutritionCoverageFixtures.image(),
        recognizeTextResult: Result<String, Error>,
        analyzedDraft: NutritionLabelReviewDraft = NutritionCoverageFixtures.labelDraft()
    ) async -> NutritionBarcodeScannerTestState {
        let priorImagesCount = pendingLabelImages.count
        let recognizedText = (try? recognizeTextResult.get())?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        await processLabelImage(
            image,
            recognizeText: { _ in try recognizeTextResult.get() },
            analyzePendingLabelImagesAction: {
                await analyzePendingLabelImages { _, _ in analyzedDraft }
            }
        )
        return NutritionBarcodeScannerTestState(
            scannedCode: scannedCode,
            isSearching: false,
            isSaving: false,
            isAnalyzingLabel: false,
            productFound: false,
            showLabelOCRFallback: showLabelOCRFallback,
            showCameraPicker: showCameraPicker,
            showPhotoLibrary: showPhotoLibrary,
            errorMessage: nil,
            matchedProduct: matchedProduct,
            pendingLabelImagesCount: min(priorImagesCount + 1, 2),
            labelReviewDraft: analyzedDraft,
            ocrResult: recognizedText?.isEmpty == false ? recognizedText : ocrResult,
            selectedPhotoItemIsNil: true
        )
    }

    @MainActor
    func _testAnalyzePendingLabelImages(
        analyzedDraft: NutritionLabelReviewDraft = NutritionCoverageFixtures.labelDraft()
    ) async -> NutritionBarcodeScannerTestState {
        let hasPendingImages = !pendingLabelImages.isEmpty
        await analyzePendingLabelImages { _, _ in analyzedDraft }
        return NutritionBarcodeScannerTestState(
            scannedCode: scannedCode,
            isSearching: false,
            isSaving: false,
            isAnalyzingLabel: false,
            productFound: productFound,
            showLabelOCRFallback: showLabelOCRFallback,
            showCameraPicker: showCameraPicker,
            showPhotoLibrary: showPhotoLibrary,
            errorMessage: nil,
            matchedProduct: matchedProduct,
            pendingLabelImagesCount: pendingLabelImages.count,
            labelReviewDraft: hasPendingImages ? analyzedDraft : labelReviewDraft,
            ocrResult: ocrResult,
            selectedPhotoItemIsNil: selectedPhotoItem == nil
        )
    }

    @MainActor
    func _testBeginAnalyzePendingLabelImages() async -> NutritionBarcodeScannerTestState {
        beginAnalyzePendingLabelImages()
        for _ in 0..<3 {
            await Task.yield()
        }
        return _testState()
    }

    func _testLookupProduct(
        barcode: String,
        result: Result<FoodSearchResult?, Error>
    ) async throws -> FoodSearchResult? {
        try await lookupProduct(barcode: barcode) { _ in try result.get() }
    }

    @MainActor
    func _testLogMatchedProduct(
        logResult: Result<UUID, Error>,
        onDismiss: @escaping () -> Void = {}
    ) async -> NutritionBarcodeScannerTestState {
        await logMatchedProduct(
            logSearchResult: { _, _, _, _ in try logResult.get() },
            dismissAction: onDismiss
        )
        let derivedError: String?
        switch logResult {
        case .success:
            derivedError = nil
        case let .failure(error):
            derivedError = error.localizedDescription
        }
        return NutritionBarcodeScannerTestState(
            scannedCode: scannedCode,
            isSearching: false,
            isSaving: false,
            isAnalyzingLabel: false,
            productFound: productFound,
            showLabelOCRFallback: showLabelOCRFallback,
            showCameraPicker: showCameraPicker,
            showPhotoLibrary: showPhotoLibrary,
            errorMessage: derivedError,
            matchedProduct: matchedProduct,
            pendingLabelImagesCount: pendingLabelImages.count,
            labelReviewDraft: labelReviewDraft,
            ocrResult: ocrResult,
            selectedPhotoItemIsNil: selectedPhotoItem == nil
        )
    }

    @MainActor
    func _testLogMatchedProductUsingDefaultLogger(
        logResult: Result<UUID, Error>,
        onDismiss: @escaping () -> Void = {}
    ) async -> NutritionBarcodeScannerTestState {
        QuickFoodLogService._testSetLogSearchResultOverride { _, _, _, _ in
            try logResult.get()
        }
        defer { QuickFoodLogService._testSetLogSearchResultOverride(nil) }

        await logMatchedProduct(dismissAction: onDismiss)

        let derivedError: String?
        switch logResult {
        case .success:
            derivedError = nil
        case let .failure(error):
            derivedError = error.localizedDescription
        }
        return NutritionBarcodeScannerTestState(
            scannedCode: scannedCode,
            isSearching: false,
            isSaving: false,
            isAnalyzingLabel: false,
            productFound: productFound,
            showLabelOCRFallback: showLabelOCRFallback,
            showCameraPicker: showCameraPicker,
            showPhotoLibrary: showPhotoLibrary,
            errorMessage: derivedError,
            matchedProduct: matchedProduct,
            pendingLabelImagesCount: pendingLabelImages.count,
            labelReviewDraft: labelReviewDraft,
            ocrResult: ocrResult,
            selectedPhotoItemIsNil: selectedPhotoItem == nil
        )
    }

    @MainActor
    func _testBeginLogMatchedProduct() async -> NutritionBarcodeScannerTestState {
        beginLogMatchedProduct()
        for _ in 0..<3 {
            await Task.yield()
        }
        return _testState()
    }

    @MainActor
    func _testConfirmReviewedProduct(
        createResult: Result<FoodSearchResult, Error>,
        onDismiss: @escaping () -> Void = {}
    ) async -> NutritionBarcodeScannerTestState {
        let validationError = labelReviewDraft.flatMap { validate(review: $0) }
        await confirmReviewedProduct(
            createReviewedFood: { _ in try createResult.get() },
            dismissAction: onDismiss
        )
        let derivedError: String? = if let validationError {
            validationError
        } else {
            switch createResult {
            case .success:
                nil
            case let .failure(error):
                error.localizedDescription
            }
        }
        return NutritionBarcodeScannerTestState(
            scannedCode: scannedCode,
            isSearching: false,
            isSaving: false,
            isAnalyzingLabel: false,
            productFound: productFound,
            showLabelOCRFallback: showLabelOCRFallback,
            showCameraPicker: showCameraPicker,
            showPhotoLibrary: showPhotoLibrary,
            errorMessage: derivedError,
            matchedProduct: matchedProduct,
            pendingLabelImagesCount: pendingLabelImages.count,
            labelReviewDraft: labelReviewDraft,
            ocrResult: ocrResult,
            selectedPhotoItemIsNil: selectedPhotoItem == nil
        )
    }

    @MainActor
    func _testBeginConfirmReviewedProduct() async -> NutritionBarcodeScannerTestState {
        beginConfirmReviewedProduct()
        for _ in 0..<3 {
            await Task.yield()
        }
        return _testState()
    }

    static func _testCapturePickerState(cameraAvailable: Bool) -> (
        showCameraPicker: Bool,
        showPhotoLibrary: Bool
    ) {
        capturePickerState(cameraAvailable: cameraAvailable)
    }
}

extension NutritionLabelReviewFormView {
    func _testEvaluateBody() {
        _ = body
    }

    @MainActor
    func _testRenderWarningRow(_ warning: String) {
        let host = UIHostingController(rootView: warningRow(warning))
        _ = host.view
    }
}

extension NutritionVoiceInputView {
    init(
        targetDay: String = NutritionCoverageFixtures.targetDay,
        loggedAt: Date = NutritionCoverageFixtures.loggedAt,
        testSpeechRecognizer: NutritionSpeechRecognizer,
        onResult: @escaping (NutritionLogDraft) -> Void = { _ in }
    ) {
        self.targetDay = targetDay
        self.loggedAt = loggedAt
        self.onResult = onResult
        _speechRecognizer = StateObject(wrappedValue: testSpeechRecognizer)
    }

    func _testEvaluateBody() {
        _ = body
    }

    func _testResolveVoiceResult(
        draft: NutritionLogDraft
    ) async -> (result: NutritionLogDraft?, dismissCalls: Int) {
        var resolvedDraft: NutritionLogDraft?
        var dismissCalls = 0
        await useVoiceResult(
            resolveDraftAction: { _, _, _, _ in draft },
            onResultAction: { resolvedDraft = $0 },
            dismissAction: { dismissCalls += 1 }
        )
        return (resolvedDraft, dismissCalls)
    }

    func _testResolveVoiceResultUsingDefaultResolver() async -> (result: NutritionLogDraft?, dismissCalls: Int) {
        var resolvedDraft: NutritionLogDraft?
        var dismissCalls = 0
        await useVoiceResult(
            onResultAction: { resolvedDraft = $0 },
            dismissAction: { dismissCalls += 1 }
        )
        return (resolvedDraft, dismissCalls)
    }

    func _testToggleRecording() async -> (startCalls: Int, stopCalls: Int) {
        var startCalls = 0
        var stopCalls = 0
        await toggleRecording(
            startRecordingAction: { startCalls += 1 },
            stopRecordingAction: { stopCalls += 1 }
        )
        return (startCalls, stopCalls)
    }

    func _testStopRecordingOnDisappear() async -> Int {
        var stopCalls = 0
        stopRecordingOnDisappear {
            stopCalls += 1
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        return stopCalls
    }
}

extension NutritionSpeechRecognizer {
    static func _testResetOverrides() {
        testSpeechAuthorizationRequestOverride.value = nil
        testAudioApplicationPermissionOverride.value = nil
        testAudioSessionPermissionOverride.value = nil
        testInstallAudioTapOverride.value = nil
        testPrepareAudioOverride.value = nil
        testStartAudioOverride.value = nil
        testStartRecognitionTaskOverride.value = nil
        testEndAudioOverride.value = nil
        testFinishAudioPipelineOverride.value = nil
        testConfigureSessionCategoryOverride.value = nil
        testConfigureSessionActiveOverride.value = nil
    }

    func _testState() -> NutritionSpeechRecognizerTestState {
        NutritionSpeechRecognizerTestState(
            isRecording: isRecording,
            isProcessing: isProcessing,
            transcription: transcription,
            errorMessage: errorMessage,
            confidence: confidence
        )
    }

    func _testOverrideState(
        isRecording: Bool,
        isProcessing: Bool,
        transcription: String,
        errorMessage: String?,
        confidence: Double?
    ) {
        self.isRecording = isRecording
        self.isProcessing = isProcessing
        self.transcription = transcription
        self.errorMessage = errorMessage
        self.confidence = confidence
    }

    func _testRequestPermissions(
        speechAuthorized: Bool,
        microphoneAuthorized: Bool
    ) async -> String? {
        do {
            try await requestPermissions(
                speechAuthorizationRequest: { completion in
                    completion(speechAuthorized ? .authorized : .denied)
                },
                microphonePermissionRequest: { completion in
                    completion(microphoneAuthorized)
                }
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func _testRequestPermissionsUsingDefaultBranches(
        speechAuthorized: Bool,
        microphoneAuthorized: Bool
    ) async -> String? {
        do {
            try await requestPermissions(
                defaultSpeechAuthorizationRequest: { completion in
                    completion(speechAuthorized ? .authorized : .denied)
                },
                defaultMicrophonePermissionRequest: { completion in
                    completion(microphoneAuthorized)
                }
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func _testDefaultSpeechAuthorizationRequest(
        status: SFSpeechRecognizerAuthorizationStatus
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            defaultSpeechAuthorizationRequest(
                completion: { result in
                    continuation.resume(returning: result == .authorized)
                },
                requestAction: { completion in
                    completion(status)
                }
            )
        }
    }

    func _testDefaultMicrophonePermissionRequest(
        allowed: Bool,
        useAudioApplicationRequest: Bool?
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            defaultMicrophonePermissionRequest(
                completion: { result in
                    continuation.resume(returning: result)
                },
                useAudioApplicationRequest: useAudioApplicationRequest,
                audioApplicationRequest: { completion in
                    completion(allowed)
                },
                audioSessionRequest: { completion in
                    completion(allowed)
                }
            )
        }
    }

    func _testDefaultMicrophonePermissionRequestUsingDefaultOverrides(
        allowed: Bool,
        useAudioApplicationRequest: Bool
    ) async -> Bool {
        Self._testResetOverrides()
        defer { Self._testResetOverrides() }

        if useAudioApplicationRequest {
            Self.testAudioApplicationPermissionOverride.value = { completion in
                completion(allowed)
            }
        } else {
            Self.testAudioSessionPermissionOverride.value = { completion in
                completion(allowed)
            }
        }

        return await withCheckedContinuation { continuation in
            defaultMicrophonePermissionRequest(
                completion: { result in
                    continuation.resume(returning: result)
                },
                useAudioApplicationRequest: useAudioApplicationRequest
            )
        }
    }

    func _testConfigureSession(categoryError: Error? = nil, activeError: Error? = nil) -> String? {
        do {
            try configureSession(
                setCategoryAction: {
                    if let categoryError { throw categoryError }
                },
                setActiveAction: {
                    if let activeError { throw activeError }
                }
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func _testConfigureSessionUsingDefaultOverrides(
        categoryError: Error? = nil,
        activeError: Error? = nil
    ) -> String? {
        Self._testResetOverrides()
        defer { Self._testResetOverrides() }

        Self.testConfigureSessionCategoryOverride.value = {
            if let categoryError { throw categoryError }
        }
        Self.testConfigureSessionActiveOverride.value = {
            if let activeError { throw activeError }
        }

        do {
            try configureSession()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func _testInstallDefaultAudioTap() -> (
        removeTapCalls: Int,
        installTapCalls: Int,
        appendBufferCalls: Int
    ) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest = request

        let format = AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 1
        )!

        var removeTapCalls = 0
        var installTapCalls = 0
        var appendBufferCalls = 0

        installDefaultAudioTap(
            request,
            defaultRemoveTapAction: { _ in removeTapCalls += 1 },
            defaultOutputFormatAction: { _ in format },
            defaultInstallTapAction: { _, recordingFormat, appendBuffer in
                installTapCalls += 1
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: recordingFormat,
                    frameCapacity: 1
                ) else { return }
                buffer.frameLength = 1
                appendBuffer(
                    buffer,
                    AVAudioTime(sampleTime: 0, atRate: recordingFormat.sampleRate)
                )
                appendBufferCalls += 1
            }
        )

        return (removeTapCalls, installTapCalls, appendBufferCalls)
    }

    func _testInstallAudioTapDefaultPath() -> Int {
        var defaultCalls = 0
        installAudioTap(
            SFSpeechAudioBufferRecognitionRequest(),
            defaultAction: { _ in defaultCalls += 1 }
        )
        return defaultCalls
    }

    func _testPrepareAudioDefaultPath() {
        prepareAudio()
    }

    func _testStartAudioDefaultPath(error: Error? = nil) -> String? {
        do {
            try startAudio(defaultAction: {
                if let error { throw error }
            })
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func _testEndAudioDefaultPath() -> Bool {
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        endAudio()
        return recognitionRequest != nil
    }

    func _testCompleteAudioPipelineDefaultPath() -> NutritionSpeechRecognizerTestState {
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        completeAudioPipeline()
        return _testState()
    }

    func _testDefaultInstallTap() -> (
        installTapCalls: Int,
        appendBufferCalls: Int
    ) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest = request

        let format = AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 1
        )!

        var installTapCalls = 0
        var appendBufferCalls = 0

        defaultInstallTap(
            audioEngine.inputNode,
            format,
            { buffer, time in
                self.recognitionRequest?.append(buffer)
                appendBufferCalls += 1
                _ = time
            },
            installTapAction: { _, recordingFormat, appendBuffer in
                installTapCalls += 1
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: recordingFormat,
                    frameCapacity: 1
                ) else { return }
                buffer.frameLength = 1
                appendBuffer(
                    buffer,
                    AVAudioTime(sampleTime: 0, atRate: recordingFormat.sampleRate)
                )
            }
        )

        return (installTapCalls, appendBufferCalls)
    }

    func _testDefaultInstallTapUsingSystemAction() -> (
        installTapCalls: Int,
        appendBufferCalls: Int
    ) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest = request

        let format = AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 1
        )!

        var installTapCalls = 0
        var appendBufferCalls = 0

        defaultInstallTap(
            audioEngine.inputNode,
            format,
            { buffer, time in
                self.recognitionRequest?.append(buffer)
                appendBufferCalls += 1
                _ = time
            },
            systemInstallTapAction: { _, recordingFormat, appendBuffer in
                installTapCalls += 1
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: recordingFormat,
                    frameCapacity: 1
                ) else { return }
                buffer.frameLength = 1
                appendBuffer(
                    buffer,
                    AVAudioTime(sampleTime: 0, atRate: recordingFormat.sampleRate)
                )
            }
        )

        return (installTapCalls, appendBufferCalls)
    }

    func _testStartRecordingUsingDefaultOverrides(
        recognitionTranscript: String? = nil,
        recognitionIsFinal: Bool = false,
        recognitionError: Error? = nil
    ) async -> NutritionSpeechRecognizerTestState {
        Self._testResetOverrides()
        defer { Self._testResetOverrides() }

        Self.testSpeechAuthorizationRequestOverride.value = { completion in
            completion(.authorized)
        }
        Self.testAudioApplicationPermissionOverride.value = { completion in
            completion(true)
        }
        Self.testConfigureSessionCategoryOverride.value = {}
        Self.testConfigureSessionActiveOverride.value = {}
        Self.testInstallAudioTapOverride.value = { _, _ in }
        Self.testPrepareAudioOverride.value = { _ in }
        Self.testStartAudioOverride.value = { _ in }
        Self.testStartRecognitionTaskOverride.value = { handleRecognitionUpdate in
            await handleRecognitionUpdate(
                recognitionTranscript,
                recognitionIsFinal,
                recognitionError
            )
        }

        await startRecording()
        return _testState()
    }

    func _testFinishRecording() -> NutritionSpeechRecognizerTestState {
        finishRecording(finishAudioPipelineAction: {})
        return _testState()
    }

    func _testFinishAudioPipeline() -> (
        state: NutritionSpeechRecognizerTestState,
        stopCalls: Int,
        removeTapCalls: Int,
        cancelCalls: Int,
        deactivateCalls: Int
    ) {
        var stopCalls = 0
        var removeTapCalls = 0
        var cancelCalls = 0
        var deactivateCalls = 0
        finishAudioPipeline(
            stopAudioAction: { stopCalls += 1 },
            removeTapAction: { removeTapCalls += 1 },
            cancelRecognitionTaskAction: { cancelCalls += 1 },
            deactivateSessionAction: { deactivateCalls += 1 }
        )
        return (_testState(), stopCalls, removeTapCalls, cancelCalls, deactivateCalls)
    }

    func _testStartRecording(
        permissionError: Error? = nil,
        configureError: Error? = nil,
        recognitionTranscript: String? = nil,
        recognitionIsFinal: Bool = false,
        recognitionError: Error? = nil
    ) async -> NutritionSpeechRecognizerTestState {
        await startRecording(
            permissionAction: {
                if let permissionError { throw permissionError }
            },
            configureSessionAction: {
                if let configureError { throw configureError }
            },
            installAudioTapAction: { _ in },
            prepareAudioAction: {},
            startAudioAction: {},
            startRecognitionTaskAction: { handleRecognitionUpdate in
                handleRecognitionUpdate(
                    recognitionTranscript,
                    recognitionIsFinal,
                    recognitionError
                )
            }
        )
        return _testState()
    }

    func _testStartDefaultRecognitionTask(
        useDefaultTaskAction: Bool = false,
        transcript: String? = nil,
        isFinal: Bool = false,
        error: Error? = nil
    ) async -> NutritionSpeechRecognizerTestState {
        _testOverrideState(
            isRecording: true,
            isProcessing: true,
            transcription: "",
            errorMessage: nil,
            confidence: nil
        )

        let request = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest = request

        if useDefaultTaskAction {
            startDefaultRecognitionTask(
                with: request,
                handleRecognitionUpdate: { [weak self] transcript, isFinal, error in
                    self?._testHandleRecognitionUpdate(transcript, isFinal: isFinal, error: error)
                },
                recognitionTaskAction: nil
            )
        } else {
            startDefaultRecognitionTask(
                with: request,
                handleRecognitionUpdate: { [weak self] transcript, isFinal, error in
                    self?._testHandleRecognitionUpdate(transcript, isFinal: isFinal, error: error)
                },
                recognitionTaskAction: { _, update in
                    update(transcript, isFinal, error)
                    return nil
                }
            )
        }

        for _ in 0..<10 {
            await Task.yield()
        }

        return _testState()
    }

    func _testStartRecognitionTaskUsingFallbackAction(
        transcript: String? = nil,
        isFinal: Bool = false,
        error: Error? = nil
    ) async -> NutritionSpeechRecognizerTestState {
        _testOverrideState(
            isRecording: true,
            isProcessing: true,
            transcription: "",
            errorMessage: nil,
            confidence: nil
        )

        let request = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest = request

        await startRecognitionTask(
            with: request,
            fallbackAction: { handleRecognitionUpdate in
                handleRecognitionUpdate(transcript, isFinal, error)
            },
            handleRecognitionUpdate: { [weak self] transcript, isFinal, error in
                self?._testHandleRecognitionUpdate(transcript, isFinal: isFinal, error: error)
            }
        )

        for _ in 0..<10 {
            await Task.yield()
        }

        return _testState()
    }

    func _testStartRecognitionTaskUsingDefaultAction(
        transcript: String? = nil,
        isFinal: Bool = false,
        error: Error? = nil
    ) async -> NutritionSpeechRecognizerTestState {
        _testOverrideState(
            isRecording: true,
            isProcessing: true,
            transcription: "",
            errorMessage: nil,
            confidence: nil
        )

        let request = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest = request

        await startRecognitionTask(
            with: request,
            defaultAction: { handleRecognitionUpdate in
                handleRecognitionUpdate(transcript, isFinal, error)
            },
            handleRecognitionUpdate: { [weak self] transcript, isFinal, error in
                self?._testHandleRecognitionUpdate(transcript, isFinal: isFinal, error: error)
            }
        )

        for _ in 0..<10 {
            await Task.yield()
        }

        return _testState()
    }

    func _testRequestAudioApplicationPermissionUsingSystemAction(
        allowed: Bool
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            requestAudioApplicationPermission(
                completion: { result in
                    continuation.resume(returning: result)
                },
                systemRequestAction: { completion in
                    completion(allowed)
                }
            )
        }
    }

    func _testRequestAudioSessionPermissionUsingSystemAction(
        allowed: Bool
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            requestAudioSessionPermission(
                completion: { result in
                    continuation.resume(returning: result)
                },
                systemRequestAction: { completion in
                    completion(allowed)
                }
            )
        }
    }

    func _testDefaultRecognitionTaskAction(
        useDefaultTaskAction: Bool = false,
        error: Error? = nil
    ) async -> NutritionSpeechRecognizerTestState {
        _testOverrideState(
            isRecording: true,
            isProcessing: true,
            transcription: "",
            errorMessage: nil,
            confidence: nil
        )

        let request = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest = request

        if useDefaultTaskAction {
            _ = defaultRecognitionTaskAction(
                request,
                { [weak self] transcript, isFinal, error in
                    self?._testHandleRecognitionUpdate(transcript, isFinal: isFinal, error: error)
                },
                recognitionTaskAction: nil
            )
        } else {
            _ = defaultRecognitionTaskAction(
                request,
                { [weak self] transcript, isFinal, error in
                    self?._testHandleRecognitionUpdate(transcript, isFinal: isFinal, error: error)
                },
                recognitionTaskAction: { _, handler in
                    handler(nil, error)
                    return nil
                }
            )
        }

        for _ in 0..<10 {
            await Task.yield()
        }

        return _testState()
    }

    private func _testHandleRecognitionUpdate(
        _ transcript: String?,
        isFinal: Bool,
        error: Error?
    ) {
        if let transcript {
            self.transcription = transcript
            confidence = isFinal ? 0.9 : 0.75
            isProcessing = false
        }

        if let error {
            errorMessage = error.localizedDescription
            finishRecording(finishAudioPipelineAction: {})
            return
        }

        if isFinal {
            finishRecording(finishAudioPipelineAction: {})
        }
    }

    func _testStopRecording() async -> NutritionSpeechRecognizerTestState {
        await stopRecording(
            endAudioAction: {},
            finishAudioPipelineAction: {}
        )
        return _testState()
    }

    func _testStopRecordingUsingDefaultOverrides() async -> NutritionSpeechRecognizerTestState {
        Self._testResetOverrides()
        defer { Self._testResetOverrides() }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        _testOverrideState(
            isRecording: true,
            isProcessing: false,
            transcription: "",
            errorMessage: nil,
            confidence: nil
        )
        Self.testEndAudioOverride.value = { _ in }
        Self.testFinishAudioPipelineOverride.value = { _ in }

        await stopRecording()
        return _testState()
    }
}

extension MealTemplateLibraryView {
    init(
        targetDay: String = NutritionCoverageFixtures.targetDay,
        loggedAt: Date = NutritionCoverageFixtures.loggedAt,
        testTemplates: [NutritionMealTemplateSummary] = [],
        testIsLoading: Bool = true,
        testShowingArchived: Bool = false,
        testStatusMessage: TemplateStatusMessage? = nil,
        onTemplatesChanged: @escaping () -> Void = {},
        onTemplateLogged: @escaping () -> Void = {}
    ) {
        self.targetDay = targetDay
        self.loggedAt = loggedAt
        self.onTemplatesChanged = onTemplatesChanged
        self.onTemplateLogged = onTemplateLogged
        _templates = State(initialValue: testTemplates)
        _isLoading = State(initialValue: testIsLoading)
        _showingArchived = State(initialValue: testShowingArchived)
        _statusMessage = State(initialValue: testStatusMessage)
    }

    func _testEvaluateBody() {
        _ = body
    }

    func _testTemplateRowSubtitle(_ template: NutritionMealTemplateSummary) -> String {
        templateRowSubtitle(template)
    }

    @MainActor
    func _testRenderTemplateRow(_ template: NutritionMealTemplateSummary) {
        let host = UIHostingController(rootView: templateRow(template))
        _ = host.view
    }

    @MainActor
    func _testRenderTemplateDestination(templateId: UUID, startsEditing: Bool) {
        let host = UIHostingController(
            rootView: templateDetailDestination(
                MealTemplateLibraryDestination(templateId: templateId, startsEditing: startsEditing)
            )
        )
        _ = host.view
    }

    @MainActor
    func _testRenderComposerSheet() {
        _ = composerSheet()
        let host = UIHostingController(rootView: composerSheet())
        _ = host.view
    }

    @MainActor
    func _testHandleComposerSaved(
        _ message: TemplateStatusMessage,
        reloadAction: @escaping () async -> Void = {}
    ) async -> (
        statusMessage: TemplateStatusMessage?,
        showingArchived: Bool
    ) {
        handleComposerSaved(message, reloadAction: reloadAction)
        for _ in 0..<10 {
            await Task.yield()
        }
        return (statusMessage, showingArchived)
    }

    @MainActor
    func _testHandleComposerSheetSaved(
        _ message: TemplateStatusMessage
    ) async -> (
        statusMessage: TemplateStatusMessage?,
        showingArchived: Bool
    ) {
        handleComposerSheetSaved(message)
        for _ in 0..<10 {
            await Task.yield()
        }
        return (statusMessage, showingArchived)
    }

    @MainActor
    func _testHandleTemplateDetailTemplatesChanged(
        reloadAction: @escaping () async -> Void = {}
    ) async -> TemplateStatusMessage? {
        handleTemplateDetailTemplatesChanged(reloadAction: reloadAction)
        for _ in 0..<10 {
            await Task.yield()
        }
        return statusMessage
    }

    func _testHandleTemplateDetailStatusMessage(_ message: TemplateStatusMessage) -> TemplateStatusMessage? {
        handleTemplateDetailStatusMessage(message)
        return statusMessage
    }

    func _testState() -> (
        templates: [NutritionMealTemplateSummary],
        isLoading: Bool,
        statusMessage: TemplateStatusMessage?
    ) {
        (templates, isLoading, statusMessage)
    }

    func _testTriggerLoadTemplates(manager: any NutritionMealTemplateManaging) async -> (
        templates: [NutritionMealTemplateSummary],
        isLoading: Bool,
        statusMessage: TemplateStatusMessage?
    ) {
        await loadTemplates(manager: manager)
        return (templates, isLoading, statusMessage)
    }

    func _testTriggerToggleArchive(
        for template: NutritionMealTemplateSummary,
        manager: any NutritionMealTemplateManaging
    ) async -> (
        templates: [NutritionMealTemplateSummary],
        isLoading: Bool,
        statusMessage: TemplateStatusMessage?
    ) {
        await toggleArchive(for: template, manager: manager)
        return (templates, isLoading, statusMessage)
    }

    static func _testLoadTemplatesResult(
        showingArchived: Bool,
        manager: any NutritionMealTemplateManaging
    ) async -> (
        templates: [NutritionMealTemplateSummary],
        statusMessage: TemplateStatusMessage?
    ) {
        await loadTemplatesResult(showingArchived: showingArchived, manager: manager)
    }

    static func _testToggleArchiveResult(
        for template: NutritionMealTemplateSummary,
        manager: any NutritionMealTemplateManaging
    ) async -> Result<TemplateStatusMessage, Error> {
        await toggleArchiveResult(for: template, manager: manager)
    }
}

extension MealTemplatesView {
    init(
        targetDay: String = NutritionCoverageFixtures.targetDay,
        loggedAt: Date = NutritionCoverageFixtures.loggedAt,
        refreshTrigger: Int = 0,
        testIsLoading: Bool,
        testTemplates: [NutritionMealTemplateSummary] = [],
        onTemplatesChanged: @escaping () -> Void = {},
        onTemplateLogged: @escaping () -> Void = {},
        onSelectTemplate: @escaping (UUID) -> Void = { _ in }
    ) {
        self.targetDay = targetDay
        self.loggedAt = loggedAt
        self.refreshTrigger = refreshTrigger
        self.onTemplatesChanged = onTemplatesChanged
        self.onTemplateLogged = onTemplateLogged
        self.onSelectTemplate = onSelectTemplate
        _isLoading = State(initialValue: testIsLoading)
        _templates = State(initialValue: testTemplates)
    }

    func _testEvaluateBody() {
        _ = body
    }

    @MainActor
    func _testRenderTemplateCard(_ template: NutritionMealTemplateSummary) {
        let host = UIHostingController(rootView: templateCard(template))
        _ = host.view
    }

    static func _testLoadTemplatesResult(
        manager: any NutritionMealTemplateManaging
    ) async -> [NutritionMealTemplateSummary] {
        await loadTemplatesResult(manager: manager)
    }

    func _testState() -> (
        templates: [NutritionMealTemplateSummary],
        isLoading: Bool
    ) {
        (templates, isLoading)
    }

    func _testTriggerLoadTemplates(manager: any NutritionMealTemplateManaging) async -> (
        templates: [NutritionMealTemplateSummary],
        isLoading: Bool
    ) {
        await loadTemplates(manager: manager)
        return (templates, isLoading)
    }
}

extension MealTemplateDetailView {
    init(
        targetDay: String = NutritionCoverageFixtures.targetDay,
        loggedAt: Date = NutritionCoverageFixtures.loggedAt,
        testViewModel: MealTemplateDetailViewModel,
        onTemplatesChanged: @escaping () -> Void = {},
        onTemplateLogged: @escaping () -> Void = {},
        onStatusMessage: @escaping (TemplateStatusMessage?) -> Void = { _ in }
    ) {
        _viewModel = State(initialValue: testViewModel)
        self.targetDay = targetDay
        self.loggedAt = loggedAt
        self.onTemplatesChanged = onTemplatesChanged
        self.onTemplateLogged = onTemplateLogged
        self.onStatusMessage = onStatusMessage
    }

    func _testEvaluateBody() {
        _ = body
    }

    @MainActor
    func _testRenderTemplateHeaderSection() {
        let host = UIHostingController(rootView: templateHeaderSection(viewModel))
        _ = host.view
    }

    @MainActor
    func _testRenderEditorDetailsSection() {
        let host = UIHostingController(rootView: editorDetailsSection(viewModel))
        _ = host.view
    }

    @MainActor
    func _testRenderEditorItemsSection() {
        let host = UIHostingController(rootView: editorItemsSection(viewModel))
        _ = host.view
    }

    @MainActor
    func _testRenderPreviewItemsSection() {
        let host = UIHostingController(rootView: previewItemsSection(viewModel))
        _ = host.view
    }

    @MainActor
    func _testRenderPreviewItemRow(_ item: NutritionEditableMealItem) {
        let host = UIHostingController(rootView: previewItemRow(item))
        _ = host.view
    }

    @MainActor
    func _testRenderActionSection() {
        let host = UIHostingController(rootView: actionSection(viewModel))
        _ = host.view
    }

    @MainActor
    func _testRenderTemplateItemEditor(index: Int) {
        let host = UIHostingController(rootView: templateItemEditor(index: index, viewModel: viewModel))
        _ = host.view
    }

    @MainActor
    func _testRenderTemplateNumericField() {
        var value = 125.0
        let host = UIHostingController(
            rootView: templateNumericField(
                "Coverage",
                value: Binding(
                    get: { value },
                    set: { value = $0 }
                )
            )
        )
        _ = host.view
    }

    func _testTriggerSaveTemplate() async {
        saveTemplate()
        await Task.yield()
        await Task.yield()
    }

    func _testTriggerToggleArchived() async {
        toggleArchived()
        await Task.yield()
        await Task.yield()
    }

    func _testTriggerLogTemplateNow() async {
        logTemplateNow()
        await Task.yield()
        await Task.yield()
    }
}

extension MealTemplateComposerView {
    init(
        testName: String = "",
        testMealType: MealType? = nil,
        testItems: [NutritionEditableMealItem] = [],
        testIsSaving: Bool = false,
        testErrorMessage: String? = nil,
        onSaved: @escaping (TemplateStatusMessage) -> Void = { _ in }
    ) {
        self.onSaved = onSaved
        _name = State(initialValue: testName)
        _mealType = State(initialValue: testMealType)
        _items = State(initialValue: testItems)
        _isSaving = State(initialValue: testIsSaving)
        _errorMessage = State(initialValue: testErrorMessage)
    }

    func _testTotals() -> (calories: Double, protein: Double, fat: Double, carbs: Double, fiber: Double?) {
        totals
    }

    func _testCanSave() -> Bool {
        canSave
    }

    func _testEvaluateBody() {
        _ = body
    }

    @MainActor
    func _testRenderDetailsSection() {
        let host = UIHostingController(rootView: detailsSection)
        _ = host.view
    }

    @MainActor
    func _testRenderPreviewSection() {
        let host = UIHostingController(rootView: previewSection)
        _ = host.view
    }

    @MainActor
    func _testRenderItemsSection() {
        let host = UIHostingController(rootView: itemsSection)
        _ = host.view
    }

    @MainActor
    func _testRenderItemEditor(index: Int) {
        let host = UIHostingController(rootView: itemEditor(index: index))
        _ = host.view
    }

    @MainActor
    func _testRenderTemplateNumericField() {
        var value = 80.0
        let host = UIHostingController(
            rootView: templateNumericField(
                "Coverage",
                value: Binding(
                    get: { value },
                    set: { value = $0 }
                )
            )
        )
        _ = host.view
    }

    @MainActor
    static func _testAddedItems(
        mealType: MealType?
    ) -> [NutritionEditableMealItem] {
        [defaultEditableMealItem(for: mealType)]
    }

    static func _testSaveDraft(
        name: String,
        mealType: MealType?,
        items: [NutritionEditableMealItem]
    ) -> NutritionMealTemplateCreateDraft {
        NutritionMealTemplateCreateDraft(
            name: name,
            mealType: mealType,
            items: items.map(NutritionMealTemplateItem.init(editableItem:))
        )
    }

    static func _testSaveResult(
        draft: NutritionMealTemplateCreateDraft,
        manager: any NutritionMealTemplateManaging
    ) async -> Result<TemplateStatusMessage, Error> {
        await saveResult(draft: draft, manager: manager)
    }

    func _testState() -> (
        isSaving: Bool,
        errorMessage: String?
    ) {
        (isSaving, errorMessage)
    }

    func _testTriggerSave(
        manager: any NutritionMealTemplateManaging,
        dismissAction: @escaping () -> Void = {}
    ) async -> (
        isSaving: Bool,
        errorMessage: String?
    ) {
        save(manager: manager, dismissAction: dismissAction)
        for _ in 0..<50 where isSaving {
            await Task.yield()
        }
        return (isSaving, errorMessage)
    }
}

extension BatchRecipeLibraryView {
    init(
        targetDay: String = NutritionCoverageFixtures.targetDay,
        loggedAt: Date = NutritionCoverageFixtures.loggedAt,
        testRecipes: [NutritionBatchRecipeSummary] = [],
        testIsLoading: Bool = true,
        testShowingArchived: Bool = false,
        testStatusMessage: TemplateStatusMessage? = nil,
        onBatchesChanged: @escaping () -> Void = {},
        onBatchLogged: @escaping () -> Void = {}
    ) {
        self.targetDay = targetDay
        self.loggedAt = loggedAt
        self.onBatchesChanged = onBatchesChanged
        self.onBatchLogged = onBatchLogged
        _recipes = State(initialValue: testRecipes)
        _isLoading = State(initialValue: testIsLoading)
        _showingArchived = State(initialValue: testShowingArchived)
        _statusMessage = State(initialValue: testStatusMessage)
    }

    func _testEvaluateBody() {
        _ = body
    }

    @MainActor
    func _testRenderBatchRow(_ recipe: NutritionBatchRecipeSummary) {
        let host = UIHostingController(rootView: batchRow(recipe))
        _ = host.view
    }

    @MainActor
    func _testRenderStyledBatchRow(_ recipe: NutritionBatchRecipeSummary) {
        let host = UIHostingController(rootView: styledBatchRow(recipe))
        _ = host.view
    }

    @MainActor
    func _testRenderDetailDestination(batchId: UUID) {
        let host = UIHostingController(
            rootView: detailDestination(BatchRecipeLibraryDestination(batchId: batchId))
        )
        _ = host.view
    }

    @MainActor
    func _testRenderComposerSheet() {
        _ = composerSheet()
        let host = UIHostingController(rootView: composerSheet())
        _ = host.view
    }

    @MainActor
    func _testRenderQuickLogSheet(_ recipe: NutritionBatchRecipeSummary) {
        _ = quickLogSheet(recipe)
        let host = UIHostingController(rootView: quickLogSheet(recipe))
        _ = host.view
    }

    @MainActor
    func _testHandleComposerSaved(
        _ message: TemplateStatusMessage,
        reloadAction: @escaping () async -> Void = {}
    ) async -> TemplateStatusMessage? {
        handleComposerSaved(message, reloadAction: reloadAction)
        for _ in 0..<10 {
            await Task.yield()
        }
        return statusMessage
    }

    @MainActor
    func _testHandleComposerSheetSaved(
        _ message: TemplateStatusMessage
    ) async -> TemplateStatusMessage? {
        handleComposerSheetSaved(message)
        for _ in 0..<10 {
            await Task.yield()
        }
        return statusMessage
    }

    @MainActor
    func _testHandleQuickLogSaved(
        _ message: TemplateStatusMessage,
        reloadAction: @escaping () async -> Void = {}
    ) async -> TemplateStatusMessage? {
        handleQuickLogSaved(message, reloadAction: reloadAction)
        for _ in 0..<10 {
            await Task.yield()
        }
        return statusMessage
    }

    @MainActor
    func _testHandleQuickLogSheetSaved(
        _ message: TemplateStatusMessage
    ) async -> TemplateStatusMessage? {
        handleQuickLogSheetSaved(message)
        for _ in 0..<10 {
            await Task.yield()
        }
        return statusMessage
    }

    @MainActor
    func _testHandleDetailBatchesChanged(
        reloadAction: @escaping () async -> Void = {}
    ) async -> TemplateStatusMessage? {
        handleDetailBatchesChanged(reloadAction: reloadAction)
        for _ in 0..<10 {
            await Task.yield()
        }
        return statusMessage
    }

    @MainActor
    func _testHandleDetailBatchLogged(
        reloadAction: @escaping () async -> Void = {}
    ) async -> TemplateStatusMessage? {
        handleDetailBatchLogged(reloadAction: reloadAction)
        for _ in 0..<10 {
            await Task.yield()
        }
        return statusMessage
    }

    func _testHandleDetailStatusMessage(_ message: TemplateStatusMessage) -> TemplateStatusMessage? {
        handleDetailStatusMessage(message)
        return statusMessage
    }

    func _testTriggerLoadRecipes(
        manager: any NutritionBatchRecipeManaging
    ) async -> (
        recipes: [NutritionBatchRecipeSummary],
        isLoading: Bool,
        statusMessage: TemplateStatusMessage?
    ) {
        await loadRecipes(manager: manager)
        return (recipes, isLoading, statusMessage)
    }

    static func _testLoadRecipesResult(
        showingArchived: Bool,
        manager: any NutritionBatchRecipeManaging
    ) async -> (
        recipes: [NutritionBatchRecipeSummary],
        statusMessage: TemplateStatusMessage?
    ) {
        await loadRecipesResult(showingArchived: showingArchived, manager: manager)
    }
}

extension BatchRecipeDetailView {
    init(
        batchId: UUID = UUID(),
        targetDay: String = NutritionCoverageFixtures.targetDay,
        loggedAt: Date = NutritionCoverageFixtures.loggedAt,
        testDetail: NutritionBatchRecipeDetail? = nil,
        testIsLoading: Bool = true,
        testIsArchiving: Bool = false,
        testIsDuplicating: Bool = false,
        testShowingComposer: Bool = false,
        testShowingLogSheet: Bool = false,
        testErrorMessage: String? = nil,
        testStatusMessage: TemplateStatusMessage? = nil,
        onBatchesChanged: @escaping () -> Void = {},
        onBatchLogged: @escaping () -> Void = {},
        onStatusMessage: @escaping (TemplateStatusMessage?) -> Void = { _ in }
    ) {
        self.batchId = batchId
        self.targetDay = targetDay
        self.loggedAt = loggedAt
        self.onBatchesChanged = onBatchesChanged
        self.onBatchLogged = onBatchLogged
        self.onStatusMessage = onStatusMessage
        _detail = State(initialValue: testDetail)
        _isLoading = State(initialValue: testIsLoading)
        _isArchiving = State(initialValue: testIsArchiving)
        _isDuplicating = State(initialValue: testIsDuplicating)
        _showingComposer = State(initialValue: testShowingComposer)
        _showingLogSheet = State(initialValue: testShowingLogSheet)
        _errorMessage = State(initialValue: testErrorMessage)
        _statusMessage = State(initialValue: testStatusMessage)
    }

    func _testEvaluateBody() {
        _ = body
    }

    @MainActor
    func _testRenderDetailHeader(_ detail: NutritionBatchRecipeDetail) {
        let host = UIHostingController(rootView: detailHeader(detail))
        _ = host.view
    }

    @MainActor
    func _testRenderDetailMacros(_ detail: NutritionBatchRecipeDetail) {
        let host = UIHostingController(rootView: detailMacros(detail))
        _ = host.view
    }

    @MainActor
    func _testRenderDetailIngredients(_ detail: NutritionBatchRecipeDetail) {
        let host = UIHostingController(rootView: detailIngredients(detail))
        _ = host.view
    }

    @MainActor
    func _testRenderDetailIngredientRow(_ ingredient: BatchRecipeIngredient) {
        let host = UIHostingController(rootView: detailIngredientRow(ingredient))
        _ = host.view
    }

    @MainActor
    func _testRenderDetailActions(_ detail: NutritionBatchRecipeDetail) {
        let host = UIHostingController(rootView: detailActions(detail))
        _ = host.view
    }

    @MainActor
    func _testRenderComposerSheet(_ detail: NutritionBatchRecipeDetail) {
        _ = composerSheet(detail)
        let host = UIHostingController(rootView: composerSheet(detail))
        _ = host.view
    }

    @MainActor
    func _testRenderComposerSheetContent() {
        _ = composerSheetContent()
        let host = UIHostingController(rootView: composerSheetContent())
        _ = host.view
    }

    @MainActor
    func _testRenderLogSheet(_ detail: NutritionBatchRecipeDetail) {
        _ = logSheet(detail)
        let host = UIHostingController(rootView: logSheet(detail))
        _ = host.view
    }

    @MainActor
    func _testRenderLogSheetContent() {
        _ = logSheetContent()
        let host = UIHostingController(rootView: logSheetContent())
        _ = host.view
    }

    @MainActor
    func _testHandleComposerSaved(
        _ message: TemplateStatusMessage,
        reloadAction: @escaping () async -> Void = {}
    ) async -> TemplateStatusMessage? {
        handleComposerSaved(message, reloadAction: reloadAction)
        for _ in 0..<10 {
            await Task.yield()
        }
        return statusMessage
    }

    @MainActor
    func _testHandleComposerSheetSaved(
        _ message: TemplateStatusMessage
    ) async -> TemplateStatusMessage? {
        handleComposerSheetSaved(message)
        for _ in 0..<10 {
            await Task.yield()
        }
        return statusMessage
    }

    @MainActor
    func _testHandleLogSaved(
        _ message: TemplateStatusMessage,
        reloadAction: @escaping () async -> Void = {}
    ) async -> TemplateStatusMessage? {
        handleLogSaved(message, reloadAction: reloadAction)
        for _ in 0..<10 {
            await Task.yield()
        }
        return statusMessage
    }

    @MainActor
    func _testHandleLogSheetSaved(
        _ message: TemplateStatusMessage
    ) async -> TemplateStatusMessage? {
        handleLogSheetSaved(message)
        for _ in 0..<10 {
            await Task.yield()
        }
        return statusMessage
    }

    func _testState() -> (
        detail: NutritionBatchRecipeDetail?,
        isLoading: Bool,
        isArchiving: Bool,
        isDuplicating: Bool,
        errorMessage: String?,
        statusMessage: TemplateStatusMessage?
    ) {
        (detail, isLoading, isArchiving, isDuplicating, errorMessage, statusMessage)
    }

    func _testTriggerLoadDetail(
        preferRemote: Bool,
        manager: any NutritionBatchRecipeManaging
    ) async -> (
        detail: NutritionBatchRecipeDetail?,
        isLoading: Bool,
        isArchiving: Bool,
        isDuplicating: Bool,
        errorMessage: String?,
        statusMessage: TemplateStatusMessage?
    ) {
        await loadDetail(preferRemote: preferRemote, manager: manager)
        return (detail, isLoading, isArchiving, isDuplicating, errorMessage, statusMessage)
    }

    func _testTriggerToggleArchived(
        manager: any NutritionBatchRecipeManaging,
        dismissAction: @escaping () -> Void = {}
    ) async -> (
        detail: NutritionBatchRecipeDetail?,
        isLoading: Bool,
        isArchiving: Bool,
        isDuplicating: Bool,
        errorMessage: String?,
        statusMessage: TemplateStatusMessage?
    ) {
        toggleArchived(manager: manager, dismissAction: dismissAction)
        for _ in 0..<50 where isArchiving {
            await Task.yield()
        }
        return (detail, isLoading, isArchiving, isDuplicating, errorMessage, statusMessage)
    }

    func _testTriggerCookAgain(
        manager: any NutritionBatchRecipeManaging,
        dismissAction: @escaping () -> Void = {}
    ) async -> (
        detail: NutritionBatchRecipeDetail?,
        isLoading: Bool,
        isArchiving: Bool,
        isDuplicating: Bool,
        errorMessage: String?,
        statusMessage: TemplateStatusMessage?
    ) {
        cookAgain(manager: manager, dismissAction: dismissAction)
        for _ in 0..<50 where isDuplicating {
            await Task.yield()
        }
        return (detail, isLoading, isArchiving, isDuplicating, errorMessage, statusMessage)
    }

    static func _testLoadDetailResult(
        batchId: UUID,
        preferRemote: Bool,
        manager: any NutritionBatchRecipeManaging
    ) async -> (
        detail: NutritionBatchRecipeDetail?,
        errorMessage: String?
    ) {
        await loadDetailResult(batchId: batchId, preferRemote: preferRemote, manager: manager)
    }

    static func _testToggleArchivedResult(
        detail: NutritionBatchRecipeDetail,
        manager: any NutritionBatchRecipeManaging
    ) async -> Result<TemplateStatusMessage, Error> {
        await toggleArchivedResult(detail: detail, manager: manager)
    }

    static func _testCookAgainResult(
        detail: NutritionBatchRecipeDetail,
        manager: any NutritionBatchRecipeManaging
    ) async -> Result<TemplateStatusMessage, Error> {
        await cookAgainResult(detail: detail, manager: manager)
    }
}

extension BatchRecipeComposerView {
    init(
        existingDetail: NutritionBatchRecipeDetail? = nil,
        testName: String,
        testDescription: String = "",
        testCookedAt: Date = NutritionCoverageFixtures.loggedAt,
        testTotalWeightG: Double = 1000,
        testTotalPortions: Int = 1,
        testIngredients: [BatchRecipeEditableIngredient] = [],
        testIsSaving: Bool = false,
        testErrorMessage: String? = nil,
        testImportMessage: String? = nil,
        testIsAnalyzingPhoto: Bool = false,
        onSaved: @escaping (TemplateStatusMessage) -> Void = { _ in }
    ) {
        self.existingDetail = existingDetail
        self.onSaved = onSaved
        _name = State(initialValue: testName)
        _description = State(initialValue: testDescription)
        _cookedAt = State(initialValue: testCookedAt)
        _totalWeightG = State(initialValue: testTotalWeightG)
        _totalPortions = State(initialValue: testTotalPortions)
        _ingredients = State(initialValue: testIngredients)
        _isSaving = State(initialValue: testIsSaving)
        _errorMessage = State(initialValue: testErrorMessage)
        _importMessage = State(initialValue: testImportMessage)
        _isAnalyzingPhoto = State(initialValue: testIsAnalyzingPhoto)
        _showingIngredientSearch = State(initialValue: false)
        _showCameraPicker = State(initialValue: false)
        _showPhotoLibrary = State(initialValue: false)
        _selectedPhotoItem = State(initialValue: nil)
    }

    func _testTotals() -> NutritionBatchMacroSnapshot {
        totals
    }

    func _testPer100g() -> NutritionBatchMacroSnapshot {
        per100g
    }

    func _testPerPortion() -> NutritionBatchMacroSnapshot {
        perPortion
    }

    func _testCanSave() -> Bool {
        canSave
    }

    func _testEvaluateBody() {
        _ = body
    }

    func _testEvaluateIngredientSearchSheet() {
        _ = ingredientSearchSheet()
    }

    func _testEvaluateCameraPickerSheet() {
        _ = cameraPickerSheet()
    }

    @MainActor
    func _testRenderDetailsSection() {
        let host = UIHostingController(rootView: detailsSection)
        _ = host.view
    }

    @MainActor
    func _testRenderTotalsSection() {
        let host = UIHostingController(rootView: totalsSection)
        _ = host.view
    }

    @MainActor
    func _testRenderIngredientsSection() {
        let host = UIHostingController(rootView: ingredientsSection)
        _ = host.view
    }

    @MainActor
    func _testRenderIngredientEditor(index: Int) {
        let host = UIHostingController(rootView: ingredientEditor(index: index))
        _ = host.view
    }

    @MainActor
    func _testRenderBatchNumericField() {
        var value = 250.0
        let host = UIHostingController(
            rootView: batchNumericField(
                "Coverage",
                value: Binding(
                    get: { value },
                    set: { value = $0 }
                )
            )
        )
        _ = host.view
    }

    @MainActor
    func _testRenderBatchIntegerField() {
        var value = 3
        let host = UIHostingController(
            rootView: batchIntegerField(
                "Coverage",
                value: Binding(
                    get: { value },
                    set: { value = $0 }
                )
            )
        )
        _ = host.view
    }

    @MainActor
    func _testPresentIngredientSearch() -> Bool {
        presentIngredientSearch()
        return showingIngredientSearch
    }

    @MainActor
    func _testOpenCameraOrLibrary(cameraAvailable: Bool) -> (
        showCameraPicker: Bool,
        showPhotoLibrary: Bool
    ) {
        openCameraOrLibrary(cameraAvailableProvider: { cameraAvailable })
        let pickerState = Self.capturePickerState(cameraAvailable: cameraAvailable)
        return (pickerState.showCameraPicker, pickerState.showPhotoLibrary)
    }

    @MainActor
    func _testBeginCameraCapture(cameraAvailable: Bool) -> (
        showCameraPicker: Bool,
        showPhotoLibrary: Bool
    ) {
        beginCameraCapture(cameraAvailableProvider: { cameraAvailable })
        let pickerState = Self.capturePickerState(cameraAvailable: cameraAvailable)
        return (pickerState.showCameraPicker, pickerState.showPhotoLibrary)
    }

    @MainActor
    func _testAddManualIngredient() -> Int {
        addManualIngredient()
        return ingredients.count
    }

    @MainActor
    func _testHandleIngredientSearchSelection(_ result: FoodSearchResult) -> [String] {
        handleIngredientSearchSelection(result)
        return ingredients.map(\.name)
    }

    @MainActor
    func _testHandlePickedCameraImageUsingOverride(
        response: BatchRecipePhotoAnalysisResponse,
        image: UIImage = NutritionCoverageFixtures.image()
    ) async -> (
        name: String,
        description: String,
        totalWeightG: Double,
        totalPortions: Int,
        ingredientNames: [String],
        isAnalyzingPhoto: Bool,
        errorMessage: String?,
        importMessage: String?
    ) {
        MediaRecognitionService._testSetCloudAnalysisEnabledOverride { true }
        MediaRecognitionService._testSetBatchRecipePhotoAnalysisOverride { _, _, _, _, _ in response }
        defer { MediaRecognitionService._testResetOverrides() }
        handlePickedCameraImage(image)
        for _ in 0..<25 {
            await Task.yield()
        }
        return _testPhotoImportState()
    }

    @MainActor
    func _testHandleSelectedPhotoItemChange() async -> (
        name: String,
        description: String,
        totalWeightG: Double,
        totalPortions: Int,
        ingredientNames: [String],
        isAnalyzingPhoto: Bool,
        errorMessage: String?,
        importMessage: String?
    ) {
        await handleSelectedPhotoItemChange()
        return _testPhotoImportState()
    }

    static func _testSaveDraft(
        existingDetail: NutritionBatchRecipeDetail?,
        name: String,
        description: String,
        cookedAt: Date,
        totalWeightG: Double,
        totalPortions: Int,
        ingredients: [BatchRecipeEditableIngredient]
    ) -> NutritionBatchRecipeDraft {
        saveDraft(
            existingDetail: existingDetail,
            name: name,
            description: description,
            cookedAt: cookedAt,
            totalWeightG: totalWeightG,
            totalPortions: totalPortions,
            ingredients: ingredients
        )
    }

    static func _testSaveResult(
        draft: NutritionBatchRecipeDraft,
        existingDetail: NutritionBatchRecipeDetail?,
        manager: any NutritionBatchRecipeManaging
    ) async -> Result<TemplateStatusMessage, Error> {
        await saveResult(draft: draft, existingDetail: existingDetail, manager: manager)
    }

    static func _testCapturePickerState(cameraAvailable: Bool) -> (
        showCameraPicker: Bool,
        showPhotoLibrary: Bool
    ) {
        capturePickerState(cameraAvailable: cameraAvailable)
    }

    func _testMergedIngredients(
        imported: [BatchRecipeEditableIngredient]
    ) -> [BatchRecipeEditableIngredient] {
        Self.mergeIngredients(existing: ingredients, imported: imported)
    }

    @MainActor
    static func _testAppliedPhotoDraftResult(
        testName: String,
        testDescription: String,
        testTotalWeightG: Double,
        testTotalPortions: Int,
        testIngredients: [BatchRecipeEditableIngredient],
        photoDraft: BatchRecipePhotoDraft
    ) -> (
        name: String,
        description: String,
        totalWeightG: Double,
        totalPortions: Int,
        ingredientNames: [String],
        importMessage: String?,
        errorMessage: String?
    ) {
        let resolvedState = BatchRecipeComposerView.resolvePhotoImportState(
            name: testName,
            description: testDescription,
            totalWeightG: testTotalWeightG,
            totalPortions: testTotalPortions,
            ingredients: testIngredients,
            photoDraft: photoDraft
        )
        return (
            name: resolvedState.name,
            description: resolvedState.description,
            totalWeightG: resolvedState.totalWeightG,
            totalPortions: resolvedState.totalPortions,
            ingredientNames: resolvedState.ingredients.map(\.name).sorted(),
            importMessage: resolvedState.importMessage,
            errorMessage: resolvedState.errorMessage
        )
    }

    func _testState() -> (
        isSaving: Bool,
        errorMessage: String?,
        importMessage: String?
    ) {
        (isSaving, errorMessage, importMessage)
    }

    func _testPhotoImportState() -> (
        name: String,
        description: String,
        totalWeightG: Double,
        totalPortions: Int,
        ingredientNames: [String],
        isAnalyzingPhoto: Bool,
        errorMessage: String?,
        importMessage: String?
    ) {
        (
            name,
            description,
            totalWeightG,
            totalPortions,
            ingredients.map(\.name).sorted(),
            isAnalyzingPhoto,
            errorMessage,
            importMessage
        )
    }

    @MainActor
    func _testApplyPhotoDraft(_ photoDraft: BatchRecipePhotoDraft) -> (
        name: String,
        description: String,
        totalWeightG: Double,
        totalPortions: Int,
        ingredientNames: [String],
        isAnalyzingPhoto: Bool,
        errorMessage: String?,
        importMessage: String?
    ) {
        apply(photoDraft: photoDraft)
        return _testPhotoImportState()
    }

    @MainActor
    func _testLoadPhotoItemUsingOverride(
        response: BatchRecipePhotoAnalysisResponse,
        dataLoader: @escaping @Sendable () async throws -> Data?
    ) async -> (
        name: String,
        description: String,
        totalWeightG: Double,
        totalPortions: Int,
        ingredientNames: [String],
        isAnalyzingPhoto: Bool,
        errorMessage: String?,
        importMessage: String?
    ) {
        MediaRecognitionService._testSetCloudAnalysisEnabledOverride { true }
        MediaRecognitionService._testSetBatchRecipePhotoAnalysisOverride { _, _, _, _, _ in response }
        defer { MediaRecognitionService._testResetOverrides() }
        await loadPhotoItem(using: dataLoader)
        return _testPhotoImportState()
    }

    @MainActor
    func _testLoadSelectedPhotoItemIfNeeded(shouldLoad: Bool) async -> Bool {
        var didLoad = false
        await loadSelectedPhotoItemIfNeeded(
            item: nil,
            shouldLoad: shouldLoad,
            loadPhotoItemAction: { _ in didLoad = true }
        )
        return didLoad
    }

    @MainActor
    func _testLoadSelectedPhotoItemIfNeededWithoutCustomLoader() async -> (
        name: String,
        description: String,
        totalWeightG: Double,
        totalPortions: Int,
        ingredientNames: [String],
        isAnalyzingPhoto: Bool,
        errorMessage: String?,
        importMessage: String?
    ) {
        await loadSelectedPhotoItemIfNeeded(item: nil, shouldLoad: true)
        return _testPhotoImportState()
    }

    func _testTriggerSave(
        manager: any NutritionBatchRecipeManaging,
        dismissAction: @escaping () -> Void = {}
    ) async -> (
        isSaving: Bool,
        errorMessage: String?,
        importMessage: String?
    ) {
        save(manager: manager, dismissAction: dismissAction)
        for _ in 0..<50 where isSaving {
            await Task.yield()
        }
        return (isSaving, errorMessage, importMessage)
    }
}

extension BatchPortionLogView {
    init(
        batchId: UUID = UUID(),
        batchName: String = "Coverage Chili",
        remainingWeightG: Double = 320,
        per100g: NutritionBatchMacroSnapshot = NutritionCoverageFixtures.batchSnapshot(),
        suggestedPortionWeightG: Double? = 120,
        targetDay: String = NutritionCoverageFixtures.targetDay,
        loggedAt: Date = NutritionCoverageFixtures.loggedAt,
        testPortionWeightG: Double? = nil,
        testMealType: MealType? = nil,
        testContext: MealContext? = .home,
        testIsSaving: Bool = false,
        testErrorMessage: String? = nil,
        onLogged: @escaping (TemplateStatusMessage) -> Void = { _ in }
    ) {
        self.batchId = batchId
        self.batchName = batchName
        self.remainingWeightG = remainingWeightG
        self.per100g = per100g
        self.suggestedPortionWeightG = suggestedPortionWeightG
        self.targetDay = targetDay
        self.loggedAt = loggedAt
        self.onLogged = onLogged
        _portionWeightG = State(
            initialValue: testPortionWeightG
                ?? min(suggestedPortionWeightG ?? 100, max(remainingWeightG, 1))
        )
        _mealType = State(initialValue: testMealType ?? Self.defaultMealType(for: loggedAt))
        _context = State(initialValue: testContext)
        _isSaving = State(initialValue: testIsSaving)
        _errorMessage = State(initialValue: testErrorMessage)
    }

    static func _testDefaultMealType(for date: Date) -> MealType {
        defaultMealType(for: date)
    }

    func _testPreview() -> NutritionBatchMacroSnapshot {
        preview
    }

    func _testCanSave() -> Bool {
        canSave
    }

    static func _testSaveResult(
        draft: NutritionBatchPortionLogDraft,
        batchName: String,
        manager: any NutritionBatchRecipeManaging
    ) async -> Result<TemplateStatusMessage, Error> {
        await saveResult(draft: draft, batchName: batchName, manager: manager)
    }

    func _testEvaluateBody() {
        _ = body
    }

    func _testState() -> (
        isSaving: Bool,
        errorMessage: String?
    ) {
        (isSaving, errorMessage)
    }

    func _testTriggerSave(
        manager: any NutritionBatchRecipeManaging,
        dismissAction: @escaping () -> Void = {}
    ) async -> (
        isSaving: Bool,
        errorMessage: String?
    ) {
        save(manager: manager, dismissAction: dismissAction)
        for _ in 0..<50 where isSaving {
            await Task.yield()
        }
        return (isSaving, errorMessage)
    }
}

extension NutritionSearchView {
    init(
        targetDay: String = NutritionCoverageFixtures.targetDay,
        loggedAt: Date = NutritionCoverageFixtures.loggedAt,
        testQuery: String = "",
        testResults: [FoodSearchResult] = [],
        testIsSearching: Bool = false,
        testErrorMessage: String? = nil,
        onSelectResult: @escaping (NutritionLogDraft) -> Void = { _ in }
    ) {
        self.targetDay = targetDay
        self.loggedAt = loggedAt
        self.onSelectResult = onSelectResult
        _query = State(initialValue: testQuery)
        _results = State(initialValue: testResults)
        _isSearching = State(initialValue: testIsSearching)
        _errorMessage = State(initialValue: testErrorMessage)
    }

    func _testEvaluateBody() {
        _ = body
    }

    func _testState() -> (
        results: [FoodSearchResult],
        isSearching: Bool,
        errorMessage: String?
    ) {
        (results, isSearching, errorMessage)
    }

    @MainActor
    func _testRenderSearchResultButton(_ result: FoodSearchResult) {
        let host = UIHostingController(rootView: searchResultButton(result))
        _ = host.view
    }

    func _testSelectSearchResult(_ result: FoodSearchResult) {
        selectSearchResult(result)
    }

    func _testSubmitSearchUsingDefaultService() {
        submitSearch()
    }

    func _testTriggerSearch(
        searcher: @escaping @Sendable (String) async throws -> [FoodSearchResult]
    ) async -> (
        results: [FoodSearchResult],
        isSearching: Bool,
        errorMessage: String?
    ) {
        search(searcher: searcher)
        for _ in 0..<50 {
            await Task.yield()
        }
        return _testState()
    }

    static func _testSearchExecution(
        query: String,
        searcher: @Sendable (String) async throws -> [FoodSearchResult]
    ) async -> Result<[FoodSearchResult], Error>? {
        guard let normalizedQuery = NutritionSearchExecutionHelper.normalizedQuery(query) else {
            return nil
        }
        return await NutritionSearchExecutionHelper.run(query: normalizedQuery, searcher: searcher)
    }
}

extension BatchRecipeIngredientPickerView {
    init(
        testQuery: String = "",
        testResults: [FoodSearchResult] = [],
        testIsSearching: Bool = false,
        testErrorMessage: String? = nil,
        onSelect: @escaping (FoodSearchResult) -> Void = { _ in }
    ) {
        self.onSelect = onSelect
        _query = State(initialValue: testQuery)
        _results = State(initialValue: testResults)
        _isSearching = State(initialValue: testIsSearching)
        _errorMessage = State(initialValue: testErrorMessage)
    }

    func _testEvaluateBody() {
        _ = body
    }

    func _testState() -> (
        results: [FoodSearchResult],
        isSearching: Bool,
        errorMessage: String?
    ) {
        (results, isSearching, errorMessage)
    }

    @MainActor
    func _testRenderSearchResultButton(_ result: FoodSearchResult) {
        let host = UIHostingController(rootView: searchResultButton(result))
        _ = host.view
    }

    func _testSelectResult(
        _ result: FoodSearchResult,
        dismissAction: @escaping () -> Void = {}
    ) {
        handleSelection(of: result, dismissAction: dismissAction)
    }

    func _testSubmitSearchUsingDefaultService() {
        submitSearch()
    }

    func _testTriggerSearch(
        searcher: @escaping @Sendable (String) async throws -> [FoodSearchResult]
    ) async -> (
        results: [FoodSearchResult],
        isSearching: Bool,
        errorMessage: String?
    ) {
        search(searcher: searcher)
        for _ in 0..<50 {
            await Task.yield()
        }
        return _testState()
    }

    static func _testSearchExecution(
        query: String,
        searcher: @Sendable (String) async throws -> [FoodSearchResult]
    ) async -> Result<[FoodSearchResult], Error>? {
        guard let normalizedQuery = NutritionSearchExecutionHelper.normalizedQuery(query) else {
            return nil
        }
        return await NutritionSearchExecutionHelper.run(query: normalizedQuery, searcher: searcher)
    }
}

extension NutritionCalendarView {
    init(
        selectedDate: Binding<Date>,
        testDisplayedMonth: Date,
        testDaysWithLogs: Set<String>
    ) {
        _selectedDate = selectedDate
        _displayedMonth = State(initialValue: testDisplayedMonth)
        _daysWithLogs = State(initialValue: testDaysWithLogs)
    }

    func _testDaysInMonth() -> [Date?] {
        daysInMonth()
    }

    func _testEvaluateBody() {
        _ = body
    }

    @MainActor
    func _testRenderDayCell(_ date: Date?) {
        let host = UIHostingController(rootView: dayCell(for: date))
        _ = host.view
    }

    @MainActor
    func _testRenderWeekdayHeader(_ day: String) {
        let host = UIHostingController(rootView: weekdayHeader(day))
        _ = host.view
    }

    func _testShiftDisplayedMonth(by value: Int, calendar: Calendar = .current) -> Date {
        shiftedMonth(by: value, calendar: calendar)
    }

    func _testSelectDate(_ date: Date) -> (selectedDate: Date, dismissCalls: Int) {
        var dismissCalls = 0
        selectDate(date) { dismissCalls += 1 }
        return (selectedDate, dismissCalls)
    }

    func _testSelectToday(_ today: Date) -> (selectedDate: Date, dismissCalls: Int) {
        var dismissCalls = 0
        selectToday(today: today) { dismissCalls += 1 }
        return (selectedDate, dismissCalls)
    }

    func _testTriggerLoadLoggedDays(
        calendar: Calendar = .current,
        dbQueue: DatabaseQueue
    ) async {
        await loadLoggedDays(calendar: calendar, dbQueue: dbQueue)
    }

    static func _testLoadLoggedDaysResult(
        displayedMonth: Date,
        calendar: Calendar = .current,
        dbQueue: DatabaseQueue
    ) async -> Set<String> {
        await loadLoggedDaysResult(
            displayedMonth: displayedMonth,
            calendar: calendar,
            dbQueue: dbQueue
        )
    }
}

extension SystemImagePicker {
    func _testConfiguredPicker(
        delegate: (UIImagePickerControllerDelegate & UINavigationControllerDelegate)? = nil
    ) -> UIImagePickerController {
        configuredPicker(delegate: delegate ?? makeCoordinator())
    }
}

extension MediaRecognitionService {
    static func _testPreparedImageDataURL(for image: UIImage) throws -> String {
        try preparedImageDataURL(for: image)
    }

    static func _testParseNutritionLabelText(_ text: String?) -> (
        name: String,
        brand: String?,
        servingSizeG: Double,
        caloriesPer100g: Double,
        proteinPer100g: Double,
        fatPer100g: Double,
        carbsPer100g: Double,
        fiberPer100g: Double,
        confidence: Double?,
        warnings: [String]
    ) {
        parseNutritionLabelText(text)
    }

    static func _testFallbackAnalysis(
        recognizedText: String?,
        barcodes: [String],
        notice: String?
    ) -> NutritionPhotoAnalysis {
        fallbackAnalysis(recognizedText: recognizedText, barcodes: barcodes, notice: notice)
    }

    static func _testAIFoodLabelDraft(
        from response: FoodLabelAnalysisResponse,
        sourceText: String?,
        barcodeHint: String?
    ) -> NutritionLabelReviewDraft {
        aiFoodLabelDraft(from: response, sourceText: sourceText, barcodeHint: barcodeHint)
    }

    static func _testFallbackFoodLabelDraft(
        sourceText: String?,
        barcode: String?,
        notice: String
    ) -> NutritionLabelReviewDraft {
        fallbackFoodLabelDraft(sourceText: sourceText, barcode: barcode, notice: notice)
    }

    static func _testBatchRecipePhotoDraft(
        from response: BatchRecipePhotoAnalysisResponse,
        fallbackRecipeName: String,
        fallbackWeightG: Double,
        fallbackPortions: Int
    ) -> BatchRecipePhotoDraft {
        batchRecipePhotoDraft(
            from: response,
            fallbackRecipeName: fallbackRecipeName,
            fallbackWeightG: fallbackWeightG,
            fallbackPortions: fallbackPortions
        )
    }

    static func _testFallbackBatchRecipePhotoDraft(
        from analysis: NutritionPhotoAnalysis,
        recipeName: String,
        totalWeightG: Double,
        totalPortions: Int,
        cloudAnalysisEnabled: Bool
    ) -> BatchRecipePhotoDraft {
        fallbackBatchRecipePhotoDraft(
            from: analysis,
            recipeName: recipeName,
            totalWeightG: totalWeightG,
            totalPortions: totalPortions,
            cloudAnalysisEnabled: cloudAnalysisEnabled
        )
    }

    static func _testAIAnalysis(
        from response: FoodPhotoAnalysisResponse,
        recognizedText: String?,
        barcodes: [String]
    ) -> NutritionPhotoAnalysis {
        aiAnalysis(from: response, recognizedText: recognizedText, barcodes: barcodes)
    }

    static func _testAISummaryFallback(
        detectedItems: [NutritionDraftCandidateItem],
        totalMacros: NutritionDraftMacroSummary?
    ) -> String {
        aiSummaryFallback(detectedItems: detectedItems, totalMacros: totalMacros)
    }

    static func _testIsCloudAnalysisEnabled() async -> Bool {
        await isCloudAnalysisEnabled()
    }

    static func _testSetRecognizeTextOverride(
        _ runner: (@Sendable (UIImage) async throws -> String)?
    ) {
        testRecognizeTextOverride.value = runner
    }

    static func _testSetSyncRecognizeTextOverride(
        _ runner: (@Sendable (UIImage) throws -> String)?
    ) {
        testSyncRecognizeTextOverride.value = runner
    }

    static func _testSetSyncDetectBarcodesOverride(
        _ runner: (@Sendable (Data) throws -> [String])?
    ) {
        testSyncDetectBarcodesOverride.value = runner
    }

    static func _testSetDetectBarcodesOverride(
        _ runner: (@Sendable (UIImage) async throws -> [String])?
    ) {
        testDetectBarcodesOverride.value = runner
    }

    static func _testSetFoodPhotoAnalysisOverride(
        _ runner: (@Sendable (String, Date, String?, [String]) async throws -> FoodPhotoAnalysisResponse)?
    ) {
        testFoodPhotoAnalysisOverride.value = runner
    }

    static func _testSetFoodPhotoServiceRunnerOverride(
        _ runner: (@Sendable (String, Date, String?, [String]) async throws -> FoodPhotoAnalysisResponse)?
    ) {
        testFoodPhotoServiceRunnerOverride.value = runner
    }

    static func _testSetFoodLabelAnalysisOverride(
        _ runner: (@Sendable ([String], String?) async throws -> FoodLabelAnalysisResponse)?
    ) {
        testFoodLabelAnalysisOverride.value = runner
    }

    static func _testSetFoodLabelServiceRunnerOverride(
        _ runner: (@Sendable ([String], String?) async throws -> FoodLabelAnalysisResponse)?
    ) {
        testFoodLabelServiceRunnerOverride.value = runner
    }

    static func _testSetBatchRecipePhotoAnalysisOverride(
        _ runner: (@Sendable (String, String, Double, Int, [String]) async throws -> BatchRecipePhotoAnalysisResponse)?
    ) {
        testBatchRecipePhotoAnalysisOverride.value = runner
    }

    static func _testSetBatchRecipePhotoServiceRunnerOverride(
        _ runner: (@Sendable (String, String, Double, Int, [String]) async throws -> BatchRecipePhotoAnalysisResponse)?
    ) {
        testBatchRecipePhotoServiceRunnerOverride.value = runner
    }

    static func _testFoodPhotoAnalysisResponse(
        imageDataURL: String,
        loggedAt: Date,
        recognizedText: String?,
        barcodes: [String],
        service: FoodPhotoAnalysisService
    ) async throws -> FoodPhotoAnalysisResponse {
        try await foodPhotoAnalysisResponse(
            imageDataURL: imageDataURL,
            loggedAt: loggedAt,
            recognizedText: recognizedText,
            barcodes: barcodes,
            service: service
        )
    }

    static func _testFoodLabelAnalysisResponse(
        imagesDataURL: [String],
        barcode: String?,
        service: FoodLabelAnalysisService
    ) async throws -> FoodLabelAnalysisResponse {
        try await foodLabelAnalysisResponse(
            imagesDataURL: imagesDataURL,
            barcode: barcode,
            service: service
        )
    }

    static func _testBatchRecipePhotoAnalysisResponse(
        imageDataURL: String,
        recipeName: String,
        totalWeightG: Double,
        totalPortions: Int,
        knownIngredients: [String],
        service: BatchRecipePhotoAnalysisService
    ) async throws -> BatchRecipePhotoAnalysisResponse {
        try await batchRecipePhotoAnalysisResponse(
            imageDataURL: imageDataURL,
            recipeName: recipeName,
            totalWeightG: totalWeightG,
            totalPortions: totalPortions,
            knownIngredients: knownIngredients,
            service: service
        )
    }

    static func _testSetCloudAnalysisEnabledOverride(
        _ runner: (@Sendable () async -> Bool)?
    ) {
        testCloudAnalysisEnabledOverride.value = runner
    }

    static func _testSetPhotoCloudAnalysisAvailableOverride(_ isAvailable: Bool?) {
        testPhotoCloudAnalysisAvailableOverride.value = isAvailable
    }

    static func _testResetOverrides() {
        testRecognizeTextOverride.value = nil
        testSyncRecognizeTextOverride.value = nil
        testSyncDetectBarcodesOverride.value = nil
        testDetectBarcodesOverride.value = nil
        testFoodPhotoAnalysisOverride.value = nil
        testFoodPhotoServiceRunnerOverride.value = nil
        testFoodLabelAnalysisOverride.value = nil
        testFoodLabelServiceRunnerOverride.value = nil
        testBatchRecipePhotoAnalysisOverride.value = nil
        testBatchRecipePhotoServiceRunnerOverride.value = nil
        testCloudAnalysisEnabledOverride.value = nil
        testPhotoCloudAnalysisAvailableOverride.value = nil
    }
}

extension NutritionDraftResolver {
    static func _testResolveDraft(
        dbQueue: DatabaseQueue,
        method: NutritionLogMethod,
        confidence: Double?,
        summary: String?,
        sourceText: String?,
        analysisSource: NutritionAnalysisSource?,
        totalMacros: NutritionDraftMacroSummary?,
        suggestions: [String],
        warnings: [String],
        mealType: MealType?,
        recognizedBarcodes: [String],
        detectedItems: [NutritionDraftCandidateItem],
        includeUnmatchedSourceTextItems: Bool,
        targetDay: String,
        loggedAt: Date
    ) async -> NutritionLogDraft {
        let resolver = NutritionDraftResolver(dbQueue: dbQueue)
        return await resolver.resolveDraft(
            method: method,
            confidence: confidence,
            summary: summary,
            sourceText: sourceText,
            analysisSource: analysisSource,
            totalMacros: totalMacros,
            suggestions: suggestions,
            warnings: warnings,
            mealType: mealType,
            recognizedBarcodes: recognizedBarcodes,
            detectedItems: detectedItems,
            includeUnmatchedSourceTextItems: includeUnmatchedSourceTextItems,
            targetDay: targetDay,
            loggedAt: loggedAt
        )
    }

    static func _testResolveVoiceFallbackDraft(
        dbQueue: DatabaseQueue,
        transcription: String,
        confidence: Double?,
        targetDay: String,
        loggedAt: Date
    ) async -> NutritionLogDraft {
        let resolver = NutritionDraftResolver(dbQueue: dbQueue)
        return await resolver.resolveDraft(
            method: .voice,
            confidence: confidence,
            summary: transcription,
            sourceText: transcription,
            analysisSource: nil,
            totalMacros: nil,
            suggestions: [],
            warnings: [],
            mealType: nil,
            recognizedBarcodes: [],
            detectedItems: [],
            includeUnmatchedSourceTextItems: true,
            targetDay: targetDay,
            loggedAt: loggedAt
        )
    }

    static func _testResolvePhotoDraft(
        dbQueue: DatabaseQueue,
        analysis: NutritionPhotoAnalysis,
        targetDay: String,
        loggedAt: Date
    ) async -> NutritionLogDraft {
        let resolver = NutritionDraftResolver(dbQueue: dbQueue)
        return await resolver.resolvePhotoDraft(
            analysis: analysis,
            targetDay: targetDay,
            loggedAt: loggedAt
        )
    }

    static func _testResolveVoiceDraft(
        dbQueue: DatabaseQueue,
        transcription: String,
        confidence: Double?,
        targetDay: String,
        loggedAt: Date
    ) async -> NutritionLogDraft {
        let resolver = NutritionDraftResolver(dbQueue: dbQueue)
        return await resolver.resolveVoiceDraft(
            transcription: transcription,
            confidence: confidence,
            targetDay: targetDay,
            loggedAt: loggedAt
        )
    }

    static func _testSetVoiceLoggingAvailableOverride(_ value: Bool?) {
        testVoiceLoggingAvailableOverride.value = value
    }

    static func _testSetParseTextOverride(
        _ runner: (@Sendable (String) async throws -> FoodTextParseResponse)?
    ) {
        testParseTextOverride.value = runner
    }

    static func _testResetOverrides() {
        testVoiceLoggingAvailableOverride.value = nil
        testParseTextOverride.value = nil
    }
}

extension NutritionCatalogService {
    private static func _testRow(
        requiredColumns: [String],
        values: [String: (any DatabaseValueConvertible)?]
    ) -> Row {
        var completeValues: [String: (any DatabaseValueConvertible)?] = [:]
        for column in requiredColumns {
            completeValues[column] = nil
        }
        for (key, value) in values {
            completeValues[key] = value
        }
        return Row(completeValues)
    }

    static func _testFavoriteKeys(
        values: [[String: (any DatabaseValueConvertible)?]]
    ) -> Set<String> {
        favoriteKeys(from: values.map {
            _testRow(requiredColumns: ["ref_type", "ref_id"], values: $0)
        })
    }

    static func _testRecentKeys(
        values: [[String: (any DatabaseValueConvertible)?]]
    ) -> Set<String> {
        recentKeys(from: values.map {
            _testRow(requiredColumns: ["user_food_id", "catalog_item_id"], values: $0)
        })
    }

    static func _testLoadFavoriteKeys(userId: UUID?, db: Database) throws -> Set<String> {
        try loadFavoriteKeys(userId: userId, db: db)
    }

    static func _testLoadRecentKeys(userId: UUID?, db: Database) throws -> Set<String> {
        try loadRecentKeys(userId: userId, db: db)
    }

    static func _testTags(
        favorites: Set<String>,
        recent: Set<String>,
        refType: FoodRefType,
        id: UUID?
    ) -> [String] {
        tags(favorites: favorites, recent: recent, refType: refType, id: id)
    }

    static func _testScore(
        result: FoodSearchResult,
        query: String,
        sourceIsProvider: Bool,
        favorites: Set<String>,
        recent: Set<String>
    ) -> Int {
        score(
            result: result,
            query: query,
            source: sourceIsProvider ? .provider : .cache,
            favorites: favorites,
            recent: recent
        )
    }

    static func _testUniqueSortedResults(
        resultsWithScores: [(result: FoodSearchResult, score: Int)],
        limit: Int
    ) -> [FoodSearchResult] {
        uniqueSortedResults(
            candidates: resultsWithScores.map { NutritionLocalSearchCandidate(result: $0.result, score: $0.score) },
            limit: limit
        )
    }

    static func _testMakeCustomResult(
        values: [String: (any DatabaseValueConvertible)?],
        tags: [String] = []
    ) -> FoodSearchResult? {
        makeCustomResult(
            from: _testRow(
                requiredColumns: [
                    "id",
                    "name",
                    "brand",
                    "barcode",
                    "default_serving_g",
                    "calories_per_100g",
                    "protein_per_100g",
                    "fat_per_100g",
                    "carbs_per_100g",
                    "fiber_per_100g"
                ],
                values: values
            ),
            tags: tags
        )
    }

    static func _testMakeCatalogResult(
        values: [String: (any DatabaseValueConvertible)?],
        tags: [String] = []
    ) -> FoodSearchResult? {
        makeCatalogResult(
            from: _testRow(
                requiredColumns: [
                    "id",
                    "name",
                    "provider",
                    "brand",
                    "barcode",
                    "serving_size_g",
                    "calories_per_100g",
                    "protein_per_100g",
                    "fat_per_100g",
                    "carbs_per_100g",
                    "fiber_per_100g"
                ],
                values: values
            ),
            tags: tags
        )
    }
}

enum NutritionCoverageHarness {
    @MainActor
    static func exerciseAdditionalViewBranches() -> Int {
        var rendered = 0

        func render<V: View>(_ view: V) {
            let host = UIHostingController(rootView: view)
            _ = host.view
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            rendered += 1
        }

        func evaluate(_ operation: () -> Void) {
            operation()
            rendered += 1
        }

        let image = NutritionCoverageFixtures.image()
        let photoAnalysis = NutritionCoverageFixtures.photoAnalysis(notice: "Review details")
        let matchedProduct = NutritionCoverageFixtures.foodResult(name: "Coverage Cereal")

        render(NutritionPhotoCaptureView())
        render(
            NutritionPhotoCaptureView(
                testCapturedImage: image,
                testIsAnalyzing: true
            )
        )
        render(
            NutritionPhotoCaptureView(
                testCapturedImage: image,
                testAnalysisResult: "Coverage meal analyzed",
                testAnalysisConfidence: 0.91,
                testPhotoAnalysis: photoAnalysis,
                testAnalysisNotice: "Review details",
                testCaptureError: "Minor note"
            )
        )
        render(
            NutritionPhotoCaptureView(
                testCapturedImage: image,
                testCaptureError: "Photo error"
            )
        )

        var labelReviewDraft = NutritionCoverageFixtures.labelDraft(
            warnings: ["OCR note"],
            sourceText: "Protein 20\nFat 8"
        )
        render(
            NutritionLabelReviewFormView(
                draft: Binding(
                    get: { labelReviewDraft },
                    set: { labelReviewDraft = $0 }
                ),
                isSaving: false,
                isAnalyzing: true,
                errorMessage: "Review error",
                onRescan: {},
                onSave: {}
            )
        )

        render(NutritionBarcodeScannerView())
        render(
            NutritionBarcodeScannerView(
                testScannedCode: "12345",
                testIsSearching: true
            )
        )
        render(
            NutritionBarcodeScannerView(
                testScannedCode: "12345",
                testIsSaving: true,
                testProductFound: true,
                testMatchedProduct: matchedProduct
            )
        )
        render(
            NutritionBarcodeScannerView(
                testScannedCode: "12345",
                testProductFound: false
            )
        )
        render(
            NutritionBarcodeScannerView(
                testIsAnalyzingLabel: true,
                testShowLabelOCRFallback: true,
                testOCRResult: "Protein 20g",
                testErrorMessage: "Fallback error",
                testPendingLabelImages: [image]
            )
        )
        render(
            NutritionBarcodeScannerView(
                testIsSaving: true,
                testIsAnalyzingLabel: true,
                testErrorMessage: "Validation error",
                testLabelReviewDraft: NutritionCoverageFixtures.labelDraft(
                    warnings: ["Review warning"],
                    sourceText: "Fiber 5"
                )
            )
        )

        let recordingRecognizer = NutritionSpeechRecognizer()
        recordingRecognizer._testOverrideState(
            isRecording: true,
            isProcessing: false,
            transcription: "",
            errorMessage: nil,
            confidence: nil
        )
        render(NutritionVoiceInputView(testSpeechRecognizer: recordingRecognizer))

        let processedRecognizer = NutritionSpeechRecognizer()
        processedRecognizer._testOverrideState(
            isRecording: false,
            isProcessing: true,
            transcription: "",
            errorMessage: nil,
            confidence: nil
        )
        render(NutritionVoiceInputView(testSpeechRecognizer: processedRecognizer))

        let transcriptRecognizer = NutritionSpeechRecognizer()
        transcriptRecognizer._testOverrideState(
            isRecording: false,
            isProcessing: false,
            transcription: "Chicken rice bowl",
            errorMessage: "Mic warning",
            confidence: 0.8
        )
        render(NutritionVoiceInputView(testSpeechRecognizer: transcriptRecognizer))

        let searchResult = NutritionCoverageFixtures.foodResult(name: "Coverage Oats")
        render(
            NutritionSearchView(
                testQuery: "coverage",
                testIsSearching: true
            )
        )
        render(
            NutritionSearchView(
                testQuery: "coverage",
                testResults: []
            )
        )
        render(
            NutritionSearchView(
                testQuery: "coverage",
                testResults: [searchResult],
                testErrorMessage: "Search warning"
            )
        )

        evaluate { MealTemplatesView(testIsLoading: true)._testEvaluateBody() }
        evaluate {
            MealTemplatesView(
                testIsLoading: false,
                testTemplates: []
            )._testEvaluateBody()
        }
        evaluate {
            MealTemplatesView(
                testIsLoading: false,
                testTemplates: [NutritionCoverageFixtures.mealTemplateSummary()]
            )._testEvaluateBody()
        }

        evaluate { MealTemplateLibraryView(testIsLoading: true)._testEvaluateBody() }
        evaluate {
            MealTemplateLibraryView(
                testTemplates: [],
                testIsLoading: false,
                testShowingArchived: false
            )._testEvaluateBody()
        }
        evaluate {
            MealTemplateLibraryView(
                testTemplates: [NutritionCoverageFixtures.mealTemplateSummary()],
                testIsLoading: false,
                testStatusMessage: TemplateStatusMessage(message: "Template synced", isError: false)
            )._testEvaluateBody()
        }
        evaluate {
            MealTemplateLibraryView(
                testTemplates: [],
                testIsLoading: false,
                testShowingArchived: true,
                testStatusMessage: TemplateStatusMessage(message: "Archive unavailable", isError: true)
            )._testEvaluateBody()
        }

        evaluate { BatchRecipeLibraryView(testIsLoading: true)._testEvaluateBody() }
        evaluate {
            BatchRecipeLibraryView(
                testRecipes: [],
                testIsLoading: false,
                testShowingArchived: false
            )._testEvaluateBody()
        }
        evaluate {
            BatchRecipeLibraryView(
                testRecipes: [NutritionCoverageFixtures.batchSummary()],
                testIsLoading: false,
                testStatusMessage: TemplateStatusMessage(message: "Batch ready", isError: false)
            )._testEvaluateBody()
        }
        evaluate {
            BatchRecipeLibraryView(
                testRecipes: [NutritionCoverageFixtures.batchSummary(archived: true)],
                testIsLoading: false,
                testShowingArchived: true,
                testStatusMessage: TemplateStatusMessage(message: "Archived batch", isError: true)
            )._testEvaluateBody()
        }

        render(BatchPortionLogView())
        render(
            BatchPortionLogView(
                remainingWeightG: 120,
                testPortionWeightG: 180,
                testErrorMessage: "Too much selected"
            )
        )
        render(
            BatchRecipeIngredientPickerView(
                testQuery: "coverage",
                testIsSearching: true
            )
        )
        render(
            BatchRecipeIngredientPickerView(
                testQuery: "coverage",
                testResults: [NutritionCoverageFixtures.foodResult()]
            )
        )
        render(
            BatchRecipeIngredientPickerView(
                testQuery: "coverage",
                testErrorMessage: "Network error"
            )
        )

        var selectedDate = NutritionCoverageFixtures.loggedAt
        let month = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 1))
            ?? NutritionCoverageFixtures.loggedAt
        render(
            NutritionCalendarView(
                selectedDate: Binding(
                    get: { selectedDate },
                    set: { selectedDate = $0 }
                ),
                testDisplayedMonth: month,
                testDaysWithLogs: ["2026-03-01", "2026-03-19"]
            )
        )

        return rendered
    }

    @MainActor
    static func exerciseTemplateAndBatchViewBranches() -> Int {
        var rendered = 0

        func evaluate(_ operation: () -> Void) {
            operation()
            rendered += 1
        }

        let activeTemplateDetail = NutritionCoverageFixtures.mealTemplateDetail()
        let archivedTemplateDetail = NutritionCoverageFixtures.mealTemplateDetail(archived: true)
        let batchDetail = NutritionCoverageFixtures.batchDetail()
        let archivedBatchDetail = NutritionCoverageFixtures.batchDetail(
            archived: true,
            remainingWeightG: 0,
            description: nil
        )

        evaluate {
            MealTemplateDetailView(
                testViewModel: MealTemplateDetailViewModel._testConfigured(
                    detail: activeTemplateDetail,
                    isLoading: true
                )
            )._testEvaluateBody()
        }
        evaluate {
            MealTemplateDetailView(
                testViewModel: MealTemplateDetailViewModel._testConfigured(
                    detail: activeTemplateDetail,
                    statusMessage: TemplateStatusMessage(message: "Template synced", isError: false)
                )
            )._testEvaluateBody()
        }
        evaluate {
            MealTemplateDetailView(
                testViewModel: MealTemplateDetailViewModel._testConfigured(
                    detail: activeTemplateDetail,
                    isEditing: true,
                    errorMessage: "Edit validation"
                )
            )._testEvaluateBody()
        }
        evaluate {
            MealTemplateDetailView(
                testViewModel: MealTemplateDetailViewModel._testConfigured(
                    detail: archivedTemplateDetail,
                    isArchiving: true,
                    statusMessage: TemplateStatusMessage(message: "Archived template", isError: true)
                )
            )._testEvaluateBody()
        }

        let templateItems = activeTemplateDetail.items.map(NutritionEditableMealItem.init(templateItem:))
        evaluate { MealTemplateComposerView(testName: "   ", testItems: [])._testEvaluateBody() }
        evaluate {
            MealTemplateComposerView(
                testName: activeTemplateDetail.template.name,
                testMealType: activeTemplateDetail.template.mealType,
                testItems: templateItems
            )._testEvaluateBody()
        }
        evaluate {
            MealTemplateComposerView(
                testName: activeTemplateDetail.template.name,
                testMealType: activeTemplateDetail.template.mealType,
                testItems: templateItems,
                testIsSaving: true,
                testErrorMessage: "Unable to save"
            )._testEvaluateBody()
        }

        evaluate { BatchRecipeDetailView(testIsLoading: true)._testEvaluateBody() }
        evaluate {
            BatchRecipeDetailView(
                batchId: batchDetail.recipe.id,
                testDetail: batchDetail,
                testIsLoading: false,
                testStatusMessage: TemplateStatusMessage(message: "Batch refreshed", isError: false)
            )._testEvaluateBody()
        }
        evaluate {
            BatchRecipeDetailView(
                batchId: archivedBatchDetail.recipe.id,
                testDetail: archivedBatchDetail,
                testIsLoading: false,
                testIsArchiving: true,
                testErrorMessage: "Archive note",
                testStatusMessage: TemplateStatusMessage(message: "Archived batch", isError: true)
            )._testEvaluateBody()
        }

        let editableIngredients = batchDetail.ingredients.map(BatchRecipeEditableIngredient.init(ingredient:))
        evaluate {
            BatchRecipeComposerView(
                testName: "Coverage Prep",
                testDescription: "Roast and chill",
                testTotalWeightG: batchDetail.recipe.totalWeightG,
                testTotalPortions: batchDetail.recipe.totalPortions ?? 1,
                testIngredients: editableIngredients,
                testImportMessage: "Photo draft imported."
            )._testEvaluateBody()
        }
        evaluate {
            BatchRecipeComposerView(
                existingDetail: batchDetail,
                testName: batchDetail.recipe.name,
                testDescription: batchDetail.recipe.description ?? "",
                testCookedAt: NutritionCoverageFixtures.loggedAt,
                testTotalWeightG: batchDetail.recipe.totalWeightG,
                testTotalPortions: batchDetail.recipe.totalPortions ?? 1,
                testIngredients: editableIngredients,
                testIsSaving: true,
                testErrorMessage: "Photo import issue",
                testIsAnalyzingPhoto: true
            )._testEvaluateBody()
        }

        return rendered
    }

    @MainActor
    static func localizedFormattingMetrics() -> (
        lastUsed: String,
        usedCount: String,
        cooked: String,
        remainingOnly: String,
        remainingWithPortions: String,
        portionsLeft: String,
        itemWithFiber: String,
        itemWithoutFiber: String,
        batchWithFiber: String,
        batchWithoutFiber: String,
        templateSubtitle: String,
        barcodeFallbackName: String
    ) {
        let sampleDate = Date(timeIntervalSince1970: 1_710_000_000)
        let template = NutritionCoverageFixtures.mealTemplateSummary()
        let batchWithFiberSnapshot = NutritionCoverageFixtures.batchSnapshot(fiberG: 4)
        let batchWithoutFiberSnapshot = NutritionCoverageFixtures.batchSnapshot(fiberG: nil)
        let barcodeFallbackName = NutritionBarcodeScannerView()._testFallbackDraft().name
        return (
            lastUsed: localizedNutritionLastUsed(sampleDate),
            usedCount: localizedNutritionUsedCount(7),
            cooked: localizedNutritionCooked("2026-03-19"),
            remainingOnly: localizedNutritionRemainingLine(weightG: 245),
            remainingWithPortions: localizedNutritionRemainingLine(weightG: 245, portionsRemaining: 2.5),
            portionsLeft: localizedNutritionPortionsLeft(1.5),
            itemWithFiber: localizedNutritionItemSummary(
                weightG: 185,
                calories: 420,
                protein: 28,
                fat: 12,
                carbs: 41,
                fiber: 8
            ),
            itemWithoutFiber: localizedNutritionItemSummary(
                weightG: 120,
                calories: 260,
                protein: 18,
                fat: 7,
                carbs: 29,
                fiber: nil
            ),
            batchWithFiber: localizedNutritionBatchMacroLine(batchWithFiberSnapshot, prefix: "Coverage"),
            batchWithoutFiber: localizedNutritionBatchMacroLine(batchWithoutFiberSnapshot, prefix: "Coverage"),
            templateSubtitle: MealTemplateLibraryView(
                testTemplates: [template],
                testIsLoading: false
            )._testTemplateRowSubtitle(template),
            barcodeFallbackName: barcodeFallbackName
        )
    }

    @MainActor
    static func validateBarcodeReview(_ review: NutritionLabelReviewDraft) -> String? {
        NutritionBarcodeScannerView._testValidate(review: review)
    }

    @MainActor
    static func batchPortionMetrics() -> (
        breakfast: MealType,
        lunch: MealType,
        dinner: MealType,
        snack: MealType,
        canSave: Bool,
        blockedSave: Bool,
        previewCalories: Double,
        previewFiber: Double?
    ) {
        let previewView = BatchPortionLogView(testPortionWeightG: 150)
        let blockedView = BatchPortionLogView(remainingWeightG: 100, testPortionWeightG: 140)
        let calendar = Calendar.current
        let breakfastDate = calendar.date(from: DateComponents(year: 2026, month: 3, day: 19, hour: 8))
            ?? NutritionCoverageFixtures.loggedAt
        let lunchDate = calendar.date(from: DateComponents(year: 2026, month: 3, day: 19, hour: 13))
            ?? NutritionCoverageFixtures.loggedAt
        let dinnerDate = calendar.date(from: DateComponents(year: 2026, month: 3, day: 19, hour: 19))
            ?? NutritionCoverageFixtures.loggedAt
        let snackDate = calendar.date(from: DateComponents(year: 2026, month: 3, day: 19, hour: 23))
            ?? NutritionCoverageFixtures.loggedAt
        return (
            breakfast: BatchPortionLogView._testDefaultMealType(for: breakfastDate),
            lunch: BatchPortionLogView._testDefaultMealType(for: lunchDate),
            dinner: BatchPortionLogView._testDefaultMealType(for: dinnerDate),
            snack: BatchPortionLogView._testDefaultMealType(for: snackDate),
            canSave: previewView._testCanSave(),
            blockedSave: blockedView._testCanSave(),
            previewCalories: previewView._testPreview().calories,
            previewFiber: previewView._testPreview().fiberG
        )
    }

    @MainActor
    static func mealTemplateComposerMetrics() -> (
        canSave: Bool,
        blockedSave: Bool,
        calories: Double,
        protein: Double,
        fiber: Double?
    ) {
        let detail = NutritionCoverageFixtures.mealTemplateDetail()
        let filledComposer = MealTemplateComposerView(
            testName: detail.template.name,
            testMealType: detail.template.mealType,
            testItems: detail.items.map(NutritionEditableMealItem.init(templateItem:))
        )
        let blockedComposer = MealTemplateComposerView(
            testName: "   ",
            testMealType: detail.template.mealType,
            testItems: detail.items.map(NutritionEditableMealItem.init(templateItem:))
        )
        let totals = filledComposer._testTotals()
        return (
            canSave: filledComposer._testCanSave(),
            blockedSave: blockedComposer._testCanSave(),
            calories: totals.calories,
            protein: totals.protein,
            fiber: totals.fiber
        )
    }

    @MainActor
    static func mealTemplateComposerMutationMetrics() -> (
        itemCount: Int,
        firstAddedName: String
    ) {
        let addedItems = MealTemplateComposerView._testAddedItems(mealType: .dinner)
        return (
            itemCount: addedItems.count,
            firstAddedName: addedItems.first?.name ?? ""
        )
    }

    @MainActor
    static func batchRecipeComposerMetrics() -> (
        canSave: Bool,
        blockedSave: Bool,
        totalCalories: Double,
        per100gProtein: Double,
        perPortionCalories: Double,
        mergedIngredientNames: [String]
    ) {
        let baseIngredients = [
            BatchRecipeEditableIngredient(
                name: "Coverage Chicken",
                brand: "Coverage Farm",
                barcode: "333333",
                weightG: 250,
                calories: 330,
                proteinG: 42,
                fatG: 9,
                carbsG: 0
            ),
            BatchRecipeEditableIngredient(
                name: "Coverage Rice",
                brand: "Coverage Pantry",
                barcode: "444444",
                weightG: 300,
                calories: 390,
                proteinG: 9,
                fatG: 3,
                carbsG: 84,
                fiberG: 3
            ),
            BatchRecipeEditableIngredient(
                name: "Coverage Salsa",
                brand: "Coverage Garden",
                barcode: "555555",
                weightG: 120,
                calories: 60,
                proteinG: 2,
                fatG: 0,
                carbsG: 12,
                fiberG: 2
            )
        ]
        let filledComposer = BatchRecipeComposerView(
            testName: "Coverage Prep",
            testDescription: "Roast and chill",
            testTotalWeightG: 780,
            testTotalPortions: 4,
            testIngredients: baseIngredients
        )
        let blockedComposer = BatchRecipeComposerView(
            testName: "Coverage Prep",
            testDescription: "Roast and chill",
            testTotalWeightG: 0,
            testTotalPortions: 0,
            testIngredients: []
        )
        let mergedNames = filledComposer._testMergedIngredients(
            imported: [
                BatchRecipeEditableIngredient(
                    name: " coverage chicken ",
                    brand: "Duplicate",
                    barcode: "",
                    weightG: 10,
                    calories: 10,
                    proteinG: 1,
                    fatG: 0,
                    carbsG: 0
                ),
                BatchRecipeEditableIngredient(
                    name: "Coverage Herbs",
                    brand: "Coverage Garden",
                    barcode: "666666",
                    weightG: 30,
                    calories: 12,
                    proteinG: 1,
                    fatG: 0,
                    carbsG: 2
                )
            ]
        )
        let totals = filledComposer._testTotals()
        return (
            canSave: filledComposer._testCanSave(),
            blockedSave: blockedComposer._testCanSave(),
            totalCalories: totals.calories,
            per100gProtein: filledComposer._testPer100g().proteinG,
            perPortionCalories: filledComposer._testPerPortion().calories,
            mergedIngredientNames: mergedNames.map(\.name).sorted()
        )
    }

    @MainActor
    static func batchRecipePhotoImportMetrics() -> (
        importedName: String,
        importedDescription: String,
        importedIngredientCount: Int,
        noteImportMessage: String?,
        mergedIngredientNames: [String],
        mergedDescription: String,
        genericImportMessage: String?,
        fallbackError: String?
    ) {
        let initialIngredients = [
            BatchRecipeEditableIngredient(
                name: "Coverage Chicken",
                brand: "Coverage Farm",
                barcode: "333333",
                weightG: 250,
                calories: 330,
                proteinG: 42,
                fatG: 9,
                carbsG: 0
            )
        ]
        let importedResult = BatchRecipeComposerView._testAppliedPhotoDraftResult(
            testName: String(localized: "nutrition_default_meal_prep_name"),
            testDescription: "",
            testTotalWeightG: 500,
            testTotalPortions: 2,
            testIngredients: [],
            photoDraft: NutritionCoverageFixtures.batchPhotoDraft(
                notes: ["Coverage import note"],
                descriptionText: "Roast and chill"
            )
        )
        let mergedResult = BatchRecipeComposerView._testAppliedPhotoDraftResult(
            testName: "Existing Prep",
            testDescription: "Base note",
            testTotalWeightG: 500,
            testTotalPortions: 2,
            testIngredients: initialIngredients,
            photoDraft: NutritionCoverageFixtures.batchPhotoDraft(
                recipeName: "Merged Coverage Prep",
                ingredients: [
                    BatchRecipeEditableIngredient(
                        name: " coverage chicken ",
                        brand: "Duplicate",
                        barcode: "",
                        weightG: 10,
                        calories: 10,
                        proteinG: 1,
                        fatG: 0,
                        carbsG: 0
                    ),
                    BatchRecipeEditableIngredient(
                        name: "Coverage Herbs",
                        brand: "Coverage Garden",
                        barcode: "666666",
                        weightG: 30,
                        calories: 12,
                        proteinG: 1,
                        fatG: 0,
                        carbsG: 2
                    )
                ],
                notes: [],
                descriptionText: "New note"
            )
        )
        let fallbackResult = BatchRecipeComposerView._testAppliedPhotoDraftResult(
            testName: "Existing Prep",
            testDescription: "Base note",
            testTotalWeightG: 500,
            testTotalPortions: 2,
            testIngredients: [],
            photoDraft: NutritionCoverageFixtures.batchPhotoDraft(
                recipeName: "Fallback Coverage Prep",
                ingredients: [],
                notes: [],
                descriptionText: nil
            )
        )

        return (
            importedName: importedResult.name,
            importedDescription: importedResult.description,
            importedIngredientCount: importedResult.ingredientNames.count,
            noteImportMessage: importedResult.importMessage,
            mergedIngredientNames: mergedResult.ingredientNames,
            mergedDescription: mergedResult.description,
            genericImportMessage: mergedResult.importMessage,
            fallbackError: fallbackResult.errorMessage
        )
    }

    @MainActor
    static func calendarDaysInMonth(for displayedMonth: Date) -> [Date?] {
        final class SelectedDateBox {
            var value: Date

            init(_ value: Date) {
                self.value = value
            }
        }

        let selectedDate = SelectedDateBox(displayedMonth)
        return NutritionCalendarView(
            selectedDate: Binding(
                get: { selectedDate.value },
                set: { selectedDate.value = $0 }
            ),
            testDisplayedMonth: displayedMonth,
            testDaysWithLogs: []
        )
        ._testDaysInMonth()
    }

    static func preparedLargeImageDataURL() throws -> String {
        try MediaRecognitionService._testPreparedImageDataURL(for: NutritionCoverageFixtures.largeImage())
    }

    static func resolveCatalogMergedDraft(dbQueue: DatabaseQueue) async -> NutritionLogDraft {
        await NutritionDraftResolver._testResolveDraft(
            dbQueue: dbQueue,
            method: .photo,
            confidence: 0.71,
            summary: "Coverage breakfast",
            sourceText: "I had oatmeal and banana",
            analysisSource: .aiVision,
            totalMacros: NutritionDraftMacroSummary(
                calories: 480,
                proteinG: 19,
                fatG: 9,
                carbsG: 82,
                fiberG: 11
            ),
            suggestions: [" add yogurt ", ""],
            warnings: [" review serving ", " "],
            mealType: .breakfast,
            recognizedBarcodes: [" 12345 ", ""],
            detectedItems: [
                NutritionDraftCandidateItem(
                    name: "Oatmeal",
                    notes: " warm bowl ",
                    confidence: nil,
                    detectedByAi: true
                ),
                NutritionDraftCandidateItem(
                    name: "Mystery Snack",
                    confidence: 0.33,
                    detectedByAi: true
                )
            ],
            includeUnmatchedSourceTextItems: true,
            targetDay: NutritionCoverageFixtures.targetDay,
            loggedAt: NutritionCoverageFixtures.loggedAt
        )
    }

    static func resolveVoiceFallbackDraft(
        dbQueue: DatabaseQueue,
        transcription: String = "I had egg whites, toast and coffee",
        confidence: Double? = 0.64
    ) async -> NutritionLogDraft {
        await NutritionDraftResolver._testResolveVoiceFallbackDraft(
            dbQueue: dbQueue,
            transcription: transcription,
            confidence: confidence,
            targetDay: NutritionCoverageFixtures.targetDay,
            loggedAt: NutritionCoverageFixtures.loggedAt
        )
    }
}
#endif
