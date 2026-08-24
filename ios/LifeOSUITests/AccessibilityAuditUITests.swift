import XCTest

@MainActor
final class AccessibilityAuditUITests: XCTestCase {
    private let authId = "33333333-3333-4333-8333-333333333333"
    private let userId = "44444444-4444-4444-8444-444444444444"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAuthenticatedCoreScreensAccessibilityAudit() throws {
        guard #available(iOS 17.0, *) else {
            throw XCTSkip("XCUIApplication.performAccessibilityAudit requires iOS 17+.")
        }

        let app = makeApp()
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 30),
            "App did not reach foreground running state for accessibility audit"
        )
        XCTAssertTrue(
            app.tabBars.firstMatch.waitForExistence(timeout: 8),
            "Tab bar did not appear before accessibility audit"
        )

        settleAuditTarget(app, screenName: "Home")
        try performReleaseBlockingAudit(on: app, screenName: "Home") { attempt in
            if attempt > 1 {
                relaunchAuthenticatedApp(app)
            } else {
                app.activate()
            }
            XCTAssertTrue(
                app.tabBars.firstMatch.waitForExistence(timeout: 8),
                "Tab bar did not appear before Home accessibility audit retry"
            )
            settleAuditTarget(app, screenName: "Home")
        }

        let settingsTab = app.tabBars.buttons.element(boundBy: 3)
        XCTAssertTrue(settingsTab.exists, "Settings tab is unavailable for accessibility audit")
        settingsTab.tap()
        XCTAssertTrue(
            app.buttons["settings.link.account_management"].waitForExistence(timeout: 8),
            "Settings screen did not appear before accessibility audit"
        )

        settleAuditTarget(app, screenName: "Settings")
        try performReleaseBlockingAudit(on: app, screenName: "Settings") { attempt in
            if attempt > 1 {
                relaunchAuthenticatedApp(app)
            } else {
                app.activate()
            }
            let settingsTab = app.tabBars.buttons.element(boundBy: 3)
            XCTAssertTrue(settingsTab.waitForExistence(timeout: 8), "Settings tab is unavailable for accessibility audit retry")
            settingsTab.tap()
            XCTAssertTrue(
                app.buttons["settings.link.account_management"].waitForExistence(timeout: 8),
                "Settings screen did not appear before accessibility audit retry"
            )
            settleAuditTarget(app, screenName: "Settings")
        }
    }

    func testCriticalHealthFlowsAccessibilityAudit() throws {
        guard #available(iOS 17.0, *) else {
            throw XCTSkip("XCUIApplication.performAccessibilityAudit requires iOS 17+.")
        }

        let targets: [(name: String, url: String, identifier: String, seed: String?)] = [
            ("Nutrition", "lifeos://nutrition?date=2026-02-24", "nutrition.day.screen", "nutrition"),
            ("Training", "lifeos://workout?date=2026-02-24", "training.day.screen", "training"),
            ("Insights", "lifeos://insights", "insights.screen", "insights"),
            ("Privacy", "lifeos://settings/privacy", "settings.privacy.screen", nil),
        ]

        for target in targets {
            let app = makeApp(initialURL: target.url, seed: target.seed)
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
            let screen = app.descendants(matching: .any)[target.identifier]
            XCTAssertTrue(
                screen.waitForExistence(timeout: 10),
                "\(target.name) screen did not appear before accessibility audit"
            )
            settleAuditTarget(app, screenName: target.name)
            try performReleaseBlockingAudit(on: app, screenName: target.name) { _ in
                relaunchAuthenticatedApp(app)
                XCTAssertTrue(screen.waitForExistence(timeout: 10))
            }
            app.terminate()
        }
    }

    private func makeApp(
        initialURL: String? = nil,
        seed: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()

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
        if let initialURL {
            app.launchArguments += ["--lifeos-ui-test-initial-url=\(initialURL)"]
            app.launchEnvironment["LIFEOS_UI_TEST_INITIAL_URL"] = initialURL
        }
        app.launchEnvironment["LIFEOS_UI_TEST_SEED_DATE"] = "2026-02-24"
        app.launchEnvironment["LIFEOS_UI_TEST_SEED_NUTRITION"] = seed == "nutrition" ? "1" : "0"
        app.launchEnvironment["LIFEOS_UI_TEST_SEED_TRAINING"] = seed == "training" ? "1" : "0"
        app.launchEnvironment["LIFEOS_UI_TEST_SEED_INSIGHTS"] = seed == "insights" ? "1" : "0"
        app.launchEnvironment["SUPABASE_URL"] = "https://localhost.invalid"
        app.launchEnvironment["SUPABASE_ANON_KEY"] = "ui-test-anon-key"

        return app
    }

    private func relaunchAuthenticatedApp(_ app: XCUIApplication) {
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 30),
            "App did not reach foreground running state for accessibility audit retry"
        )
        dismissPendingSystemAlerts()
        settleAuditTarget(app, screenName: "relaunch")
    }

    @available(iOS 17.0, *)
    private func performReleaseBlockingAudit(
        on app: XCUIApplication,
        screenName: String,
        recoverInvalidTarget: (_ attempt: Int) -> Void
    ) throws {
        let maxAttempts = 4

        for attempt in 1...maxAttempts {
            do {
                try runAccessibilityAudit(on: app, screenName: screenName)
                return
            } catch let error where isInvalidTargetAppAuditError(error) {
                XCTContext.runActivity(named: "\(screenName) accessibility audit invalid target retry \(attempt)") { activity in
                    activity.add(XCTAttachment(string: String(describing: error)))
                }
                if attempt == maxAttempts {
                    throw error
                }
                recoverInvalidTarget(attempt)
            }
        }
    }

    @available(iOS 17.0, *)
    private func runAccessibilityAudit(
        on app: XCUIApplication,
        screenName: String
    ) throws {
        settleAuditTarget(app, screenName: screenName)

        try app.performAccessibilityAudit { issue in
            XCTContext.runActivity(named: "\(screenName) accessibility issue: \(issue.compactDescription)") { activity in
                activity.add(XCTAttachment(string: issue.detailedDescription))
                activity.add(XCTAttachment(string: self.debugDescription(for: issue)))
            }
            return false
        }
    }

    private func settleAuditTarget(_ app: XCUIApplication, screenName: String) {
        dismissPendingSystemAlerts()
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 10),
            "App did not stay foregrounded for \(screenName) accessibility audit"
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        dismissPendingSystemAlerts()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 10),
            "App did not return to foreground after \(screenName) system alert handling"
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }

    private func dismissPendingSystemAlerts() {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            guard dismissOneSystemAlertIfPresent() else {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
    }

    @discardableResult
    private func dismissOneSystemAlertIfPresent() -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 0.4) else {
            return false
        }

        let label = alert.label
        let shouldPreferDeny = label.localizedCaseInsensitiveContains("location")
            || label.localizedCaseInsensitiveContains("геопози")
            || label.localizedCaseInsensitiveContains("местополож")
        let allowButtons = ["Allow", "OK", "Разрешить", "Продолжить"]
        let denyButtons = ["Don't Allow", "Not Now", "Deny", "Запретить", "Не разрешать"]
        let preferredButtons = shouldPreferDeny
            ? denyButtons + allowButtons
            : allowButtons + denyButtons

        for title in preferredButtons {
            let button = alert.buttons[title]
            if button.exists {
                button.tap()
                return true
            }
        }

        let fallbackButton = alert.buttons.firstMatch
        if fallbackButton.exists {
            fallbackButton.tap()
            return true
        }
        return false
    }

    private func isInvalidTargetAppAuditError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "com.apple.accessibilityAudit"
            && nsError.code == -902
            && nsError.localizedDescription.contains("Invalid target app")
    }

    @available(iOS 17.0, *)
    private func debugDescription(for issue: XCUIAccessibilityAuditIssue) -> String {
        var lines = [
            "compactDescription: \(issue.compactDescription)",
            "detailedDescription: \(issue.detailedDescription)",
            "debugDescription: \(String(reflecting: issue))",
            "mirror:"
        ]

        for child in Mirror(reflecting: issue).children {
            lines.append("- \(child.label ?? "<nil>"): \(String(reflecting: child.value))")
        }

        return lines.joined(separator: "\n")
    }
}
