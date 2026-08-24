import Foundation
import XCTest
@testable import LifeOS

@MainActor
final class WatchSnapshotFallbackTests: XCTestCase {
    override func tearDown() {
        APIClient._testResetOverrides()
        AuthManager.setActiveAuthIdForTests(nil)
        super.tearDown()
    }

    func testPushLatestSnapshotWithLocalFallbackBuildsFromLocalStoreWhenServerFails() async throws {
        let manager = WatchSyncManager()
        let dbManager = try DatabaseManager.inMemory()
        let syncEngine = SyncEngine(dbQueue: dbManager.dbQueue)
        let authId = UUID()
        let userId = UUID()
        let now = Date()
        let today = "2026-03-16"

        AuthManager.setActiveAuthIdForTests(authId)
        APIClient._testSetEdgeInvokeOverride { _, _ in
            struct ExpectedError: Error {}
            throw ExpectedError()
        }

        try await dbManager.dbQueue.write { db in
            var user = User(id: userId, authId: authId, timezone: "UTC")
            user.onboardingCompleted = true
            user.createdAt = now
            user.updatedAt = now
            try user.insert(db)

            var state = PhysiologicalState(userId: userId, date: today, recoveryScore: 72)
            state.createdAt = now
            state.updatedAt = now
            state.confidenceScore = 0.91
            state.sleepDurationHours = 7.4
            state.sleepQualityPercent = 86
            try state.insert(db)
        }

        let source = await manager.pushLatestSnapshotWithLocalFallback(
            date: today,
            syncEngine: syncEngine,
            now: now
        )

        let pushed = try XCTUnwrap(manager._testLastPushedSnapshot())
        XCTAssertEqual(source, .local)
        XCTAssertEqual(pushed.date, today)
        XCTAssertEqual(try XCTUnwrap(pushed.recoveryScore), 72, accuracy: 0.0001)
        XCTAssertEqual(pushed.recoveryZone, RecoveryZone.ready.rawValue)
        XCTAssertEqual(try XCTUnwrap(pushed.confidenceScore), 0.91, accuracy: 0.0001)
    }
}
