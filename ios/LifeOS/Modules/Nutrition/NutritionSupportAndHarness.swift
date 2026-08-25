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
