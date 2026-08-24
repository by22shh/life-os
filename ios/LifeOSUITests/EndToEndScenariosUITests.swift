import XCTest

@MainActor
final class EndToEndScenariosUITests: XCTestCase {
    private enum VerticalScrollDirection {
        case up
        case down
    }

    private let scenarioAuthId = UUID().uuidString.lowercased()
    private let scenarioUserId = UUID().uuidString.lowercased()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLiveBackendAnonymousBootstrapSmoke() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LIFEOS_UI_TEST_LIVE_BACKEND"] == "1",
              let rawURL = environment["LIFEOS_UI_TEST_LIVE_SUPABASE_URL"],
              let baseURL = URL(string: rawURL),
              let anonKey = environment["LIFEOS_UI_TEST_LIVE_SUPABASE_ANON_KEY"],
              !anonKey.isEmpty else {
            throw XCTSkip("Live backend smoke requires LIFEOS_UI_TEST_LIVE_* environment variables.")
        }

        var settingsRequest = URLRequest(
            url: baseURL.appendingPathComponent("auth/v1/settings")
        )
        settingsRequest.setValue(anonKey, forHTTPHeaderField: "apikey")
        let (_, response) = try await URLSession.shared.data(for: settingsRequest)
        XCTAssertEqual(
            (response as? HTTPURLResponse)?.statusCode,
            200,
            "The configured Supabase Auth endpoint is not reachable."
        )

        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["LIFEOS_UI_TEST_LIVE_BACKEND"] = "1"
        app.launchEnvironment["LIFEOS_UI_TEST_DISABLE_BACKGROUND"] = "1"
        app.launchEnvironment["SUPABASE_URL"] = rawURL
        app.launchEnvironment["SUPABASE_ANON_KEY"] = anonKey
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        let onboarding = app.buttons["onboarding.value_prop.continue"]
        let shell = app.tabBars.firstMatch
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !onboarding.exists, !shell.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(
            onboarding.exists || shell.exists,
            "The app did not complete anonymous bootstrap against the real backend."
        )
    }

    func testOnboardingFlow() throws {
        let app = makeApp(
            authState: "needs_onboarding",
            seedSyncBlocker: false
        )
        app.launch()

        let valuePropContinueCandidates = [
            app.buttons["onboarding.value_prop.continue"],
            app.buttons["onboarding.continue"]
        ]
        guard let continueButton = waitForAnyElement(
            valuePropContinueCandidates,
            in: app,
            timeout: 5,
            allowVerticalScroll: false
        ) else {
            print("UI DEBUG (onboarding.continue missing):\n\(app.debugDescription)")
            return XCTFail("Onboarding continue button not found")
        }
        continueButton.tap() // profile -> health flags

        let quickWinPrimary = app.buttons["onboarding.quick_win.primary"]
        if !waitForElement(quickWinPrimary, in: app, timeout: 8, allowVerticalScroll: false) {
            print("UI DEBUG (onboarding quick win missing):\n\(app.debugDescription)")
        }
        XCTAssertTrue(waitForElement(quickWinPrimary, in: app, timeout: 1, allowVerticalScroll: false))
        quickWinPrimary.tap() // mark quick win complete in UI tests
        XCTAssertTrue(waitForElement(quickWinPrimary, in: app, timeout: 8, allowVerticalScroll: false))
        quickWinPrimary.tap() // quick win -> HealthKit

        let skipHealthKit = app.buttons["onboarding.healthkit.skip"]
        XCTAssertTrue(waitForElement(skipHealthKit, in: app, timeout: 8, allowVerticalScroll: true))
        skipHealthKit.tap()

        let confirmDOB = app.buttons["onboarding.profile.confirm_date_of_birth"]
        XCTAssertTrue(waitForElement(confirmDOB, in: app, timeout: 8, allowVerticalScroll: true))
        confirmDOB.tap()

        let sexOption = app.descendants(matching: .any)["onboarding.profile.sex.male"]
        XCTAssertTrue(waitForElement(sexOption, in: app, timeout: 8, allowVerticalScroll: true))
        sexOption.tap()

        let heightField = app.textFields["onboarding.profile.height"]
        XCTAssertTrue(waitForElement(heightField, in: app, timeout: 8, allowVerticalScroll: true))

        let goalOption = app.descendants(matching: .any)["onboarding.profile.goal.recovery"]
        if !waitForElement(goalOption, in: app, timeout: 8, allowVerticalScroll: true) {
            print("UI DEBUG (onboarding.profile.goal.recovery missing):\n\(app.debugDescription)")
        }
        XCTAssertTrue(waitForElement(goalOption, in: app, timeout: 1, allowVerticalScroll: true))
        goalOption.tap()

        let activityOptionCandidates = [
            app.descendants(matching: .any)["onboarding.profile.activity.moderate"],
            app.descendants(matching: .button)["Moderate"],
            app.buttons["Moderate"]
        ]
        guard let activityOption = waitForAnyElement(
            activityOptionCandidates,
            in: app,
            timeout: 8,
            allowVerticalScroll: true
        ) else {
            print("UI DEBUG (onboarding.profile.activity.moderate missing):\n\(app.debugDescription)")
            return XCTFail("Onboarding activity option not found")
        }
        activityOption.tap()

        let profileWeightField = app.textFields["onboarding.profile.weight"]
        XCTAssertTrue(waitForElement(profileWeightField, in: app, timeout: 8, allowVerticalScroll: true))

        let profileContinue = app.buttons["onboarding.profile.continue"]
        XCTAssertTrue(waitForElement(profileContinue, in: app, timeout: 8, allowVerticalScroll: true))
        profileContinue.tap()

        let firstInsightContinue = app.buttons["onboarding.first_insight.continue"]
        if !waitForElement(firstInsightContinue, in: app, timeout: 8, allowVerticalScroll: true) {
            print("UI DEBUG (onboarding.first_insight.continue missing):\n\(app.debugDescription)")
            XCTFail("First insight continue button not found")
            return
        }
        firstInsightContinue.tap()

        let skipNotifications = app.buttons["onboarding.notifications.skip"]
        XCTAssertTrue(waitForElement(skipNotifications, in: app, timeout: 8, allowVerticalScroll: true))
        skipNotifications.tap()

        let completeButton = app.buttons["onboarding.complete"]
        XCTAssertTrue(waitForElement(completeButton, in: app, timeout: 8, allowVerticalScroll: true))
        completeButton.tap()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
    }

    func testSyncConflictScenario() throws {
        let app = makeApp(
            authState: "authenticated",
            seedSyncBlocker: true
        )
        app.launch()

        openSettingsTab(app)

        let syncLink = app.buttons["settings.link.sync"]
        XCTAssertTrue(waitForElement(syncLink, in: app, timeout: 8, allowVerticalScroll: true))
        syncLink.tap()

        let blocker = app.descendants(matching: .any)["settings.sync.blocker"]
        if !waitForElement(blocker, in: app, timeout: 8, allowVerticalScroll: false) {
            print("UI DEBUG (settings.sync.blocker missing):\n\(app.debugDescription)")
        }
        XCTAssertTrue(waitForElement(blocker, in: app, timeout: 1, allowVerticalScroll: false))

        let dismissButtonCandidates = [
            app.buttons["settings.sync.dismiss"],
            app.buttons["Dismiss"]
        ]
        guard let dismissButton = waitForAnyElement(
            dismissButtonCandidates,
            in: app,
            timeout: 5,
            allowVerticalScroll: false
        ) else {
            print("UI DEBUG (dismiss button missing):\n\(app.debugDescription)")
            return XCTFail("Dismiss button not found")
        }
        dismissButton.tap()

        let blockerCleared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: blocker
        )
        XCTAssertEqual(XCTWaiter().wait(for: [blockerCleared], timeout: 5), .completed)
    }

    func testDeleteAndExportScenario() throws {
        let app = makeApp(
            authState: "authenticated",
            seedSyncBlocker: false
        )
        app.launch()

        openSettingsTab(app)

        let exportButton = app.buttons["settings.button.export"]
        XCTAssertTrue(waitForElement(exportButton, in: app, timeout: 8, allowVerticalScroll: true))
        exportButton.tap()

        let exportStatus = app.descendants(matching: .any)["settings.export.status"]
        if !waitForElement(exportStatus, in: app, timeout: 8, allowVerticalScroll: true) {
            print("UI DEBUG (settings.export.status missing):\n\(app.debugDescription)")
        }
        XCTAssertTrue(waitForElement(exportStatus, in: app, timeout: 1, allowVerticalScroll: true))

        app.terminate()

        let privacyApp = makeApp(
            authState: "authenticated",
            seedSyncBlocker: false,
            initialURL: "lifeos://settings/privacy"
        )
        privacyApp.launch()

        let deleteButtonCandidates = [
            privacyApp.buttons["settings.privacy.delete_account"],
            privacyApp.buttons["Delete account"]
        ]
        guard let deleteButton = waitForAnyElement(
            deleteButtonCandidates,
            in: privacyApp,
            timeout: 8,
            allowVerticalScroll: true
        ) else {
            print("UI DEBUG (settings.privacy.delete_account missing):\n\(privacyApp.debugDescription)")
            return XCTFail("Delete account button not found")
        }
        XCTAssertTrue(
            waitForHittableElement(
                deleteButton,
                in: privacyApp,
                timeout: 3,
                allowVerticalScroll: true,
                preferredDirection: .up
            )
        )
        deleteButton.tap()

        let confirmDelete = privacyApp.buttons.matching(identifier: "settings.privacy.delete_account.confirm").firstMatch
        if waitForElement(confirmDelete, in: privacyApp, timeout: 5, allowVerticalScroll: false) {
            confirmDelete.tap()
        } else {
            let destructiveButtons = privacyApp.buttons.matching(
                NSPredicate(format: "identifier CONTAINS[c] 'delete' OR label CONTAINS[c] 'Delete'")
            )
            XCTAssertTrue(destructiveButtons.firstMatch.waitForExistence(timeout: 5))
            destructiveButtons.firstMatch.tap()
        }

        XCTAssertTrue(privacyApp.wait(for: .runningForeground, timeout: 5))
    }

    func testNotificationRulesScenario() throws {
        let app = makeApp(
            authState: "authenticated",
            seedSyncBlocker: false
        )
        app.launch()

        openSettingsTab(app)

        let notificationsLink = app.buttons["settings.link.notifications"]
        XCTAssertTrue(waitForElement(notificationsLink, in: app, timeout: 8, allowVerticalScroll: true))
        notificationsLink.tap()

        let criticalOnlySwitch = app.switches["settings.notifications.critical_only"]
        XCTAssertTrue(criticalOnlySwitch.waitForExistence(timeout: 5))
        if let value = criticalOnlySwitch.value as? String, value == "0" {
            criticalOnlySwitch.tap()
        }

        let saveButton = app.buttons["settings.notifications.save"]
        if !waitForElement(saveButton, in: app, timeout: 8, allowVerticalScroll: true) {
            print("UI DEBUG (settings.notifications.save missing):\n\(app.debugDescription)")
        }
        XCTAssertTrue(waitForElement(saveButton, in: app, timeout: 1, allowVerticalScroll: true))
        saveButton.tap()

        let statusText = app.descendants(matching: .any)["settings.notifications.status"]
        if !waitForElement(statusText, in: app, timeout: 8, allowVerticalScroll: true) {
            print("UI DEBUG (settings.notifications.status missing):\n\(app.debugDescription)")
        }
        XCTAssertTrue(waitForElement(statusText, in: app, timeout: 1, allowVerticalScroll: true))
    }

    func testNutritionManualSearchScenario() throws {
        let app = makeApp(
            authState: "authenticated",
            seedSyncBlocker: false,
            initialURL: "lifeos://nutrition?date=2026-02-24",
            seedNutrition: true,
            seedDate: "2026-02-24"
        )
        app.launch()

        let manualButton = app.buttons["nutrition.input.manual"]
        XCTAssertTrue(waitForElement(manualButton, in: app, timeout: 8, allowVerticalScroll: false))
        XCTAssertTrue(waitForElementCount(prefix: "nutrition.meal.row.", count: 1, in: app, timeout: 8))
        manualButton.tap()

        let searchScreen = app.descendants(matching: .any)["nutrition.search.screen"]
        if !waitForElement(searchScreen, in: app, timeout: 8, allowVerticalScroll: false) {
            print("UI DEBUG (nutrition.search.screen missing):\n\(app.debugDescription)")
        }
        XCTAssertTrue(waitForElement(searchScreen, in: app, timeout: 1, allowVerticalScroll: false))

        let searchField = app.textFields["nutrition.search.query"]
        if !waitForElement(searchField, in: app, timeout: 8, allowVerticalScroll: false) {
            print("UI DEBUG (nutrition.search.query missing):\n\(app.debugDescription)")
        }
        XCTAssertTrue(waitForElement(searchField, in: app, timeout: 8, allowVerticalScroll: false))
        searchField.tap()
        searchField.typeText("Banana\n")

        let resultButton = app.buttons["nutrition.search.result.Banana Bread UITest"]
        XCTAssertTrue(waitForElement(resultButton, in: app, timeout: 8, allowVerticalScroll: true))

        let favoriteButton = app.buttons[
            "nutrition.search.favorite.aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        ]
        XCTAssertTrue(waitForElement(favoriteButton, in: app, timeout: 8, allowVerticalScroll: true))
        favoriteButton.tap()
        XCTAssertTrue(favoriteButton.waitForExistence(timeout: 3))

        resultButton.tap()

        let logScreen = app.descendants(matching: .any)["nutrition.log.screen"]
        XCTAssertTrue(waitForElement(logScreen, in: app, timeout: 8, allowVerticalScroll: false))

        let saveButton = app.buttons["nutrition.log.save"]
        XCTAssertTrue(waitForElement(saveButton, in: app, timeout: 8, allowVerticalScroll: true))
        saveButton.tap()

        XCTAssertTrue(waitForElementCount(prefix: "nutrition.meal.row.", count: 2, in: app, timeout: 8))
    }

    func testTrainingMultiExerciseSaveScenario() throws {
        let logApp = makeApp(
            authState: "authenticated",
            seedSyncBlocker: false,
            initialURL: "lifeos://workout/log",
            seedTraining: true
        )
        logApp.launch()

        let workoutLogScreen = logApp.scrollViews["training.workout_log.screen"]
        XCTAssertTrue(waitForElement(workoutLogScreen, in: logApp, timeout: 8, allowVerticalScroll: false))

        let exerciseSearch = logApp.textFields["training.exercise.search"]
        XCTAssertTrue(exerciseSearch.waitForExistence(timeout: 5))

        replaceText(in: exerciseSearch, with: "Bench", app: logApp)
        let benchButton = logApp.buttons["training.exercise.result.Bench Press UITest"]
        XCTAssertTrue(waitForElement(benchButton, in: logApp, timeout: 5, allowVerticalScroll: true))
        benchButton.tap()

        replaceText(in: exerciseSearch, with: "Squat", app: logApp)
        let squatButton = logApp.buttons["training.exercise.result.Back Squat UITest"]
        XCTAssertTrue(waitForElement(squatButton, in: logApp, timeout: 5, allowVerticalScroll: true))
        squatButton.tap()

        let benchName = logApp.staticTexts["training.exercise.name.Bench Press UITest"]
        let squatName = logApp.staticTexts["training.exercise.name.Back Squat UITest"]
        if !waitForElement(benchName, in: logApp, timeout: 5, allowVerticalScroll: true) {
            print("UI DEBUG (training bench name missing):\n\(logApp.debugDescription)")
        }
        XCTAssertTrue(waitForElement(benchName, in: logApp, timeout: 1, allowVerticalScroll: true))
        XCTAssertTrue(waitForElement(squatName, in: logApp, timeout: 5, allowVerticalScroll: true))

        let benchWeight = logApp.textFields["training.exercise.weight.0.0"]
        let benchReps = logApp.textFields["training.exercise.reps.0.0"]
        let squatWeight = logApp.textFields["training.exercise.weight.1.0"]
        let squatReps = logApp.textFields["training.exercise.reps.1.0"]

        if !waitForElement(benchWeight, in: logApp, timeout: 5, allowVerticalScroll: true) {
            print("UI DEBUG (training weight fields missing):\n\(logApp.debugDescription)")
        }
        XCTAssertTrue(waitForElement(benchWeight, in: logApp, timeout: 5, allowVerticalScroll: true))
        replaceText(in: benchWeight, with: "80", app: logApp)
        replaceText(in: benchReps, with: "5", app: logApp)
        replaceText(in: squatWeight, with: "120", app: logApp)
        replaceText(in: squatReps, with: "5", app: logApp)

        let saveButton = logApp.buttons["training.workout.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.tap()

        let workoutLogDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: workoutLogScreen
        )
        XCTAssertEqual(XCTWaiter().wait(for: [workoutLogDismissed], timeout: 8), .completed)

        logApp.terminate()

        let verificationApp = makeApp(
            authState: "authenticated",
            seedSyncBlocker: false,
            initialURL: "lifeos://workout",
            seedTraining: true
        )
        verificationApp.launch()

        let trainingScreen = verificationApp.descendants(matching: .any)["training.day.screen"]
        if !waitForElement(trainingScreen, in: verificationApp, timeout: 8, allowVerticalScroll: false) {
            print("UI DEBUG (training day screen missing after save):\n\(verificationApp.debugDescription)")
        }
        XCTAssertTrue(waitForElement(trainingScreen, in: verificationApp, timeout: 8, allowVerticalScroll: false))
        if !waitForElementCount(prefix: "training.session.", minimum: 1, in: verificationApp, timeout: 8) {
            print("UI DEBUG (training session rows missing after save):\n\(verificationApp.debugDescription)")
        }
        XCTAssertTrue(waitForElementCount(prefix: "training.session.", minimum: 1, in: verificationApp, timeout: 8))
    }

    func testSupplementsMarkTakenScenario() throws {
        let app = makeApp(
            authState: "authenticated",
            seedSyncBlocker: false,
            initialURL: "lifeos://supplements?date=2026-02-24",
            seedSupplements: true,
            seedDate: "2026-02-24"
        )
        app.launch()

        let supplementsScreen = app.descendants(matching: .any)["supplements.day.screen"]
        if !waitForElement(supplementsScreen, in: app, timeout: 8, allowVerticalScroll: false) {
            print("UI DEBUG (supplements screen missing):\n\(app.debugDescription)")
        }
        XCTAssertTrue(waitForElement(supplementsScreen, in: app, timeout: 1, allowVerticalScroll: false))

        let markTakenButton = app.descendants(matching: .any)["supplements.mark_taken.Vitamin D3 UITest"]
        if !waitForElement(markTakenButton, in: app, timeout: 8, allowVerticalScroll: false) {
            print("UI DEBUG (supplements mark taken missing):\n\(app.debugDescription)")
        }
        XCTAssertTrue(waitForElement(markTakenButton, in: app, timeout: 1, allowVerticalScroll: false))
        markTakenButton.tap()

        let takenBadge = app.descendants(matching: .any)["supplements.taken.badge.Vitamin D3 UITest"]
        if !waitForElement(takenBadge, in: app, timeout: 8, allowVerticalScroll: false) {
            print("UI DEBUG (supplements taken badge missing):\n\(app.debugDescription)")
        }
        XCTAssertTrue(waitForElement(takenBadge, in: app, timeout: 1, allowVerticalScroll: false))

        let logRow = app.descendants(matching: .any)["supplements.log.row.Vitamin D3 UITest"]
        if !waitForElement(logRow, in: app, timeout: 8, allowVerticalScroll: false) {
            print("UI DEBUG (supplements log row missing):\n\(app.debugDescription)")
        }
        XCTAssertTrue(waitForElement(logRow, in: app, timeout: 1, allowVerticalScroll: false))
    }

    func testInsightsExperimentScenario() throws {
        let app = makeApp(
            authState: "authenticated",
            seedSyncBlocker: false,
            initialURL: "lifeos://insights",
            seedInsights: true
        )
        app.launch()

        let insightsScreen = app.descendants(matching: .any)["insights.screen"]
        if !waitForElement(insightsScreen, in: app, timeout: 8, allowVerticalScroll: false) {
            print("UI DEBUG (insights.screen missing):\n\(app.debugDescription)")
        }
        XCTAssertTrue(waitForElement(insightsScreen, in: app, timeout: 1, allowVerticalScroll: false))

        let experimentLibrary = app.descendants(matching: .any)["insights.experiments.library"]
        XCTAssertTrue(waitForElement(experimentLibrary, in: app, timeout: 8, allowVerticalScroll: true))
        experimentLibrary.tap()
        let experimentList = app.descendants(matching: .any)["experiments.list.screen"]
        XCTAssertTrue(waitForElement(experimentList, in: app, timeout: 8, allowVerticalScroll: false))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waitForElement(insightsScreen, in: app, timeout: 8, allowVerticalScroll: false))

        let insightCard = app.descendants(matching: .any)["insights.card.Caffeine Timing UITest"]
        if !waitForElement(insightCard, in: app, timeout: 8, allowVerticalScroll: true) {
            print("UI DEBUG (insight card missing):\n\(app.debugDescription)")
        }
        XCTAssertTrue(waitForElement(insightCard, in: app, timeout: 8, allowVerticalScroll: true))
        insightCard.tap()

        let detailScreen = app.scrollViews["insights.detail.screen"]
        XCTAssertTrue(waitForElement(detailScreen, in: app, timeout: 8, allowVerticalScroll: false))

        let startExperimentButton = app.buttons["insights.detail.start_experiment"]
        XCTAssertTrue(waitForElement(startExperimentButton, in: app, timeout: 5, allowVerticalScroll: true))
        startExperimentButton.tap()

        XCTAssertTrue(detailScreen.waitForExistence(timeout: 5))
    }

    private func makeApp(
        authState: String,
        seedSyncBlocker: Bool,
        initialURL: String? = nil,
        seedNutrition: Bool = false,
        seedTraining: Bool = false,
        seedSupplements: Bool = false,
        seedInsights: Bool = false,
        seedDate: String = "2026-02-24"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments += [
            "--lifeos-ui-test-bootstrap=1",
            "--lifeos-ui-test-disable-background=1",
            "--lifeos-ui-test-auth-state=\(authState)",
            "--lifeos-ui-test-auth-id=\(scenarioAuthId)",
            "--lifeos-ui-test-user-id=\(scenarioUserId)",
            "--lifeos-ui-test-seed-sync-blocker=\(seedSyncBlocker ? "1" : "0")",
            "--lifeos-ui-test-seed-nutrition=\(seedNutrition ? "1" : "0")",
            "--lifeos-ui-test-seed-training=\(seedTraining ? "1" : "0")",
            "--lifeos-ui-test-seed-supplements=\(seedSupplements ? "1" : "0")",
            "--lifeos-ui-test-seed-insights=\(seedInsights ? "1" : "0")",
            "--lifeos-ui-test-seed-date=\(seedDate)"
        ]
        if let initialURL {
            app.launchArguments += ["--lifeos-ui-test-initial-url=\(initialURL)"]
        }
        app.launchEnvironment["LIFEOS_UI_TEST_BOOTSTRAP"] = "1"
        app.launchEnvironment["LIFEOS_UI_TEST_DISABLE_BACKGROUND"] = "1"
        app.launchEnvironment["LIFEOS_UI_TEST_AUTH_STATE"] = authState
        app.launchEnvironment["LIFEOS_UI_TEST_AUTH_ID"] = scenarioAuthId
        app.launchEnvironment["LIFEOS_UI_TEST_USER_ID"] = scenarioUserId
        app.launchEnvironment["LIFEOS_UI_TEST_SEED_SYNC_BLOCKER"] = seedSyncBlocker ? "1" : "0"
        app.launchEnvironment["LIFEOS_UI_TEST_SEED_NUTRITION"] = seedNutrition ? "1" : "0"
        app.launchEnvironment["LIFEOS_UI_TEST_SEED_TRAINING"] = seedTraining ? "1" : "0"
        app.launchEnvironment["LIFEOS_UI_TEST_SEED_SUPPLEMENTS"] = seedSupplements ? "1" : "0"
        app.launchEnvironment["LIFEOS_UI_TEST_SEED_INSIGHTS"] = seedInsights ? "1" : "0"
        app.launchEnvironment["LIFEOS_UI_TEST_SEED_DATE"] = seedDate
        if let initialURL {
            app.launchEnvironment["LIFEOS_UI_TEST_INITIAL_URL"] = initialURL
        }
        app.launchEnvironment["SUPABASE_URL"] = "https://localhost.invalid"
        app.launchEnvironment["SUPABASE_ANON_KEY"] = "ui-test-anon-key"
        return app
    }

    private func openSettingsTab(_ app: XCUIApplication) {
        if !app.tabBars.firstMatch.waitForExistence(timeout: 8) {
            print("UI DEBUG (tab bar missing):\n\(app.debugDescription)")
        }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 8))
        let settingsTab = app.tabBars.buttons.element(boundBy: 3)
        XCTAssertTrue(settingsTab.exists)
        settingsTab.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.screen"].waitForExistence(timeout: 5))
    }

    private func waitForElement(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval,
        allowVerticalScroll: Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var scrollAttempts = 0
        while Date() < deadline {
            if element.exists {
                return true
            }
            if allowVerticalScroll {
                let direction: VerticalScrollDirection = scrollAttempts < 3 ? .up : .down
                performVerticalScroll(in: app, direction: direction)
                scrollAttempts = scrollAttempts == 5 ? 0 : scrollAttempts + 1
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return element.exists
    }

    private func waitForHittableElement(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval,
        allowVerticalScroll: Bool,
        preferredDirection: VerticalScrollDirection
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var scrollAttempts = 0
        while Date() < deadline {
            if element.exists && element.isHittable {
                return true
            }
            if allowVerticalScroll {
                let direction = scrollAttempts.isMultiple(of: 2)
                    ? preferredDirection
                    : opposite(of: preferredDirection)
                performVerticalScroll(in: app, direction: direction)
                scrollAttempts += 1
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return element.exists && element.isHittable
    }

    private func opposite(of direction: VerticalScrollDirection) -> VerticalScrollDirection {
        switch direction {
        case .up:
            return .down
        case .down:
            return .up
        }
    }

    private func waitForAnyElement(
        _ elements: [XCUIElement],
        in app: XCUIApplication,
        timeout: TimeInterval,
        allowVerticalScroll: Bool
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        var scrollAttempts = 0
        while Date() < deadline {
            if let matched = elements.first(where: \.exists) {
                return matched
            }
            if allowVerticalScroll {
                let direction: VerticalScrollDirection = scrollAttempts < 3 ? .up : .down
                performVerticalScroll(in: app, direction: direction)
                scrollAttempts = scrollAttempts == 5 ? 0 : scrollAttempts + 1
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return elements.first(where: \.exists)
    }

    private func primaryVerticalScrollContainer(in app: XCUIApplication) -> XCUIElement? {
        let table = app.tables.allElementsBoundByIndex
            .filter { $0.exists && $0.frame.height > 0 }
            .max { $0.frame.height < $1.frame.height }
        if let table {
            return table
        }

        return app.scrollViews.allElementsBoundByIndex
            .filter { $0.exists && $0.frame.height > 60 }
            .max { $0.frame.height < $1.frame.height }
    }

    private func performVerticalScroll(in app: XCUIApplication, direction: VerticalScrollDirection) {
        guard let scrollContainer = primaryVerticalScrollContainer(in: app) else {
            switch direction {
            case .up:
                app.swipeUp()
            case .down:
                app.swipeDown()
            }
            return
        }

        let startOffset: CGVector
        let endOffset: CGVector

        switch direction {
        case .up:
            startOffset = CGVector(dx: 0.5, dy: 0.72)
            endOffset = CGVector(dx: 0.5, dy: 0.42)
        case .down:
            startOffset = CGVector(dx: 0.5, dy: 0.42)
            endOffset = CGVector(dx: 0.5, dy: 0.72)
        }

        let start = scrollContainer.coordinate(withNormalizedOffset: startOffset)
        let end = scrollContainer.coordinate(withNormalizedOffset: endOffset)
        start.press(forDuration: 0.01, thenDragTo: end)
    }

    private func replaceText(in element: XCUIElement, with value: String, app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        focusTextInput(element, in: app)
        if let currentValue = element.value as? String, !currentValue.isEmpty {
            let deleteSequence = String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count + 2)
            element.typeText(deleteSequence)
        }
        element.typeText(value)
    }

    private func focusTextInput(_ element: XCUIElement, in app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch

        for _ in 0..<3 {
            element.tap()
            if keyboard.waitForExistence(timeout: 1) {
                return
            }
        }

        XCTFail("Keyboard did not appear for text input \(element.identifier)")
    }

    private func dismissKeyboardIfPresent(in app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }

        let doneButtonCandidates = [
            app.keyboards.buttons["Done"],
            app.toolbars.buttons["Done"],
            app.buttons["Done"]
        ]

        if let doneButton = doneButtonCandidates.first(where: \.exists) {
            doneButton.tap()
            return
        }

        if app.navigationBars.firstMatch.exists {
            app.navigationBars.firstMatch.tap()
        } else {
            app.swipeDown()
        }
    }

    private func countElements(withIdentifierPrefix prefix: String, in app: XCUIApplication) -> Int {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .count
    }

    private func waitForElementCount(
        prefix: String,
        count: Int,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        waitForElementCount(prefix: prefix, minimum: count, in: app, timeout: timeout) &&
            countElements(withIdentifierPrefix: prefix, in: app) == count
    }

    private func waitForElementCount(
        prefix: String,
        minimum: Int,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if countElements(withIdentifierPrefix: prefix, in: app) >= minimum {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return countElements(withIdentifierPrefix: prefix, in: app) >= minimum
    }
}
