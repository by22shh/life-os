import SwiftUI
import ComposableArchitecture
import CryptoKit
import GRDB
import PhotosUI
import UniformTypeIdentifiers

@MainActor
struct LabsOverviewView: View {
    let store: StoreOf<LabsFeature>
    @State private var showScanCapture = false

    private var aiAvailability: AIAvailability {
        AIAvailability()
    }

    private var isLabOcrAvailable: Bool {
        aiAvailability.labOcrAvailable
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Label(String(localized: "labs_overview_title"), systemImage: "waveform.path.ecg")
                    .font(LifeOSTypography.title3)

                if store.isLoading && store.summary == nil && store.scanHistory.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, Spacing.s)
                } else {
                    summarySection
                    scanCallToAction
                    historySections
                }
            }
            .padding(.top, Spacing.m)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(LayoutConstants.contentPadding)
        .accessibilityIdentifier("labs.overview.screen")
        .background(LifeOSColors.Surface.background)
        .navigationTitle(String(localized: "labs_overview_title"))
        .toolbar {
            if isLabOcrAvailable {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showScanCapture = true
                    } label: {
                        Image(systemName: "doc.text.viewfinder")
                    }
                    .accessibilityLabel(String(localized: "labs_scan_button"))
                }
            }
        }
        .sheet(isPresented: $showScanCapture, onDismiss: handleCaptureDismiss) {
            LabsScanCaptureView()
        }
        .refreshable {
            store.send(.task)
        }
        .onAppear(perform: handleAppear)
        .refreshOnFeatureFlagChanges()
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let summary = store.summary {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(summary.primaryText)
                        .font(LifeOSTypography.body.weight(.semibold))
                    if let secondary = summary.secondaryText {
                        Text(secondary)
                            .font(LifeOSTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(summary.accessibilitySummary)
            } else {
                Text(String(localized: "labs_overview_empty_title"))
                    .font(LifeOSTypography.body.weight(.semibold))
                Text(String(localized: "labs_overview_empty_subtitle"))
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
            }

            if let metrics = store.metrics {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.s), count: 2),
                    spacing: Spacing.s
                ) {
                    metricCard(title: String(localized: "labs_overview_metric_saved_scans"), value: "\(metrics.totalScanCount)")
                    metricCard(title: String(localized: "labs_overview_metric_markers"), value: "\(metrics.totalMarkerCount)")
                    metricCard(title: String(localized: "labs_overview_metric_needs_review"), value: "\(metrics.reviewRequiredCount)")
                    metricCard(title: String(localized: "labs_overview_metric_pinned"), value: "\(metrics.pinnedCount)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
    }

    private var scanCallToAction: some View {
        Group {
            if isLabOcrAvailable {
                Button {
                    showScanCapture = true
                } label: {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: "doc.text.viewfinder")
                            .font(.title3)
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(String(localized: "labs_scan_button"))
                                .font(LifeOSTypography.body.weight(.semibold))
                            Text(String(localized: "labs_overview_scan_cta_subtitle"))
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.m)
                    .background(LifeOSColors.Semantic.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
                }
                .buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(String(localized: "labs_scan_button"))
                        .font(LifeOSTypography.body.weight(.semibold))
                    Text(
                        NSLocalizedString(
                            "labs_scan_rollout_unavailable",
                            value: "Lab scan OCR is temporarily unavailable right now.",
                            comment: "Labs scan rollout disabled message"
                        )
                    )
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.m)
                .background(LifeOSColors.Surface.card)
                .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
            }
        }
    }

    @ViewBuilder
    private var historySections: some View {
        let reviewItems = store.scanHistory.filter(\.needsReview)
        let pinnedItems = store.scanHistory.filter { $0.isPinned && !$0.needsReview }
        let recentItems = store.scanHistory.filter { !$0.needsReview && !$0.isPinned }

        if store.scanHistory.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(String(localized: "labs_overview_history_title"))
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                Text(String(localized: "labs_overview_history_empty"))
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.m)
            .background(LifeOSColors.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
        } else {
            historySection(
                title: String(localized: "labs_overview_section_needs_review"),
                subtitle: String(localized: "labs_overview_section_needs_review_subtitle"),
                items: reviewItems
            )
            historySection(
                title: String(localized: "labs_overview_section_pinned"),
                subtitle: String(localized: "labs_overview_section_pinned_subtitle"),
                items: pinnedItems
            )
            historySection(
                title: String(localized: "labs_overview_section_recent"),
                subtitle: String(localized: "labs_overview_section_recent_subtitle"),
                items: recentItems
            )
        }
    }

    @ViewBuilder
    private func historySection(
        title: String,
        subtitle: String,
        items: [LabScanHistoryItem]
    ) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title)
                        .font(LifeOSTypography.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)
                }

                LazyVStack(spacing: Spacing.s) {
                    ForEach(items) { item in
                        NavigationLink {
                            LabScanDetailView(scanId: item.id)
                        } label: {
                            historyRow(item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func historyRow(_ item: LabScanHistoryItem) -> some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: scanIconName(for: item))
                .font(.title3)
                .foregroundStyle(scanStatusTint(for: item))
                .frame(width: LayoutConstants.minTouchTarget, height: LayoutConstants.minTouchTarget)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xxs) {
                    Text(item.title)
                        .font(LifeOSTypography.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(LifeOSColors.Semantic.primary)
                    }
                }

                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: Spacing.xs) {
                    historyPill(text: item.statusText, tint: scanStatusTint(for: item))
                    historyPill(
                        text: LabsLocalizedText.markersCountSummary(item.markerCount),
                        tint: LifeOSColors.Semantic.primary
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.accessibilitySummary)
        .accessibilityIdentifier("labs.history.\(item.id.uuidString)")
    }

    private func metricCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title)
                .font(LifeOSTypography.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(LifeOSTypography.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.background)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private func historyPill(text: String, tint: Color) -> some View {
        Text(text)
            .font(LifeOSTypography.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }

    private func scanStatusTint(for item: LabScanHistoryItem) -> Color {
        if item.needsReview {
            return LifeOSColors.Recovery.caution
        }
        switch item.statusRawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case ScanStatus.completed.rawValue:
            return LifeOSColors.Recovery.ready
        case ScanStatus.failed.rawValue:
            return LifeOSColors.Recovery.critical
        case ScanStatus.processing.rawValue, ScanStatus.pending.rawValue:
            return LifeOSColors.Semantic.primary
        default:
            return LifeOSColors.Semantic.primary
        }
    }

    private func scanIconName(for item: LabScanHistoryItem) -> String {
        switch item.scanTypeRawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case ScanType.bloodTest.rawValue:
            return "drop.circle"
        case ScanType.inbody.rawValue:
            return "figure.arms.open"
        case ScanType.dexa.rawValue:
            return "bone"
        default:
            return "doc.text"
        }
    }

    private func handleAppear() {
        store.send(.task)
    }

    private func handleCaptureDismiss() {
        store.send(.task)
    }
}

