// MARK: - Auth Manager
// Source of truth: life_os_api_specification.md §Authentication
// Supports: Anonymous (first-launch), Sign In with Apple, Email OTP.

import Foundation
import Observation
import Supabase
import AuthenticationServices
import GRDB
import OSLog

/// Authentication state machine.
enum AuthState: Equatable, Sendable {
    case loading
    case anonymous
    case authenticated
    case needsOnboarding
    case signedOut
}

enum AuthCallbackStatus: Equatable, Sendable {
    case idle
    case processing
    case succeeded(email: String?)
    case failed(String)

    var isProcessing: Bool {
        if case .processing = self {
            return true
        }
        return false
    }
}

/// Manages Supabase Auth lifecycle.
/// Observable so SwiftUI views react to auth state changes.
@Observable
@MainActor
final class AuthManager {
    @MainActor private(set) static var activeAuthId: UUID?
    @MainActor private(set) static var activeHasCloudSession = false
    @MainActor private(set) static var activeRequiresCloudReauthentication = false
    private nonisolated static let baseIsRunningTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        && ProcessInfo.processInfo.environment["LIFEOS_UI_TEST_LIVE_BACKEND"] != "1"
    private nonisolated static let offlineAuthIdDefaultsKey = "lifeos.offline_local_auth_id"
    private nonisolated static let lastCloudAuthIdDefaultsKey = "lifeos.last_cloud_auth_id"
#if DEBUG
    @MainActor private static var runningTestsOverride: Bool?
    @MainActor private static var bootstrapSessionOverride: (() async throws -> Session)?
    @MainActor private static var defaultBootstrapSessionOverride: (() async throws -> Session)?
    @MainActor private static var anonymousSignInOverride: (() async throws -> Session)?
    @MainActor private static var defaultAnonymousSignInOverride: (() async throws -> Session)?
    @MainActor private static var appleSignInOverride: ((String) async throws -> Session)?
    @MainActor private static var defaultAppleSignInOverride: ((String) async throws -> Session)?
    @MainActor private static var sendOTPOverride: ((String) async throws -> Void)?
    @MainActor private static var defaultSendOTPOverride: ((String) async throws -> Void)?
    @MainActor private static var verifyOTPOverride: ((String, String) async throws -> Session?)?
    @MainActor private static var defaultVerifyOTPOverride: ((String, String) async throws -> Session?)?
    @MainActor private static var signOutOverride: (() async throws -> Void)?
    @MainActor private static var defaultSignOutOverride: (() async throws -> Void)?
    @MainActor private static var deleteAccountOverride: ((String) async throws -> Void)?
    @MainActor private static var defaultDeleteAccountOverride: ((String) async throws -> Void)?
    @MainActor private static var fallbackUITestAuthIdOverride: UUID??
#endif

    @MainActor
    private static var fallbackUITestAuthId: UUID? {
#if DEBUG
        if let override = fallbackUITestAuthIdOverride {
            return override
        }
#endif
        return UUID(uuidString: "11111111-1111-4111-8111-111111111111")
    }

    private static var isRunningTests: Bool {
#if DEBUG
        if let override = runningTestsOverride {
            return override
        }
#endif
        return baseIsRunningTests
    }

#if DEBUG
    static func setActiveAuthIdForTests(_ authId: UUID?) {
        activeAuthId = authId
    }

    static func _testSetActiveHasCloudSession(_ value: Bool) {
        activeHasCloudSession = value
    }

    static func _testSetActiveRequiresCloudReauthentication(_ value: Bool) {
        activeRequiresCloudReauthentication = value
    }

    static func _testSetRunningTestsOverride(_ value: Bool?) {
        runningTestsOverride = value
    }

    static func _testSetBootstrapSessionOverride(_ value: (() async throws -> Session)?) {
        bootstrapSessionOverride = value
    }

    static func _testSetDefaultBootstrapSessionOverride(_ value: (() async throws -> Session)?) {
        defaultBootstrapSessionOverride = value
    }

    static func _testSetAnonymousSignInOverride(_ value: (() async throws -> Session)?) {
        anonymousSignInOverride = value
    }

    static func _testSetDefaultAnonymousSignInOverride(_ value: (() async throws -> Session)?) {
        defaultAnonymousSignInOverride = value
    }

    static func _testSetAppleSignInOverride(_ value: ((String) async throws -> Session)?) {
        appleSignInOverride = value
    }

    static func _testSetDefaultAppleSignInOverride(_ value: ((String) async throws -> Session)?) {
        defaultAppleSignInOverride = value
    }

    static func _testSetSendOTPOverride(_ value: ((String) async throws -> Void)?) {
        sendOTPOverride = value
    }

    static func _testSetDefaultSendOTPOverride(_ value: ((String) async throws -> Void)?) {
        defaultSendOTPOverride = value
    }

    static func _testSetVerifyOTPOverride(_ value: ((String, String) async throws -> Session?)?) {
        verifyOTPOverride = value
    }

    static func _testSetDefaultVerifyOTPOverride(_ value: ((String, String) async throws -> Session?)?) {
        defaultVerifyOTPOverride = value
    }

    static func _testSetSignOutOverride(_ value: (() async throws -> Void)?) {
        signOutOverride = value
    }

    static func _testSetDefaultSignOutOverride(_ value: (() async throws -> Void)?) {
        defaultSignOutOverride = value
    }

