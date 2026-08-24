import XCTest
@testable import LifeOS
import GRDB

final class PerformanceBudgetTests: XCTestCase {

    func testBudgetConstantsMatchBlueprint() {
        XCTAssertEqual(PerformanceMonitor.coldLaunchBudgetMs, 2_000)
        XCTAssertEqual(PerformanceMonitor.warmLaunchBudgetMs, 500)
        XCTAssertEqual(PerformanceMonitor.diaryLoadBudgetMs, 200)
        XCTAssertEqual(PerformanceMonitor.localQueryBudgetMs, 50)

        XCTAssertTrue(PerformanceMonitor.isWithinColdLaunchBudget(1_999))
        XCTAssertFalse(PerformanceMonitor.isWithinColdLaunchBudget(2_001))
        XCTAssertTrue(PerformanceMonitor.isWithinWarmLaunchBudget(499))
        XCTAssertFalse(PerformanceMonitor.isWithinWarmLaunchBudget(501))
    }

    func testLocalQueryFitsBudgetOnInMemoryDatabase() throws {
        let manager = try DatabaseManager.inMemory()

        let start = Date()
        _ = try manager.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM food_logs")
        }
        let elapsedMs = Date().timeIntervalSince(start) * 1000

        XCTAssertTrue(
            PerformanceMonitor.isWithinLocalQueryBudget(elapsedMs),
            "Local query exceeded budget: \(elapsedMs)ms"
        )
    }

    @MainActor
    func testDiaryRefreshFitsBudgetOnInMemoryDatabase() async throws {
        let manager = try DatabaseManager.inMemory()
        let viewModel = DiaryViewModel(dbQueue: manager.dbQueue)

        let start = Date()
        await viewModel.refresh(for: Date())
        let elapsedMs = Date().timeIntervalSince(start) * 1000

        XCTAssertTrue(
            PerformanceMonitor.isWithinDiaryLoadBudget(elapsedMs),
            "Diary load exceeded budget: \(elapsedMs)ms"
        )
    }

    func testPerformanceMonitorTrackingPathsDoNotCrash() {
        // Cold launch end without start (nil-start guard path).
        PerformanceMonitor.trackColdLaunchEnd()

        // Cold launch normal path.
        PerformanceMonitor.trackColdLaunchStart()
        PerformanceMonitor.trackColdLaunchEnd()

        // Cold launch budget-exceeded path.
        PerformanceMonitor.trackColdLaunchStart()
        Thread.sleep(forTimeInterval: 2.05)
        PerformanceMonitor.trackColdLaunchEnd()

        // Warm launch end without start (nil-start guard path).
        PerformanceMonitor.trackWarmLaunchEnd()

        // Warm launch normal path.
        PerformanceMonitor.trackWarmLaunchStart()
        PerformanceMonitor.trackWarmLaunchEnd()

        // Warm launch budget-exceeded path.
        PerformanceMonitor.trackWarmLaunchStart()
        Thread.sleep(forTimeInterval: 0.55)
        PerformanceMonitor.trackWarmLaunchEnd()

        // Direct warm launch reporting paths.
        PerformanceMonitor.trackWarmLaunch(durationMs: 100)
        PerformanceMonitor.trackWarmLaunch(durationMs: 700)

        // Warm launch without duration: no pending and pending branches.
        PerformanceMonitor.trackWarmLaunch()
        PerformanceMonitor.trackWarmLaunchStart()
        PerformanceMonitor.trackWarmLaunch()

        // Diary and local query budget branches.
        PerformanceMonitor.trackDiaryLoad(durationMs: 100)
        PerformanceMonitor.trackDiaryLoad(durationMs: 300)
        PerformanceMonitor.trackLocalQuery(durationMs: 10, label: "fast_query")
        PerformanceMonitor.trackLocalQuery(durationMs: 60, label: "slow_query")
    }
}