#if DEBUG
extension LabsOverviewView {
    @MainActor
    func _testRunTaskAction() async {
        handleAppear()
    }

    @MainActor
    func _testEvaluateBodyAndHelpers() {
        _ = body
        _ = summarySection
        _ = scanCallToAction
        _ = historySections
        _ = metricCard(title: "Saved", value: "3")
        _ = historyPill(text: "Completed", tint: .blue)

        for item in store.scanHistory {
            _ = historySection(title: "Section", subtitle: "Subtitle", items: [item])
            _ = historyRow(item)
            _ = scanStatusTint(for: item)
            _ = scanIconName(for: item)
        }

        handleCaptureDismiss()
    }

    @MainActor
    func _testResolvedHistoryIcons() -> [String] {
        store.scanHistory.map { item in
            _ = scanStatusTint(for: item)
            return scanIconName(for: item)
        }
    }
}
#endif

// MARK: - Labs Scan Capture View (Photo/PDF → OCR)

@MainActor
struct LabsScanCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var captureMode: LabsCaptureMode = .photo
    @State private var isProcessing = false
    @State private var isSavingReview = false
    @State private var ocrText: String?
    @State private var extractedMarkers: [ExtractedLabMarker] = []
    @State private var showReview = false
    @State private var privacySettings: PrivacySettings?
    @State private var captureError: String?
    @State private var showCameraPicker = false
    @State private var showPhotoLibrary = false
    @State private var showPDFImporter = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var sourceFileHash: String?
    @State private var capturedAsset: CapturedLabAsset?
    @State private var captureConfidence = 0.55
    @State private var measuredDate = Date()
    @State private var reviewConfirmed = false
    @State private var duplicateScanIDs: [UUID] = []
    @State private var allowDuplicate = false

    private var isLabOcrAvailable: Bool {
        AIAvailability().labOcrAvailable
    }

    private var rolloutDisabledMessage: String {
        NSLocalizedString(
            "labs_scan_rollout_unavailable",
            value: "Lab scan OCR is temporarily unavailable right now.",
            comment: "Labs scan rollout disabled message"
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.m) {
                if let settings = privacySettings, settings.medicalScanLocalOnly {
                    Label(String(localized: "labs_privacy_local_only"), systemImage: "lock.shield")
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(LifeOSColors.Semantic.primary)
                        .padding(Spacing.s)
                        .background(LifeOSColors.Semantic.primary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
                }

                Picker(String(localized: "labs_capture_mode"), selection: $captureMode) {
                    Text(String(localized: "labs_photo")).tag(LabsCaptureMode.photo)
                    Text(String(localized: "labs_pdf")).tag(LabsCaptureMode.pdf)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, LayoutConstants.contentPadding)

                if !isLabOcrAvailable {
                    Text(rolloutDisabledMessage)
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()

                if isProcessing {
                    VStack(spacing: Spacing.s) {
                        ProgressView()
                        Text(String(localized: "labs_processing_ocr"))
                            .font(LifeOSTypography.body)
                            .foregroundStyle(.secondary)
                    }
                } else if let ocrText {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack {
                            Label(
                                String(format: String(localized: "labs_markers_found_format"), extractedMarkers.count),
                                systemImage: extractedMarkers.isEmpty ? "doc.text.magnifyingglass" : "checkmark.circle"
                            )
                            .font(LifeOSTypography.headline)
                            .foregroundStyle(extractedMarkers.isEmpty ? .secondary : LifeOSColors.Recovery.ready)
                            Spacer()
                            Text(String(localized: "labs_verify_with_original"))
                                .font(LifeOSTypography.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        ScrollView {
                            VStack(alignment: .leading, spacing: Spacing.s) {
                                Text(ocrText)
                                    .font(LifeOSTypography.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)

                                if !extractedMarkers.isEmpty {
                                    Divider()
                                    LazyVStack(alignment: .leading, spacing: Spacing.xxs) {
                                        ForEach(extractedMarkers) { marker in
                                            HStack {
                                                Text(marker.name)
                                                    .font(LifeOSTypography.body)
                                                Spacer()
                                                Text("\(marker.value) \(marker.unit)")
                                                    .font(LifeOSTypography.body.weight(.semibold))
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 200)
                    }
                    .padding(LayoutConstants.contentPadding)

                    Button(String(localized: "labs_review_results")) {
                        captureError = nil
                        showReview = true
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    VStack(spacing: Spacing.s) {
                        Image(systemName: captureMode == .photo ? "doc.text.viewfinder" : "doc.richtext")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text(captureMode == .photo
                            ? String(localized: "labs_photo_prompt")
                            : String(localized: "labs_pdf_prompt"))
                            .font(LifeOSTypography.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Button(captureMode == .photo
                            ? String(localized: "labs_take_photo")
                            : String(localized: "labs_select_pdf")) {
                            startCapture()
                        }
                        .buttonStyle(.borderedProminent)

                        if captureMode == .photo {
                            Button(String(localized: "nutrition_choose_photo")) {
                                showPhotoLibrary = true
                            }
                            .buttonStyle(.bordered)
                        }

                        if let captureError {
                            Text(captureError)
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }
                    }
                }

                Spacer()
            }
            .padding(LayoutConstants.contentPadding)
            .navigationTitle(String(localized: "labs_scan_title"))
            .interactiveDismissDisabled(isSavingReview)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) { dismiss() }
                        .disabled(isSavingReview)
                }
            }
            .sheet(isPresented: $showReview) {
                LabsReviewView(
                    markers: $extractedMarkers,
                    isSaving: isSavingReview,
                    errorMessage: captureError,
                    measuredDate: $measuredDate,
                    reviewConfirmed: $reviewConfirmed,
                    duplicateCount: duplicateScanIDs.count,
                    allowDuplicate: $allowDuplicate,
                    onKeepExisting: { showReview = false; dismiss() },
                    onSave: { await handleReviewSave() }
                )
            }
            .task { await loadPrivacySettings() }
            .sheet(isPresented: $showCameraPicker) {
                SystemImagePicker(sourceType: .camera) { image in
                    Task { await processImage(image, sourceData: image.jpegData(compressionQuality: 0.9)) }
                }
            }
            .photosPicker(
                isPresented: $showPhotoLibrary,
                selection: $selectedPhotoItem,
                matching: .images
            )
            .task(id: selectedPhotoItem) {
                guard let selectedPhotoItem else { return }
                await loadPhotoItem(selectedPhotoItem)
            }
            .fileImporter(
                isPresented: $showPDFImporter,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { await processPDF(at: url) }
                case .failure(let error):
                    captureError = error.localizedDescription
                }
            }
        }
    }

    private func startCapture() {
        captureError = nil
        capturedAsset = nil
        guard isLabOcrAvailable else {
            captureError = rolloutDisabledMessage
            return
        }

        if captureMode == .photo {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                showCameraPicker = true
            } else {
                showPhotoLibrary = true
            }
        } else {
            showPDFImporter = true
        }
    }

    @MainActor
    private func loadPrivacySettings() async {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }

        do {
            privacySettings = try await DatabaseManager.shared.dbQueue.read { db in
                try Self.loadScopedPrivacySettings(authId: authId, db: db)
            }
        } catch {
            privacySettings = nil
        }
    }

    @MainActor
    private func handleReviewSave() async {
        guard !isSavingReview, reviewConfirmed else { return }

        captureError = nil
        isSavingReview = true
        let didSave = await saveMarkers()
        isSavingReview = false

        guard didSave else { return }
        showReview = false
        dismiss()
    }

    @MainActor
    private func saveMarkers() async -> Bool {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        do {
            try await Self.persistMarkers(
                scanId: UUID(),
                now: Date(),
                authId: authId,
                dbQueue: DatabaseManager.shared.dbQueue,
                extractedMarkers: extractedMarkers,
                ocrText: ocrText,
                sourceFileHash: sourceFileHash,
                capturedAsset: capturedAsset,
                captureConfidence: captureConfidence,
                measuredDate: measuredDate,
                reviewConfirmed: reviewConfirmed,
                allowDuplicate: allowDuplicate
            )
            captureError = nil
            return true
        } catch LabsSaveError.duplicates(let ids) {
            duplicateScanIDs = ids
            captureError = String(localized: "labs_duplicate_saved_message")
            return false
        } catch {
            captureError = error.localizedDescription
            return false
        }
    }

    @MainActor
    private func loadPhotoItem(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                captureError = String(localized: "error.media.selected_image_load")
                return
            }
            await processImage(image, sourceData: data)
            selectedPhotoItem = nil
        } catch {
            captureError = error.localizedDescription
            selectedPhotoItem = nil
        }
    }

    @MainActor
    private func processImage(_ image: UIImage, sourceData: Data?) async {
        isProcessing = true
        captureError = nil
        sourceFileHash = sourceData.map(Self.sha256)
        capturedAsset = sourceData.map { CapturedLabAsset(data: $0, fileExtension: "jpg") }

        do {
            let text = try await MediaRecognitionService.recognizeText(in: image)
            ocrText = text
            extractedMarkers = LabsMarkerCatalog.extractMarkers(from: text)
            measuredDate = LabsMarkerCatalog.documentDate(from: text) ?? Date()
            reviewConfirmed = false
            allowDuplicate = false
            duplicateScanIDs = []
            captureConfidence = 0
        } catch {
            captureError = error.localizedDescription
        }

        isProcessing = false
    }

    @MainActor
    private func processPDF(at url: URL) async {
        isProcessing = true
        captureError = nil

        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: url)
            sourceFileHash = Self.sha256(data)
            capturedAsset = CapturedLabAsset(data: data, fileExtension: "pdf")
            let text = try await MediaRecognitionService.recognizeText(inPDFAt: url)
            ocrText = text
            extractedMarkers = LabsMarkerCatalog.extractMarkers(from: text)
            measuredDate = LabsMarkerCatalog.documentDate(from: text) ?? Date()
            reviewConfirmed = false
            allowDuplicate = false
            duplicateScanIDs = []
            captureConfidence = 0
        } catch {
            captureError = error.localizedDescription
        }

        isProcessing = false
    }

    nonisolated private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func resolveUserId(authId: String?, db: Database) throws -> UUID? {
        try UserIdentityLookup.resolveUserId(authId: authId, db: db)
    }

    nonisolated private static func loadScopedPrivacySettings(authId: String?, db: Database) throws -> PrivacySettings? {
        guard let userId = try resolveUserId(authId: authId, db: db) else {
            return nil
        }
        return try loadScopedPrivacySettings(userId: userId, db: db)
    }

    nonisolated private static func loadScopedPrivacySettings(userId: UUID, db: Database) throws -> PrivacySettings {
        if let settings = try PrivacySettings.fetchOne(
            db,
            sql: """
                SELECT *
                FROM privacy_settings
                WHERE user_id = ? OR user_id = ?
                ORDER BY updated_at DESC
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString]
        ) {
            return settings
        }

        // Privacy-first fallback: medical scans remain local unless this user explicitly opted into cloud storage.
        return PrivacySettings(userId: userId)
    }

    nonisolated private static func outboxHeadersJson() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
    }

    nonisolated private static func persistMarkers(
        scanId: UUID,
        now: Date,
        authId: String?,
        dbQueue: DatabaseQueue,
        extractedMarkers: [ExtractedLabMarker],
        ocrText: String?,
        sourceFileHash: String?,
        capturedAsset: CapturedLabAsset?,
        captureConfidence: Double,
        measuredDate: Date? = nil,
        reviewConfirmed: Bool = false,
        allowDuplicate: Bool = false
    ) async throws {
        guard !extractedMarkers.isEmpty, extractedMarkers.allSatisfy(LabsMarkerCatalog.isValidForSave) else {
            throw LabsSaveError.invalidMarkers
        }
        let resultDate = measuredDate ?? now
        let day = DiaryDateFormatter.formatDate(resultDate)
        let needsReview = !reviewConfirmed
        let scheduledDeletionAt = Calendar.current.date(byAdding: .day, value: 90, to: now)
        var storedAssetURLForCleanup: URL?

        do {
            let storedAssetURL = try capturedAsset.map { try LabScanAssetStore.persistAsset(scanId: scanId, asset: $0) }
            storedAssetURLForCleanup = storedAssetURL

            try await dbQueue.write { db in
                guard let userId = try Self.resolveUserId(authId: authId, db: db) else {
                    throw LabsSaveError.userUnavailable
                }
                // Check in the insertion transaction as well as in the review flow:
                // local-only/offline imports must have the same duplicate protection.
                let incoming = Set(extractedMarkers.map { LabsMarkerCatalog.markerIdentifier(for: $0.name) })
                let candidates = try MedicalScan.fetchAll(db, sql: """
                    SELECT * FROM medical_scans
                    WHERE (user_id = ? OR user_id = ?) AND deleted_at IS NULL
                      AND (scan_date = ? OR (source_file_sha256 IS NOT NULL AND source_file_sha256 = ?))
                    """, arguments: [userId, userId.uuidString, day, sourceFileHash])
                let duplicates = try candidates.filter { scan in
                    if let sourceFileHash, scan.sourceFileSha256 == sourceFileHash { return true }
                    let existing = try HealthMeasurement.fetchAll(db, sql: """
                        SELECT * FROM health_measurements WHERE medical_scan_id = ? OR source_scan_id = ?
                        """, arguments: [scan.id.uuidString, scan.id.uuidString])
                    let identifiers = Set(existing.map { LabsMarkerCatalog.markerIdentifier(for: $0.biomarkerName) })
                    return LabsMarkerCatalog.markerOverlap(incoming: incoming, existing: identifiers) >= 0.6
                }.map(\.id)
                if !duplicates.isEmpty && !allowDuplicate { throw LabsSaveError.duplicates(duplicates) }
                let privacySettings = try Self.loadScopedPrivacySettings(userId: userId, db: db)
                let status = needsReview ? ScanStatus.reviewRequired : ScanStatus.completed
                let documentLanguage = Locale.current.language.languageCode?.identifier ?? Locale.current.identifier
                let storageMode = privacySettings.medicalScanLocalOnly ? "local_only" : "cloud"
                let storeOriginalInCloud = privacySettings.medicalScanLocalOnly ? false : privacySettings.cloudBackupEnabled
                let imageURL = storedAssetURL.flatMap { capturedAsset?.isImage == true ? $0.absoluteString : nil }
                let originalImageURL = storedAssetURL?.absoluteString
                var measurementRecords: [HealthMeasurement] = []
                measurementRecords.reserveCapacity(extractedMarkers.count)

                for marker in extractedMarkers {
                    let reference = LabsMarkerCatalog.bounds(for: marker)
                    guard let markerValue = LabsMarkerCatalog.numericValue(marker.value) else { throw LabsSaveError.invalidMarkers }
                    let canonicalMarkerId = HealthMeasurement.canonicalMarkerId(
                        markerId: LabsMarkerCatalog.markerIdentifier(for: marker.name),
                        biomarkerName: marker.name,
                        originalLabel: marker.name
                    ) ?? LabsMarkerCatalog.markerIdentifier(for: marker.name)
                    let canonicalStatus = HealthMeasurementStatus.canonicalRawValue(
                            for: nil,
                            value: markerValue,
                            referenceRangeLow: reference.low,
                            referenceRangeHigh: reference.high
                        )
                    var measurementRecord = HealthMeasurement(
                        userId: userId,
                        biomarkerName: marker.name,
                        value: markerValue,
                        unit: marker.unit
                    )
                    measurementRecord.medicalScanId = scanId
                    measurementRecord.sourceScanId = scanId
                    measurementRecord.createdAt = now
                    measurementRecord.updatedAt = now
                    measurementRecord.markerId = canonicalMarkerId
                    measurementRecord.originalValue = markerValue
                    measurementRecord.originalUnit = marker.unit
                    measurementRecord.originalLabel = marker.name
                    measurementRecord.status = canonicalStatus
                    measurementRecord.referenceRangeLow = reference.low
                    measurementRecord.referenceRangeHigh = reference.high
                    measurementRecord.measuredAt = resultDate
                    measurementRecord.measuredDate = day
                    measurementRecord.sourceType = "scan"
                    // The recognition API returns text, not a calibrated confidence.
                    measurementRecord.confidence = nil
                    measurementRecord.userCorrected = false
                    measurementRecord.manuallyVerified = reviewConfirmed
                    measurementRecord.notes = marker.referenceRange
                    measurementRecords.append(measurementRecord)
                }
                let processedPayload = try? LabScanSyncPayloadBuilder.processedData(from: measurementRecords)
                var scanRecord = MedicalScan(id: scanId, userId: userId, scanType: .bloodTest)
                scanRecord.createdAt = now
                scanRecord.updatedAt = now
                scanRecord.status = status
                scanRecord.imageUrl = imageURL
                scanRecord.imageUploadedAt = nil
                scanRecord.originalImageUrl = originalImageURL
                scanRecord.aiConfidence = nil
                scanRecord.ocrConfidence = nil
                scanRecord.extractionStatus = status.rawValue
                scanRecord.markersExtracted = measurementRecords.count
                scanRecord.processedData = processedPayload
                scanRecord.needsReview = needsReview
                scanRecord.userReviewed = reviewConfirmed
                scanRecord.userReviewedAt = reviewConfirmed ? now : nil
                scanRecord.manuallyVerified = reviewConfirmed
                scanRecord.pinnedByUser = false
                scanRecord.scanDate = day
                scanRecord.documentLanguage = documentLanguage
                scanRecord.sourceFileSha256 = sourceFileHash
                scanRecord.storageMode = storageMode
                scanRecord.storeOriginalInCloud = storeOriginalInCloud
                scanRecord.scheduledDeletionAt = storedAssetURL == nil ? nil : scheduledDeletionAt
                scanRecord.notes = ocrText
                try scanRecord.insert(db)

                if storageMode != "local_only" {
                    var scanEvent = OutboxEvent(
                        id: scanId,
                        httpMethod: .POST,
                        path: "api-labs",
                        bodyJson: try LabScanSyncPayloadBuilder.buildBody(scan: scanRecord),
                        priority: 100
                    )
                    scanEvent.userVisibleBlocker = true
                    scanEvent.headersJson = try Self.outboxHeadersJson()
                    try scanEvent.insert(db)
                }

                for measurementRecord in measurementRecords {
                    try measurementRecord.insert(db)
                }
            }
        } catch {
            if let storedAssetURL = storedAssetURLForCleanup {
                try? FileManager.default.removeItem(at: storedAssetURL)
            }
            throw error
        }
    }

    enum LabsSaveError: LocalizedError {
        case userUnavailable
        case invalidMarkers
        case duplicates([UUID])

        var errorDescription: String? {
            switch self {
            case .userUnavailable: String(localized: "error.user.unavailable")
            case .invalidMarkers: String(localized: "labs_invalid_markers_message")
            case .duplicates: String(localized: "labs_duplicates_message")
            }
        }
    }
}

enum LabsCaptureMode: Hashable {
    case photo
    case pdf
}

struct ExtractedLabMarker: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var value: String
    var unit: String
    var referenceRange: String?
    var isNormal: Bool
}

#if DEBUG
extension LabsScanCaptureView {
    init(
        _testCaptureMode: LabsCaptureMode = .photo,
        _testIsProcessing: Bool = false,
        _testIsSavingReview: Bool = false,
        _testOCRText: String? = nil,
        _testExtractedMarkers: [ExtractedLabMarker] = [],
        _testShowReview: Bool = false,
        _testPrivacySettings: PrivacySettings? = nil,
        _testCaptureError: String? = nil,
        _testShowCameraPicker: Bool = false,
        _testShowPhotoLibrary: Bool = false,
        _testShowPDFImporter: Bool = false,
        _testSourceFileHash: String? = nil,
        _testCapturedAsset: CapturedLabAsset? = nil,
        _testCaptureConfidence: Double = 0.55
    ) {
        _captureMode = State(initialValue: _testCaptureMode)
        _isProcessing = State(initialValue: _testIsProcessing)
        _isSavingReview = State(initialValue: _testIsSavingReview)
        _ocrText = State(initialValue: _testOCRText)
        _extractedMarkers = State(initialValue: _testExtractedMarkers)
        _showReview = State(initialValue: _testShowReview)
        _privacySettings = State(initialValue: _testPrivacySettings)
        _captureError = State(initialValue: _testCaptureError)
        _showCameraPicker = State(initialValue: _testShowCameraPicker)
        _showPhotoLibrary = State(initialValue: _testShowPhotoLibrary)
        _showPDFImporter = State(initialValue: _testShowPDFImporter)
        _selectedPhotoItem = State(initialValue: nil)
        _sourceFileHash = State(initialValue: _testSourceFileHash)
        _capturedAsset = State(initialValue: _testCapturedAsset)
        _captureConfidence = State(initialValue: _testCaptureConfidence)
    }

    @MainActor
    func _testEvaluateBody() {
        _ = body
    }

    @MainActor
    func _testTriggerStartCapture() -> (
        showCameraPicker: Bool,
        showPhotoLibrary: Bool,
        showPDFImporter: Bool,
        captureError: String?
    ) {
        startCapture()
        return (
            _showCameraPicker.wrappedValue,
            _showPhotoLibrary.wrappedValue,
            _showPDFImporter.wrappedValue,
            _captureError.wrappedValue
        )
    }

    @MainActor
    func _testProcessImage(
        _ image: UIImage,
        sourceData: Data?
    ) async -> (
        ocrText: String?,
        markerCount: Int,
        captureError: String?,
        isProcessing: Bool,
        captureConfidence: Double,
        sourceFileHash: String?,
        capturedAssetExtension: String?
    ) {
        await processImage(image, sourceData: sourceData)
        return (
            _ocrText.wrappedValue,
            _extractedMarkers.wrappedValue.count,
            _captureError.wrappedValue,
            _isProcessing.wrappedValue,
            _captureConfidence.wrappedValue,
            _sourceFileHash.wrappedValue,
            _capturedAsset.wrappedValue?.fileExtension
        )
    }

    @MainActor
    func _testProcessPDF(
        at url: URL
    ) async -> (
        ocrText: String?,
        markerCount: Int,
        captureError: String?,
        isProcessing: Bool,
        captureConfidence: Double,
        sourceFileHash: String?,
        capturedAssetExtension: String?
    ) {
        await processPDF(at: url)
        return (
            _ocrText.wrappedValue,
            _extractedMarkers.wrappedValue.count,
            _captureError.wrappedValue,
            _isProcessing.wrappedValue,
            _captureConfidence.wrappedValue,
            _sourceFileHash.wrappedValue,
            _capturedAsset.wrappedValue?.fileExtension
        )
    }

    nonisolated static func _testSha256(_ data: Data) -> String {
        sha256(data)
    }

    nonisolated static func _testOutboxHeadersJson() throws -> Data {
        try outboxHeadersJson()
    }

    nonisolated static func _testPersistMarkers(
        scanId: UUID,
        now: Date,
        authId: String?,
        dbQueue: DatabaseQueue,
        extractedMarkers: [ExtractedLabMarker],
        ocrText: String?,
        sourceFileHash: String?,
        capturedAsset: CapturedLabAsset?,
        captureConfidence: Double,
        measuredDate: Date? = nil,
        reviewConfirmed: Bool = false,
        allowDuplicate: Bool = false
    ) async throws {
        try await persistMarkers(
            scanId: scanId,
            now: now,
            authId: authId,
            dbQueue: dbQueue,
            extractedMarkers: extractedMarkers,
            ocrText: ocrText,
            sourceFileHash: sourceFileHash,
            capturedAsset: capturedAsset,
            captureConfidence: captureConfidence,
            measuredDate: measuredDate,
            reviewConfirmed: reviewConfirmed,
            allowDuplicate: allowDuplicate
        )
    }

    nonisolated static func _testLoadScopedPrivacySettings(
        authId: String?,
        db: Database
    ) throws -> PrivacySettings? {
        try loadScopedPrivacySettings(authId: authId, db: db)
    }

    nonisolated static func _testLoadScopedPrivacySettings(
        userId: UUID,
        db: Database
    ) throws -> PrivacySettings {
        try loadScopedPrivacySettings(userId: userId, db: db)
    }
}
#endif

// MARK: - Labs Review & Normalization View

struct LabsReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var markers: [ExtractedLabMarker]
    let isSaving: Bool
    let errorMessage: String?
    var measuredDate: Binding<Date> = .constant(Date())
    var reviewConfirmed: Binding<Bool> = .constant(false)
    var duplicateCount: Int = 0
    var allowDuplicate: Binding<Bool> = .constant(false)
    var onKeepExisting: () -> Void = {}
    let onSave: @MainActor () async -> Void

    var body: some View {
        NavigationStack {
            List {
                Section(String(localized: "labs_review_section_header")) {
                    Text(String(localized: "labs_review_instructions"))
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)
                    DatePicker(String(localized: "labs_test_date_label"), selection: measuredDate, displayedComponents: .date)
                        .disabled(isSaving)
                    Text(String(localized: "labs_test_date_hint"))
                        .font(LifeOSTypography.caption)
                    Toggle(String(localized: "labs_review_confirmation_toggle"), isOn: reviewConfirmed)
                        .disabled(isSaving)
                }

                if duplicateCount > 0 {
                    Section(String.localizedStringWithFormat(String(localized: "labs_duplicate_section_format"), duplicateCount)) {
                        Button(String(localized: "labs_keep_existing_button"), action: onKeepExisting)
                            .disabled(isSaving)
                        Toggle(String(localized: "labs_save_as_separate_toggle"), isOn: allowDuplicate)
                            .disabled(isSaving)
                    }
                }

                if isSaving {
                    Section {
                        HStack(spacing: Spacing.s) {
                            ProgressView()
                            Text(String(localized: "loading"))
                                .font(LifeOSTypography.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage, !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .font(LifeOSTypography.caption)
                            .foregroundStyle(LifeOSColors.Semantic.destructive)
                    }
                }

                ForEach($markers) { $marker in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        // Marker Name (editable)
                        TextField(String(localized: "labs_marker_name"), text: $marker.name)
                            .font(LifeOSTypography.body.weight(.semibold))
                            .disabled(isSaving)

                        HStack(spacing: Spacing.s) {
                            // Value
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "labs_value"))
                                    .font(LifeOSTypography.caption2)
                                    .foregroundStyle(.secondary)
                                TextField("0", text: $marker.value)
                                    .textFieldStyle(.roundedBorder)
                                    .keyboardType(.decimalPad)
                                    .disabled(isSaving)
                            }

                            // Unit
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "labs_unit"))
                                    .font(LifeOSTypography.caption2)
                                    .foregroundStyle(.secondary)
                                TextField("mg/dL", text: Binding(
                                    get: { marker.unit },
                                    set: { newUnit in
                                        // A reference entered in the old unit cannot survive a unit edit.
                                        if LabsMarkerCatalog.normalizedUnit(newUnit) != LabsMarkerCatalog.normalizedUnit(marker.unit) {
                                            marker.referenceRange = nil
                                        }
                                        marker.unit = newUnit
                                    }
                                ))
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(isSaving)
                            }
                        }

                        // Reference Range
                        HStack {
                            Text(String(localized: "labs_reference_range"))
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.secondary)
                            TextField(String(localized: "labs_range_placeholder"), text: Binding(
                                get: { marker.referenceRange ?? "" },
                                set: { marker.referenceRange = $0.isEmpty ? nil : $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(LifeOSTypography.caption)
                            .disabled(isSaving)
                        }

                        // Normal indicator
                        HStack {
                            let normality = LabsMarkerCatalog.normality(for: marker)
                            Image(systemName: normality == true ? "checkmark.circle.fill" : "questionmark.circle")
                                .foregroundStyle(normality == true ? LifeOSColors.Recovery.ready : LifeOSColors.Recovery.caution)
                            Text(normality.map { $0
                                ? String(localized: "labs_within_range")
                                : String(localized: "labs_out_of_range") } ?? String(localized: "labs_no_confirmed_range"))
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, Spacing.xxs)
                }
                .onDelete { indices in markers.remove(atOffsets: indices) }
            }
            .onChange(of: markers) { _, _ in
                reviewConfirmed.wrappedValue = false
                allowDuplicate.wrappedValue = false
            }
            .onChange(of: measuredDate.wrappedValue) { _, _ in
                reviewConfirmed.wrappedValue = false
                allowDuplicate.wrappedValue = false
            }
            .navigationTitle(String(localized: "labs_review_title"))
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        markers.append(
                            ExtractedLabMarker(
                                id: UUID(),
                                name: "",
                                value: "",
                                unit: "",
                                referenceRange: nil,
                                isNormal: true
                            )
                        )
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await onSave() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text(String(localized: "save"))
                        }
                    }
                    .disabled(
                        isSaving ||
                        !reviewConfirmed.wrappedValue ||
                        markers.isEmpty ||
                        !markers.allSatisfy(LabsMarkerCatalog.isValidForSave) ||
                        (duplicateCount > 0 && !allowDuplicate.wrappedValue)
                    )
                }
            }
        }
    }
}

enum LabsMarkerCatalog {
    // Aliases identify markers only. Reference intervals depend on the laboratory,
    // method, age and sex; never infer them or units from a marker's name.
    private static let aliases: [String: [String]] = [
        "Hemoglobin": ["hemoglobin", "hgb", "гемоглобин"],
        "WBC": ["wbc", "white blood cells", "leukocytes", "лейкоциты"],
        "RBC": ["rbc", "red blood cells", "эритроциты"],
        "Platelets": ["platelets", "plt", "тромбоциты"],
        "Glucose": ["glucose", "глюкоза"],
        "Creatinine": ["creatinine", "креатинин"],
        "ALT": ["alt", "алт", "аланинаминотрансфераза"],
        "AST": ["ast", "аст", "аспартатаминотрансфераза"],
        "Ferritin": ["ferritin", "ферритин"],
        "TSH": ["tsh", "ттг", "тиреотропный гормон"],
        "Vitamin D": ["vitamin d", "25-oh vitamin d", "витамин d", "25-он витамин d"],
        "Vitamin B12": ["vitamin b12", "b12", "витамин b12", "витамин в12"],
        "HbA1c": ["hba1c", "hb a1c", "гликированный гемоглобин"],
        "CRP": ["crp", "c-reactive protein", "срб", "с-реактивный белок"]
    ]

    static func normalizedUnit(_ unit: String) -> String {
        let key = unit.lowercased().replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "μ", with: "µ")
        return [
            "mmol/l": "mmol/L", "ммоль/л": "mmol/L",
            "µmol/l": "µmol/L", "umol/l": "µmol/L", "мкмоль/л": "µmol/L",
            "mg/dl": "mg/dL", "мг/дл": "mg/dL",
            "mg/l": "mg/L", "мг/л": "mg/L",
            "g/l": "g/L", "г/л": "g/L", "g/dl": "g/dL", "г/дл": "g/dL",
            "ng/ml": "ng/mL", "нг/мл": "ng/mL",
            "pg/ml": "pg/mL", "пг/мл": "pg/mL",
            "u/l": "U/L", "ед/л": "U/L",
            "uiu/ml": "µIU/mL", "µiu/ml": "µIU/mL", "мкме/мл": "µIU/mL",
            "10^3/ul": "10^3/µL", "10^3/µl": "10^3/µL",
            "10^6/ul": "10^6/µL", "10^6/µl": "10^6/µL",
            "10^9/l": "10^9/L", "10^12/l": "10^12/L", "%": "%"
        ][key] ?? unit.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func numericValue(_ value: String) -> Double? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard normalized.range(of: #"^[+-]?\d+(?:\.\d+)?$"#, options: .regularExpression) != nil,
              let number = Double(normalized), number.isFinite else { return nil }
        return number
    }

    static func isValidForSave(_ marker: ExtractedLabMarker) -> Bool {
        !marker.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !marker.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        numericValue(marker.value) != nil &&
        (marker.referenceRange?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false ||
         bounds(for: marker).low != nil)
    }

    static func extractMarkers(from text: String) -> [ExtractedLabMarker] {
        // A comma inside a decimal is data, never a record separator.
        let lines = text.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ";")))
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)^([\p{L}][\p{L}\p{N} %()/+\-._]{0,80}?)[:\s]+([<>≤≥]?[+-]?\d+(?:[.,]\d+)?)\s*([\p{L}µμ%/^*×\p{N}⁰¹²³⁴⁵⁶⁷⁸⁹]+)?(?:\s+\(?([+-]?\d+(?:[.,]\d+)?\s*[-–—]\s*[+-]?\d+(?:[.,]\d+)?)\)?)?$"#
        ) else { return [] }
        var seen = Set<String>()
        return lines.compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let ns = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
            func field(_ index: Int) -> String? {
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            }
            guard let name = field(1), let value = field(2) else { return nil }
            var marker = ExtractedLabMarker(
                id: UUID(), name: canonicalName(for: name),
                value: value.replacingOccurrences(of: ",", with: "."),
                unit: normalizedUnit(field(3) ?? ""), referenceRange: field(4), isNormal: false
            )
            marker.isNormal = normality(for: marker) == true
            let key = "\(markerIdentifier(for: marker.name))|\(marker.value)|\(marker.unit)"
            guard seen.insert(key).inserted else { return nil }
            return marker
        }
    }

    static func canonicalName(for name: String) -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Exact matching prevents e.g. HbA1c from becoming hemoglobin.
        return aliases.first { $0.value.contains(normalized) }?.key ??
            name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func markerIdentifier(for name: String) -> String {
        canonicalName(for: name).lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
    }

    static func bounds(for marker: ExtractedLabMarker) -> (low: Double?, high: Double?) {
        guard !marker.unit.isEmpty, let text = marker.referenceRange,
              let regex = try? NSRegularExpression(pattern: #"^\s*([+-]?\d+(?:[.,]\d+)?)\s*[-–—]\s*([+-]?\d+(?:[.,]\d+)?)\s*$"#),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              let low = numericValue((text as NSString).substring(with: match.range(at: 1))),
              let high = numericValue((text as NSString).substring(with: match.range(at: 2))), low <= high else {
            return (nil, nil)
        }
        return (low, high)
    }

    static func normality(for marker: ExtractedLabMarker) -> Bool? {
        let range = bounds(for: marker)
        guard let value = numericValue(marker.value), let low = range.low, let high = range.high else { return nil }
        return value >= low && value <= high
    }

    static func documentDate(from text: String) -> Date? {
        // Only explicitly labelled collection/test dates, never an incidental birth date.
        let pattern = #"(?im)^\s*(?:дата(?:\s+(?:анализа|исследования|забора(?:\s+крови)?))?|(?:sample|collection|test|report)\s+date|date)\s*[:\-]?\s*(\d{4}-\d{2}-\d{2}|\d{2}[./]\d{2}[./]\d{4})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        let token = (text as NSString).substring(with: match.range(at: 1))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.isLenient = false
        formatter.dateFormat = token.contains("-") ? "yyyy-MM-dd" : (token.contains("/") ? "dd/MM/yyyy" : "dd.MM.yyyy")
        guard let date = formatter.date(from: token), formatter.string(from: date) == token else { return nil }
        return date
    }

    static func markerOverlap(incoming: Set<String>, existing: Set<String>) -> Double {
        guard !incoming.isEmpty, !existing.isEmpty else { return 0 }
        return Double(incoming.intersection(existing).count) / Double(min(incoming.count, existing.count))
    }
}
