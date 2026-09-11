import SwiftUI
import Observation
import Combine
import GRDB
import FamilyControls
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

#if DEBUG
@MainActor
private func noopSettingsEnqueue(
    _: SyncEngine,
    _: String,
    _: HTTPMethod,
    _: [String: Any]
) async throws { }

@MainActor
private func noopSettingsErasure(_: String) async throws { }

@MainActor
private func noopSettingsErasureStatus() async throws -> ErasureStatusResponse {
    ErasureStatusResponse(
        scheduled: false,
        deletionDate: nil,
        deletionInProgress: false,
        reason: nil,
        deletionState: nil,
        deletionMode: nil,
        deletionAttemptCount: nil,
        retryAfterSeconds: nil,
        idempotencyKey: nil
    )
}

@MainActor
private func noopSettingsCancelErasure() async throws -> ErasureCancelResponse {
    ErasureCancelResponse(cancelled: false, status: "queued", deletionState: nil)
}

@MainActor
private func noopSettingsRequestExport() async throws -> ExportRequestResponse {
    ExportRequestResponse(exportId: UUID().uuidString, status: "queued")
}

@MainActor
private func noopSettingsExportStatus(_ exportId: String) async throws -> ExportStatusResponse {
    ExportStatusResponse(exportId: exportId, status: "pending", downloadUrl: nil)
}

@MainActor
private func noopSettingsDownloadExportArchive(_: String) async throws -> URL {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("json")
    try Data("{}".utf8).write(to: fileURL, options: .atomic)
    return fileURL
}
#endif

private struct SettingsCloudReconnectNotice: View {
    let requirement: SettingsAccountRequirement

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(String(localized: "settings_cloud_reconnect_title"), systemImage: "person.crop.circle.badge.exclamationmark")
                .font(LifeOSTypography.subheadline.weight(.semibold))
                .foregroundStyle(LifeOSColors.Recovery.caution)

            Text(String(localized: "settings_cloud_reconnect_notice"))
                .font(LifeOSTypography.footnote)
                .foregroundStyle(.secondary)

            NavigationLink {
                SettingsAccountManagementView(requirement: requirement)
            } label: {
                Text(String(localized: "settings_cloud_reconnect_cta"))
                    .font(LifeOSTypography.subheadline.weight(.semibold))
            }
        }
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }
}

struct SettingsSyncView: View {
    @State private var viewModel: SettingsSyncViewModel

    init(syncEngine: SyncEngine = AppContainer.shared?.syncEngine ?? previewSyncEngine) {
        _viewModel = State(initialValue: SettingsSyncViewModel(syncEngine: syncEngine))
    }

#if DEBUG
    init(
        testPendingCount: Int,
        testFailedPermanentCount: Int,
        testOldestPendingAgeHours: Double?,
        testStatusMessage: String?,
        testBlocker: SyncBlockerSummary?
    ) {
        let metrics = SyncHealthMetrics(
            pendingCount: testPendingCount,
            failedPermanentCount: testFailedPermanentCount,
            oldestPendingAgeHours: testOldestPendingAgeHours
        )
        let vm = SettingsSyncViewModel(
            syncEngine: previewSyncEngine,
            refreshOperation: { (metrics, testBlocker) },
            replayOperation: { },
            pullOperation: { },
            fixBlockerOperation: { _ in },
            dismissBlockerOperation: { _ in }
        )
        vm.pendingCount = testPendingCount
        vm.failedPermanentCount = testFailedPermanentCount
        vm.oldestPendingAgeHours = testOldestPendingAgeHours
        vm.statusMessage = testStatusMessage
        vm.blocker = testBlocker
        _viewModel = State(initialValue: vm)
    }

    func _testEvaluateBody() {
        _ = metricRow(title: "Pending", value: "1")
        _ = body
    }

    func _testTriggerActions() {
        triggerFixBlocker()
        triggerDismissBlocker()
        triggerReplayNow()
        triggerPullNow()
    }
#endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Label(String(localized: "settings_sync_status"), systemImage: "arrow.triangle.2.circlepath")
                    .font(LifeOSTypography.title3)

                if viewModel.requiresCloudReconnect {
                    SettingsCloudReconnectNotice(requirement: .sync)
                        .accessibilityIdentifier("settings.sync.reconnect_notice")
                }

                metricRow(
                    title: String(localized: "settings_sync_pending"),
                    value: "\(viewModel.pendingCount)"
                )
                metricRow(
                    title: String(localized: "settings_sync_failed"),
                    value: "\(viewModel.failedPermanentCount)"
                )
                metricRow(
                    title: String(localized: "settings_sync_oldest_pending"),
                    value: viewModel.oldestPendingText
                )

