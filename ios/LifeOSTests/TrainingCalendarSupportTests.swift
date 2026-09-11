import Foundation
import GRDB
import XCTest
@testable import LifeOS

private actor TrainingCalendarRouteAPIClientMock: TrainingCalendarRouteAPIClient {
    private let response: WorkoutCalendarRemoteResponse?
    private let error: Error?
    private(set) var requests: [(from: String, to: String)] = []

    init(response: WorkoutCalendarRemoteResponse? = nil, error: Error? = nil) {
        self.response = response
        self.error = error
    }

    func fetchWorkoutCalendar(
        from fromDay: String,
        to toDay: String
    ) async throws -> WorkoutCalendarRemoteResponse {
        requests.append((fromDay, toDay))
        if let error {
            throw error
        }
        return response ?? WorkoutCalendarRemoteResponse(from: fromDay, to: toDay, days: [])
    }

    func requestSnapshot() -> [(from: String, to: String)] {
        requests
    }
}

@MainActor
final class TrainingCalendarSupportTests: XCTestCase {
    private func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }

    private func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: localized(key), arguments: arguments)
    }

    override func tearDown() {
        AuthManager.setActiveAuthIdForTests(nil)
        AuthManager._testSetActiveHasCloudSession(false)
        super.tearDown()
    }

    func testDayAndWeekSummaryExposeCalendarBusinessState() {
        let restDay = TrainingCalendarDay(
            day: "2026-03-02",
            loggedCount: 0,
            plannedCount: 0,
            completedPlannedCount: 0,
            totalDurationMinutes: 0,
            totalTrimpScore: 0
        )
        XCTAssertFalse(restDay.hasLoggedWorkout)
        XCTAssertFalse(restDay.hasPlannedWorkout)
        XCTAssertNil(restDay.durationLabel)
        XCTAssertNil(restDay.compactMetricLabel)
        XCTAssertTrue(restDay.accessibilitySummary.contains(localized("training.calendar_rest_day")))

        let plannedDay = TrainingCalendarDay(
            day: "2026-03-03",
            loggedCount: 0,
            plannedCount: 2,
            completedPlannedCount: 1,
            totalDurationMinutes: 0,
            totalTrimpScore: 0
        )
        XCTAssertTrue(plannedDay.hasPlannedWorkout)
        XCTAssertEqual(plannedDay.compactMetricLabel, localizedFormat("training.calendar_planned_short_format", 2))
        XCTAssertTrue(plannedDay.accessibilitySummary.contains(localizedFormat("training.calendar_planned_format", 2)))

        let loggedDay = TrainingCalendarDay(
            day: "2026-03-04",
            loggedCount: 3,
            plannedCount: 2,
            completedPlannedCount: 1,
            totalDurationMinutes: 135,
            totalTrimpScore: 155
        )
        XCTAssertTrue(loggedDay.hasLoggedWorkout)
        XCTAssertEqual(loggedDay.durationLabel, localizedTrainingMinutes(135))
        XCTAssertEqual(loggedDay.compactMetricLabel, localizedTrainingMinutes(135))
        XCTAssertTrue(loggedDay.accessibilitySummary.contains(localizedFormat("training.calendar_logged_format", 3)))
        XCTAssertTrue(loggedDay.accessibilitySummary.contains(localizedFormat("training.calendar_trimp_format", 155.0)))

        let mixedSummary = TrainingCalendarWeekSummary(days: [restDay, plannedDay, loggedDay])
        XCTAssertEqual(mixedSummary.loggedSessions, 3)
        XCTAssertEqual(mixedSummary.plannedSessions, 4)
        XCTAssertEqual(mixedSummary.completedPlannedSessions, 2)
        XCTAssertEqual(mixedSummary.totalDurationMinutes, 135)
        XCTAssertEqual(mixedSummary.totalTrimpScore, 155)
        XCTAssertEqual(mixedSummary.completionLabel, localizedFormat("training.calendar_completion_format", 3, 4))
        XCTAssertEqual(mixedSummary.durationLabel, localizedTrainingMinutes(135))
        XCTAssertEqual(mixedSummary.loadLabel, "155 TRIMP")

        let loggedOnlySummary = TrainingCalendarWeekSummary(days: [
            TrainingCalendarDay(
                day: "2026-03-05",
                loggedCount: 1,
                plannedCount: 0,
                completedPlannedCount: 0,
                totalDurationMinutes: 30,
                totalTrimpScore: 20
            )
        ])
        XCTAssertEqual(loggedOnlySummary.completionLabel, localizedFormat("training.calendar_logged_only_format", 1))

        let emptySummary = TrainingCalendarWeekSummary(days: [restDay])
        XCTAssertEqual(emptySummary.completionLabel, localized("training.calendar_recovery_week"))
        XCTAssertEqual(emptySummary.durationLabel, localized("training.calendar_no_duration"))
        XCTAssertEqual(emptySummary.loadLabel, localized("training.calendar_load_pending"))
    }

    func testRangeHelpersResolveContainingWeekAndCalendarMonth() throws {
        let calendar = Calendar.current
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 4)))

        let week = TrainingCalendarLoader.weekRange(containing: date)
        let expectedWeekStart = calendar.dateInterval(of: .weekOfYear, for: date)?.start
        XCTAssertEqual(week.from, DiaryDateFormatter.formatDate(try XCTUnwrap(expectedWeekStart)))
        XCTAssertEqual(week.to, DiaryDateFormatter.formatDate(
            try XCTUnwrap(calendar.date(byAdding: .day, value: 6, to: try XCTUnwrap(expectedWeekStart)))
        ))

        let month = TrainingCalendarLoader.monthRange(for: date)
        XCTAssertEqual(month.from, "2026-03-01")
        XCTAssertEqual(month.to, "2026-03-31")
    }

    func testRemoteRangeUsesAPIWhenRuntimeAndCloudSessionAreAvailable() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = TrainingCalendarRouteAPIClientMock(
            response: WorkoutCalendarRemoteResponse(
                from: "2026-03-01",
                to: "2026-03-03",
                days: [
                    WorkoutCalendarRemoteDay(
                        date: "2026-03-02",
                        loggedCount: 1,
                        plannedCount: 2,
                        completedPlannedCount: 1,
                        totalDurationMinutes: 55,
                        totalTrimpScore: 73.5,
                        hasLoggedWorkout: true,
                        hasPlannedWorkout: true
                    )
                ]
            )
        )

        let days = try await TrainingCalendarLoader.loadRange(
            from: "2026-03-01",
            to: "2026-03-03",
            dbQueue: manager.dbQueue,
            apiClient: api,
            runtimeConfigured: { true },
            hasCloudSessionProvider: { true }
        )

        let requests = await api.requestSnapshot()
        XCTAssertEqual(requests.map(\.from), ["2026-03-01"])
        XCTAssertEqual(days, [
            TrainingCalendarDay(
                day: "2026-03-02",
                loggedCount: 1,
                plannedCount: 2,
                completedPlannedCount: 1,
                totalDurationMinutes: 55,
                totalTrimpScore: 73.5
            )
        ])
    }

    func testLocalFallbackEnumeratesRangeWhenNoLocalUserExists() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = TrainingCalendarRouteAPIClientMock()

        let days = try await TrainingCalendarLoader.loadRange(
            from: "2026-03-01",
            to: "2026-03-03",
            dbQueue: manager.dbQueue,
            apiClient: api,
            runtimeConfigured: { false },
            hasCloudSessionProvider: { true }
        )

        let requests = await api.requestSnapshot()
        XCTAssertEqual(requests.count, 0)
        XCTAssertEqual(days.map(\.day), ["2026-03-01", "2026-03-02", "2026-03-03"])
        XCTAssertTrue(days.allSatisfy { !$0.hasLoggedWorkout && !$0.hasPlannedWorkout })
        XCTAssertTrue(days.allSatisfy { $0.accessibilitySummary.contains(localized("training.calendar_rest_day")) })
    }

    func testLocalFallbackAggregatesWorkoutAndPlanRowsAndIgnoresDeletedSessions() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()

        try await manager.dbQueue.write { db in
            let user = User(id: userId, authId: authId, timezone: "UTC", units: .metric)
            try user.insert(db)

            try Self.insertWorkout(
                db,
                userId: userId,
                day: "2026-03-02",
                durationMinutes: 45,
                trimpScore: 52
            )
            try Self.insertWorkout(
                db,
                userId: userId,
                day: "2026-03-02",
                durationMinutes: 30,
                trimpScore: 31
            )
            try Self.insertWorkout(
                db,
                userId: userId,
                day: "2026-03-02",
                durationMinutes: 99,
                trimpScore: 120,
                deletedAt: Date()
            )
            try Self.insertWorkout(
                db,
                userId: userId,
                day: "2026-03-03",
                durationMinutes: 20,
                trimpScore: nil
            )

            let planId = UUID()
            let plan = TrainingPlan(
                id: planId,
                userId: userId,
                name: "March build",
                goal: .strength,
                planJson: Data("{}".utf8)
            )
            try plan.insert(db)

            try Self.insertPlanSession(db, planId: planId, userId: userId, day: "2026-03-02", status: .planned)
            try Self.insertPlanSession(db, planId: planId, userId: userId, day: "2026-03-02", status: .completed)
            try Self.insertPlanSession(db, planId: planId, userId: userId, day: "2026-03-03", status: .skipped)
        }

        AuthManager.setActiveAuthIdForTests(authId)

        let days = try await TrainingCalendarLoader.loadRange(
            from: "2026-03-01",
            to: "2026-03-04",
            dbQueue: manager.dbQueue,
            apiClient: TrainingCalendarRouteAPIClientMock(),
            runtimeConfigured: { true },
            hasCloudSessionProvider: { false }
        )

        XCTAssertEqual(days.map(\.day), ["2026-03-01", "2026-03-02", "2026-03-03", "2026-03-04"])

        let marchSecond = try XCTUnwrap(days.first { $0.day == "2026-03-02" })
        XCTAssertEqual(marchSecond.loggedCount, 2)
        XCTAssertEqual(marchSecond.plannedCount, 2)
        XCTAssertEqual(marchSecond.completedPlannedCount, 1)
        XCTAssertEqual(marchSecond.totalDurationMinutes, 75)
        XCTAssertEqual(marchSecond.totalTrimpScore, 83)
        XCTAssertTrue(marchSecond.hasLoggedWorkout)
        XCTAssertTrue(marchSecond.hasPlannedWorkout)

        let marchThird = try XCTUnwrap(days.first { $0.day == "2026-03-03" })
        XCTAssertEqual(marchThird.loggedCount, 1)
        XCTAssertEqual(marchThird.plannedCount, 1)
        XCTAssertEqual(marchThird.completedPlannedCount, 0)
        XCTAssertEqual(marchThird.totalDurationMinutes, 20)
        XCTAssertEqual(marchThird.totalTrimpScore, 0)

        let summary = TrainingCalendarWeekSummary(days: days)
        XCTAssertEqual(summary.loggedSessions, 3)
        XCTAssertEqual(summary.plannedSessions, 3)
        XCTAssertEqual(summary.completedPlannedSessions, 1)
        XCTAssertEqual(summary.totalDurationMinutes, 95)
        XCTAssertEqual(summary.totalTrimpScore, 83)
    }

    func testRemoteFailureFallsBackToLocalCalendar() async throws {
        struct ExpectedRemoteFailure: Error {}

        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()

        try await manager.dbQueue.write { db in
            let user = User(id: userId, authId: authId, timezone: "UTC", units: .metric)
            try user.insert(db)

            try Self.insertWorkout(
                db,
                userId: userId,
                day: "2026-03-02",
                durationMinutes: 40,
                trimpScore: 60
            )
        }

        AuthManager.setActiveAuthIdForTests(authId)
        let api = TrainingCalendarRouteAPIClientMock(error: ExpectedRemoteFailure())

        let days = try await TrainingCalendarLoader.loadRange(
            from: "2026-03-01",
            to: "2026-03-02",
            dbQueue: manager.dbQueue,
            apiClient: api,
            runtimeConfigured: { true },
            hasCloudSessionProvider: { true }
        )

        let requests = await api.requestSnapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(days.map(\.day), ["2026-03-01", "2026-03-02"])
        XCTAssertEqual(days.last?.loggedCount, 1)
        XCTAssertEqual(days.last?.totalDurationMinutes, 40)
        XCTAssertEqual(days.last?.totalTrimpScore, 60)
    }

    private nonisolated static func insertWorkout(
        _ db: Database,
        userId: UUID,
        day: String,
        durationMinutes: Int,
        trimpScore: Double?,
        deletedAt: Date? = nil
    ) throws {
        var session = WorkoutSession(
            userId: userId,
            startedAt: Date(timeIntervalSince1970: 1_772_553_600),
            sessionDate: day,
            source: .manual
        )
        session.durationMinutes = durationMinutes
        session.trimpScore = trimpScore
        session.deletedAt = deletedAt
        try session.insert(db)
    }

    private nonisolated static func insertPlanSession(
        _ db: Database,
        planId: UUID,
        userId: UUID,
        day: String,
        status: PlanSessionStatus
    ) throws {
        var session = TrainingPlanSession(
            trainingPlanId: planId,
            userId: userId,
            plannedDate: day,
            sessionType: .strength
        )
        session.status = status
        try session.insert(db)
    }
}