    static func _testSetDeleteAccountOverride(_ value: ((String) async throws -> Void)?) {
        deleteAccountOverride = value
    }

    static func _testSetDefaultDeleteAccountOverride(_ value: ((String) async throws -> Void)?) {
        defaultDeleteAccountOverride = value
    }

    static func _testSetOfflineLocalAuthId(_ authId: UUID?) {
        if let authId {
            UserDefaults.standard.set(authId.uuidString, forKey: offlineAuthIdDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: offlineAuthIdDefaultsKey)
        }
    }

    static func _testSetLastCloudAuthId(_ authId: UUID?) {
        if let authId {
            UserDefaults.standard.set(authId.uuidString, forKey: lastCloudAuthIdDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastCloudAuthIdDefaultsKey)
        }
    }

    static func _testSetFallbackUITestAuthIdOverride(_ value: UUID??) {
        fallbackUITestAuthIdOverride = value
    }

    static func _testResetOverrides() {
        UserDefaults.standard.removeObject(forKey: signedOutVaultOwnerKey)
        runningTestsOverride = nil
        bootstrapSessionOverride = nil
        defaultBootstrapSessionOverride = nil
        anonymousSignInOverride = nil
        defaultAnonymousSignInOverride = nil
        appleSignInOverride = nil
        defaultAppleSignInOverride = nil
        sendOTPOverride = nil
        defaultSendOTPOverride = nil
        verifyOTPOverride = nil
        defaultVerifyOTPOverride = nil
        signOutOverride = nil
        defaultSignOutOverride = nil
        deleteAccountOverride = nil
        defaultDeleteAccountOverride = nil
        fallbackUITestAuthIdOverride = nil
        UserDefaults.standard.removeObject(forKey: offlineAuthIdDefaultsKey)
        UserDefaults.standard.removeObject(forKey: lastCloudAuthIdDefaultsKey)
        activeRequiresCloudReauthentication = false
    }
#endif

    // MARK: - State

    private(set) var authState: AuthState = .loading
    private(set) var session: Session?
    private(set) var userId: UUID?
    private(set) var isAnonymous: Bool = false
    private(set) var hasRecoveredLocalIdentity = false
    private(set) var requiresCloudReauthentication = false
    private(set) var authCallbackStatus: AuthCallbackStatus = .idle

    var isAuthenticated: Bool {
        authState == .authenticated || authState == .anonymous || authState == .needsOnboarding
    }

    var hasCloudSession: Bool {
        session != nil
    }

    // MARK: - Dependencies

    private let client: SupabaseClient
    private let dbQueue: DatabaseManager
    private let logger = Logger(subsystem: "com.lifeos.app", category: "Auth")

    init(client: SupabaseClient = SupabaseConfig.client,
         db: DatabaseManager = .shared) {
        self.client = client
        self.dbQueue = db
    }

    // MARK: - Session Bootstrap

    /// Call on app launch. Restores existing session or signs in anonymously.
    func bootstrap() async {
        authCallbackStatus = .idle

        if UserDefaults.standard.string(forKey: Self.signedOutVaultOwnerKey) != nil {
            authState = .signedOut
            return
        }

        if UITestBootstrap.isEnabled,
           let overrideState = UITestBootstrap.requestedAuthState {
            applyUITestOverride(state: overrideState)
            return
        }

        if Self.isRunningTests {
            self.session = nil
            self.userId = nil
            self.isAnonymous = false
            hasRecoveredLocalIdentity = false
            setCloudReconnectRequirement(false)
            Self.activeAuthId = nil
            Self.activeHasCloudSession = false
            self.authState = .signedOut
            return
        }

        let shouldFallbackImmediatelyWithoutRuntime: Bool
#if DEBUG
        shouldFallbackImmediatelyWithoutRuntime =
            !Self.hasBootstrapSessionOverride && !Self.hasAnonymousSignInOverride
#else
        shouldFallbackImmediatelyWithoutRuntime = true
#endif

        if !SupabaseConfig.isRuntimeConfigured && shouldFallbackImmediatelyWithoutRuntime {
            await activateLocalFallbackMode(
                operation: "runtime bootstrap",
                requiresCloudReconnect: false
            )
            return
        }

        do {
            // Try to restore existing session
            let session: Session
#if DEBUG
            if let override = Self.bootstrapSessionOverride {
                session = try await override()
            } else if let override = Self.defaultBootstrapSessionOverride {
                session = try await override()
            } else {
                guard SupabaseConfig.isRuntimeConfigured else {
                    throw AuthError.localOnlyMode
                }
                session = try await client.auth.session
            }
#else
            session = try await client.auth.session
#endif
            try applySessionState(session, isAnonymous: session.user.isAnonymous)
            await synchronizeLocalIdentityState(
                authId: session.user.id,
                email: session.user.email,
                operation: "session restore"
            )

            await refreshPostAuthState()
        } catch {
            if await canRestoreExistingLocalIdentity() {
                await activateLocalFallbackMode(
                    operation: "session restore",
                    requiresCloudReconnect: true
                )
            } else {
                // No existing session — sign in anonymously per spec §3336
                await signInAnonymously()
            }
        }

        // Start monitoring session lifecycle (foreground + 401 events)
        startSessionMonitor()
    }