                if let blocker = viewModel.blocker {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Label(String(localized: "settings_sync_blocker_title"), systemImage: "exclamationmark.triangle.fill")
                            .font(LifeOSTypography.subheadline.weight(.semibold))
                            .foregroundStyle(LifeOSColors.Recovery.caution)

                        Text(viewModel.blockerSummary(for: blocker))
                            .font(LifeOSTypography.footnote)
                            .foregroundStyle(.secondary)

                        Text(viewModel.blockerGuidance(for: blocker))
                            .font(LifeOSTypography.footnote)
                            .foregroundStyle(.primary)

                        HStack(spacing: Spacing.s) {
                            Button(String(localized: "settings_sync_fix_cta"), action: triggerFixBlocker)
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("settings.sync.fix")

                            Button(String(localized: "settings_sync_dismiss_cta"), action: triggerDismissBlocker)
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("settings.sync.dismiss")
                        }
                    }
                    .padding(Spacing.s)
                    .background(LifeOSColors.Surface.card)
                    .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
                    .accessibilityIdentifier("settings.sync.blocker")
                }

                HStack(spacing: Spacing.s) {
                    Button(String(localized: "settings_sync_replay_now"), action: triggerReplayNow)
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.requiresCloudReconnect)

                    Button(String(localized: "settings_sync_pull_now"), action: triggerPullNow)
                    .buttonStyle(.bordered)
                    .disabled(viewModel.requiresCloudReconnect)
                }

                if let statusMessage = viewModel.statusMessage {
                    Text(statusMessage)
                        .font(LifeOSTypography.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.sync.status")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(LayoutConstants.contentPadding)
        }
        .background(LifeOSColors.Surface.background)
        .navigationTitle(String(localized: "settings_sync_status"))
        .task(viewModel.refresh)
    }

    private func triggerFixBlocker() {
        Task { await viewModel.fixBlocker() }
    }

    private func triggerDismissBlocker() {
        Task { await viewModel.dismissBlocker() }
    }

    private func triggerReplayNow() {
        Task { await viewModel.replayNow() }
    }

    private func triggerPullNow() {
        Task { await viewModel.pullNow() }
    }

    private func metricRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(LifeOSTypography.body)
            Spacer()
            Text(value)
                .font(LifeOSTypography.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

struct SettingsNotificationsView: View {
    @State private var viewModel: SettingsNotificationsViewModel
    @State private var isPresentingEmergencyOverride = false

    init(
        syncEngine: SyncEngine = AppContainer.shared?.syncEngine ?? previewSyncEngine,
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue
    ) {
        _viewModel = State(initialValue: SettingsNotificationsViewModel(syncEngine: syncEngine, dbQueue: dbQueue))
    }

#if DEBUG
    init(
        testSettings: NotificationSettings,
        testIsLoaded: Bool,
        testStatusMessage: String?,
        testIsPickingApps: Bool = false
    ) {
        let vm = SettingsNotificationsViewModel(
            syncEngine: previewSyncEngine,
            dbQueue: DatabaseManager.shared.dbQueue,
            enqueue: noopSettingsEnqueue
        )
        vm.settings = testSettings
        vm.isLoaded = testIsLoaded
        vm.statusMessage = testStatusMessage
        vm.isPickingApps = testIsPickingApps
        _viewModel = State(initialValue: vm)
    }

    func _testEvaluateBody() {
        _ = body
    }

    func _testEvaluatePickerSheetContent() {
        _ = pickerSheetContent()
    }

    func _testTriggerActions() {
        triggerOpenPicker()
        handleSelectionChange(FamilyActivitySelection())
        triggerSave()
    }
#endif

    var body: some View {
        @Bindable var viewModel = viewModel

        Form {
            if !viewModel.isLoaded {
                ProgressView(String(localized: "loading"))
            } else {
                Section {
                    Toggle(String(localized: "settings_morning_brief_enabled"), isOn: $viewModel.settings.morningBriefEnabled)
                    Toggle(String(localized: "settings_positive_enabled"), isOn: $viewModel.settings.positiveEnabled)
                    Toggle(String(localized: "settings_nudges_enabled"), isOn: $viewModel.settings.nudgesEnabled)
                    Toggle(String(localized: "settings_celebration_enabled"), isOn: $viewModel.settings.celebrationEnabled)
                    Toggle(String(localized: "settings_critical_only"), isOn: $viewModel.settings.criticalOnly)
                        .accessibilityIdentifier("settings.notifications.critical_only")
                } header: {
                    Text(String(localized: "settings_notifications"))
                }

                Section {
                    Stepper(
                        "\(String(localized: "settings_max_total_per_day")): \(viewModel.settings.maxTotalPerDay)",
                        value: $viewModel.settings.maxTotalPerDay,
                        in: 1...6
                    )
                    Stepper(
                        "\(String(localized: "settings_max_nudges_per_day")): \(viewModel.settings.maxNudgesPerDay)",
                        value: $viewModel.settings.maxNudgesPerDay,
                        in: 0...2
                    )
                    Stepper(
                        "\(String(localized: "settings_max_positive_per_day")): \(viewModel.settings.maxPositivePerDay)",
                        value: $viewModel.settings.maxPositivePerDay,
                        in: 0...3
                    )
                    Stepper(
                        "\(String(localized: "settings_max_celebration_per_day")): \(viewModel.settings.maxCelebrationPerDay)",
                        value: $viewModel.settings.maxCelebrationPerDay,
                        in: 0...2
                    )
                } header: {
                    Text(String(localized: "settings_notification_limits"))
                }

                Section {
                    DatePicker(
                        String(localized: "settings_morning_brief_time"),
                        selection: timeBinding($viewModel.settings.morningBriefTimeLocal),
                        displayedComponents: .hourAndMinute
                    )
                    DatePicker(
                        String(localized: "settings_quiet_hours_start"),
                        selection: timeBinding($viewModel.settings.quietHoursStart),
                        displayedComponents: .hourAndMinute
                    )
                    DatePicker(
                        String(localized: "settings_quiet_hours_end"),
                        selection: timeBinding($viewModel.settings.quietHoursEnd),
                        displayedComponents: .hourAndMinute
                    )
                } header: {
                    Text(String(localized: "settings_notification_schedule"))
                } footer: {
                    Text(String(localized: "settings_notification_schedule_footer"))
                }
                
                Section {
                    Picker(String(localized: "settings_control_level"), selection: $viewModel.settings.controlLevel) {
                        Text(String(localized: "control_level_advisory")).tag(ControlLevel.advisory)
                        Text(String(localized: "control_level_protective")).tag(ControlLevel.protective)
                        if viewModel.isGuardianFeatureEnabled {
                            Text(String(localized: "control_level_guardian")).tag(ControlLevel.guardian)
                        }
                    }

                    if let guardianAvailabilityMessage = viewModel.guardianAvailabilityMessage {
                        Text(guardianAvailabilityMessage)
                            .font(LifeOSTypography.footnote)
                            .foregroundStyle(LifeOSColors.Recovery.caution)
                    }

                    if viewModel.settings.controlLevel == .guardian {
                        Toggle(String(localized: "settings_focus_control_enabled"), isOn: $viewModel.settings.focusControlEnabled)
                            .disabled(!viewModel.canUseGuardianSystemControls)

                        Button(String(localized: "settings_select_blocked_apps"), action: triggerOpenPicker)
                            .disabled(!viewModel.canUseGuardianSystemControls)

                        Text(viewModel.guardianStatusDescription)
                            .font(LifeOSTypography.footnote)
                            .foregroundStyle(.secondary)

                        if !viewModel.blockedApps.isEmpty {
                            Text(String(localized: "settings_notifications_blocked_apps"))
                                .font(LifeOSTypography.subheadline.weight(.semibold))
                            ForEach(viewModel.blockedApps) { app in
                                Text(app.displayName)
                                    .font(LifeOSTypography.body)
                            }
                        } else {
                            Text(
                                String.localizedStringWithFormat(
                                    String(localized: "settings_notifications_blocked_apps_empty"),
                                    String(localized: "control_level_protective")
                                )
                            )
                                .font(LifeOSTypography.footnote)
                                .foregroundStyle(.secondary)
                        }

                        if viewModel.blockedCategoryCount > 0 {
                            Text(
                                String.localizedStringWithFormat(
                                    String(localized: "settings_notifications_blocked_categories_format"),
                                    viewModel.blockedCategoryCount
                                )
                            )
                                .font(LifeOSTypography.footnote)
                                .foregroundStyle(.secondary)
                        }

                        if viewModel.blockedWebDomainCount > 0 {
                            Text(
                                String.localizedStringWithFormat(
                                    String(localized: "settings_notifications_blocked_websites_format"),
                                    viewModel.blockedWebDomainCount
                                )
                            )
                                .font(LifeOSTypography.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Button(String(localized: "settings_notifications_emergency_override"), action: triggerPresentEmergencyOverride)
                            .disabled(!viewModel.canActivateEmergencyOverride)

                        Text(String(localized: "settings_notifications_emergency_override_note"))
                            .font(LifeOSTypography.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .sheet(isPresented: $viewModel.isPickingApps, content: pickerSheetContent)
                .sheet(isPresented: $isPresentingEmergencyOverride, content: emergencyOverrideSheetContent)

                if !viewModel.capabilityMessages.isEmpty {
                    Section {
                        ForEach(Array(viewModel.capabilityMessages.enumerated()), id: \.offset) { _, message in
                            Text(message)
                                .font(LifeOSTypography.footnote)
                                .foregroundStyle(LifeOSColors.Recovery.caution)
                        }
                    } header: {
                        Text(String(localized: "settings_notifications_system_services"))
                    }
                }

                Section {
                    Button(String(localized: "settings_save"), action: triggerSave)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("settings.notifications.save")
                }

                if let statusMessage = viewModel.statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(LifeOSTypography.footnote)
                            .accessibilityIdentifier("settings.notifications.status")
                    }
                }
            }
        }
        .navigationTitle(String(localized: "settings_notifications"))
        .task(viewModel.load)
        .onReceive(NotificationCenter.default.publisher(for: FeatureFlagManager.didUpdateNotification)) { _ in
            Task {
                await viewModel.handleFeatureFlagSnapshotDidChange()
            }
        }
    }

    private func triggerOpenPicker() {
        guard viewModel.canUseGuardianSystemControls else {
            viewModel.statusMessage = viewModel.guardianAvailabilityMessage ?? AppCapabilityAvailability.familyControlsUnavailableMessage
            return
        }
        viewModel.isPickingApps = true
    }

    private func handleSelectionChange(_ newSelection: FamilyActivitySelection) {
        viewModel.saveSelection(newSelection)
    }

    private func triggerSave() {
        Task { await viewModel.save() }
    }

    private func timeBinding(_ source: Binding<String>) -> Binding<Date> {
        Binding(
            get: {
                let parts = source.wrappedValue.split(separator: ":")
                let hour = parts.count > 0 ? Int(parts[0]) ?? 7 : 7
                let minute = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                return Calendar.current.date(
                    bySettingHour: min(23, max(0, hour)),
                    minute: min(59, max(0, minute)),
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                source.wrappedValue = String(
                    format: "%02d:%02d",
                    min(23, max(0, components.hour ?? 0)),
                    min(59, max(0, components.minute ?? 0))
                )
            }
        )
    }

    private func triggerPresentEmergencyOverride() {
        guard viewModel.canActivateEmergencyOverride else { return }
        isPresentingEmergencyOverride = true
    }

    private func triggerEmergencyOverride() {
        Task {
            await viewModel.activateGuardianEmergencyOverride()
            await MainActor.run {
                isPresentingEmergencyOverride = false
            }
        }
    }

    private func pickerSheetContent() -> some View {
        FamilyActivityPicker(selection: $viewModel.selection)
            .onChange(of: viewModel.selection) { _, newSelection in
                handleSelectionChange(newSelection)
            }
    }

    @ViewBuilder
    private func emergencyOverrideSheetContent() -> some View {
        GuardianEmergencyOverrideSheet(
            isEnabled: viewModel.canActivateEmergencyOverride,
            onConfirm: triggerEmergencyOverride
        )
    }
}

private struct GuardianEmergencyOverrideSheet: View {
    private static let holdDuration: TimeInterval = 15

    @Environment(\.dismiss) private var dismiss
    @State private var holdProgress = 0.0
    @State private var holdTask: Task<Void, Never>?

    let isEnabled: Bool
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text(String(localized: "settings_emergency_override_title"))
                    .font(LifeOSTypography.title2.weight(.semibold))

                Text(String(localized: "settings_emergency_override_description"))
                    .font(LifeOSTypography.body)
                    .foregroundStyle(.secondary)

                Text(String(localized: "settings_emergency_override_hold_instruction"))
                    .font(LifeOSTypography.footnote)
                    .foregroundStyle(.secondary)

                ProgressView(value: holdProgress, total: 1)
                    .tint(LifeOSColors.Recovery.caution)

                Button(action: {}) {
                    Text(
                        isEnabled
                            ? String(localized: "settings_emergency_override_hold_button")
                            : String(localized: "settings_emergency_override_unavailable")
                    )
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isEnabled)
                .onLongPressGesture(
                    minimumDuration: Self.holdDuration,
                    maximumDistance: 36,
                    pressing: handlePressing(_:),
                    perform: confirmOverride
                )

                Button(String(localized: "cancel")) {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "close")) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func handlePressing(_ isPressing: Bool) {
        holdTask?.cancel()
        if isPressing {
            holdTask = Task {
                let start = Date()
                while !Task.isCancelled {
                    let seconds = Date().timeIntervalSince(start)
                    await MainActor.run {
                        holdProgress = min(1, seconds / Self.holdDuration)
                    }
                    if seconds >= Self.holdDuration {
                        return
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        } else {
            holdProgress = 0
        }
    }

    private func confirmOverride() {
        holdTask?.cancel()
        holdProgress = 1
        onConfirm()
    }
}

struct SettingsExportDataView: View {
    @State private var shareArchive: SettingsExportShareItem?
    @State private var isShowingImporter = false
    @State private var viewModel: SettingsExportDataViewModel

    init(
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue
    ) {
        _viewModel = State(initialValue: SettingsExportDataViewModel(dbQueue: dbQueue))
    }

#if DEBUG
    fileprivate init(
        testExport: SettingsExportJobSnapshot?,
        testIsLoaded: Bool,
        testStatusMessage: String?,
        testIsRequestingExport: Bool = false,
        testIsRefreshingStatus: Bool = false,
        testIsDownloadingExport: Bool = false
    ) {
        let vm = SettingsExportDataViewModel(
            dbQueue: DatabaseManager.shared.dbQueue,
            requestExportOperation: noopSettingsRequestExport,
            exportStatusOperation: noopSettingsExportStatus,
            downloadExportOperation: noopSettingsDownloadExportArchive
        )
        vm.latestExport = testExport
        vm.isLoaded = testIsLoaded
        vm.statusMessage = testStatusMessage
        vm.isRequestingExport = testIsRequestingExport
        vm.isRefreshingStatus = testIsRefreshingStatus
        vm.isDownloadingExport = testIsDownloadingExport
        _viewModel = State(initialValue: vm)
    }

    func _testEvaluateBody() {
        _ = body
    }

    func _testTriggerActions() {
        triggerRequestExport()
        triggerRefreshStatus()
        triggerDownloadArchive()
    }
#endif

    var body: some View {
        Form {
            if !viewModel.isLoaded {
                ProgressView(String(localized: "loading"))
            } else {
                Section {
                    Text(String(localized: "settings_export_description"))
                        .font(LifeOSTypography.body)
                }

                Section {
                    if viewModel.requiresCloudReconnect {
                        SettingsCloudReconnectNotice(requirement: .export)
                    }

                    if let export = viewModel.latestExport {
                        LabeledContent(String(localized: "settings_export_id")) {
                            Text(export.id)
                                .font(LifeOSTypography.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        LabeledContent(String(localized: "settings_export_status_label")) {
                            Label(viewModel.statusText(for: export), systemImage: viewModel.statusIcon(for: export))
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(viewModel.statusColor(for: export))
                        }

                        if let requestedAt = export.requestedAt {
                            LabeledContent(String(localized: "settings_export_requested_at")) {
                                Text(SettingsPrivacyFormatting.displayDateTime(for: requestedAt))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let completedAt = export.completedAt {
                            LabeledContent(String(localized: "settings_export_completed_at")) {
                                Text(SettingsPrivacyFormatting.displayDateTime(for: completedAt))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let failureReason = export.failureReason, !failureReason.isEmpty {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text(String(localized: "settings_export_error_label"))
                                    .font(LifeOSTypography.subheadline.weight(.semibold))
                                Text(failureReason)
                                    .font(LifeOSTypography.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let note = viewModel.statusNote(for: export) {
                            Text(note)
                                .font(LifeOSTypography.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("settings.export.status")
                        }
                    } else {
                        Text(String(localized: "settings_export_no_request"))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings.export.status")
                    }
                } header: {
                    Text(String(localized: "settings_export_latest_section"))
                }

                Section {
                    if viewModel.canDownloadLatestExport {
                        Button(action: triggerDownloadArchive) {
                            HStack(spacing: Spacing.s) {
                                if viewModel.isDownloadingExport {
                                    ProgressView()
                                }
                                Text(String(localized: "settings_export_download_archive"))
                            }
                        }
                        .disabled(viewModel.isDownloadingExport)
                        .accessibilityIdentifier("settings.export.download")
                    }

                    Button(String(localized: "settings_export_refresh_status"), action: triggerRefreshStatus)
                        .disabled(!viewModel.canRefreshStatus)
                        .accessibilityIdentifier("settings.export.refresh")

                    Button(String(localized: "settings_export_request_new"), action: triggerRequestExport)
                        .disabled(!viewModel.canRequestExport)
                        .accessibilityIdentifier("settings.export.request")
                }

                Section {
                    Text(String(localized: "settings_import_description"))
                        .font(LifeOSTypography.footnote)
                        .foregroundStyle(.secondary)

                    Button(action: triggerImportArchive) {
                        HStack(spacing: Spacing.s) {
                            if viewModel.isImportingArchive {
                                ProgressView()
                            }
                            Text(String(localized: "settings_import_archive"))
                        }
                    }
                    .disabled(viewModel.isImportingArchive)
                    .accessibilityIdentifier("settings.export.import")
                } header: {
                    Text(String(localized: "settings_import_section"))
                }

                if let statusMessage = viewModel.statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(LifeOSTypography.footnote)
                            .accessibilityIdentifier("settings.export.status")
                    }
                }
            }
        }
        .navigationTitle(String(localized: "settings_export_data"))
        .task(viewModel.load)
        .refreshable {
            await viewModel.refreshStatus()
        }
        .sheet(item: $shareArchive) { shareArchive in
            SettingsExportActivitySheet(fileURL: shareArchive.fileURL)
        }
        .fileImporter(
            isPresented: $isShowingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: handleImportSelection
        )
    }

    private func triggerImportArchive() {
        isShowingImporter = true
    }

    private func handleImportSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await viewModel.importArchive(from: url) }
        case .failure(let error):
            viewModel.statusMessage = error.localizedDescription
        }
    }

    private func triggerRequestExport() {
        Task { await viewModel.requestExport() }
    }

    private func triggerRefreshStatus() {
        Task { await viewModel.refreshStatus() }
    }

    private func triggerDownloadArchive() {
        Task {
            guard let fileURL = await viewModel.downloadArchive() else { return }
            shareArchive = SettingsExportShareItem(fileURL: fileURL)
        }
    }
}

private struct SettingsExportShareItem: Identifiable {
    let id = UUID()
    let fileURL: URL
}

#if canImport(UIKit)
private struct SettingsExportActivitySheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) { }
}
#else
private struct SettingsExportActivitySheet: View {
    let fileURL: URL

    var body: some View {
        Text(fileURL.lastPathComponent)
    }
}
#endif

struct SettingsFoodDataSourcesView: View {
#if DEBUG
    func _testEvaluateBody() {
        _ = body
    }
#endif

    var body: some View {
        Form {
            Section {
                Text(String(localized: "settings_food_data_sources_intro_primary"))
                    .font(LifeOSTypography.body)

                Text(String(localized: "settings_food_data_sources_intro_secondary"))
                    .font(LifeOSTypography.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text(String(localized: "settings_food_data_sources_lookup_header"))
            }

            Section {
                SettingsFoodDataSourceCard(
                    title: String(localized: "settings_food_data_sources_source_personal_title"),
                    systemImage: "person.crop.circle.badge.checkmark",
                    badge: String(localized: "settings_food_data_sources_source_personal_badge"),
                    detail: String(localized: "settings_food_data_sources_source_personal_detail")
                )

                SettingsFoodDataSourceCard(
                    title: String(localized: "settings_food_data_sources_source_off_title"),
                    systemImage: "globe",
                    badge: String(localized: "settings_food_data_sources_source_off_badge"),
                    detail: String(localized: "settings_food_data_sources_source_off_detail")
                )

                SettingsFoodDataSourceCard(
                    title: String(localized: "settings_food_data_sources_source_ocr_title"),
                    systemImage: "camera.viewfinder",
                    badge: String(localized: "settings_food_data_sources_source_ocr_badge"),
                    detail: String(localized: "settings_food_data_sources_source_ocr_detail")
                )
            } header: {
                Text(String(localized: "settings_food_data_sources_sources_header"))
            }

            Section {
                LabeledContent(String(localized: "settings_food_data_sources_priority_first_title")) {
                    Text(String(localized: "settings_food_data_sources_priority_first_value"))
                        .foregroundStyle(.secondary)
                }

                LabeledContent(String(localized: "settings_food_data_sources_priority_second_title")) {
                    Text(String(localized: "settings_food_data_sources_priority_second_value"))
                        .foregroundStyle(.secondary)
                }

                LabeledContent(String(localized: "settings_food_data_sources_priority_third_title")) {
                    Text(String(localized: "settings_food_data_sources_priority_third_value"))
                        .foregroundStyle(.secondary)
                }

                LabeledContent(String(localized: "settings_food_data_sources_priority_fourth_title")) {
                    Text(String(localized: "settings_food_data_sources_priority_fourth_value"))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "settings_food_data_sources_priority_header"))
            } footer: {
                Text(String(localized: "settings_food_data_sources_priority_footer"))
            }

            Section {
                Text(String(localized: "settings_food_data_sources_cache_catalog"))

                Text(String(localized: "settings_food_data_sources_cache_ocr"))

                Text(String(localized: "settings_food_data_sources_cache_photos"))
            } header: {
                Text(String(localized: "settings_food_data_sources_caching_header"))
            }

            Section {
                NavigationLink {
                    SettingsPrivacyView()
                } label: {
                    Label(String(localized: "settings_food_data_sources_review_privacy"), systemImage: "lock.shield")
                }
                .accessibilityIdentifier("settings.food_data_sources.privacy")

                PrivacyNoteView(.photoRetention)
                PrivacyNoteView(
                    .custom(
                        icon: "camera.aperture",
                        text: String(localized: "settings_food_data_sources_cloud_ocr_note")
                    )
                )
                PrivacyNoteView(
                    .custom(
                        icon: "checkmark.shield",
                        text: String(localized: "settings_food_data_sources_verification_note")
                    )
                )
            } header: {
                Text(String(localized: "settings_food_data_sources_controls_header"))
            } footer: {
                Text(String(localized: "settings_food_data_sources_controls_footer"))
            }

            Section {
                if let openFoodFactsURL = URL(string: "https://world.openfoodfacts.org") {
                    Link(destination: openFoodFactsURL) {
                        Label(String(localized: "settings_food_data_sources_open_food_facts_link"), systemImage: "arrow.up.right.square")
                    }
                    .accessibilityIdentifier("settings.food_data_sources.open_food_facts")
                }

                Text(String(localized: "settings_food_data_sources_external_disclosure"))
                    .font(LifeOSTypography.footnote)
                    .foregroundStyle(.secondary)

                Text(String(localized: "settings_food_data_sources_precision_note"))
                    .font(LifeOSTypography.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text(String(localized: "settings_food_data_sources_external_header"))
            }
        }
        .navigationTitle(String(localized: "settings_food_data_sources_title"))
        .accessibilityIdentifier("settings.food_data_sources.screen")
    }
}

private struct SettingsFoodDataSourceCard: View {
    let title: String
    let systemImage: String
    let badge: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Label(title, systemImage: systemImage)
                    .font(LifeOSTypography.subheadline.weight(.semibold))

                Spacer(minLength: Spacing.s)

                Text(badge)
                    .font(LifeOSTypography.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, Spacing.xxs)
                    .background(LifeOSColors.Surface.elevated)
                    .clipShape(Capsule())
            }

            Text(detail)
                .font(LifeOSTypography.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }
}

struct SettingsPrivacyView: View {
    @State private var viewModel: SettingsPrivacyViewModel
    @State private var showDeleteConfirmation = false

    init(
        syncEngine: SyncEngine = AppContainer.shared?.syncEngine ?? previewSyncEngine,
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue
    ) {
        _viewModel = State(initialValue: SettingsPrivacyViewModel(syncEngine: syncEngine, dbQueue: dbQueue))
    }

#if DEBUG
    fileprivate init(
        testSettings: PrivacySettings,
        testIsLoaded: Bool,
        testStatusMessage: String?,
        testAccountDeletionStatus: SettingsAccountDeletionSnapshot? = nil
    ) {
        let vm = SettingsPrivacyViewModel(
            syncEngine: previewSyncEngine,
            dbQueue: DatabaseManager.shared.dbQueue,
            enqueue: noopSettingsEnqueue,
            requestErasure: noopSettingsErasure,
            erasureStatusOperation: noopSettingsErasureStatus,
            cancelErasureOperation: noopSettingsCancelErasure
        )
        vm.settings = testSettings
        vm.isLoaded = testIsLoaded
        vm.statusMessage = testStatusMessage
        vm.accountDeletionStatus = testAccountDeletionStatus
        _viewModel = State(initialValue: vm)
    }

    func _testEvaluateBody() {
        _ = body
    }

    func _testTriggerActions() {
        triggerSave()
        triggerDeletePrompt()
        triggerDeleteAccount()
        triggerRefreshDeleteStatus()
        triggerCancelScheduledDeletion()
    }

    func _testCancelDeleteAccount() {
        cancelDeleteAccount()
    }
#endif

    var body: some View {
        @Bindable var viewModel = viewModel

        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
            if !viewModel.isLoaded {
                ProgressView(String(localized: "loading"))
            } else {
                privacySection {
                    privacyToggle(String(localized: "settings_menstrual_local_only"), isOn: $viewModel.settings.menstrualLocalOnly)
                    PrivacyNoteView(.menstrualLocalOnly)

                    privacyToggle(String(localized: "settings_medical_scan_local_only"), isOn: $viewModel.settings.medicalScanLocalOnly)
                    PrivacyNoteView(.medicalScanRetention)

                    privacyToggle(String(localized: "settings_cloud_backup_enabled"), isOn: $viewModel.settings.cloudBackupEnabled)
                    privacyToggle(String(localized: "settings_vector_opt_in"), isOn: $viewModel.settings.vectorOptIn)
                    privacyToggle(String(localized: "settings_analytics_consent"), isOn: $viewModel.settings.analyticsConsent)
                    privacyToggle(String(localized: "settings_ai_processing_consent"), isOn: $viewModel.settings.aiProcessingConsent)
                    PrivacyNoteView(.aiProcessing)
                    privacyToggle(String(localized: "settings_cloud_ocr_enabled"), isOn: $viewModel.settings.cloudOcrEnabled)
                } header: {
                    Text(String(localized: "settings_privacy"))
                } footer: {
                    privacyFooter(String(localized: "settings_privacy_footer"))
                }

                privacySection {
                    privacyToggle(String(localized: "settings_privacy_widget_recovery"), isOn: $viewModel.widgetPrivacy.showRecoveryScore)
                    privacyToggle(String(localized: "settings_privacy_widget_nutrition"), isOn: $viewModel.widgetPrivacy.showNutrition)
                    privacyToggle(String(localized: "settings_privacy_widget_supplements"), isOn: $viewModel.widgetPrivacy.showSupplements)
                    privacyToggle(String(localized: "settings_privacy_widget_workout"), isOn: $viewModel.widgetPrivacy.showTraining)
                } header: {
                    Text(String(localized: "settings_privacy_widgets_header"))
                } footer: {
                    privacyFooter(String(localized: "settings_privacy_widgets_footer"))
                }

                privacySection {
                    Button(action: triggerSave) {
                        Text(String(localized: "settings_save"))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: LayoutConstants.minTouchTarget, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("settings.privacy.save")
                }

                privacySection {
                    Label {
                        Text(viewModel.accountDeletionSummaryText)
                            .foregroundStyle(LifeOSColors.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: viewModel.accountDeletionSummaryIconName)
                            .foregroundStyle(viewModel.accountDeletionSummaryColor)
                    }

                    if viewModel.requiresCloudReconnect {
                        SettingsCloudReconnectNotice(requirement: .general)
                    }

                    if let snapshot = viewModel.accountDeletionStatus {
                        if let deletionDate = snapshot.deletionDateText {
                            LabeledContent(String(localized: "settings_delete_account_scheduled_for")) {
                                Text(deletionDate)
                                    .foregroundStyle(LifeOSColors.Text.secondary)
                            }
                        }

                        if let stateText = viewModel.deletionStateText(for: snapshot) {
                            LabeledContent(String(localized: "settings_delete_account_state_label")) {
                                Text(stateText)
                                    .foregroundStyle(LifeOSColors.Text.secondary)
                            }
                        }

                        if let modeText = viewModel.deletionModeText(for: snapshot) {
                            LabeledContent(String(localized: "settings_delete_account_mode_label")) {
                                Text(modeText)
                                    .foregroundStyle(LifeOSColors.Text.secondary)
                            }
                        }

                        if let reasonText = viewModel.deletionReasonText(for: snapshot) {
                            LabeledContent(String(localized: "settings_delete_account_reason_label")) {
                                Text(reasonText)
                                    .foregroundStyle(LifeOSColors.Text.secondary)
                            }
                        }

                        if let attemptCount = snapshot.deletionAttemptCount, attemptCount > 0 {
                            LabeledContent(String(localized: "settings_delete_account_attempts_label")) {
                                Text("\(attemptCount)")
                                    .foregroundStyle(LifeOSColors.Text.secondary)
                            }
                        }

                        if let retryText = viewModel.retryAfterText(for: snapshot) {
                            LabeledContent(String(localized: "settings_delete_account_retry_after_label")) {
                                Text(retryText)
                                    .foregroundStyle(LifeOSColors.Text.secondary)
                            }
                        }

                        if let note = viewModel.accountDeletionStatusNote {
                            Text(note)
                                .font(LifeOSTypography.footnote)
                                .foregroundStyle(LifeOSColors.Text.secondary)
                        }
                    }
                } header: {
                    Text(String(localized: "settings_delete_account_status_section"))
                }

                privacySection {
                    Button(action: triggerRefreshDeleteStatus) {
                        Text(String(localized: "settings_delete_account_refresh_status"))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: LayoutConstants.minTouchTarget, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                        .disabled(viewModel.isRefreshingDeletionStatus)
                        .accessibilityIdentifier("settings.privacy.delete_account.refresh")

                    Button(action: triggerCancelScheduledDeletion) {
                        Text(String(localized: "settings_delete_account_cancel_scheduled"))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: LayoutConstants.minTouchTarget, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                        .disabled(!viewModel.canCancelScheduledDeletion)
                        .accessibilityIdentifier("settings.privacy.delete_account.cancel")
                }

                // MARK: Account Deletion (GDPR / App Store requirement)
                privacySection {
                    Button(role: .destructive, action: triggerDeletePrompt) {
                        Label(String(localized: "settings_delete_account"), systemImage: "trash")
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: LayoutConstants.minTouchTarget, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(String(localized: "settings_delete_account_accessibility"))
                    .accessibilityIdentifier("settings.privacy.delete_account")
                    .disabled(!viewModel.canRequestDeletion)
                } header: {
                    Text(String(localized: "settings_danger_zone"))
                } footer: {
                    privacyFooter(viewModel.deleteActionFooterText)
                }
                .confirmationDialog(
                    String(localized: "settings_delete_account_confirm_title"),
                    isPresented: $showDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(
                        String(localized: "settings_delete_account_confirm_action"),
                        role: .destructive,
                        action: triggerDeleteAccount
                    )
                    .accessibilityIdentifier("settings.privacy.delete_account.confirm")
                    Button(String(localized: "settings_delete_account_cancel"), role: .cancel, action: cancelDeleteAccount)
                } message: {
                    Text(String(localized: "settings_delete_account_confirm_body"))
                }

                if let statusMessage = viewModel.statusMessage {
                    privacySection {
                        Text(statusMessage)
                            .font(LifeOSTypography.footnote)
                            .accessibilityIdentifier("settings.privacy.status")
                    }
                }
            }
            }
            .padding(Spacing.m)
        }
        .background(LifeOSColors.Surface.background)
        .navigationTitle(String(localized: "settings_privacy"))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.privacy.screen")
        .task(viewModel.load)
    }

    // Keep this finite form eager: every preference remains in the view tree
    // when larger Dynamic Type sizes move its row beyond the visible viewport.
    private func privacySection<Content: View, Header: View, Footer: View>(
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            header()
                .font(LifeOSTypography.headline)
                .foregroundStyle(LifeOSColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Spacing.m, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.m)
                .background(LifeOSColors.Surface.card, in: RoundedRectangle(cornerRadius: CornerRadius.md))
            footer()
        }
    }

    private func privacySection<Content: View, Header: View>(
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header
    ) -> some View {
        privacySection(content: content, header: header, footer: { EmptyView() })
    }

    private func privacySection<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        privacySection(content: content, header: { EmptyView() }, footer: { EmptyView() })
    }

    private func privacyToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(LifeOSTypography.body)
                .foregroundStyle(LifeOSColors.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 44)
    }

    private func privacyFooter(_ text: String) -> some View {
        Text(text)
            .font(LifeOSTypography.footnote)
            .foregroundStyle(LifeOSColors.Text.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func triggerSave() {
        Task { await viewModel.save() }
    }

    private func triggerDeletePrompt() {
        HapticManager.heavyImpact()
        showDeleteConfirmation = true
    }

    private func triggerDeleteAccount() {
        Task { await viewModel.deleteAccount() }
    }

    private func triggerRefreshDeleteStatus() {
        Task { await viewModel.refreshDeletionStatus() }
    }

    private func triggerCancelScheduledDeletion() {
        Task { await viewModel.cancelScheduledDeletion() }
    }

    private func cancelDeleteAccount() {
        showDeleteConfirmation = false
    }
}

private struct SettingsExportJobSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let status: String
    let requestedAt: Date?
    let completedAt: Date?
    let downloadUrl: String?
    let failureReason: String?
    let queuedLocally: Bool
    let blockedLocally: Bool
    let localErrorMessage: String?

    var isReady: Bool {
        if let downloadUrl, URL(string: downloadUrl) != nil {
            return true
        }
        return status.caseInsensitiveCompare("ready") == .orderedSame
    }

    var isInProgress: Bool {
        if queuedLocally { return true }
        switch status.lowercased() {
        case "queued", "pending", "processing":
            return true
        default:
            return false
        }
    }
}

private struct SettingsAccountDeletionSnapshot: Equatable, Sendable {
    let scheduled: Bool
    let deletionDate: String?
    let deletionInProgress: Bool
    let reason: String?
    let deletionState: String?
    let deletionMode: String?
    let deletionAttemptCount: Int?
    let retryAfterSeconds: Int?
    let idempotencyKey: String?
    let localDeleteQueued: Bool
    let localCancelQueued: Bool
    let localErrorMessage: String?

    var deletionDateText: String? {
        SettingsPrivacyFormatting.displayDateTime(for: deletionDate)
    }

    var canCancel: Bool {
        !deletionInProgress && (scheduled || localDeleteQueued) && !localCancelQueued
    }

    var blocksNewDeletionRequest: Bool {
        localDeleteQueued || localCancelQueued || scheduled || deletionInProgress
    }
}

private struct SettingsQueuedPrivacyEvent: Sendable {
    let createdAtLocal: Date
    let status: OutboxStatus
    let errorMessage: String?

    var isLocallyQueued: Bool {
        switch status {
        case .pending, .inFlight, .failedRetryable:
            return true
        case .succeeded, .failedPermanent, .cancelled:
            return false
        }
    }

    var isBlockedLocally: Bool {
        status == .failedPermanent
    }
}

private enum SettingsPrivacyFormatting {
    private static func makeISO8601Formatter(withFractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = withFractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }

    private static let retryFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        return formatter
    }()

    static func displayDateTime(for date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func displayDateTime(for isoString: String?) -> String? {
        guard let isoString else { return nil }
        if let parsed = parseISODate(isoString) {
            return displayDateTime(for: parsed)
        }
        return humanizedIdentifier(isoString)
    }

    static func retryAfterText(seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        return retryFormatter.string(from: TimeInterval(seconds)) ?? "\(seconds)s"
    }

    static func humanizedIdentifier(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let text = raw.replacingOccurrences(of: "_", with: " ")
        guard let first = text.first else { return nil }
        return first.uppercased() + text.dropFirst()
    }

    private static func parseISODate(_ isoString: String) -> Date? {
        if let withFractionalSeconds = makeISO8601Formatter(withFractionalSeconds: true).date(from: isoString) {
            return withFractionalSeconds
        }
        return makeISO8601Formatter(withFractionalSeconds: false).date(from: isoString)
    }
}

private func settingsHTTPStatusCode(_ error: Error) -> Int? {
    let nsError = error as NSError
    guard nsError.domain == "APIClientHTTPErrorDomain" else { return nil }
    return nsError.code
}

@MainActor
private func settingsRequiresCloudReconnect() -> Bool {
    SupabaseConfig.isRuntimeConfigured && AuthManager.activeRequiresCloudReauthentication
}

@MainActor
@Observable
private final class SettingsExportDataViewModel {
    var latestExport: SettingsExportJobSnapshot?
    var isLoaded = false
    var statusMessage: String?
    var isRequestingExport = false
    var isRefreshingStatus = false
    var isDownloadingExport = false
    var isImportingArchive = false
    var requiresCloudReconnect = false

    private let dbQueue: DatabaseQueue
    private let requestExportOperation: @MainActor () async throws -> ExportRequestResponse
    private let exportStatusOperation: @MainActor (String) async throws -> ExportStatusResponse
    private let downloadExportOperation: @MainActor (String) async throws -> URL
    private let importArchiveOperation: @MainActor (URL) async throws -> LocalPrivacyImportSummary
    private let explicitUserIdForTests: UUID?

    init(
        dbQueue: DatabaseQueue,
        requestExportOperation: @escaping @MainActor () async throws -> ExportRequestResponse = {
            try await PrivacyGateway().requestExport()
        },
        exportStatusOperation: @escaping @MainActor (String) async throws -> ExportStatusResponse = { exportId in
            try await PrivacyGateway().exportStatus(exportId: exportId)
        },
        downloadExportOperation: @escaping @MainActor (String) async throws -> URL = { exportId in
            try await PrivacyGateway().downloadExportArchive(exportId: exportId)
        },
        importArchiveOperation: @escaping @MainActor (URL) async throws -> LocalPrivacyImportSummary = { url in
            try await PrivacyGateway().importArchive(from: url)
        },
        explicitUserIdForTests: UUID? = nil
    ) {
        self.dbQueue = dbQueue
        self.requestExportOperation = requestExportOperation
        self.exportStatusOperation = exportStatusOperation
        self.downloadExportOperation = downloadExportOperation
        self.importArchiveOperation = importArchiveOperation
        self.explicitUserIdForTests = explicitUserIdForTests
    }

    var canDownloadLatestExport: Bool {
        latestExport?.downloadUrl != nil
    }

    var canRefreshStatus: Bool {
        latestExport != nil && !isRefreshingStatus && !isDownloadingExport && !requiresCloudReconnect
    }

    var canRequestExport: Bool {
        !requiresCloudReconnect &&
        !isRequestingExport &&
        !isDownloadingExport &&
        !(latestExport?.isInProgress ?? false)
    }

    func load() async {
        do {
            try await reloadLatestExport()
            if latestExport != nil && !requiresCloudReconnect {
                await refreshStatus(announceResult: false)
            }
        } catch {
            statusMessage = userFacingSettingsError(error, fallback: SettingsError.exportFailed)
            isLoaded = true
        }
    }

    func requestExport() async {
        guard !isRequestingExport else { return }
        guard !updateCloudReconnectRequirement() else {
            statusMessage = userFacingSettingsError(
                AuthError.cloudSessionReconnectRequired,
                fallback: SettingsError.exportFailed
            )
            return
        }
        isRequestingExport = true
        defer { isRequestingExport = false }

        do {
            _ = try await requestExportOperation()
            try await reloadLatestExport()
            if let latestExport {
                statusMessage = statusNote(for: latestExport) ?? statusText(for: latestExport)
            } else {
                statusMessage = String(localized: "settings_export_requested_message")
            }
        } catch {
            statusMessage = userFacingSettingsError(error, fallback: SettingsError.exportFailed)
        }
    }

    func refreshStatus() async {
        await refreshStatus(announceResult: true)
    }

    func downloadArchive() async -> URL? {
        guard !isDownloadingExport else { return nil }
        guard let exportId = latestExport?.id else {
            statusMessage = String(localized: "settings_export_no_request")
            return nil
        }

        isDownloadingExport = true
        defer { isDownloadingExport = false }

        do {
            let archiveURL = try await downloadExportOperation(exportId)
            do {
                try await reloadLatestExport()
            } catch { }
            if let latestExport {
                statusMessage = statusNote(for: latestExport) ?? statusText(for: latestExport)
            }
            return archiveURL
        } catch {
            do {
                try await reloadLatestExport()
            } catch { }

            if let privacyError = error as? PrivacyError,
               case .exportNotReady = privacyError,
               let latestExport {
                statusMessage = statusNote(for: latestExport) ?? userFacingSettingsError(
                    error,
                    fallback: SettingsError.exportFailed
                )
                return nil
            }

            statusMessage = userFacingSettingsError(error, fallback: SettingsError.exportFailed)
            return nil
        }
    }

    func importArchive(from url: URL) async {
        guard !isImportingArchive else { return }
        isImportingArchive = true
        defer { isImportingArchive = false }

        do {
            let summary = try await importArchiveOperation(url)
            statusMessage = String(
                format: String(localized: "settings_import_success_format"),
                summary.importedRows,
                summary.skippedRows
            )
        } catch {
            statusMessage = userFacingSettingsError(error, fallback: SettingsError.importFailed)
        }
    }

    func statusText(for export: SettingsExportJobSnapshot) -> String {
        if export.blockedLocally {
            return String(localized: "settings_export_status_failed")
        }
        if export.queuedLocally {
            return String(localized: "settings_export_status_queued_local")
        }

        switch export.status.lowercased() {
        case "queued", "pending":
            return String(localized: "settings_export_status_pending")
        case "processing":
            return String(localized: "settings_export_status_processing")
        case "ready":
            return String(localized: "settings_export_status_ready")
        case "failed":
            return String(localized: "settings_export_status_failed")
        default:
            return SettingsPrivacyFormatting.humanizedIdentifier(export.status)
                ?? String(localized: "settings_export_status_unknown")
        }
    }

    func statusIcon(for export: SettingsExportJobSnapshot) -> String {
        if export.blockedLocally || export.status.lowercased() == "failed" {
            return "exclamationmark.triangle.fill"
        }
        if export.isReady {
            return "checkmark.circle.fill"
        }
        if export.queuedLocally {
            return "arrow.triangle.2.circlepath.circle.fill"
        }
        return "clock.fill"
    }

    func statusColor(for export: SettingsExportJobSnapshot) -> Color {
        if export.blockedLocally || export.status.lowercased() == "failed" {
            return LifeOSColors.Semantic.destructive
        }
        if export.isReady {
            return LifeOSColors.Semantic.success
        }
        if export.queuedLocally {
            return LifeOSColors.Semantic.primary
        }
        return LifeOSColors.Semantic.warning
    }

    func statusNote(for export: SettingsExportJobSnapshot) -> String? {
        if let localErrorMessage = export.localErrorMessage, export.blockedLocally, !localErrorMessage.isEmpty {
            return localErrorMessage
        }
        if export.queuedLocally {
            return String(localized: "settings_export_waiting_sync")
        }
        if export.isReady {
            return String(localized: "settings_export_ready_note")
        }
        if export.status.lowercased() == "processing" || export.status.lowercased() == "pending" {
            return String(localized: "settings_export_processing_note")
        }
        if let failureReason = export.failureReason, !failureReason.isEmpty {
            return failureReason
        }
        return nil
    }

    private func refreshStatus(announceResult: Bool) async {
        guard !isRefreshingStatus else { return }
        guard let exportId = latestExport?.id else {
            if announceResult {
                statusMessage = String(localized: "settings_export_no_request")
            }
            isLoaded = true
            return
        }

        if updateCloudReconnectRequirement() {
            do {
                try await reloadLatestExport()
            } catch {
                statusMessage = userFacingSettingsError(error, fallback: SettingsError.exportFailed)
                return
            }
            if announceResult {
                statusMessage = userFacingSettingsError(
                    AuthError.cloudSessionReconnectRequired,
                    fallback: SettingsError.exportFailed
                )
            }
            return
        }

        isRefreshingStatus = true
        defer { isRefreshingStatus = false }

        do {
            _ = try await exportStatusOperation(exportId)
            try await reloadLatestExport()
            if announceResult, let latestExport {
                statusMessage = statusNote(for: latestExport) ?? statusText(for: latestExport)
            }
        } catch {
            do {
                try await reloadLatestExport()
            } catch {
                statusMessage = userFacingSettingsError(error, fallback: SettingsError.exportFailed)
                return
            }

            if settingsHTTPStatusCode(error) == 404, latestExport?.isInProgress == true {
                if announceResult {
                    statusMessage = String(localized: "settings_export_waiting_sync")
                }
                return
            }

            if announceResult {
                statusMessage = userFacingSettingsError(error, fallback: SettingsError.exportFailed)
            }
        }
    }

    private func reloadLatestExport() async throws {
        requiresCloudReconnect = settingsRequiresCloudReconnect()
        latestExport = try await fetchLatestExport()
        isLoaded = true
    }

    private func updateCloudReconnectRequirement() -> Bool {
        let requiresReconnect = settingsRequiresCloudReconnect()
        requiresCloudReconnect = requiresReconnect
        return requiresReconnect
    }

    private func fetchLatestExport() async throws -> SettingsExportJobSnapshot? {
        guard let userId = try await latestUserId() else { return nil }
        return try await dbQueue.read { db in
            let latestRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, status, download_url, requested_at, completed_at, failure_reason
                    FROM export_jobs
                    WHERE user_id = ? OR lower(CAST(user_id AS TEXT)) = lower(?)
                    ORDER BY requested_at DESC, updated_at DESC
                    LIMIT 1
                    """,
                arguments: [userId, userId.uuidString]
            )

            let latestQueuedEvent = try Self.latestOutboxExportEvent(in: db)

            let rowSnapshot: SettingsExportJobSnapshot? = {
                guard let latestRow else { return nil }
                let exportId: String? = latestRow["id"]
                let status: String? = latestRow["status"]
                guard let exportId, let status else { return nil }
                return SettingsExportJobSnapshot(
                    id: exportId,
                    status: status,
                    requestedAt: latestRow["requested_at"],
                    completedAt: latestRow["completed_at"],
                    downloadUrl: latestRow["download_url"],
                    failureReason: latestRow["failure_reason"],
                    queuedLocally: latestQueuedEvent?.exportId == exportId && latestQueuedEvent?.event.isLocallyQueued == true,
                    blockedLocally: latestQueuedEvent?.exportId == exportId && latestQueuedEvent?.event.isBlockedLocally == true,
                    localErrorMessage: latestQueuedEvent?.exportId == exportId ? latestQueuedEvent?.event.errorMessage : nil
                )
            }()

            if let rowSnapshot {
                if let latestQueuedEvent,
                   latestQueuedEvent.exportId != rowSnapshot.id,
                   latestQueuedEvent.event.createdAtLocal >= (rowSnapshot.requestedAt ?? .distantPast) {
                    return SettingsExportJobSnapshot(
                        id: latestQueuedEvent.exportId,
                        status: "queued",
                        requestedAt: latestQueuedEvent.event.createdAtLocal,
                        completedAt: nil,
                        downloadUrl: nil,
                        failureReason: nil,
                        queuedLocally: latestQueuedEvent.event.isLocallyQueued,
                        blockedLocally: latestQueuedEvent.event.isBlockedLocally,
                        localErrorMessage: latestQueuedEvent.event.errorMessage
                    )
                }
                return rowSnapshot
            }

            guard let latestQueuedEvent else { return nil }
            return SettingsExportJobSnapshot(
                id: latestQueuedEvent.exportId,
                status: "queued",
                requestedAt: latestQueuedEvent.event.createdAtLocal,
                completedAt: nil,
                downloadUrl: nil,
                failureReason: nil,
                queuedLocally: latestQueuedEvent.event.isLocallyQueued,
                blockedLocally: latestQueuedEvent.event.isBlockedLocally,
                localErrorMessage: latestQueuedEvent.event.errorMessage
            )
        }
    }

    private func latestUserId() async throws -> UUID? {
        if let explicitUserIdForTests {
            return explicitUserIdForTests
        }

        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        guard let authId else { return nil }
        return try await dbQueue.read { db in
            try UserIdentityLookup.resolveUserId(authId: authId, db: db)
        }
    }

    private nonisolated static func latestOutboxExportEvent(in db: Database) throws -> (exportId: String, event: SettingsQueuedPrivacyEvent)? {
        let rows = try OutboxEvent
            .filter(Column("path") == "api-user-export")
            .order(Column("created_at_local").desc)
            .limit(12)
            .fetchAll(db)

        for row in rows {
            guard let exportId = Self.exportId(from: row.bodyJson) else { continue }
            return (
                exportId: exportId,
                event: SettingsQueuedPrivacyEvent(
                    createdAtLocal: row.createdAtLocal,
                    status: row.status,
                    errorMessage: row.lastErrorMessage
                )
            )
        }
        return nil
    }

    private nonisolated static func exportId(from bodyJson: Data) -> String? {
        guard
            let payload = try? JSONSerialization.jsonObject(with: bodyJson) as? [String: Any],
            let exportId = payload["export_id"] as? String,
            !exportId.isEmpty
        else {
            return nil
        }
        return exportId
    }
}

@MainActor
@Observable
private final class SettingsSyncViewModel {
    var pendingCount: Int = 0
    var failedPermanentCount: Int = 0
    var oldestPendingAgeHours: Double?
    var statusMessage: String?
    var blocker: SyncBlockerSummary?
    var requiresCloudReconnect = false

    private let syncEngine: SyncEngine
    private let refreshOperation: @Sendable () async throws -> (SyncHealthMetrics, SyncBlockerSummary?)
    private let replayOperation: @Sendable () async throws -> Void
    private let pullOperation: @Sendable () async throws -> Void
    private let fixBlockerOperation: @Sendable (SyncBlockerSummary) async throws -> Void
    private let dismissBlockerOperation: @Sendable (UUID) async throws -> Void

    init(
        syncEngine: SyncEngine,
        refreshOperation: (@Sendable () async throws -> (SyncHealthMetrics, SyncBlockerSummary?))? = nil,
        replayOperation: (@Sendable () async throws -> Void)? = nil,
        pullOperation: (@Sendable () async throws -> Void)? = nil,
        fixBlockerOperation: (@Sendable (SyncBlockerSummary) async throws -> Void)? = nil,
        dismissBlockerOperation: (@Sendable (UUID) async throws -> Void)? = nil
    ) {
        self.syncEngine = syncEngine
        self.refreshOperation = refreshOperation ?? {
            let metrics = try await syncEngine.healthMetrics()
            let blocker = try await syncEngine.userVisibleBlocker()
            return (metrics, blocker)
        }
        self.replayOperation = replayOperation ?? {
            try await syncEngine.pushPendingEvents()
        }
        self.pullOperation = pullOperation ?? {
            try await syncEngine.pullAll()
        }
        self.fixBlockerOperation = fixBlockerOperation ?? { blocker in
            try await syncEngine.retryFailedPermanentEvent(blocker.id)
        }
        self.dismissBlockerOperation = dismissBlockerOperation ?? { blockerId in
            try await syncEngine.cancelEvent(blockerId)
        }
    }

    var oldestPendingText: String {
        guard let oldestPendingAgeHours else { return "—" }
        let rounded = Int(oldestPendingAgeHours.rounded())
        return "\(rounded)h"
    }

    func refresh() async {
        requiresCloudReconnect = settingsRequiresCloudReconnect()
        do {
            let (metrics, blocker) = try await refreshOperation()
            pendingCount = metrics.pendingCount
            failedPermanentCount = metrics.failedPermanentCount
            oldestPendingAgeHours = metrics.oldestPendingAgeHours
            self.blocker = blocker
            statusMessage = nil
        } catch {
            statusMessage = userFacingSettingsError(error, fallback: SyncError.serverError(code: 0, message: nil))
        }
    }

    func replayNow() async {
        guard !updateCloudReconnectRequirement() else {
            statusMessage = userFacingSettingsError(SyncError.authRequired, fallback: SyncError.authRequired)
            return
        }
        do {
            try await replayOperation()
            statusMessage = String(localized: "settings_saved")
            await refresh()
        } catch {
            statusMessage = userFacingSettingsError(error, fallback: SyncError.networkUnavailable)
        }
    }

    func pullNow() async {
        guard !updateCloudReconnectRequirement() else {
            statusMessage = userFacingSettingsError(SyncError.authRequired, fallback: SyncError.authRequired)
            return
        }
        do {
            try await pullOperation()
            statusMessage = String(localized: "settings_saved")
            await refresh()
        } catch {
            statusMessage = userFacingSettingsError(error, fallback: SyncError.serverError(code: 0, message: nil))
        }
    }

    func fixBlocker() async {
        guard let blocker else { return }
        do {
            try await fixBlockerOperation(blocker)
            statusMessage = String(localized: "settings_saved")
            await refresh()
        } catch {
            statusMessage = userFacingSettingsError(error, fallback: SyncError.networkUnavailable)
        }
    }

    func dismissBlocker() async {
        guard let blocker else { return }
        do {
            try await dismissBlockerOperation(blocker.id)
            statusMessage = String(localized: "settings_saved")
            await refresh()
        } catch {
            statusMessage = userFacingSettingsError(error, fallback: SyncError.serverError(code: 0, message: nil))
        }
    }

    func blockerSummary(for blocker: SyncBlockerSummary) -> String {
        let errorText = blocker.errorMessage ?? String(localized: "settings_sync_blocker_error_unknown")
        return String(format: String(localized: "settings_sync_blocker_summary_format"), blocker.path, errorText)
    }

    func blockerGuidance(for blocker: SyncBlockerSummary) -> String {
        switch blocker.path {
        case "api-food-log", "api-nutrition-batches":
            return String(localized: "settings_sync_blocker_guidance_food")
        case "api-settings-notifications":
            return String(localized: "settings_sync_blocker_guidance_notifications")
        case "api-settings-privacy":
            return String(localized: "settings_sync_blocker_guidance_privacy")
        case "api-account-delete", "api-account-delete-cancel", "api-user-export":
            return String(localized: "settings_sync_blocker_guidance_privacy_request")
        default:
            return String(localized: "settings_sync_blocker_guidance_generic")
        }
    }

    private func updateCloudReconnectRequirement() -> Bool {
        let requiresReconnect = settingsRequiresCloudReconnect()
        requiresCloudReconnect = requiresReconnect
        return requiresReconnect
    }
}

private struct GuardianBlockedAppSummary: Identifiable, Equatable {
    let id: String
    let displayName: String
}

@MainActor
@Observable
private final class SettingsNotificationsViewModel {
    var settings = NotificationSettings(userId: UUID())
    var isLoaded = false
    var statusMessage: String?
#if DEBUG
    var testLastErrorDescription: String?
#endif

    // Guardian Mode
    var selection = GuardianManager.shared.loadSelection()
    var guardianSnapshot: GuardianRuntimeSnapshot = .inactive
    var isPickingApps = false

    private let syncEngine: SyncEngine
    private let dbQueue: DatabaseQueue
    private let featureFlags: FeatureFlagManager
    private let enqueue: @MainActor (SyncEngine, String, HTTPMethod, [String: Any]) async throws -> Void
    private let requestErasure: @MainActor (String) async throws -> Void
    private let explicitUserIdForTests: UUID?

    init(
        syncEngine: SyncEngine,
        dbQueue: DatabaseQueue,
        featureFlags: FeatureFlagManager? = nil,
        enqueue: @escaping @MainActor (SyncEngine, String, HTTPMethod, [String: Any]) async throws -> Void = enqueueOutbox,
        requestErasure: @escaping @MainActor (String) async throws -> Void = { reason in
            try await PrivacyGateway().requestErasure(reason: reason)
        },
        explicitUserIdForTests: UUID? = nil
    ) {
        self.syncEngine = syncEngine
        self.dbQueue = dbQueue
        self.featureFlags = featureFlags ?? AppContainer.shared?.featureFlags ?? FeatureFlagManager(dbQueue: dbQueue)
        self.enqueue = enqueue
        self.requestErasure = requestErasure
        self.explicitUserIdForTests = explicitUserIdForTests
    }

    var blockedApps: [GuardianBlockedAppSummary] {
        selection.applications
            .map { application in
                GuardianBlockedAppSummary(
                    id: application.bundleIdentifier ?? application.localizedDisplayName ?? "selected-app",
                    displayName: application.localizedDisplayName ?? application.bundleIdentifier ?? String(localized: "settings_notifications_selected_app")
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var blockedCategoryCount: Int {
        selection.categoryTokens.count
    }

    var blockedWebDomainCount: Int {
        selection.webDomainTokens.count
    }

    var isGuardianCapabilityAvailable: Bool {
        AppCapabilityAvailability.isFamilyControlsAvailable
    }

    var isGuardianFeatureEnabled: Bool {
        featureFlags.isEnabled(.guardianModeEnabled)
    }

    var canUseGuardianSystemControls: Bool {
        isGuardianFeatureEnabled && isGuardianCapabilityAvailable
    }

    var guardianAvailabilityMessage: String? {
        if !isGuardianFeatureEnabled {
            return String(localized: "settings_notifications_guardian_feature_disabled")
        }
        if settings.controlLevel == .guardian && !isGuardianCapabilityAvailable {
            return AppCapabilityAvailability.familyControlsUnavailableMessage
        }
        return nil
    }

    var capabilityMessages: [String] {
        var messages: [String] = []
        if let remotePushStatusMessage = PushNotificationManager.shared.remotePushStatusMessage {
            messages.append(remotePushStatusMessage)
        }
        return messages
    }

    var canActivateEmergencyOverride: Bool {
        settings.controlLevel == .guardian &&
            settings.focusControlEnabled &&
            canUseGuardianSystemControls &&
            !isGuardianPausedToday
    }

    var guardianStatusDescription: String {
        if let guardianAvailabilityMessage {
            return guardianAvailabilityMessage
        }
        switch guardianSnapshot.state {
        case .inactive:
            return String(localized: "settings_notifications_guardian_no_active_window")
        case .pausedToday:
            return String(localized: "settings_notifications_guardian_paused_today")
        case .active:
            guard let session = guardianSnapshot.session else {
                return String(localized: "settings_notifications_guardian_active")
            }
            let window = "\(session.startedAt.formatted(date: .omitted, time: .shortened)) - \(session.endsAt.formatted(date: .omitted, time: .shortened))"
            return String.localizedStringWithFormat(
                String(localized: "settings_notifications_guardian_restriction_window_format"),
                window,
                session.reason
            )
        }
    }

    private var isGuardianPausedToday: Bool {
        if case .pausedToday = guardianSnapshot.state {
            return true
        }
        return false
    }

    func load() async {
        do {
            guard let userId = try await latestUserId() else {
                statusMessage = String(localized: "settings_sync_engine_unavailable")
                isLoaded = true
                return
            }

            let loaded = try await dbQueue.read { db in
                try NotificationSettings.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM notification_settings
                        WHERE user_id = ? OR user_id = ?
                        ORDER BY updated_at DESC
                        LIMIT 1
                        """,
                    arguments: [userId, userId.uuidString]
                )
            }

            if let loaded {
                applyLoadedSettings(loaded)
                let runtimeResult = await GuardianManager.shared.refreshRuntimeState(
                    dbQueue: dbQueue,
                    syncEngine: syncEngine
                )
                applyGuardianRuntimeResult(runtimeResult)
                return
            }

            settings = NotificationSettings(userId: userId)
            applyGuardianAvailabilityPolicy()
            let settingsToInsert = settings
            try await dbQueue.write { db in
                try settingsToInsert.insert(db)
            }
            try await completeInitialInsertLoad()
            let runtimeResult = await GuardianManager.shared.refreshRuntimeState(
                dbQueue: dbQueue,
                syncEngine: syncEngine
            )
            applyGuardianRuntimeResult(runtimeResult)
        } catch {
#if DEBUG
            let userIds = await debugUserIdsForErrorContext()
            testLastErrorDescription = "\(error) | settings.userId=\(settings.userId.uuidString) | users=\(userIds)"
#endif
            statusMessage = userFacingSettingsError(error, fallback: SettingsError.saveFailed)
            isLoaded = true
        }
    }

    func save() async {
        guard isLoaded else { return }
        do {
            applyGuardianAvailabilityPolicy()
            _ = await updateGuardianState()
            settings = settings.normalizedForInvariants(
                guardianModeEnabled: isGuardianFeatureEnabled
            )
            settings.updatedAt = Date()

            let settingsToSave = settings
            try await dbQueue.write { db in
                try settingsToSave.save(db)
            }

            try await enqueue(
                syncEngine,
                "api-settings-notifications",
                .PATCH,
                settings.apiPayload(guardianModeEnabled: isGuardianFeatureEnabled)
            )
            if let notificationScheduler = AppContainer.shared?.notificationScheduler {
                await notificationScheduler.refreshSchedules()
            }
            let runtimeResult = await GuardianManager.shared.refreshRuntimeState(
                dbQueue: dbQueue,
                syncEngine: syncEngine
            )
            applyGuardianRuntimeResult(runtimeResult)
            GuardianManager.shared.dismissRuntimeBanner()
            statusMessage = String(localized: "settings_saved")
        } catch {
#if DEBUG
            let userIds = await debugUserIdsForErrorContext()
            testLastErrorDescription = "\(error) | settings.userId=\(settings.userId.uuidString) | users=\(userIds)"
#endif
            statusMessage = userFacingSettingsError(error, fallback: SettingsError.saveFailed)
        }
    }

    func saveSelection(_ newSelection: FamilyActivitySelection) {
        guard canUseGuardianSystemControls else { return }
        selection = GuardianManager.shared.saveSelection(newSelection, settings: settings)
        guardianSnapshot = GuardianManager.shared.syncEnforcementState(settings: settings)
    }

    func activateGuardianEmergencyOverride() async {
        guard canActivateEmergencyOverride else {
            statusMessage = guardianAvailabilityMessage ?? String(localized: "settings_notifications_guardian_unavailable")
            return
        }
        guardianSnapshot = GuardianManager.shared.pauseControlForToday(settings: settings)
        statusMessage = String(localized: "settings_notifications_emergency_override_enabled")
        selection = GuardianManager.shared.loadSelection()
        if let userId = try? await latestUserId() {
            await GuardianManager.shared.recordEmergencyOverride(userId: userId, dbQueue: dbQueue)
        }
    }

    private func updateGuardianState() async -> Bool {
        var guardianAuthorizationApplied = true
        if !isGuardianFeatureEnabled &&
            (settings.controlLevel == .guardian || settings.focusControlEnabled) {
            applyGuardianAvailabilityPolicy()
            selection = GuardianManager.shared.saveSelection(selection, settings: settings)
            guardianSnapshot = GuardianManager.shared.syncEnforcementState(settings: settings)
            return false
        }
        if settings.controlLevel == .guardian && settings.focusControlEnabled {
            guard isGuardianCapabilityAvailable else {
                settings.focusControlEnabled = false
                settings.controlLevel = .protective
                statusMessage = AppCapabilityAvailability.familyControlsUnavailableMessage
                selection = GuardianManager.shared.saveSelection(selection, settings: settings)
                guardianSnapshot = GuardianManager.shared.syncEnforcementState(settings: settings)
                return false
            }
            do {
                try await GuardianManager.shared.requestAuthorization()
                settings.focusControlLastGrantedAt = Date()
            } catch {
                settings.focusControlEnabled = false
                settings.controlLevel = .protective
#if DEBUG
                testLastErrorDescription = String(describing: error)
#endif
                statusMessage = userFacingSettingsError(error, fallback: SettingsError.saveFailed)
                guardianAuthorizationApplied = false
            }
        }

        selection = GuardianManager.shared.saveSelection(selection, settings: settings)
        guardianSnapshot = GuardianManager.shared.syncEnforcementState(settings: settings)
        return guardianAuthorizationApplied
    }

    fileprivate func applyLoadedSettings(_ loaded: NotificationSettings) {
        settings = loaded
        applyGuardianAvailabilityPolicy()
        selection = GuardianManager.shared.loadSelection()
        guardianSnapshot = GuardianManager.shared.syncEnforcementState(settings: settings)
        isLoaded = true
    }

    fileprivate func completeInitialInsertLoad() async throws {
        try await enqueue(
            syncEngine,
            "api-settings-notifications",
            .POST,
            settings.apiPayload(guardianModeEnabled: isGuardianFeatureEnabled)
        )
        if let notificationScheduler = AppContainer.shared?.notificationScheduler {
            await notificationScheduler.refreshSchedules()
        }
        isLoaded = true
    }

    private func applyGuardianRuntimeResult(_ result: GuardianRuntimeRefreshResult) {
        if let settings = result.settings {
            self.settings = settings
            applyGuardianAvailabilityPolicy(setStatusMessage: false)
        }
        selection = GuardianManager.shared.loadSelection()
        guardianSnapshot = result.snapshot
        if let runtimeBannerMessage = GuardianManager.shared.runtimeBannerMessage {
            statusMessage = runtimeBannerMessage
        }
    }

    private func applyGuardianAvailabilityPolicy(setStatusMessage: Bool = true) {
        let wasGuardianRequested = settings.controlLevel == .guardian || settings.focusControlEnabled
        let normalized = settings.normalizedForInvariants(
            guardianModeEnabled: isGuardianFeatureEnabled
        )
        let didDowngradeGuardian = !isGuardianFeatureEnabled && wasGuardianRequested &&
            (normalized.controlLevel != settings.controlLevel ||
                normalized.focusControlEnabled != settings.focusControlEnabled)
        settings = normalized
        if didDowngradeGuardian && setStatusMessage {
            statusMessage = guardianAvailabilityMessage
        }
    }

    func handleFeatureFlagSnapshotDidChange() async {
        guard isLoaded else { return }
        applyGuardianAvailabilityPolicy()
        selection = GuardianManager.shared.loadSelection()
        guardianSnapshot = GuardianManager.shared.syncEnforcementState(settings: settings)
        if let runtimeBannerMessage = GuardianManager.shared.runtimeBannerMessage {
            statusMessage = runtimeBannerMessage
        } else if !isGuardianFeatureEnabled {
            statusMessage = guardianAvailabilityMessage
        }
    }

    private func latestUserId() async throws -> UUID? {
        if let explicitUserIdForTests {
            return explicitUserIdForTests
        }

        guard let authId = AuthManager.activeAuthId?.uuidString else {
            return nil
        }

        return try await dbQueue.read { db in
            try UserIdentityLookup.resolveUserId(authId: authId, db: db)
        }
    }

    fileprivate nonisolated static func decodedUserId(from idString: String?) -> UUID? {
        guard let idString else { return nil }
        return UUID(uuidString: idString)
    }

#if DEBUG
    private func debugUserIdsForErrorContext() async -> [String] {
        do {
            return try await dbQueue.read { db in
                try String.fetchAll(db, sql: "SELECT id FROM users ORDER BY id")
            }
        } catch {
            return []
        }
    }
#endif
}

@MainActor
@Observable
private final class SettingsPrivacyViewModel {
    var settings = PrivacySettings(userId: UUID())
    var widgetPrivacy = WidgetPrivacySettings()
    var isLoaded = false
    var statusMessage: String?
    var accountDeletionStatus: SettingsAccountDeletionSnapshot?
    var isRefreshingDeletionStatus = false
    var isDeletingAccount = false
    var isCancellingScheduledDeletion = false
    var requiresCloudReconnect = false
#if DEBUG
    var testLastErrorDescription: String?
#endif

    private let syncEngine: SyncEngine
    private let dbQueue: DatabaseQueue
    private let enqueue: @MainActor (SyncEngine, String, HTTPMethod, [String: Any]) async throws -> Void
    private let requestErasure: @MainActor (String) async throws -> Void
    private let erasureStatusOperation: @MainActor () async throws -> ErasureStatusResponse
    private let cancelErasureOperation: @MainActor () async throws -> ErasureCancelResponse
    private let explicitUserIdForTests: UUID?

    init(
        syncEngine: SyncEngine,
        dbQueue: DatabaseQueue,
        enqueue: @escaping @MainActor (SyncEngine, String, HTTPMethod, [String: Any]) async throws -> Void = enqueueOutbox,
        requestErasure: @escaping @MainActor (String) async throws -> Void = { reason in
            try await PrivacyGateway().requestErasure(reason: reason)
        },
        erasureStatusOperation: @escaping @MainActor () async throws -> ErasureStatusResponse = {
            try await PrivacyGateway().erasureStatus()
        },
        cancelErasureOperation: @escaping @MainActor () async throws -> ErasureCancelResponse = {
            try await PrivacyGateway().cancelScheduledErasure()
        },
        explicitUserIdForTests: UUID? = nil
    ) {
        self.syncEngine = syncEngine
        self.dbQueue = dbQueue
        self.enqueue = enqueue
        self.requestErasure = requestErasure
        self.erasureStatusOperation = erasureStatusOperation
        self.cancelErasureOperation = cancelErasureOperation
        self.explicitUserIdForTests = explicitUserIdForTests
    }

    var accountDeletionSummaryText: String {
        guard let accountDeletionStatus else {
            return String(localized: "settings_delete_account_status_none")
        }
        if accountDeletionStatus.localCancelQueued {
            return String(localized: "settings_delete_account_status_cancel_queued")
        }
        if accountDeletionStatus.deletionInProgress {
            return String(localized: "settings_delete_account_status_in_progress")
        }
        if accountDeletionStatus.localDeleteQueued {
            return String(localized: "settings_delete_account_status_queued")
        }
        if accountDeletionStatus.scheduled {
            return String(localized: "settings_delete_account_status_scheduled")
        }
        switch accountDeletionStatus.deletionState?.lowercased() {
        case "completed":
            return String(localized: "settings_delete_account_state_completed")
        case "failed":
            return String(localized: "settings_delete_account_status_failed")
        case "cancelled":
            return String(localized: "settings_delete_account_state_cancelled")
        default:
            return String(localized: "settings_delete_account_status_none")
        }
    }

    var accountDeletionSummaryIconName: String {
        guard let accountDeletionStatus else { return "person.crop.circle.badge.checkmark" }
        if accountDeletionStatus.localCancelQueued {
            return "arrow.uturn.backward.circle.fill"
        }
        if accountDeletionStatus.deletionInProgress {
            return "hourglass.circle.fill"
        }
        if accountDeletionStatus.localDeleteQueued || accountDeletionStatus.scheduled {
            return "calendar.badge.clock"
        }
        if accountDeletionStatus.deletionState?.lowercased() == "failed" {
            return "exclamationmark.triangle.fill"
        }
        return "person.crop.circle.badge.checkmark"
    }

    var accountDeletionSummaryColor: Color {
        guard let accountDeletionStatus else { return Color.secondary }
        if accountDeletionStatus.localCancelQueued {
            return LifeOSColors.Semantic.primary
        }
        if accountDeletionStatus.deletionInProgress {
            return LifeOSColors.Semantic.warning
        }
        if accountDeletionStatus.localDeleteQueued || accountDeletionStatus.scheduled {
            return LifeOSColors.Semantic.warning
        }
        if accountDeletionStatus.deletionState?.lowercased() == "failed" {
            return LifeOSColors.Semantic.destructive
        }
        return LifeOSColors.Semantic.success
    }

    var accountDeletionStatusNote: String? {
        guard let accountDeletionStatus else { return nil }
        if let localErrorMessage = accountDeletionStatus.localErrorMessage, !localErrorMessage.isEmpty {
            return localErrorMessage
        }
        if accountDeletionStatus.localCancelQueued {
            return String(localized: "settings_delete_account_cancel_requested")
        }
        if accountDeletionStatus.localDeleteQueued {
            return String(localized: "settings_delete_account_scheduled")
        }
        if accountDeletionStatus.deletionInProgress {
            return String(localized: "settings_delete_account_in_progress_note")
        }
        if accountDeletionStatus.scheduled {
            return String(localized: "settings_delete_account_scheduled_note")
        }
        if accountDeletionStatus.deletionMode?.lowercased() == "local_only",
           accountDeletionStatus.deletionState?.lowercased() == "completed" {
            return String(localized: "settings_delete_account_local_only_completed")
        }
        if accountDeletionStatus.deletionState?.lowercased() == "failed" {
            return String(localized: "settings_delete_account_failed_note")
        }
        return nil
    }

    var canRequestDeletion: Bool {
        !requiresCloudReconnect &&
        !isDeletingAccount &&
        !isCancellingScheduledDeletion &&
        !(accountDeletionStatus?.blocksNewDeletionRequest ?? false)
    }

    var canCancelScheduledDeletion: Bool {
        !requiresCloudReconnect &&
        !isCancellingScheduledDeletion &&
        !isDeletingAccount &&
        (accountDeletionStatus?.canCancel ?? false)
    }

    var deleteActionFooterText: String {
        if requiresCloudReconnect {
            return String(localized: "settings_cloud_reconnect_notice")
        }
        if !canRequestDeletion {
            return accountDeletionStatusNote ?? String(localized: "settings_delete_account_footer")
        }
        return String(localized: "settings_delete_account_footer")
    }

    func load() async {
        requiresCloudReconnect = settingsRequiresCloudReconnect()
        do {
            widgetPrivacy = WidgetSnapshotStorage.loadPrivacy()
            guard let userId = try await latestUserId() else {
                statusMessage = String(localized: "settings_sync_engine_unavailable")
                isLoaded = true
                return
            }

            let loaded = try await dbQueue.read { db in
                try PrivacySettings.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM privacy_settings
                        WHERE user_id = ? OR user_id = ?
                        ORDER BY updated_at DESC
                        LIMIT 1
                        """,
                    arguments: [userId, userId.uuidString]
                )
            }

            if let loaded {
                applyLoadedSettings(loaded)
                await refreshDeletionStatus(announceResult: false)
                return
            }

            settings = PrivacySettings(userId: userId)
            let settingsToInsert = settings
            try await dbQueue.write { db in
                try settingsToInsert.insert(db)
            }
            try await completeInitialInsertLoad()
            await refreshDeletionStatus(announceResult: false)
        } catch {
#if DEBUG
            let userIds = await debugUserIdsForErrorContext()
            testLastErrorDescription = "\(error) | settings.userId=\(settings.userId.uuidString) | users=\(userIds)"
#endif
            statusMessage = userFacingSettingsError(error, fallback: SettingsError.saveFailed)
            isLoaded = true
        }
    }

    func save() async {
        guard isLoaded else { return }
        do {
            settings.updatedAt = Date()

            let settingsToSave = settings
            try await dbQueue.write { db in
                try settingsToSave.save(db)
            }

            WidgetSnapshotStorage.storePrivacy(widgetPrivacy)
            await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
            try await completeSave()
        } catch {
#if DEBUG
            let userIds = await debugUserIdsForErrorContext()
            testLastErrorDescription = "\(error) | settings.userId=\(settings.userId.uuidString) | users=\(userIds)"
#endif
            statusMessage = userFacingSettingsError(error, fallback: SettingsError.saveFailed)
        }
    }

    func deleteAccount() async {
        guard !isDeletingAccount else { return }
        guard !updateCloudReconnectRequirement() else {
            statusMessage = userFacingSettingsError(
                AuthError.cloudSessionReconnectRequired,
                fallback: SettingsError.deletionFailed
            )
            return
        }
        isDeletingAccount = true
        defer { isDeletingAccount = false }

        do {
            try await requestErasure("user_requested")
            await load()
            statusMessage = accountDeletionStatusNote ?? accountDeletionSummaryText
        } catch {
#if DEBUG
            let userIds = await debugUserIdsForErrorContext()
            testLastErrorDescription = "\(error) | settings.userId=\(settings.userId.uuidString) | users=\(userIds)"
#endif
            statusMessage = userFacingSettingsError(error, fallback: SettingsError.deletionFailed)
        }
    }

    func refreshDeletionStatus() async {
        await refreshDeletionStatus(announceResult: true)
    }

    func cancelScheduledDeletion() async {
        guard canCancelScheduledDeletion else { return }
        guard !updateCloudReconnectRequirement() else {
            statusMessage = userFacingSettingsError(
                AuthError.cloudSessionReconnectRequired,
                fallback: SettingsError.deletionFailed
            )
            return
        }
        isCancellingScheduledDeletion = true
        defer { isCancellingScheduledDeletion = false }

        do {
            _ = try await cancelErasureOperation()
            accountDeletionStatus = try await buildAccountDeletionSnapshot(remoteStatus: nil)
            statusMessage = String(localized: "settings_delete_account_cancel_requested")
        } catch {
#if DEBUG
            let userIds = await debugUserIdsForErrorContext()
            testLastErrorDescription = "\(error) | settings.userId=\(settings.userId.uuidString) | users=\(userIds)"
#endif
            statusMessage = userFacingSettingsError(error, fallback: SettingsError.deletionFailed)
        }
    }

    func deletionStateText(for snapshot: SettingsAccountDeletionSnapshot) -> String? {
        guard let state = snapshot.deletionState?.lowercased() else { return nil }
        switch state {
        case "requested":
            return String(localized: "settings_delete_account_state_requested")
        case "scheduled":
            return String(localized: "settings_delete_account_state_scheduled")
        case "auth_deleting":
            return String(localized: "settings_delete_account_state_auth_deleting")
        case "data_deleting":
            return String(localized: "settings_delete_account_state_data_deleting")
        case "vector_verifying":
            return String(localized: "settings_delete_account_state_vector_verifying")
        case "retry_scheduled":
            return String(localized: "settings_delete_account_state_retry_scheduled")
        case "completed":
            return String(localized: "settings_delete_account_state_completed")
        case "failed":
            return String(localized: "settings_delete_account_state_failed")
        case "cancelled":
            return String(localized: "settings_delete_account_state_cancelled")
        default:
            return SettingsPrivacyFormatting.humanizedIdentifier(state)
        }
    }

    func deletionModeText(for snapshot: SettingsAccountDeletionSnapshot) -> String? {
        guard let mode = snapshot.deletionMode?.lowercased() else { return nil }
        switch mode {
        case "local_erased_cloud_pending":
            return String(localized: "settings_delete_account_local_erased_cloud_pending")
        case "scheduled":
            return String(localized: "settings_delete_account_mode_scheduled")
        case "immediate":
            return String(localized: "settings_delete_account_mode_immediate")
        case "local_only":
            return String(localized: "settings_delete_account_mode_local_only")
        default:
            return SettingsPrivacyFormatting.humanizedIdentifier(mode)
        }
    }

    func deletionReasonText(for snapshot: SettingsAccountDeletionSnapshot) -> String? {
        guard let reason = snapshot.reason?.lowercased() else { return nil }
        switch reason {
        case "user_requested":
            return String(localized: "settings_delete_account_reason_user_requested")
        default:
            return SettingsPrivacyFormatting.humanizedIdentifier(reason)
        }
    }

    func retryAfterText(for snapshot: SettingsAccountDeletionSnapshot) -> String? {
        SettingsPrivacyFormatting.retryAfterText(seconds: snapshot.retryAfterSeconds)
    }

    fileprivate func applyLoadedSettings(_ loaded: PrivacySettings) {
        settings = loaded
        isLoaded = true
    }

    fileprivate func completeInitialInsertLoad() async throws {
        try await applyPrivacyOutboxPolicyIfNeeded()
        try await enqueue(syncEngine, "api-settings-privacy", .POST, Self.privacyPayload(from: settings))
        isLoaded = true
    }

    fileprivate func completeSave() async throws {
        try await applyPrivacyOutboxPolicyIfNeeded()
        try await enqueue(syncEngine, "api-settings-privacy", .PATCH, Self.privacyPayload(from: settings))
        statusMessage = String(localized: "settings_saved")
    }

    fileprivate func applyPrivacyOutboxPolicyIfNeeded() async throws {
        var pathsToCancel: [String] = []
        if settings.menstrualLocalOnly {
            pathsToCancel.append(contentsOf: ["api-menstrual-sync", "rest/v1/menstrual_logs"])
        }
        if settings.medicalScanLocalOnly {
            pathsToCancel.append(contentsOf: [
                "api-labs",
                "rest/v1/medical_scans",
                "rest/v1/health_measurements",
            ])
        }
        if !settings.cloudBackupEnabled {
            pathsToCancel.append("rest/v1/user_health_flags")
        }
        guard !pathsToCancel.isEmpty else { return }
        try await syncEngine.cancelPendingEvents(matchingPaths: Array(Set(pathsToCancel)))
    }

    private func latestUserId() async throws -> UUID? {
        if let explicitUserIdForTests {
            return explicitUserIdForTests
        }

        guard let authId = AuthManager.activeAuthId?.uuidString else {
            return nil
        }

        return try await dbQueue.read { db in
            try UserIdentityLookup.resolveUserId(authId: authId, db: db)
        }
    }

    fileprivate nonisolated static func decodedUserId(from idString: String?) -> UUID? {
        guard let idString else { return nil }
        return UUID(uuidString: idString)
    }

    private func refreshDeletionStatus(announceResult: Bool) async {
        guard !isRefreshingDeletionStatus else { return }
        isRefreshingDeletionStatus = true
        defer { isRefreshingDeletionStatus = false }

        let reconnectRequired = updateCloudReconnectRequirement()
        do {
            let remoteStatus = try await erasureStatusOperationIfNeeded(reconnectRequired: reconnectRequired)
            accountDeletionStatus = try await buildAccountDeletionSnapshot(remoteStatus: remoteStatus)
            if announceResult {
                if reconnectRequired {
                    statusMessage = String(localized: "settings_cloud_reconnect_notice")
                } else {
                    statusMessage = accountDeletionStatusNote ?? accountDeletionSummaryText
                }
            }
        } catch {
            do {
                accountDeletionStatus = try await buildAccountDeletionSnapshot(remoteStatus: nil)
            } catch {
                if announceResult {
                    statusMessage = userFacingSettingsError(error, fallback: SettingsError.deletionFailed)
                }
                return
            }

            if announceResult {
                if settingsHTTPStatusCode(error) == 404 {
                    statusMessage = accountDeletionStatusNote ?? accountDeletionSummaryText
                } else if accountDeletionStatus?.blocksNewDeletionRequest == true {
                    statusMessage = accountDeletionStatusNote ?? accountDeletionSummaryText
                } else {
                    statusMessage = userFacingSettingsError(error, fallback: SettingsError.deletionFailed)
                }
            }
        }
    }

    private func erasureStatusOperationIfNeeded(
        reconnectRequired: Bool
    ) async throws -> ErasureStatusResponse? {
        guard !reconnectRequired else { return nil }
        return try await erasureStatusOperation()
    }

    private func updateCloudReconnectRequirement() -> Bool {
        let requiresReconnect = settingsRequiresCloudReconnect()
        requiresCloudReconnect = requiresReconnect
        return requiresReconnect
    }

    private func buildAccountDeletionSnapshot(
        remoteStatus: ErasureStatusResponse?
    ) async throws -> SettingsAccountDeletionSnapshot? {
        let userId = settings.userId
        return try await dbQueue.read { db -> SettingsAccountDeletionSnapshot? in
            let deleteEvent = try Self.latestQueuedPrivacyEvent(path: "api-account-delete", in: db)
            let cancelEvent = try Self.latestQueuedPrivacyEvent(path: "api-account-delete-cancel", in: db)
            let latestLocalAudit = try Self.latestLocalDeletionAudit(for: userId, in: db)
            let latestLocalFailure = try Self.latestLocalDeletionFailure(for: userId, in: db)

            let localDeleteQueued: Bool
            let localCancelQueued: Bool
            let localErrorMessage: String?

            if let cancelEvent, cancelEvent.isLocallyQueued,
               cancelEvent.createdAtLocal >= (deleteEvent?.createdAtLocal ?? .distantPast) {
                localCancelQueued = true
                localDeleteQueued = false
                localErrorMessage = cancelEvent.errorMessage
            } else if let deleteEvent, deleteEvent.isLocallyQueued {
                localDeleteQueued = true
                localCancelQueued = false
                localErrorMessage = deleteEvent.errorMessage
            } else {
                localDeleteQueued = false
                localCancelQueued = false
                localErrorMessage = cancelEvent?.isBlockedLocally == true
                    ? cancelEvent?.errorMessage
                    : deleteEvent?.errorMessage
            }

            let resolvedRemoteStatus = Self.isMeaningful(remoteStatus)
                ? remoteStatus
                : (localDeleteQueued || localCancelQueued || localErrorMessage != nil
                    ? ErasureStatusResponse(
                        scheduled: false,
                        deletionDate: nil,
                        deletionInProgress: false,
                        reason: nil,
                        deletionState: nil,
                        deletionMode: nil,
                        deletionAttemptCount: nil,
                        retryAfterSeconds: nil,
                        idempotencyKey: nil
                    )
                    : nil)

            if let resolvedRemoteStatus {
                return SettingsAccountDeletionSnapshot(
                    scheduled: resolvedRemoteStatus.scheduled,
                    deletionDate: resolvedRemoteStatus.deletionDate,
                    deletionInProgress: resolvedRemoteStatus.deletionInProgress,
                    reason: resolvedRemoteStatus.reason,
                    deletionState: resolvedRemoteStatus.deletionState,
                    deletionMode: resolvedRemoteStatus.deletionMode,
                    deletionAttemptCount: resolvedRemoteStatus.deletionAttemptCount,
                    retryAfterSeconds: resolvedRemoteStatus.retryAfterSeconds,
                    idempotencyKey: resolvedRemoteStatus.idempotencyKey,
                    localDeleteQueued: localDeleteQueued,
                    localCancelQueued: localCancelQueued,
                    localErrorMessage: localErrorMessage
                )
            }

            if let latestLocalFailure,
               latestLocalAudit == nil || latestLocalFailure.createdAt >= (latestLocalAudit?.deletedAt ?? .distantPast) {
                return SettingsAccountDeletionSnapshot(
                    scheduled: false,
                    deletionDate: DateFormatting.iso8601FullString(from: latestLocalFailure.createdAt),
                    deletionInProgress: false,
                    reason: nil,
                    deletionState: "failed",
                    deletionMode: "local_only",
                    deletionAttemptCount: 1,
                    retryAfterSeconds: nil,
                    idempotencyKey: nil,
                    localDeleteQueued: false,
                    localCancelQueued: false,
                    localErrorMessage: latestLocalFailure.error
                )
            }

            if let latestLocalAudit {
                return SettingsAccountDeletionSnapshot(
                    scheduled: false,
                    deletionDate: DateFormatting.iso8601FullString(from: latestLocalAudit.deletedAt),
                    deletionInProgress: false,
                    reason: Self.deletionReason(from: latestLocalAudit.notes),
                    deletionState: latestLocalAudit.complianceVerified ? "completed" : "failed",
                    deletionMode: "local_only",
                    deletionAttemptCount: 1,
                    retryAfterSeconds: nil,
                    idempotencyKey: nil,
                    localDeleteQueued: false,
                    localCancelQueued: false,
                    localErrorMessage: nil
                )
            }

            return nil
        }
    }

    private nonisolated static func isMeaningful(_ remoteStatus: ErasureStatusResponse?) -> Bool {
        guard let remoteStatus else { return false }
        return remoteStatus.scheduled
            || remoteStatus.deletionInProgress
            || remoteStatus.deletionDate != nil
            || remoteStatus.reason != nil
            || remoteStatus.deletionState != nil
            || remoteStatus.deletionMode != nil
            || remoteStatus.deletionAttemptCount != nil
            || remoteStatus.retryAfterSeconds != nil
            || remoteStatus.idempotencyKey != nil
    }

    private nonisolated static func latestLocalDeletionAudit(
        for userId: UUID,
        in db: Database
    ) throws -> DeletionAuditLog? {
        try DeletionAuditLog.fetchOne(
            db,
            sql: """
                SELECT *
                FROM deletion_audit_log
                WHERE user_id_deleted = ? OR lower(CAST(user_id_deleted AS TEXT)) = lower(?)
                ORDER BY deleted_at DESC
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString]
        )
    }

    private nonisolated static func latestLocalDeletionFailure(
        for userId: UUID,
        in db: Database
    ) throws -> DeletionFailure? {
        try DeletionFailure.fetchOne(
            db,
            sql: """
                SELECT *
                FROM deletion_failures
                WHERE (user_id = ? OR lower(CAST(user_id AS TEXT)) = lower(?))
                  AND resolved = 0
                ORDER BY created_at DESC
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString]
        )
    }

    private nonisolated static func deletionReason(from notes: String?) -> String? {
        guard let notes, notes.hasPrefix("local_only:") else { return nil }
        return String(notes.dropFirst("local_only:".count))
    }

    private nonisolated static func latestQueuedPrivacyEvent(path: String, in db: Database) throws -> SettingsQueuedPrivacyEvent? {
        try OutboxEvent
            .filter(Column("path") == path)
            .order(Column("created_at_local").desc)
            .limit(1)
            .fetchOne(db)
            .map {
                SettingsQueuedPrivacyEvent(
                    createdAtLocal: $0.createdAtLocal,
                    status: $0.status,
                    errorMessage: $0.lastErrorMessage
                )
            }
    }

#if DEBUG
    private func debugUserIdsForErrorContext() async -> [String] {
        do {
            return try await dbQueue.read { db in
                try String.fetchAll(db, sql: "SELECT id FROM users ORDER BY id")
            }
        } catch {
            return []
        }
    }
#endif

    fileprivate static func privacyPayload(from settings: PrivacySettings) -> [String: Any] {
        [
            "id": settings.id.uuidString,
            "user_id": settings.userId.uuidString,
            "menstrual_local_only": settings.menstrualLocalOnly,
            "medical_scan_local_only": settings.medicalScanLocalOnly,
            "cloud_backup_enabled": settings.cloudBackupEnabled,
            "vector_opt_in": settings.vectorOptIn,
            "analytics_consent": settings.analyticsConsent,
            "ai_processing_consent": settings.aiProcessingConsent,
            "cloud_ocr_enabled": settings.cloudOcrEnabled
        ]
    }
}

@MainActor
func enqueueOutbox(syncEngine: SyncEngine, path: String, method: HTTPMethod, body: [String: Any]) async throws {
    let payload = try JSONSerialization.data(withJSONObject: body)
    let event = OutboxEvent(
        httpMethod: method,
        path: path,
        bodyJson: payload,
        priority: 90
    )
    try await syncEngine.enqueueMutation(event)
}

@MainActor
func userFacingSettingsError(_ error: Error, fallback: any LocalizedError) -> String {
    if let localizedError = error as? LocalizedError,
       let description = localizedError.errorDescription,
       !description.isEmpty {
        return description
    }
    if let fallbackDescription = fallback.errorDescription {
        return fallbackDescription
    }
    return String(localized: "settings_sync_engine_unavailable")
}

// MARK: - Previews Helpers
// Only for SwiftUI Previews to prevent crashing if AppContainer is not initialized
var previewSyncEngine: SyncEngine {
    SyncEngine(dbQueue: DatabaseManager.shared.dbQueue)
}

#if DEBUG
@MainActor
enum SettingsDestinationViewsTestHarness {
    @MainActor
    private static func noopEnqueue(
        _: SyncEngine,
        _: String,
        _: HTTPMethod,
        _: [String: Any]
    ) async throws { }

    private static func stringOrEmpty(_ value: String?) -> String {
        if let value {
            return value
        }
        return ""
    }

    private static func stringOrNilLiteral(_ value: String?) -> String {
        if let value {
            return value
        }
        return "nil"
    }

    private static func flagString(_ condition: Bool, trueValue: String) -> String {
        if condition {
            return trueValue
        }
        return ""
    }

    private static func statusMessageOrFallback(_ value: String?, fallback: String) -> String {
        if let value {
            return value
        }
        return fallback
    }

    nonisolated private static func deleteUsersMatchingAuth(_ authId: UUID, in db: Database) throws {
        try db.execute(
            sql: """
                DELETE FROM users
                WHERE auth_id = ? OR auth_id = ?
                """,
            arguments: [authId, authId.uuidString]
        )
    }

    nonisolated private static func upsertCanonicalUser(_ userId: UUID, authId: UUID, in db: Database) throws {
        try db.execute(
            sql: """
                DELETE FROM users
                WHERE id = ? OR id = ? OR auth_id = ? OR auth_id = ?
                """,
            arguments: [userId, userId.uuidString, authId, authId.uuidString]
        )
        let now = Date()
        try db.execute(
            sql: """
                INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                MixedUUIDStorage.encode(userId),
                MixedUUIDStorage.encode(authId),
                "UTC",
                "metric",
                now,
                now
            ]
        )
    }

    nonisolated private static func insertOutboxEvent(
        path: String,
        body: [String: Any],
        status: OutboxStatus = .pending,
        createdAt: Date = Date(),
        errorMessage: String? = nil,
        in db: Database
    ) throws {
        let payload = try JSONSerialization.data(withJSONObject: body)
        var event = OutboxEvent(httpMethod: .POST, path: path, bodyJson: payload, priority: 80)
        event.status = status
        event.createdAtLocal = createdAt
        event.updatedAtLocal = createdAt
        event.lastErrorMessage = errorMessage
        try event.insert(db)
    }

    nonisolated private static func insertExportJob(
        exportId: String,
        userId: UUID,
        status: String,
        downloadUrl: String? = nil,
        requestedAt: Date,
        completedAt: Date? = nil,
        failureReason: String? = nil,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO export_jobs (
                    id, user_id, status, download_url, requested_at,
                    completed_at, failure_reason, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                exportId,
                userId.uuidString,
                status,
                downloadUrl,
                requestedAt,
                completedAt,
                failureReason,
                requestedAt,
                completedAt ?? requestedAt
            ]
        )
    }

    static func exerciseOptionalStringHelpersWithNilBranches() -> [String] {
        [
            stringOrEmpty(nil),
            stringOrNilLiteral(nil),
            flagString(false, trueValue: "should_not_appear"),
            statusMessageOrFallback(nil, fallback: "fallback")
        ]
    }

    static func exerciseOptionalStringHelpersWithValueBranches() -> [String] {
        [
            stringOrEmpty("value"),
            stringOrNilLiteral("value"),
            flagString(true, trueValue: "flagged"),
            statusMessageOrFallback("status", fallback: "fallback")
        ]
    }

    static func exerciseBodyBranches() {
        let blocker = SyncBlockerSummary(
            id: UUID(),
            path: "api-food-log",
            errorCategory: nil,
            errorMessage: "failed"
        )
        SettingsSyncView(
            testPendingCount: 3,
            testFailedPermanentCount: 1,
            testOldestPendingAgeHours: 27,
            testStatusMessage: "Queued",
            testBlocker: blocker
        )._testEvaluateBody()
        SettingsSyncView(
            testPendingCount: 3,
            testFailedPermanentCount: 1,
            testOldestPendingAgeHours: 27,
            testStatusMessage: "Queued",
            testBlocker: blocker
        )._testTriggerActions()
        SettingsSyncView(
            testPendingCount: 0,
            testFailedPermanentCount: 0,
            testOldestPendingAgeHours: nil,
            testStatusMessage: nil,
            testBlocker: nil
        )._testEvaluateBody()

        var notificationSettings = NotificationSettings(userId: UUID())
        notificationSettings.controlLevel = .guardian
        notificationSettings.focusControlEnabled = true
        SettingsNotificationsView(
            testSettings: notificationSettings,
            testIsLoaded: true,
            testStatusMessage: "Saved",
            testIsPickingApps: true
        )._testEvaluateBody()
        SettingsNotificationsView(
            testSettings: notificationSettings,
            testIsLoaded: true,
            testStatusMessage: "Saved",
            testIsPickingApps: true
        )._testEvaluatePickerSheetContent()
        SettingsNotificationsView(
            testSettings: notificationSettings,
            testIsLoaded: true,
            testStatusMessage: "Saved",
            testIsPickingApps: true
        )._testTriggerActions()
        SettingsNotificationsView(
            testSettings: notificationSettings,
            testIsLoaded: false,
            testStatusMessage: nil
        )._testEvaluateBody()

        let exportSnapshot = SettingsExportJobSnapshot(
            id: UUID().uuidString,
            status: "ready",
            requestedAt: Date(),
            completedAt: Date(),
            downloadUrl: "https://example.com/export.zip",
            failureReason: nil,
            queuedLocally: false,
            blockedLocally: false,
            localErrorMessage: nil
        )
        SettingsExportDataView(
            testExport: exportSnapshot,
            testIsLoaded: true,
            testStatusMessage: "Ready"
        )._testEvaluateBody()
        SettingsExportDataView(
            testExport: exportSnapshot,
            testIsLoaded: true,
            testStatusMessage: "Ready"
        )._testTriggerActions()
        SettingsExportDataView(
            testExport: nil,
            testIsLoaded: false,
            testStatusMessage: nil
        )._testEvaluateBody()

        SettingsFoodDataSourcesView()._testEvaluateBody()

        var privacySettings = PrivacySettings(userId: UUID())
        privacySettings.cloudBackupEnabled = false
        let deletionSnapshot = SettingsAccountDeletionSnapshot(
            scheduled: true,
            deletionDate: ISO8601DateFormatter().string(from: Date()),
            deletionInProgress: false,
            reason: "user_requested",
            deletionState: "scheduled",
            deletionMode: "scheduled",
            deletionAttemptCount: 1,
            retryAfterSeconds: 120,
            idempotencyKey: UUID().uuidString,
            localDeleteQueued: false,
            localCancelQueued: false,
            localErrorMessage: nil
        )
        SettingsPrivacyView(
            testSettings: privacySettings,
            testIsLoaded: true,
            testStatusMessage: "Saved",
            testAccountDeletionStatus: deletionSnapshot
        )._testEvaluateBody()
        SettingsPrivacyView(
            testSettings: privacySettings,
            testIsLoaded: true,
            testStatusMessage: "Saved",
            testAccountDeletionStatus: deletionSnapshot
        )._testTriggerActions()
        SettingsPrivacyView(
            testSettings: privacySettings,
            testIsLoaded: true,
            testStatusMessage: "Saved",
            testAccountDeletionStatus: deletionSnapshot
        )._testCancelDeleteAccount()
        SettingsPrivacyView(
            testSettings: privacySettings,
            testIsLoaded: false,
            testStatusMessage: nil
        )._testEvaluateBody()
    }

    static func exerciseSyncViewModel(syncEngine: SyncEngine) async -> [String] {
        let vm = SettingsSyncViewModel(syncEngine: syncEngine)
        let beforeText = vm.oldestPendingText

        await vm.refresh()
        await vm.replayNow()
        await vm.pullNow()
        await vm.fixBlocker()
        await vm.dismissBlocker()

        let paths = [
            "api-food-log",
            "api-settings-notifications",
            "api-settings-privacy",
            "api-account-delete",
            "api-account-delete-cancel",
            "api-user-export",
            "something-else"
        ]

        var outputs = [beforeText]
        for path in paths {
            let blocker = SyncBlockerSummary(
                id: UUID(),
                path: path,
                errorCategory: nil,
                errorMessage: "boom"
            )
            outputs.append(vm.blockerSummary(for: blocker))
            outputs.append(vm.blockerGuidance(for: blocker))
        }
        outputs.append(
            vm.blockerSummary(
                for: SyncBlockerSummary(
                    id: UUID(),
                    path: "api-food-log",
                    errorCategory: nil,
                    errorMessage: nil
                )
            )
        )

        vm.blocker = SyncBlockerSummary(id: UUID(), path: "api-food-log", errorCategory: nil, errorMessage: nil)
        await vm.fixBlocker()
        vm.blocker = SyncBlockerSummary(id: UUID(), path: "api-settings-privacy", errorCategory: nil, errorMessage: nil)
        await vm.dismissBlocker()

        outputs.append(vm.oldestPendingText)
        let syncStatus = statusMessageOrFallback(vm.statusMessage, fallback: String(localized: "settings_saved"))
        vm.statusMessage = syncStatus
        outputs.append(syncStatus)
        return outputs
    }

    static func exerciseSyncViewModelFailureBranches(
        syncEngine: SyncEngine,
        dbQueue: DatabaseQueue
    ) async -> [String] {
        try? await dbQueue.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS outbox_events")
            try db.execute(sql: "DROP TABLE IF EXISTS sync_watermarks")
        }

        let vm = SettingsSyncViewModel(syncEngine: syncEngine)
        vm.blocker = SyncBlockerSummary(id: UUID(), path: "api-food-log", errorCategory: nil, errorMessage: "failed")

        await vm.refresh()
        let refreshMessage = stringOrEmpty(vm.statusMessage)

        await vm.replayNow()
        let replayMessage = stringOrEmpty(vm.statusMessage)

        await vm.fixBlocker()
        let fixMessage = stringOrEmpty(vm.statusMessage)

        await vm.dismissBlocker()
        let dismissMessage = stringOrEmpty(vm.statusMessage)

        return [refreshMessage, replayMessage, fixMessage, dismissMessage]
    }

    static func exerciseNotificationsViewModel(
        syncEngine: SyncEngine,
        dbQueue: DatabaseQueue
    ) async -> (isLoaded: Bool, statusMessage: String?) {
        let vm = SettingsNotificationsViewModel(syncEngine: syncEngine, dbQueue: dbQueue)
        await vm.save()
        await vm.load()
        await vm.load()
        vm.saveSelection(FamilyActivitySelection())
        vm.settings.controlLevel = .guardian
        vm.settings.focusControlEnabled = true
        await vm.save()
        vm.settings.controlLevel = .advisory
        vm.settings.focusControlEnabled = false
        await vm.save()
        return (vm.isLoaded, vm.statusMessage)
    }

    static func exerciseExportViewModel(
        dbQueue: DatabaseQueue,
        authId: UUID,
        userId: UUID
    ) async throws -> (
        isLoaded: Bool,
        statusMessage: String?,
        exportId: String?,
        canDownload: Bool,
        queuedLocally: Bool
    ) {
        let exportId = UUID().uuidString
        let requestedAt = Date()

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
        }
        try await dbQueue.write { db in
            try upsertCanonicalUser(userId, authId: authId, in: db)
            try db.execute(sql: "DELETE FROM export_jobs")
            try db.execute(sql: "DELETE FROM outbox_events")
        }

        let vm = SettingsExportDataViewModel(
            dbQueue: dbQueue,
            requestExportOperation: {
                try await dbQueue.write { db in
                    try insertExportJob(
                        exportId: exportId,
                        userId: userId,
                        status: "pending",
                        requestedAt: requestedAt,
                        in: db
                    )
                    try insertOutboxEvent(
                        path: "api-user-export",
                        body: ["export_id": exportId],
                        status: .pending,
                        createdAt: requestedAt,
                        in: db
                    )
                }
                return ExportRequestResponse(exportId: exportId, status: "queued")
            },
            exportStatusOperation: { exportId in
                try await dbQueue.write { db in
                    try db.execute(
                        sql: "DELETE FROM outbox_events WHERE path = ?",
                        arguments: ["api-user-export"]
                    )
                    try db.execute(
                        sql: """
                            UPDATE export_jobs
                            SET status = ?, download_url = ?, completed_at = ?, updated_at = ?
                            WHERE id = ?
                            """,
                        arguments: [
                            "ready",
                            "https://example.com/\(exportId).zip",
                            Date(),
                            Date(),
                            exportId
                        ]
                    )
                }
                return ExportStatusResponse(
                    exportId: exportId,
                    status: "ready",
                    downloadUrl: "https://example.com/\(exportId).zip"
                )
            },
            explicitUserIdForTests: userId
        )

        await vm.load()
        await vm.requestExport()
        let queuedLocally = vm.latestExport?.queuedLocally ?? false
        await vm.refreshStatus()

        return (
            isLoaded: vm.isLoaded,
            statusMessage: vm.statusMessage,
            exportId: vm.latestExport?.id,
            canDownload: vm.canDownloadLatestExport,
            queuedLocally: queuedLocally
        )
    }

    static func exercisePrivacyViewModel(
        syncEngine: SyncEngine,
        dbQueue: DatabaseQueue
    ) async -> (isLoaded: Bool, statusMessage: String?, canCancelDeletion: Bool) {
        var remoteStatus = ErasureStatusResponse(
            scheduled: true,
            deletionDate: ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400)),
            deletionInProgress: false,
            reason: "user_requested",
            deletionState: "scheduled",
            deletionMode: "scheduled",
            deletionAttemptCount: 0,
            retryAfterSeconds: nil,
            idempotencyKey: UUID().uuidString
        )
        let vm = SettingsPrivacyViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            requestErasure: { _ in
                try await dbQueue.write { db in
                    try insertOutboxEvent(
                        path: "api-account-delete",
                        body: ["reason": "user_requested", "immediate": false],
                        in: db
                    )
                }
            },
            erasureStatusOperation: {
                remoteStatus
            },
            cancelErasureOperation: {
                remoteStatus = ErasureStatusResponse(
                    scheduled: false,
                    deletionDate: nil,
                    deletionInProgress: false,
                    reason: nil,
                    deletionState: "cancelled",
                    deletionMode: "scheduled",
                    deletionAttemptCount: 0,
                    retryAfterSeconds: nil,
                    idempotencyKey: UUID().uuidString
                )
                try await dbQueue.write { db in
                    try insertOutboxEvent(
                        path: "api-account-delete-cancel",
                        body: [:],
                        in: db
                    )
                }
                return ErasureCancelResponse(cancelled: true, status: nil, deletionState: "cancelled")
            }
        )
        await vm.save()
        await vm.load()
        await vm.load()
        await vm.save()
        await vm.deleteAccount()
        await vm.refreshDeletionStatus()
        let canCancelDeletion = vm.canCancelScheduledDeletion
        await vm.cancelScheduledDeletion()
        return (vm.isLoaded, vm.statusMessage, canCancelDeletion)
    }

    static func exercisePrivacyExistingLoadBranch(
        syncEngine: SyncEngine,
        dbQueue: DatabaseQueue
    ) async -> (isLoaded: Bool, usedExistingBranch: Bool) {
        let userId = UUID()
        let settingsId = UUID()
        let authId = UUID()
        let now = Date()
        try! await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM privacy_settings")
            try upsertCanonicalUser(userId, authId: authId, in: db)
            try db.execute(
                sql: """
                    INSERT INTO privacy_settings
                    (id, user_id, menstrual_local_only, medical_scan_local_only, cloud_backup_enabled, vector_opt_in, analytics_consent, cloud_ocr_enabled, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    settingsId.uuidString,
                    userId.uuidString,
                    true,
                    true,
                    false,
                    true,
                    true,
                    true,
                    now,
                    now
                ]
            )
        }

        let vm = SettingsPrivacyViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            explicitUserIdForTests: userId
        )
        await vm.load()
        return (vm.isLoaded, vm.settings.id == settingsId && vm.settings.vectorOptIn)
    }

    static func exercisePrivacyLoadFailureBranch(
        syncEngine: SyncEngine,
        dbQueue: DatabaseQueue
    ) async -> String {
        try? await dbQueue.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS privacy_settings")
            try db.execute(sql: "DROP TABLE IF EXISTS users")
        }

        let vm = SettingsPrivacyViewModel(syncEngine: syncEngine, dbQueue: dbQueue)
        await vm.load()
        return stringOrEmpty(vm.statusMessage)
    }

    static func exerciseInsertionAndSaveSuccessPaths(
        syncEngine: SyncEngine,
        dbQueue: DatabaseQueue,
        authId: UUID,
        userId: UUID
    ) async -> (
        notificationsLoaded: Bool,
        privacyLoaded: Bool,
        notificationsStatus: String?,
        privacyStatus: String?
    ) {
        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
        }

        try? await dbQueue.write { db in
            try upsertCanonicalUser(userId, authId: authId, in: db)
            try db.execute(sql: "DELETE FROM notification_settings")
            try db.execute(sql: "DELETE FROM privacy_settings")
        }

        let enqueueSuccess = noopEnqueue
        let notifications = SettingsNotificationsViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: enqueueSuccess
        )
        await notifications.load()
        await notifications.load()
        notifications.settings.controlLevel = .advisory
        notifications.settings.focusControlEnabled = false
        await notifications.save()

        let privacy = SettingsPrivacyViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: enqueueSuccess
        )
        await privacy.load()
        await privacy.load()
        await privacy.save()

        return (
            notificationsLoaded: notifications.isLoaded,
            privacyLoaded: privacy.isLoaded,
            notificationsStatus: notifications.statusMessage,
            privacyStatus: privacy.statusMessage
        )
    }

    static func exerciseLatestUserIdAndExistingLoadBranches(
        syncEngine: SyncEngine,
        dbQueue: DatabaseQueue,
        authId: UUID
    ) async -> [String] {
        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
        }

        try! await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM notification_settings")
            try db.execute(sql: "DELETE FROM privacy_settings")
            try deleteUsersMatchingAuth(authId, in: db)
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: ["invalid-user-id", authId.uuidString, "UTC", "metric", Date(), Date()]
            )
        }

        let notificationsInvalidUser = SettingsNotificationsViewModel(syncEngine: syncEngine, dbQueue: dbQueue)
        await notificationsInvalidUser.load()
        let notificationsInvalidStatus = stringOrEmpty(notificationsInvalidUser.statusMessage)

        let privacyInvalidUser = SettingsPrivacyViewModel(syncEngine: syncEngine, dbQueue: dbQueue)
        await privacyInvalidUser.load()
        let privacyInvalidStatus = stringOrEmpty(privacyInvalidUser.statusMessage)

        let userId = UUID()
        try? await dbQueue.write { db in
            try upsertCanonicalUser(userId, authId: authId, in: db)
        }

        let enqueueSuccess = noopEnqueue
        let notificationsInsert = SettingsNotificationsViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: enqueueSuccess
        )
        await notificationsInsert.load()
        await notificationsInsert.save()

        let privacyInsert = SettingsPrivacyViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: enqueueSuccess
        )
        await privacyInsert.load()
        await privacyInsert.save()

        let privacyExisting = SettingsPrivacyViewModel(syncEngine: syncEngine, dbQueue: dbQueue)
        await privacyExisting.load()

        return [
            notificationsInvalidStatus,
            privacyInvalidStatus,
            stringOrEmpty(notificationsInsert.statusMessage),
            stringOrEmpty(privacyInsert.statusMessage),
            stringOrEmpty(privacyExisting.statusMessage)
        ]
    }

    static func exerciseDeterministicCoverageBranches(
        syncEngine: SyncEngine,
        dbQueue: DatabaseQueue,
        authId: UUID
    ) async -> [String] {
        let enqueueSuccess = noopEnqueue
        let userId = UUID()

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(nil)
        }
        try? await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM notification_settings")
            try db.execute(sql: "DELETE FROM privacy_settings")
        }

        let notificationsNoAuth = SettingsNotificationsViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: enqueueSuccess
        )
        await notificationsNoAuth.load()

        let privacyNoAuth = SettingsPrivacyViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: enqueueSuccess
        )
        await privacyNoAuth.load()

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
        }
        try? await dbQueue.write { db in
            try upsertCanonicalUser(userId, authId: authId, in: db)
            try db.execute(sql: "DELETE FROM notification_settings")
            try db.execute(sql: "DELETE FROM privacy_settings")
        }

        let notificationsInsert = SettingsNotificationsViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: enqueueSuccess
        )
        await notificationsInsert.load()
        let notificationsLoaded = SettingsNotificationsViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: enqueueSuccess
        )
        await notificationsLoaded.load()

        let privacyInsert = SettingsPrivacyViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: enqueueSuccess
        )
        await privacyInsert.load()
        await privacyInsert.save()
        let privacyLoaded = SettingsPrivacyViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: enqueueSuccess
        )
        await privacyLoaded.load()

        return [
            stringOrEmpty(notificationsNoAuth.statusMessage),
            stringOrEmpty(privacyNoAuth.statusMessage),
            flagString(notificationsInsert.isLoaded, trueValue: "notifications_inserted"),
            flagString(notificationsLoaded.isLoaded, trueValue: "notifications_loaded_existing"),
            flagString(privacyInsert.isLoaded, trueValue: "privacy_inserted"),
            flagString(privacyLoaded.isLoaded, trueValue: "privacy_loaded_existing"),
            stringOrEmpty(privacyInsert.statusMessage)
        ]
    }

    static func exerciseNotificationsAndPrivacyLoadSaveCoverage(
        syncEngine: SyncEngine,
        dbQueue: DatabaseQueue,
        authId: UUID,
        userId: UUID
    ) async -> [String] {
        let enqueueSuccess = noopEnqueue
        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
        }

        try? await dbQueue.write { db in
            try upsertCanonicalUser(userId, authId: authId, in: db)
            try db.execute(sql: "DELETE FROM notification_settings")
            try db.execute(sql: "DELETE FROM privacy_settings")
        }

        let notificationsInsert = SettingsNotificationsViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: enqueueSuccess
        )
        await notificationsInsert.load()
        notificationsInsert.settings.controlLevel = .advisory
        notificationsInsert.settings.focusControlEnabled = false
        await notificationsInsert.save()

        let notificationsLoaded = SettingsNotificationsViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: enqueueSuccess
        )
        await notificationsLoaded.load()

        let privacyInsert = SettingsPrivacyViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: enqueueSuccess
        )
        await privacyInsert.load()
        await privacyInsert.save()

        let privacyLoaded = SettingsPrivacyViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: enqueueSuccess
        )
        await privacyLoaded.load()

        return [
            stringOrEmpty(notificationsInsert.statusMessage),
            stringOrEmpty(notificationsLoaded.statusMessage),
            stringOrEmpty(privacyInsert.statusMessage),
            stringOrEmpty(privacyLoaded.statusMessage),
            flagString(notificationsInsert.isLoaded, trueValue: "notifications_insert_loaded"),
            flagString(notificationsLoaded.isLoaded, trueValue: "notifications_existing_loaded"),
            flagString(privacyInsert.isLoaded, trueValue: "privacy_insert_loaded"),
            flagString(privacyLoaded.isLoaded, trueValue: "privacy_existing_loaded")
        ]
    }

    static func exerciseExplicitLoadSaveTransitionBranches(
        syncEngine: SyncEngine,
        dbQueue: DatabaseQueue,
        authId: UUID,
        userId: UUID
    ) async -> [String] {
        let enqueueSuccess = noopEnqueue

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
        }
        try! await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM notification_settings")
            try db.execute(sql: "DELETE FROM privacy_settings")
            try upsertCanonicalUser(userId, authId: authId, in: db)
        }

        let notificationsInsert = SettingsNotificationsViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: enqueueSuccess
        )
        await notificationsInsert.load()
        notificationsInsert.settings.controlLevel = .advisory
        notificationsInsert.settings.focusControlEnabled = false
        await notificationsInsert.save()

        let notificationsExisting = SettingsNotificationsViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: enqueueSuccess
        )
        await notificationsExisting.load()

        let privacyInsert = SettingsPrivacyViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: enqueueSuccess
        )
        await privacyInsert.load()
        await privacyInsert.save()

        let privacyExisting = SettingsPrivacyViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: enqueueSuccess
        )
        await privacyExisting.load()

        return [
            flagString(notificationsInsert.isLoaded, trueValue: "notifications_inserted"),
            flagString(notificationsExisting.isLoaded, trueValue: "notifications_existing"),
            flagString(privacyInsert.isLoaded, trueValue: "privacy_inserted"),
            flagString(privacyExisting.isLoaded, trueValue: "privacy_existing")
        ]
    }

    static func exerciseDirectViewModelHelperBranches(
        syncEngine: SyncEngine,
        dbQueue: DatabaseQueue
    ) async -> [String] {
        let enqueueSuccess = noopEnqueue
        let notifications = SettingsNotificationsViewModel(syncEngine: syncEngine, dbQueue: dbQueue, enqueue: enqueueSuccess)
        notifications.applyLoadedSettings(NotificationSettings(userId: UUID()))
        try? await notifications.completeInitialInsertLoad()
        let decodedNotificationUserId = stringOrEmpty(
            SettingsNotificationsViewModel.decodedUserId(from: UUID().uuidString)?.uuidString
        )
        let decodedNotificationNil = stringOrNilLiteral(
            SettingsNotificationsViewModel.decodedUserId(from: nil)?.uuidString
        )

        let privacy = SettingsPrivacyViewModel(syncEngine: syncEngine, dbQueue: dbQueue, enqueue: enqueueSuccess)
        privacy.applyLoadedSettings(PrivacySettings(userId: UUID()))
        try? await privacy.completeInitialInsertLoad()
        try? await privacy.completeSave()
        let decodedPrivacyUserId = stringOrEmpty(
            SettingsPrivacyViewModel.decodedUserId(from: UUID().uuidString)?.uuidString
        )
        let decodedPrivacyNil = stringOrNilLiteral(
            SettingsPrivacyViewModel.decodedUserId(from: nil)?.uuidString
        )

        return [
            flagString(notifications.isLoaded, trueValue: "notifications_loaded"),
            flagString(privacy.isLoaded, trueValue: "privacy_loaded"),
            decodedNotificationUserId,
            decodedNotificationNil,
            decodedPrivacyUserId,
            decodedPrivacyNil,
            stringOrEmpty(privacy.statusMessage)
        ]
    }

    static func exerciseDeterministicLoadAndSaveBranches(
        syncEngine: SyncEngine,
        dbQueue: DatabaseQueue,
        authId: UUID,
        userId: UUID
    ) async -> [String] {
        let enqueueSuccess = noopEnqueue
        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
        }

        try? await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM notification_settings")
            try db.execute(sql: "DELETE FROM privacy_settings")
            try upsertCanonicalUser(userId, authId: authId, in: db)
        }

        let notificationsInsert = SettingsNotificationsViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: enqueueSuccess,
            explicitUserIdForTests: userId
        )
        await notificationsInsert.load()

        let notificationsLoaded = SettingsNotificationsViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: enqueueSuccess,
            explicitUserIdForTests: userId
        )
        await notificationsLoaded.load()
        notificationsLoaded.settings.controlLevel = .advisory
        notificationsLoaded.settings.focusControlEnabled = false
        await notificationsLoaded.save()

        try! await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM privacy_settings")
        }

        let privacyInsert = SettingsPrivacyViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: enqueueSuccess,
            explicitUserIdForTests: userId
        )
        await privacyInsert.load()

        let privacyLoaded = SettingsPrivacyViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: enqueueSuccess,
            explicitUserIdForTests: userId
        )
        await privacyLoaded.load()
        await privacyLoaded.save()

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(nil)
        }

        return [
            flagString(notificationsInsert.isLoaded, trueValue: "notifications_insert_path"),
            flagString(notificationsLoaded.isLoaded, trueValue: "notifications_loaded_path"),
            statusMessageOrFallback(
                notificationsLoaded.testLastErrorDescription,
                fallback: statusMessageOrFallback(notificationsLoaded.statusMessage, fallback: "")
            ),
            flagString(privacyInsert.isLoaded, trueValue: "privacy_insert_path"),
            flagString(privacyLoaded.isLoaded, trueValue: "privacy_loaded_path"),
            statusMessageOrFallback(
                privacyLoaded.testLastErrorDescription,
                fallback: statusMessageOrFallback(privacyLoaded.statusMessage, fallback: "")
            )
        ]
    }

    static func exerciseMixedUUIDScopedExistingLoad(
        syncEngine: SyncEngine,
        dbQueue: DatabaseQueue,
        authId: UUID,
        userId: UUID,
        otherUserId: UUID
    ) async -> [String] {
        let enqueueSuccess = noopEnqueue
        let now = Date()
        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
        }

        try? await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM notification_settings")
            try db.execute(sql: "DELETE FROM privacy_settings")
            try upsertCanonicalUser(userId, authId: authId, in: db)

            try db.execute(
                sql: """
                    DELETE FROM users
                    WHERE id = ? OR id = ?
                    """,
                arguments: [otherUserId, otherUserId.uuidString]
            )
            var otherUser = User(id: otherUserId, authId: UUID(), timezone: "UTC", units: .metric)
            otherUser.createdAt = now
            otherUser.updatedAt = now.addingTimeInterval(60)
            try otherUser.insert(db)

            try db.execute(
                sql: """
                    INSERT INTO notification_settings (
                        id, user_id, morning_brief_enabled, positive_enabled, nudges_enabled,
                        celebration_enabled, critical_only, morning_brief_time_local,
                        quiet_hours_start, quiet_hours_end, max_positive_per_day,
                        max_nudges_per_day, max_celebration_per_day, max_total_per_day,
                        control_level, focus_control_enabled, focus_control_last_granted_at,
                        created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    otherUserId.uuidString,
                    false, false, false, false, false,
                    "09:00", "22:00", "07:00",
                    1, 1, 1, 3,
                    "guardian", false, nil,
                    now,
                    now.addingTimeInterval(120)
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO notification_settings (
                        id, user_id, morning_brief_enabled, positive_enabled, nudges_enabled,
                        celebration_enabled, critical_only, morning_brief_time_local,
                        quiet_hours_start, quiet_hours_end, max_positive_per_day,
                        max_nudges_per_day, max_celebration_per_day, max_total_per_day,
                        control_level, focus_control_enabled, focus_control_last_granted_at,
                        created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    true, true, true, true, false,
                    "07:00", "22:00", "07:00",
                    3, 2, 2, 6,
                    "advisory", false, nil,
                    now,
                    now
                ]
            )

            try db.execute(
                sql: """
                    INSERT INTO privacy_settings (
                        id, user_id, menstrual_local_only, medical_scan_local_only,
                        cloud_backup_enabled, vector_opt_in, analytics_consent, cloud_ocr_enabled,
                        created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    otherUserId.uuidString,
                    false, false, true, true, true, false,
                    now,
                    now.addingTimeInterval(120)
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO privacy_settings (
                        id, user_id, menstrual_local_only, medical_scan_local_only,
                        cloud_backup_enabled, vector_opt_in, analytics_consent, cloud_ocr_enabled,
                        created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    true, true, false, false, false, true,
                    now,
                    now
                ]
            )
        }

        let notifications = SettingsNotificationsViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: enqueueSuccess,
            explicitUserIdForTests: userId
        )
        await notifications.load()

        let privacy = SettingsPrivacyViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: enqueueSuccess,
            explicitUserIdForTests: userId
        )
        await privacy.load()

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(nil)
        }

        return [
            notifications.settings.userId.uuidString,
            privacy.settings.userId.uuidString,
            notifications.settings.controlLevel.rawValue,
            privacy.settings.cloudBackupEnabled ? "cloud_on" : "cloud_off"
        ]
    }

    static func exerciseGuardianAuthorizationFailure(
        syncEngine: SyncEngine,
        dbQueue: DatabaseQueue
    ) async -> String? {
        let vm = SettingsNotificationsViewModel(syncEngine: syncEngine, dbQueue: dbQueue)
        vm.isLoaded = true
        vm.settings.controlLevel = .guardian
        vm.settings.focusControlEnabled = true
        await vm.save()
        return vm.statusMessage
    }

    static func exerciseFailureBranches(
        syncEngine: SyncEngine,
        dbQueue: DatabaseQueue
    ) async -> [String] {
        func appendStatusMessage(_ message: String?, to outputs: inout [String]) {
            if let message {
                outputs.append(message)
            } else {
                outputs.append("")
            }
        }

        var outputs: [String] = []
        appendStatusMessage(nil, to: &outputs)

        let notificationsNoAuth = SettingsNotificationsViewModel(syncEngine: syncEngine, dbQueue: dbQueue)
        AuthManager.setActiveAuthIdForTests(nil)
        await notificationsNoAuth.load()
        appendStatusMessage(notificationsNoAuth.statusMessage, to: &outputs)

        let privacyNoAuth = SettingsPrivacyViewModel(syncEngine: syncEngine, dbQueue: dbQueue)
        await privacyNoAuth.load()
        appendStatusMessage(privacyNoAuth.statusMessage, to: &outputs)

        try? await dbQueue.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS notification_settings")
            try db.execute(sql: "DROP TABLE IF EXISTS privacy_settings")
            try db.execute(sql: "DROP TABLE IF EXISTS outbox_events")
            try db.execute(sql: "DROP TABLE IF EXISTS users")
        }

        let notificationsLoadError = SettingsNotificationsViewModel(syncEngine: syncEngine, dbQueue: dbQueue)
        await notificationsLoadError.load()
        appendStatusMessage(notificationsLoadError.statusMessage, to: &outputs)

        let privacyLoadError = SettingsPrivacyViewModel(syncEngine: syncEngine, dbQueue: dbQueue)
        await privacyLoadError.load()
        appendStatusMessage(privacyLoadError.statusMessage, to: &outputs)

        let notificationsSaveError = SettingsNotificationsViewModel(syncEngine: syncEngine, dbQueue: dbQueue)
        notificationsSaveError.isLoaded = true
        await notificationsSaveError.save()
        appendStatusMessage(notificationsSaveError.statusMessage, to: &outputs)

        let privacySaveError = SettingsPrivacyViewModel(syncEngine: syncEngine, dbQueue: dbQueue)
        privacySaveError.isLoaded = true
        await privacySaveError.save()
        appendStatusMessage(privacySaveError.statusMessage, to: &outputs)

        let previousContainer = AppContainer.shared
        AppContainer.shared = AppContainer(syncEngine: syncEngine)
        let privacyDeleteError = SettingsPrivacyViewModel(syncEngine: syncEngine, dbQueue: dbQueue)
        await privacyDeleteError.deleteAccount()
        appendStatusMessage(privacyDeleteError.statusMessage, to: &outputs)
        AppContainer.shared = previousContainer

        return outputs
    }

    static func userFacingErrors() -> [String] {
        struct CustomError: LocalizedError {
            let value: String
            var errorDescription: String? { value }
        }
        struct EmptyFallbackError: LocalizedError {}

        let explicit = userFacingSettingsError(CustomError(value: "custom"), fallback: SettingsError.exportFailed)
        let fallback = userFacingSettingsError(NSError(domain: "x", code: 1), fallback: SettingsError.exportFailed)
        let defaultFallback = userFacingSettingsError(NSError(domain: "x", code: 2), fallback: EmptyFallbackError())
        return [explicit, fallback, defaultFallback]
    }

    static func privacyPayloadSnapshot() -> [String: Any] {
        var settings = PrivacySettings(userId: UUID())
        settings.menstrualLocalOnly = true
        settings.medicalScanLocalOnly = false
        settings.cloudBackupEnabled = true
        settings.vectorOptIn = true
        settings.analyticsConsent = false
        settings.cloudOcrEnabled = true
        return SettingsPrivacyViewModel.privacyPayload(from: settings)
    }

    static func enqueueOutboxMutation(
        syncEngine: SyncEngine,
        path: String
    ) async throws {
        try await enqueueOutbox(
            syncEngine: syncEngine,
            path: path,
            method: .POST,
            body: [
                "id": UUID().uuidString,
                "value": "test"
            ]
        )
    }
}
#endif
