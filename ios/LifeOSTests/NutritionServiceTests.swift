import Foundation
import GRDB
import XCTest
@testable import LifeOS

private actor NutritionHistoryClientMock: NutritionHistoryAPIClient {
    struct Invocation: Sendable {
        let orderBy: String
        let ascending: Bool
        let limit: Int
        let offset: Int
        let exactMatch: [String: String]
    }

    private let response: [FoodLog]
    private var invocations: [Invocation] = []

    init(response: [FoodLog]) {
        self.response = response
    }

    func fetchHistoricalFoodLogs(
        orderBy: String,
        ascending: Bool,
        limit: Int,
        offset: Int,
        exactMatch: [String: String]
    ) async throws -> [FoodLog] {
        invocations.append(
            Invocation(
                orderBy: orderBy,
                ascending: ascending,
                limit: limit,
                offset: offset,
                exactMatch: exactMatch
            )
        )
        return response
    }

    func invocationCount() -> Int {
        invocations.count
    }

    func firstInvocation() -> Invocation? {
        invocations.first
    }
}

private actor NutritionMealDetailClientMock: NutritionMealDetailAPIClient {
    private let response: NutritionMealRemoteDetailResponse
    private(set) var requestedIds: [UUID] = []

    init(response: NutritionMealRemoteDetailResponse) {
        self.response = response
    }

    func fetchMealDetail(id: UUID) async throws -> NutritionMealRemoteDetailResponse {
        requestedIds.append(id)
        return response
    }

    func requestCount() -> Int {
        requestedIds.count
    }
}

private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?

    func set(_ request: URLRequest) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func snapshot() -> URLRequest? {
        lock.lock()
        let value = request
        lock.unlock()
        return value
    }
}

final class NutritionServiceTests: XCTestCase {

    private static func insertUser(_ db: Database, userId: UUID, authId: UUID = UUID()) throws {
        var user = User(id: userId, authId: authId, timezone: "UTC", units: .metric)
        user.weightKg = 72
        try user.insert(db)
    }

    private static func insertCatalogItem(
        _ db: Database,
        id: UUID = UUID(),
        provider: FoodProvider = .openFoodFacts,
        name: String,
        barcode: String
    ) throws -> UUID {
        var item = FoodCatalogItem(
            id: id,
            provider: provider,
            name: name,
            caloriesPer100g: 210,
            proteinPer100g: 11,
            fatPer100g: 7,
            carbsPer100g: 24
        )
        item.barcode = barcode
        item.brand = "Cache Brand"
        item.fiberPer100g = 5
        item.fetchedAt = Date()
        item.expiresAt = Date().addingTimeInterval(24 * 60 * 60)
        item.createdAt = Date()
        item.updatedAt = Date()
        try item.insert(db)
        return item.id
    }

    private static func insertUserFood(
        _ db: Database,
        id: UUID = UUID(),
        userId: UUID,
        name: String,
        barcode: String
    ) throws -> UUID {
        var item = UserFood(
            id: id,
            userId: userId,
            name: name,
            caloriesPer100g: 180,
            proteinPer100g: 9,
            fatPer100g: 4,
            carbsPer100g: 23
        )
        item.brand = "Home Kitchen"
        item.barcode = barcode
        item.defaultServingG = 120
        item.fiberPer100g = 7
        try item.insert(db)
        return item.id
    }

    private static func insertFavorite(
        _ db: Database,
        userId: UUID,
        refType: FoodRefType,
        refId: UUID
    ) throws {
        try UserFoodFavorite(userId: userId, refType: refType, refId: refId).insert(db)
    }

    private static func makeSearchResult(id: UUID, refType: FoodRefType) -> FoodSearchResult {
        FoodSearchResult(
            id: id,
            refType: refType,
            provider: refType == .catalog ? .openFoodFacts : nil,
            name: refType == .catalog ? "Catalog Meal" : "Custom Meal",
            brand: "LifeOS",
            barcode: "4600000000000",
            servingSizeG: 45,
            caloriesPer100g: 320,
            proteinPer100g: 18,
            fatPer100g: 9,
            carbsPer100g: 36,
            fiberPer100g: 6,
            tags: ["favorite"]
        )
    }

    private static func makeReviewDraft(
        barcode: String = " 460123 ",
        name: String = " Coverage Product ",
        brand: String = " Coverage Brand ",
        servingSizeG: Double = 55,
        caloriesPer100g: Double = 320,
        proteinPer100g: Double = 18,
        fatPer100g: Double = 9,
        carbsPer100g: Double = 34,
        fiberPer100g: Double = 5,
        confidence: Double? = 0.91,
        analysisSource: NutritionAnalysisSource = .aiVision
    ) -> NutritionLabelReviewDraft {
        NutritionLabelReviewDraft(
            barcode: barcode,
            name: name,
            brand: brand,
            servingSizeG: servingSizeG,
            caloriesPer100g: caloriesPer100g,
            proteinPer100g: proteinPer100g,
            fatPer100g: fatPer100g,
            carbsPer100g: carbsPer100g,
            fiberPer100g: fiberPer100g,
            confidence: confidence,
            analysisSource: analysisSource
        )
    }

    private static func insertMeal(
        _ db: Database,
        logId: UUID = UUID(),
        userId: UUID,
        loggedDate: String = "2026-03-12",
        inputMethod: NutritionInputMethod = .manual,
        calories: Double = 520,
        protein: Double = 32,
        fat: Double = 18,
        carbs: Double = 54
    ) throws -> FoodLog {
        var log = FoodLog(
            id: logId,
            userId: userId,
            loggedAt: Date(timeIntervalSince1970: 1_773_331_200),
            loggedDate: loggedDate,
            inputMethod: inputMethod,
            calories: calories,
            proteinG: protein,
            fatG: fat,
            carbsG: carbs
        )
        log.mealType = .lunch
        log.context = .home
        try log.insert(db)
        return log
    }

    private static func insertMealItem(
        _ db: Database,
        logId: UUID,
        userId: UUID,
        name: String = "Chicken bowl",
        calories: Double = 520,
        protein: Double = 32,
        fat: Double = 18,
        carbs: Double = 54
    ) throws -> FoodItem {
        var item = FoodItem(
            foodLogId: logId,
            userId: userId,
            name: name,
            weightG: 300,
            calories: calories,
            proteinG: protein,
            fatG: fat,
            carbsG: carbs
        )
        item.fiberG = 6
        try item.insert(db)
        return item
    }

    private static func insertMealTemplate(
        _ db: Database,
        templateId: UUID = UUID(),
        userId: UUID,
        name: String = "Protein breakfast",
        mealType: MealType? = .breakfast,
        archived: Bool = false,
        timesUsed: Int = 2,
        items: [NutritionMealTemplateItem]? = nil
    ) throws -> MealTemplate {
        let templateItems = items ?? [
            NutritionMealTemplateItem(
                name: "Greek yogurt",
                brand: "LifeOS",
                barcode: "460123",
                weightG: 180,
                calories: 190,
                proteinG: 17,
                fatG: 5,
                carbsG: 14,
                fiberG: 0
            ),
            NutritionMealTemplateItem(
                name: "Granola",
                brand: "LifeOS",
                barcode: "460456",
                weightG: 60,
                calories: 240,
                proteinG: 6,
                fatG: 8,
                carbsG: 34,
                fiberG: 4
            )
        ]
        let totals = (
            calories: templateItems.reduce(0) { $0 + $1.calories },
            protein: templateItems.reduce(0) { $0 + $1.proteinG },
            fat: templateItems.reduce(0) { $0 + $1.fatG },
            carbs: templateItems.reduce(0) { $0 + $1.carbsG },
            fiber: templateItems.reduce(0) { $0 + ($1.fiberG ?? 0) }
        )

        var template = MealTemplate(
            id: templateId,
            userId: userId,
            name: name,
            templateItems: try JSONEncoder.supabase.encode(templateItems),
            calories: totals.calories,
            proteinG: totals.protein,
            fatG: totals.fat,
            carbsG: totals.carbs
        )
        template.mealType = mealType
        template.fiberG = totals.fiber > 0 ? totals.fiber : nil
        template.archived = archived
        template.timesUsed = timesUsed
        template.lastUsedAt = Date(timeIntervalSince1970: 1_773_420_000)
        template.updatedAt = Date(timeIntervalSince1970: 1_773_420_100)
        try template.insert(db)
        return template
    }