    // MARK: - Session Monitoring

    private var sessionMonitorObservers: [NSObjectProtocol] = []

    /// Subscribes to foreground transitions and 401 responses so the session
    /// is re-validated automatically when the token might have expired.
    /// Re-invocation removes previous observers first so duplicate
    /// subscriptions never stack.
    func startSessionMonitor() {
        for observer in sessionMonitorObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        sessionMonitorObservers.removeAll()

#if os(iOS)
        let foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.validateSession()
            }
        }
        sessionMonitorObservers.append(foregroundObserver)
#endif
        let unauthorizedObserver = NotificationCenter.default.addObserver(
            forName: .apiClientReceivedUnauthorized,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.validateSession()
            }
        }
        sessionMonitorObservers.append(unauthorizedObserver)
    }

    /// Validates the current session token. If refresh fails, we preserve the
    /// local profile when possible and mark the account for cloud reconnect.
    private func validateSession() async {
        guard session != nil, SupabaseConfig.isRuntimeConfigured else { return }

        do {
            let refreshedSession = try await client.auth.session
            try applySessionState(refreshedSession, isAnonymous: refreshedSession.user.isAnonymous)
            logger.info("Session validated successfully.")
        } catch {
            logger.warning("Session validation failed — entering local recovery mode: \(error.localizedDescription, privacy: .public)")
            if await canRestoreExistingLocalIdentity() {
                await activateLocalFallbackMode(
                    operation: "session validation",
                    requiresCloudReconnect: true
                )
                return
            }

            self.session = nil
            self.userId = nil
            self.isAnonymous = false
            hasRecoveredLocalIdentity = false
            setCloudReconnectRequirement(false)
            Self.activeAuthId = nil
            Self.activeHasCloudSession = false
            self.authState = .signedOut
        }
    }

    private func applyUITestOverride(state: AuthState) {
        let authId = UITestBootstrap.authId
        hasRecoveredLocalIdentity = false
        setCloudReconnectRequirement(false)

        switch state {
        case .signedOut:
            self.session = nil
            self.userId = nil
            self.isAnonymous = false
            Self.activeAuthId = nil
            Self.activeHasCloudSession = false
            self.authState = .signedOut
        case .anonymous:
            self.session = Self.makeUITestSession(authId: authId, isAnonymous: true)
            self.userId = authId
            self.isAnonymous = true
            Self.activeAuthId = authId
            Self.activeHasCloudSession = true
            self.authState = .anonymous
        case .authenticated:
            self.session = Self.makeUITestSession(authId: authId, isAnonymous: false)
            self.userId = authId
            self.isAnonymous = false
            Self.activeAuthId = authId
            Self.activeHasCloudSession = true
            self.authState = .authenticated
        case .needsOnboarding:
            self.session = Self.makeUITestSession(authId: authId, isAnonymous: false)
            self.userId = authId
            self.isAnonymous = false
            Self.activeAuthId = authId
            Self.activeHasCloudSession = true
            self.authState = .needsOnboarding
        case .loading:
            let fallbackId: UUID
            if let overriddenFallbackId = Self.fallbackUITestAuthId {
                fallbackId = overriddenFallbackId
            } else {
                fallbackId = authId
            }
            self.session = nil
            self.userId = fallbackId
            self.isAnonymous = false
            Self.activeAuthId = fallbackId
            Self.activeHasCloudSession = false
            self.authState = .signedOut
        }
    }

    private static func makeUITestSession(authId: UUID, isAnonymous: Bool) -> Session {
        let now = Date()
        let user = Supabase.User(
            id: authId,
            appMetadata: [:],
            userMetadata: [:],
            aud: "authenticated",
            createdAt: now,
            updatedAt: now,
            isAnonymous: isAnonymous
        )
        return Session(
            accessToken: "ui-test-token-\(authId.uuidString.lowercased())",
            tokenType: "bearer",
            expiresIn: 3600,
            expiresAt: now.addingTimeInterval(3600).timeIntervalSince1970,
            refreshToken: "ui-test-refresh-\(authId.uuidString.lowercased())",
            user: user
        )
    }

    // MARK: - Anonymous Sign-In (First Launch)

    /// Per spec: "Client signs in anonymously to get a JWT."
    /// This enables frictionless onboarding.
    func signInAnonymously() async {
        guard UserDefaults.standard.string(forKey: Self.signedOutVaultOwnerKey) == nil else {
            authState = .signedOut
            return
        }
        authCallbackStatus = .idle
        do {
            let session: Session
#if DEBUG
            if let override = Self.anonymousSignInOverride {
                session = try await override()
            } else if let override = Self.defaultAnonymousSignInOverride {
                session = try await override()
            } else {
                session = try await client.auth.signInAnonymously()
            }
#else
            session = try await client.auth.signInAnonymously()
#endif
            try applySessionState(session, isAnonymous: true)
            await synchronizeLocalIdentityState(
                authId: session.user.id,
                email: session.user.email,
                operation: "anonymous sign-in"
            )
            await refreshPostAuthState()
        } catch {
            await activateLocalFallbackMode(
                operation: "anonymous sign-in",
                requiresCloudReconnect: false
            )
        }
    }

    /// Restores a usable local profile for the current build.
    /// In cloud-configured environments we prefer anonymous auth to get a JWT;
    /// in local-only builds we create the offline profile directly on device.
    func startLocalProfile() async {
        authCallbackStatus = .idle
        guard SupabaseConfig.isRuntimeConfigured else {
            await activateOfflineLocalMode()
            return
        }
        await signInAnonymously()
    }

    // MARK: - Sign In with Apple

    /// Triggers Apple credential flow. On success, links or signs in.
    func signInWithApple(credential: ASAuthorizationAppleIDCredential) async throws {
        authCallbackStatus = .idle
#if DEBUG
        let hasTestOverride = Self.hasAppleIdentityOverride
#else
        let hasTestOverride = false
#endif
        if !hasTestOverride {
            try Self.requireCloudAuthRuntime()
        }
        guard hasTestOverride || AppCapabilityAvailability.isAppleSignInAvailable else {
            throw AuthError.appleSignInUnavailable
        }
        let tokenString = try Self.appleIdentityTokenString(from: credential.identityToken)
        try await signInWithAppleToken(
            tokenString,
            preferLinkingCurrentAccount: isAnonymous
        )
    }

    func linkEmail(to email: String) async throws {
        authCallbackStatus = .idle
        try Self.requireCloudAuthRuntime()
        let normalizedEmail = Self.normalizedEmail(email)
        guard !normalizedEmail.isEmpty else {
            throw AuthError.invalidCredential
        }
        guard session != nil else {
            throw AuthError.accountLinkRequiresCloudSession
        }

        let updatedUser = try await client.auth.update(
            user: UserAttributes(email: normalizedEmail),
            redirectTo: SupabaseConfig.redirectURL
        )

        if var currentSession = session {
            currentSession.user = updatedUser
            self.session = currentSession
            self.isAnonymous = updatedUser.isAnonymous
            Self.activeHasCloudSession = true
        }

        await synchronizeLocalIdentityState(
            authId: updatedUser.id,
            email: updatedUser.email ?? normalizedEmail,
            operation: "email link"
        )
        await refreshPostAuthState(hasSession: true)
    }

    private func signInWithAppleToken(
        _ tokenString: String,
        preferLinkingCurrentAccount: Bool = false
    ) async throws {
        let session: Session
        let shouldLinkCurrentAnonymousAccount = preferLinkingCurrentAccount && isAnonymous && self.session != nil

        if shouldLinkCurrentAnonymousAccount {
            guard self.session != nil else {
                throw AuthError.accountLinkRequiresCloudSession
            }
            session = try await linkAppleIdentity(tokenString)
        } else {
            session = try await signInWithAppleIdentity(tokenString)
        }

        try applySessionState(session, isAnonymous: false)
        await synchronizeLocalIdentityState(
            authId: session.user.id,
            email: session.user.email,
            operation: "apple sign-in"
        )

        await refreshPostAuthState()
    }

    // MARK: - Email OTP (Magic Link)

    /// Send an OTP code to the given email.
    private static func runSendOTPOverrideIfPresent(_ email: String) async throws -> Bool {
#if DEBUG
        if let override = Self.sendOTPOverride {
            try await override(email)
            return true
        }
        if let override = Self.defaultSendOTPOverride {
            try await override(email)
            return true
        }
#endif
        return false
    }

    func sendOTP(to email: String) async throws {
        authCallbackStatus = .idle
        let normalizedEmail = Self.normalizedEmail(email)
        guard !normalizedEmail.isEmpty else {
            throw AuthError.invalidCredential
        }
        if try await Self.runSendOTPOverrideIfPresent(normalizedEmail) {
            return
        }
        try Self.requireCloudAuthRuntime()
        try await client.auth.signInWithOTP(
            email: normalizedEmail,
            redirectTo: SupabaseConfig.redirectURL
        )
    }

    func handleAuthCallback(_ url: URL) async {
        guard Self.isAuthCallbackURL(url) else { return }

        guard SupabaseConfig.isRuntimeConfigured else {
            authCallbackStatus = .failed(AuthError.localOnlyMode.errorDescription ?? "")
            return
        }

        authCallbackStatus = .processing

        do {
            let session = try await client.auth.session(from: url)
            try applySessionState(session, isAnonymous: session.user.isAnonymous)
            await synchronizeLocalIdentityState(
                authId: session.user.id,
                email: session.user.email,
                operation: "auth callback"
            )
            await refreshPostAuthState()
            authCallbackStatus = .succeeded(email: session.user.email)
        } catch {
            authCallbackStatus = .failed(Self.friendlyAuthMessage(error))
        }
    }

    func resetAuthCallbackStatus() {
        authCallbackStatus = .idle
    }

    /// Verify the OTP code the user received.
    func verifyOTP(email: String, token: String) async throws {
        authCallbackStatus = .idle
        let normalizedEmail = Self.normalizedEmail(email)
        guard !normalizedEmail.isEmpty else {
            throw AuthError.invalidCredential
        }
        let session: Session?
#if DEBUG
        if let override = Self.verifyOTPOverride {
            session = try await override(normalizedEmail, token)
        } else if let override = Self.defaultVerifyOTPOverride {
            session = try await override(normalizedEmail, token)
        } else {
            try Self.requireCloudAuthRuntime()
            session = try await client.auth.verifyOTP(email: normalizedEmail, token: token, type: .email).session
        }
#else
        try Self.requireCloudAuthRuntime()
        session = try await client.auth.verifyOTP(email: normalizedEmail, token: token, type: .email).session
#endif
        guard let session else {
            throw AuthError.sessionExpired
        }

        try applySessionState(session, isAnonymous: false)
        await synchronizeLocalIdentityState(
            authId: session.user.id,
            email: session.user.email,
            operation: "otp verification"
        )

        await refreshPostAuthState()
    }

    // MARK: - Sign Out

    func signOut(removingLocalData: Bool = false) async throws {
        let vaultOwner = userId
        if removingLocalData, let authId = userId {
            let localUser = try await dbQueue.dbQueue.read { db in
                try UserIdentityLookup.fetchUser(authId: authId.uuidString, db: db)
            }
            if let localUser {
                // The erasure executor purges user-scoped data and writes the
                // deletion audit + fresh stub itself; a second purge here would
                // delete that audit trail.
                _ = try await LocalPrivacyErasureExecutor.execute(reason: "explicit_local_profile_removal", user: LocalPrivacyUserContext(userId: localUser.id, authId: authId), dbQueue: dbQueue.dbQueue)
            }
        }
#if os(iOS)
        await PushNotificationManager.shared.unregisterCurrentDevice()
#endif
        if session != nil {
#if DEBUG
            if let override = Self.signOutOverride {
                try await override()
            } else if let override = Self.defaultSignOutOverride {
                try await override()
            } else {
                try await client.auth.signOut()
            }
#else
            try await client.auth.signOut()
#endif
        }
        // Preserve local-only history and queued writes; this vault remains bound to its owner.
        if removingLocalData {
            UserDefaults.standard.removeObject(forKey: Self.signedOutVaultOwnerKey)
        } else if let vaultOwner {
            UserDefaults.standard.set(vaultOwner.uuidString, forKey: Self.signedOutVaultOwnerKey)
        }
        BiometricAuthManager.shared.reset()
        Self.clearOfflineLocalAuthId()
        Self.clearLastCloudAuthId()
        self.session = nil
        self.userId = nil
        self.isAnonymous = false
        hasRecoveredLocalIdentity = false
        setCloudReconnectRequirement(false)
        self.authCallbackStatus = .idle
        Self.activeAuthId = nil
        Self.activeHasCloudSession = false
        self.authState = .signedOut
        GuardianManager.shared.clearRuntimeBanner(for: .authCloudReconnect)
        GuardianManager.shared.clearRuntimeBanner(for: .authLocalProfile)
        GuardianManager.shared.clearRuntimeBanner(for: .authStateRefresh)
        await AppContainer.shared?.widgetSnapshotCoordinator.clearSnapshot()
        WatchSyncManager.shared.clearSnapshot()
    }

    // MARK: - Account Deletion (GDPR)

    /// Requests account deletion via outbox-backed erasure flow.
    /// We intentionally keep the current auth session so the queued erasure
    /// request can be replayed reliably when connectivity is available.
    func deleteAccount(reason: String? = nil) async throws {
        guard userId != nil else { return }

        // Route through PrivacyGateway so deletion request follows LocalStore → Outbox → Replay.
        let requestReason = reason ?? "user_requested"
#if DEBUG
        if let override = Self.deleteAccountOverride {
            try await override(requestReason)
            return
        }
        if let override = Self.defaultDeleteAccountOverride {
            try await override(requestReason)
            return
        }
#endif
        try await PrivacyGateway().requestErasure(reason: requestReason)
    }

    // MARK: - Internal

    /// Resolve the current shell state after any auth/bootstrap transition.
    func refreshPostAuthState() async {
        await refreshPostAuthState(hasSession: session != nil)
    }

    private func refreshPostAuthState(hasSession: Bool) async {
        if UITestBootstrap.isEnabled,
           UITestBootstrap.requestedAuthState == .authenticated,
           authState == .needsOnboarding {
            GuardianManager.shared.clearRuntimeBanner(for: .authStateRefresh)
            authState = .authenticated
            return
        }

        let hasPersistentIdentity = hasSession || isAnonymous || hasRecoveredLocalIdentity
        guard hasPersistentIdentity else {
            GuardianManager.shared.clearRuntimeBanner(for: .authStateRefresh)
            authState = .signedOut
            return
        }

        do {
            let resolution = try await loadLocalAuthResolution(authId: userId)
            authState = resolvedPostBootstrapAuthState(
                hasPersistentIdentity: hasPersistentIdentity,
                resolution: resolution
            )
            GuardianManager.shared.clearRuntimeBanner(for: .authStateRefresh)
        } catch {
            logger.error("Failed to refresh post-auth state from local store: \(error.localizedDescription, privacy: .public)")
            GuardianManager.shared.showRuntimeBanner(
                message: String(localized: "runtime_banner_auth_state_refresh_failed"),
                for: .authStateRefresh
            )
            authState = .needsOnboarding
        }
    }

    /// Clears local user-scoped data to prevent cross-account data leakage.
    /// Keeps local_meta/device identity intact.
    private func clearLocalUserState() async throws {
        try await dbQueue.dbQueue.write { db in
            try LocalUserDataReset.purgeUserScopedData(in: db)
        }
    }

    private static let signedOutVaultOwnerKey = "lifeos.signed_out_vault_owner"

    private func applySessionState(_ session: Session, isAnonymous: Bool) throws {
        if let owner = UserDefaults.standard.string(forKey: Self.signedOutVaultOwnerKey),
           owner.lowercased() != session.user.id.uuidString.lowercased() {
            throw AuthError.localVaultBelongsToAnotherAccount
        }
        UserDefaults.standard.removeObject(forKey: Self.signedOutVaultOwnerKey)
        self.session = session
        self.userId = session.user.id
        self.isAnonymous = isAnonymous
        hasRecoveredLocalIdentity = false
        setCloudReconnectRequirement(false)
        Self.activeAuthId = session.user.id
        Self.activeHasCloudSession = true
        Self.persistLastCloudAuthId(session.user.id)
    }

    private func setCloudReconnectRequirement(_ requiresCloudReconnect: Bool) {
        requiresCloudReauthentication = requiresCloudReconnect
        Self.activeRequiresCloudReauthentication = requiresCloudReconnect
        if requiresCloudReconnect {
            GuardianManager.shared.showRuntimeBanner(
                message: String(localized: "runtime_banner_auth_cloud_reconnect"),
                for: .authCloudReconnect
            )
        } else {
            GuardianManager.shared.clearRuntimeBanner(for: .authCloudReconnect)
        }
    }

    private struct LocalAuthResolution {
        let user: User?
        let onboardingStep: OnboardingStep?

        var isOnboardingComplete: Bool {
            user?.onboardingCompleted == true || onboardingStep == .onboardingComplete
        }
    }

    private func loadLocalAuthResolution(authId: UUID?) async throws -> LocalAuthResolution {
        let activeAuthId = authId?.uuidString
        return try await dbQueue.dbQueue.read { db in
            let user = try UserIdentityLookup.fetchUser(authId: activeAuthId, db: db)
            let resolvedUserId = try UserIdentityLookup.resolveUserId(authId: activeAuthId, db: db)
            let onboardingStepRaw: String?
            if let resolvedUserId {
                onboardingStepRaw = try String.fetchOne(
                    db,
                    sql: """
                        SELECT step
                        FROM onboarding_state
                        WHERE user_id = ? OR user_id = ?
                        ORDER BY updated_at DESC
                        LIMIT 1
                        """,
                    arguments: [resolvedUserId, resolvedUserId.uuidString]
                )
            } else {
                onboardingStepRaw = nil
            }
            return LocalAuthResolution(
                user: user,
                onboardingStep: onboardingStepRaw.flatMap(OnboardingStep.init(rawValue:))
            )
        }
    }

    private func resolvedPostBootstrapAuthState(
        hasPersistentIdentity: Bool,
        resolution: LocalAuthResolution
    ) -> AuthState {
        guard hasPersistentIdentity else {
            return .signedOut
        }
        if resolution.isOnboardingComplete {
            return isAnonymous ? .anonymous : .authenticated
        }
        return .needsOnboarding
    }

    private func activateOfflineLocalMode() async {
        guard UserDefaults.standard.string(forKey: Self.signedOutVaultOwnerKey) == nil else {
            authState = .signedOut
            return
        }
        let offlineAuthId = Self.offlineLocalAuthId()
        await synchronizeLocalIdentityState(
            authId: offlineAuthId,
            email: nil,
            operation: "offline local mode"
        )
        self.session = nil
        self.userId = offlineAuthId
        self.isAnonymous = true
        hasRecoveredLocalIdentity = false
        setCloudReconnectRequirement(false)
        self.authCallbackStatus = .idle
        Self.activeAuthId = offlineAuthId
        Self.activeHasCloudSession = false
        await refreshPostAuthState()
    }

    nonisolated static func isAuthCallbackURL(_ url: URL) -> Bool {
        url.scheme == "lifeos" && url.host() == "auth" && url.path().hasPrefix("/callback")
    }

    private func synchronizeLocalIdentityState(
        authId: UUID,
        email: String?,
        operation: String
    ) async {
        do {
            let offlineAuthId = Self.storedOfflineLocalAuthId()
            let hasCloudSession = session != nil
            _ = try await dbQueue.dbQueue.write { db in
                if hasCloudSession {
                    try UserIdentityReconciler.reconcileCloudAuthenticatedIdentity(
                        authId: authId,
                        email: email,
                        offlineAuthId: offlineAuthId,
                        db: db
                    )
                } else {
                    try UserIdentityReconciler.reconcileAuthenticatedIdentity(
                        authId: authId,
                        email: email,
                        offlineAuthId: offlineAuthId,
                        db: db
                    )
                }
            }
            if let syncEngine = AppContainer.shared?.syncEngine {
                try await scheduleCanonicalUserUpsertIfNeeded(
                    authId: authId,
                    email: email,
                    syncEngine: syncEngine
                )
            }
            if let offlineAuthId, offlineAuthId != authId {
                Self.clearOfflineLocalAuthId()
            }
            GuardianManager.shared.clearRuntimeBanner(for: .authLocalProfile)
        } catch {
            logger.error(
                "Failed to synchronize local identity during \(operation, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            GuardianManager.shared.showRuntimeBanner(
                message: String(localized: "runtime_banner_auth_local_profile_failed"),
                for: .authLocalProfile
            )
        }
    }

    private func scheduleCanonicalUserUpsertIfNeeded(
        authId: UUID,
        email: String?,
        syncEngine: SyncEngine
    ) async throws {
        let hasCloudSession = await MainActor.run { Self.activeHasCloudSession }
        guard SupabaseConfig.isRuntimeConfigured, hasCloudSession else {
            return
        }

        guard let user = try await dbQueue.dbQueue.read({ db in
            try UserIdentityReconciler.preferredLocalUser(authId: authId, db: db)
        }) else {
            return
        }

        var payload: [String: Any] = [
            "id": authId.uuidString,
            "auth_id": authId.uuidString,
        ]
        if let normalizedEmail = Self.normalizedOptionalEmail(email) ?? Self.normalizedOptionalEmail(user.email) {
            payload["email"] = normalizedEmail
        }

        try await syncEngine.enqueueOrRefreshCanonicalUserUpsert(
            bodyJson: try JSONSerialization.data(withJSONObject: payload, options: []),
            userId: authId,
            priority: 10
        )
        try await syncEngine.retryFailedPermanentEventsRecoverableFromUserBootstrap()
    }

    private func canRestoreExistingLocalIdentity() async -> Bool {
        do {
            return try await dbQueue.dbQueue.read { db in
                if let lastCloudAuthId = Self.storedLastCloudAuthId(),
                   try UserIdentityReconciler.hasLocalUser(authId: lastCloudAuthId, db: db) {
                    return true
                }
                if let offlineAuthId = Self.storedOfflineLocalAuthId(),
                   try UserIdentityReconciler.hasLocalUser(authId: offlineAuthId, db: db) {
                    return true
                }
                return false
            }
        } catch {
            logger.error("Failed to inspect local fallback identity: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func activateLocalFallbackMode(
        operation: String,
        requiresCloudReconnect: Bool
    ) async {
        if let fallbackIdentity = await resolvePreferredLocalFallbackIdentity() {
            await synchronizeLocalIdentityState(
                authId: fallbackIdentity,
                email: nil,
                operation: "\(operation) local fallback"
            )
            self.session = nil
            self.userId = fallbackIdentity
            self.isAnonymous = false
            hasRecoveredLocalIdentity = true
            setCloudReconnectRequirement(requiresCloudReconnect)
            self.authCallbackStatus = .idle
            Self.activeAuthId = fallbackIdentity
            Self.activeHasCloudSession = false
            await refreshLocalOnlyAuthState(authId: fallbackIdentity)
            return
        }

        await activateOfflineLocalMode()
    }

    private func resolvePreferredLocalFallbackIdentity() async -> UUID? {
        do {
            return try await dbQueue.dbQueue.read { db in
                if let lastCloudAuthId = Self.storedLastCloudAuthId(),
                   try UserIdentityReconciler.hasLocalUser(authId: lastCloudAuthId, db: db) {
                    return lastCloudAuthId
                }
                return nil
            }
        } catch {
            logger.error("Failed to resolve preferred local fallback identity: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func refreshLocalOnlyAuthState(authId: UUID) async {
        userId = authId
        await refreshPostAuthState(hasSession: false)
    }

    private func signInWithAppleIdentity(_ tokenString: String) async throws -> Session {
#if DEBUG
        if let override = Self.appleSignInOverride {
            return try await override(tokenString)
        }
        if let override = Self.defaultAppleSignInOverride {
            return try await override(tokenString)
        }
#endif
        try Self.requireCloudAuthRuntime()
        return try await client.auth.signInWithIdToken(
            credentials: .init(
                provider: .apple,
                idToken: tokenString
            )
        )
    }

    private func linkAppleIdentity(_ tokenString: String) async throws -> Session {
#if DEBUG
        if let override = Self.appleSignInOverride {
            return try await override(tokenString)
        }
        if let override = Self.defaultAppleSignInOverride {
            return try await override(tokenString)
        }
#endif
        try Self.requireCloudAuthRuntime()
        return try await client.auth.linkIdentityWithIdToken(
            credentials: .init(
                provider: .apple,
                idToken: tokenString
            )
        )
    }

    private nonisolated static func offlineLocalAuthId() -> UUID {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: offlineAuthIdDefaultsKey),
           let existing = UUID(uuidString: stored) {
            return existing
        }

        let generated = UUID()
        defaults.set(generated.uuidString, forKey: offlineAuthIdDefaultsKey)
        return generated
    }

    private nonisolated static func storedOfflineLocalAuthId() -> UUID? {
        guard let stored = UserDefaults.standard.string(forKey: offlineAuthIdDefaultsKey) else {
            return nil
        }
        return UUID(uuidString: stored)
    }

    private nonisolated static func clearOfflineLocalAuthId() {
        UserDefaults.standard.removeObject(forKey: offlineAuthIdDefaultsKey)
    }

    private nonisolated static func persistLastCloudAuthId(_ authId: UUID) {
        UserDefaults.standard.set(authId.uuidString, forKey: lastCloudAuthIdDefaultsKey)
    }

    private nonisolated static func storedLastCloudAuthId() -> UUID? {
        guard let stored = UserDefaults.standard.string(forKey: lastCloudAuthIdDefaultsKey) else {
            return nil
        }
        return UUID(uuidString: stored)
    }

    private nonisolated static func clearLastCloudAuthId() {
        UserDefaults.standard.removeObject(forKey: lastCloudAuthIdDefaultsKey)
    }

    private nonisolated static func normalizedEmail(_ email: String) -> String {
        email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private nonisolated static func normalizedOptionalEmail(_ email: String?) -> String? {
        guard let email else { return nil }
        let normalized = normalizedEmail(email)
        return normalized.isEmpty ? nil : normalized
    }

    private nonisolated static func requireCloudAuthRuntime() throws {
        guard SupabaseConfig.isRuntimeConfigured else {
            throw AuthError.localOnlyMode
        }
    }

#if DEBUG
    @MainActor
    private static var hasBootstrapSessionOverride: Bool {
        bootstrapSessionOverride != nil || defaultBootstrapSessionOverride != nil
    }

    @MainActor
    private static var hasAnonymousSignInOverride: Bool {
        anonymousSignInOverride != nil || defaultAnonymousSignInOverride != nil
    }

    @MainActor
    private static var hasAppleIdentityOverride: Bool {
        appleSignInOverride != nil || defaultAppleSignInOverride != nil
    }
#endif

    private static func friendlyAuthMessage(_ error: Error) -> String {
        if let authError = error as? AuthError,
           let message = authError.errorDescription {
            return message
        }
        if let message = (error as? LocalizedError)?.errorDescription, !message.isEmpty {
            return message
        }
        return AuthError.networkUnavailable.errorDescription ?? ""
    }

    nonisolated private static func appleIdentityTokenString(from identityToken: Data?) throws -> String {
        guard let identityToken,
              let tokenString = String(data: identityToken, encoding: .utf8) else {
            throw AuthError.invalidCredential
        }
        return tokenString
    }

    nonisolated private static func deleteAllRowsIfTableExists(_ table: String, db: Database) throws {
        let exists = try Int.fetchOne(
            db,
            sql: "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            arguments: [table]
        ) == 1
        guard exists else { return }
        try db.execute(sql: "DELETE FROM \(quotedIdentifier(table))")
    }

    nonisolated private static func quotedIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

#if DEBUG
extension AuthManager {
    func _testApplyUITestOverride(_ state: AuthState) {
        applyUITestOverride(state: state)
    }

    func _testSetState(
        authState: AuthState,
        userId: UUID?,
        isAnonymous: Bool,
        requiresCloudReauthentication: Bool = false,
        hasRecoveredLocalIdentity: Bool? = nil
    ) {
        self.authState = authState
        self.userId = userId
        self.isAnonymous = isAnonymous
        self.hasRecoveredLocalIdentity = hasRecoveredLocalIdentity ?? requiresCloudReauthentication
        self.requiresCloudReauthentication = requiresCloudReauthentication
        self.session = nil
    }

    func _testSetRequiresCloudReauthentication(_ value: Bool) {
        requiresCloudReauthentication = value
    }

    func _testSetRecoveredLocalIdentity(_ value: Bool) {
        hasRecoveredLocalIdentity = value
    }

    func _testSetAuthCallbackStatus(_ value: AuthCallbackStatus) {
        authCallbackStatus = value
    }

    func _testApplyCloudIdentity(_ id: UUID) {
        try? applySessionState(Self.makeUITestSession(authId: id, isAnonymous: false), isAnonymous: false)
    }

    func _testApplySessionState(_ session: Session, isAnonymous: Bool) {
        try? applySessionState(session, isAnonymous: isAnonymous)
    }

    func _testSignInWithAppleToken(_ tokenString: String) async throws {
        try await signInWithAppleToken(tokenString)
    }

    func _testRefreshPostAuthState(hasSession: Bool) async {
        await refreshPostAuthState(hasSession: hasSession)
    }

    func _testClearLocalUserState() async throws {
        try await clearLocalUserState()
    }

    nonisolated static func _testQuotedIdentifier(_ identifier: String) -> String {
        quotedIdentifier(identifier)
    }

    nonisolated static func _testDeleteAllRowsIfTableExists(_ table: String, db: Database) throws {
        try deleteAllRowsIfTableExists(table, db: db)
    }

    nonisolated static func _testAppleIdentityTokenString(from identityToken: Data?) throws -> String {
        try appleIdentityTokenString(from: identityToken)
    }
}
#endif

// MARK: - Auth Error

enum AuthError: LocalizedError {
    case localVaultBelongsToAnotherAccount
    case invalidCredential
    case sessionExpired
    case networkUnavailable
    case localOnlyMode
    case accountLinkRequiresCloudSession
    case cloudSessionReconnectRequired
    case appleSignInUnavailable

    var errorDescription: String? {
        switch self {
        case .localVaultBelongsToAnotherAccount:
            return String(localized: "auth_local_data_other_account_message")
        case .invalidCredential:
            return String(localized: "auth_error_invalid_credential")
        case .sessionExpired:
            return String(localized: "auth_error_session_expired")
        case .networkUnavailable:
            return String(localized: "auth_error_network_unavailable")
        case .localOnlyMode:
            return String(localized: "auth_error_local_only_mode")
        case .accountLinkRequiresCloudSession:
            return String(localized: "auth_error_link_requires_cloud_session")
        case .cloudSessionReconnectRequired:
            return String(localized: "auth_error_cloud_session_reconnect_required")
        case .appleSignInUnavailable:
            return String(localized: "auth_error_apple_sign_in_unavailable")
        }
    }
}
