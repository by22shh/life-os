import XCTest
@testable import LifeOS
import GRDB

final class MenstrualCycleAdjustmentTests: XCTestCase {

    var manager: DatabaseManager!

    override func setUp() async throws {
        manager = try DatabaseManager.inMemory()
    }

    // MARK: - Phase derivation

    func testDerivePhaseRequiresTwoPeriodStarts() {
        XCTAssertNil(
            MenstrualCycleAdjustment.derivePhase(
                flowDates: ["2026-02-01", "2026-02-02"],
                on: "2026-02-10"
            )
        )
    }

    func testDerivePhaseScalesToRecordedCycleLength() throws {
        let flowDates = ["2026-01-01", "2026-01-29", "2026-02-26"]

        let menstrual = try XCTUnwrap(
            MenstrualCycleAdjustment.derivePhase(flowDates: flowDates, on: "2026-02-27")
        )
        XCTAssertEqual(menstrual.phase, .menstrual)
        XCTAssertEqual(menstrual.cycleDay, 2)
        XCTAssertEqual(menstrual.cycleLength, 28)

        let follicular = try XCTUnwrap(
            MenstrualCycleAdjustment.derivePhase(flowDates: flowDates, on: "2026-03-05")
        )
        XCTAssertEqual(follicular.phase, .follicular)

        let ovulation = try XCTUnwrap(
            MenstrualCycleAdjustment.derivePhase(flowDates: flowDates, on: "2026-03-12")
        )
        XCTAssertEqual(ovulation.phase, .ovulation)

        let luteal = try XCTUnwrap(
            MenstrualCycleAdjustment.derivePhase(flowDates: flowDates, on: "2026-03-17")
        )
        XCTAssertEqual(luteal.phase, .luteal)

        let late = try XCTUnwrap(
            MenstrualCycleAdjustment.derivePhase(flowDates: flowDates, on: "2026-04-05")
        )
        XCTAssertEqual(late.phase, .luteal)
        XCTAssertNil(late.cycleDay, "late cycles should not claim a cycle day")
    }

    func testPeriodStartsIgnoreConsecutiveBleedingDays() {
        let starts = MenstrualCycleAdjustment.periodStarts(
            from: ["2026-01-01", "2026-01-02", "2026-01-03", "2026-01-29", "2026-01-30"]
        )
        XCTAssertEqual(starts.sorted(), ["2026-01-01", "2026-01-29"])
    }

    // MARK: - Recovery integration

    func testRecoveryScoreAppliesLutealCompensationAndAdjustment() async throws {
        let userId = UUID()
        try await insertUser(userId)
        try await insertBaselineStates(userId: userId)

        // No tracking record: raw score from a 0.5°C deviation.
        let untracked = try await manager.dbQueue.read { db in
            try RecoveryEngine.computeScore(userId: userId, date: Self.today, db: db)
        }
        XCTAssertNil(untracked.menstrualPhase)
        XCTAssertEqual(untracked.components.tempScore ?? -1, 70, accuracy: 0.1)

        try await setMenstrualTracking(userId: userId, enabled: true)
        try await insertMenstrualLogs(userId: userId, dates: ["2026-01-14", "2026-02-11"])

        let luteal = try await manager.dbQueue.read { db in
            try RecoveryEngine.computeScore(userId: userId, date: Self.today, db: db)
        }
        XCTAssertEqual(luteal.menstrualPhase, MenstrualPhase.luteal.rawValue)
        XCTAssertEqual(luteal.menstrualAdjustment, 5)
        // Luteal compensation removes the expected 0.3°C rise, so the
        // temperature component reads 100 and the score is clamped at 100.
        XCTAssertEqual(luteal.components.tempScore ?? -1, 100, accuracy: 0.1)
        XCTAssertEqual(luteal.score, 100, accuracy: 0.1)
    }

    func testRecoveryScoreAppliesMenstrualAdjustment() async throws {
        let userId = UUID()
        try await insertUser(userId)
        try await insertBaselineStates(userId: userId)
        try await setMenstrualTracking(userId: userId, enabled: true)
        try await insertMenstrualLogs(userId: userId, dates: ["2026-02-05", "2026-03-05"])

        let menstrual = try await manager.dbQueue.read { db in
            try RecoveryEngine.computeScore(userId: userId, date: Self.today, db: db)
        }
        XCTAssertEqual(menstrual.menstrualPhase, MenstrualPhase.menstrual.rawValue)
        XCTAssertEqual(menstrual.menstrualAdjustment, 3)
        XCTAssertEqual(menstrual.components.tempScore ?? -1, 70, accuracy: 0.1)
        XCTAssertEqual(menstrual.score, 73, accuracy: 0.1)
    }

    // MARK: - Fixtures

    private static let today = "2026-03-06"

    private func insertUser(_ id: UUID) async throws {
        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, created_at, updated_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [id.uuidString, UUID().uuidString, Date(), Date()]
            )
        }
    }

    private func insertBaselineStates(userId: UUID) async throws {
        try await manager.dbQueue.write { db in
            for day in 1...5 {
                let date = String(format: "2026-03-%02d", day)
                try db.execute(
                    sql: """
                        INSERT INTO physiological_states
                            (id, user_id, date, wrist_temperature_deviation_c,
                             recovery_score, recovery_zone, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        UUID().uuidString,
                        userId.uuidString,
                        date,
                        0.0,
                        50,
                        RecoveryZone.ready.rawValue,
                        Date(),
                        Date()
                    ]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO physiological_states
                        (id, user_id, date, wrist_temperature_deviation_c,
                         recovery_score, recovery_zone, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    Self.today,
                    0.5,
                    50,
                    RecoveryZone.ready.rawValue,
                    Date(),
                    Date()
                ]
            )
        }
    }

    private func setMenstrualTracking(userId: UUID, enabled: Bool) async throws {
        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO user_health_flags
                        (id, user_id, menstrual_tracking_enabled, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [UUID().uuidString, userId.uuidString, enabled, Date(), Date()]
            )
        }
    }

    private func insertMenstrualLogs(userId: UUID, dates: [String]) async throws {
        try await manager.dbQueue.write { db in
            for date in dates {
                try db.execute(
                    sql: """
                        INSERT INTO menstrual_logs
                            (id, user_id, date, flow, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        UUID().uuidString,
                        userId.uuidString,
                        date,
                        MenstrualFlow.medium.rawValue,
                        Date(),
                        Date()
                    ]
                )
            }
        }
    }
}
