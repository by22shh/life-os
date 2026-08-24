import XCTest

@MainActor
final class PerformanceHardGateUITests: XCTestCase {
    private enum GateDefaults {
        static let startupBudgetMs: Double = 4_000
        static let sampleCount = 3
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testColdLaunchStartupBudgetHardGate() throws {
        var samplesMs: [Double] = []
        samplesMs.reserveCapacity(GateDefaults.sampleCount)

        // Warm-up launch is intentionally excluded from measured samples.
        // It amortizes first-run simulator/session setup noise.
        let warmupApp = makeApp()
        warmupApp.launch()
        XCTAssertTrue(
            warmupApp.wait(for: .runningForeground, timeout: 8),
            "Warm-up launch did not reach foreground running state"
        )
        warmupApp.terminate()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        for _ in 0..<GateDefaults.sampleCount {
            let app = makeApp()
            let start = Date()
            app.launch()

            let runningForeground = app.wait(for: .runningForeground, timeout: 8)
            XCTAssertTrue(runningForeground, "App did not reach foreground running state after launch")

            let elapsedMs = Date().timeIntervalSince(start) * 1000
            samplesMs.append(elapsedMs)
            app.terminate()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        let averageMs = samplesMs.reduce(0, +) / Double(samplesMs.count)
        let maxMs = samplesMs.max() ?? 0

        XCTAssertLessThanOrEqual(
            averageMs,
            startupBudgetMs,
            "Average startup exceeded hard gate: \(averageMs)ms > \(startupBudgetMs)ms. Samples: \(samplesMs)"
        )
        XCTAssertLessThanOrEqual(
            maxMs,
            startupBudgetMs * 1.25,
            "Startup outlier exceeded hard gate tolerance: \(maxMs)ms. Samples: \(samplesMs)"
        )
    }

    private var startupBudgetMs: Double {
        let raw = ProcessInfo.processInfo.environment["LIFEOS_STARTUP_BUDGET_MS"] ?? ""
        return Double(raw) ?? GateDefaults.startupBudgetMs
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        let authId = "11111111-1111-4111-8111-111111111111"
        let userId = "22222222-2222-4222-8222-222222222222"

        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += [
            "--lifeos-ui-test-bootstrap=1",
            "--lifeos-ui-test-disable-background=1",
            "--lifeos-ui-test-auth-state=authenticated",
            "--lifeos-ui-test-auth-id=\(authId)",
            "--lifeos-ui-test-user-id=\(userId)",
            "--lifeos-ui-test-seed-sync-blocker=0"
        ]
        app.launchEnvironment["LIFEOS_UI_TEST_BOOTSTRAP"] = "1"
        app.launchEnvironment["LIFEOS_UI_TEST_DISABLE_BACKGROUND"] = "1"
        app.launchEnvironment["LIFEOS_UI_TEST_AUTH_STATE"] = "authenticated"
        app.launchEnvironment["LIFEOS_UI_TEST_AUTH_ID"] = authId
        app.launchEnvironment["LIFEOS_UI_TEST_USER_ID"] = userId
        app.launchEnvironment["LIFEOS_UI_TEST_SEED_SYNC_BLOCKER"] = "0"
        app.launchEnvironment["SUPABASE_URL"] = "https://localhost.invalid"
        app.launchEnvironment["SUPABASE_ANON_KEY"] = "ui-test-anon-key"
        return app
    }
}
