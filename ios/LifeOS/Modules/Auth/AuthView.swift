// MARK: - Auth View
// Sign-in screen with cloud auth options or local-only recovery when runtime
// configuration is unavailable.

import SwiftUI
import AuthenticationServices
import ComposableArchitecture

struct AuthView: View {
    @Environment(AuthManager.self) private var environmentAuthManager
    @State private var store: StoreOf<AuthFeature>
    @State private var isStartingLocalProfile = false
    private let authManagerOverride: AuthManager?

    private var authManager: AuthManager { if let authManagerOverride { return authManagerOverride }; return environmentAuthManager }
    private var shouldAnimateLogo: Bool {
        Self.shouldAnimateLogo(environment: ProcessInfo.processInfo.environment)
    }
    private var isHandlingAuthCallback: Bool {
        authManager.authCallbackStatus.isProcessing
    }
    private var isAppleSignInAvailable: Bool {
        AppCapabilityAvailability.isAppleSignInAvailable
    }
    private var isCloudAuthAvailable: Bool {
        SupabaseConfig.isRuntimeConfigured
    }
    private var authSubtitle: String {
        if isCloudAuthAvailable {
            return String(localized: "auth_subtitle")
        }
        return String(localized: "auth_local_mode_subtitle")
    }
    private var isAuthInteractionDisabled: Bool {
        isHandlingAuthCallback || isStartingLocalProfile
    }
#if DEBUG
    private static let testAppleSignInOverride = LockedTestOverride<@MainActor @Sendable () async throws -> Void>()
    private static let testSendOTPOverride = LockedTestOverride<@MainActor @Sendable (String) async throws -> Void>()
    private static let testVerifyOTPOverride = LockedTestOverride<@MainActor @Sendable (String, String) async throws -> Void>()
#endif

    private static func resolveAuthManager(
        authManagerOverride: AuthManager?,
        environmentAuthManager: AuthManager
    ) -> AuthManager {
        if let authManagerOverride {
            return authManagerOverride
        }
        return environmentAuthManager
    }

    private static func resolveAuthManagerDeferred(
        authManagerOverride: AuthManager?,
        environmentAuthManager: AuthManager
    ) -> AuthManager {
        resolveAuthManager(
            authManagerOverride: authManagerOverride,
            environmentAuthManager: environmentAuthManager
        )
    }

    init(
        store: StoreOf<AuthFeature> = Store(initialState: AuthFeature.State()) { AuthFeature() },
        testAuthManager: AuthManager? = nil
    ) {
        _store = State(initialValue: store)
        self.authManagerOverride = testAuthManager
    }

    var body: some View {
        @Bindable var store = store

        return VStack(spacing: Spacing.xl) {
            Spacer()

            // Logo & Welcome
            VStack(spacing: Spacing.m) {
                logoSymbolView(shouldAnimate: shouldAnimateLogo)

                Text(String(localized: "app_name"))
                    .font(LifeOSTypography.metricLarge)
                    .foregroundStyle(.primary)

                Text(authSubtitle)
                    .font(LifeOSTypography.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            // Auth Options
            authOptionsView
            .padding(.horizontal, Spacing.l)
            .disabled(isAuthInteractionDisabled)

            authCallbackFeedbackView

            // Error
            if let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, Spacing.l)
            }

            Spacer()
                .frame(height: Spacing.xl)
        }
        .background(LifeOSColors.Surface.background)
        .sheet(
            isPresented: emailOTPSheetBinding(store: store),
            content: emailOTPSheetContent
        )
    }

    @ViewBuilder
    private var authOptionsView: some View {
        if isCloudAuthAvailable {
            cloudAuthOptionsView
        } else {
            localOnlyAuthOptionsView
        }
    }

    private var cloudAuthOptionsView: some View {
        VStack(spacing: Spacing.m) {
            SignInWithAppleButton(
                .signIn,
                onRequest: appleSignInRequest,
                onCompletion: handleAppleSignInResult
            )
            .signInWithAppleButtonStyle(.whiteOutline)
            .frame(height: LayoutConstants.minTouchTarget)
            .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.buttonCornerRadius))
            .disabled(!isAppleSignInAvailable)

