import Foundation
import GRDB
import XCTest
@testable import LifeOS

private actor DailyInsightsRouteClientMock: DailyInsightsRouteAPIClient {
    enum Mode {
        case success(DailyInsightsEdgeResponse)
        case failure(Error)
    }

    private let mode: Mode
    private(set) var requestedDates: [String] = []

    init(mode: Mode) {
        self.mode = mode
    }

    func fetchDailyInsightsSnapshot(date: String) async throws -> DailyInsightsEdgeResponse {
        requestedDates.append(date)
        switch mode {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }

    func requestSnapshot() -> [String] {
        requestedDates
    }
}

private actor DailyInsightsServiceMock: DailyInsightsManaging {
    enum Mode {
        case success(DailyInsightsSnapshot?)
        case failure(Error)
    }

    private let mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func refreshCurrentDaySnapshot() async throws -> DailyInsightsSnapshot? {
        switch mode {
        case .success(let snapshot):
            return snapshot
        case .failure(let error):
            throw error
        }
    }
}

private let dailyInsightsCurrentDayDate = Date(timeIntervalSince1970: 1_773_835_200)

@MainActor
final class DailyInsightsServiceTests: XCTestCase {
    override func tearDown() {
        AuthManager.setActiveAuthIdForTests(nil)
        AuthManager._testSetActiveHasCloudSession(false)
        super.tearDown()
    }

    nonisolated private static func insertUser(
        _ db: Database,
        userId: UUID,
        authId: UUID,
        timezone: String = "UTC"
    ) throws {
        var user = User(id: userId, authId: authId, timezone: timezone, units: .metric)
        user.baselineSleepHours = 8
        try user.insert(db)
    }

    nonisolated private static func insertRecoveryState(
        _ db: Database,
        userId: UUID,
        date: String,
        recoveryScore: Double,
        sleepDurationHours: Double,
        confidenceScore: Double
    ) throws {
        var state = PhysiologicalState(userId: userId, date: date, recoveryScore: recoveryScore)
        state.sleepDurationHours = sleepDurationHours
        state.confidenceScore = confidenceScore
        state.allostaticLoad = recoveryScore < 50 ? 4.2 : 2.1
        try state.insert(db)
    }

    nonisolated private static func insertFoodLog(
        _ db: Database,
        userId: UUID,
        loggedDate: String,
        proteinG: Double
    ) throws {
        var log = FoodLog(
            userId: userId,
            loggedAt: dailyInsightsCurrentDayDate,
            loggedDate: loggedDate,
            inputMethod: .manual,
            calories: 520,
            proteinG: proteinG,
            fatG: 18,
            carbsG: 54
        )
        log.loggedTimezone = "UTC"
        try log.insert(db)
    }

    nonisolated private static func insertTarget(
        _ db: Database,
        userId: UUID,
        date: String,
        proteinTarget: Int
    ) throws {
        var target = DailyNutritionTarget(userId: userId, date: date)
        target.finalCalories = 2200
        target.finalProteinG = proteinTarget
        try target.insert(db)
    }

    nonisolated private static func makeSnapshot(date: String, userId: UUID) -> DailyInsightsSnapshot {
        var insight = Insight(
            id: UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!,
            userId: userId,
            category: .general,
            title: "Remote insight",
            body: "Canonical body",
            confidence: 0.9
        )
        insight.type = "daily/\(date)/setup_prompt"
        insight.priority = 2

        var recommendation = Recommendation(
            id: UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!,
            userId: userId,
            recommendationDate: date,
            category: "recovery",
            priority: "medium",
            title: "Remote recommendation",
            description: "Canonical recommendation",
            reasoning: "Canonical reasoning"
        )
        recommendation.triggerCondition = "daily/\(date)/steady_day"
        recommendation.timeOfDay = "morning"

        return DailyInsightsSnapshot(
            date: date,
            insights: [insight],
            recommendations: [recommendation]
        )
    }

    func testDailyInsightsServiceProducesLocalFallbackWithoutCloudSession() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            try Self.insertRecoveryState(db, userId: userId, date: "2026-03-18", recoveryScore: 42, sleepDurationHours: 6.1, confidenceScore: 0.88)
            try Self.insertTarget(db, userId: userId, date: "2026-03-18", proteinTarget: 140)
            try Self.insertFoodLog(db, userId: userId, loggedDate: "2026-03-18", proteinG: 55)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        AuthManager._testSetActiveHasCloudSession(false)

        let routeClient = DailyInsightsRouteClientMock(mode: .failure(SyncError.networkUnavailable))
        let service = DailyInsightsService(
            dbQueue: manager.dbQueue,
            apiClient: routeClient,
            nowProvider: { dailyInsightsCurrentDayDate }
        )

        let snapshot = try await service.refreshCurrentDaySnapshot()
        let persisted = try await manager.dbQueue.read { db in
            (
                insights: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM insights") ?? 0,
                recommendations: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recommendations") ?? 0
            )
        }

        XCTAssertEqual(snapshot?.date, "2026-03-18")
        XCTAssertFalse(snapshot?.insights.isEmpty ?? true)
        XCTAssertFalse(snapshot?.recommendations.isEmpty ?? true)
        XCTAssertGreaterThanOrEqual(persisted.insights, 1)
        XCTAssertGreaterThanOrEqual(persisted.recommendations, 1)
        let requests = await routeClient.requestSnapshot()
        XCTAssertTrue(requests.isEmpty)
    }

    func testDailyInsightsServiceFetchesRemoteCanonicalSnapshotAndPersists() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        AuthManager._testSetActiveHasCloudSession(true)

        let snapshot = Self.makeSnapshot(date: "2026-03-18", userId: userId)
        let response = DailyInsightsEdgeResponse(
            date: snapshot.date,
            insights: snapshot.insights,
            recommendations: snapshot.recommendations
        )
        let routeClient = DailyInsightsRouteClientMock(mode: .success(response))
        let service = DailyInsightsService(
            dbQueue: manager.dbQueue,
            apiClient: routeClient,
            nowProvider: { dailyInsightsCurrentDayDate }
        )

        let refreshed = try await service.refreshCurrentDaySnapshot()
        let stored = try await manager.dbQueue.read { db in
            (
                insight: try Insight.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM insights
                        WHERE dismissed = 0
                        ORDER BY updated_at DESC
                        LIMIT 1
                        """
                ),
                recommendation: try Recommendation.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM recommendations
                        WHERE dismissed = 0
                        ORDER BY updated_at DESC
                        LIMIT 1
                        """
                )
            )
        }

        XCTAssertEqual(refreshed?.insights.first?.title, "Remote insight")
        XCTAssertEqual(refreshed?.recommendations.first?.title, "Remote recommendation")
        XCTAssertEqual(stored.insight?.title, "Remote insight")
        XCTAssertEqual(stored.recommendation?.title, "Remote recommendation")
        let requests = await routeClient.requestSnapshot()
        XCTAssertEqual(requests, ["2026-03-18"])
    }

    func testDailyInsightsServiceDismissesOlderGeneratedDailyInsights() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)

            var staleInsight = Insight(
                id: UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!,
                userId: userId,
                category: .general,
                title: "Stale daily insight",
                body: "Yesterday's guidance",
                confidence: 0.82
            )
            staleInsight.type = "daily/2026-03-17/setup_prompt"
            staleInsight.createdAt = Date(timeIntervalSince1970: 1_773_792_000)
            staleInsight.updatedAt = Date(timeIntervalSince1970: 1_773_792_000)
            try staleInsight.insert(db)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        AuthManager._testSetActiveHasCloudSession(true)

        let snapshot = Self.makeSnapshot(date: "2026-03-18", userId: userId)
        let response = DailyInsightsEdgeResponse(
            date: snapshot.date,
            insights: snapshot.insights,
            recommendations: snapshot.recommendations
        )
        let routeClient = DailyInsightsRouteClientMock(mode: .success(response))
        let service = DailyInsightsService(
            dbQueue: manager.dbQueue,
            apiClient: routeClient,
            nowProvider: { dailyInsightsCurrentDayDate }
        )

        _ = try await service.refreshCurrentDaySnapshot()
        let stored = try await manager.dbQueue.read { db in
            try Insight.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM insights
                    ORDER BY created_at ASC
                    """
            )
        }

        XCTAssertGreaterThanOrEqual(stored.count, 2)
        XCTAssertEqual(stored.first(where: { $0.type == "daily/2026-03-17/setup_prompt" })?.dismissed, true)
        XCTAssertTrue(stored.contains(where: { $0.type == "daily/2026-03-18/setup_prompt" && $0.dismissed == false }))
    }

    @MainActor
    func testInsightsViewModelFallsBackToGeneratedSnapshotWhenDatabaseIsEmpty() async throws {
        let manager = try DatabaseManager.inMemory()
        AuthManager.setActiveAuthIdForTests(nil)
        let userId = UUID()
        let snapshot = Self.makeSnapshot(date: "2026-03-18", userId: userId)
        let viewModel = InsightsViewModel(
            dbQueue: manager.dbQueue,
            dailyInsightsService: DailyInsightsServiceMock(mode: .success(snapshot))
        )

        await viewModel.refresh()

        XCTAssertEqual(viewModel.insights.map(\.title), ["Remote insight"])
        XCTAssertNil(viewModel.loadError)
    }

    @MainActor
    func testHomeViewModelUsesGeneratedRecommendationsWhenDatabaseIsEmpty() async throws {
        let manager = try DatabaseManager.inMemory()
        AuthManager.setActiveAuthIdForTests(nil)
        let userId = UUID()
        let snapshot = Self.makeSnapshot(date: "2026-03-18", userId: userId)
        let viewModel = HomeViewModel(
            dbQueue: manager.dbQueue,
            dailyInsightsService: DailyInsightsServiceMock(mode: .success(snapshot)),
            pushLatestWatchSnapshot: { _ in }
        )

        await viewModel.refresh()

        XCTAssertEqual(viewModel.recommendations.map(\.title), ["Remote recommendation"])
    }
}
