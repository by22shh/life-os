import SwiftUI
import Observation
import GRDB
import HealthKit
import UIKit
import AuthenticationServices

#if DEBUG
@MainActor
private func noopAccountSettingsEnqueue(
    _: SyncEngine,
    _: String,
    _: HTTPMethod,
    _: [String: Any]
) async throws { }

@MainActor
private func noopAppleHealthRequestAccess() async throws -> Bool { false }

@MainActor
private func noopAppleHealthBackfill(_: UUID) async throws { }
#endif

private enum SettingsAccountFormSupport {
    static let minimumSupportedAge = 13
    static let maximumSupportedAge = 100
    static let minimumHeightCm = 100.0
    static let maximumHeightCm = 250.0
    static let defaultDateOfBirth: Date = {
        Calendar(identifier: .gregorian).date(byAdding: .year, value: -30, to: Date()) ?? Date()
    }()

    static var supportedDateOfBirthRange: ClosedRange<Date> {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let youngest = calendar.date(byAdding: .year, value: -minimumSupportedAge, to: now) ?? now
        let oldest = calendar.date(byAdding: .year, value: -maximumSupportedAge, to: now) ?? youngest
        return oldest...youngest
    }

    static func supportedAge(from dateOfBirth: Date, hasConfirmedDateOfBirth: Bool) -> Int? {
        guard hasConfirmedDateOfBirth else { return nil }
        let years = Calendar.current.dateComponents([.year], from: dateOfBirth, to: Date()).year ?? 0
        guard (minimumSupportedAge...maximumSupportedAge).contains(years) else { return nil }
        return years
    }

    static func clampedDateOfBirth(_ date: Date) -> Date {
        let bounds = supportedDateOfBirthRange
        if date < bounds.lowerBound { return bounds.lowerBound }
        if date > bounds.upperBound { return bounds.upperBound }
        return date
    }

    static func parseMetricValue(_ text: String, allowedRange: ClosedRange<Double>) -> Double? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), allowedRange.contains(value) else {
            return nil
        }
        return roundedMetricValue(value)
    }

    static func roundedMetricValue(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    static func formattedMetricValue(_ value: Double) -> String {
        let rounded = roundedMetricValue(value)
        if rounded.rounded(.towardZero) == rounded {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }

    static func normalizedDateOnly(_ date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: components.year,
            month: components.month,
            day: components.day,
            hour: 12
        )) ?? date
    }

    static func localDateOnlyString(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return DateFormatting.dateOnlyString(from: date)
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func trimmedOrNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func localizedTitle(for sex: BiologicalSex) -> String {
        switch sex {
        case .male:
            return String(localized: "onboarding_profile_sex_male")
        case .female:
            return String(localized: "onboarding_profile_sex_female")
        case .other:
            return String(localized: "onboarding_profile_sex_other")
        }
    }

    static func localizedTitle(for goal: PrimaryGoal) -> String {
        switch goal {
        case .recovery:
            return String(localized: "onboarding_profile_goal_recovery")
        case .performance:
            return String(localized: "onboarding_profile_goal_performance")
        case .weight:
            return String(localized: "onboarding_profile_goal_weight")
        case .generalHealth:
            return String(localized: "onboarding_profile_goal_general_health")
        }
    }

    static func localizedTitle(for activityLevel: ActivityLevel) -> String {
        switch activityLevel {
        case .sedentary:
            return String(localized: "onboarding_profile_activity_sedentary")
        case .light:
            return String(localized: "onboarding_profile_activity_light")
        case .moderate:
            return String(localized: "onboarding_profile_activity_moderate")
        case .active:
            return String(localized: "onboarding_profile_activity_active")
        case .veryActive:
            return String(localized: "onboarding_profile_activity_very_active")
        }
    }

    static func localizedTitle(for unitSystem: UnitSystem) -> String {
        switch unitSystem {
        case .metric:
            return String(localized: "settings_units_metric")
        case .imperial:
            return String(localized: "settings_units_imperial")
        }
    }

    static func languageDescription(locale: Locale = .current) -> String {
        let languageCode = locale.language.languageCode?.identifier ?? Locale.preferredLanguages.first ?? locale.identifier
        return locale.localizedString(forLanguageCode: languageCode)?.capitalized(with: locale) ?? languageCode
    }

    static func regionDescription(locale: Locale = .current) -> String {
        let regionCode = locale.region?.identifier ?? locale.identifier
        return locale.localizedString(forRegionCode: regionCode) ?? regionCode
    }

    static func timeZoneDisplayName(for identifier: String, locale: Locale = .current) -> String {
        let fallback = identifier.replacingOccurrences(of: "_", with: " ")
        guard let timeZone = TimeZone(identifier: identifier) else { return fallback }
        let city = identifier.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: "_", with: " ") ?? fallback
        let name = timeZone.localizedName(for: .generic, locale: locale) ?? city
        let offsetSeconds = timeZone.secondsFromGMT()
        let sign = offsetSeconds >= 0 ? "+" : "-"
        let absolute = abs(offsetSeconds)
        let hours = absolute / 3600
        let minutes = (absolute % 3600) / 60
        let offset = String(format: "GMT%@%02d:%02d", sign, hours, minutes)
        return "\(city) • \(name) • \(offset)"
    }
}

enum SettingsAccountRequirement: Equatable, Sendable {
    case general
    case sync
    case export

    fileprivate var guidanceMessage: String {
        switch self {
        case .general:
            return String(localized: "settings_account_link_guidance")
        case .sync:
            return String(localized: "settings_account_link_sync_required")
        case .export:
            return String(localized: "settings_account_link_export_required")
        }
    }
}

struct SettingsAccountManagementView: View {
    @Environment(AuthManager.self) private var authManager
    @State private var emailAddress = ""
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var isShowingEmailSheet = false
    @State private var isShowingReconnectSheet = false
    @State private var isShowingAnonymousResetConfirmation = false
    @State private var isShowingLocalProfileRemovalConfirmation = false

    let requirement: SettingsAccountRequirement

    init(requirement: SettingsAccountRequirement = .general) {
        self.requirement = requirement
    }

    private var isLocalOnlyAnonymousAccount: Bool {
        !SupabaseConfig.isRuntimeConfigured &&
        authManager.isAnonymous && !authManager.hasCloudSession
    }

    private var requiresAnonymousCloudBootstrap: Bool {
        SupabaseConfig.isRuntimeConfigured &&
        authManager.isAnonymous &&
        !authManager.hasCloudSession
    }

    private var isLocalOnlyRecoveredAccount: Bool {
        !SupabaseConfig.isRuntimeConfigured &&
        !authManager.isAnonymous &&
        !authManager.hasCloudSession &&
        authManager.userId != nil
    }

    private var requiresCloudReconnect: Bool {
        authManager.requiresCloudReauthentication
    }

