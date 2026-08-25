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
private struct FoodLabelAnalysisRequest: Encodable, Sendable {
    let barcode: String?
    let locale: String
    let imagesBase64: [String]

    enum CodingKeys: String, CodingKey {
        case barcode
        case locale
        case imagesBase64 = "images_base64"
    }
}

struct FoodLabelAnalysisResponse: Decodable, Sendable {
    let barcode: String?
    let name: String
    let brand: String?
    let servingSizeG: Double?
    let macrosPer100g: NutritionFoodsRemoteMacros
    let confidence: Double?
    let warnings: [String]
    let needsReview: Bool

    enum CodingKeys: String, CodingKey {
        case barcode
        case name
        case brand
        case servingSizeG = "serving_size_g"
        case macrosPer100g = "macros_per_100g"
        case confidence
        case warnings
        case needsReview = "needs_review"
    }
}

struct FoodLabelAnalysisService: Sendable {
    private let apiClient: any PredictionAPIClient

    init(apiClient: any PredictionAPIClient = APIClient()) {
        self.apiClient = apiClient
    }

    func analyzeLabel(
        imagesDataURL: [String],
        barcode: String?,
        localeIdentifier: String = Locale.preferredLanguages.first ?? Locale.autoupdatingCurrent.identifier
    ) async throws -> FoodLabelAnalysisResponse {
        let request = FoodLabelAnalysisRequest(
            barcode: barcode?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            locale: localeIdentifier,
            imagesBase64: imagesDataURL
        )

        do {
            let body = try JSONEncoder().encode(request)
            return try await apiClient.callEdgeFunction(
                "analyze-food-label",
                body: body,
                headers: [:],
                maxAttempts: 2
            )
        } catch let error as APIClientError {
            throw error
        } catch {
            throw FoodLabelAnalysisServiceError.transport(error)
        }
    }
}

enum FoodLabelAnalysisServiceError: Error {
    case transport(Error)
}

private struct BatchRecipePhotoAnalysisRequest: Encodable, Sendable {
    let recipeName: String
    let totalWeightGrams: Double
    let portionsPlanned: Int
    let cookingMethod: String?
    let knownIngredients: [String]
    let imageBase64: String

    enum CodingKeys: String, CodingKey {
        case recipeName = "recipe_name"
        case totalWeightGrams = "total_weight_grams"
        case portionsPlanned = "portions_planned"
        case cookingMethod = "cooking_method"
        case knownIngredients = "known_ingredients"
        case imageBase64 = "image_base64"
    }
}

struct BatchRecipePhotoAnalysisResponse: Decodable, Sendable {
    let recipeName: String?
    let ingredientsDetected: [Ingredient]
    let totalBatch: Totals?
    let per100g: Totals?
    let perPortion: Portion?
    let notes: [String]
    let storage: Storage?
    let confidence: Double?

    struct Ingredient: Decodable, Sendable {
        let name: String
        let estimatedRawWeightG: Double?
        let estimatedCookedWeightG: Double?
        let calories: Double
        let proteinG: Double
        let fatG: Double
        let carbsG: Double
        let confidence: Double?

        enum CodingKeys: String, CodingKey {
            case name
            case estimatedRawWeightG = "estimated_raw_weight_g"
            case estimatedCookedWeightG = "estimated_cooked_weight_g"
            case calories
            case proteinG = "protein_g"
            case fatG = "fat_g"
            case carbsG = "carbs_g"
            case confidence
        }
    }

    struct Totals: Decodable, Sendable {
        let weightG: Double?
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

    struct Portion: Decodable, Sendable {
        let weightG: Double?
        let calories: Double
        let proteinG: Double
        let fatG: Double
        let carbsG: Double

        enum CodingKeys: String, CodingKey {
            case weightG = "weight_g"
            case calories
            case proteinG = "protein_g"
            case fatG = "fat_g"
            case carbsG = "carbs_g"
        }
    }

    struct Storage: Decodable, Sendable {
        let refrigeratorDays: Int?
        let freezerMonths: Int?
        let reheatingTip: String?

        enum CodingKeys: String, CodingKey {
            case refrigeratorDays = "refrigerator_days"
            case freezerMonths = "freezer_months"
            case reheatingTip = "reheating_tip"
        }
    }

    enum CodingKeys: String, CodingKey {
        case recipeName = "recipe_name"
        case ingredientsDetected = "ingredients_detected"
        case totalBatch = "total_batch"
        case per100g = "per_100g"
        case perPortion = "per_portion"
        case notes
        case storage
        case confidence
    }
}

struct BatchRecipePhotoAnalysisService: Sendable {
    private let apiClient: any PredictionAPIClient

    init(apiClient: any PredictionAPIClient = APIClient()) {
        self.apiClient = apiClient
    }

