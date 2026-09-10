// MARK: - Supabase Configuration
// Source of truth: life_os_api_specification.md §Authentication

import Foundation
import Supabase

/// Centralized Supabase client configuration.
/// URL and anon key are loaded from environment or defaults.
enum SupabaseConfig {
    private static let fallbackURL = URL(string: "https://localhost.invalid")!
    private static let fallbackAnonKey = "development-missing-anon-key"
    private static let isRunningTests: Bool = computeIsRunningTests(
        env: ProcessInfo.processInfo.environment,
        args: ProcessInfo.processInfo.arguments
    )

    // MARK: - Keys

    /// Supabase project URL.
    /// Override via `SUPABASE_URL` environment variable or Info.plist key.
    static let url: URL = {
        resolveURL(
            envURL: ProcessInfo.processInfo.environment["SUPABASE_URL"],
            plistURL: Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
            isRunningTests: isRunningTests
        )
    }()

    /// Supabase anonymous (public) key.
    /// Override via `SUPABASE_ANON_KEY` environment variable or Info.plist key.
    static let anonKey: String = {
        resolveAnonKey(
            envKey: ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"],
            plistKey: Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
            isRunningTests: isRunningTests
        )
    }()

    /// Whether the app has a real remote runtime configuration and can talk to Supabase.
    static let isRuntimeConfigured: Bool = {
        let resolvedURL = resolveURL(
            envURL: ProcessInfo.processInfo.environment["SUPABASE_URL"],
            plistURL: Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
            isRunningTests: isRunningTests
        )
        let resolvedAnonKey = resolveAnonKey(
            envKey: ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"],
            plistKey: Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
            isRunningTests: isRunningTests
        )
        return resolvedURL != fallbackURL && resolvedAnonKey != fallbackAnonKey
    }()

    /// Deep link scheme for auth callbacks.
    static let redirectURL = URL(string: "lifeos://auth/callback")!

    // MARK: - Client

    /// Shared Supabase client instance.
    /// Session tokens go to a hardened Keychain storage
    /// (AfterFirstUnlock + ThisDeviceOnly) instead of the SDK default, which
    /// migrates to other devices via device backups.
    static let client = SupabaseClient(
        supabaseURL: url,
        supabaseKey: anonKey,
        options: .init(
            auth: .init(storage: SupabaseSessionKeychainStorage()),
            global: .init(
                headers: [
                    "Accept-Encoding": "gzip, br" // Implements §6.1.1 HTTP Compression
                ]
            )
        )
    )

    private static func resolveURL(
        envURL: String?,
        plistURL: String?,
        isRunningTests: Bool
    ) -> URL {
        if let envURL, let url = URL(string: envURL),
           isRunningTests || url.scheme?.lowercased() == "https" {
            return url
        }
        if let plistURL, let url = URL(string: plistURL),
           isRunningTests || url.scheme?.lowercased() == "https" {
            return url
        }
        if isRunningTests {
            return fallbackURL
        }
        return fallbackURL
    }

    private static func computeIsRunningTests(env: [String: String], args: [String]) -> Bool {
#if DEBUG
        // Live UI smoke uses the real Auth flow against the local HTTP stack.
        // It intentionally does not enable the fake-profile bootstrap flag.
        if env["LIFEOS_UI_TEST_LIVE_BACKEND"] == "1" { return true }
#endif
        let uiBootstrapFlag = env["LIFEOS_UI_TEST_BOOTSTRAP"] == "1"
            || args.contains(where: { $0 == "--lifeos-ui-test-bootstrap=1" })
        if env["XCTestConfigurationFilePath"] != nil {
            return true
        }
        return uiBootstrapFlag
    }

    private static func resolveAnonKey(
        envKey: String?,
        plistKey: String?,
        isRunningTests: Bool
    ) -> String {
        if let envKey, !envKey.isEmpty {
            return envKey
        }
        if let plistKey, !plistKey.isEmpty {
            return plistKey
        }
        if isRunningTests {
            return fallbackAnonKey
        }
        return fallbackAnonKey
    }

    private static func validatedSupabaseURL(_ candidate: URL, isRunningTests: Bool) -> URL {
        guard isRunningTests || candidate.scheme?.lowercased() == "https" else {
            return fallbackURL
        }
        return candidate
    }
}

#if DEBUG
extension SupabaseConfig {
    static func _testComputeIsRunningTests(env: [String: String], args: [String]) -> Bool {
        computeIsRunningTests(env: env, args: args)
    }

    static func _testResolveURL(envURL: String?, plistURL: String?, isRunningTests: Bool) -> URL {
        resolveURL(envURL: envURL, plistURL: plistURL, isRunningTests: isRunningTests)
    }

    static func _testResolveAnonKey(envKey: String?, plistKey: String?, isRunningTests: Bool) -> String {
        resolveAnonKey(envKey: envKey, plistKey: plistKey, isRunningTests: isRunningTests)
    }

    static func _testValidatedSupabaseURL(_ candidate: URL, isRunningTests: Bool) -> URL {
        validatedSupabaseURL(candidate, isRunningTests: isRunningTests)
    }

    static func _testIsRuntimeConfigured(url: URL, anonKey: String) -> Bool {
        url != fallbackURL && anonKey != fallbackAnonKey
    }
}
#endif