    private var accountStatusText: String {
        if isLocalOnlyAnonymousAccount {
            return String(localized: "settings_account_status_local_only")
        }
        if isLocalOnlyRecoveredAccount {
            return String(localized: "settings_account_status_local_only")
        }
        if requiresCloudReconnect {
            return String(localized: "settings_account_status_reconnect_required")
        }
        if authManager.isAnonymous {
            return String(localized: "settings_account_status_anonymous")
        }
        if let email = authManager.session?.user.email,
           !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(
                format: String(localized: "settings_account_status_email_format"),
                email
            )
        }
        return String(localized: "settings_account_status_linked")
    }

    private var secondaryStatusText: String {
        if isLocalOnlyRecoveredAccount {
            return String(localized: "settings_account_link_unavailable_local_build")
        }
        if requiresCloudReconnect {
            return String(localized: "settings_cloud_reconnect_notice")
        }
        if authManager.isAnonymous {
            return requirement.guidanceMessage
        }
        return String(localized: "settings_account_data_preserved")
    }

    private var accountExitButtonTitle: String {
        if authManager.isAnonymous {
            return String(localized: "settings_account_start_fresh")
        }
        if requiresCloudReconnect || isLocalOnlyRecoveredAccount {
            return String(localized: "settings_account_remove_local_profile")
        }
        return String(localized: "settings_account_sign_out")
    }

    private var isAppleSignInAvailable: Bool {
        AppCapabilityAvailability.isAppleSignInAvailable
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "settings_account_status_label")) {
                    Text(accountStatusText)
                        .foregroundStyle(.secondary)
                }

                Text(secondaryStatusText)
                    .font(LifeOSTypography.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text(String(localized: "settings_account_management"))
            }

            if authManager.isAnonymous {
                Section {
                    SignInWithAppleButton(
                        .continue,
                        onRequest: { $0.requestedScopes = [.email, .fullName] },
                        onCompletion: handleAppleLinkResult
                    )
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: LayoutConstants.minTouchTarget)
                    .disabled(isWorking || isLocalOnlyAnonymousAccount || !isAppleSignInAvailable)

                    Button(String(localized: "settings_account_link_email"), action: openEmailSheet)
                        .disabled(isWorking || isLocalOnlyAnonymousAccount)
                } header: {
                    Text(String(localized: "settings_account_link_actions"))
                }

                if !isAppleSignInAvailable {
                    Section {
                        Text(String(localized: "settings_account_link_apple_unavailable_build"))
                            .font(LifeOSTypography.footnote)
                            .foregroundStyle(LifeOSColors.Recovery.caution)
                    }
                }

                if isLocalOnlyAnonymousAccount {
                    Section {
                        Text(String(localized: "settings_account_link_unavailable_local_build"))
                            .font(LifeOSTypography.footnote)
                            .foregroundStyle(LifeOSColors.Recovery.caution)
                    }
                }
            }

            if isLocalOnlyRecoveredAccount {
                Section {
                    Text(String(localized: "settings_account_link_unavailable_local_build"))
                        .font(LifeOSTypography.footnote)
                        .foregroundStyle(LifeOSColors.Recovery.caution)
                }
            }

            if requiresCloudReconnect {
                Section {
                    Button(String(localized: "settings_cloud_reconnect_cta"), action: openReconnectSheet)
                        .disabled(isWorking)
                } header: {
                    Text(String(localized: "settings_account_reconnect_actions"))
                }
            }

            Section {
                Button(role: (authManager.isAnonymous || requiresCloudReconnect || isLocalOnlyRecoveredAccount) ? .destructive : nil, action: triggerAccountExit) {
                    Text(accountExitButtonTitle)
                }
                .disabled(isWorking)
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(LifeOSTypography.footnote)
                }
            }
        }
        .navigationTitle(String(localized: "settings_account_management"))
        .sheet(isPresented: $isShowingEmailSheet, content: emailSheet)
        .sheet(isPresented: $isShowingReconnectSheet, content: reconnectSheet)
        .onChange(of: authManager.hasCloudSession) { _, hasCloudSession in
            guard hasCloudSession else { return }
            if isShowingReconnectSheet {
                closeReconnectSheet()
                statusMessage = String(localized: "settings_account_reconnect_success")
            }
        }
        .confirmationDialog(
            String(localized: "settings_account_start_fresh_confirm_title"),
            isPresented: $isShowingAnonymousResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                String(localized: "settings_account_start_fresh_confirm_action"),
                role: .destructive,
                action: confirmAnonymousReset
            )
        } message: {
            Text(String(localized: "settings_account_start_fresh_confirm_body"))
        }
        .confirmationDialog(
            String(localized: "settings_account_remove_local_profile_confirm_title"),
            isPresented: $isShowingLocalProfileRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                String(localized: "settings_account_remove_local_profile_confirm_action"),
                role: .destructive,
                action: confirmLocalProfileRemoval
            )
        } message: {
            Text(String(localized: "settings_account_remove_local_profile_confirm_body"))
        }
    }

    private func emailSheet() -> some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        String(localized: "settings_account_email_placeholder"),
                        text: $emailAddress
                    )
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Text(String(localized: "settings_account_link_email_helper"))
                        .font(LifeOSTypography.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(String(localized: "settings_account_link_email"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel"), action: closeEmailSheet)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "save"), action: submitEmailLink)
                        .disabled(emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                }
            }
        }
    }

    private func openEmailSheet() {
        isShowingEmailSheet = true
    }

    private func closeEmailSheet() {
        isShowingEmailSheet = false
    }

    private func reconnectSheet() -> some View {
        NavigationStack {
            AuthView(testAuthManager: authManager)
                .navigationTitle(String(localized: "settings_account_reconnect_actions"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "cancel"), action: closeReconnectSheet)
                    }
                }
        }
    }

    private func openReconnectSheet() {
        statusMessage = nil
        isShowingReconnectSheet = true
    }

    private func closeReconnectSheet() {
        isShowingReconnectSheet = false
    }

    private func submitEmailLink() {
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                try await prepareAnonymousCloudBootstrapIfNeeded()
                try await authManager.linkEmail(to: emailAddress)
                if let notificationScheduler = AppContainer.shared?.notificationScheduler {
                    await notificationScheduler.refreshSchedules()
                }
                statusMessage = String(localized: "settings_account_link_email_pending")
                closeEmailSheet()
            } catch {
                statusMessage = Self.friendlyAuthMessage(error)
            }
        }
    }

    private func handleAppleLinkResult(_ result: Result<ASAuthorization, Error>) {
        guard case .success(let authorization) = result else {
            if case .failure(let error) = result {
                statusMessage = Self.friendlyAuthMessage(error)
            }
            return
        }

        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            statusMessage = String(localized: "auth_invalid_apple_credential")
            return
        }

        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                try await prepareAnonymousCloudBootstrapIfNeeded()
                try await authManager.signInWithApple(credential: credential)
                if let notificationScheduler = AppContainer.shared?.notificationScheduler {
                    await notificationScheduler.refreshSchedules()
                }
                statusMessage = String(localized: "settings_account_link_success")
            } catch {
                statusMessage = Self.friendlyAuthMessage(error)
            }
        }
    }

    private func prepareAnonymousCloudBootstrapIfNeeded() async throws {
        guard requiresAnonymousCloudBootstrap else { return }
        await authManager.startLocalProfile()
        guard authManager.hasCloudSession else {
            throw AuthError.accountLinkRequiresCloudSession
        }
    }

    private func triggerAccountExit() {
        if authManager.isAnonymous {
            isShowingAnonymousResetConfirmation = true
            return
        }
        if requiresCloudReconnect || isLocalOnlyRecoveredAccount {
            isShowingLocalProfileRemovalConfirmation = true
            return
        }

        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                try await authManager.signOut()
                if let notificationScheduler = AppContainer.shared?.notificationScheduler {
                    await notificationScheduler.refreshSchedules()
                }
            } catch {
                statusMessage = Self.friendlyAuthMessage(error)
            }
        }
    }

    private func confirmLocalProfileRemoval() {
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                try await authManager.signOut(removingLocalData: true)
                if let notificationScheduler = AppContainer.shared?.notificationScheduler {
                    await notificationScheduler.refreshSchedules()
                }
            } catch {
                statusMessage = Self.friendlyAuthMessage(error)
            }
        }
    }

    private func confirmAnonymousReset() {
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                try await authManager.signOut(removingLocalData: true)
                await authManager.startLocalProfile()
                if let notificationScheduler = AppContainer.shared?.notificationScheduler {
                    await notificationScheduler.refreshSchedules()
                }
                statusMessage = String(localized: "settings_account_start_fresh_success")
            } catch {
                statusMessage = Self.friendlyAuthMessage(error)
            }
        }
    }

    private static func friendlyAuthMessage(_ error: Error) -> String {
        if let authError = error as? AuthError {
            return authError.localizedDescription
        }
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        return String(localized: "auth_error_network_unavailable")
    }
}

struct SettingsProfileView: View {
    @State private var viewModel: SettingsProfileViewModel

    init(
        syncEngine: SyncEngine = AppContainer.shared?.syncEngine ?? previewSyncEngine,
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue
    ) {
        _viewModel = State(initialValue: SettingsProfileViewModel(syncEngine: syncEngine, dbQueue: dbQueue))
    }

#if DEBUG
    init(testUser: User, testIsLoaded: Bool, testStatusMessage: String?) {
        let vm = SettingsProfileViewModel(
            syncEngine: previewSyncEngine,
            dbQueue: DatabaseManager.shared.dbQueue,
            enqueue: noopAccountSettingsEnqueue
        )
        vm.applyLoadedUser(testUser)
        vm.isLoaded = testIsLoaded
        vm.statusMessage = testStatusMessage
        _viewModel = State(initialValue: vm)
    }

    func _testEvaluateBody() {
        _ = body
    }