    func analyzePhoto(
        imageDataURL: String,
        recipeName: String,
        totalWeightG: Double,
        totalPortions: Int,
        knownIngredients: [String]
    ) async throws -> BatchRecipePhotoAnalysisResponse {
        let request = BatchRecipePhotoAnalysisRequest(
            recipeName: recipeName,
            totalWeightGrams: totalWeightG,
            portionsPlanned: totalPortions,
            cookingMethod: "unknown",
            knownIngredients: knownIngredients,
            imageBase64: imageDataURL
        )

        do {
            let body = try JSONEncoder().encode(request)
            return try await apiClient.callEdgeFunction(
                "analyze-batch-recipe-image",
                body: body,
                headers: [:],
                maxAttempts: 2
            )
        } catch let error as APIClientError {
            throw error
        } catch {
            throw BatchRecipePhotoAnalysisServiceError.transport(error)
        }
    }
}

enum BatchRecipePhotoAnalysisServiceError: Error {
    case transport(Error)
}

private struct FoodTextParseRequest: Encodable, Sendable {
    let text: String
    let locale: String
    let context: String?
    let mealType: String?

    enum CodingKeys: String, CodingKey {
        case text
        case locale
        case context
        case mealType = "meal_type"
    }
}

struct FoodTextParseResponse: Decodable, Sendable {
    let items: [DetectedItem]
    let detectedItems: [DetectedItem]
    let totalMacros: Totals?
    let mealTypeRaw: String?
    let confidence: Double?
    let needsClarification: Bool
    let clarifyingQuestions: [ClarifyingQuestion]
    let warnings: [String]
    let suggestions: [String]
    let contextAnalysis: String?

    struct DetectedItem: Decodable, Sendable {
        let name: String
        let quantity: Double?
        let unit: String?
        let categoryRaw: String?
        let weightG: Double?
        let calories: Double?
        let proteinG: Double?
        let fatG: Double?
        let carbsG: Double?
        let fiberG: Double?
        let confidence: Double?
        let notes: String?
        let brand: String?
        let barcode: String?

        enum CodingKeys: String, CodingKey {
            case name
            case quantity
            case unit
            case categoryRaw = "category"
            case weightG = "weight_g"
            case calories
            case proteinG = "protein_g"
            case fatG = "fat_g"
            case carbsG = "carbs_g"
            case fiberG = "fiber_g"
            case confidence
            case notes
            case brand
            case barcode
        }
    }

    struct ClarifyingQuestion: Decodable, Sendable {
        let id: String
        let question: String
        let options: [String]

        let itemIndex: Int?
        let itemName: String?

        enum CodingKeys: String, CodingKey {
            case id
            case question
            case options
            case itemIndex = "item_index"
            case itemName = "item_name"
        }
    }

    struct Totals: Decodable, Sendable {
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

    enum CodingKeys: String, CodingKey {
        case items
        case detectedItems = "detected_items"
        case totalMacros = "total_macros"
        case mealTypeRaw = "meal_type"
        case confidence
        case needsClarification = "needs_clarification"
        case clarifyingQuestions = "clarifying_questions"
        case warnings
        case suggestions
        case contextAnalysis = "context_analysis"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let responseItems = try container.decodeIfPresent([DetectedItem].self, forKey: .items) ?? []
        let detectedResponseItems = try container.decodeIfPresent([DetectedItem].self, forKey: .detectedItems) ?? []
        items = responseItems.isEmpty ? detectedResponseItems : responseItems
        detectedItems = detectedResponseItems.isEmpty ? items : detectedResponseItems
        totalMacros = try container.decodeIfPresent(Totals.self, forKey: .totalMacros)
        mealTypeRaw = try container.decodeIfPresent(String.self, forKey: .mealTypeRaw)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        needsClarification = try container.decodeIfPresent(Bool.self, forKey: .needsClarification) ?? false
        clarifyingQuestions = try container.decodeIfPresent([ClarifyingQuestion].self, forKey: .clarifyingQuestions) ?? []
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        suggestions = try container.decodeIfPresent([String].self, forKey: .suggestions) ?? []
        contextAnalysis = try container.decodeIfPresent(String.self, forKey: .contextAnalysis)
    }
}

struct FoodTextParsingService: Sendable {
    private let apiClient: any PredictionAPIClient

    init(apiClient: any PredictionAPIClient = APIClient()) {
        self.apiClient = apiClient
    }

