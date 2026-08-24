import XCTest
@testable import LifeOS

final class DeepLinkRouterTests: XCTestCase {

    func testRegistryRoutes() {
        let router = DeepLinkRouter()

        XCTAssertTrue(router.handle(URL(string: "lifeos://recovery")!))
        XCTAssertEqual(router.pendingNavigation, .recoveryDetail(date: nil))

        XCTAssertTrue(router.handle(URL(string: "lifeos://nutrition?date=2026-02-16")!))
        XCTAssertEqual(router.pendingNavigation, .nutrition(date: "2026-02-16"))

        XCTAssertTrue(router.handle(URL(string: "lifeos://nutrition/log?method=photo")!))
        XCTAssertEqual(router.pendingNavigation, .nutritionLog(method: .photo, aiConfidence: nil))

        XCTAssertTrue(router.handle(URL(string: "lifeos://nutrition/log?method=photo&confidence=0.5")!))
        XCTAssertEqual(router.pendingNavigation, .nutritionLog(method: .photo, aiConfidence: 0.5))

        XCTAssertTrue(router.handle(URL(string: "lifeos://supplements?date=2026-02-16")!))
        XCTAssertEqual(router.pendingNavigation, .supplements(date: "2026-02-16"))

        XCTAssertTrue(router.handle(URL(string: "lifeos://workout?date=2026-02-16")!))
        XCTAssertEqual(router.pendingNavigation, .workout(date: "2026-02-16"))

        XCTAssertTrue(router.handle(URL(string: "lifeos://workout/log")!))
        XCTAssertEqual(router.pendingNavigation, .workoutLog)

        XCTAssertTrue(router.handle(URL(string: "lifeos://sleep?date=2026-02-16")!))
        XCTAssertEqual(router.pendingNavigation, .sleep(date: "2026-02-16"))

        XCTAssertTrue(router.handle(URL(string: "lifeos://diary?date=2026-02-16")!))
        XCTAssertEqual(router.pendingNavigation, .diary(date: "2026-02-16"))

        let insightId = UUID()
        XCTAssertTrue(router.handle(URL(string: "lifeos://insights/\(insightId.uuidString)")!))
        XCTAssertEqual(router.pendingNavigation, .insightDetail(id: insightId))

        let experimentId = UUID()
        XCTAssertTrue(router.handle(URL(string: "lifeos://experiments/\(experimentId.uuidString)")!))
        XCTAssertEqual(router.pendingNavigation, .experiment(id: experimentId))

        XCTAssertTrue(router.handle(URL(string: "lifeos://settings/sync")!))
        XCTAssertEqual(router.pendingNavigation, .settingsSync)

        XCTAssertTrue(router.handle(URL(string: "lifeos://settings/notifications")!))
        XCTAssertEqual(router.pendingNavigation, .settingsNotifications)

        XCTAssertTrue(router.handle(URL(string: "lifeos://settings/privacy")!))
        XCTAssertEqual(router.pendingNavigation, .settingsPrivacy)

        let labId = UUID()
        XCTAssertTrue(router.handle(URL(string: "lifeos://labs/\(labId.uuidString)")!))
        XCTAssertEqual(router.pendingNavigation, .labScan(id: labId))
    }

    func testFallbackUnknownRouteOpensHome() {
        let router = DeepLinkRouter()
        XCTAssertTrue(router.handle(URL(string: "lifeos://unknown/path")!))
        XCTAssertEqual(router.pendingNavigation, .home)
        XCTAssertEqual(router.selectedTab, .home)
    }

    func testConsumeClearsPendingDestination() {
        let router = DeepLinkRouter()
        XCTAssertTrue(router.handle(URL(string: "lifeos://settings/sync")!))
        let consumed = router.consumePendingNavigation()
        XCTAssertEqual(consumed, .settingsSync)
        XCTAssertNil(router.pendingNavigation)
    }

    func testLegacyAliasRoutesRemainSupported() {
        let router = DeepLinkRouter()

        XCTAssertTrue(router.handle(URL(string: "lifeos://diary/2026-02-16")!))
        XCTAssertEqual(router.pendingNavigation, .diary(date: "2026-02-16"))

        XCTAssertTrue(router.handle(URL(string: "lifeos://recovery/2026-02-16")!))
        XCTAssertEqual(router.pendingNavigation, .recoveryDetail(date: "2026-02-16"))

        XCTAssertTrue(router.handle(URL(string: "lifeos://food/log")!))
        XCTAssertEqual(router.pendingNavigation, .nutritionLog(method: nil, aiConfidence: nil))

        let experimentId = UUID()
        XCTAssertTrue(router.handle(URL(string: "lifeos://experiments/\(experimentId.uuidString)/log")!))
        XCTAssertEqual(router.pendingNavigation, .experiment(id: experimentId))

        XCTAssertTrue(router.handle(URL(string: "lifeos://achievements")!))
        XCTAssertEqual(router.pendingNavigation, .insights)
    }