    func testLogMealPersistsFoodLogAndOutboxEvent() async throws {
        let manager = try DatabaseManager.inMemory()
        let service = NutritionService(dbQueue: manager.dbQueue)
        let userId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId)
        }

        let log = FoodLog(
            userId: userId,
            loggedDate: "2026-02-24",
            inputMethod: .manual,
            calories: 600,
            proteinG: 35,
            fatG: 20,
            carbsG: 70
        )

        try await service.logMeal(log)

        try await manager.dbQueue.read { db in
            XCTAssertEqual(try FoodLog.fetchCount(db), 1)
            XCTAssertEqual(try OutboxEvent.fetchCount(db), 1)

            let event = try OutboxEvent.fetchOne(
                db,
                sql: """
                    SELECT *
                    FROM outbox_events
                    WHERE id = ? OR id = ?
                    LIMIT 1
                    """,
                arguments: [log.id, log.id.uuidString]
            )
            XCTAssertEqual(event?.path, "api-food-log")
            XCTAssertEqual(event?.priority, 100)

            let headersData = try XCTUnwrap(event?.headersJson)
            let headers = try XCTUnwrap(
                JSONSerialization.jsonObject(with: headersData) as? [String: String]
            )
            XCTAssertEqual(headers["Content-Type"], "application/json")
        }
    }

    func testFetchHistoricalFoodLogsForRecentDateUsesLocalDatabaseOnly() async throws {
        let manager = try DatabaseManager.inMemory()
        let service = NutritionService(dbQueue: manager.dbQueue)
        let userId = UUID()
        let targetDate = Date()
        let targetDateStr = DateFormatting.dateOnlyString(from: targetDate)

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId)

            let early = FoodLog(
                userId: userId,
                loggedAt: targetDate.addingTimeInterval(100),
                loggedDate: targetDateStr,
                inputMethod: .manual,
                calories: 350,
                proteinG: 20,
                fatG: 10,
                carbsG: 40
            )
            let late = FoodLog(
                userId: userId,
                loggedAt: targetDate.addingTimeInterval(500),
                loggedDate: targetDateStr,
                inputMethod: .manual,
                calories: 450,
                proteinG: 25,
                fatG: 15,
                carbsG: 50
            )
            let otherDay = FoodLog(
                userId: userId,
                loggedAt: targetDate.addingTimeInterval(1_000),
                loggedDate: "2026-01-01",
                inputMethod: .manual,
                calories: 300,
                proteinG: 15,
                fatG: 10,
                carbsG: 35
            )
            try early.insert(db)
            try late.insert(db)
            try otherDay.insert(db)
        }

        let mock = NutritionHistoryClientMock(response: [])
        let logs = try await service.fetchHistoricalFoodLogs(for: targetDate, apiClient: mock)

        XCTAssertEqual(logs.count, 2)
        XCTAssertEqual(logs[0].calories, 350)
        XCTAssertEqual(logs[1].calories, 450)
        let callCount = await mock.invocationCount()
        XCTAssertEqual(callCount, 0)
    }

    func testFetchHistoricalFoodLogsForOldDateCallsApiAndCachesLocally() async throws {
        let manager = try DatabaseManager.inMemory()
        let service = NutritionService(dbQueue: manager.dbQueue)
        let userId = UUID()
        let oldDate = Calendar.current.date(byAdding: .day, value: -120, to: Date()) ?? Date()
        let oldDateStr = DateFormatting.dateOnlyString(from: oldDate)

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId)
        }

        let remoteLogs = [
            FoodLog(
                userId: userId,
                loggedAt: oldDate.addingTimeInterval(10),
                loggedDate: oldDateStr,
                inputMethod: .manual,
                calories: 420,
                proteinG: 24,
                fatG: 14,
                carbsG: 48
            ),
            FoodLog(
                userId: userId,
                loggedAt: oldDate.addingTimeInterval(20),
                loggedDate: oldDateStr,
                inputMethod: .manual,
                calories: 520,
                proteinG: 30,
                fatG: 18,
                carbsG: 60
            )
        ]
        let mock = NutritionHistoryClientMock(response: remoteLogs)

        let logs = try await service.fetchHistoricalFoodLogs(for: oldDate, apiClient: mock)

        XCTAssertEqual(logs.map(\.id), remoteLogs.map(\.id))

        let callCount = await mock.invocationCount()
        XCTAssertEqual(callCount, 1)
        let firstInvocation = await mock.firstInvocation()
        let invocation = try XCTUnwrap(firstInvocation)
        XCTAssertEqual(invocation.orderBy, "logged_at")
        XCTAssertTrue(invocation.ascending)
        XCTAssertEqual(invocation.limit, 1000)
        XCTAssertEqual(invocation.offset, 0)
        XCTAssertEqual(invocation.exactMatch["logged_date"], oldDateStr)

        let cachedCount = try await manager.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM food_logs WHERE logged_date = ?",
                arguments: [oldDateStr]
            ) ?? 0
        }
        XCTAssertEqual(cachedCount, 2)
    }

    func testNutritionCatalogServiceSearchUsesEdgeRouteAndCachesRemoteFoods() async throws {
        final class RequestCapture: @unchecked Sendable {
            private let lock = NSLock()
            private var request: URLRequest?

            func set(_ request: URLRequest) {
                lock.lock()
                self.request = request
                lock.unlock()
            }

            func snapshot() -> URLRequest? {
                lock.lock()
                let value = request
                lock.unlock()
                return value
            }
        }

        let manager = try DatabaseManager.inMemory()
        let api = APIClient(deviceId: "nutrition-catalog-search")
        let service = NutritionCatalogService(dbQueue: manager.dbQueue, apiClient: api)
        let authId = UUID()
        let userId = UUID()
        let customId = UUID()
        let catalogId = UUID()
        let capture = RequestCapture()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
        }

        APIClient._testResetOverrides()
        defer {
            APIClient._testResetOverrides()
            Task { await RateLimitTracker.shared.reset() }
            Task { @MainActor in AuthManager.setActiveAuthIdForTests(nil) }
        }

        await RateLimitTracker.shared.reset()
        await MainActor.run { AuthManager.setActiveAuthIdForTests(authId) }
        APIClient._testSetPostgrestAccessTokenOverride("nutrition-token")

        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://example.com/functions/v1/api-foods/search")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )
        let body = """
        {
          "query": "oat",
          "limit": 20,
          "results": [
            {
              "type": "custom",
              "id": "\(customId.uuidString)",
              "name": "Homemade Oats",
              "brand": "Kitchen",
              "barcode": "111",
              "serving_size_g": 40,
              "macros_per_100g": {
                "calories": 380,
                "protein_g": 13,
                "fat_g": 7,
                "carbs_g": 67,
                "fiber_g": 10
              },
              "tags": ["recent"]
            },
            {
              "type": "catalog",
              "id": "\(catalogId.uuidString)",
              "provider": "open_food_facts",
              "name": "Oat Bar",
              "brand": "OFF",
              "barcode": "222",
              "serving_size_g": 35,
              "macros_per_100g": {
                "calories": 420,
                "protein_g": 11,
                "fat_g": 14,
                "carbs_g": 62,
                "fiber_g": 8
              },
              "tags": ["favorite"]
            }
          ]
        }
        """

        APIClient._testSetEdgeRouteDataForRequestOverride { request in
            capture.set(request)
            return (Data(body.utf8), response)
        }

        let results = try await service.searchFoods(query: "oat")

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].refType, .custom)
        XCTAssertEqual(results[1].refType, .catalog)
        XCTAssertEqual(results[1].provider, .openFoodFacts)

        let request = try XCTUnwrap(capture.snapshot())
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer nutrition-token")
        XCTAssertTrue(request.url?.path.contains("/functions/v1/api-foods/search") == true)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "q" })?.value, "oat")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "limit" })?.value, "20")

        try await manager.dbQueue.read { db in
            let cachedCustom = try XCTUnwrap(
                Row.fetchOne(
                    db,
                    sql: """
                        SELECT name
                        FROM user_foods
                        WHERE id = ? OR id = ?
                        LIMIT 1
                        """,
                    arguments: [customId, customId.uuidString]
                )
            )
            XCTAssertEqual(cachedCustom["name"] as String?, "Homemade Oats")

            let cachedCatalog = try XCTUnwrap(
                Row.fetchOne(
                    db,
                    sql: """
                        SELECT name, provider
                        FROM food_catalog_items
                        WHERE id = ? OR id = ?
                        LIMIT 1
                        """,
                    arguments: [catalogId, catalogId.uuidString]
                )
            )
            XCTAssertEqual(cachedCatalog["name"] as String?, "Oat Bar")
            XCTAssertEqual(cachedCatalog["provider"] as String?, FoodProvider.openFoodFacts.rawValue)
        }
    }

    func testNutritionCatalogServiceSearchFallsBackToLocalCacheWhenEdgeRouteFails() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = APIClient(deviceId: "nutrition-catalog-search-fallback")
        let service = NutritionCatalogService(dbQueue: manager.dbQueue, apiClient: api)
        let authId = UUID()
        let userId = UUID()
        let cachedCatalogId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            _ = try Self.insertCatalogItem(db, id: cachedCatalogId, name: "Banana Bread", barcode: "333")
        }

        APIClient._testResetOverrides()
        defer {
            APIClient._testResetOverrides()
            Task { await RateLimitTracker.shared.reset() }
            Task { @MainActor in AuthManager.setActiveAuthIdForTests(nil) }
        }

        await RateLimitTracker.shared.reset()
        await MainActor.run { AuthManager.setActiveAuthIdForTests(authId) }
        APIClient._testSetPostgrestAccessTokenOverride("nutrition-token")
        APIClient._testSetEdgeRouteDataForRequestOverride { _ in
            throw NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue)
        }

        let results = try await service.searchFoods(query: "Banana")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, cachedCatalogId)
        XCTAssertEqual(results.first?.refType, .catalog)
    }

    func testNutritionCatalogServiceSearchReturnsEmptyResultsForBlankQuery() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = APIClient(deviceId: "nutrition-catalog-search-blank")
        let service = NutritionCatalogService(dbQueue: manager.dbQueue, apiClient: api)
        let capture = RequestCapture()

        APIClient._testResetOverrides()
        defer { APIClient._testResetOverrides() }

        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/functions/v1/api-foods/search")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        APIClient._testSetEdgeRouteDataForRequestOverride { request in
            capture.set(request)
            return (Data(#"{"query":"","limit":20,"results":[]}"#.utf8), response)
        }

        let results = try await service.searchFoods(query: "   \n ")

        XCTAssertTrue(results.isEmpty)
        XCTAssertNil(capture.snapshot())
    }

    func testNutritionCatalogServiceSearchThrowsOriginalErrorWhenFallbackCacheIsEmpty() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = APIClient(deviceId: "nutrition-catalog-search-throw")
        let service = NutritionCatalogService(dbQueue: manager.dbQueue, apiClient: api)
        let expectedError = NSError(domain: "NutritionCoverage", code: 404)

        APIClient._testResetOverrides()
        defer {
            APIClient._testResetOverrides()
            Task { await RateLimitTracker.shared.reset() }
            Task { @MainActor in AuthManager.setActiveAuthIdForTests(nil) }
        }

        await RateLimitTracker.shared.reset()
        APIClient._testSetPostgrestAccessTokenOverride("nutrition-token")
        APIClient._testSetEdgeRouteDataForRequestOverride { _ in
            throw expectedError
        }

        do {
            _ = try await service.searchFoods(query: "No Coverage Match")
            XCTFail("Expected fallback search to rethrow the original error")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, expectedError.domain)
            XCTAssertEqual(error.code, expectedError.code)
        }
    }

    func testNutritionCatalogServiceLocalFallbackRanksFavoriteRecentCustomAndCacheResults() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = APIClient(deviceId: "nutrition-catalog-local-ranking")
        let service = NutritionCatalogService(dbQueue: manager.dbQueue, apiClient: api)
        let authId = UUID()
        let userId = UUID()
        let favoriteCatalogId = UUID()
        let recentCatalogId = UUID()
        let customFoodId = UUID()
        let plainCatalogId = UUID()
        let mealId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            _ = try Self.insertCatalogItem(db, id: favoriteCatalogId, name: "Bread Favorite", barcode: "111")
            _ = try Self.insertCatalogItem(db, id: recentCatalogId, name: "Bread Recent", barcode: "222")
            _ = try Self.insertCatalogItem(db, id: plainCatalogId, name: "Bread Plain", barcode: "333")
            _ = try Self.insertUserFood(db, id: customFoodId, userId: userId, name: "Bread Custom", barcode: "444")
            try Self.insertFavorite(db, userId: userId, refType: .catalog, refId: favoriteCatalogId)

            _ = try Self.insertMeal(db, logId: mealId, userId: userId)
            var recentItem = FoodItem(
                foodLogId: mealId,
                userId: userId,
                name: "Bread Recent Portion",
                weightG: 100,
                calories: 220,
                proteinG: 10,
                fatG: 7,
                carbsG: 28
            )
            recentItem.catalogItemId = recentCatalogId
            try recentItem.insert(db)
        }

        APIClient._testResetOverrides()
        defer {
            APIClient._testResetOverrides()
            Task { await RateLimitTracker.shared.reset() }
            Task { @MainActor in AuthManager.setActiveAuthIdForTests(nil) }
        }

        await RateLimitTracker.shared.reset()
        await MainActor.run { AuthManager.setActiveAuthIdForTests(authId) }
        APIClient._testSetPostgrestAccessTokenOverride("nutrition-token")
        APIClient._testSetEdgeRouteDataForRequestOverride { _ in
            throw NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue)
        }

        let results = try await service.searchFoods(query: "Bread", limit: 10)

        XCTAssertEqual(results.map(\.id), [favoriteCatalogId, recentCatalogId, customFoodId, plainCatalogId])
        XCTAssertEqual(results.map(\.refType), [.catalog, .catalog, .custom, .catalog])
        XCTAssertEqual(Set(results[0].tags), ["favorite"])
        XCTAssertEqual(Set(results[1].tags), ["recent"])
        XCTAssertTrue(results[2].tags.isEmpty)
        XCTAssertTrue(results[3].tags.isEmpty)
    }

    func testNutritionCatalogServiceStaticSearchHelpersCoverRemainingBranches() throws {
        let favoriteId = UUID()
        let recentId = UUID()
        let customId = UUID()
        let cacheId = UUID()
        let providerId = UUID()
        let favoriteKey = "catalog:\(favoriteId.uuidString)"
        let recentKey = "catalog:\(recentId.uuidString)"

        let favoriteKeys = NutritionCatalogService._testFavoriteKeys(
            values: [
                ["ref_type": "catalog", "ref_id": favoriteId.uuidString],
                ["ref_type": "catalog"],
                ["ref_id": recentId.uuidString]
            ]
        )
        XCTAssertEqual(favoriteKeys, [favoriteKey])

        let recentKeys = NutritionCatalogService._testRecentKeys(
            values: [
                ["user_food_id": customId.uuidString],
                ["catalog_item_id": recentId.uuidString],
                ["user_food_id": customId.uuidString, "catalog_item_id": recentId.uuidString],
                [:]
            ]
        )
        XCTAssertEqual(recentKeys, ["custom:\(customId.uuidString)", recentKey])

        let favoriteResult = FoodSearchResult(
            id: favoriteId,
            refType: .catalog,
            provider: .openFoodFacts,
            name: "bread",
            brand: "Bread House",
            barcode: "bread",
            servingSizeG: nil,
            caloriesPer100g: 0,
            proteinPer100g: 0,
            fatPer100g: 0,
            carbsPer100g: 0,
            fiberPer100g: nil,
            tags: []
        )
        XCTAssertEqual(
            NutritionCatalogService._testScore(
                result: favoriteResult,
                query: "bread",
                sourceIsProvider: false,
                favorites: [favoriteKey],
                recent: []
            ),
            -105
        )

        let recentResult = FoodSearchResult(
            id: recentId,
            refType: .catalog,
            provider: .openFoodFacts,
            name: "Recent Option",
            brand: nil,
            barcode: nil,
            servingSizeG: nil,
            caloriesPer100g: 0,
            proteinPer100g: 0,
            fatPer100g: 0,
            carbsPer100g: 0,
            fiberPer100g: nil,
            tags: []
        )
        XCTAssertEqual(
            NutritionCatalogService._testScore(
                result: recentResult,
                query: "bread",
                sourceIsProvider: false,
                favorites: [],
                recent: [recentKey]
            ),
            100
        )

        let customResult = FoodSearchResult(
            id: customId,
            refType: .custom,
            provider: nil,
            name: "Bread pudding",
            brand: nil,
            barcode: nil,
            servingSizeG: nil,
            caloriesPer100g: 0,
            proteinPer100g: 0,
            fatPer100g: 0,
            carbsPer100g: 0,
            fiberPer100g: nil,
            tags: []
        )
        XCTAssertEqual(
            NutritionCatalogService._testScore(
                result: customResult,
                query: "bread",
                sourceIsProvider: false,
                favorites: [],
                recent: []
            ),
            170
        )

        let cacheResult = FoodSearchResult(
            id: cacheId,
            refType: .catalog,
            provider: .openFoodFacts,
            name: "Plain Bread",
            brand: nil,
            barcode: nil,
            servingSizeG: nil,
            caloriesPer100g: 0,
            proteinPer100g: 0,
            fatPer100g: 0,
            carbsPer100g: 0,
            fiberPer100g: nil,
            tags: []
        )
        XCTAssertEqual(
            NutritionCatalogService._testScore(
                result: cacheResult,
                query: "bread",
                sourceIsProvider: false,
                favorites: [],
                recent: []
            ),
            290
        )

        let providerResult = FoodSearchResult(
            id: providerId,
            refType: .catalog,
            provider: .openFoodFacts,
            name: "Provider Option",
            brand: "Bread House",
            barcode: nil,
            servingSizeG: nil,
            caloriesPer100g: 0,
            proteinPer100g: 0,
            fatPer100g: 0,
            carbsPer100g: 0,
            fiberPer100g: nil,
            tags: []
        )
        XCTAssertEqual(
            NutritionCatalogService._testScore(
                result: providerResult,
                query: "bread",
                sourceIsProvider: true,
                favorites: [],
                recent: []
            ),
            395
        )

        let uniqueResults = NutritionCatalogService._testUniqueSortedResults(
            resultsWithScores: [
                (
                    result: FoodSearchResult(
                        id: favoriteId,
                        refType: .catalog,
                        provider: .openFoodFacts,
                        name: "Zulu",
                        brand: nil,
                        barcode: nil,
                        servingSizeG: nil,
                        caloriesPer100g: 0,
                        proteinPer100g: 0,
                        fatPer100g: 0,
                        carbsPer100g: 0,
                        fiberPer100g: nil,
                        tags: []
                    ),
                    score: 10
                ),
                (
                    result: FoodSearchResult(
                        id: recentId,
                        refType: .catalog,
                        provider: .openFoodFacts,
                        name: "Alpha",
                        brand: nil,
                        barcode: nil,
                        servingSizeG: nil,
                        caloriesPer100g: 0,
                        proteinPer100g: 0,
                        fatPer100g: 0,
                        carbsPer100g: 0,
                        fiberPer100g: nil,
                        tags: []
                    ),
                    score: 10
                ),
                (
                    result: FoodSearchResult(
                        id: favoriteId,
                        refType: .catalog,
                        provider: .openFoodFacts,
                        name: "Zulu Duplicate",
                        brand: nil,
                        barcode: nil,
                        servingSizeG: nil,
                        caloriesPer100g: 0,
                        proteinPer100g: 0,
                        fatPer100g: 0,
                        carbsPer100g: 0,
                        fiberPer100g: nil,
                        tags: []
                    ),
                    score: 5
                ),
                (
                    result: FoodSearchResult(
                        id: cacheId,
                        refType: .catalog,
                        provider: .openFoodFacts,
                        name: "Beta",
                        brand: nil,
                        barcode: nil,
                        servingSizeG: nil,
                        caloriesPer100g: 0,
                        proteinPer100g: 0,
                        fatPer100g: 0,
                        carbsPer100g: 0,
                        fiberPer100g: nil,
                        tags: []
                    ),
                    score: 15
                )
            ],
            limit: 2
        )
        XCTAssertEqual(uniqueResults.map(\.id), [favoriteId, recentId])

        XCTAssertNil(
            NutritionCatalogService._testMakeCustomResult(
                values: ["id": customId.uuidString]
            )
        )
        let mappedCustom = try XCTUnwrap(
            NutritionCatalogService._testMakeCustomResult(
                values: [
                    "id": customId.uuidString,
                    "name": "Helper Custom"
                ],
                tags: ["recent"]
            )
        )
        XCTAssertEqual(mappedCustom.id, customId)
        XCTAssertEqual(mappedCustom.refType, .custom)
        XCTAssertEqual(mappedCustom.caloriesPer100g, 0)
        XCTAssertEqual(mappedCustom.proteinPer100g, 0)
        XCTAssertEqual(mappedCustom.fatPer100g, 0)
        XCTAssertEqual(mappedCustom.carbsPer100g, 0)
        XCTAssertNil(mappedCustom.fiberPer100g)
        XCTAssertEqual(mappedCustom.tags, ["recent"])

        XCTAssertNil(
            NutritionCatalogService._testMakeCatalogResult(
                values: ["id": cacheId.uuidString]
            )
        )
        let mappedCatalog = try XCTUnwrap(
            NutritionCatalogService._testMakeCatalogResult(
                values: [
                    "id": cacheId.uuidString,
                    "name": "Helper Catalog",
                    "provider": "unknown-provider"
                ],
                tags: ["favorite"]
            )
        )
        XCTAssertEqual(mappedCatalog.id, cacheId)
        XCTAssertEqual(mappedCatalog.refType, .catalog)
        XCTAssertEqual(mappedCatalog.provider, .other)
        XCTAssertEqual(mappedCatalog.caloriesPer100g, 0)
        XCTAssertEqual(mappedCatalog.proteinPer100g, 0)
        XCTAssertEqual(mappedCatalog.fatPer100g, 0)
        XCTAssertEqual(mappedCatalog.carbsPer100g, 0)
        XCTAssertNil(mappedCatalog.fiberPer100g)
        XCTAssertEqual(mappedCatalog.tags, ["favorite"])

        let defaultProviderCatalog = try XCTUnwrap(
            NutritionCatalogService._testMakeCatalogResult(
                values: [
                    "id": UUID().uuidString,
                    "name": "Default Provider Catalog"
                ]
            )
        )
        XCTAssertEqual(defaultProviderCatalog.provider, .other)
    }

    func testNutritionCatalogServiceStaticDatabaseHelpersCoverWrapperBranches() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let catalogId = UUID()
        let customId = UUID()
        let mealId = UUID()
        let loggedAt = Date(timeIntervalSince1970: 1_710_000_000)

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            try Self.insertFavorite(db, userId: userId, refType: .catalog, refId: catalogId)

            var meal = FoodLog(
                id: mealId,
                userId: userId,
                loggedAt: loggedAt,
                loggedDate: "2026-03-18",
                inputMethod: .manual,
                calories: 420,
                proteinG: 22,
                fatG: 16,
                carbsG: 41
            )
            meal.createdAt = loggedAt
            meal.updatedAt = loggedAt
            try meal.insert(db)

            var item = FoodItem(
                foodLogId: mealId,
                userId: userId,
                name: "Coverage Meal",
                weightG: 120,
                calories: 240,
                proteinG: 14,
                fatG: 9,
                carbsG: 25
            )
            item.catalogItemId = catalogId
            item.userFoodId = customId
            item.createdAt = loggedAt
            item.updatedAt = loggedAt
            try item.insert(db)
        }

        try await manager.dbQueue.read { db in
            XCTAssertEqual(try NutritionCatalogService._testLoadFavoriteKeys(userId: nil, db: db), [])
            XCTAssertEqual(try NutritionCatalogService._testLoadRecentKeys(userId: nil, db: db), [])
            XCTAssertEqual(
                try NutritionCatalogService._testLoadFavoriteKeys(userId: userId, db: db),
                ["catalog:\(catalogId.uuidString)"]
            )
            XCTAssertEqual(
                try NutritionCatalogService._testLoadRecentKeys(userId: userId, db: db),
                ["catalog:\(catalogId.uuidString)", "custom:\(customId.uuidString)"]
            )
        }

        XCTAssertEqual(
            NutritionCatalogService._testTags(
                favorites: ["catalog:\(catalogId.uuidString)"],
                recent: ["catalog:\(catalogId.uuidString)"],
                refType: .catalog,
                id: catalogId
            ),
            ["favorite", "recent"]
        )
        XCTAssertEqual(
            NutritionCatalogService._testTags(
                favorites: [],
                recent: [],
                refType: .catalog,
                id: nil
            ),
            []
        )
    }

    func testNutritionCatalogServiceBarcodeUsesEdgeRouteAndCachesResult() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = APIClient(deviceId: "nutrition-catalog-barcode")
        let service = NutritionCatalogService(dbQueue: manager.dbQueue, apiClient: api)
        let authId = UUID()
        let userId = UUID()
        let catalogId = UUID()
        let capture = RequestCapture()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
        }

        APIClient._testResetOverrides()
        defer {
            APIClient._testResetOverrides()
            Task { await RateLimitTracker.shared.reset() }
            Task { @MainActor in AuthManager.setActiveAuthIdForTests(nil) }
        }

        await RateLimitTracker.shared.reset()
        await MainActor.run { AuthManager.setActiveAuthIdForTests(authId) }
        APIClient._testSetPostgrestAccessTokenOverride("nutrition-token")

        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://example.com/functions/v1/api-foods/barcode/460123")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )
        let body = """
        {
          "type": "catalog",
          "id": "\(catalogId.uuidString)",
          "provider": "open_food_facts",
          "name": "Greek Yogurt",
          "brand": "Acme",
          "barcode": "460123",
          "serving_size_g": 150,
          "macros_per_100g": {
            "calories": 98,
            "protein_g": 9.5,
            "fat_g": 3.1,
            "carbs_g": 4.8,
            "fiber_g": 0
          },
          "tags": ["favorite"],
          "fetched_at": "2026-03-08T10:00:00Z",
          "expires_at": "2026-04-07T10:00:00Z"
        }
        """

        APIClient._testSetEdgeRouteDataForRequestOverride { request in
            capture.set(request)
            return (Data(body.utf8), response)
        }

        let result = try await service.lookupBarcode("460123")

        XCTAssertEqual(result?.id, catalogId)
        XCTAssertEqual(result?.provider, .openFoodFacts)
        XCTAssertEqual(result?.barcode, "460123")

        let request = try XCTUnwrap(capture.snapshot())
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer nutrition-token")
        XCTAssertTrue(request.url?.path.contains("/functions/v1/api-foods/barcode/460123") == true)

        try await manager.dbQueue.read { db in
            let cachedCatalog = try XCTUnwrap(
                Row.fetchOne(
                    db,
                    sql: """
                        SELECT barcode, provider
                        FROM food_catalog_items
                        WHERE id = ? OR id = ?
                        LIMIT 1
                        """,
                    arguments: [catalogId, catalogId.uuidString]
                )
            )
            XCTAssertEqual(cachedCatalog["barcode"] as String?, "460123")
            XCTAssertEqual(cachedCatalog["provider"] as String?, FoodProvider.openFoodFacts.rawValue)
        }
    }

    func testNutritionCatalogServiceBarcodeFallsBackToLocalCacheWhenEdgeRouteFails() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = APIClient(deviceId: "nutrition-catalog-barcode-fallback")
        let service = NutritionCatalogService(dbQueue: manager.dbQueue, apiClient: api)
        let authId = UUID()
        let userId = UUID()
        let cachedCatalogId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            _ = try Self.insertCatalogItem(db, id: cachedCatalogId, name: "Trail Mix", barcode: "999")
        }

        APIClient._testResetOverrides()
        defer {
            APIClient._testResetOverrides()
            Task { await RateLimitTracker.shared.reset() }
            Task { @MainActor in AuthManager.setActiveAuthIdForTests(nil) }
        }

        await RateLimitTracker.shared.reset()
        await MainActor.run { AuthManager.setActiveAuthIdForTests(authId) }
        APIClient._testSetPostgrestAccessTokenOverride("nutrition-token")
        APIClient._testSetEdgeRouteDataForRequestOverride { _ in
            throw NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue)
        }

        let result = try await service.lookupBarcode("999")

        XCTAssertEqual(result?.id, cachedCatalogId)
        XCTAssertEqual(result?.refType, .catalog)
    }

    func testNutritionCatalogServiceBarcodeReturnsNilForBlankInputWithoutCallingAPI() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = APIClient(deviceId: "nutrition-catalog-barcode-blank")
        let service = NutritionCatalogService(dbQueue: manager.dbQueue, apiClient: api)
        let capture = RequestCapture()

        APIClient._testResetOverrides()
        defer { APIClient._testResetOverrides() }

        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/functions/v1/api-foods/barcode/blank")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        APIClient._testSetEdgeRouteDataForRequestOverride { request in
            capture.set(request)
            return (Data("{}".utf8), response)
        }

        let result = try await service.lookupBarcode("   ")

        XCTAssertNil(result)
        XCTAssertNil(capture.snapshot())
    }

    func testNutritionCatalogServiceBarcodeFallsBackToCustomFoodWhenPresent() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = APIClient(deviceId: "nutrition-catalog-barcode-custom")
        let service = NutritionCatalogService(dbQueue: manager.dbQueue, apiClient: api)
        let authId = UUID()
        let userId = UUID()
        let customFoodId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            _ = try Self.insertUserFood(db, id: customFoodId, userId: userId, name: "Custom Cereal", barcode: "777")
        }

        APIClient._testResetOverrides()
        defer {
            APIClient._testResetOverrides()
            Task { await RateLimitTracker.shared.reset() }
            Task { @MainActor in AuthManager.setActiveAuthIdForTests(nil) }
        }

        await RateLimitTracker.shared.reset()
        await MainActor.run { AuthManager.setActiveAuthIdForTests(authId) }
        APIClient._testSetPostgrestAccessTokenOverride("nutrition-token")
        APIClient._testSetEdgeRouteDataForRequestOverride { _ in
            throw NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue)
        }

        let result = try await service.lookupBarcode("777")

        XCTAssertEqual(result?.id, customFoodId)
        XCTAssertEqual(result?.refType, .custom)
        XCTAssertEqual(Set(result?.tags ?? []), ["user_override"])
    }

    func testNutritionCatalogServiceBarcodeFallsBackToLifeOSLabelCatalogWhenOpenFoodFactsExpired() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = APIClient(deviceId: "nutrition-catalog-barcode-label")
        let service = NutritionCatalogService(dbQueue: manager.dbQueue, apiClient: api)
        let authId = UUID()
        let userId = UUID()
        let expiredCatalogId = UUID()
        let labelCatalogId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            _ = try Self.insertCatalogItem(
                db,
                id: expiredCatalogId,
                provider: .openFoodFacts,
                name: "Expired OFF Product",
                barcode: "888"
            )
            _ = try Self.insertCatalogItem(
                db,
                id: labelCatalogId,
                provider: .lifeosLabelOcr,
                name: "OCR Product",
                barcode: "888"
            )
            try db.execute(
                sql: """
                    UPDATE food_catalog_items
                    SET expires_at = ?
                    WHERE id = ? OR id = ?
                    """,
                arguments: [Date(timeIntervalSince1970: 0), expiredCatalogId, expiredCatalogId.uuidString]
            )
        }

        APIClient._testResetOverrides()
        defer {
            APIClient._testResetOverrides()
            Task { await RateLimitTracker.shared.reset() }
            Task { @MainActor in AuthManager.setActiveAuthIdForTests(nil) }
        }

        await RateLimitTracker.shared.reset()
        await MainActor.run { AuthManager.setActiveAuthIdForTests(authId) }
        APIClient._testSetPostgrestAccessTokenOverride("nutrition-token")
        APIClient._testSetEdgeRouteDataForRequestOverride { _ in
            throw NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue)
        }

        let result = try await service.lookupBarcode("888")

        XCTAssertEqual(result?.id, labelCatalogId)
        XCTAssertEqual(result?.provider, .lifeosLabelOcr)
        XCTAssertEqual(result?.refType, .catalog)
    }

    func testNutritionCatalogServiceBarcodeFallsBackToGenericCatalogProviderWhenSpecificProvidersMiss() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = APIClient(deviceId: "nutrition-catalog-barcode-generic")
        let service = NutritionCatalogService(dbQueue: manager.dbQueue, apiClient: api)
        let authId = UUID()
        let userId = UUID()
        let genericCatalogId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            _ = try Self.insertCatalogItem(
                db,
                id: genericCatalogId,
                provider: .other,
                name: "Generic Cache Product",
                barcode: "555"
            )
        }

        APIClient._testResetOverrides()
        defer {
            APIClient._testResetOverrides()
            Task { await RateLimitTracker.shared.reset() }
            Task { @MainActor in AuthManager.setActiveAuthIdForTests(nil) }
        }

        await RateLimitTracker.shared.reset()
        await MainActor.run { AuthManager.setActiveAuthIdForTests(authId) }
        APIClient._testSetPostgrestAccessTokenOverride("nutrition-token")
        APIClient._testSetEdgeRouteDataForRequestOverride { _ in
            throw NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue)
        }

        let result = try await service.lookupBarcode("555")

        XCTAssertEqual(result?.id, genericCatalogId)
        XCTAssertEqual(result?.provider, .other)
        XCTAssertEqual(result?.refType, .catalog)
    }

    func testNutritionCatalogServiceBarcodeReturnsNilWhenRemoteAndLocalLookupMiss() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = APIClient(deviceId: "nutrition-catalog-barcode-nil")
        let service = NutritionCatalogService(dbQueue: manager.dbQueue, apiClient: api)

        APIClient._testResetOverrides()
        defer {
            APIClient._testResetOverrides()
            Task { await RateLimitTracker.shared.reset() }
            Task { @MainActor in AuthManager.setActiveAuthIdForTests(nil) }
        }

        await RateLimitTracker.shared.reset()
        APIClient._testSetPostgrestAccessTokenOverride("nutrition-token")
        APIClient._testSetEdgeRouteDataForRequestOverride { _ in
            throw NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue)
        }

        let result = try await service.lookupBarcode("000")

        XCTAssertNil(result)
    }

    func testNutritionCatalogServiceCreateReviewedFoodCreatesBarcodeCatalogItemAndCachesIt() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = APIClient(deviceId: "nutrition-catalog-create-barcode")
        let service = NutritionCatalogService(dbQueue: manager.dbQueue, apiClient: api)
        let authId = UUID()
        let userId = UUID()
        let catalogId = UUID()
        let capture = RequestCapture()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
        }

        APIClient._testResetOverrides()
        defer {
            APIClient._testResetOverrides()
            Task { await RateLimitTracker.shared.reset() }
            Task { @MainActor in AuthManager.setActiveAuthIdForTests(nil) }
        }

        await RateLimitTracker.shared.reset()
        await MainActor.run { AuthManager.setActiveAuthIdForTests(authId) }
        APIClient._testSetPostgrestAccessTokenOverride("nutrition-token")

        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/functions/v1/api-foods/barcode/460123/create")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let body = """
        {
          "provider": "lifeos_label_ocr",
          "id": "\(catalogId.uuidString)",
          "barcode": "460123"
        }
        """
        APIClient._testSetEdgeRouteDataForRequestOverride { request in
            capture.set(request)
            return (Data(body.utf8), response)
        }

        let review = Self.makeReviewDraft()
        let result = try await service.createReviewedFood(review: review)

        XCTAssertEqual(result.id, catalogId)
        XCTAssertEqual(result.refType, .catalog)
        XCTAssertEqual(result.provider, .lifeosLabelOcr)
        XCTAssertEqual(result.name, "Coverage Product")
        XCTAssertEqual(result.brand, "Coverage Brand")
        XCTAssertEqual(result.barcode, "460123")

        let request = try XCTUnwrap(capture.snapshot())
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.url?.path.contains("/functions/v1/api-foods/barcode/460123/create") == true)
        let requestBody = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        XCTAssertEqual(json["provider"] as? String, FoodProvider.lifeosLabelOcr.rawValue)
        XCTAssertEqual(json["name"] as? String, "Coverage Product")
        XCTAssertEqual(json["brand"] as? String, "Coverage Brand")
        XCTAssertEqual(json["serving_size_g"] as? Double, 55)
        let macros = try XCTUnwrap(json["macros_per_100g"] as? [String: Any])
        XCTAssertEqual(macros["calories"] as? Double, 320)
        XCTAssertEqual(macros["protein_g"] as? Double, 18)
        XCTAssertEqual(macros["fat_g"] as? Double, 9)
        XCTAssertEqual(macros["carbs_g"] as? Double, 34)
        XCTAssertEqual(macros["fiber_g"] as? Double, 5)
        XCTAssertEqual(json["source_confidence"] as? Double, 0.91)

        try await manager.dbQueue.read { db in
            let cachedRow = try XCTUnwrap(
                Row.fetchOne(
                    db,
                    sql: """
                        SELECT provider, name, brand, barcode, fiber_per_100g
                        FROM food_catalog_items
                        WHERE id = ? OR id = ?
                        LIMIT 1
                        """,
                    arguments: [catalogId, catalogId.uuidString]
                )
            )
            XCTAssertEqual(cachedRow["provider"] as String?, FoodProvider.lifeosLabelOcr.rawValue)
            XCTAssertEqual(cachedRow["name"] as String?, "Coverage Product")
            XCTAssertEqual(cachedRow["brand"] as String?, "Coverage Brand")
            XCTAssertEqual(cachedRow["barcode"] as String?, "460123")
            XCTAssertEqual(cachedRow["fiber_per_100g"] as Double?, 5)
        }
    }

    func testNutritionCatalogServiceCreateReviewedFoodCreatesCustomFoodAndCachesIt() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = APIClient(deviceId: "nutrition-catalog-create-custom")
        let service = NutritionCatalogService(dbQueue: manager.dbQueue, apiClient: api)
        let authId = UUID()
        let userId = UUID()
        let customId = UUID()
        let capture = RequestCapture()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
        }

        APIClient._testResetOverrides()
        defer {
            APIClient._testResetOverrides()
            Task { await RateLimitTracker.shared.reset() }
            Task { @MainActor in AuthManager.setActiveAuthIdForTests(nil) }
        }

        await RateLimitTracker.shared.reset()
        await MainActor.run { AuthManager.setActiveAuthIdForTests(authId) }
        APIClient._testSetPostgrestAccessTokenOverride("nutrition-token")

        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/functions/v1/api-foods/custom")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let body = """
        {
          "id": "\(customId.uuidString)",
          "name": "Coverage Product",
          "created_at": "2026-03-20T10:00:00Z"
        }
        """
        APIClient._testSetEdgeRouteDataForRequestOverride { request in
            capture.set(request)
            return (Data(body.utf8), response)
        }

        let review = Self.makeReviewDraft(
            barcode: "   ",
            brand: "   ",
            analysisSource: .onDeviceFallback
        )
        let result = try await service.createReviewedFood(review: review)

        XCTAssertEqual(result.id, customId)
        XCTAssertEqual(result.refType, .custom)
        XCTAssertNil(result.provider)
        XCTAssertEqual(result.name, "Coverage Product")
        XCTAssertNil(result.brand)
        XCTAssertNil(result.barcode)
        XCTAssertEqual(Set(result.tags), ["user_override"])

        let request = try XCTUnwrap(capture.snapshot())
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.url?.path.contains("/functions/v1/api-foods/custom") == true)
        let requestBody = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "Coverage Product")
        XCTAssertNil(json["brand"])
        XCTAssertNil(json["barcode"])
        XCTAssertEqual(json["default_serving_g"] as? Double, 55)
        let macros = try XCTUnwrap(json["macros_per_100g"] as? [String: Any])
        XCTAssertEqual(macros["fiber_g"] as? Double, 5)

        try await manager.dbQueue.read { db in
            let cachedRow = try XCTUnwrap(
                Row.fetchOne(
                    db,
                    sql: """
                        SELECT user_id, name, brand, barcode, fiber_per_100g
                        FROM user_foods
                        WHERE id = ? OR id = ?
                        LIMIT 1
                        """,
                    arguments: [customId, customId.uuidString]
                )
            )
            XCTAssertEqual(MixedUUIDStorage.decode(from: cachedRow, column: "user_id"), userId)
            XCTAssertEqual(cachedRow["name"] as String?, "Coverage Product")
            XCTAssertNil(cachedRow["brand"] as String?)
            XCTAssertNil(cachedRow["barcode"] as String?)
            XCTAssertEqual(cachedRow["fiber_per_100g"] as Double?, 5)
        }
    }

    func testNutritionCatalogServiceCreateReviewedFoodSkipsCustomCacheWhenUserIsUnavailable() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = APIClient(deviceId: "nutrition-catalog-create-custom-no-user")
        let service = NutritionCatalogService(dbQueue: manager.dbQueue, apiClient: api)
        let customId = UUID()

        APIClient._testResetOverrides()
        defer {
            APIClient._testResetOverrides()
            Task { await RateLimitTracker.shared.reset() }
            Task { @MainActor in AuthManager.setActiveAuthIdForTests(nil) }
        }

        await RateLimitTracker.shared.reset()
        APIClient._testSetPostgrestAccessTokenOverride("nutrition-token")

        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/functions/v1/api-foods/custom")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let body = """
        {
          "id": "\(customId.uuidString)",
          "name": "Coverage Product",
          "created_at": "2026-03-20T10:00:00Z"
        }
        """
        APIClient._testSetEdgeRouteDataForRequestOverride { _ in
            (Data(body.utf8), response)
        }

        let review = Self.makeReviewDraft(barcode: "", analysisSource: .onDeviceFallback)
        let result = try await service.createReviewedFood(review: review)

        XCTAssertEqual(result.id, customId)
        XCTAssertEqual(result.refType, .custom)

        try await manager.dbQueue.read { db in
            XCTAssertEqual(try UserFood.fetchCount(db), 0)
        }
    }

    func testQuickFoodLogServiceStoresCustomReferenceAsUserFoodId() async throws {
        let manager = try DatabaseManager.inMemory()
        let service = QuickFoodLogService(dbQueue: manager.dbQueue)
        let authId = UUID()
        let userId = UUID()
        let customFoodId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
        }

        defer {
            Task { @MainActor in AuthManager.setActiveAuthIdForTests(nil) }
        }
        await MainActor.run { AuthManager.setActiveAuthIdForTests(authId) }

        let logId = try await service.logSearchResult(
            Self.makeSearchResult(id: customFoodId, refType: .custom),
            method: .manual,
            targetDay: "2026-03-08",
            loggedAt: Date()
        )

        try await manager.dbQueue.read { db in
            let row = try XCTUnwrap(
                Row.fetchOne(
                    db,
                    sql: """
                        SELECT user_food_id, catalog_item_id, fiber_g
                        FROM food_items
                        WHERE food_log_id = ? OR food_log_id = ?
                        LIMIT 1
                        """,
                    arguments: [logId, logId.uuidString]
                )
            )
            XCTAssertEqual(MixedUUIDStorage.decode(from: row, column: "user_food_id"), customFoodId)
            XCTAssertNil(MixedUUIDStorage.decode(from: row, column: "catalog_item_id"))
            XCTAssertEqual(row["fiber_g"] as Double?, 6)
        }
    }

    func testQuickFoodLogServiceStoresCatalogReferenceAndQueuesDependentOutboxEvents() async throws {
        let manager = try DatabaseManager.inMemory()
        let service = QuickFoodLogService(dbQueue: manager.dbQueue)
        let authId = UUID()
        let userId = UUID()
        let catalogFoodId = UUID()
        let loggedAt = Date(timeIntervalSince1970: 1_710_000_000)

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
        }

        defer {
            Task { @MainActor in AuthManager.setActiveAuthIdForTests(nil) }
        }
        await MainActor.run { AuthManager.setActiveAuthIdForTests(authId) }

        let logId = try await service.logCatalogItem(
            Self.makeSearchResult(id: catalogFoodId, refType: .catalog),
            method: .barcode,
            targetDay: "2026-03-18",
            loggedAt: loggedAt
        )

        try await manager.dbQueue.read { db in
            let log = try XCTUnwrap(
                FoodLog.fetchOne(
                    db,
                    sql: "SELECT * FROM food_logs WHERE id = ? OR id = ? LIMIT 1",
                    arguments: [logId, logId.uuidString]
                )
            )
            XCTAssertEqual(log.loggedDate, "2026-03-18")
            XCTAssertEqual(log.inputMethod, .barcode)
            XCTAssertEqual(log.aiConfidence, 0.95)
            XCTAssertFalse(log.needsReview)
            XCTAssertEqual(log.loggedTimezone, TimeZone.current.identifier)
            XCTAssertEqual(log.loggedUtcOffsetMinutes, TimeZone.current.secondsFromGMT(for: loggedAt) / 60)

            let item = try XCTUnwrap(
                FoodItem.fetchOne(
                    db,
                    sql: "SELECT * FROM food_items WHERE food_log_id = ? OR food_log_id = ? LIMIT 1",
                    arguments: [logId, logId.uuidString]
                )
            )
            XCTAssertEqual(item.catalogItemId, catalogFoodId)
            XCTAssertNil(item.userFoodId)

            let events = try OutboxEvent.fetchAll(
                db,
                sql: "SELECT * FROM outbox_events WHERE path IN (?, ?) ORDER BY priority ASC",
                arguments: ["api-food-log", "rest/v1/food_items"]
            )
            XCTAssertEqual(events.count, 2)
            XCTAssertEqual(events[0].path, "api-food-log")
            XCTAssertEqual(events[0].priority, 100)
            XCTAssertEqual(events[1].path, "rest/v1/food_items")
            XCTAssertEqual(events[1].priority, 101)
            XCTAssertEqual(events[1].dependsOn, logId)
        }
    }

    func testQuickFoodLogServiceThrowsWhenActiveUserCanNotBeResolved() async throws {
        let manager = try DatabaseManager.inMemory()
        let service = QuickFoodLogService(dbQueue: manager.dbQueue)

        defer {
            Task { @MainActor in AuthManager.setActiveAuthIdForTests(nil) }
        }
        await MainActor.run { AuthManager.setActiveAuthIdForTests(UUID()) }

        do {
            _ = try await service.logSearchResult(
                Self.makeSearchResult(id: UUID(), refType: .catalog),
                method: .manual,
                targetDay: "2026-03-18",
                loggedAt: Date()
            )
            XCTFail("Expected unresolved user to throw")
        } catch let error as SyncError {
            guard case .networkUnavailable = error else {
                return XCTFail("Unexpected sync error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUpdateMealReplacesItemsAndQueuesPatchEvent() async throws {
        let manager = try DatabaseManager.inMemory()
        let service = NutritionService(dbQueue: manager.dbQueue)
        let authId = UUID()
        let userId = UUID()
        let mealId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            _ = try Self.insertMeal(db, logId: mealId, userId: userId)
            _ = try Self.insertMealItem(db, logId: mealId, userId: userId)
        }

        let replacement = FoodItem(
            id: UUID(),
            foodLogId: mealId,
            userId: userId,
            name: "Salmon rice bowl",
            weightG: 340,
            calories: 640,
            proteinG: 42,
            fatG: 21,
            carbsG: 61
        )

        try await service.updateMeal(
            NutritionMealUpdateDraft(
                id: mealId,
                loggedAt: Date(timeIntervalSince1970: 1_773_334_800),
                loggedDate: "2026-03-13",
                mealType: .dinner,
                context: .restaurant,
                userNotes: "Adjusted portion after review",
                items: [replacement]
            )
        )

        try await manager.dbQueue.read { db in
            let log = try XCTUnwrap(
                FoodLog.fetchOne(
                    db,
                    sql: "SELECT * FROM food_logs WHERE id = ? OR id = ? LIMIT 1",
                    arguments: [mealId, mealId.uuidString]
                )
            )
            XCTAssertEqual(log.loggedDate, "2026-03-13")
            XCTAssertEqual(log.mealType, .dinner)
            XCTAssertEqual(log.context, .restaurant)
            XCTAssertEqual(log.userNotes, "Adjusted portion after review")
            XCTAssertEqual(log.calories, 640, accuracy: 0.001)
            XCTAssertEqual(log.proteinG, 42, accuracy: 0.001)
            XCTAssertEqual(log.fatG, 21, accuracy: 0.001)
            XCTAssertEqual(log.carbsG, 61, accuracy: 0.001)
            XCTAssertTrue(log.userCorrected)
            XCTAssertFalse(log.needsReview)
            XCTAssertNil(log.aiConfidence)

            let items = try FoodItem.fetchAll(
                db,
                sql: "SELECT * FROM food_items WHERE food_log_id = ? OR food_log_id = ? ORDER BY created_at ASC",
                arguments: [mealId, mealId.uuidString]
            )
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items[0].name, "Salmon rice bowl")

            let event = try XCTUnwrap(
                OutboxEvent.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM outbox_events
                        WHERE path = ?
                        ORDER BY created_at_local DESC
                        LIMIT 1
                        """,
                    arguments: ["api-food-log/\(mealId.uuidString)"]
                )
            )
            XCTAssertEqual(event.httpMethod, .PATCH)
        }
    }

    func testDeleteAndUndoMealQueueEdgeRouteEvents() async throws {
        let manager = try DatabaseManager.inMemory()
        let service = NutritionService(dbQueue: manager.dbQueue)
        let authId = UUID()
        let userId = UUID()
        let mealId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            _ = try Self.insertMeal(db, logId: mealId, userId: userId)
            _ = try Self.insertMealItem(db, logId: mealId, userId: userId)
        }

        let deletedAt = try await service.deleteMeal(id: mealId)
        XCTAssertLessThan(abs(deletedAt.timeIntervalSinceNow), 5)

        try await manager.dbQueue.read { db in
            let log = try XCTUnwrap(
                FoodLog.fetchOne(
                    db,
                    sql: "SELECT * FROM food_logs WHERE id = ? OR id = ? LIMIT 1",
                    arguments: [mealId, mealId.uuidString]
                )
            )
            XCTAssertNotNil(log.deletedAt)
            XCTAssertEqual(log.deletedReason, .userDeleted)

            let event = try XCTUnwrap(
                OutboxEvent.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM outbox_events
                        WHERE path = ?
                        ORDER BY created_at_local DESC
                        LIMIT 1
                        """,
                    arguments: ["api-food-log/\(mealId.uuidString)"]
                )
            )
            XCTAssertEqual(event.httpMethod, .DELETE)
        }

        try await service.undoDeleteMeal(id: mealId)

        try await manager.dbQueue.read { db in
            let log = try XCTUnwrap(
                FoodLog.fetchOne(
                    db,
                    sql: "SELECT * FROM food_logs WHERE id = ? OR id = ? LIMIT 1",
                    arguments: [mealId, mealId.uuidString]
                )
            )
            XCTAssertNil(log.deletedAt)
            XCTAssertNil(log.deletedReason)

            let event = try XCTUnwrap(
                OutboxEvent.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM outbox_events
                        WHERE path = ?
                        ORDER BY created_at_local DESC
                        LIMIT 1
                        """,
                    arguments: ["api-food-log/\(mealId.uuidString)/undo"]
                )
            )
            XCTAssertEqual(event.httpMethod, .POST)
        }
    }

    func testLoadMealDetailPrefersRemoteAndCachesSnapshot() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let mealId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            _ = try Self.insertMeal(db, logId: mealId, userId: userId, calories: 410, protein: 24, fat: 14, carbs: 44)
        }

        let remoteDetail = NutritionMealRemoteDetailResponse(
            id: mealId,
            loggedAt: Date(timeIntervalSince1970: 1_773_420_000),
            loggedDate: "2026-03-14",
            mealType: .dinner,
            context: .restaurant,
            inputMethod: .vision,
            macros: .init(calories: 710, proteinG: 48, fatG: 28, carbsG: 62, fiberG: 9),
            aiConfidence: 0.81,
            userCorrected: false,
            userNotes: "Remote snapshot",
            items: [
                .init(
                    id: UUID(),
                    name: "Steak",
                    brand: nil,
                    barcode: nil,
                    catalogItemId: nil,
                    userFoodId: nil,
                    batchRecipeId: nil,
                    weightG: 220,
                    macros: .init(calories: 430, proteinG: 36, fatG: 26, carbsG: 0, fiberG: nil),
                    confidence: 0.83,
                    detectedByAi: true,
                    userAdjusted: false
                ),
                .init(
                    id: UUID(),
                    name: "Potatoes",
                    brand: nil,
                    barcode: nil,
                    catalogItemId: nil,
                    userFoodId: nil,
                    batchRecipeId: nil,
                    weightG: 180,
                    macros: .init(calories: 280, proteinG: 12, fatG: 2, carbsG: 62, fiberG: 9),
                    confidence: 0.79,
                    detectedByAi: true,
                    userAdjusted: false
                )
            ]
        )
        let detailClient = NutritionMealDetailClientMock(response: remoteDetail)
        let service = NutritionService(dbQueue: manager.dbQueue, detailAPIClient: detailClient)

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
            AuthManager._testSetActiveHasCloudSession(true)
        }
        defer {
            Task { @MainActor in
                AuthManager.setActiveAuthIdForTests(nil)
                AuthManager._testSetActiveHasCloudSession(false)
            }
        }

        let detail = try await service.loadMealDetail(id: mealId, preferRemote: true)
        let snapshot = try XCTUnwrap(detail)
        XCTAssertEqual(snapshot.log.calories, 710, accuracy: 0.001)
        XCTAssertEqual(snapshot.items.count, 2)
        let requestCount = await detailClient.requestCount()
        XCTAssertEqual(requestCount, 1)

        try await manager.dbQueue.read { db in
            let cachedLog = try XCTUnwrap(
                FoodLog.fetchOne(
                    db,
                    sql: "SELECT * FROM food_logs WHERE id = ? OR id = ? LIMIT 1",
                    arguments: [mealId, mealId.uuidString]
                )
            )
            XCTAssertEqual(cachedLog.calories, 710, accuracy: 0.001)

            let itemCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM food_items WHERE food_log_id = ? OR food_log_id = ?",
                arguments: [mealId, mealId.uuidString]
            ) ?? -1
            XCTAssertEqual(itemCount, 2)
        }
    }

    func testLoadMealTemplateDetailReturnsLocalTemplateItems() async throws {
        let manager = try DatabaseManager.inMemory()
        let service = NutritionService(dbQueue: manager.dbQueue)
        let authId = UUID()
        let userId = UUID()
        let templateId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            _ = try Self.insertMealTemplate(db, templateId: templateId, userId: userId)
        }

        defer {
            Task { @MainActor in AuthManager.setActiveAuthIdForTests(nil) }
        }
        await MainActor.run { AuthManager.setActiveAuthIdForTests(authId) }

        let detail = try await service.loadMealTemplateDetail(id: templateId, preferRemote: false)

        let snapshot = try XCTUnwrap(detail)
        XCTAssertEqual(snapshot.template.id, templateId)
        XCTAssertEqual(snapshot.template.name, "Protein breakfast")
        XCTAssertEqual(snapshot.items.count, 2)
        XCTAssertEqual(snapshot.items.first?.name, "Greek yogurt")
    }

    func testCreateMealTemplatePersistsLocalTemplateAndQueuesCreateEvent() async throws {
        let manager = try DatabaseManager.inMemory()
        let service = NutritionService(dbQueue: manager.dbQueue)
        let authId = UUID()
        let userId = UUID()
        let templateId = UUID()
        let items = [
            NutritionMealTemplateItem(
                name: "Chicken bowl",
                brand: "LifeOS",
                barcode: "460999",
                weightG: 320,
                calories: 540,
                proteinG: 42,
                fatG: 18,
                carbsG: 46,
                fiberG: 8
            ),
            NutritionMealTemplateItem(
                name: "Kiwi",
                brand: nil,
                barcode: nil,
                weightG: 90,
                calories: 52,
                proteinG: 1,
                fatG: 0.4,
                carbsG: 12,
                fiberG: 2.4
            )
        ]

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
        }

        defer {
            Task { @MainActor in AuthManager.setActiveAuthIdForTests(nil) }
        }
        await MainActor.run { AuthManager.setActiveAuthIdForTests(authId) }

        let createdId = try await service.createMealTemplate(
            NutritionMealTemplateCreateDraft(
                id: templateId,
                name: "Desk lunch",
                mealType: .lunch,
                items: items
            )
        )

        XCTAssertEqual(createdId, templateId)

        try await manager.dbQueue.read { db in
            let template = try XCTUnwrap(
                MealTemplate.fetchOne(
                    db,
                    sql: "SELECT * FROM meal_templates WHERE id = ? OR id = ? LIMIT 1",
                    arguments: [templateId, templateId.uuidString]
                )
            )
            XCTAssertEqual(template.userId, userId)
            XCTAssertEqual(template.name, "Desk lunch")
            XCTAssertEqual(template.mealType, .lunch)
            XCTAssertEqual(template.calories, 592, accuracy: 0.001)
            XCTAssertEqual(template.proteinG, 43, accuracy: 0.001)
            XCTAssertEqual(template.fatG, 18.4, accuracy: 0.001)
            XCTAssertEqual(template.carbsG, 58, accuracy: 0.001)
            let fiberG = try XCTUnwrap(template.fiberG)
            XCTAssertEqual(fiberG, 10.4, accuracy: 0.001)
            XCTAssertEqual(template.timesUsed, 0)
            XCTAssertFalse(template.archived)

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let storedItems = try decoder.decode([NutritionMealTemplateItem].self, from: template.templateItems)
            XCTAssertEqual(storedItems, items)

            let event = try XCTUnwrap(
                OutboxEvent.fetchOne(
                    db,
                    sql: "SELECT * FROM outbox_events WHERE id = ? OR id = ? LIMIT 1",
                    arguments: [templateId, templateId.uuidString]
                )
            )
            XCTAssertEqual(event.httpMethod, .POST)
            XCTAssertEqual(event.path, "api-nutrition-templates")

            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: event.bodyJson) as? [String: Any]
            )
            XCTAssertEqual(payload["id"] as? String, templateId.uuidString)
        }
    }

    @MainActor
    func testCreateMealTemplateFailsWithoutResolvedUserIdentity() async throws {
        let manager = try DatabaseManager.inMemory()
        let service = NutritionService(dbQueue: manager.dbQueue)
        let authId = UUID()

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        do {
            _ = try await service.createMealTemplate(
                NutritionMealTemplateCreateDraft(
                    name: "Unbound template",
                    mealType: .snack,
                    items: [
                        NutritionMealTemplateItem(
                            name: "Bar",
                            weightG: 55,
                            calories: 240,
                            proteinG: 20,
                            fatG: 8,
                            carbsG: 18,
                            fiberG: 4
                        )
                    ]
                )
            )
            XCTFail("Expected createMealTemplate to fail when user identity cannot be resolved")
        } catch {
            XCTAssertEqual(error.localizedDescription, SyncError.networkUnavailable.errorDescription)
        }

        let snapshot = try await manager.dbQueue.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meal_templates") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox_events WHERE path = 'api-nutrition-templates'") ?? 0
            )
        }

        XCTAssertEqual(snapshot.0, 0)
        XCTAssertEqual(snapshot.1, 0)
    }

    func testUpdateMealTemplateAfterCreateDependsOnPendingCreateEvent() async throws {
        let manager = try DatabaseManager.inMemory()
        let service = NutritionService(dbQueue: manager.dbQueue)
        let authId = UUID()
        let userId = UUID()
        let templateId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
        }

        defer {
            Task { @MainActor in AuthManager.setActiveAuthIdForTests(nil) }
        }
        await MainActor.run { AuthManager.setActiveAuthIdForTests(authId) }

        _ = try await service.createMealTemplate(
            NutritionMealTemplateCreateDraft(
                id: templateId,
                name: "Office lunch",
                mealType: .lunch,
                items: [
                    NutritionMealTemplateItem(
                        name: "Rice bowl",
                        weightG: 280,
                        calories: 510,
                        proteinG: 28,
                        fatG: 14,
                        carbsG: 66,
                        fiberG: 6
                    )
                ]
            )
        )

        try await service.updateMealTemplate(
            NutritionMealTemplateUpdateDraft(
                id: templateId,
                name: "Office lunch v2",
                mealType: .dinner,
                items: [
                    NutritionMealTemplateItem(
                        name: "Rice bowl",
                        weightG: 320,
                        calories: 580,
                        proteinG: 34,
                        fatG: 16,
                        carbsG: 72,
                        fiberG: 7
                    )
                ],
                archived: false
            )
        )

        try await manager.dbQueue.read { db in
            let event = try XCTUnwrap(
                OutboxEvent.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM outbox_events
                        WHERE path = ?
                        ORDER BY created_at_local DESC
                        LIMIT 1
                        """,
                    arguments: ["api-nutrition-templates/\(templateId.uuidString)"]
                )
            )
            XCTAssertEqual(event.httpMethod, .PATCH)
            XCTAssertEqual(event.dependsOn, templateId)
        }
    }

    func testApplyMealTemplateAfterCreateDependsOnPendingCreateEvent() async throws {
        let manager = try DatabaseManager.inMemory()
        let service = NutritionService(dbQueue: manager.dbQueue)
        let authId = UUID()
        let userId = UUID()
        let templateId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
        }

        defer {
            Task { @MainActor in AuthManager.setActiveAuthIdForTests(nil) }
        }
        await MainActor.run { AuthManager.setActiveAuthIdForTests(authId) }

        _ = try await service.createMealTemplate(
            NutritionMealTemplateCreateDraft(
                id: templateId,
                name: "Quick dinner",
                mealType: .dinner,
                items: [
                    NutritionMealTemplateItem(
                        name: "Salmon",
                        weightG: 180,
                        calories: 360,
                        proteinG: 34,
                        fatG: 22,
                        carbsG: 0,
                        fiberG: 0
                    )
                ]
            )
        )

        _ = try await service.applyMealTemplate(
            id: templateId,
            targetDay: "2026-03-16",
            loggedAt: Date(timeIntervalSince1970: 1_773_600_000),
            context: .home
        )

        try await manager.dbQueue.read { db in
            let event = try XCTUnwrap(
                OutboxEvent.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM outbox_events
                        WHERE path = ?
                        ORDER BY created_at_local DESC
                        LIMIT 1
                        """,
                    arguments: ["api-nutrition-templates/\(templateId.uuidString)/log"]
                )
            )
            XCTAssertEqual(event.httpMethod, .POST)
            XCTAssertEqual(event.dependsOn, templateId)
        }
    }

    func testUpdateMealTemplateRewritesLocalTemplateAndQueuesPatchEvent() async throws {
        let manager = try DatabaseManager.inMemory()
        let service = NutritionService(dbQueue: manager.dbQueue)
        let authId = UUID()
        let userId = UUID()
        let templateId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            _ = try Self.insertMealTemplate(db, templateId: templateId, userId: userId)
        }

        defer {
            Task { @MainActor in AuthManager.setActiveAuthIdForTests(nil) }
        }
        await MainActor.run { AuthManager.setActiveAuthIdForTests(authId) }

        try await service.updateMealTemplate(
            NutritionMealTemplateUpdateDraft(
                id: templateId,
                name: "Work lunch",
                mealType: .lunch,
                items: [
                    NutritionMealTemplateItem(
                        name: "Chicken wrap",
                        brand: "Cafe",
                        barcode: "9988",
                        weightG: 320,
                        calories: 640,
                        proteinG: 38,
                        fatG: 24,
                        carbsG: 52,
                        fiberG: 7
                    )
                ],
                archived: false
            )
        )

        try await manager.dbQueue.read { db in
            let template = try XCTUnwrap(
                MealTemplate.fetchOne(
                    db,
                    sql: "SELECT * FROM meal_templates WHERE id = ? OR id = ? LIMIT 1",
                    arguments: [templateId, templateId.uuidString]
                )
            )
            XCTAssertEqual(template.name, "Work lunch")
            XCTAssertEqual(template.mealType, .lunch)
            XCTAssertEqual(template.calories, 640, accuracy: 0.001)
            let fiberG = try XCTUnwrap(template.fiberG)
            XCTAssertEqual(fiberG, 7, accuracy: 0.001)

            let event = try XCTUnwrap(
                OutboxEvent.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM outbox_events
                        WHERE path = ?
                        ORDER BY created_at_local DESC
                        LIMIT 1
                        """,
                    arguments: ["api-nutrition-templates/\(templateId.uuidString)"]
                )
            )
            XCTAssertEqual(event.httpMethod, .PATCH)
        }
    }

    func testArchiveMealTemplateQueuesPatchEvent() async throws {
        let manager = try DatabaseManager.inMemory()
        let service = NutritionService(dbQueue: manager.dbQueue)
        let authId = UUID()
        let userId = UUID()
        let templateId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            _ = try Self.insertMealTemplate(db, templateId: templateId, userId: userId, archived: false)
        }

        defer {
            Task { @MainActor in AuthManager.setActiveAuthIdForTests(nil) }
        }
        await MainActor.run { AuthManager.setActiveAuthIdForTests(authId) }

        try await service.setMealTemplateArchived(id: templateId, archived: true)

        try await manager.dbQueue.read { db in
            let template = try XCTUnwrap(
                MealTemplate.fetchOne(
                    db,
                    sql: "SELECT * FROM meal_templates WHERE id = ? OR id = ? LIMIT 1",
                    arguments: [templateId, templateId.uuidString]
                )
            )
            XCTAssertTrue(template.archived)

            let event = try XCTUnwrap(
                OutboxEvent.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM outbox_events
                        WHERE path = ?
                        ORDER BY created_at_local DESC
                        LIMIT 1
                        """,
                    arguments: ["api-nutrition-templates/\(templateId.uuidString)"]
                )
            )
            XCTAssertEqual(event.httpMethod, .PATCH)
        }
    }

    func testApplyMealTemplateQueuesTemplateLogRouteAndFoodItemEvents() async throws {
        let manager = try DatabaseManager.inMemory()
        let service = NutritionService(dbQueue: manager.dbQueue)
        let authId = UUID()
        let userId = UUID()
        let templateId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            _ = try Self.insertMealTemplate(db, templateId: templateId, userId: userId)
        }

        defer {
            Task { @MainActor in AuthManager.setActiveAuthIdForTests(nil) }
        }
        await MainActor.run { AuthManager.setActiveAuthIdForTests(authId) }

        let result = try await service.applyMealTemplate(
            id: templateId,
            targetDay: "2026-03-16",
            loggedAt: Date(timeIntervalSince1970: 1_773_600_000),
            context: nil
        )

        try await manager.dbQueue.read { db in
            let log = try XCTUnwrap(
                FoodLog.fetchOne(
                    db,
                    sql: "SELECT * FROM food_logs WHERE id = ? OR id = ? LIMIT 1",
                    arguments: [result.foodLogId, result.foodLogId.uuidString]
                )
            )
            XCTAssertEqual(log.inputMethod, .template)
            XCTAssertEqual(log.loggedDate, "2026-03-16")

            let createEvent = try XCTUnwrap(
                OutboxEvent.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM outbox_events
                        WHERE path = ?
                        LIMIT 1
                        """,
                    arguments: ["api-nutrition-templates/\(templateId.uuidString)/log"]
                )
            )
            XCTAssertEqual(createEvent.id, result.foodLogId)
            XCTAssertEqual(createEvent.httpMethod, .POST)

            let legacyCreateCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?",
                arguments: ["api-food-log"]
            ) ?? -1
            XCTAssertEqual(legacyCreateCount, 0)

            let foodItemCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM food_items WHERE food_log_id = ? OR food_log_id = ?",
                arguments: [result.foodLogId, result.foodLogId.uuidString]
            ) ?? -1
            XCTAssertEqual(foodItemCount, 2)

            let dependentItemEvents = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM outbox_events
                    WHERE path = ?
                      AND (depends_on = ? OR depends_on = ?)
                    """,
                arguments: ["rest/v1/food_items", result.foodLogId, result.foodLogId.uuidString]
            ) ?? -1
            XCTAssertEqual(dependentItemEvents, 2)

            let template = try XCTUnwrap(
                MealTemplate.fetchOne(
                    db,
                    sql: "SELECT * FROM meal_templates WHERE id = ? OR id = ? LIMIT 1",
                    arguments: [templateId, templateId.uuidString]
                )
            )
            XCTAssertEqual(template.timesUsed, 3)
            XCTAssertNotNil(template.lastUsedAt)
        }
    }
}