    func parseText(
        _ text: String,
        mealContext: MealContext? = nil,
        mealType: MealType? = nil,
        localeIdentifier: String = Locale.preferredLanguages.first ?? Locale.autoupdatingCurrent.identifier
    ) async throws -> FoodTextParseResponse {
        let request = FoodTextParseRequest(
            text: text,
            locale: localeIdentifier,
            context: mealContext?.rawValue,
            mealType: mealType?.rawValue
        )

        do {
            let body = try JSONEncoder().encode(request)
            return try await apiClient.callEdgeFunction(
                "parse-food-text",
                body: body,
                headers: [:],
                maxAttempts: 2
            )
        } catch let error as APIClientError {
            throw error
        } catch {
            throw FoodTextParsingServiceError.transport(error)
        }
    }
}

enum FoodTextParsingServiceError: Error {
    case transport(Error)
}

enum MediaRecognitionService {
    private static let queue = DispatchQueue(label: "com.lifeos.media-recognition", qos: .userInitiated)
    private static let imageCompressionQuality = 0.82
    private static let maxImageDimension: CGFloat = 1_536
#if DEBUG
    private static let testRecognizeTextOverride = LockedTestOverride<
        @Sendable (UIImage) async throws -> String
    >()
    private static let testSyncRecognizeTextOverride = LockedTestOverride<
        @Sendable (UIImage) throws -> String
    >()
    private static let testSyncDetectBarcodesOverride = LockedTestOverride<
        @Sendable (Data) throws -> [String]
    >()
    private static let testDetectBarcodesOverride = LockedTestOverride<
        @Sendable (UIImage) async throws -> [String]
    >()
    private static let testFoodPhotoAnalysisOverride = LockedTestOverride<
        @Sendable (String, Date, String?, [String]) async throws -> FoodPhotoAnalysisResponse
    >()
    private static let testFoodPhotoServiceRunnerOverride = LockedTestOverride<
        @Sendable (String, Date, String?, [String]) async throws -> FoodPhotoAnalysisResponse
    >()
    private static let testFoodLabelAnalysisOverride = LockedTestOverride<
        @Sendable ([String], String?) async throws -> FoodLabelAnalysisResponse
    >()
    private static let testFoodLabelServiceRunnerOverride = LockedTestOverride<
        @Sendable ([String], String?) async throws -> FoodLabelAnalysisResponse
    >()
    private static let testBatchRecipePhotoAnalysisOverride = LockedTestOverride<
        @Sendable (String, String, Double, Int, [String]) async throws -> BatchRecipePhotoAnalysisResponse
    >()
    private static let testBatchRecipePhotoServiceRunnerOverride = LockedTestOverride<
        @Sendable (String, String, Double, Int, [String]) async throws -> BatchRecipePhotoAnalysisResponse
    >()
    private static let testCloudAnalysisEnabledOverride = LockedTestOverride<
        @Sendable () async -> Bool
    >()
    private static let testPhotoCloudAnalysisAvailableOverride = LockedTestOverride<Bool>()
#endif

    static func analyzeNutritionPhoto(_ image: UIImage, loggedAt: Date) async -> NutritionPhotoAnalysis {
        async let recognizedTextTask = recognizedTextResult(for: image)
        async let barcodesTask = barcodeResult(for: image)

        let recognizedTextResult = await recognizedTextTask
        let barcodeResult = await barcodesTask
        let recognizedText = normalizedRecognizedText(recognizedTextResult)
        let barcodes = Array(Set(barcodeResult ?? [])).sorted()

        let cloudAnalysisEnabled = await isCloudAnalysisEnabled()
        guard cloudAnalysisEnabled else {
            return fallbackAnalysis(
                recognizedText: recognizedText,
                barcodes: barcodes,
                notice: String(localized: "nutrition_photo_cloud_disabled_notice")
            )
        }

        do {
            let imageDataURL = try preparedImageDataURL(for: image)
            let response = try await foodPhotoAnalysisResponse(
                imageDataURL: imageDataURL,
                loggedAt: loggedAt,
                recognizedText: recognizedText,
                barcodes: barcodes
            )
            return aiAnalysis(
                from: response,
                recognizedText: recognizedText,
                barcodes: barcodes
            )
        } catch {
#if DEBUG
            fputs("Food photo analysis fallback: \(error)\n", stderr)
#endif
            return fallbackAnalysis(
                recognizedText: recognizedText,
                barcodes: barcodes,
                notice: String(localized: "nutrition_photo_fallback_notice")
            )
        }
    }

    static func analyzeFoodLabelDraft(
        from images: [UIImage],
        barcodeHint: String?
    ) async -> NutritionLabelReviewDraft {
        let preparedImages = Array(images.suffix(2))
        let recognizedTexts = await recognizedTextResults(for: preparedImages)
        let detectedBarcodes = await barcodeResults(for: preparedImages)
        let resolvedBarcode = ([barcodeHint] + detectedBarcodes)
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let sourceText = normalizedRecognizedText(
            recognizedTexts
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
        )

        let cloudAnalysisEnabled = await isCloudAnalysisEnabled()
        if cloudAnalysisEnabled {
            do {
                let imageDataURLs = try preparedImages.map { try preparedImageDataURL(for: $0) }
                let response = try await foodLabelAnalysisResponse(
                    imagesDataURL: imageDataURLs,
                    barcode: resolvedBarcode
                )
                return aiFoodLabelDraft(
                    from: response,
                    sourceText: sourceText,
                    barcodeHint: resolvedBarcode
                )
            } catch {
#if DEBUG
                fputs("Food label analysis fallback: \(error)\n", stderr)
#endif
            }
        }

        let notice = cloudAnalysisEnabled
            ? String(localized: "nutrition_photo_fallback_notice")
            : String(localized: "nutrition_photo_cloud_disabled_notice")
        return fallbackFoodLabelDraft(
            sourceText: sourceText,
            barcode: resolvedBarcode,
            notice: notice
        )
    }