    func testNonLifeOSSchemeIsRejected() {
        let router = DeepLinkRouter()
        XCTAssertFalse(router.handle(URL(string: "https://example.com")!))
        XCTAssertNil(router.pendingNavigation)
    }

    func testAdditionalRegistryRoutesAndFallbacks() {
        let router = DeepLinkRouter()

        XCTAssertTrue(router.handle(URL(string: "lifeos://auth/callback")!))
        XCTAssertEqual(router.pendingNavigation, .authCallback)

        XCTAssertTrue(router.handle(URL(string: "lifeos://hydration?date=2026-02-16")!))
        XCTAssertEqual(router.pendingNavigation, .hydration(date: "2026-02-16"))

        XCTAssertTrue(router.handle(URL(string: "lifeos://wellness?date=2026-02-16")!))
        XCTAssertEqual(router.pendingNavigation, .wellness(date: "2026-02-16"))

        XCTAssertTrue(router.handle(URL(string: "lifeos://menstrual?date=2026-02-16")!))
        XCTAssertEqual(router.pendingNavigation, .menstrual(date: "2026-02-16"))

        XCTAssertTrue(router.handle(URL(string: "lifeos://body-composition")!))
        XCTAssertEqual(router.pendingNavigation, .bodyComposition)

        XCTAssertTrue(router.handle(URL(string: "lifeos://bodyComposition")!))
        XCTAssertEqual(router.pendingNavigation, .bodyComposition)

        XCTAssertTrue(router.handle(URL(string: "lifeos://settings/other")!))
        XCTAssertEqual(router.pendingNavigation, .settings)

        XCTAssertTrue(router.handle(URL(string: "lifeos://labs/not-a-uuid")!))
        XCTAssertEqual(router.pendingNavigation, .labs)

        XCTAssertTrue(router.handle(URL(string: "lifeos://insights/not-a-uuid")!))
        XCTAssertEqual(router.pendingNavigation, .insights)

        router.selectedTab = .home
        XCTAssertTrue(router.handle(URL(string: "lifeos://simulation")!))
        XCTAssertEqual(router.pendingNavigation, .simulation)
        XCTAssertEqual(router.selectedTab, .home)

        router.selectedTab = .insights
        XCTAssertTrue(router.handle(URL(string: "lifeos://insights/simulate")!))
        XCTAssertEqual(router.pendingNavigation, .simulation)
        XCTAssertEqual(router.selectedTab, .insights)
    }

    func testNutritionAndFoodLogConfidenceNormalization() {
        let router = DeepLinkRouter()

        XCTAssertTrue(router.handle(URL(string: "lifeos://nutrition/log?method=voice&confidence=1.5")!))
        XCTAssertEqual(router.pendingNavigation, .nutritionLog(method: .voice, aiConfidence: 1.0))

        XCTAssertTrue(router.handle(URL(string: "lifeos://nutrition/log?method=manual&confidence=-0.3")!))
        XCTAssertEqual(router.pendingNavigation, .nutritionLog(method: .manual, aiConfidence: 0.0))

        XCTAssertTrue(router.handle(URL(string: "lifeos://food/log?confidence=abc")!))
        XCTAssertEqual(router.pendingNavigation, .nutritionLog(method: nil, aiConfidence: nil))

        XCTAssertTrue(router.handle(URL(string: "lifeos://food/2026-02-16")!))
        XCTAssertEqual(router.pendingNavigation, .nutrition(date: "2026-02-16"))
    }

    func testAdditionalFallbackAndAliasParsingBranches() {
        let router = DeepLinkRouter()

        XCTAssertTrue(router.handle(URL(string: "lifeos://home")!))
        XCTAssertEqual(router.pendingNavigation, .home)

        XCTAssertTrue(router.handle(URL(string: "lifeos://supplements/log?date=2026-02-16")!))
        XCTAssertEqual(router.pendingNavigation, .supplementsLog(date: "2026-02-16"))

        XCTAssertTrue(router.handle(URL(string: "lifeos://auth/not-callback")!))
        XCTAssertEqual(router.pendingNavigation, .home)

        XCTAssertTrue(router.handle(URL(string: "lifeos://experiments/not-a-uuid/path")!))
        XCTAssertEqual(router.pendingNavigation, .insights)

        XCTAssertTrue(router.handle(URL(string: "lifeos://recovery/not-a-date")!))
        XCTAssertEqual(router.pendingNavigation, .recoveryDetail(date: nil))

        XCTAssertTrue(router.handle(URL(string: "lifeos://cycle/2026-02-16")!))
        XCTAssertEqual(router.pendingNavigation, .menstrual(date: "2026-02-16"))
    }
}