    func _testTriggerActions() {
        triggerConfirmDateOfBirth()
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
                    TextField(String(localized: "settings_profile_display_name"), text: $viewModel.displayName)
                        .textContentType(.name)
                        .accessibilityIdentifier("settings.profile.display_name")

                    LabeledContent(String(localized: "settings_profile_email")) {
                        Text(viewModel.email ?? String(localized: "settings_profile_missing_email"))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(String(localized: "settings_profile_identity_section"))
                }

                Section {
                    DatePicker(
                        String(localized: "onboarding_profile_dob_title"),
                        selection: Binding(
                            get: { viewModel.dateOfBirth },
                            set: { viewModel.setDateOfBirth($0) }
                        ),
                        in: SettingsAccountFormSupport.supportedDateOfBirthRange,
                        displayedComponents: .date
                    )
                    .accessibilityIdentifier("settings.profile.date_of_birth")

                    if !viewModel.hasDateOfBirth {
                        Button(String(localized: "onboarding_profile_confirm_dob"), action: triggerConfirmDateOfBirth)
                            .accessibilityIdentifier("settings.profile.confirm_date_of_birth")
                    }

                    if let age = viewModel.profileAge {
                        LabeledContent(String(localized: "onboarding_profile_dob_description")) {
                            Text(String(format: String(localized: "onboarding_profile_age_value_format"), age))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(String(localized: "settings_profile_invalid_age"))
                            .font(LifeOSTypography.footnote)
                            .foregroundStyle(LifeOSColors.Recovery.caution)
                    }

                    Picker(String(localized: "onboarding_profile_sex_title"), selection: $viewModel.sex) {
                        Text(String(localized: "settings_select_option")).tag(Optional<BiologicalSex>.none)
                        ForEach(BiologicalSex.allCases, id: \.self) { option in
                            Text(SettingsAccountFormSupport.localizedTitle(for: option)).tag(Optional(option))
                        }
                    }
                    .accessibilityIdentifier("settings.profile.sex")

                    HStack(spacing: Spacing.s) {
                        TextField(
                            String(localized: "onboarding_profile_height_placeholder"),
                            text: $viewModel.heightInputText
                        )
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("settings.profile.height")

                        Text(String(localized: "unit_cm"))
                            .foregroundStyle(.secondary)
                    }

                    Picker(String(localized: "onboarding_profile_goal_title"), selection: $viewModel.primaryGoal) {
                        Text(String(localized: "settings_select_option")).tag(Optional<PrimaryGoal>.none)
                        ForEach(PrimaryGoal.allCases, id: \.self) { option in
                            Text(SettingsAccountFormSupport.localizedTitle(for: option)).tag(Optional(option))
                        }
                    }
                    .accessibilityIdentifier("settings.profile.goal")

                    Picker(String(localized: "onboarding_profile_activity_title"), selection: $viewModel.activityLevel) {
                        Text(String(localized: "settings_select_option")).tag(Optional<ActivityLevel>.none)
                        ForEach(ActivityLevel.allCases, id: \.self) { option in
                            Text(SettingsAccountFormSupport.localizedTitle(for: option)).tag(Optional(option))
                        }
                    }
                    .accessibilityIdentifier("settings.profile.activity")
                } header: {
                    Text(String(localized: "settings_profile_personal_section"))
                } footer: {
                    Text(String(localized: "settings_profile_footer"))
                }

                Section {
                    Button(String(localized: "settings_save"), action: triggerSave)
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewModel.canSave)
                        .accessibilityIdentifier("settings.profile.save")
                }

                if let statusMessage = viewModel.statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(LifeOSTypography.footnote)
                            .accessibilityIdentifier("settings.profile.status")
                    }
                }
            }
        }
        .navigationTitle(String(localized: "settings_profile"))
        .task(viewModel.load)
    }

    private func triggerConfirmDateOfBirth() {
        viewModel.confirmDateOfBirth()
    }

    private func triggerSave() {
        Task { await viewModel.save() }
    }
}

struct SettingsHealthFlagsView: View {
    @State private var viewModel: SettingsHealthFlagsViewModel

    init(
        syncEngine: SyncEngine = AppContainer.shared?.syncEngine ?? previewSyncEngine,
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue
    ) {
        _viewModel = State(initialValue: SettingsHealthFlagsViewModel(syncEngine: syncEngine, dbQueue: dbQueue))
    }

#if DEBUG
    init(
        testFlags: UserHealthFlags,
        testCloudBackupEnabled: Bool,
        testIsLoaded: Bool,
        testStatusMessage: String?
    ) {
        let vm = SettingsHealthFlagsViewModel(
            syncEngine: previewSyncEngine,
            dbQueue: DatabaseManager.shared.dbQueue,
            enqueue: noopAccountSettingsEnqueue
        )
        vm.flags = testFlags
        vm.cloudBackupEnabled = testCloudBackupEnabled
        vm.isLoaded = testIsLoaded
        vm.statusMessage = testStatusMessage
        _viewModel = State(initialValue: vm)
    }

    func _testEvaluateBody() {
        _ = body
    }

    func _testTriggerActions() {
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
                    Toggle(String(localized: "settings_health_flag_cardiac_condition"), isOn: $viewModel.flags.hasCardiacCondition)
                    Toggle(String(localized: "settings_health_flag_pacemaker"), isOn: $viewModel.flags.hasPacemaker)
                    Toggle(String(localized: "settings_health_flag_beta_blockers"), isOn: $viewModel.flags.onBetaBlockers)
                    Toggle(String(localized: "settings_health_flag_pregnant"), isOn: $viewModel.flags.isPregnant)
                    Toggle(String(localized: "settings_health_flag_menstrual_tracking"), isOn: $viewModel.flags.menstrualTrackingEnabled)
                    Toggle(String(localized: "settings_health_flag_eating_disorder_history"), isOn: $viewModel.flags.hasEatingDisorderHistory)
                    Toggle(String(localized: "settings_health_flag_chronic_fatigue"), isOn: $viewModel.flags.hasChronicFatigue)
                } header: {
                    Text(String(localized: "settings_health_flags"))
                } footer: {
                    Text(
                        viewModel.cloudBackupEnabled
                        ? String(localized: "settings_health_flags_cloud_backup_enabled")
                        : String(localized: "settings_health_flags_cloud_backup_disabled")
                    )
                }

                if viewModel.hasDerivedEffects {
                    Section {
                        if viewModel.flags.disableHrv {
                            Label(String(localized: "settings_health_flags_disable_hrv"), systemImage: "waveform.path.ecg")
                        }
                        if viewModel.flags.hideCalories {
                            Label(String(localized: "settings_health_flags_hide_calories"), systemImage: "fork.knife")
                        }
                        if viewModel.flags.pregnancyMode {
                            Label(String(localized: "settings_health_flags_pregnancy_mode"), systemImage: "figure.and.child.holdinghands")
                        }
                    } header: {
                        Text(String(localized: "settings_health_flags_effects"))
                    }
                }

                Section {
                    Button(String(localized: "settings_save"), action: triggerSave)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("settings.health_flags.save")
                }

                if let statusMessage = viewModel.statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(LifeOSTypography.footnote)
                            .accessibilityIdentifier("settings.health_flags.status")
                    }
                }
            }
        }
        .navigationTitle(String(localized: "settings_health_flags"))
        .task(viewModel.load)
    }

    private func triggerSave() {
        Task { await viewModel.save() }
    }
}

struct SettingsUnitsLocaleView: View {
    @Environment(\.openURL) private var openURL
    @State private var viewModel: SettingsUnitsLocaleViewModel

    init(
        syncEngine: SyncEngine = AppContainer.shared?.syncEngine ?? previewSyncEngine,
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue
    ) {
        _viewModel = State(initialValue: SettingsUnitsLocaleViewModel(syncEngine: syncEngine, dbQueue: dbQueue))
    }

#if DEBUG
    init(testUnits: UnitSystem, testTimeZone: String, testIsLoaded: Bool, testStatusMessage: String?) {
        let vm = SettingsUnitsLocaleViewModel(
            syncEngine: previewSyncEngine,
            dbQueue: DatabaseManager.shared.dbQueue,
            enqueue: noopAccountSettingsEnqueue
        )
        vm.units = testUnits
        vm.timeZoneIdentifier = testTimeZone
        vm.isLoaded = testIsLoaded
        vm.statusMessage = testStatusMessage
        _viewModel = State(initialValue: vm)
    }

    func _testEvaluateBody() {
        _ = body
    }

    func _testTriggerActions() {
        triggerUseCurrentTimeZone()
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
                    Picker(String(localized: "settings_units_locale"), selection: $viewModel.units) {
                        ForEach(UnitSystem.allCases, id: \.self) { option in
                            Text(SettingsAccountFormSupport.localizedTitle(for: option)).tag(option)
                        }
                    }
                    .accessibilityIdentifier("settings.units_locale.units")
                } header: {
                    Text(String(localized: "settings_units_locale"))
                }