    static func analyzeBatchRecipePhoto(
        _ image: UIImage,
        recipeName: String,
        totalWeightG: Double,
        totalPortions: Int,
        knownIngredients: [String]
    ) async -> BatchRecipePhotoDraft {
        let resolvedRecipeName = recipeName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? String(localized: "nutrition_default_meal_prep_name")
        let normalizedWeight = totalWeightG > 0 ? totalWeightG : 1_000
        let normalizedPortions = max(totalPortions, 1)
        let cloudAnalysisEnabled = await isCloudAnalysisEnabled()

        if cloudAnalysisEnabled {
            do {
                let imageDataURL = try preparedImageDataURL(for: image)
                let response = try await batchRecipePhotoAnalysisResponse(
                    imageDataURL: imageDataURL,
                    recipeName: resolvedRecipeName,
                    totalWeightG: normalizedWeight,
                    totalPortions: normalizedPortions,
                    knownIngredients: knownIngredients
                )
                let draft = batchRecipePhotoDraft(
                    from: response,
                    fallbackRecipeName: resolvedRecipeName,
                    fallbackWeightG: normalizedWeight,
                    fallbackPortions: normalizedPortions
                )
                if !draft.ingredients.isEmpty {
                    return draft
                }
            } catch {
#if DEBUG
                fputs("Batch recipe photo analysis fallback: \(error)\n", stderr)
#endif
            }
        }

        let fallbackAnalysis = await analyzeNutritionPhoto(image, loggedAt: Date())
        return fallbackBatchRecipePhotoDraft(
            from: fallbackAnalysis,
            recipeName: resolvedRecipeName,
            totalWeightG: normalizedWeight,
            totalPortions: normalizedPortions,
            cloudAnalysisEnabled: cloudAnalysisEnabled
        )
    }

    private static func foodPhotoAnalysisResponse(
        imageDataURL: String,
        loggedAt: Date,
        recognizedText: String?,
        barcodes: [String],
        service: FoodPhotoAnalysisService = FoodPhotoAnalysisService()
    ) async throws -> FoodPhotoAnalysisResponse {
#if DEBUG
        if let override = testFoodPhotoAnalysisOverride.value {
            return try await override(imageDataURL, loggedAt, recognizedText, barcodes)
        }
        if let serviceRunner = testFoodPhotoServiceRunnerOverride.value {
            return try await serviceRunner(imageDataURL, loggedAt, recognizedText, barcodes)
        }
#endif
        return try await defaultFoodPhotoAnalysisResponse(
            imageDataURL: imageDataURL,
            loggedAt: loggedAt,
            recognizedText: recognizedText,
            barcodes: barcodes,
            service: service
        )
    }

    private static func defaultFoodPhotoAnalysisResponse(
        imageDataURL: String,
        loggedAt: Date,
        recognizedText: String?,
        barcodes: [String],
        service: FoodPhotoAnalysisService = FoodPhotoAnalysisService()
    ) async throws -> FoodPhotoAnalysisResponse {
        try await service.analyzePhoto(
            imageDataURL: imageDataURL,
            loggedAt: loggedAt,
            recognizedText: recognizedText,
            barcodes: barcodes
        )
    }

    private static func foodLabelAnalysisResponse(
        imagesDataURL: [String],
        barcode: String?,
        service: FoodLabelAnalysisService = FoodLabelAnalysisService()
    ) async throws -> FoodLabelAnalysisResponse {
#if DEBUG
        if let override = testFoodLabelAnalysisOverride.value {
            return try await override(imagesDataURL, barcode)
        }
        if let serviceRunner = testFoodLabelServiceRunnerOverride.value {
            return try await serviceRunner(imagesDataURL, barcode)
        }
#endif
        return try await defaultFoodLabelAnalysisResponse(
            imagesDataURL: imagesDataURL,
            barcode: barcode,
            service: service
        )
    }

    private static func defaultFoodLabelAnalysisResponse(
        imagesDataURL: [String],
        barcode: String?,
        service: FoodLabelAnalysisService = FoodLabelAnalysisService()
    ) async throws -> FoodLabelAnalysisResponse {
        try await service.analyzeLabel(
            imagesDataURL: imagesDataURL,
            barcode: barcode
        )
    }