            if !isAppleSignInAvailable {
                Text(String(localized: "auth_apple_sign_in_unavailable_build"))
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: openEmailOTPTask) {
                Label(String(localized: "continue_with_email"), systemImage: "envelope")
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: LayoutConstants.minTouchTarget)
            }
            .buttonStyle(.bordered)
            .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.buttonCornerRadius))
        }
    }

    private var localOnlyAuthOptionsView: some View {
        VStack(spacing: Spacing.m) {
            Button(action: startLocalProfileTask) {
                Group {
                    if isStartingLocalProfile {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label(
                            String(localized: "auth_continue_on_this_device"),
                            systemImage: "person.crop.circle.badge.plus"
                        )
                        .font(LifeOSTypography.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: LayoutConstants.minTouchTarget)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.buttonCornerRadius))

            Text(String(localized: "auth_error_local_only_mode"))
                .font(LifeOSTypography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private func logoSymbolView(shouldAnimate: Bool) -> some View {
        if shouldAnimate {
            Image(systemName: "heart.text.square.fill")
                .font(LifeOSTypography.metricMedium)
                .foregroundStyle(LifeOSColors.Semantic.primary)
                .symbolEffect(.pulse)
        } else {
            Image(systemName: "heart.text.square.fill")
                .font(LifeOSTypography.metricMedium)
                .foregroundStyle(LifeOSColors.Semantic.primary)
        }
    }

    @ViewBuilder
    private var authCallbackFeedbackView: some View {
        switch authManager.authCallbackStatus {
        case .idle:
            EmptyView()
        case .processing:
            HStack(spacing: Spacing.s) {
                ProgressView()
                Text(String(localized: "auth_callback_processing_title"))
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.l)
        case .succeeded:
            Text(String(localized: "auth_callback_success_message"))
                .font(LifeOSTypography.caption)
                .foregroundStyle(LifeOSColors.Semantic.success)
                .padding(.horizontal, Spacing.l)
        case .failed(let errorMessage):
            Text(errorMessage)
                .font(LifeOSTypography.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, Spacing.l)
        }
    }

    // MARK: - Validated Bindings

    /// Binding that routes email text changes through the reducer for
    /// whitespace trimming, lowercasing, and validation state reset.
    private var emailBinding: Binding<String> {
        Binding(
            get: { store.email },
            set: { store.send(.emailChanged($0)) }
        )
    }

    /// Binding that routes OTP input through the reducer for
    /// non-digit stripping and 6-character cap.
    private var otpCodeBinding: Binding<String> {
        Binding(
            get: { store.otpCode },
            set: { store.send(.otpCodeChanged($0)) }
        )
    }

    // MARK: - Email OTP Sheet

    private var emailOTPSheet: some View {
        @Bindable var store = store

        return NavigationStack {
            VStack(spacing: Spacing.l) {
                if !store.otpSent {
                    // Email input
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text(String(localized: "auth_email_title"))
                            .font(LifeOSTypography.headline)

                        Text(String(localized: "auth_email_subtitle"))
                            .font(LifeOSTypography.body)
                            .foregroundStyle(.secondary)

                        TextField(String(localized: "auth_email_placeholder"), text: emailBinding)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        // Inline hint when email is non-empty but invalid.
                        if !store.email.isEmpty && !store.isEmailValid {
                            Text(String(localized: "auth_email_hint_invalid"))
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.secondary)
                        }

                        Button(action: sendOTPTask) {
                            if store.isLoading {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text(String(localized: "send_code"))
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.canSendOTP)
                    }
                } else {
                    // OTP input
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text(String(localized: "auth_otp_title"))
                            .font(LifeOSTypography.headline)

                        Text("\(String(localized: "auth_otp_sent_prefix")) \(store.email)")
                            .font(LifeOSTypography.body)
                            .foregroundStyle(.secondary)

                        TextField(String(localized: "auth_otp_placeholder"), text: otpCodeBinding)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)

                        Button(action: verifyOTPTask) {
                            if store.isLoading {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text(String(localized: "verify"))
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.canVerifyOTP)
                    }
                }

                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.red)
                }

                Spacer()
            }
            .padding(Spacing.l)
            .navigationTitle(String(localized: "auth_email_sign_in_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel"), action: closeEmailOTPSheet)
                }
            }
        }
    }

    private func emailOTPSheetContent() -> some View {
        emailOTPSheet
    }

    private func openEmailOTP(store: StoreOf<AuthFeature>) {
        store.send(.openEmailOTP(true))
    }

    private func emailOTPSheetBinding(store: StoreOf<AuthFeature>) -> Binding<Bool> {
        Binding(
            get: { store.showEmailOTP },
            set: { store.send(.openEmailOTP($0)) }
        )
    }

    private func appleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        Self.configureAppleRequest(request)
    }

    private func openEmailOTPTask() {
        openEmailOTPTask(store: store)
    }

    private func startLocalProfileTask() {
        scheduleAuthTask { await startLocalProfile() }
    }

    private func sendOTPTask() {
        sendOTPTask(store: store)
    }

    private func verifyOTPTask() {
        verifyOTPTask(store: store)
    }

    private func closeEmailOTPSheet() {
        store.send(.openEmailOTP(false))
    }

    private func handleAppleSignInResult(_ result: Result<ASAuthorization, Error>) {
        handleAppleSignInCompletion(result, store: store)
    }

    private func openEmailOTPTask(store: StoreOf<AuthFeature>) {
        guard isCloudAuthAvailable else { return }
        scheduleAuthTask {
            openEmailOTP(store: store)
        }
    }

    private func startLocalProfile() async {
        guard !isStartingLocalProfile else { return }
        isStartingLocalProfile = true
        defer { isStartingLocalProfile = false }
        await authManager.startLocalProfile()
    }

    private func scheduleAuthTask(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        Task { @MainActor in
            await operation()
        }
    }

    private func handleAppleSignInCompletion(
        _ result: Result<ASAuthorization, Error>,
        store: StoreOf<AuthFeature>
    ) {
        scheduleAuthTask { await handleAppleSignIn(result, store: store) }
    }

    private func sendOTPTask(store: StoreOf<AuthFeature>) {
        sendOTPTask(store: store, run: sendOTP)
    }

    private func sendOTPTask(
        store: StoreOf<AuthFeature>,
        run: @escaping @MainActor @Sendable (StoreOf<AuthFeature>) async -> Void
    ) {
        scheduleAuthTask { await run(store) }
    }

    private func verifyOTPTask(store: StoreOf<AuthFeature>) {
        verifyOTPTask(store: store, run: verifyOTP)
    }

    private func verifyOTPTask(
        store: StoreOf<AuthFeature>,
        run: @escaping @MainActor @Sendable (StoreOf<AuthFeature>) async -> Void
    ) {
        scheduleAuthTask { await run(store) }
    }

    private func handleAppleSignIn(
        _ result: Result<ASAuthorization, Error>,
        store: StoreOf<AuthFeature>
    ) async {
        switch result {
        case .success(let auth):
            let appleSignInCredential = auth.credential as? ASAuthorizationAppleIDCredential
            await handleAppleSignInSuccessResult(
                hasCredential: appleSignInCredential != nil,
                credential: appleSignInCredential,
                store: store,
                defaultSignIn: runDefaultAppleSignInWithAuthManager
            )
        case .failure(let error):
            if Self.shouldReportAppleFailure(error) {
                store.send(.appleSignInFailed(friendlyAuthError(error)))
            }
        }
    }

    private static func runDefaultAppleSignIn(
        credential: ASAuthorizationAppleIDCredential?,
        signIn: (ASAuthorizationAppleIDCredential) async throws -> Void
    ) async throws {
        guard let credential else { throw AuthError.invalidCredential }
        try await signIn(credential)
    }

    private func runDefaultAppleSignInWithAuthManager(credential: ASAuthorizationAppleIDCredential?) async throws { try await Self.runDefaultAppleSignIn(credential: credential, signIn: authManager.signInWithApple(credential:)) }

    private func runDefaultSendOTPWithAuthManager(email: String) async throws {
        try await authManager.sendOTP(to: email)
    }

    private func runDefaultVerifyOTPWithAuthManager(email: String, token: String) async throws { try await authManager.verifyOTP(email: email, token: token) }

    private func handleAppleSignInSuccessResult(
        hasCredential: Bool,
        credential: ASAuthorizationAppleIDCredential?,
        store: StoreOf<AuthFeature>,
        defaultSignIn: @escaping (ASAuthorizationAppleIDCredential?) async throws -> Void
    ) async {
        await handleAppleSignInSuccess(
            hasCredential: hasCredential,
            store: store
        ) {
#if DEBUG
            if let override = Self.testAppleSignInOverride.value {
                try await override()
            } else {
                try await defaultSignIn(credential)
            }
#else
            try await defaultSignIn(credential)
#endif
        }
    }

    private func sendOTP(store: StoreOf<AuthFeature>) async {
        await sendOTP(store: store, defaultSend: runDefaultSendOTPWithAuthManager(email:))
    }

    private func sendOTP(
        store: StoreOf<AuthFeature>,
        defaultSend: (String) async throws -> Void
    ) async {
#if DEBUG
        if let override = Self.testSendOTPOverride.value {
            await sendOTP(store: store, send: override)
            return
        }
#endif
        await sendOTP(store: store, send: defaultSend)
    }

    private func sendOTP(
        store: StoreOf<AuthFeature>,
        send: (String) async throws -> Void
    ) async {
        await runSendOTP(store: store, send: send)
    }

    private func verifyOTP(store: StoreOf<AuthFeature>) async {
        await verifyOTP(store: store, defaultVerify: runDefaultVerifyOTPWithAuthManager(email:token:))
    }

    private func verifyOTP(
        store: StoreOf<AuthFeature>,
        defaultVerify: (String, String) async throws -> Void
    ) async {
#if DEBUG
        if let override = Self.testVerifyOTPOverride.value {
            await verifyOTP(store: store, verify: override)
            return
        }
#endif
        await verifyOTP(store: store, verify: defaultVerify)
    }

    private func verifyOTP(
        store: StoreOf<AuthFeature>,
        verify: (String, String) async throws -> Void
    ) async {
        await runVerifyOTP(store: store, verify: verify)
    }

    private func runSendOTP(
        store: StoreOf<AuthFeature>,
        send: (String) async throws -> Void
    ) async {
        await runAuthAction(
            start: { store.send(.sendOTPTapped) },
            success: { store.send(.sendOTPSucceeded) },
            failure: { store.send(.sendOTPFailed($0)) }
        ) {
            try await send(store.email)
        }
    }

    private func runVerifyOTP(
        store: StoreOf<AuthFeature>,
        verify: (String, String) async throws -> Void
    ) async {
        await runAuthAction(
            start: { store.send(.verifyOTPTapped) },
            success: { store.send(.verifyOTPSucceeded) },
            failure: { store.send(.verifyOTPFailed($0)) }
        ) {
            try await verify(store.email, store.otpCode)
        }
    }

    /// Maximum retry attempts for OTP network operations.
    private static let maxOTPRetries = 3

    /// Base delay in seconds for exponential backoff (doubles each attempt: 2s, 4s).
    private static let baseRetryDelay: TimeInterval = 2.0

    private func runAuthAction(
        start: () -> Void,
        success: () -> Void,
        failure: (String) -> Void,
        operation: () async throws -> Void
    ) async {
        start()
        var lastError: Error?
        for attempt in 0..<Self.maxOTPRetries {
            do {
                try await operation()
                success()
                return
            } catch {
                lastError = error
                // Only retry on transient network errors, not auth/validation errors.
                guard Self.isRetryableAuthError(error), attempt < Self.maxOTPRetries - 1 else {
                    break
                }
                // Exponential backoff: 2s → 4s
                let delay = Self.baseRetryDelay * pow(2.0, Double(attempt))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        failure(friendlyAuthError(lastError ?? AuthError.networkUnavailable))
    }

    /// Determines whether an auth-related error is transient and worth retrying.
    /// Returns `false` for validation errors, invalid credentials, and session issues.
    private static func isRetryableAuthError(_ error: Error) -> Bool {
        if error is AuthError { return false }
        let nsError = error as NSError
        // NSURLErrorDomain network errors are retryable
        if nsError.domain == NSURLErrorDomain { return true }
        // HTTP 5xx or 429 are retryable
        if let status = nsError.userInfo["status"] as? Int {
            return status >= 500 || status == 429
        }
        return nsError.domain == "NSPOSIXErrorDomain"
    }

    private func friendlyAuthError(_ error: Error) -> String {
        Self.resolveFriendlyAuthError(error)
    }

    private func handleAppleAuthorization(
        hasValidCredential: Bool,
        store: StoreOf<AuthFeature>,
        signIn: () async throws -> Void
    ) async {
        guard hasValidCredential else {
            store.send(.appleSignInFailed(String(localized: "auth_invalid_apple_credential")))
            return
        }
        do {
            try await signIn()
        } catch {
            store.send(.appleSignInFailed(friendlyAuthError(error)))
        }
    }

    private func handleAppleSignInSuccess(
        hasCredential: Bool,
        store: StoreOf<AuthFeature>,
        signIn: () async throws -> Void
    ) async {
        await handleAppleAuthorization(
            hasValidCredential: hasCredential,
            store: store,
            signIn: signIn
        )
    }

    private static func resolveFriendlyAuthError(_ error: Error) -> String {
        if let authError = error as? AuthError {
            return authError.localizedDescription
        }
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return message
        }
        return String(localized: "auth_error_network_unavailable")
    }

    private static func shouldAnimateLogo(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil
    }

    private static func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.email, .fullName]
    }

    private static func requestedScopesOrEmpty(_ scopes: [ASAuthorization.Scope]?) -> [ASAuthorization.Scope] {
        if let scopes {
            return scopes
        }
        return []
    }

    private static func shouldReportAppleFailure(_ error: Error) -> Bool {
        (error as NSError).code != ASAuthorizationError.canceled.rawValue
    }