                Section {
                    NavigationLink {
                        SettingsTimeZonePickerView(selectedIdentifier: $viewModel.timeZoneIdentifier)
                    } label: {
                        LabeledContent(String(localized: "settings_timezone")) {
                            Text(SettingsAccountFormSupport.timeZoneDisplayName(for: viewModel.timeZoneIdentifier))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("settings.units_locale.timezone")

                    Button(String(localized: "settings_timezone_use_device"), action: triggerUseCurrentTimeZone)
                        .accessibilityIdentifier("settings.units_locale.timezone.use_device")
                } footer: {
                    Text(String(localized: "settings_units_locale_footer"))
                }

                Section {
                    LabeledContent(String(localized: "settings_locale_language")) {
                        Text(viewModel.languageDescription)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent(String(localized: "settings_locale_region")) {
                        Text(viewModel.regionDescription)
                            .foregroundStyle(.secondary)
                    }

                    Button(String(localized: "settings_open_app_settings"), action: openAppSettings)
                        .accessibilityIdentifier("settings.units_locale.open_app_settings")
                } header: {
                    Text(String(localized: "settings_locale_section"))
                } footer: {
                    Text(String(localized: "settings_locale_system_note"))
                }

                Section {
                    Button(String(localized: "settings_save"), action: triggerSave)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("settings.units_locale.save")
                }

                if let statusMessage = viewModel.statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(LifeOSTypography.footnote)
                            .accessibilityIdentifier("settings.units_locale.status")
                    }
                }
            }
        }
        .navigationTitle(String(localized: "settings_units_locale"))
        .task(viewModel.load)
    }

    private func triggerUseCurrentTimeZone() {
        viewModel.useCurrentTimeZone()
    }

    private func triggerSave() {
        Task { await viewModel.save() }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

private struct SettingsTimeZonePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedIdentifier: String
    @State private var searchText = ""

    private var filteredIdentifiers: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifiers = TimeZone.knownTimeZoneIdentifiers.sorted()
        guard !query.isEmpty else { return prioritized(identifiers) }
        return identifiers.filter {
            $0.localizedCaseInsensitiveContains(query) ||
            SettingsAccountFormSupport.timeZoneDisplayName(for: $0).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List(filteredIdentifiers, id: \.self) { identifier in
            Button {
                selectedIdentifier = identifier
                dismiss()
            } label: {
                HStack(spacing: Spacing.s) {
                    Text(SettingsAccountFormSupport.timeZoneDisplayName(for: identifier))
                    Spacer()
                    if identifier == selectedIdentifier {
                        Image(systemName: "checkmark")
                            .foregroundStyle(LifeOSColors.Semantic.primary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .navigationTitle(String(localized: "settings_timezone"))
        .searchable(text: $searchText, prompt: Text(String(localized: "settings_timezone_search")))
    }

    private func prioritized(_ identifiers: [String]) -> [String] {
        let current = TimeZone.autoupdatingCurrent.identifier
        var priority: [String] = []
        for candidate in [selectedIdentifier, current] where !priority.contains(candidate) {
            priority.append(candidate)
        }
        let remainder = identifiers.filter { !priority.contains($0) }
        return priority + remainder
    }
}

struct SettingsAppleHealthView: View {
    @Environment(\.openURL) private var openURL
    @State private var viewModel: SettingsAppleHealthViewModel

    init(
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue
    ) {
        _viewModel = State(initialValue: SettingsAppleHealthViewModel(dbQueue: dbQueue))
    }

#if DEBUG
    fileprivate init(
        testSnapshot: SettingsAppleHealthSnapshot,
        testIsLoaded: Bool,
        testStatusMessage: String?,
        testIsRequestingAccess: Bool = false,
        testIsBackfilling: Bool = false
    ) {
        let vm = SettingsAppleHealthViewModel(
            dbQueue: DatabaseManager.shared.dbQueue,
            requestAccessOperation: noopAppleHealthRequestAccess,
            authorizationSnapshotOperation: { testSnapshot },
            backfillOperation: noopAppleHealthBackfill
        )
        vm.snapshot = testSnapshot
        vm.isLoaded = testIsLoaded
        vm.statusMessage = testStatusMessage
        vm.isRequestingAccess = testIsRequestingAccess
        vm.isBackfilling = testIsBackfilling
        _viewModel = State(initialValue: vm)
    }

    func _testEvaluateBody() {
        _ = body
    }

    func _testTriggerActions() {
        triggerRefresh()
        triggerRequestAccess()
        triggerImportRecent()
    }
#endif

    var body: some View {
        Form {
            if !viewModel.isLoaded {
                ProgressView(String(localized: "loading"))
            } else {
                Section {
                    Label(viewModel.summaryText, systemImage: viewModel.summaryIconName)
                        .foregroundStyle(viewModel.summaryColor)
                    Text(viewModel.authorizationBreakdownText)
                        .font(LifeOSTypography.footnote)
                        .foregroundStyle(.secondary)
                    if let capabilityWarningText = viewModel.capabilityWarningText {
                        Text(capabilityWarningText)
                            .font(LifeOSTypography.footnote)
                            .foregroundStyle(LifeOSColors.Recovery.caution)
                    }
                    PrivacyNoteView(.healthKitReadOnly)
                } header: {
                    Text(String(localized: "settings_apple_health_connection_section"))
                }

                Section {
                    ForEach(viewModel.snapshot.metrics) { metric in
                        LabeledContent(metric.title) {
                            Text(viewModel.metricStatusText(for: metric.status))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(String(localized: "settings_apple_health_types_section"))
                }

                Section {
                    Button(String(localized: "settings_apple_health_request_access"), action: triggerRequestAccess)
                        .disabled(!viewModel.snapshot.isAvailable || viewModel.isRequestingAccess)
                        .accessibilityIdentifier("settings.apple_health.request_access")

                    Button(String(localized: "settings_apple_health_refresh_status"), action: triggerRefresh)
                        .disabled(viewModel.isRefreshingStatus)
                        .accessibilityIdentifier("settings.apple_health.refresh")

                    Button(String(localized: "settings_apple_health_import_recent"), action: triggerImportRecent)
                        .disabled(!viewModel.canImportRecent)
                        .accessibilityIdentifier("settings.apple_health.import_recent")

                    Button(String(localized: "settings_open_app_settings"), action: openAppSettings)
                        .accessibilityIdentifier("settings.apple_health.open_app_settings")
                } header: {
                    Text(String(localized: "settings_apple_health_actions_section"))
                }

                if let statusMessage = viewModel.statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(LifeOSTypography.footnote)
                            .accessibilityIdentifier("settings.apple_health.status")
                    }
                }
            }
        }
        .navigationTitle(String(localized: "settings_apple_health"))
        .task(viewModel.load)
    }

    private func triggerRequestAccess() {
        Task { await viewModel.requestAccess() }
    }

    private func triggerRefresh() {
        Task { await viewModel.refreshStatus() }
    }

    private func triggerImportRecent() {
        Task { await viewModel.importRecentData() }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

@MainActor
@Observable
private final class SettingsProfileViewModel {
    var displayName = ""
    var email: String?
    var dateOfBirth = SettingsAccountFormSupport.defaultDateOfBirth
    var hasDateOfBirth = false
    var sex: BiologicalSex?
    var heightInputText = ""
    var primaryGoal: PrimaryGoal?
    var activityLevel: ActivityLevel?
    var isLoaded = false
    var statusMessage: String?

    private let syncEngine: SyncEngine
    private let dbQueue: DatabaseQueue
    private let enqueue: @MainActor (SyncEngine, String, HTTPMethod, [String: Any]) async throws -> Void
    private let explicitUserIdForTests: UUID?

    init(
        syncEngine: SyncEngine,
        dbQueue: DatabaseQueue,
        enqueue: @escaping @MainActor (SyncEngine, String, HTTPMethod, [String: Any]) async throws -> Void = enqueueOutbox,
        explicitUserIdForTests: UUID? = nil
    ) {
        self.syncEngine = syncEngine
        self.dbQueue = dbQueue
        self.enqueue = enqueue
        self.explicitUserIdForTests = explicitUserIdForTests
    }

    var profileAge: Int? {
        SettingsAccountFormSupport.supportedAge(from: dateOfBirth, hasConfirmedDateOfBirth: hasDateOfBirth)
    }

    var parsedHeightCm: Double? {
        SettingsAccountFormSupport.parseMetricValue(
            heightInputText,
            allowedRange: SettingsAccountFormSupport.minimumHeightCm...SettingsAccountFormSupport.maximumHeightCm
        )
    }

    var canSave: Bool {
        hasDateOfBirth &&
        profileAge != nil &&
        sex != nil &&
        parsedHeightCm != nil &&
        primaryGoal != nil &&
        activityLevel != nil
    }

    func load() async {
        do {
            guard let authId = AuthManager.activeAuthId?.uuidString else {
                statusMessage = String(localized: "settings_sync_engine_unavailable")
                isLoaded = true
                return
            }
            let loadedUser = try await dbQueue.read { db in
                try UserIdentityLookup.fetchUser(authId: authId, db: db)
            }
            guard let loadedUser else {
                statusMessage = String(localized: "settings_sync_engine_unavailable")
                isLoaded = true
                return
            }

            applyLoadedUser(loadedUser)
            isLoaded = true
        } catch {
            statusMessage = userFacingSettingsError(error, fallback: SettingsError.saveFailed)
            isLoaded = true
        }
    }

    func setDateOfBirth(_ value: Date) {
        dateOfBirth = SettingsAccountFormSupport.clampedDateOfBirth(value)
        hasDateOfBirth = true
    }

    func confirmDateOfBirth() {
        dateOfBirth = SettingsAccountFormSupport.clampedDateOfBirth(dateOfBirth)
        hasDateOfBirth = true
    }

    func save() async {
        guard isLoaded else { return }
        guard let userId = try? await latestUserId(),
              let authId = AuthManager.activeAuthId?.uuidString,
              let profileAge,
              let sex,
              let heightCm = parsedHeightCm,
              let primaryGoal,
              let activityLevel else {
            statusMessage = String(localized: "settings_profile_complete_required")
            return
        }

        do {
            let now = Date()
            let stableDateOfBirth = SettingsAccountFormSupport.normalizedDateOnly(dateOfBirth)
            let trimmedDisplayName = SettingsAccountFormSupport.trimmedOrNil(displayName)
            let roundedHeightCm = SettingsAccountFormSupport.roundedMetricValue(heightCm)
            let ageRange = AgeRange(age: profileAge)

            try await dbQueue.write { db in
                try db.execute(
                    sql: """
                        UPDATE users
                        SET display_name = ?,
                            date_of_birth = ?,
                            age_range = ?,
                            sex = ?,
                            height_cm = ?,
                            primary_goal = ?,
                            activity_level = ?,
                            updated_at = ?
                        WHERE id = ? OR id = ?
                        """,
                    arguments: [
                        trimmedDisplayName,
                        stableDateOfBirth,
                        ageRange.rawValue,
                        sex.rawValue,
                        roundedHeightCm,
                        primaryGoal.rawValue,
                        activityLevel.rawValue,
                        now,
                        userId,
                        MixedUUIDStorage.encode(userId)
                    ]
                )
            }

            try await enqueue(
                syncEngine,
                "rest/v1/users",
                .POST,
                [
                    "id": userId.uuidString,
                    "auth_id": authId,
                    "display_name": trimmedDisplayName ?? NSNull(),
                    "date_of_birth": SettingsAccountFormSupport.localDateOnlyString(from: stableDateOfBirth),
                    "age_range": ageRange.rawValue,
                    "sex": sex.rawValue,
                    "height_cm": roundedHeightCm,
                    "primary_goal": primaryGoal.rawValue,
                    "activity_level": activityLevel.rawValue,
                    "updated_at": ISO8601DateFormatter.supabaseString(from: now)
                ]
            )
            statusMessage = String(localized: "settings_saved")
        } catch {
            statusMessage = userFacingSettingsError(error, fallback: SettingsError.saveFailed)
        }
    }

    fileprivate func applyLoadedUser(_ user: User) {
        displayName = user.displayName ?? ""
        email = user.email
        if let dateOfBirth = user.dateOfBirth {
            self.dateOfBirth = SettingsAccountFormSupport.clampedDateOfBirth(dateOfBirth)
            hasDateOfBirth = true
        } else {
            self.dateOfBirth = SettingsAccountFormSupport.defaultDateOfBirth
            hasDateOfBirth = false
        }
        sex = user.sex
        if let heightCm = user.heightCm {
            heightInputText = SettingsAccountFormSupport.formattedMetricValue(heightCm)
        } else {
            heightInputText = ""
        }
        primaryGoal = user.primaryGoal
        activityLevel = user.activityLevel
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
}

@MainActor
@Observable
private final class SettingsHealthFlagsViewModel {
    var flags = UserHealthFlags(userId: UUID())
    var cloudBackupEnabled = false
    var isLoaded = false
    var statusMessage: String?

    private let syncEngine: SyncEngine
    private let dbQueue: DatabaseQueue
    private let enqueue: @MainActor (SyncEngine, String, HTTPMethod, [String: Any]) async throws -> Void
    private let explicitUserIdForTests: UUID?

    init(
        syncEngine: SyncEngine,
        dbQueue: DatabaseQueue,
        enqueue: @escaping @MainActor (SyncEngine, String, HTTPMethod, [String: Any]) async throws -> Void = enqueueOutbox,
        explicitUserIdForTests: UUID? = nil
    ) {
        self.syncEngine = syncEngine
        self.dbQueue = dbQueue
        self.enqueue = enqueue
        self.explicitUserIdForTests = explicitUserIdForTests
    }

    var hasDerivedEffects: Bool {
        flags.disableHrv || flags.hideCalories || flags.pregnancyMode
    }

    func load() async {
        do {
            guard let userId = try await latestUserId() else {
                statusMessage = String(localized: "settings_sync_engine_unavailable")
                isLoaded = true
                return
            }

            let loadedFlags = try await dbQueue.read { db in
                try UserHealthFlags.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM user_health_flags
                        WHERE user_id = ? OR user_id = ?
                        ORDER BY updated_at DESC
                        LIMIT 1
                        """,
                    arguments: [userId, userId.uuidString]
                )
            }

            cloudBackupEnabled = try await loadCloudBackupEnabled(for: userId)
            if let loadedFlags {
                flags = loadedFlags
            } else {
                flags = UserHealthFlags(userId: userId)
            }
            flags.userId = userId
            flags.refreshDerivedFlags()
            isLoaded = true
        } catch {
            statusMessage = userFacingSettingsError(error, fallback: SettingsError.saveFailed)
            isLoaded = true
        }
    }

    func save() async {
        guard isLoaded else { return }
        guard let userId = try? await latestUserId() else {
            statusMessage = String(localized: "settings_sync_engine_unavailable")
            return
        }

        do {
            let now = Date()
            let sourceFlags: UserHealthFlags = {
                var snapshot = flags
                snapshot.userId = userId
                snapshot.refreshDerivedFlags()
                return snapshot
            }()

            let persistedResult: (UserHealthFlags, Bool) = try await dbQueue.write { db in
                let existingRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, created_at
                        FROM user_health_flags
                        WHERE user_id = ? OR user_id = ?
                        ORDER BY updated_at DESC
                        """,
                    arguments: [userId, userId.uuidString]
                )
                let recordId = existingRows.first.flatMap { MixedUUIDStorage.decode(from: $0, column: "id") } ?? sourceFlags.id
                let existingCreatedAt: Date? = existingRows.first?["created_at"]

                var flagsToSave = sourceFlags
                flagsToSave = UserHealthFlags(id: recordId, userId: userId)
                flagsToSave.hasCardiacCondition = sourceFlags.hasCardiacCondition
                flagsToSave.hasPacemaker = sourceFlags.hasPacemaker
                flagsToSave.onBetaBlockers = sourceFlags.onBetaBlockers
                flagsToSave.isPregnant = sourceFlags.isPregnant
                flagsToSave.menstrualTrackingEnabled = sourceFlags.menstrualTrackingEnabled
                flagsToSave.hasEatingDisorderHistory = sourceFlags.hasEatingDisorderHistory
                flagsToSave.hasChronicFatigue = sourceFlags.hasChronicFatigue
                flagsToSave.createdAt = existingCreatedAt ?? now
                flagsToSave.updatedAt = now
                flagsToSave.refreshDerivedFlags()

                let cloudBackupEnabled = (try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT cloud_backup_enabled
                        FROM privacy_settings
                        WHERE user_id = ? OR user_id = ?
                        ORDER BY updated_at DESC
                        LIMIT 1
                        """,
                    arguments: [userId, userId.uuidString]
                )) ?? false

                let encodedRecordId = MixedUUIDStorage.encode(flagsToSave.id)
                let encodedUserId = MixedUUIDStorage.encode(flagsToSave.userId)

                if let primaryId = existingRows.first.flatMap({ MixedUUIDStorage.decode(from: $0, column: "id") }) {
                    for duplicateId in existingRows.dropFirst().compactMap({ MixedUUIDStorage.decode(from: $0, column: "id") }) {
                        try db.execute(
                            sql: "DELETE FROM user_health_flags WHERE id = ? OR id = ?",
                            arguments: [duplicateId, MixedUUIDStorage.encode(duplicateId)]
                        )
                    }

                    try db.execute(
                        sql: """
                            UPDATE user_health_flags
                            SET user_id = ?,
                                has_cardiac_condition = ?,
                                has_pacemaker = ?,
                                on_beta_blockers = ?,
                                is_pregnant = ?,
                                menstrual_tracking_enabled = ?,
                                has_eating_disorder_history = ?,
                                has_chronic_fatigue = ?,
                                disable_hrv = ?,
                                hide_calories = ?,
                                pregnancy_mode = ?,
                                created_at = ?,
                                updated_at = ?
                            WHERE id = ? OR id = ?
                            """,
                        arguments: [
                            encodedUserId,
                            flagsToSave.hasCardiacCondition,
                            flagsToSave.hasPacemaker,
                            flagsToSave.onBetaBlockers,
                            flagsToSave.isPregnant,
                            flagsToSave.menstrualTrackingEnabled,
                            flagsToSave.hasEatingDisorderHistory,
                            flagsToSave.hasChronicFatigue,
                            flagsToSave.disableHrv,
                            flagsToSave.hideCalories,
                            flagsToSave.pregnancyMode,
                            flagsToSave.createdAt,
                            flagsToSave.updatedAt,
                            primaryId,
                            MixedUUIDStorage.encode(primaryId)
                        ]
                    )
                } else {
                    try db.execute(
                        sql: """
                            INSERT INTO user_health_flags (
                                id, user_id, has_cardiac_condition, has_pacemaker, on_beta_blockers,
                                is_pregnant, menstrual_tracking_enabled, has_eating_disorder_history,
                                has_chronic_fatigue, disable_hrv, hide_calories, pregnancy_mode,
                                created_at, updated_at
                            )
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            encodedRecordId,
                            encodedUserId,
                            flagsToSave.hasCardiacCondition,
                            flagsToSave.hasPacemaker,
                            flagsToSave.onBetaBlockers,
                            flagsToSave.isPregnant,
                            flagsToSave.menstrualTrackingEnabled,
                            flagsToSave.hasEatingDisorderHistory,
                            flagsToSave.hasChronicFatigue,
                            flagsToSave.disableHrv,
                            flagsToSave.hideCalories,
                            flagsToSave.pregnancyMode,
                            flagsToSave.createdAt,
                            flagsToSave.updatedAt
                        ]
                    )
                }

                return (flagsToSave, cloudBackupEnabled)
            }

            flags = persistedResult.0
            cloudBackupEnabled = persistedResult.1
            await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
            _ = await WatchSyncManager.shared.pushLatestSnapshotFromLocalStore(syncEngine: syncEngine)

            if cloudBackupEnabled {
                try await enqueue(
                    syncEngine,
                    "rest/v1/user_health_flags",
                    .POST,
                    [
                        "id": flags.id.uuidString,
                        "user_id": flags.userId.uuidString,
                        "has_cardiac_condition": flags.hasCardiacCondition,
                        "has_pacemaker": flags.hasPacemaker,
                        "on_beta_blockers": flags.onBetaBlockers,
                        "is_pregnant": flags.isPregnant,
                        "menstrual_tracking_enabled": flags.menstrualTrackingEnabled,
                        "has_eating_disorder_history": flags.hasEatingDisorderHistory,
                        "has_chronic_fatigue": flags.hasChronicFatigue,
                        "disable_hrv": flags.disableHrv,
                        "hide_calories": flags.hideCalories,
                        "pregnancy_mode": flags.pregnancyMode,
                        "created_at": ISO8601DateFormatter.supabaseString(from: flags.createdAt),
                        "updated_at": ISO8601DateFormatter.supabaseString(from: flags.updatedAt)
                    ]
                )
            }

            statusMessage = String(localized: "settings_saved")
        } catch {
            statusMessage = userFacingSettingsError(error, fallback: SettingsError.saveFailed)
        }
    }

    private func loadCloudBackupEnabled(for userId: UUID) async throws -> Bool {
        try await dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT cloud_backup_enabled
                    FROM privacy_settings
                    WHERE user_id = ? OR user_id = ?
                    ORDER BY updated_at DESC
                    LIMIT 1
                    """,
                arguments: [userId, userId.uuidString]
            ) ?? false
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
}

@MainActor
@Observable
private final class SettingsUnitsLocaleViewModel {
    var units: UnitSystem = .metric
    var timeZoneIdentifier: String = TimeZone.autoupdatingCurrent.identifier
    var isLoaded = false
    var statusMessage: String?

    private let syncEngine: SyncEngine
    private let dbQueue: DatabaseQueue
    private let enqueue: @MainActor (SyncEngine, String, HTTPMethod, [String: Any]) async throws -> Void
    private let explicitUserIdForTests: UUID?

    init(
        syncEngine: SyncEngine,
        dbQueue: DatabaseQueue,
        enqueue: @escaping @MainActor (SyncEngine, String, HTTPMethod, [String: Any]) async throws -> Void = enqueueOutbox,
        explicitUserIdForTests: UUID? = nil
    ) {
        self.syncEngine = syncEngine
        self.dbQueue = dbQueue
        self.enqueue = enqueue
        self.explicitUserIdForTests = explicitUserIdForTests
    }

    var languageDescription: String {
        SettingsAccountFormSupport.languageDescription()
    }

    var regionDescription: String {
        SettingsAccountFormSupport.regionDescription()
    }

    func load() async {
        do {
            guard let authId = AuthManager.activeAuthId?.uuidString else {
                statusMessage = String(localized: "settings_sync_engine_unavailable")
                isLoaded = true
                return
            }
            let loadedUser = try await dbQueue.read { db in
                try UserIdentityLookup.fetchUser(authId: authId, db: db)
            }
            guard let loadedUser else {
                statusMessage = String(localized: "settings_sync_engine_unavailable")
                isLoaded = true
                return
            }

            units = loadedUser.units
            timeZoneIdentifier = TimeZone(identifier: loadedUser.timezone) != nil
                ? loadedUser.timezone
                : TimeZone.autoupdatingCurrent.identifier
            isLoaded = true
        } catch {
            statusMessage = userFacingSettingsError(error, fallback: SettingsError.saveFailed)
            isLoaded = true
        }
    }

    func useCurrentTimeZone() {
        timeZoneIdentifier = TimeZone.autoupdatingCurrent.identifier
    }

    func save() async {
        guard isLoaded else { return }
        guard let userId = try? await latestUserId(),
              let authId = AuthManager.activeAuthId?.uuidString else {
            statusMessage = String(localized: "settings_sync_engine_unavailable")
            return
        }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            statusMessage = String(localized: "settings_timezone_invalid")
            return
        }

        do {
            let now = Date()
            let selectedTimeZoneIdentifier = timeZoneIdentifier
            let selectedUnits = units
            try await dbQueue.write { db in
                try db.execute(
                    sql: """
                        UPDATE users
                        SET timezone = ?,
                            units = ?,
                            updated_at = ?
                        WHERE id = ? OR id = ?
                        """,
                    arguments: [
                        selectedTimeZoneIdentifier,
                        selectedUnits.rawValue,
                        now,
                        userId,
                        MixedUUIDStorage.encode(userId)
                    ]
                )
            }

            try await enqueue(
                syncEngine,
                "rest/v1/users",
                .POST,
                [
                    "id": userId.uuidString,
                    "auth_id": authId,
                    "timezone": selectedTimeZoneIdentifier,
                    "units": selectedUnits.rawValue,
                    "updated_at": ISO8601DateFormatter.supabaseString(from: now)
                ]
            )
            statusMessage = String(localized: "settings_saved")
        } catch {
            statusMessage = userFacingSettingsError(error, fallback: SettingsError.saveFailed)
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
}

private struct SettingsAppleHealthMetric: Equatable, Identifiable {
    let id: String
    let title: String
    let status: HKAuthorizationStatus
}

private struct SettingsAppleHealthSnapshot: Equatable {
    var isAvailable: Bool
    var metrics: [SettingsAppleHealthMetric]

    static let unavailable = SettingsAppleHealthSnapshot(isAvailable: false, metrics: [])

    var authorizedCount: Int {
        metrics.filter { $0.status == .sharingAuthorized }.count
    }

    var hasDeniedAccess: Bool {
        metrics.contains { $0.status == .sharingDenied }
    }

    var isFullyAuthorized: Bool {
        !metrics.isEmpty && authorizedCount == metrics.count
    }
}

@MainActor
private func loadSettingsAppleHealthAuthorizationSnapshot() async -> SettingsAppleHealthSnapshot {
    guard HealthKitManager.isAvailable else { return .unavailable }
    let store = HKHealthStore()
    let metrics = [
        SettingsAppleHealthMetric(
            id: "sleep",
            title: String(localized: "settings_apple_health_sleep"),
            status: store.authorizationStatus(for: HKCategoryType(.sleepAnalysis))
        ),
        SettingsAppleHealthMetric(
            id: "hrv",
            title: String(localized: "settings_apple_health_hrv"),
            status: store.authorizationStatus(for: HKQuantityType(.heartRateVariabilitySDNN))
        ),
        SettingsAppleHealthMetric(
            id: "resting_hr",
            title: String(localized: "settings_apple_health_resting_hr"),
            status: store.authorizationStatus(for: HKQuantityType(.restingHeartRate))
        )
    ]
    return SettingsAppleHealthSnapshot(isAvailable: true, metrics: metrics)
}

@MainActor
@Observable
private final class SettingsAppleHealthViewModel {
    var snapshot: SettingsAppleHealthSnapshot = .unavailable
    var isLoaded = false
    var isRefreshingStatus = false
    var isRequestingAccess = false
    var isBackfilling = false
    var statusMessage: String?

    private let dbQueue: DatabaseQueue
    private let requestAccessOperation: @MainActor () async throws -> Bool
    private let authorizationSnapshotOperation: @MainActor () async -> SettingsAppleHealthSnapshot
    private let backfillOperation: @MainActor (UUID) async throws -> Void
    private let explicitUserIdForTests: UUID?

    init(
        dbQueue: DatabaseQueue,
        requestAccessOperation: @escaping @MainActor () async throws -> Bool = {
            try await HealthKitManager.shared.requestAuthorization()
        },
        authorizationSnapshotOperation: @escaping @MainActor () async -> SettingsAppleHealthSnapshot = loadSettingsAppleHealthAuthorizationSnapshot,
        backfillOperation: @escaping @MainActor (UUID) async throws -> Void = { userId in
            try await HealthSyncManager.shared.backfillRecentData(days: 14, userId: userId)
        },
        explicitUserIdForTests: UUID? = nil
    ) {
        self.dbQueue = dbQueue
        self.requestAccessOperation = requestAccessOperation
        self.authorizationSnapshotOperation = authorizationSnapshotOperation
        self.backfillOperation = backfillOperation
        self.explicitUserIdForTests = explicitUserIdForTests
    }

    var summaryText: String {
        if !snapshot.isAvailable {
            return AppCapabilityAvailability.healthKitSummaryText
        }
        if snapshot.isFullyAuthorized {
            return String(localized: "settings_apple_health_status_connected")
        }
        if snapshot.authorizedCount > 0 {
            return String(localized: "settings_apple_health_status_partial")
        }
        if snapshot.hasDeniedAccess {
            return String(localized: "settings_apple_health_status_denied")
        }
        return String(localized: "settings_apple_health_status_not_requested")
    }

    var capabilityWarningText: String? {
        let warning = AppCapabilityAvailability.healthKitCapabilityWarning
        guard warning != summaryText else { return nil }
        return warning
    }

    var summaryIconName: String {
        if !snapshot.isAvailable { return "heart.slash" }
        if snapshot.isFullyAuthorized { return "heart.circle.fill" }
        if snapshot.authorizedCount > 0 { return "heart.circle" }
        if snapshot.hasDeniedAccess { return "exclamationmark.heart" }
        return "heart"
    }

    var summaryColor: Color {
        if !snapshot.isAvailable { return .secondary }
        if snapshot.isFullyAuthorized { return LifeOSColors.Semantic.primary }
        if snapshot.authorizedCount > 0 { return LifeOSColors.Recovery.caution }
        if snapshot.hasDeniedAccess { return LifeOSColors.Recovery.critical }
        return .secondary
    }

    var authorizationBreakdownText: String {
        String(
            format: String(localized: "settings_apple_health_authorized_count_format"),
            snapshot.authorizedCount,
            snapshot.metrics.count
        )
    }

    var canImportRecent: Bool {
        snapshot.isAvailable && snapshot.authorizedCount > 0 && !isBackfilling
    }

    func load() async {
        await refreshStatus()
    }

    func refreshStatus() async {
        isRefreshingStatus = true
        snapshot = await authorizationSnapshotOperation()
        isLoaded = true
        isRefreshingStatus = false
    }

    func requestAccess() async {
        guard snapshot.isAvailable else {
            statusMessage = AppCapabilityAvailability.healthKitCapabilityWarning ?? HealthKitError.notAvailable.errorDescription
            return
        }
        isRequestingAccess = true
        do {
            _ = try await requestAccessOperation()
            await refreshStatus()
            statusMessage = String(localized: "settings_apple_health_access_updated")
        } catch {
            statusMessage = userFacingSettingsError(error, fallback: HealthKitError.authorizationDenied)
        }
        isRequestingAccess = false
    }

    func importRecentData() async {
        guard let userId = try? await latestUserId() else {
            statusMessage = String(localized: "settings_sync_engine_unavailable")
            return
        }
        guard canImportRecent else {
            statusMessage = String(localized: "settings_apple_health_status_not_requested")
            return
        }

        isBackfilling = true
        do {
            try await backfillOperation(userId)
            statusMessage = String(localized: "settings_apple_health_imported")
        } catch {
            statusMessage = userFacingSettingsError(error, fallback: HealthKitError.authorizationDenied)
        }
        isBackfilling = false
    }

    func metricStatusText(for status: HKAuthorizationStatus) -> String {
        switch status {
        case .sharingAuthorized:
            return String(localized: "settings_apple_health_metric_allowed")
        case .sharingDenied:
            return String(localized: "settings_apple_health_metric_denied")
        case .notDetermined:
            return String(localized: "settings_apple_health_metric_not_requested")
        @unknown default:
            return String(localized: "settings_apple_health_metric_not_requested")
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

}

#if DEBUG
@MainActor
extension SettingsDestinationViewsTestHarness {
    private static func makeAccountTestUser(userId: UUID, authId: UUID) -> User {
        var user = User(id: userId, authId: authId, timezone: "UTC", units: .metric)
        user.email = "settings@lifeos.local"
        user.displayName = "Taylor"
        user.dateOfBirth = Calendar(identifier: .gregorian).date(from: DateComponents(year: 1993, month: 4, day: 12))
        user.ageRange = .age25_34
        user.sex = .female
        user.heightCm = 168.2
        user.primaryGoal = .performance
        user.activityLevel = .active
        user.createdAt = Date()
        user.updatedAt = Date()
        return user
    }

    private static func upsertAccountUser(_ user: User, in dbQueue: DatabaseQueue) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    DELETE FROM users
                    WHERE id = ? OR id = ? OR auth_id = ? OR auth_id = ?
                    """,
                arguments: [
                    user.id,
                    user.id.uuidString,
                    user.authId,
                    user.authId.uuidString
                ]
            )
            try user.insert(db)
        }
    }

    static func exerciseAccountSettingsBodyBranches() {
        let authId = UUID()
        let user = makeAccountTestUser(userId: UUID(), authId: authId)

        SettingsProfileView(
            testUser: user,
            testIsLoaded: true,
            testStatusMessage: "Saved"
        )._testEvaluateBody()
        SettingsProfileView(
            testUser: user,
            testIsLoaded: true,
            testStatusMessage: "Saved"
        )._testTriggerActions()
        SettingsProfileView(
            testUser: user,
            testIsLoaded: false,
            testStatusMessage: nil
        )._testEvaluateBody()

        SettingsHealthFlagsView(
            testFlags: UserHealthFlags(userId: UUID()),
            testCloudBackupEnabled: false,
            testIsLoaded: true,
            testStatusMessage: "Saved"
        )._testEvaluateBody()
        SettingsHealthFlagsView(
            testFlags: UserHealthFlags(userId: UUID()),
            testCloudBackupEnabled: true,
            testIsLoaded: true,
            testStatusMessage: "Saved"
        )._testTriggerActions()
        SettingsHealthFlagsView(
            testFlags: UserHealthFlags(userId: UUID()),
            testCloudBackupEnabled: false,
            testIsLoaded: false,
            testStatusMessage: nil
        )._testEvaluateBody()

        SettingsUnitsLocaleView(
            testUnits: .metric,
            testTimeZone: "Europe/Berlin",
            testIsLoaded: true,
            testStatusMessage: "Saved"
        )._testEvaluateBody()
        SettingsUnitsLocaleView(
            testUnits: .imperial,
            testTimeZone: "America/New_York",
            testIsLoaded: true,
            testStatusMessage: "Saved"
        )._testTriggerActions()

        let connectedSnapshot = SettingsAppleHealthSnapshot(
            isAvailable: true,
            metrics: [
                SettingsAppleHealthMetric(id: "sleep", title: "Sleep", status: .sharingAuthorized),
                SettingsAppleHealthMetric(id: "hrv", title: "HRV", status: .sharingAuthorized),
                SettingsAppleHealthMetric(id: "resting_hr", title: "Resting HR", status: .sharingAuthorized)
            ]
        )
        SettingsAppleHealthView(
            testSnapshot: connectedSnapshot,
            testIsLoaded: true,
            testStatusMessage: "Updated"
        )._testEvaluateBody()
        SettingsAppleHealthView(
            testSnapshot: connectedSnapshot,
            testIsLoaded: true,
            testStatusMessage: "Updated"
        )._testTriggerActions()
        SettingsAppleHealthView(
            testSnapshot: .unavailable,
            testIsLoaded: false,
            testStatusMessage: nil
        )._testEvaluateBody()
    }

    static func exerciseProfileSettingsViewModel(
        syncEngine: SyncEngine,
        dbQueue: DatabaseQueue,
        authId: UUID,
        userId: UUID
    ) async throws -> (
        isLoaded: Bool,
        statusMessage: String?,
        storedDisplayName: String?,
        storedDateOfBirth: String?,
        outboxDisplayName: String?,
        outboxGoal: String?
    ) {
        let user = makeAccountTestUser(userId: userId, authId: authId)
        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
        }
        try await upsertAccountUser(user, in: dbQueue)
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM outbox_events WHERE path = 'rest/v1/users'")
        }

        let viewModel = SettingsProfileViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            explicitUserIdForTests: userId
        )
        await viewModel.load()
        viewModel.displayName = "Morgan"
        viewModel.confirmDateOfBirth()
        viewModel.heightInputText = "171.4"
        viewModel.primaryGoal = .recovery
        viewModel.activityLevel = .moderate
        await viewModel.save()
        let isLoaded = viewModel.isLoaded
        let statusMessage = viewModel.statusMessage

        return try await dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT display_name, date_of_birth
                    FROM users
                    WHERE id = ? OR id = ?
                    LIMIT 1
                    """,
                arguments: [userId, userId.uuidString]
            )
            let payloadData = try Data.fetchOne(
                db,
                sql: """
                    SELECT body_json
                    FROM outbox_events
                    WHERE path = ?
                    ORDER BY created_at_local DESC
                    LIMIT 1
                    """,
                arguments: ["rest/v1/users"]
            )
            let payload: [String: Any]
            if let payloadData,
               let decoded = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
                payload = decoded
            } else {
                payload = [:]
            }
            return (
                isLoaded: isLoaded,
                statusMessage: statusMessage,
                storedDisplayName: row?["display_name"],
                storedDateOfBirth: (row?["date_of_birth"] as Date?).map(DateFormatting.dateOnlyString(from:)),
                outboxDisplayName: payload["display_name"] as? String,
                outboxGoal: payload["primary_goal"] as? String
            )
        }
    }

    static func exerciseHealthFlagsSettingsViewModel(
        syncEngine: SyncEngine,
        dbQueue: DatabaseQueue,
        authId: UUID,
        userId: UUID
    ) async throws -> (
        isLoaded: Bool,
        statusMessage: String?,
        disableHrv: Bool,
        hideCalories: Bool,
        pregnancyMode: Bool
    ) {
        let user = makeAccountTestUser(userId: userId, authId: authId)
        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
        }
        try await upsertAccountUser(user, in: dbQueue)
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM user_health_flags")
            try db.execute(sql: "DELETE FROM privacy_settings")
            try db.execute(sql: "DELETE FROM outbox_events WHERE path = 'rest/v1/user_health_flags'")
            var privacy = PrivacySettings(userId: userId)
            privacy.cloudBackupEnabled = true
            try privacy.insert(db)
        }

        let viewModel = SettingsHealthFlagsViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            enqueue: noopAccountSettingsEnqueue,
            explicitUserIdForTests: userId
        )
        await viewModel.load()
        viewModel.flags.hasCardiacCondition = true
        viewModel.flags.hasEatingDisorderHistory = true
        viewModel.flags.isPregnant = true
        await viewModel.save()

        return (
            isLoaded: viewModel.isLoaded,
            statusMessage: viewModel.statusMessage,
            disableHrv: viewModel.flags.disableHrv,
            hideCalories: viewModel.flags.hideCalories,
            pregnancyMode: viewModel.flags.pregnancyMode
        )
    }

    static func exerciseUnitsLocaleSettingsViewModel(
        syncEngine: SyncEngine,
        dbQueue: DatabaseQueue,
        authId: UUID,
        userId: UUID
    ) async throws -> (
        isLoaded: Bool,
        statusMessage: String?,
        storedUnits: String?,
        storedTimeZone: String?
    ) {
        let user = makeAccountTestUser(userId: userId, authId: authId)
        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
        }
        try await upsertAccountUser(user, in: dbQueue)
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM outbox_events WHERE path = 'rest/v1/users'")
        }

        let viewModel = SettingsUnitsLocaleViewModel(
            syncEngine: syncEngine,
            dbQueue: dbQueue,
            explicitUserIdForTests: userId
        )
        await viewModel.load()
        viewModel.units = .imperial
        viewModel.timeZoneIdentifier = "America/New_York"
        await viewModel.save()
        let isLoaded = viewModel.isLoaded
        let statusMessage = viewModel.statusMessage

        return try await dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT units, timezone
                    FROM users
                    WHERE id = ? OR id = ?
                    LIMIT 1
                    """,
                arguments: [userId, userId.uuidString]
            )
            return (
                isLoaded: isLoaded,
                statusMessage: statusMessage,
                storedUnits: row?["units"],
                storedTimeZone: row?["timezone"]
            )
        }
    }

    static func exerciseAppleHealthSettingsViewModel(
        dbQueue: DatabaseQueue,
        authId: UUID,
        userId: UUID
    ) async throws -> (
        summaryBefore: String,
        summaryAfter: String,
        statusMessage: String?,
        canImportAfterRequest: Bool
    ) {
        let user = makeAccountTestUser(userId: userId, authId: authId)
        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
        }
        try await upsertAccountUser(user, in: dbQueue)

        let initialSnapshot = SettingsAppleHealthSnapshot(
            isAvailable: true,
            metrics: [
                SettingsAppleHealthMetric(id: "sleep", title: "Sleep", status: .notDetermined),
                SettingsAppleHealthMetric(id: "hrv", title: "HRV", status: .notDetermined),
                SettingsAppleHealthMetric(id: "resting_hr", title: "Resting HR", status: .notDetermined)
            ]
        )
        let connectedSnapshot = SettingsAppleHealthSnapshot(
            isAvailable: true,
            metrics: [
                SettingsAppleHealthMetric(id: "sleep", title: "Sleep", status: .sharingAuthorized),
                SettingsAppleHealthMetric(id: "hrv", title: "HRV", status: .sharingAuthorized),
                SettingsAppleHealthMetric(id: "resting_hr", title: "Resting HR", status: .sharingAuthorized)
            ]
        )
        var currentSnapshot = initialSnapshot

        let viewModel = SettingsAppleHealthViewModel(
            dbQueue: dbQueue,
            requestAccessOperation: {
                currentSnapshot = connectedSnapshot
                return true
            },
            authorizationSnapshotOperation: {
                currentSnapshot
            },
            backfillOperation: noopAppleHealthBackfill,
            explicitUserIdForTests: userId
        )

        await viewModel.load()
        let summaryBefore = viewModel.summaryText
        await viewModel.requestAccess()
        await viewModel.importRecentData()

        return (
            summaryBefore: summaryBefore,
            summaryAfter: viewModel.summaryText,
            statusMessage: viewModel.statusMessage,
            canImportAfterRequest: viewModel.canImportRecent
        )
    }
}
#endif