    private static func batchRecipePhotoAnalysisResponse(
        imageDataURL: String,
        recipeName: String,
        totalWeightG: Double,
        totalPortions: Int,
        knownIngredients: [String],
        service: BatchRecipePhotoAnalysisService = BatchRecipePhotoAnalysisService()
    ) async throws -> BatchRecipePhotoAnalysisResponse {
#if DEBUG
        if let override = testBatchRecipePhotoAnalysisOverride.value {
            return try await override(
                imageDataURL,
                recipeName,
                totalWeightG,
                totalPortions,
                knownIngredients
            )
        }
        if let serviceRunner = testBatchRecipePhotoServiceRunnerOverride.value {
            return try await serviceRunner(
                imageDataURL,
                recipeName,
                totalWeightG,
                totalPortions,
                knownIngredients
            )
        }
#endif
        return try await defaultBatchRecipePhotoAnalysisResponse(
            imageDataURL: imageDataURL,
            recipeName: recipeName,
            totalWeightG: totalWeightG,
            totalPortions: totalPortions,
            knownIngredients: knownIngredients,
            service: service
        )
    }

    private static func defaultBatchRecipePhotoAnalysisResponse(
        imageDataURL: String,
        recipeName: String,
        totalWeightG: Double,
        totalPortions: Int,
        knownIngredients: [String],
        service: BatchRecipePhotoAnalysisService = BatchRecipePhotoAnalysisService()
    ) async throws -> BatchRecipePhotoAnalysisResponse {
        try await service.analyzePhoto(
            imageDataURL: imageDataURL,
            recipeName: recipeName,
            totalWeightG: totalWeightG,
            totalPortions: totalPortions,
            knownIngredients: knownIngredients
        )
    }

