import Foundation
import GRDB
import XCTest
@testable import LifeOS

private actor WeeklyStrategyRouteClientMock: WeeklyStrategyRouteAPIClient {
    enum Mode {
        case success(WeeklyStrategyEdgeResponse)
        case failure(Error)
    }

    private let mode: Mode
    private(set) var requestedWeekStarts: [String] = []

    init(mode: Mode) {
        self.mode = mode
    }

    func fetchWeeklyStrategyReport(weekStart: String) async throws -> WeeklyStrategyEdgeResponse {
        requestedWeekStarts.append(weekStart)
        switch mode {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }

    func requestSnapshot() -> [String] {
        requestedWeekStarts
    }
}

private actor WeeklyStrategyServiceMock: WeeklyStrategyManaging {
    enum Mode {
        case success(WeeklyStrategyReport?)
        case failure(Error)
    }

    private let mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func refreshCurrentWeekReport() async throws -> WeeklyStrategyReport? {
        switch mode {
        case .success(let report):
            return report
        case .failure(let error):
            throw error
        }
    }
}

@MainActor
final class WeeklyStrategyServiceTests: XCTestCase {
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
        user.weightKg = 75
        try user.insert(db)
    }

    nonisolated private static func insertRecoveryState(
        _ db: Database,
        userId: UUID,
        date: String,
        recoveryScore: Double,
        sleepDurationHours: Double,
        allostaticLoad: Double
    ) throws {
        var state = PhysiologicalState(userId: userId, date: date, recoveryScore: recoveryScore)
        state.sleepDurationHours = sleepDurationHours
        state.allostaticLoad = allostaticLoad
        try state.insert(db)
    }

    nonisolated private static func insertFoodLog(
        _ db: Database,
        userId: UUID,
        loggedDate: String
    ) throws {
        var log = FoodLog(
            userId: userId,
            loggedAt: Date(timeIntervalSince1970: 1_774_022_800),
            loggedDate: loggedDate,
            inputMethod: .manual,
            calories: 600,
            proteinG: 35,
            fatG: 20,
            carbsG: 55
        )
        log.loggedTimezone = "UTC"
        try log.insert(db)
    }

    nonisolated private static func insertWorkoutSession(
        _ db: Database,
        userId: UUID,
        sessionDate: String,
        trimpScore: Double
    ) throws {
        var session = WorkoutSession(
            userId: userId,
            startedAt: Date(timeIntervalSince1970: 1_774_022_800),
            sessionDate: sessionDate,
            source: .manual
        )
        session.trimpScore = trimpScore
        session.startedTimezone = "UTC"
        session.startedUtcOffsetMinutes = 0
        try session.insert(db)
    }

    nonisolated private static func insertInsight(
        _ db: Database,
        userId: UUID,
        title: String = "Readiness insight"
    ) throws {
        var insight = Insight(
            userId: userId,
            category: .recovery,
            title: title,
            body: "Body",
            confidence: 0.82
        )
        insight.dismissed = false
        insight.priority = 2
        try insight.insert(db)
    }

    nonisolated private static func makeSummaryStatsData(trainingVolume: Double) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "avg_recovery_score": 81.4,
                "recovery_trend": "increasing",
                "days_in_optimal_zone": 3,
                "days_in_critical_zone": 0,
                "avg_sleep_duration": 7.6,
                "sleep_consistency": 0.84,
                "nutrition_adherence": 0.71,
                "training_volume": trainingVolume,
                "allostatic_load": 2.3
            ],
            options: [.sortedKeys]
        )
    }

    func testWeeklyStrategyServiceReturnsLocalFallbackWithoutCloudSession() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            try Self.insertRecoveryState(db, userId: userId, date: "2026-03-16", recoveryScore: 78, sleepDurationHours: 7.8, allostaticLoad: 2.1)
            try Self.insertRecoveryState(db, userId: userId, date: "2026-03-17", recoveryScore: 82, sleepDurationHours: 8.1, allostaticLoad: 2.0)
            try Self.insertFoodLog(db, userId: userId, loggedDate: "2026-03-16")
            try Self.insertWorkoutSession(db, userId: userId, sessionDate: "2026-03-17", trimpScore: 45)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        AuthManager._testSetActiveHasCloudSession(false)

        let routeClient = WeeklyStrategyRouteClientMock(mode: .failure(SyncError.networkUnavailable))
        let service = WeeklyStrategyService(
            dbQueue: manager.dbQueue,
            apiClient: routeClient,
            nowProvider: { Date(timeIntervalSince1970: 1_773_878_400) }
        )

        let report = try await service.refreshCurrentWeekReport()
        let persistedCount = try await manager.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM weekly_strategy_reports") ?? 0
        }

        XCTAssertEqual(report?.weekStart, "2026-03-16")
        XCTAssertEqual(report?.weekEnd, "2026-03-22")
        XCTAssertEqual(report?.modelUsed, "local_heuristic")
        XCTAssertTrue(report?.reportMarkdown.contains("Training volume (TRIMP): 45.0") == true)
        XCTAssertEqual(persistedCount, 0)
        let requests = await routeClient.requestSnapshot()
        XCTAssertTrue(requests.isEmpty)
    }

    func testWeeklyStrategyServiceFetchesRemoteAndPersistsCanonicalReport() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let reportId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        AuthManager._testSetActiveHasCloudSession(true)

        let response = WeeklyStrategyEdgeResponse(
            reportId: reportId,
            createdAt: Date(timeIntervalSince1970: 1_773_878_400),
            updatedAt: Date(timeIntervalSince1970: 1_773_882_000),
            weekStart: "2026-03-16",
            weekEnd: "2026-03-22",
            reportMarkdown: "Remote weekly strategy",
            summaryStats: try Self.makeSummaryStatsData(trainingVolume: 91.5),
            modelUsed: "local_heuristic",
            promptVersion: "v1"
        )
        let routeClient = WeeklyStrategyRouteClientMock(mode: .success(response))
        let service = WeeklyStrategyService(
            dbQueue: manager.dbQueue,
            apiClient: routeClient,
            nowProvider: { Date(timeIntervalSince1970: 1_773_878_400) }
        )

        let report = try await service.refreshCurrentWeekReport()
        let storedReport = try await manager.dbQueue.read { db in
            try WeeklyStrategyReport.fetchOne(
                db,
                sql: """
                    SELECT *
                    FROM weekly_strategy_reports
                    WHERE (user_id = ? OR user_id = ?)
                      AND week_start = ?
                    LIMIT 1
                    """,
                arguments: [userId, userId.uuidString, "2026-03-16"]
            )
        }

        XCTAssertEqual(report?.id, reportId)
        XCTAssertEqual(report?.reportMarkdown, "Remote weekly strategy")
        XCTAssertEqual(storedReport?.id, reportId)
        XCTAssertEqual(storedReport?.promptVersion, "v1")
        let requests = await routeClient.requestSnapshot()
        XCTAssertEqual(requests, ["2026-03-16"])
    }

    @MainActor
    func testInsightsViewModelUsesGeneratedWeeklyStrategyEvenWhenNotPersisted() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        let transientReport = WeeklyStrategyReport(
            userId: userId,
            weekStart: "2026-03-16",
            weekEnd: "2026-03-22",
            summaryStats: try Self.makeSummaryStatsData(trainingVolume: 64),
            reportMarkdown: "Transient weekly strategy"
        )
        let service = WeeklyStrategyServiceMock(mode: .success(transientReport))
        let viewModel = InsightsViewModel(
            dbQueue: manager.dbQueue,
            weeklyStrategyService: service
        )

        await viewModel.refresh()

        XCTAssertEqual(viewModel.latestWeeklyStrategyReport?.reportMarkdown, "Transient weekly strategy")
        XCTAssertNil(viewModel.loadError)
    }

    @MainActor
    func testInsightsViewModelPreservesInsightsWhenWeeklyStrategyRefreshFails() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            try Self.insertInsight(db, userId: userId)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        let service = WeeklyStrategyServiceMock(
            mode: .failure(SyncError.serverError(code: 500, message: "boom"))
        )
        let viewModel = InsightsViewModel(
            dbQueue: manager.dbQueue,
            weeklyStrategyService: service
        )

        await viewModel.refresh()

        XCTAssertEqual(viewModel.totalInsightCount, 1)
        XCTAssertEqual(viewModel.insights.count, 1)
        XCTAssertNil(viewModel.loadError)
    }
}