#if DEBUG
    @MainActor
    func _testEvaluateBody() {
        _ = body
    }

    @MainActor
    func _testEmailOTPSheet() -> some View {
        emailOTPSheet
    }

    @MainActor
    func _testEmailOTPSheetContent() -> some View {
        emailOTPSheetContent()
    }

    @MainActor
    func _testEvaluateLogoVariants() {
        _ = logoSymbolView(shouldAnimate: true)
        _ = logoSymbolView(shouldAnimate: false)
    }

    static func _testShouldAnimateLogo(environment: [String: String]) -> Bool {
        shouldAnimateLogo(environment: environment)
    }

    static func _testConfiguredAppleRequestScopes() -> [ASAuthorization.Scope] {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        configureAppleRequest(request)
        return requestedScopesOrEmpty(request.requestedScopes)
    }

    @MainActor
    func _testAppleSignInRequestWrapperScopes() -> [ASAuthorization.Scope] {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        appleSignInRequest(request)
        return Self.requestedScopesOrEmpty(request.requestedScopes)
    }

    static func _testRequestedScopesOrEmpty(_ scopes: [ASAuthorization.Scope]?) -> [ASAuthorization.Scope] {
        requestedScopesOrEmpty(scopes)
    }

    static func _testShouldReportAppleFailure(_ error: NSError) -> Bool {
        shouldReportAppleFailure(error)
    }

    static func _testFriendlyAuthError(_ error: Error) -> String {
        resolveFriendlyAuthError(error)
    }

    @MainActor
    func _testHandleAppleAuthorization(
        hasValidCredential: Bool,
        store: StoreOf<AuthFeature>,
        signIn: @escaping () async throws -> Void
    ) async {
        await handleAppleAuthorization(
            hasValidCredential: hasValidCredential,
            store: store,
            signIn: signIn
        )
    }

    @MainActor
    func _testRunAuthAction(
        store: StoreOf<AuthFeature>,
        startAction: AuthFeature.Action,
        successAction: AuthFeature.Action,
        failureAction: @escaping (String) -> AuthFeature.Action,
        operation: @escaping () async throws -> Void
    ) async {
        await runAuthAction(
            start: { store.send(startAction) },
            success: { store.send(successAction) },
            failure: { store.send(failureAction($0)) },
            operation: operation
        )
    }

    @MainActor
    func _testOpenEmailOTP(store: StoreOf<AuthFeature>) {
        openEmailOTP(store: store)
    }

    @MainActor
    func _testOpenEmailOTPTask(store: StoreOf<AuthFeature>) {
        scheduleAuthTask {
            openEmailOTP(store: store)
        }
    }

    @MainActor
    func _testScheduleAuthTask(
        operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        scheduleAuthTask(operation)
    }

    @MainActor
    func _testHandleAppleSignInResult(
        _ result: Result<ASAuthorization, Error>,
        store: StoreOf<AuthFeature>
    ) async {
        await handleAppleSignIn(result, store: store)
    }

    @MainActor
    func _testHandleAppleSignInSuccessResult(
        hasCredential: Bool,
        credential: ASAuthorizationAppleIDCredential? = nil,
        store: StoreOf<AuthFeature>,
        defaultSignIn: @escaping (ASAuthorizationAppleIDCredential?) async throws -> Void
    ) async {
        await handleAppleSignInSuccessResult(
            hasCredential: hasCredential,
            credential: credential,
            store: store,
            defaultSignIn: defaultSignIn
        )
    }

    @MainActor
    func _testHandleAppleSignInCompletion(
        _ result: Result<ASAuthorization, Error>,
        store: StoreOf<AuthFeature>
    ) {
        handleAppleSignInCompletion(result, store: store)
    }

    @MainActor
    func _testRunSendOTP(
        store: StoreOf<AuthFeature>,
        send: @escaping (String) async throws -> Void
    ) async {
        await runSendOTP(store: store, send: send)
    }

    @MainActor
    func _testRunVerifyOTP(
        store: StoreOf<AuthFeature>,
        verify: @escaping (String, String) async throws -> Void
    ) async {
        await runVerifyOTP(store: store, verify: verify)
    }

    @MainActor
    func _testSendOTPTask(
        store: StoreOf<AuthFeature>,
        run: @escaping @MainActor @Sendable (StoreOf<AuthFeature>) async -> Void
    ) {
        sendOTPTask(store: store, run: run)
    }

    @MainActor
    func _testVerifyOTPTask(
        store: StoreOf<AuthFeature>,
        run: @escaping @MainActor @Sendable (StoreOf<AuthFeature>) async -> Void
    ) {
        verifyOTPTask(store: store, run: run)
    }

    @MainActor
    func _testSendOTP(
        store: StoreOf<AuthFeature>,
        send: @escaping (String) async throws -> Void
    ) async {
        await sendOTP(store: store, send: send)
    }

    @MainActor
    func _testVerifyOTP(
        store: StoreOf<AuthFeature>,
        verify: @escaping (String, String) async throws -> Void
    ) async {
        await verifyOTP(store: store, verify: verify)
    }

    @MainActor
    func _testHandleAppleSignInSuccess(
        hasCredential: Bool,
        store: StoreOf<AuthFeature>,
        signIn: @escaping () async throws -> Void
    ) async {
        await handleAppleSignInSuccess(
            hasCredential: hasCredential,
            store: store,
            signIn: signIn
        )
    }

    static func _testSetAppleSignInOverride(
        _ override: (@MainActor @Sendable () async throws -> Void)?
    ) {
        testAppleSignInOverride.value = override
    }

    static func _testSetSendOTPOverride(
        _ override: (@MainActor @Sendable (String) async throws -> Void)?
    ) {
        testSendOTPOverride.value = override
    }

    static func _testSetVerifyOTPOverride(
        _ override: (@MainActor @Sendable (String, String) async throws -> Void)?
    ) {
        testVerifyOTPOverride.value = override
    }

    static func _testResetDefaultAuthOverrides() {
        testAppleSignInOverride.value = nil
        testSendOTPOverride.value = nil
        testVerifyOTPOverride.value = nil
    }

    @MainActor
    func _testAuthManagerGetterIsOverride() -> Bool {
        guard let authManagerOverride else { return false }
        return authManager === authManagerOverride
    }

    @MainActor
    func _testResolveAuthManagerFromGetter() -> AuthManager {
        authManager
    }

    static func _testResolveAuthManager(
        authManagerOverride: AuthManager?,
        environmentAuthManager: AuthManager
    ) -> AuthManager {
        resolveAuthManager(
            authManagerOverride: authManagerOverride,
            environmentAuthManager: environmentAuthManager
        )
    }

    static func _testResolveAuthManagerDeferred(
        authManagerOverride: AuthManager?,
        environmentAuthManager: AuthManager
    ) -> AuthManager {
        resolveAuthManagerDeferred(
            authManagerOverride: authManagerOverride,
            environmentAuthManager: environmentAuthManager
        )
    }

    @MainActor
    func _testRunDefaultSendOTPTask(store: StoreOf<AuthFeature>) {
        sendOTPTask(store: store)
    }

    @MainActor
    func _testRunDefaultVerifyOTPTask(store: StoreOf<AuthFeature>) {
        verifyOTPTask(store: store)
    }

    @MainActor
    func _testRunDefaultSendOTP(store: StoreOf<AuthFeature>) async {
        await sendOTP(store: store)
    }

    @MainActor
    func _testRunDefaultSendOTP(
        store: StoreOf<AuthFeature>,
        defaultSend: @escaping (String) async throws -> Void
    ) async {
        await sendOTP(store: store, defaultSend: defaultSend)
    }

    @MainActor
    func _testRunDefaultVerifyOTP(store: StoreOf<AuthFeature>) async {
        await verifyOTP(store: store)
    }

    @MainActor
    func _testRunDefaultVerifyOTP(
        store: StoreOf<AuthFeature>,
        defaultVerify: @escaping (String, String) async throws -> Void
    ) async {
        await verifyOTP(store: store, defaultVerify: defaultVerify)
    }

    static func _testRunDefaultAppleSignIn(
        credential: ASAuthorizationAppleIDCredential?,
        signIn: (ASAuthorizationAppleIDCredential) async throws -> Void
    ) async throws {
        try await runDefaultAppleSignIn(credential: credential, signIn: signIn)
    }

    @MainActor
    func _testRunDefaultAppleSignInWithAuthManager(credential: ASAuthorizationAppleIDCredential?) async throws { try await runDefaultAppleSignInWithAuthManager(credential: credential) }

    @MainActor
    func _testTriggerDefaultActionMethods(error: Error) {
        openEmailOTPTask()
        sendOTPTask()
        verifyOTPTask()
        closeEmailOTPSheet()
        handleAppleSignInResult(.failure(error))
    }

    @MainActor
    func _testEmailOTPSheetBindingRoundTrip(
        store: StoreOf<AuthFeature>,
        value: Bool
    ) -> Bool {
        let binding = emailOTPSheetBinding(store: store)
        binding.wrappedValue = value
        return binding.wrappedValue
    }
#endif
}

#Preview {
    AuthView()
        .environment(AuthManager())
}