    static func detectBarcodes(in image: UIImage) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard let data = image.jpegData(compressionQuality: 0.9) else {
                        throw RecognitionError.invalidImageData
                    }
#if DEBUG
                    if let override = testSyncDetectBarcodesOverride.value {
                        let codes = try override(data)
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        continuation.resume(returning: Array(Set(codes)).sorted())
                        return
                    }
#endif
                    let request = VNDetectBarcodesRequest()
                    request.symbologies = [.ean13, .ean8, .upce, .code128, .qr]
                    let handler = VNImageRequestHandler(data: data, options: [:])
                    try handler.perform([request])
                    let codes = (request.results ?? []).compactMap { observation in
                        observation.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    continuation.resume(returning: Array(Set(codes)).sorted())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func recognizeText(in image: UIImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try syncRecognizeText(in: image))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func recognizeText(inPDFAt url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard let document = PDFDocument(url: url) else {
                        throw RecognitionError.invalidDocument
                    }

                    var pages: [String] = []
                    for pageIndex in 0..<document.pageCount {
                        guard let page = document.page(at: pageIndex) else { continue }
                        let embeddedText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if !embeddedText.isEmpty {
                            pages.append(embeddedText)
                            continue
                        }

                        let bounds = page.bounds(for: .mediaBox)
                        let renderer = UIGraphicsImageRenderer(size: bounds.size)
                        let image = renderer.image { context in
                            UIColor.white.setFill()
                            context.fill(CGRect(origin: .zero, size: bounds.size))
                            context.cgContext.translateBy(x: 0, y: bounds.size.height)
                            context.cgContext.scaleBy(x: 1, y: -1)
                            page.draw(with: .mediaBox, to: context.cgContext)
                        }
                        let ocrText = try syncRecognizeText(in: image)
                        if !ocrText.isEmpty {
                            pages.append(ocrText)
                        }
                    }

                    continuation.resume(returning: pages.joined(separator: "\n"))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func syncRecognizeText(in image: UIImage) throws -> String {
#if DEBUG
        if let override = testSyncRecognizeTextOverride.value {
            return try override(image)
        }
#endif
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            throw RecognitionError.invalidImageData
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = Array(Locale.preferredLanguages.prefix(2))
        let handler = VNImageRequestHandler(data: data, options: [:])
        try handler.perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    private static func aiAnalysis(
        from response: FoodPhotoAnalysisResponse,
        recognizedText: String?,
        barcodes: [String]
    ) -> NutritionPhotoAnalysis {
        let detectedItems = response.detectedItems.map { item in
            NutritionDraftCandidateItem(
                name: item.name,
                category: item.categoryRaw.flatMap { NutritionDetectedFoodCategory(rawValue: $0) },
                notes: normalizedRecognizedText(item.notes),
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

        let summary = normalizedRecognizedText(response.contextAnalysis)
            ?? aiSummaryFallback(detectedItems: detectedItems, totalMacros: totalMacros)

        return NutritionPhotoAnalysis(
            summary: summary,
            confidence: response.confidence,
            source: .aiVision,
            recognizedText: recognizedText,
            barcodes: barcodes,
            detectedItems: detectedItems,
            totalMacros: totalMacros,
            warnings: normalizedLines(response.warnings),
            suggestions: normalizedLines(response.suggestions),
            mealType: response.mealTypeRaw.flatMap { MealType(rawValue: $0.lowercased()) },
            notice: nil
        )
    }

    private static func fallbackAnalysis(
        recognizedText: String?,
        barcodes: [String],
        notice: String?
    ) -> NutritionPhotoAnalysis {
        let hasSignals = (recognizedText?.isEmpty == false) || !barcodes.isEmpty
        return NutritionPhotoAnalysis(
            summary: fallbackSummary(recognizedText: recognizedText, barcodes: barcodes),
            confidence: hasSignals ? 0.58 : 0.42,
            source: .onDeviceFallback,
            recognizedText: recognizedText,
            barcodes: barcodes,
            detectedItems: [],
            totalMacros: nil,
            warnings: notice.map { [$0] } ?? [],
            suggestions: [],
            mealType: nil,
            notice: notice
        )
    }

    private static func aiSummaryFallback(
        detectedItems: [NutritionDraftCandidateItem],
        totalMacros: NutritionDraftMacroSummary?
    ) -> String {
        let names = detectedItems
            .map(\.name)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(3)
            .joined(separator: ", ")

        guard !names.isEmpty else {
            return String(localized: "nutrition_photo_analyzed")
        }

        if let totalMacros {
            return String(
                format: String(localized: "nutrition_photo_ai_summary_fallback_format"),
                names,
                Int(totalMacros.calories.rounded())
            )
        }
        return String(
            format: String(localized: "nutrition_photo_ai_summary_names_only_format"),
            names
        )
    }

    private static func fallbackSummary(
        recognizedText: String?,
        barcodes: [String]
    ) -> String {
        var fragments: [String] = []
        if let code = barcodes.first, !code.isEmpty {
            fragments.append(
                String(
                    format: String(localized: "nutrition_photo_local_hint_barcode_format"),
                    code
                )
            )
        }
        if let recognizedText,
           !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let preview = recognizedText
                .replacingOccurrences(of: "\n", with: " ")
                .split(separator: " ")
                .prefix(24)
                .joined(separator: " ")
            if !preview.isEmpty {
                fragments.append(
                    String(
                        format: String(localized: "nutrition_photo_local_hint_text_format"),
                        preview
                    )
                )
            }
        }
        if fragments.isEmpty {
            return String(localized: "nutrition_photo_analyzed")
        }
        return fragments.joined(separator: "\n")
    }

    private static func aiFoodLabelDraft(
        from response: FoodLabelAnalysisResponse,
        sourceText: String?,
        barcodeHint: String?
    ) -> NutritionLabelReviewDraft {
        let resolvedBarcode = response.barcode?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? barcodeHint?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? ""
        let warnings = normalizedLines(response.warnings)
        return NutritionLabelReviewDraft(
            barcode: resolvedBarcode,
            name: response.name,
            brand: response.brand ?? "",
            servingSizeG: response.servingSizeG ?? 100,
            caloriesPer100g: response.macrosPer100g.calories,
            proteinPer100g: response.macrosPer100g.proteinG,
            fatPer100g: response.macrosPer100g.fatG,
            carbsPer100g: response.macrosPer100g.carbsG,
            fiberPer100g: response.macrosPer100g.fiberG ?? 0,
            confidence: response.confidence,
            warnings: warnings,
            sourceText: sourceText,
            analysisSource: .aiVision,
            summary: response.name
        )
    }

    private static func fallbackFoodLabelDraft(
        sourceText: String?,
        barcode: String?,
        notice: String
    ) -> NutritionLabelReviewDraft {
        let parserResult = parseNutritionLabelText(sourceText)
        var warnings = parserResult.warnings
        warnings.insert(notice, at: 0)
        return NutritionLabelReviewDraft(
            barcode: barcode ?? "",
            name: parserResult.name,
            brand: parserResult.brand ?? "",
            servingSizeG: parserResult.servingSizeG,
            caloriesPer100g: parserResult.caloriesPer100g,
            proteinPer100g: parserResult.proteinPer100g,
            fatPer100g: parserResult.fatPer100g,
            carbsPer100g: parserResult.carbsPer100g,
            fiberPer100g: parserResult.fiberPer100g,
            confidence: parserResult.confidence,
            warnings: normalizedLines(warnings),
            sourceText: sourceText,
            analysisSource: .onDeviceFallback,
            summary: parserResult.name
        )
    }

    private static func batchRecipePhotoDraft(
        from response: BatchRecipePhotoAnalysisResponse,
        fallbackRecipeName: String,
        fallbackWeightG: Double,
        fallbackPortions: Int
    ) -> BatchRecipePhotoDraft {
        let recipeName = response.recipeName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? fallbackRecipeName
        let totalWeightG = response.totalBatch?.weightG ?? fallbackWeightG
        let resolvedPortions: Int
        if let perPortionWeight = response.perPortion?.weightG,
           perPortionWeight > 0 {
            resolvedPortions = max(Int((totalWeightG / perPortionWeight).rounded()), 1)
        } else {
            resolvedPortions = fallbackPortions
        }
        let ingredientWeightFallback = response.ingredientsDetected.isEmpty
            ? max(totalWeightG / Double(max(fallbackPortions, 1)), 100)
            : max(totalWeightG / Double(response.ingredientsDetected.count), 50)

        let ingredients = response.ingredientsDetected.map { ingredient in
            BatchRecipeEditableIngredient(
                name: ingredient.name,
                weightG: ingredient.estimatedCookedWeightG ?? ingredient.estimatedRawWeightG ?? ingredientWeightFallback,
                calories: ingredient.calories,
                proteinG: ingredient.proteinG,
                fatG: ingredient.fatG,
                carbsG: ingredient.carbsG,
                fiberG: 0
            )
        }

        var notes = normalizedLines(response.notes)
        if let storage = response.storage {
            if let refrigeratorDays = storage.refrigeratorDays {
                notes.append("Refrigerator: \(refrigeratorDays) days")
            }
            if let freezerMonths = storage.freezerMonths {
                notes.append("Freezer: \(freezerMonths) months")
            }
            if let reheatingTip = storage.reheatingTip?.trimmingCharacters(in: .whitespacesAndNewlines),
               !reheatingTip.isEmpty {
                notes.append(reheatingTip)
            }
        }

        return BatchRecipePhotoDraft(
            recipeName: recipeName,
            ingredients: ingredients,
            totalWeightG: totalWeightG,
            totalPortions: resolvedPortions,
            confidence: response.confidence,
            notes: notes,
            descriptionText: notes.isEmpty ? nil : notes.joined(separator: "\n")
        )
    }

    private static func fallbackBatchRecipePhotoDraft(
        from analysis: NutritionPhotoAnalysis,
        recipeName: String,
        totalWeightG: Double,
        totalPortions: Int,
        cloudAnalysisEnabled: Bool
    ) -> BatchRecipePhotoDraft {
        let detectedItems = analysis.detectedItems
        let ingredientWeightFallback = detectedItems.isEmpty
            ? max(totalWeightG / Double(max(totalPortions, 1)), 100)
            : max(totalWeightG / Double(detectedItems.count), 50)
        let ingredients = detectedItems.map { item in
            BatchRecipeEditableIngredient(
                name: item.name,
                brand: item.brand ?? "",
                barcode: item.barcode ?? "",
                catalogItemId: item.catalogItemId,
                userFoodId: item.userFoodId,
                weightG: item.weightG ?? ingredientWeightFallback,
                calories: item.calories ?? 0,
                proteinG: item.proteinG ?? 0,
                fatG: item.fatG ?? 0,
                carbsG: item.carbsG ?? 0,
                fiberG: item.fiberG ?? 0
            )
        }

        var notes = normalizedLines(analysis.warnings)
        if let summary = normalizedRecognizedText(analysis.summary) {
            notes.insert(summary, at: 0)
        }
        if notes.isEmpty {
            notes.append(
                cloudAnalysisEnabled
                    ? String(localized: "nutrition_photo_fallback_notice")
                    : String(localized: "nutrition_photo_cloud_disabled_notice")
            )
        }

        return BatchRecipePhotoDraft(
            recipeName: recipeName,
            ingredients: ingredients,
            totalWeightG: totalWeightG,
            totalPortions: totalPortions,
            confidence: analysis.confidence,
            notes: notes,
            descriptionText: notes.joined(separator: "\n")
        )
    }

    static func preparedImageDataURL(for image: UIImage) throws -> String {
        let normalizedImage = resizedImageIfNeeded(image, maxDimension: maxImageDimension)
        guard let data = normalizedImage.jpegData(compressionQuality: imageCompressionQuality) else {
            throw RecognitionError.invalidImageData
        }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    private static func resizedImageIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longestSide = max(size.width, size.height)
        guard longestSide > maxDimension, longestSide > 0 else {
            return image
        }

        let scale = maxDimension / longestSide
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private static func normalizedRecognizedText(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedLines(_ values: [String]) -> [String] {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func recognizedTextResult(for image: UIImage) async -> String? {
#if DEBUG
        if let override = testRecognizeTextOverride.value {
            return try? await override(image)
        }
#endif
        return try? await recognizeText(in: image)
    }

    private static func barcodeResult(for image: UIImage) async -> [String]? {
#if DEBUG
        if let override = testDetectBarcodesOverride.value {
            return try? await override(image)
        }
#endif
        return try? await detectBarcodes(in: image)
    }

    private static func recognizedTextResults(for images: [UIImage]) async -> [String] {
        var results: [String] = []
        for image in images {
            if let text = await recognizedTextResult(for: image),
               let normalized = normalizedRecognizedText(text) {
                results.append(normalized)
            }
        }
        return results
    }

    private static func barcodeResults(for images: [UIImage]) async -> [String?] {
        var results: [String?] = []
        for image in images {
            let barcode = (await barcodeResult(for: image))?.first
            results.append(barcode)
        }
        return results
    }

    private static func parseNutritionLabelText(_ text: String?) -> (
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
        let normalizedText = normalizedRecognizedText(text)
        let lines = normalizedText?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let name = lines.first(where: {
            !$0.contains(where: \.isNumber) &&
            !$0.lowercased().contains("protein") &&
            !$0.lowercased().contains("fat") &&
            !$0.lowercased().contains("carb") &&
            !$0.lowercased().contains("бел") &&
            !$0.lowercased().contains("жир") &&
            !$0.lowercased().contains("угл")
        }) ?? String(localized: "nutrition_default_item_name")
        let servingSizeG = extractFirstNumber(
            matchingAnyOf: [
                #"serv(?:ing)?[^0-9]{0,12}(\d+(?:[.,]\d+)?)\s*(?:g|ml)"#,
                #"порц(?:ия|ии)?[^0-9]{0,12}(\d+(?:[.,]\d+)?)\s*(?:г|мл)"#,
                #"(\d+(?:[.,]\d+)?)\s*(?:g|г|ml|мл)"#
            ],
            in: normalizedText
        ) ?? 100
        let calories = extractFirstNumber(
            matchingAnyOf: [
                #"kcal[^0-9]{0,8}(\d+(?:[.,]\d+)?)"#,
                #"калор[^0-9]{0,8}(\d+(?:[.,]\d+)?)"#,
                #"энерг[^0-9]{0,12}(\d+(?:[.,]\d+)?)"#
            ],
            in: normalizedText
        ) ?? 0
        let protein = extractFirstNumber(
            matchingAnyOf: [#"protein[^0-9]{0,8}(\d+(?:[.,]\d+)?)"#, #"бел[оа]к[^0-9]{0,8}(\d+(?:[.,]\d+)?)"#],
            in: normalizedText
        ) ?? 0
        let fat = extractFirstNumber(
            matchingAnyOf: [#"fat[^0-9]{0,8}(\d+(?:[.,]\d+)?)"#, #"жир[^0-9]{0,8}(\d+(?:[.,]\d+)?)"#],
            in: normalizedText
        ) ?? 0
        let carbs = extractFirstNumber(
            matchingAnyOf: [#"carb(?:ohydrate)?s?[^0-9]{0,8}(\d+(?:[.,]\d+)?)"#, #"углевод[^0-9]{0,8}(\d+(?:[.,]\d+)?)"#],
            in: normalizedText
        ) ?? 0
        let fiber = extractFirstNumber(
            matchingAnyOf: [#"fiber[^0-9]{0,8}(\d+(?:[.,]\d+)?)"#, #"клетчат[^0-9]{0,8}(\d+(?:[.,]\d+)?)"#],
            in: normalizedText
        ) ?? 0

        var warnings: [String] = []
        if normalizedText == nil {
            warnings.append(String(localized: "nutrition_barcode_review_label_manually"))
        }
        if calories == 0 && protein == 0 && fat == 0 && carbs == 0 {
            warnings.append(String(localized: "nutrition_review_serving_sizes_warning"))
        }

        return (
            name: name,
            brand: nil,
            servingSizeG: servingSizeG,
            caloriesPer100g: calories,
            proteinPer100g: protein,
            fatPer100g: fat,
            carbsPer100g: carbs,
            fiberPer100g: fiber,
            confidence: normalizedText == nil ? 0.35 : 0.52,
            warnings: warnings
        )
    }

    private static func extractFirstNumber(
        matchingAnyOf patterns: [String],
        in text: String?
    ) -> Double? {
        guard let text else { return nil }
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            let value = text[valueRange].replacingOccurrences(of: ",", with: ".")
            if let parsed = Double(value), parsed >= 0 {
                return parsed
            }
        }
        return nil
    }

    private static func isCloudAnalysisEnabled() async -> Bool {
#if DEBUG
        if let override = testCloudAnalysisEnabledOverride.value {
            return await override()
        }
        if let availableOverride = testPhotoCloudAnalysisAvailableOverride.value {
            guard availableOverride else {
                return false
            }
        } else {
            let photoCloudAnalysisAvailable = await MainActor.run {
                AIAvailability().photoCloudAnalysisAvailable
            }
            guard photoCloudAnalysisAvailable else {
                return false
            }
        }
#else
        let photoCloudAnalysisAvailable = await MainActor.run {
            AIAvailability().photoCloudAnalysisAvailable
        }
        guard photoCloudAnalysisAvailable else {
            return false
        }
#endif
        let activeAuthId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        guard let authId = activeAuthId else {
            return true
        }

        do {
            return try await DatabaseManager.shared.dbQueue.read { db in
                let enabled = try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT cloud_ocr_enabled
                        FROM privacy_settings
                        WHERE user_id = (
                            SELECT id
                            FROM users
                            WHERE auth_id = ?
                            LIMIT 1
                        )
                        ORDER BY updated_at DESC
                        LIMIT 1
                        """,
                    arguments: [authId]
                )
                return enabled ?? true
            }
        } catch {
            return true
        }
    }

    enum RecognitionError: LocalizedError {
        case invalidImageData
        case invalidDocument

        var errorDescription: String? {
            switch self {
            case .invalidImageData:
                return String(localized: "error.media.selected_image_process")
            case .invalidDocument:
                return String(localized: "error.media.selected_document_open")
            }
        }
    }
}

// MARK: - Test support extensions (co-located with their types)
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
