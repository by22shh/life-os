// MARK: - Settings View
// Account, preferences, data controls, and routing to settings destinations.

import SwiftUI
import Observation
import UIKit

struct SettingsView: View {
    @Environment(AuthManager.self) private var authManager
    @State private var viewModel = SettingsViewModel()

    private var accountStatusSymbolName: String {
        if !authManager.hasCloudSession || authManager.isAnonymous {
            return "person.crop.circle.badge.exclamationmark"
        }
        return "person.crop.circle.badge.checkmark"
    }

    /// Export stays available in explicit offline-local builds because
    /// PrivacyGateway can generate a local archive without cloud runtime config.
    /// When a cloud session needs reconnecting, keep the export screen reachable
    /// so it can explain the requirement and show any existing export state.
    private var canOpenExportData: Bool {
        authManager.hasCloudSession ||
        authManager.requiresCloudReauthentication ||
        !SupabaseConfig.isRuntimeConfigured
    }

    init(testExportStatusMessage: String? = nil) {
        let configured = SettingsViewModel()
        configured.exportStatusMessage = testExportStatusMessage
        _viewModel = State(initialValue: configured)
    }

    var body: some View {
        NavigationStack {
            List {
                // Profile
                settingsSectionHeader(String(localized: "settings_account_section"))

                Section {
                    NavigationLink {
                        SettingsAccountManagementView()
                    } label: {
                        settingsNavigationRow(
                            String(localized: "settings_account_management"),
                            systemImage: accountStatusSymbolName
                        )
                    }
                    .accessibilityIdentifier("settings.link.account_management")

                    NavigationLink {
                        SettingsProfileView()
                    } label: {
                        settingsNavigationRow(String(localized: "settings_profile"), systemImage: "person.circle")
                    }
                    .accessibilityIdentifier("settings.link.profile")

                    NavigationLink {
                        SettingsHealthFlagsView()
                    } label: {
                        settingsNavigationRow(String(localized: "settings_health_flags"), systemImage: "heart.text.square")
                    }
                    .accessibilityIdentifier("settings.link.health_flags")
                }

                // Preferences
                settingsSectionHeader(String(localized: "settings_preferences_section"))

                Section {
                    NavigationLink {
                        SettingsUnitsLocaleView()
                    } label: {
                        settingsNavigationRow(String(localized: "settings_units_locale"), systemImage: "globe")
                    }
                    .accessibilityIdentifier("settings.link.units_locale")

                    NavigationLink {
                        SettingsNotificationsView()
                    } label: {
                        settingsNavigationRow(String(localized: "settings_notifications"), systemImage: "bell")
                    }
                    .accessibilityIdentifier("settings.link.notifications")

                    NavigationLink {
                        SettingsSecurityView()
                    } label: {
                        settingsNavigationRow(String(localized: "settings_security"), systemImage: "lock.circle")
                    }
                    .accessibilityIdentifier("settings.link.security")

                    NavigationLink {
                        SettingsPrivacyView()
                    } label: {
                        settingsNavigationRow(String(localized: "settings_privacy"), systemImage: "lock.shield")
                    }
                    .accessibilityIdentifier("settings.link.privacy")
                }

                // Data
                settingsSectionHeader(String(localized: "settings_data_section"))

                Section {
                    NavigationLink {
                        if !authManager.hasCloudSession {
                            SettingsAccountManagementView(requirement: .sync)
                        } else {
                            SettingsSyncView()
                        }
                    } label: {
                        settingsNavigationRow(
                            String(localized: "settings_sync_status"),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .accessibilityIdentifier("settings.link.sync")

                    NavigationLink {
                        exportDestination()
                    } label: {
                        settingsNavigationRow(String(localized: "settings_export_data"), systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("settings.button.export")

                    NavigationLink {
                        SettingsFoodDataSourcesView()
                    } label: {
                        settingsNavigationRow(
                            String(localized: "settings_food_data_sources_title"),
                            systemImage: "fork.knife.circle"
                        )
                    }
                    .accessibilityIdentifier("settings.link.food_data_sources")

                    NavigationLink {
                        SettingsAppleHealthView()
                    } label: {
                        settingsNavigationRow(String(localized: "settings_apple_health"), systemImage: "heart")
                    }
                    .accessibilityIdentifier("settings.link.apple_health")
                }

                if let exportStatusMessage = viewModel.exportStatusMessage {
                    Section {
                        Text(exportStatusMessage)
                            .font(LifeOSTypography.footnote)
                            .accessibilityIdentifier("settings.export.status")
                    }
                }

                // About
                settingsSectionHeader(String(localized: "settings_about_section"))

                Section {
                    HStack {
                        Text(String(localized: "settings_version"))
                            .font(LifeOSTypography.body)
                        Spacer()
                        Text(String(localized: "settings_version_value"))
                            .font(LifeOSTypography.body)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(String(localized: "settings_build"))
                            .font(LifeOSTypography.body)
                        Spacer()
                        Text(String(localized: "settings_build_value"))
                            .font(LifeOSTypography.body)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .environment(\.defaultMinListRowHeight, LayoutConstants.listRowMinHeight)
            .navigationTitle(String(localized: "tab_settings"))
            .accessibilityIdentifier("settings.screen")
        }
    }

    private func settingsSectionHeader(_ title: String) -> some View {
        SettingsSectionHeaderLabel(title: title)
            .accessibilityHidden(true)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: Spacing.l, leading: LayoutConstants.contentPadding, bottom: Spacing.xs, trailing: LayoutConstants.contentPadding))
    }

    private func settingsNavigationRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: systemImage)
                .font(LifeOSTypography.body)
                .foregroundStyle(LifeOSColors.Semantic.primary)
                .frame(width: LayoutConstants.iconSize, alignment: .center)
                .accessibilityHidden(true)

            Text(title)
                .font(LifeOSTypography.body)
                .foregroundStyle(LifeOSColors.Text.primary)
                .multilineTextAlignment(.leading)
        }
    }

    @ViewBuilder
    private func exportDestination() -> some View {
        if canOpenExportData {
            SettingsExportDataView()
        } else {
            SettingsAccountManagementView(requirement: .export)
        }
    }

    private func requestExportAction() {
        Task {
            await viewModel.requestExport()
        }
    }
}

private struct SettingsSectionHeaderLabel: UIViewRepresentable {
    let title: String

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.adjustsFontForContentSizeCategory = true
        label.font = UIFont.preferredFont(forTextStyle: .subheadline)
        label.textColor = UIColor.label
        label.numberOfLines = 0
        label.isAccessibilityElement = false
        label.accessibilityElementsHidden = true
        return label
    }

    func updateUIView(_ uiView: UILabel, context: Context) {
        uiView.text = title
        uiView.adjustsFontForContentSizeCategory = true
        uiView.font = UIFont.preferredFont(forTextStyle: .subheadline)
        uiView.isAccessibilityElement = false
        uiView.accessibilityElementsHidden = true
    }
}

#if DEBUG
extension SettingsView {
    @MainActor
    func _testEvaluateBody() {
        #if os(iOS)
        let host = UIHostingController(
            rootView: self.environment(AuthManager())
        )
        host.loadViewIfNeeded()
        #else
        _ = body
        #endif
    }

