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
// MARK: - Photo Capture View

struct NutritionPhotoCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var capturedImage: UIImage?
    @State private var isAnalyzing = false
    @State private var analysisResult: String?
    @State private var analysisConfidence: Double?
    @State private var photoAnalysis: NutritionPhotoAnalysis?
    @State private var analysisNotice: String?
    @State private var showCameraPicker = false
    @State private var showPhotoLibrary = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var captureError: String?
    let targetDay: String
    let loggedAt: Date
    var savedDraftId: UUID? = nil
    var onDraftStateChanged: () -> Void = {}
    let onResult: (NutritionLogDraft) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.m) {
                if let image = capturedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))

                    if isAnalyzing {
                        ProgressView(String(localized: "nutrition_analyzing_photo"))
                    } else if let result = analysisResult {
                        VStack(spacing: Spacing.xs) {
                            Text(result)
                                .font(LifeOSTypography.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            if let analysisNotice {
                                Text(analysisNotice)
                                    .font(LifeOSTypography.caption)
                                    .foregroundStyle(LifeOSColors.Recovery.caution)
                                    .multilineTextAlignment(.center)
                            }
                            if let captureError {
                                Text(captureError)
                                    .font(LifeOSTypography.caption2)
                                    .foregroundStyle(.red)
                                    .multilineTextAlignment(.center)
                            }
                        }
                    } else if let captureError {
                        Text(captureError)
                            .font(LifeOSTypography.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: Spacing.s) {
                        Button(String(localized: "nutrition_use_photo"), action: beginUseCapturedPhoto)
                            .buttonStyle(.borderedProminent)
                            .disabled(isAnalyzing)

                        Button(String(localized: "nutrition_save_photo_for_later"), action: beginSavePhotoForLater)
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("nutrition.photo.save_for_later")
                    }
                } else {
                    VStack(spacing: Spacing.s) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text(String(localized: "nutrition_take_photo_prompt"))
                            .font(LifeOSTypography.body)
                            .foregroundStyle(.secondary)
                        Button(String(localized: "nutrition_open_camera"), action: beginCameraCapture)
                        .buttonStyle(.borderedProminent)

                        Button(String(localized: "nutrition_choose_photo"), action: openPhotoLibraryPicker)
                        .buttonStyle(.bordered)

                        if let captureError {
                            Text(captureError)
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
            }
            .padding(LayoutConstants.contentPadding)
            .navigationTitle(String(localized: "nutrition_photo_title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: dismissScreen) {
                        Text(String(localized: "cancel"))
                    }
                }
            }
            .sheet(isPresented: $showCameraPicker, content: cameraPickerSheet)
            .photosPicker(
                isPresented: $showPhotoLibrary,
                selection: $selectedPhotoItem,
                matching: .images
            )
            .task(id: selectedPhotoItem, handleSelectedPhotoItemChange)
            .task(id: savedDraftId, loadSavedDraftIfNeeded)
        }
    }

    private func fallbackPhotoAnalysis() -> NutritionPhotoAnalysis {
        NutritionPhotoAnalysis(
            summary: analysisResult ?? String(localized: "nutrition_photo_analyzed"),
            confidence: analysisConfidence,
            source: .onDeviceFallback,
            recognizedText: nil,
            barcodes: [],
            detectedItems: [],
            totalMacros: nil,
            warnings: [],
            suggestions: [],
            mealType: nil,
            notice: analysisNotice
        )
    }

    private func cameraPickerSheet() -> some View {
        SystemImagePicker(
            sourceType: .camera,
            onImagePicked: handlePickedCameraImage
        )
    }

    private func beginUseCapturedPhoto() {
        Task { await useCapturedPhoto() }
    }

    private func beginSavePhotoForLater() {
        savePhotoForLater()
    }

    private func beginCameraCapture() {
        openCameraOrLibrary()
    }

    private func openPhotoLibraryPicker() {
        showPhotoLibrary = true
    }

    private func dismissScreen() {
        performDismiss()
    }

    @MainActor
    private func loadSavedDraftIfNeeded() async {
        guard let savedDraftId, capturedImage == nil else { return }
        do {
            let data = try NutritionPhotoDraftStore.imageData(id: savedDraftId)
            guard let image = UIImage(data: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            await processCapturedImage(image)
        } catch {
            captureError = String(localized: "nutrition_photo_draft_load_failed")
        }
    }

    @MainActor
    private func savePhotoForLater(
        saveAction: ((Data, String, Date, UUID?) throws -> NutritionPhotoDraft)? = nil,
        dismissAction: (() -> Void)? = nil
    ) {
        guard let capturedImage,
              let imageData = capturedImage.jpegData(compressionQuality: 0.85) else {
            captureError = String(localized: "nutrition_photo_draft_save_failed")
            return
        }
        do {
            if let saveAction {
                _ = try saveAction(imageData, targetDay, loggedAt, savedDraftId)
            } else {
                _ = try NutritionPhotoDraftStore.save(
                    imageData: imageData,
                    targetDay: targetDay,
                    loggedAt: loggedAt,
                    id: savedDraftId
                )
            }
            onDraftStateChanged()
            performDismiss(dismissAction: dismissAction)
        } catch {
            captureError = String(localized: "nutrition_photo_draft_save_failed")
        }
    }

    private func performDismiss(
        dismissAction: (() -> Void)? = nil
    ) {
        let handleDismiss = dismissAction ?? { dismiss() }
        handleDismiss()
    }

    private func handlePickedCameraImage(_ image: UIImage) {
        handleCapturedCameraImage(image)
    }

    private func handleCapturedCameraImage(
        _ image: UIImage,
        processCapturedImageAction: ((UIImage) async -> Void)? = nil
    ) {
        Task {
            if let processCapturedImageAction {
                await processCapturedImageAction(image)
            } else {
                await processCapturedImage(image)
            }
        }
    }

    @MainActor
    private func handleSelectedPhotoItemChange() async {
        await loadSelectedPhotoItemIfNeeded(
            item: selectedPhotoItem,
            shouldLoad: selectedPhotoItem != nil
        )
    }

    @MainActor
    private func loadSelectedPhotoItemIfNeeded(
        item: PhotosPickerItem?,
        shouldLoad: Bool,
        loadPhotoItemAction: ((PhotosPickerItem?) async -> Void)? = nil
    ) async {
        guard shouldLoad else { return }
        if let loadPhotoItemAction {
            await loadPhotoItemAction(item)
            return
        }
        await loadSelectedPhotoItemIfPresent(item)
    }

    @MainActor
    private func useCapturedPhoto(
        resolvePhotoDraft: ((NutritionPhotoAnalysis, String, Date) async -> NutritionLogDraft)? = nil,
        onResultAction: ((NutritionLogDraft) -> Void)? = nil,
        dismissAction: (() -> Void)? = nil
    ) async {
        let draft: NutritionLogDraft
        if let resolvePhotoDraft {
            draft = await resolvePhotoDraft(
                photoAnalysis ?? fallbackPhotoAnalysis(),
                targetDay,
                loggedAt
            )
        } else {
            draft = await resolveDefaultPhotoDraft(
                analysis: photoAnalysis ?? fallbackPhotoAnalysis(),
                targetDay: targetDay,
                loggedAt: loggedAt
            )
        }
        if let onResultAction {
            onResultAction(draft)
        } else {
            onResult(draft)
        }
        if let savedDraftId {
            try? NutritionPhotoDraftStore.delete(id: savedDraftId)
            onDraftStateChanged()
        }
        performDismiss(dismissAction: dismissAction)
    }

    @MainActor
    private func resolveDefaultPhotoDraft(
        analysis: NutritionPhotoAnalysis,
        targetDay: String,
        loggedAt: Date
    ) async -> NutritionLogDraft {
        await NutritionDraftResolver().resolvePhotoDraft(
            analysis: analysis,
            targetDay: targetDay,
            loggedAt: loggedAt
        )
    }

    private static func capturePickerState(cameraAvailable: Bool) -> (
        showCameraPicker: Bool,
        showPhotoLibrary: Bool
    ) {
        if cameraAvailable {
            return (showCameraPicker: true, showPhotoLibrary: false)
        }
        return (showCameraPicker: false, showPhotoLibrary: true)
    }

    private func openCameraOrLibrary(
        cameraAvailableProvider: (() -> Bool)? = nil
    ) {
        let cameraAvailable = cameraAvailableProvider?()
            ?? UIImagePickerController.isSourceTypeAvailable(.camera)
        let state = Self.capturePickerState(cameraAvailable: cameraAvailable)
        showCameraPicker = state.showCameraPicker
        showPhotoLibrary = state.showPhotoLibrary
    }

    @MainActor
    private func loadPhotoItem(
        _ item: PhotosPickerItem? = nil,
        loadTransferable: (() async throws -> Data?)? = nil,
        processCapturedImageAction: ((UIImage) async -> Void)? = nil
    ) async {
        do {
            let data: Data?
            if let loadTransferable {
                data = try await loadTransferable()
            } else {
                data = try await loadDefaultPhotoTransferable(item: item)
            }
            guard let data,
                  let image = UIImage(data: data) else {
                captureError = String(localized: "error.media.selected_image_load")
                return
            }
            if let processCapturedImageAction {
                await processCapturedImageAction(image)
            } else {
                await processCapturedImage(image)
            }
            selectedPhotoItem = nil
        } catch {
            captureError = error.localizedDescription
            selectedPhotoItem = nil
        }
    }

    private func loadDefaultPhotoTransferable(
        item: PhotosPickerItem?
    ) async throws -> Data? {
        try await item?.loadTransferable(type: Data.self)
    }

    @MainActor
    private func processCapturedImage(
        _ image: UIImage,
        analyzePhoto: ((UIImage, Date) async -> NutritionPhotoAnalysis)? = nil
    ) async {
        capturedImage = image
        captureError = nil
        analysisResult = nil
        photoAnalysis = nil
        analysisNotice = nil
        isAnalyzing = true

        let analysis = await analyzeCapturedPhoto(
            image,
            loggedAt: loggedAt,
            analyzer: analyzePhoto
        )
        analysisResult = analysis.summary
        analysisConfidence = analysis.confidence
        photoAnalysis = analysis
        analysisNotice = analysis.notice

        isAnalyzing = false
    }

    @MainActor
    private func analyzeCapturedPhoto(
        _ image: UIImage,
        loggedAt: Date,
        analyzer: ((UIImage, Date) async -> NutritionPhotoAnalysis)? = nil
    ) async -> NutritionPhotoAnalysis {
        if let analyzer {
            return await analyzer(image, loggedAt)
        }
        return await MediaRecognitionService.analyzeNutritionPhoto(image, loggedAt: loggedAt)
    }
}

