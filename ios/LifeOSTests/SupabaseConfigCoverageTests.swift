import XCTest
@testable import LifeOS

final class SupabaseConfigCoverageTests: XCTestCase {
    func testComputeIsRunningTestsDetectsAllSignals() {
        XCTAssertTrue(
            SupabaseConfig._testComputeIsRunningTests(
                env: ["XCTestConfigurationFilePath": "/tmp/xctest.xctestconfiguration"],
                args: []
            )
        )

        XCTAssertTrue(
            SupabaseConfig._testComputeIsRunningTests(
                env: ["LIFEOS_UI_TEST_BOOTSTRAP": "1"],
                args: []
            )
        )

        XCTAssertTrue(
            SupabaseConfig._testComputeIsRunningTests(
                env: [:],
                args: ["--lifeos-ui-test-bootstrap=1"]
            )
        )

        XCTAssertFalse(
            SupabaseConfig._testComputeIsRunningTests(
                env: [:],
                args: []
            )
        )
    }

    func testResolveURLPrefersEnvironmentWhenValid() {
        let resolved = SupabaseConfig._testResolveURL(
            envURL: "https://env.example.com",
            plistURL: "https://plist.example.com",
            isRunningTests: false
        )

        XCTAssertEqual(resolved.absoluteString, "https://env.example.com")
    }

    func testResolveURLFallsBackToPlistWhenEnvironmentMissingOrInvalid() {
        let fromMissingEnv = SupabaseConfig._testResolveURL(
            envURL: nil,
            plistURL: "https://plist.example.com",
            isRunningTests: false
        )
        XCTAssertEqual(fromMissingEnv.absoluteString, "https://plist.example.com")

        let fromInvalidEnv = SupabaseConfig._testResolveURL(
            envURL: "://invalid-url",
            plistURL: "https://plist.example.com",
            isRunningTests: false
        )
        XCTAssertEqual(fromInvalidEnv.absoluteString, "https://plist.example.com")
    }

    func testResolveURLFallsBackToDefaultWhenNoInputsProvided() {
        let resolved = SupabaseConfig._testResolveURL(
            envURL: nil,
            plistURL: nil,
            isRunningTests: true
        )

        XCTAssertEqual(resolved, URL(string: "https://localhost.invalid")!)
    }

    func testValidatedSupabaseURLSchemeRules() {
        let httpsCandidate = URL(string: "https://project.example.com")!
        let httpCandidate = URL(string: "http://project.example.com")!

        XCTAssertEqual(
            SupabaseConfig._testValidatedSupabaseURL(httpsCandidate, isRunningTests: false),
            httpsCandidate
        )
        XCTAssertEqual(
            SupabaseConfig._testValidatedSupabaseURL(httpCandidate, isRunningTests: false),
            URL(string: "https://localhost.invalid")!
        )
        XCTAssertEqual(
            SupabaseConfig._testValidatedSupabaseURL(httpCandidate, isRunningTests: true),
            httpCandidate
        )
    }

    func testResolveAnonKeyPriorityAndFallback() {
        let envKey = SupabaseConfig._testResolveAnonKey(
            envKey: "env-key",
            plistKey: "plist-key",
            isRunningTests: false
        )
        XCTAssertEqual(envKey, "env-key")

        let plistKey = SupabaseConfig._testResolveAnonKey(
            envKey: nil,
            plistKey: "plist-key",
            isRunningTests: false
        )
        XCTAssertEqual(plistKey, "plist-key")

        let fallbackFromEmptyPlist = SupabaseConfig._testResolveAnonKey(
            envKey: nil,
            plistKey: "",
            isRunningTests: true
        )
        XCTAssertEqual(fallbackFromEmptyPlist, "development-missing-anon-key")

        let fallbackInTests = SupabaseConfig._testResolveAnonKey(
            envKey: nil,
            plistKey: nil,
            isRunningTests: true
        )
        XCTAssertEqual(fallbackInTests, "development-missing-anon-key")
    }

    func testIsRuntimeConfiguredRequiresRealURLAndAnonKey() {
        XCTAssertTrue(
            SupabaseConfig._testIsRuntimeConfigured(
                url: URL(string: "https://project.example.com")!,
                anonKey: "real-anon-key"
            )
        )
        XCTAssertFalse(
            SupabaseConfig._testIsRuntimeConfigured(
                url: URL(string: "https://localhost.invalid")!,
                anonKey: "real-anon-key"
            )
        )
        XCTAssertFalse(
            SupabaseConfig._testIsRuntimeConfigured(
                url: URL(string: "https://project.example.com")!,
                anonKey: "development-missing-anon-key"
            )
        )
    }
}