    @MainActor
    func _testCanOpenExportData() -> Bool {
        canOpenExportData
    }

    @MainActor
    func _testTriggerExportAction() {
        requestExportAction()
    }

    @MainActor
    static func _testRequestExportSuccessMessage(exportId: String) async -> String? {
        let viewModel = SettingsViewModel(
            requestExportOperation: {
                ExportRequestResponse(exportId: exportId, status: "queued")
            }
        )
        await viewModel.requestExport()
        return viewModel.exportStatusMessage
    }

    @MainActor
    static func _testRequestExportFailureMessage() async -> String? {
        struct ExportFailure: LocalizedError {
            var errorDescription: String? { "export-failed" }
        }
        let viewModel = SettingsViewModel(
            requestExportOperation: {
                throw ExportFailure()
            }
        )
        await viewModel.requestExport()
        return viewModel.exportStatusMessage
    }

    @MainActor
    static func _testRequestExportUnknownFailureMessage() async -> String? {
        let viewModel = SettingsViewModel(
            requestExportOperation: {
                throw NSError(domain: "SettingsCoverage", code: 777)
            }
        )
        await viewModel.requestExport()
        return viewModel.exportStatusMessage
    }
}
#endif

#Preview {
    SettingsView()
        .environment(AuthManager())
}

@MainActor
@Observable
private final class SettingsViewModel {
    var exportStatusMessage: String?
    private let requestExportOperation: @Sendable () async throws -> ExportRequestResponse

    init(
        requestExportOperation: @escaping @Sendable () async throws -> ExportRequestResponse = {
            try await PrivacyGateway().requestExport()
        }
    ) {
        self.requestExportOperation = requestExportOperation
    }

    func requestExport() async {
        do {
            let response = try await requestExportOperation()
            exportStatusMessage = "\(String(localized: "settings_export_data")): \(response.exportId)"
        } catch {
            if let localized = (error as? LocalizedError)?.errorDescription {
                exportStatusMessage = localized
            } else {
                exportStatusMessage = SettingsError.exportFailed.errorDescription
            }
        }
    }
}
