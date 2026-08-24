import SwiftUI
import Observation
import GRDB
import PDFKit
import OSLog

private let labsCleanupLogger = Logger(subsystem: "LifeOS", category: "LabsCleanup")

struct LabScanDetailView: View {
    let scanId: UUID
    @State private var viewModel: LabScanDetailViewModel

    init(scanId: UUID) {
        self.scanId = scanId
        _viewModel = State(initialValue: LabScanDetailViewModel(scanId: scanId))
    }

#if DEBUG
    init(scanId: UUID, testViewModel: LabScanDetailViewModel) {
        self.scanId = scanId
        _viewModel = State(initialValue: testViewModel)
    }
#endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if let statusMessage = viewModel.statusMessage {
                    banner(statusMessage, tint: LifeOSColors.Semantic.primary)
                }

                if let actionError = viewModel.actionError {
                    banner(actionError, tint: LifeOSColors.Recovery.caution)
                }

                if viewModel.isLoading && viewModel.scan == nil {
                    loadingState
                } else if let scan = viewModel.scan {
                    overviewSection(scan)
                    documentSection(scan)
                    markersSection
                    extractionSection(scan)
                    reviewSection(scan)
                    sourceSection(scan)
                    privacySection(scan)
                } else if let loadError = viewModel.loadError {
                    errorState(loadError)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(LayoutConstants.contentPadding)
        }
        .background(LifeOSColors.Surface.background)
        .navigationTitle(String(localized: "labs_detail_title"))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if viewModel.canRefreshRemotely {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.isSaving)
                    .accessibilityLabel(String(localized: "labs_detail_retry"))
                }

                if viewModel.scan != nil {
                    Button {
                        Task { await viewModel.togglePinned() }
                    } label: {
                        Image(systemName: viewModel.isPinned ? "pin.fill" : "pin")
                    }
                    .disabled(viewModel.isSaving)
                    .accessibilityLabel(viewModel.isPinned
                        ? String(localized: "labs_detail_unpin")
                        : String(localized: "labs_detail_pin"))
                }
            }
        }
        .task {
            await viewModel.load()
        }
        .refreshable {
            await viewModel.refresh()
        }
    }

    private var loadingState: some View {
        VStack(spacing: Spacing.s) {
            ProgressView()
            Text(String(localized: "loading"))
                .font(LifeOSTypography.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xl)
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(String(localized: "labs_detail_not_found"), systemImage: "exclamationmark.triangle")
                .font(LifeOSTypography.headline)
                .foregroundStyle(LifeOSColors.Recovery.caution)

            Text(message)
                .font(LifeOSTypography.footnote)
                .foregroundStyle(.secondary)

            Button(String(localized: "labs_detail_retry")) {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.bordered)

            Text(scanId.uuidString)
                .font(LifeOSTypography.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LayoutConstants.contentPadding)
        .background(LifeOSColors.Surface.card, in: RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(String(localized: "labs_detail_not_found"), systemImage: "doc.text.magnifyingglass")
                .font(LifeOSTypography.headline)
                .foregroundStyle(.secondary)

            Text(scanId.uuidString)
                .font(LifeOSTypography.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LayoutConstants.contentPadding)
        .background(LifeOSColors.Surface.card, in: RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
    }

    private func overviewSection(_ scan: MedicalScan) -> some View {
        LabScanSectionCard(title: String(localized: "labs_detail_summary"), systemImage: "waveform.path.ecg") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(alignment: .top, spacing: Spacing.s) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(viewModel.scanTitle)
                            .font(LifeOSTypography.title3)
                            .foregroundStyle(.primary)

                        if let subtitle = viewModel.scanSubtitle {
                            Text(subtitle)
                                .font(LifeOSTypography.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: Spacing.xs) {
                        LabScanPill(text: viewModel.scanStatusText, tint: viewModel.statusTint)

                        if scan.needsReview {
                            LabScanPill(text: String(localized: "labs_review_section_header"), tint: LifeOSColors.Recovery.caution)
                        } else if scan.userReviewed {
                            LabScanPill(text: String(localized: "labs_detail_reviewed"), tint: LifeOSColors.Recovery.ready)
                        }
                    }
                }

                LabScanDetailRow(label: String(localized: "labs_detail_scan_type"), value: viewModel.scanTypeText)
                LabScanDetailRow(label: String(localized: "labs_detail_scan_date"), value: viewModel.scanDateText)
                LabScanDetailRow(label: String(localized: "labs_detail_status"), value: viewModel.scanStatusText)
                LabScanDetailRow(label: String(localized: "labs_detail_marker_count"), value: "\(viewModel.markerCount)")
                LabScanDetailRow(label: String(localized: "labs_detail_ai_confidence"), value: viewModel.aiConfidenceText)
                LabScanDetailRow(label: String(localized: "labs_detail_ocr_confidence"), value: viewModel.ocrConfidenceText)
            }
        }
    }

    private func documentSection(_ scan: MedicalScan) -> some View {
        LabScanSectionCard(title: String(localized: "labs_detail_document"), systemImage: "doc.richtext") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                LabScanDocumentPreview(
                    documentURL: viewModel.documentURL,
                    fallbackText: viewModel.documentFallbackText,
                    notesPreview: viewModel.notesPreview
                )

                if let documentName = viewModel.documentName {
                    LabScanDetailRow(label: String(localized: "labs_detail_document_name"), value: documentName)
                }

                if let documentURL = viewModel.documentURL, !documentURL.isFileURL {
                    Link(destination: documentURL) {
                        Label(String(localized: "labs_detail_open_document"), systemImage: "arrow.up.right.square")
                            .font(LifeOSTypography.subheadline.weight(.semibold))
                    }
                }
            }
        }
    }

    private var markersSection: some View {
        LabScanSectionCard(title: String(localized: "labs_detail_markers"), systemImage: "list.bullet.rectangle") {
            if viewModel.markerSummaries.isEmpty {
                Text(String(localized: "labs_detail_no_markers"))
                    .font(LifeOSTypography.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    ForEach(viewModel.markerSummaries) { marker in
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            HStack(alignment: .top, spacing: Spacing.s) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(marker.name)
                                        .font(LifeOSTypography.body.weight(.semibold))

                                    if let measuredAtText = marker.measuredAtText {
                                        Text(measuredAtText)
                                            .font(LifeOSTypography.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer(minLength: 0)

                                Text(marker.valueText)
                                    .font(LifeOSTypography.body.weight(.semibold))
                                    .multilineTextAlignment(.trailing)
                            }

                            HStack(spacing: Spacing.xs) {
                                LabScanPill(text: marker.statusText, tint: marker.statusTint)

                                if let referenceRangeText = marker.referenceRangeText {
                                    Text(referenceRangeText)
                                        .font(LifeOSTypography.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if let notes = marker.notes, !notes.isEmpty {
                                Text(notes)
                                    .font(LifeOSTypography.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, Spacing.xxs)

                        if marker.id != viewModel.markerSummaries.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func extractionSection(_ scan: MedicalScan) -> some View {
        LabScanSectionCard(title: String(localized: "labs_detail_extraction"), systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                if let extractionStatus = scan.extractionStatus, !extractionStatus.isEmpty {
                    LabScanDetailRow(
                        label: String(localized: "labs_detail_extraction_status"),
                        value: LabScanDetailViewModel.humanizedIdentifier(extractionStatus)
                    )
                }

                if let extractionError = scan.extractionError, !extractionError.isEmpty {
                    LabScanDetailRow(label: String(localized: "labs_detail_extraction_error"), value: extractionError)
                }

                if let notesPreview = viewModel.notesPreview, !notesPreview.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(String(localized: "labs_detail_ocr_preview"))
                            .font(LifeOSTypography.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(notesPreview)
                            .font(LifeOSTypography.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func reviewSection(_ scan: MedicalScan) -> some View {
        LabScanSectionCard(title: String(localized: "labs_detail_review"), systemImage: "checkmark.seal") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                if scan.userReviewed, let reviewedAt = scan.userReviewedAt {
                    Text(
                        String(
                            format: String(localized: "labs_detail_reviewed_at_format"),
                            LabScanDetailViewModel.formattedTimestamp(reviewedAt)
                        )
                    )
                    .font(LifeOSTypography.footnote)
                    .foregroundStyle(.secondary)
                } else if scan.userReviewed {
                    Text(String(localized: "labs_detail_reviewed"))
                        .font(LifeOSTypography.footnote)
                        .foregroundStyle(.secondary)
                }

                LabScanDetailRow(
                    label: String(localized: "labs_detail_manual_verification"),
                    value: scan.manuallyVerified ? String(localized: "labs_detail_reviewed") : String(localized: "labs_review_section_header")
                )

                HStack(spacing: Spacing.s) {
                    Button(String(localized: "labs_detail_mark_reviewed")) {
                        Task { await viewModel.markReviewed() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isSaving || !viewModel.canMarkReviewed)

                    Button(viewModel.isPinned
                        ? String(localized: "labs_detail_unpin")
                        : String(localized: "labs_detail_pin")) {
                        Task { await viewModel.togglePinned() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isSaving)
                }
            }
        }
    }

    private func sourceSection(_ scan: MedicalScan) -> some View {
        LabScanSectionCard(title: String(localized: "labs_detail_source"), systemImage: "internaldrive") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                LabScanDetailRow(label: String(localized: "labs_detail_storage"), value: viewModel.storageModeText)

                if let labName = scan.labName, !labName.isEmpty {
                    LabScanDetailRow(label: String(localized: "labs_detail_lab_name"), value: labName)
                }

                if let documentLanguage = scan.documentLanguage, !documentLanguage.isEmpty {
                    LabScanDetailRow(label: String(localized: "labs_detail_language"), value: documentLanguage)
                }

                if let imageUploadedAt = scan.imageUploadedAt {
                    LabScanDetailRow(
                        label: String(localized: "labs_detail_uploaded_at"),
                        value: LabScanDetailViewModel.formattedTimestamp(imageUploadedAt)
                    )
                }

                if let scheduledDeletionAt = scan.scheduledDeletionAt {
                    LabScanDetailRow(
                        label: String(localized: "labs_detail_scheduled_deletion"),
                        value: LabScanDetailViewModel.formattedTimestamp(scheduledDeletionAt)
                    )
                }

                if let sourceFileSha256 = scan.sourceFileSha256, !sourceFileSha256.isEmpty {
                    LabScanDetailRow(
                        label: String(localized: "labs_detail_file_hash"),
                        value: sourceFileSha256,
                        allowSelection: true
                    )
                }
            }
        }
    }

    private func privacySection(_ scan: MedicalScan) -> some View {
        LabScanSectionCard(title: String(localized: "labs_detail_privacy"), systemImage: "lock.shield") {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if scan.storageMode == "local_only" {
                    PrivacyNoteView(.medicalScanLocalOnly)
                }
                PrivacyNoteView(.medicalScanRetention)
            }
        }
    }

    private func banner(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(LifeOSTypography.footnote)
            .foregroundStyle(tint)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }
}

#if DEBUG
extension LabScanDetailView {
    @MainActor
    func _testRunLoadTask() async {
        await viewModel.load()
    }
}
#endif

@MainActor
@Observable
final class LabScanDetailViewModel {
    typealias RemoteLoader = @Sendable (UUID) async throws -> LabScanDetailSnapshot?
    typealias DocumentURLResolver = @Sendable (MedicalScan) async throws -> URL?

    let scanId: UUID

    private(set) var scan: MedicalScan?
    private(set) var markerSummaries: [LabScanMarkerSummary] = []
    private(set) var resolvedRemoteDocumentURL: URL?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var loadError: String?
    private(set) var actionError: String?
    private(set) var statusMessage: String?

    private let dbQueue: DatabaseQueue
    private let remoteLoader: RemoteLoader
    private let documentURLResolver: DocumentURLResolver
    private let shouldFetchRemote: Bool

    init(
        scanId: UUID,
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue,
        remoteLoader: RemoteLoader? = nil,
        documentURLResolver: DocumentURLResolver? = nil,
        shouldFetchRemote: Bool = SupabaseConfig.isRuntimeConfigured
    ) {
        self.scanId = scanId
        self.dbQueue = dbQueue
        self.remoteLoader = remoteLoader ?? Self.defaultRemoteLoader
        self.documentURLResolver = documentURLResolver ?? Self.defaultDocumentURLResolver
        self.shouldFetchRemote = shouldFetchRemote
    }

    var markerCount: Int {
        markerSummaries.count
    }

    var canRefreshRemotely: Bool {
        shouldFetchRemote
    }

    var canMarkReviewed: Bool {
        guard let scan else { return false }
        return scan.needsReview || !scan.userReviewed || scan.status == .reviewRequired
    }

    var isPinned: Bool {
        scan?.pinnedByUser == true
    }

    var scanTitle: String {
        guard let scan else { return scanId.uuidString }
        if let labName = scan.labName?.trimmingCharacters(in: .whitespacesAndNewlines), !labName.isEmpty {
            return labName
        }
        return scanTypeText
    }

    var scanSubtitle: String? {
        guard scan != nil else { return nil }
        return [scanDateText, storageModeText]
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }

    var scanTypeText: String {
        guard let scan else { return "" }
        return Self.humanizedIdentifier(scan.scanType.rawValue)
    }

    var scanStatusText: String {
        guard let scan else { return "" }
        return Self.humanizedIdentifier(scan.status.rawValue)
    }

    var scanDateText: String {
        guard let scan else { return "" }
        if let scanDate = scan.scanDate,
           let parsedDate = DiaryDateFormatter.parseDate(scanDate) {
            return Self.formattedDate(parsedDate)
        }
        return Self.formattedTimestamp(scan.createdAt)
    }

    var aiConfidenceText: String {
        formattedConfidence(scan?.aiConfidence)
    }

    var ocrConfidenceText: String {
        formattedConfidence(scan?.ocrConfidence)
    }

    var storageModeText: String {
        guard let storageMode = scan?.storageMode?.lowercased() else { return "" }
        switch storageMode {
        case "local_only":
            return String(localized: "labs_detail_storage_local_only")
        case "cloud":
            return String(localized: "labs_detail_storage_cloud")
        default:
            return Self.humanizedIdentifier(storageMode)
        }
    }

    var documentURL: URL? {
        guard let scan else { return nil }
        if let directDocumentURL = Self.directDocumentURL(for: scan) {
            return directDocumentURL
        }
        return resolvedRemoteDocumentURL
    }

    var documentName: String? {
        if let documentURL {
            return documentURL.lastPathComponent.removingPercentEncoding ?? documentURL.lastPathComponent
        }
        if let scan,
           let storagePath = Self.documentStoragePath(for: scan) {
            let lastPathComponent = (storagePath as NSString).lastPathComponent
            return lastPathComponent.removingPercentEncoding ?? lastPathComponent
        }
        return nil
    }

    var notesPreview: String? {
        guard let scan else { return nil }

        if let notes = scan.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            return notes
        }

        guard let aiExtractionRaw = scan.aiExtractionRaw,
              let rawPreview = String(data: aiExtractionRaw, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPreview.isEmpty else {
            return nil
        }
        return rawPreview
    }

    var documentFallbackText: String {
        if let notesPreview, !notesPreview.isEmpty {
            return notesPreview
        }
        return String(localized: "labs_detail_document_unavailable_detail")
    }

    var statusTint: Color {
        guard let scan else { return .secondary }
        switch scan.status {
        case .completed:
            return LifeOSColors.Recovery.ready
        case .reviewRequired:
            return LifeOSColors.Recovery.caution
        case .failed:
            return LifeOSColors.Recovery.critical
        case .processing, .pending:
            return LifeOSColors.Semantic.primary
        }
    }

    func load() async {
        await load(forceRemote: false)
    }

    func refresh() async {
        await load(forceRemote: true)
    }

    func markReviewed() async {
        guard !isSaving, var scan else { return }
        isSaving = true
        actionError = nil
        statusMessage = nil

        let previous = scan
        let now = Date()
        scan.userReviewed = true
        scan.userReviewedAt = now
        scan.manuallyVerified = true
        scan.needsReview = false
        scan.updatedAt = now

        if scan.status == .reviewRequired {
            scan.status = .completed
        }
        if scan.extractionStatus == ScanStatus.reviewRequired.rawValue {
            scan.extractionStatus = ScanStatus.completed.rawValue
        }

        do {
            try await persistScan(scan)
            self.scan = scan
            statusMessage = String(localized: "labs_detail_changes_saved")
        } catch {
            self.scan = previous
            actionError = error.localizedDescription
        }

        isSaving = false
    }

    func togglePinned() async {
        guard !isSaving, var scan else { return }
        isSaving = true
        actionError = nil
        statusMessage = nil

        let previous = scan
        scan.pinnedByUser.toggle()
        scan.updatedAt = Date()

        do {
            try await persistScan(scan)
            self.scan = scan
            statusMessage = String(localized: "labs_detail_changes_saved")
        } catch {
            self.scan = previous
            actionError = error.localizedDescription
        }

        isSaving = false
    }

    nonisolated static func humanizedIdentifier(_ rawValue: String) -> String {
        LabsLocalizedText.identifier(rawValue)
    }

    nonisolated static func formattedTimestamp(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    private func load(forceRemote: Bool) async {
        if forceRemote {
            actionError = nil
            statusMessage = nil
        } else {
            isLoading = true
            loadError = nil
            actionError = nil
            statusMessage = nil
        }

        defer {
            if !forceRemote {
                isLoading = false
            }
        }

        do {
            if !forceRemote, let localSnapshot = try await loadLocalSnapshot() {
                applySnapshot(localSnapshot)
                await resolveDocumentURLIfNeeded(for: localSnapshot.scan)
                return
            }

            if shouldFetchRemote, let remoteSnapshot = try await remoteLoader(scanId) {
                try await persistRemoteSnapshot(remoteSnapshot)
                applySnapshot(remoteSnapshot)
                await resolveDocumentURLIfNeeded(for: remoteSnapshot.scan)
                return
            }

            if forceRemote, let localSnapshot = try await loadLocalSnapshot() {
                applySnapshot(localSnapshot)
                await resolveDocumentURLIfNeeded(for: localSnapshot.scan)
                return
            }

            scan = nil
            markerSummaries = []
            resolvedRemoteDocumentURL = nil
            loadError = nil
        } catch {
            if forceRemote, let localSnapshot = try? await loadLocalSnapshot() {
                applySnapshot(localSnapshot)
                await resolveDocumentURLIfNeeded(for: localSnapshot.scan)
                actionError = error.localizedDescription
                return
            }

            scan = nil
            markerSummaries = []
            resolvedRemoteDocumentURL = nil
            loadError = error.localizedDescription
        }
    }

    private func loadLocalSnapshot() async throws -> LabScanDetailSnapshot? {
        try await dbQueue.read { db in
            guard let scan = try MedicalScan
                .filter(sql: "id = ? OR id = ?", arguments: [scanId, scanId.uuidString])
                .fetchOne(db) else {
                return nil
            }

            let measurements = try HealthMeasurement.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM health_measurements
                    WHERE (
                        medical_scan_id = ? OR medical_scan_id = ?
                        OR source_scan_id = ? OR source_scan_id = ?
                    )
                    ORDER BY COALESCE(measured_at, created_at) DESC,
                             COALESCE(NULLIF(biomarker_name, ''), NULLIF(original_label, ''), marker_id) COLLATE NOCASE ASC
                    """,
                arguments: [scanId, scanId.uuidString, scanId, scanId.uuidString]
            )

            return LabScanDetailSnapshot(scan: scan, measurements: measurements)
        }
    }

    private func applySnapshot(_ snapshot: LabScanDetailSnapshot) {
        scan = snapshot.scan
        markerSummaries = Self.buildMarkerSummaries(scan: snapshot.scan, measurements: snapshot.measurements)
        loadError = nil
    }

    private func persistRemoteSnapshot(_ snapshot: LabScanDetailSnapshot) async throws {
        try await dbQueue.write { db in
            let scan = snapshot.scan
            try scan.save(db)

            for measurement in snapshot.measurements {
                try measurement.save(db)
            }
        }
    }

    private func persistScan(_ scan: MedicalScan) async throws {
        try await dbQueue.write { db in
            let persistedScan = scan
            try persistedScan.save(db)

            if persistedScan.manuallyVerified {
                let measurementUpdateTimestamp = Date()
                try db.execute(
                    sql: """
                        UPDATE health_measurements
                        SET manually_verified = ?, updated_at = ?
                        WHERE medical_scan_id = ? OR source_scan_id = ?
                        """,
                    arguments: [
                        persistedScan.manuallyVerified,
                        measurementUpdateTimestamp,
                        persistedScan.id,
                        persistedScan.id
                    ]
                )
            }

            guard Self.shouldEnqueueSync(for: persistedScan) else { return }
            let relatedMeasurements = try HealthMeasurement.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM health_measurements
                    WHERE (
                        medical_scan_id = ? OR medical_scan_id = ?
                        OR source_scan_id = ? OR source_scan_id = ?
                    )
                    ORDER BY COALESCE(measured_at, created_at) DESC,
                             COALESCE(NULLIF(biomarker_name, ''), NULLIF(original_label, ''), marker_id) COLLATE NOCASE ASC
                    """,
                arguments: [persistedScan.id, persistedScan.id.uuidString, persistedScan.id, persistedScan.id.uuidString]
            )

            var event = OutboxEvent(
                id: UUID(),
                httpMethod: .POST,
                path: "api-labs",
                bodyJson: try LabScanSyncPayloadBuilder.buildBody(
                    scan: persistedScan,
                    measurements: relatedMeasurements
                ),
                priority: 100
            )
            event.userVisibleBlocker = true
            event.headersJson = try Self.outboxHeadersJson()
            try event.insert(db)
        }
    }

    nonisolated private static func shouldEnqueueSync(for scan: MedicalScan) -> Bool {
        scan.storageMode?.lowercased() != "local_only"
    }

    private static func defaultRemoteLoader(scanId: UUID) async throws -> LabScanDetailSnapshot? {
        guard SupabaseConfig.isRuntimeConfigured else { return nil }

        let apiClient = APIClient()
        let scans: [MedicalScan] = try await apiClient.fetch(
            from: "medical_scans",
            limit: 1,
            exactMatch: ["id": scanId.uuidString]
        )

        guard let scan = scans.first else {
            return nil
        }

        async let sourceMeasurements: [HealthMeasurement] = apiClient.fetch(
            from: "health_measurements",
            exactMatch: ["source_scan_id": scanId.uuidString]
        )
        let measurements = deduplicatedMeasurements(try await sourceMeasurements)
        return LabScanDetailSnapshot(scan: scan, measurements: measurements)
    }

    private static func defaultDocumentURLResolver(scan: MedicalScan) async throws -> URL? {
        guard let storagePath = documentStoragePath(for: scan),
              SupabaseConfig.isRuntimeConfigured else {
            return nil
        }

        return try await APIClient().createSignedLabScanAssetURL(path: storagePath)
    }

    private static func deduplicatedMeasurements(_ measurements: [HealthMeasurement]) -> [HealthMeasurement] {
        var uniqueMeasurements: [UUID: HealthMeasurement] = [:]
        for measurement in measurements {
            uniqueMeasurements[measurement.id] = measurement
        }
        return uniqueMeasurements.values.sorted {
            if $0.biomarkerName != $1.biomarkerName {
                return $0.biomarkerName.localizedCaseInsensitiveCompare($1.biomarkerName) == .orderedAscending
            }
            return ($0.measuredAt ?? $0.createdAt) > ($1.measuredAt ?? $1.createdAt)
        }
    }

    private static func buildMarkerSummaries(
        scan: MedicalScan,
        measurements: [HealthMeasurement]
    ) -> [LabScanMarkerSummary] {
        if !measurements.isEmpty {
            return measurements.map(Self.markerSummary(from:))
        }

        if let processedDataMarkers = decodeProcessedMarkers(from: scan.processedData) {
            return processedDataMarkers.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }

        return []
    }

    private static func markerSummary(from measurement: HealthMeasurement) -> LabScanMarkerSummary {
        let statusPresentation = measurementStatusPresentation(
            rawStatus: measurement.status,
            value: measurement.value,
            referenceRangeLow: measurement.referenceRangeLow,
            referenceRangeHigh: measurement.referenceRangeHigh
        )

        let referenceRangeText = referenceRangeText(
            low: measurement.referenceRangeLow,
            high: measurement.referenceRangeHigh,
            unit: measurement.unit
        ) ?? measurement.notes

        return LabScanMarkerSummary(
            id: measurement.id.uuidString,
            name: measurement.biomarkerName,
            valueText: formattedMarkerValue(value: measurement.value, unit: measurement.unit),
            statusText: statusPresentation.text,
            statusTint: statusPresentation.tint,
            referenceRangeText: referenceRangeText,
            measuredAtText: measurement.resolvedMeasuredDate.flatMap {
                DiaryDateFormatter.parseDate($0).map(formattedDate)
            } ?? measurement.measuredAt.map(formattedTimestamp),
            notes: measurement.userCorrected ? String(localized: "labs_detail_reviewed") : nil
        )
    }

    private static func decodeProcessedMarkers(from data: Data?) -> [LabScanMarkerSummary]? {
        guard let data else { return nil }

        let decoder = JSONDecoder()

        if let extractedMarkers = try? decoder.decode([ExtractedLabMarker].self, from: data) {
            return extractedMarkers.map { marker in
                LabScanMarkerSummary(
                    id: marker.id.uuidString,
                    name: marker.name,
                    valueText: formattedMarkerValue(
                        value: Double(marker.value.replacingOccurrences(of: ",", with: ".")),
                        unit: marker.unit
                    ),
                    statusText: marker.isNormal
                        ? String(localized: "labs_within_range")
                        : String(localized: "labs_out_of_range"),
                    statusTint: marker.isNormal ? LifeOSColors.Recovery.ready : LifeOSColors.Recovery.caution,
                    referenceRangeText: marker.referenceRange,
                    measuredAtText: nil,
                    notes: nil
                )
            }
        }

        if let wrappedPayload = try? decoder.decode(LabScanProcessedMarkersEnvelope.self, from: data) {
            return wrappedPayload.markers.map { marker in
                let statusPresentation = measurementStatusPresentation(
                    rawStatus: marker.status,
                    value: marker.value,
                    referenceRangeLow: marker.referenceRangeLow,
                    referenceRangeHigh: marker.referenceRangeHigh
                )

                return LabScanMarkerSummary(
                    id: marker.measurementId ?? [
                        marker.markerId,
                        marker.originalLabel,
                        marker.unit,
                    ]
                    .compactMap { $0 }
                    .joined(separator: "|"),
                    name: marker.originalLabel ?? marker.markerId,
                    valueText: formattedMarkerValue(value: marker.value, unit: marker.unit),
                    statusText: statusPresentation.text,
                    statusTint: statusPresentation.tint,
                    referenceRangeText: referenceRangeText(
                        low: marker.referenceRangeLow,
                        high: marker.referenceRangeHigh,
                        unit: marker.unit
                    ),
                    measuredAtText: nil,
                    notes: nil
                )
            }
        }

        return nil
    }

    private static func referenceRangeText(low: Double?, high: Double?, unit: String?) -> String? {
        guard low != nil || high != nil else { return nil }
        let left = low.map(Self.formattedNumber) ?? "?"
        let right = high.map(Self.formattedNumber) ?? "?"
        let normalizedUnit = unit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalizedUnit.isEmpty ? "\(left) - \(right)" : "\(left) - \(right) \(normalizedUnit)"
    }

    private static func measurementStatusPresentation(
        rawStatus: String?,
        value: Double?,
        referenceRangeLow: Double?,
        referenceRangeHigh: Double?
    ) -> (text: String, tint: Color) {
        if let normalizedStatus = HealthMeasurementStatus(
            normalizedRawValue: rawStatus,
            value: value,
            referenceRangeLow: referenceRangeLow,
            referenceRangeHigh: referenceRangeHigh
        ) {
            switch normalizedStatus {
            case .optimal:
                return (String(localized: "labs_within_range"), LifeOSColors.Recovery.ready)
            case .criticalLow, .criticalHigh:
                return (humanizedIdentifier(normalizedStatus.rawValue), LifeOSColors.Recovery.critical)
            case .low, .high:
                return (humanizedIdentifier(normalizedStatus.rawValue), LifeOSColors.Recovery.caution)
            }
        }

        let normalizedLegacyStatus = rawStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalizedLegacyStatus {
        case "out_of_range", "out of range", "abnormal":
            return (String(localized: "labs_out_of_range"), LifeOSColors.Recovery.caution)
        case "normal", "within_range", "within range", "in_range":
            return (String(localized: "labs_within_range"), LifeOSColors.Recovery.ready)
        default:
            break
        }

        if let value, isValueWithinRange(value, low: referenceRangeLow, high: referenceRangeHigh) {
            return (String(localized: "labs_within_range"), LifeOSColors.Recovery.ready)
        }
        if referenceRangeLow != nil || referenceRangeHigh != nil {
            return (String(localized: "labs_out_of_range"), LifeOSColors.Recovery.caution)
        }
        return (
            humanizedIdentifier(rawStatus ?? ScanStatus.pending.rawValue),
            LifeOSColors.Semantic.primary
        )
    }

    private static func formattedMarkerValue(value: Double?, unit: String) -> String {
        guard let value else {
            return unit.isEmpty ? "—" : "— \(unit)"
        }
        let normalizedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedUnit.isEmpty ? formattedNumber(value) : "\(formattedNumber(value)) \(normalizedUnit)"
    }

    private static func formattedNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
            .replacingOccurrences(of: #"(\.\d*?[1-9])0+$"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\.0+$"#, with: "", options: .regularExpression)
    }

    private static func isValueWithinRange(_ value: Double, low: Double?, high: Double?) -> Bool {
        if let low, value < low { return false }
        if let high, value > high { return false }
        return low != nil || high != nil
    }

    private func formattedConfidence(_ value: Double?) -> String {
        guard let value else { return String(localized: "labs_detail_confidence_unavailable") }
        return "\(Int((value * 100).rounded()))%"
    }

    private static func formattedDate(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
    }

    private static func directDocumentURL(for scan: MedicalScan) -> URL? {
        for rawValue in [scan.originalImageUrl, scan.imageUrl] {
            guard let directURL = LabScanCloudStorage.directURL(from: rawValue) else { continue }
            return directURL
        }
        return nil
    }

    private static func documentStoragePath(for scan: MedicalScan) -> String? {
        LabScanCloudStorage.storagePath(from: scan.originalImageUrl)
            ?? LabScanCloudStorage.storagePath(from: scan.imageUrl)
    }

    private func resolveDocumentURLIfNeeded(for scan: MedicalScan) async {
        resolvedRemoteDocumentURL = nil
        guard Self.directDocumentURL(for: scan) == nil else { return }

        do {
            resolvedRemoteDocumentURL = try await documentURLResolver(scan)
        } catch {
            resolvedRemoteDocumentURL = nil
        }
    }

    nonisolated private static func outboxHeadersJson() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
    }
}

struct LabScanDetailSnapshot: Equatable, Sendable {
    let scan: MedicalScan
    let measurements: [HealthMeasurement]
}

struct LabScanMarkerSummary: Identifiable {
    let id: String
    let name: String
    let valueText: String
    let statusText: String
    let statusTint: Color
    let referenceRangeText: String?
    let measuredAtText: String?
    let notes: String?
}

struct CapturedLabAsset: Equatable, Sendable {
    let data: Data
    let fileExtension: String

    var isImage: Bool {
        fileExtension.lowercased() != "pdf"
    }
}

enum LabScanAssetStore {
    static func persistAsset(scanId: UUID, asset: CapturedLabAsset) throws -> URL {
        let directory = try assetsDirectory()
        let filename = "\(scanId.uuidString.lowercased()).\(asset.fileExtension.lowercased())"
        let fileURL = directory.appendingPathComponent(filename, isDirectory: false)
        try asset.data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    static func assetsDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent("MedicalScans", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

enum LabsCleanupService {
    static func pruneStaleAssets(dbQueue: DatabaseQueue) async {
        do {
            let referencedFiles = try await dbQueue.read { db -> Set<String> in
                let scans = try MedicalScan.fetchAll(
                    db,
                    sql: """
                        SELECT *
                        FROM medical_scans
                        WHERE image_url IS NOT NULL
                           OR original_image_url IS NOT NULL
                        """
                )

                return Set(
                    scans
                        .flatMap { scan in [scan.imageUrl, scan.originalImageUrl] }
                        .compactMap { rawValue in
                            guard let rawValue,
                                  let url = URL(string: rawValue),
                                  url.isFileURL else { return nil }
                            return url.standardizedFileURL.path
                        }
                )
            }

            let directory = try LabScanAssetStore.assetsDirectory()
            let fileManager = FileManager.default
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            while let fileURL = enumerator?.nextObject() as? URL {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
                if resourceValues.isDirectory == true {
                    continue
                }

                let standardizedPath = fileURL.standardizedFileURL.path
                if !referencedFiles.contains(standardizedPath) {
                    try fileManager.removeItem(at: fileURL)
                }
            }
        } catch {
            labsCleanupLogger.error("Error pruning scan assets: \(error.localizedDescription, privacy: .private)")
        }
    }
}

private struct LabScanSectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(title, systemImage: systemImage)
                .font(LifeOSTypography.headline)
                .foregroundStyle(.primary)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LayoutConstants.contentPadding)
        .background(LifeOSColors.Surface.card, in: RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
    }
}

private struct LabScanDetailRow: View {
    let label: String
    let value: String
    var allowSelection = false

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Text(label)
                .font(LifeOSTypography.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Group {
                if allowSelection {
                    Text(value)
                        .textSelection(.enabled)
                } else {
                    Text(value)
                }
            }
            .font(LifeOSTypography.subheadline)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.trailing)
        }
    }
}

private struct LabScanPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(LifeOSTypography.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct LabScanDocumentPreview: View {
    let documentURL: URL?
    let fallbackText: String
    let notesPreview: String?

    var body: some View {
        Group {
            if let documentURL {
                preview(for: documentURL)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func preview(for url: URL) -> some View {
        if url.pathExtension.lowercased() == "pdf" {
            if url.isFileURL {
                LabScanPDFPreview(url: url)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
            } else {
                placeholder
            }
        } else if url.isFileURL, let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
        } else {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ZStack {
                        RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius)
                            .fill(LifeOSColors.Surface.elevated)
                        ProgressView()
                    }
                    .frame(height: 220)

                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))

                case .failure:
                    placeholder

                @unknown default:
                    placeholder
                }
            }
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(String(localized: "labs_detail_document_unavailable"), systemImage: "doc.text.magnifyingglass")
                .font(LifeOSTypography.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(notesPreview ?? fallbackText)
                .font(LifeOSTypography.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LayoutConstants.contentPadding)
        .background(LifeOSColors.Surface.elevated, in: RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }
}

private struct LabScanPDFPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context _: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.document = PDFDocument(url: url)
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context _: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
        }
    }
}