// MARK: - Barcode Scanner View (with CIS Label OCR Fallback)

struct NutritionBarcodeScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scannedCode: String?
    @State private var isSearching = false
    @State private var isSaving = false
    @State private var isAnalyzingLabel = false
    @State private var productFound = false
    @State private var showLabelOCRFallback = false
    @State private var ocrResult: String?
    @State private var showCameraPicker = false
    @State private var showPhotoLibrary = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var errorMessage: String?
    @State private var matchedProduct: FoodSearchResult?
    @State private var pendingLabelImages: [UIImage] = []
    @State private var labelReviewDraft: NutritionLabelReviewDraft?
    private let catalogService = NutritionCatalogService()
    let targetDay: String
    let loggedAt: Date
    let onLogged: () -> Void
    let onResult: (NutritionLogDraft) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.m) {
                if labelReviewDraft != nil {
                    NutritionLabelReviewFormView(
                        draft: reviewDraftBinding(),
                        isSaving: isSaving,
                        isAnalyzing: isAnalyzingLabel,
                        errorMessage: errorMessage,
                        onRescan: beginCameraCapture,
                        onSave: beginConfirmReviewedProduct
                    )
                } else if showLabelOCRFallback {
                    VStack(spacing: Spacing.s) {
                        Label(String(localized: "nutrition_barcode_not_found"), systemImage: "exclamationmark.triangle")
                            .font(LifeOSTypography.headline)
                            .foregroundStyle(LifeOSColors.Recovery.caution)

                        Text(String(localized: "nutrition_label_ocr_prompt"))
                            .font(LifeOSTypography.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Button(String(localized: "nutrition_scan_label"), action: beginCameraCapture)
                        .buttonStyle(.borderedProminent)

                        if isAnalyzingLabel {
                            ProgressView(String(localized: "nutrition_analyzing_photo"))
                        }

                        if let ocrResult {
                            Text(ocrResult)
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)

                            Button(String(localized: "nutrition_review_product"), action: beginAnalyzePendingLabelImages)
                            .buttonStyle(.bordered)
                            .disabled(reviewProductDisabled())
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }
                    }
                } else if let scannedCode {
                    if isSearching {
                        ProgressView(String(localized: "nutrition_searching_barcode"))
                    } else if productFound {
                        VStack(spacing: Spacing.s) {
                            Text(String(format: String(localized: "nutrition_product_found_format"), scannedCode))
                                .font(LifeOSTypography.body)

                            if let matchedProduct {
                                VStack(spacing: Spacing.xxs) {
                                    Text(matchedProduct.name)
                                        .font(LifeOSTypography.headline)
                                    if !NutritionSafetyPolicy.hidesCalories {
                                        Text("\(matchedProduct.roundedCaloriesPer100g) kcal / 100g")
                                            .font(LifeOSTypography.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            Button(String(localized: "nutrition_add_product"), action: beginLogMatchedProduct)
                            .buttonStyle(.borderedProminent)
                            .disabled(isSaving)
                            .accessibilityIdentifier("nutrition.barcode.add_product")

                            if isSaving {
                                ProgressView(String(localized: "nutrition_save_product_progress"))
                            }
                        }
                    } else {
                        Text(String(localized: "nutrition_barcode_no_match"))
                            .font(LifeOSTypography.body)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: Spacing.s) {
                        Image(systemName: "barcode.viewfinder")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text(String(localized: "nutrition_scan_barcode_prompt"))
                            .font(LifeOSTypography.body)
                            .foregroundStyle(.secondary)
                        Button(String(localized: "nutrition_start_scan"), action: beginCameraCapture)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("nutrition.barcode.start_scan")

                        Button(String(localized: "nutrition_choose_photo"), action: openPhotoLibraryPicker)
                        .buttonStyle(.bordered)

                        if let errorMessage {
                            Text(errorMessage)
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
            }
            .padding(LayoutConstants.contentPadding)
            .accessibilityIdentifier("nutrition.barcode.screen")
            .navigationTitle(String(localized: "nutrition_barcode_title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: dismissScreen) {
                        Text(String(localized: "cancel"))
                    }
                }
            }
            .sheet(isPresented: $showCameraPicker, content: cameraPickerSheet)
            .photosPicker(
                isPresented: $showPhotoLibrary,
                selection: $selectedPhotoItem,
                matching: .images
            )
            .task(id: selectedPhotoItem, handleSelectedPhotoItemChange)
        }
    }

    private func beginCameraCapture() {
        openCameraOrLibrary()
    }

    private func cameraPickerSheet() -> some View {
        SystemImagePicker(
            sourceType: .camera,
            onImagePicked: handlePickedCameraImage
        )
    }

    private func openPhotoLibraryPicker() {
        showPhotoLibrary = true
    }

    private func dismissScreen() {
        performDismiss()
    }

    private func performDismiss(
        dismissAction: (() -> Void)? = nil
    ) {
        let handleDismiss = dismissAction ?? { dismiss() }
        handleDismiss()
    }

    private func beginConfirmReviewedProduct() {
        Task { await confirmReviewedProduct() }
    }

    private func beginAnalyzePendingLabelImages() {
        Task { await analyzePendingLabelImages() }
    }

    private func beginLogMatchedProduct() {
        Task { await logMatchedProduct() }
    }

    private func handlePickedCameraImage(_ image: UIImage) {
        handleCapturedCameraImage(image)
    }

    private func handleCapturedCameraImage(
        _ image: UIImage,
        processScannedImageAction: ((UIImage) async -> Void)? = nil
    ) {
        Task {
            if let processScannedImageAction {
                await processScannedImageAction(image)
            } else {
                await processScannedImage(image)
            }
        }
    }

    @MainActor
    private func handleSelectedPhotoItemChange() async {
        await loadSelectedPhotoItemIfNeeded(
            item: selectedPhotoItem,
            shouldLoad: selectedPhotoItem != nil
        )
    }

    private func reviewDraftBinding() -> Binding<NutritionLabelReviewDraft> {
        Binding(
            get: { labelReviewDraft ?? fallbackDraft },
            set: { labelReviewDraft = $0 }
        )
    }

    private func reviewProductDisabled() -> Bool {
        isAnalyzingLabel || pendingLabelImages.isEmpty
    }

    @MainActor
    private func loadSelectedPhotoItemIfNeeded(
        item: PhotosPickerItem?,
        shouldLoad: Bool,
        loadPhotoItemAction: ((PhotosPickerItem?) async -> Void)? = nil
    ) async {
        guard shouldLoad else { return }
        if let loadPhotoItemAction {
            await loadPhotoItemAction(item)
        } else if let item {
            await loadPhotoItem(item)
        }
    }

    private static func capturePickerState(cameraAvailable: Bool) -> (
        showCameraPicker: Bool,
        showPhotoLibrary: Bool
    ) {
        if cameraAvailable {
            return (showCameraPicker: true, showPhotoLibrary: false)
        }
        return (showCameraPicker: false, showPhotoLibrary: true)
    }

    private func openCameraOrLibrary(
        cameraAvailableProvider: (() -> Bool)? = nil
    ) {
        let cameraAvailable = cameraAvailableProvider?()
            ?? UIImagePickerController.isSourceTypeAvailable(.camera)
        let state = Self.capturePickerState(cameraAvailable: cameraAvailable)
        showCameraPicker = state.showCameraPicker
        showPhotoLibrary = state.showPhotoLibrary
    }

    @MainActor
    private func loadPhotoItem(
        _ item: PhotosPickerItem? = nil,
        loadTransferable: (() async throws -> Data?)? = nil,
        routeSelectedImageAction: ((UIImage) async -> Void)? = nil
    ) async {
        do {
            let data: Data?
            if let loadTransferable {
                data = try await loadTransferable()
            } else {
                data = try await loadDefaultPhotoTransferable(item: item)
            }
            guard let data,
                  let image = UIImage(data: data) else {
                errorMessage = String(localized: "error.media.selected_image_load")
                return
            }
            if let routeSelectedImageAction {
                await routeSelectedImageAction(image)
            } else {
                await routeSelectedImage(image)
            }
            selectedPhotoItem = nil
        } catch {
            errorMessage = error.localizedDescription
            selectedPhotoItem = nil
        }
    }

    private func loadDefaultPhotoTransferable(
        item: PhotosPickerItem?
    ) async throws -> Data? {
        try await item?.loadTransferable(type: Data.self)
    }

    @MainActor
    private func routeSelectedImage(
        _ image: UIImage,
        processLabelImageAction: ((UIImage) async -> Void)? = nil,
        processScannedImageAction: ((UIImage) async -> Void)? = nil
    ) async {
        if showLabelOCRFallback || labelReviewDraft != nil {
            if let processLabelImageAction {
                await processLabelImageAction(image)
            } else {
                await processLabelImage(image)
            }
        } else {
            if let processScannedImageAction {
                await processScannedImageAction(image)
            } else {
                await processScannedImage(image)
            }
        }
    }

    @MainActor
    private func processScannedImage(
        _ image: UIImage,
        detectBarcodes: ((UIImage) async throws -> [String])? = nil,
        recognizeText: ((UIImage) async throws -> String)? = nil,
        lookupBarcode: ((String) async throws -> FoodSearchResult?)? = nil
    ) async {
        let detect = detectBarcodes ?? detectImageBarcodes
        let recognize = recognizeText ?? recognizeImageText
        let lookup = lookupBarcode ?? { barcode in
            try await lookupProduct(barcode: barcode)
        }
        isSearching = true
        errorMessage = nil
        ocrResult = nil
        showLabelOCRFallback = false
        matchedProduct = nil
        labelReviewDraft = nil
        pendingLabelImages = []

        do {
            let codes = try await detect(image)
            if let code = codes.first {
                scannedCode = code
                matchedProduct = try await lookup(code)
                productFound = matchedProduct != nil
                showLabelOCRFallback = matchedProduct == nil
                if matchedProduct == nil {
                    pendingLabelImages = [image]
                    let text = try await recognize(image)
                    ocrResult = text.isEmpty ? String(localized: "nutrition_barcode_review_label_manually") : text
                }
                isSearching = false
                return
            }

            let text = try await recognize(image)
            scannedCode = nil
            productFound = false
            showLabelOCRFallback = true
            pendingLabelImages = [image]
            ocrResult = text.isEmpty ? String(localized: "nutrition_barcode_no_barcode_detected") : text
        } catch {
            errorMessage = error.localizedDescription
        }

        isSearching = false
    }

    @MainActor
    private func processLabelImage(
        _ image: UIImage,
        recognizeText: ((UIImage) async throws -> String)? = nil,
        analyzePendingLabelImagesAction: (() async -> Void)? = nil
    ) async {
        let recognize = recognizeText ?? { image in
            try await MediaRecognitionService.recognizeText(in: image)
        }
        let analyze = analyzePendingLabelImagesAction ?? {
            await analyzePendingLabelImages()
        }
        errorMessage = nil
        pendingLabelImages = Array((pendingLabelImages + [image]).suffix(2))

        if let text = try? await recognize(image),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ocrResult = text
        }

        await analyze()
    }

    @MainActor
    private func analyzePendingLabelImages(
        analyzeFoodLabelDraft: (([UIImage], String?) async -> NutritionLabelReviewDraft)? = nil
    ) async {
        let analyze = analyzeFoodLabelDraft ?? { images, barcodeHint in
            await MediaRecognitionService.analyzeFoodLabelDraft(from: images, barcodeHint: barcodeHint)
        }
        guard !pendingLabelImages.isEmpty else { return }
        isAnalyzingLabel = true
        errorMessage = nil
        defer { isAnalyzingLabel = false }

        let draft = await analyze(pendingLabelImages, scannedCode)
        labelReviewDraft = draft
    }

    private func lookupProduct(
        barcode: String,
        lookupBarcode: ((String) async throws -> FoodSearchResult?)? = nil
    ) async throws -> FoodSearchResult? {
        let lookup = lookupBarcode ?? { barcode in
            try await catalogService.lookupBarcode(barcode)
        }
        return try await lookup(barcode)
    }

    @MainActor
    private func logMatchedProduct(
        logSearchResult: ((FoodSearchResult, NutritionInputMethod, String, Date) async throws -> UUID)? = nil,
        onLoggedAction: (() -> Void)? = nil,
        dismissAction: (() -> Void)? = nil
    ) async {
        guard let matchedProduct else { return }
        let log = logSearchResult ?? defaultLogMatchedProduct
        let handleLogged = onLoggedAction ?? onLogged
        let handleDismiss = dismissAction ?? { dismiss() }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            _ = try await log(matchedProduct, .barcode, targetDay, loggedAt)
            handleLogged()
            handleDismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func defaultLogMatchedProduct(
        _ result: FoodSearchResult,
        method: NutritionInputMethod,
        targetDay: String,
        loggedAt: Date
    ) async throws -> UUID {
        try await QuickFoodLogService().logSearchResult(
            result,
            method: method,
            targetDay: targetDay,
            loggedAt: loggedAt
        )
    }

    private func detectImageBarcodes(
        _ image: UIImage
    ) async throws -> [String] {
        try await MediaRecognitionService.detectBarcodes(in: image)
    }

    private func recognizeImageText(
        _ image: UIImage
    ) async throws -> String {
        try await MediaRecognitionService.recognizeText(in: image)
    }

    @MainActor
    private func confirmReviewedProduct(
        createReviewedFood: ((NutritionLabelReviewDraft) async throws -> FoodSearchResult)? = nil,
        onResultAction: ((NutritionLogDraft) -> Void)? = nil,
        dismissAction: (() -> Void)? = nil
    ) async {
        guard let labelReviewDraft else { return }
        let createFood = createReviewedFood ?? { review in
            try await catalogService.createReviewedFood(review: review)
        }
        let handleResult = onResultAction ?? onResult
        let handleDismiss = dismissAction ?? { dismiss() }
        if let validationError = validate(review: labelReviewDraft) {
            errorMessage = validationError
            return
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let result = try await createFood(labelReviewDraft)
            let draft = labelReviewDraft.makeLogDraft(
                from: result,
                targetDay: targetDay,
                loggedAt: loggedAt
            )
            handleResult(draft)
            handleDismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func validate(review: NutritionLabelReviewDraft) -> String? {
        if review.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "nutrition_validation_name_required")
        }
        if review.servingSizeG <= 0 {
            return String(localized: "nutrition_validation_weight_positive")
        }
        if review.caloriesPer100g < 0 ||
            review.proteinPer100g < 0 ||
            review.fatPer100g < 0 ||
            review.carbsPer100g < 0 ||
            review.fiberPer100g < 0 {
            return "Nutrition values must be zero or greater."
        }
        return nil
    }

    private var fallbackDraft: NutritionLabelReviewDraft {
        NutritionLabelReviewDraft(
            name: String(localized: "nutrition_default_item_name"),
            servingSizeG: 100,
            caloriesPer100g: 0,
            proteinPer100g: 0,
            fatPer100g: 0,
            carbsPer100g: 0,
            confidence: nil,
            analysisSource: .onDeviceFallback
        )
    }
}

struct NutritionLabelReviewFormView: View {
    @Binding var draft: NutritionLabelReviewDraft
    let isSaving: Bool
    let isAnalyzing: Bool
    let errorMessage: String?
    let onRescan: () -> Void
    let onSave: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Label(String(localized: "nutrition_review_product"), systemImage: "checklist")
                    .font(LifeOSTypography.headline)

                Text(String(localized: "nutrition_label_ocr_prompt"))
                    .font(LifeOSTypography.body)
                    .foregroundStyle(.secondary)

                if !draft.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(String(localized: "nutrition_photo_review_notes_title"))
                            .font(LifeOSTypography.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(draft.warnings, id: \.self, content: warningRow)
                    }
                    .padding(Spacing.s)
                    .background(LifeOSColors.Surface.card)
                    .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
                }

                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(String(localized: "nutrition_recipe_info"))
                        .font(LifeOSTypography.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    TextField(String(localized: "nutrition_item_name"), text: $draft.name)
                        .textInputAutocapitalization(.words)
                    TextField(String(localized: "nutrition_brand"), text: $draft.brand)
                        .textInputAutocapitalization(.words)
                    TextField(String(localized: "nutrition_barcode"), text: $draft.barcode)
                        .keyboardType(.numberPad)
                    numericField(String(localized: "nutrition_portion_weight_g"), value: $draft.servingSizeG)
                }
                .padding(Spacing.s)
                .background(LifeOSColors.Surface.card)
                .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))

                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(String(localized: "nutrition_macros"))
                        .font(LifeOSTypography.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if !NutritionSafetyPolicy.hidesCalories { numericField(String(localized: "nutrition_unit_kcal"), value: $draft.caloriesPer100g) }
                    HStack(spacing: Spacing.s) {
                        numericField(String(localized: "nutrition_macro_label_protein"), value: $draft.proteinPer100g)
                        numericField(String(localized: "nutrition_macro_label_fat"), value: $draft.fatPer100g)
                    }
                    HStack(spacing: Spacing.s) {
                        numericField(String(localized: "nutrition_macro_label_carbs"), value: $draft.carbsPer100g)
                        numericField(String(localized: "nutrition_macro_label_fiber"), value: $draft.fiberPer100g)
                    }
                }
                .padding(Spacing.s)
                .background(LifeOSColors.Surface.card)
                .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))

                if let sourceText = draft.sourceText,
                   !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(String(localized: "notes"))
                            .font(LifeOSTypography.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(sourceText)
                            .font(LifeOSTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(Spacing.s)
                    .background(LifeOSColors.Surface.card)
                    .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.red)
                }

                if isAnalyzing {
                    ProgressView(String(localized: "nutrition_analyzing_photo"))
                }

                HStack(spacing: Spacing.s) {
                    Button(String(localized: "nutrition_scan_label"), action: onRescan)
                        .buttonStyle(.bordered)
                    Button(String(localized: "save"), action: onSave)
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving || isAnalyzing)
                }

                if isSaving {
                    ProgressView(String(localized: "nutrition_save_product_progress"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func numericField(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(LifeOSTypography.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(
                title,
                value: value,
                format: .number.precision(.fractionLength(0...1))
            )
            .keyboardType(.decimalPad)
            .textFieldStyle(.roundedBorder)
        }
    }

    private func warningRow(_ warning: String) -> some View {
        Text(warning)
            .font(LifeOSTypography.caption)
            .foregroundStyle(LifeOSColors.Recovery.caution)
    }
}

private extension NutritionPhotoCaptureView {
    @MainActor
    func loadSelectedPhotoItemIfPresent(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        await loadPhotoItem(item)
    }
}

// MARK: - Voice Input View

struct NutritionVoiceInputView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speechRecognizer = NutritionSpeechRecognizer()
    @State private var pendingResolution: NutritionVoiceResolution?
    @State private var clarificationAnswers: [String: String] = [:]
    @State private var isResolving = false
    let targetDay: String
    let loggedAt: Date
    let onResult: (NutritionLogDraft) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let pendingResolution,
                   let response = pendingResolution.response,
                   !response.clarifyingQuestions.isEmpty {
                    clarificationContent(
                        resolution: pendingResolution,
                        questions: response.clarifyingQuestions
                    )
                } else {
                    recordingContent
                }
            }
            .padding(LayoutConstants.contentPadding)
            .navigationTitle(String(localized: "nutrition_voice_title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel"), action: dismiss.callAsFunction)
                }
            }
            .onDisappear { stopRecordingOnDisappear() }
        }
    }

    private var recordingContent: some View {
        VStack(spacing: Spacing.m) {
            Spacer()

            Image(systemName: speechRecognizer.isRecording ? "mic.fill" : "mic")
                .font(.system(size: 64))
                .foregroundStyle(speechRecognizer.isRecording ? .red : LifeOSColors.Semantic.primary)
                .symbolEffect(.pulse, isActive: speechRecognizer.isRecording)

            if speechRecognizer.isProcessing || isResolving {
                ProgressView(String(localized: "nutrition_processing_voice"))
            } else if !speechRecognizer.transcription.isEmpty {
                Text(speechRecognizer.transcription)
                    .font(LifeOSTypography.body)
                    .padding(Spacing.m)
                    .background(LifeOSColors.Surface.card)
                    .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))

                Button(String(localized: "nutrition_use_voice_result")) {
                    Task { await useVoiceResult() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("nutrition.voice.use_result")
            } else {
                Text(speechRecognizer.isRecording
                    ? String(localized: "nutrition_listening")
                    : String(localized: "nutrition_voice_prompt"))
                    .font(LifeOSTypography.body)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = speechRecognizer.errorMessage {
                Text(errorMessage)
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button {
                Task { await toggleRecording() }
            } label: {
                Text(speechRecognizer.isRecording
                    ? String(localized: "nutrition_stop_recording")
                    : String(localized: "nutrition_start_recording"))
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.s)
            }
            .buttonStyle(.borderedProminent)
            .tint(speechRecognizer.isRecording ? .red : LifeOSColors.Semantic.primary)
        }
    }

    private func clarificationContent(
        resolution: NutritionVoiceResolution,
        questions: [FoodTextParseResponse.ClarifyingQuestion]
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(String(localized: "nutrition_voice_clarifications_title"))
                    .font(LifeOSTypography.title3)
                Text(String(localized: "nutrition_voice_clarifications_subtitle"))
                    .font(LifeOSTypography.body)
                    .foregroundStyle(.secondary)

                ForEach(questions, id: \.id) { question in
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text(question.question)
                            .font(LifeOSTypography.headline)

                        ForEach(question.options, id: \.self) { option in
                            Button {
                                clarificationAnswers[question.id] = option
                            } label: {
                                HStack {
                                    Text(option)
                                    Spacer()
                                    if clarificationAnswers[question.id] == option {
                                        Image(systemName: "checkmark.circle.fill")
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier(
                                "nutrition.voice.clarification.\(question.id).\(option)"
                            )
                        }

                        TextField(
                            String(localized: "nutrition_voice_clarification_custom"),
                            text: clarificationBinding(for: question.id)
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                    .padding(Spacing.m)
                    .background(LifeOSColors.Surface.card)
                    .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
                }

                Button(String(localized: "nutrition_voice_apply_clarifications")) {
                    Task { await applyClarifications(questions) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isResolving)
                .accessibilityIdentifier("nutrition.voice.clarifications.apply")

                Button(String(localized: "nutrition_voice_review_without_answers")) {
                    finishVoiceResult(resolution.draft)
                }
                .buttonStyle(.bordered)
                .disabled(isResolving)
            }
        }
        .accessibilityIdentifier("nutrition.voice.clarifications")
    }

    private func clarificationBinding(for id: String) -> Binding<String> {
        Binding(
            get: { clarificationAnswers[id] ?? "" },
            set: { clarificationAnswers[id] = $0 }
        )
    }

    private func useVoiceResult(
        resolveDraftAction: ((String, Double?, String, Date) async -> NutritionLogDraft)? = nil,
        onResultAction: ((NutritionLogDraft) -> Void)? = nil,
        dismissAction: (() -> Void)? = nil
    ) async {
        isResolving = true
        defer { isResolving = false }
        if let resolveDraftAction {
            let draft = await resolveDraftAction(
                speechRecognizer.transcription,
                speechRecognizer.confidence,
                targetDay,
                loggedAt
            )
            finishVoiceResult(
                draft,
                onResultAction: onResultAction,
                dismissAction: dismissAction
            )
        } else {
            let resolution = await NutritionDraftResolver().resolveVoiceResolution(
                transcription: speechRecognizer.transcription,
                confidence: speechRecognizer.confidence,
                targetDay: targetDay,
                loggedAt: loggedAt
            )
            if let response = resolution.response,
               response.needsClarification,
               !response.clarifyingQuestions.isEmpty {
                pendingResolution = resolution
                clarificationAnswers = [:]
            } else {
                finishVoiceResult(
                    resolution.draft,
                    onResultAction: onResultAction,
                    dismissAction: dismissAction
                )
            }
        }
    }

    private func applyClarifications(
        _ questions: [FoodTextParseResponse.ClarifyingQuestion]
    ) async {
        isResolving = true
        defer { isResolving = false }
        let answered = questions.compactMap { question -> String? in
            guard let answer = clarificationAnswers[question.id]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !answer.isEmpty else {
                return nil
            }
            return "\(question.itemName ?? question.question): \(answer)"
        }
        guard !answered.isEmpty else {
            if let draft = pendingResolution?.draft {
                finishVoiceResult(draft)
            }
            return
        }
        let clarifiedText = [
            speechRecognizer.transcription,
            String(localized: "nutrition_voice_clarifications_context") + " " + answered.joined(separator: "; "),
        ].joined(separator: ". ")
        let draft = await NutritionDraftResolver().resolveVoiceDraft(
            transcription: clarifiedText,
            confidence: speechRecognizer.confidence,
            targetDay: targetDay,
            loggedAt: loggedAt
        )
        finishVoiceResult(draft)
    }

    private func finishVoiceResult(
        _ draft: NutritionLogDraft,
        onResultAction: ((NutritionLogDraft) -> Void)? = nil,
        dismissAction: (() -> Void)? = nil
    ) {
        (onResultAction ?? onResult)(draft)
        (dismissAction ?? { dismiss() })()
    }

    private func toggleRecording(
        startRecordingAction: (() async -> Void)? = nil,
        stopRecordingAction: (() async -> Void)? = nil
    ) async {
        if speechRecognizer.isRecording {
            if let stopRecordingAction {
                await stopRecordingAction()
            } else {
                await speechRecognizer.stopRecording()
            }
        } else if let startRecordingAction {
            await startRecordingAction()
        } else {
            await speechRecognizer.startRecording()
        }
    }

    private func stopRecordingOnDisappear(
        stopRecordingAction: (() async -> Void)? = nil
    ) {
        Task {
            if let stopRecordingAction {
                await stopRecordingAction()
            } else {
                await speechRecognizer.stopRecording()
            }
        }
    }

}

// MARK: - Test support extensions (co-located with their types)
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
