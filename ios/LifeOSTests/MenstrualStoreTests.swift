import Foundation
import GRDB
import XCTest
@testable import LifeOS

final class MenstrualStoreTests: XCTestCase {

    private static func seedUser(
        db: Database,
        userId: UUID,
        authId: UUID
    ) throws {
        var user = User(id: userId, authId: authId, timezone: "UTC", units: .metric)
        try user.insert(db)
    }

    private static func seedUserAndPrivacy(
        db: Database,
        userId: UUID,
        authId: UUID,
        menstrualLocalOnly: Bool
    ) throws {
        try seedUser(db: db, userId: userId, authId: authId)

        var settings = PrivacySettings(userId: userId)
        settings.menstrualLocalOnly = menstrualLocalOnly
        try settings.insert(db)
    }

    func testSaveAndDeleteLogEnqueueOutboxWhenSyncEnabled() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let store = MenstrualStore(dbQueue: manager.dbQueue)

        try await manager.dbQueue.write { db in
            try Self.seedUserAndPrivacy(
                db: db,
                userId: userId,
                authId: authId,
                menstrualLocalOnly: false
            )
        }

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
        }

        let log = MenstrualLog(
            userId: userId,
            date: "2026-02-24",
            flow: .light,
            painLevel: 1
        )

        try await store.saveLog(log)
        let fetched = try await store.fetchLog(date: "2026-02-24")
        XCTAssertEqual(fetched?.id, log.id)

        let outboxCountAfterSave = try await manager.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox_events") ?? 0
        }
        XCTAssertEqual(outboxCountAfterSave, 1)

        try await store.deleteLog(id: log.id)

        let deletedAtExists = try await manager.dbQueue.read { db in
            try Date.fetchOne(
                db,
                sql: "SELECT deleted_at FROM menstrual_logs WHERE id = ?",
                arguments: [log.id.uuidString]
            ) != nil
        }
        XCTAssertTrue(deletedAtExists)

        let outboxCountAfterDelete = try await manager.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox_events") ?? 0
        }
        XCTAssertEqual(outboxCountAfterDelete, 2)

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(nil)
        }
    }

    func testSaveLogSkipsOutboxWhenLocalOnlyEnabled() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let store = MenstrualStore(dbQueue: manager.dbQueue)

        try await manager.dbQueue.write { db in
            try Self.seedUserAndPrivacy(
                db: db,
                userId: userId,
                authId: authId,
                menstrualLocalOnly: true
            )
        }

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
        }

        try await store.saveLog(
            MenstrualLog(userId: userId, date: "2026-02-24", flow: .medium, painLevel: 2)
        )

        let outboxCount = try await manager.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox_events") ?? 0
        }
        XCTAssertEqual(outboxCount, 0)

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(nil)
        }
    }

    func testSaveLogSkipsOutboxWhenPrivacySettingsMissing() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let store = MenstrualStore(dbQueue: manager.dbQueue)

        try await manager.dbQueue.write { db in
            try Self.seedUser(db: db, userId: userId, authId: authId)
        }

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
        }

        try await store.saveLog(
            MenstrualLog(userId: userId, date: "2026-02-24", flow: .medium, painLevel: 2)
        )

        let outboxCount = try await manager.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox_events") ?? 0
        }
        XCTAssertEqual(outboxCount, 0)

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(nil)
        }
    }

    func testFetchLogReturnsNilWithoutActiveAuth() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let store = MenstrualStore(dbQueue: manager.dbQueue)

        try await manager.dbQueue.write { db in
            try Self.seedUserAndPrivacy(
                db: db,
                userId: userId,
                authId: authId,
                menstrualLocalOnly: false
            )
        }

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(nil)
        }

        let log = MenstrualLog(userId: userId, date: "2026-02-24")
        try await store.saveLog(log)
        let fetched = try await store.fetchLog(date: "2026-02-24")
        XCTAssertNil(fetched)
    }

    func testDeleteLogMatchesLegacyTextBackedIdentifier() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let logId = UUID()
        let now = Date()
        let store = MenstrualStore(dbQueue: manager.dbQueue)

        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    userId.uuidString,
                    authId.uuidString,
                    "UTC",
                    "metric",
                    now,
                    now
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO privacy_settings (
                        id, user_id, menstrual_local_only, medical_scan_local_only,
                        cloud_backup_enabled, vector_opt_in, analytics_consent, cloud_ocr_enabled,
                        created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    false,
                    false,
                    false,
                    false,
                    false,
                    false,
                    now,
                    now
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO menstrual_logs (
                        id, user_id, date, flow, pain_level, deleted_at, created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    logId.uuidString,
                    userId.uuidString,
                    "2026-02-24",
                    MenstrualFlow.medium.rawValue,
                    2,
                    nil,
                    now,
                    now
                ]
            )
        }

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
        }

        try await store.deleteLog(id: logId)

        let deletedAtExists = try await manager.dbQueue.read { db in
            try Date.fetchOne(
                db,
                sql: """
                    SELECT deleted_at
                    FROM menstrual_logs
                    WHERE id = ? OR id = ?
                    """,
                arguments: [logId, logId.uuidString]
            ) != nil
        }
        XCTAssertTrue(deletedAtExists)

        let outboxCount = try await manager.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?", arguments: ["api-menstrual-sync"]) ?? 0
        }
        XCTAssertEqual(outboxCount, 1)

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(nil)
        }
    }

    func testFetchContextReturnsTrackingStateCurrentLogAndHistory() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let store = MenstrualStore(dbQueue: manager.dbQueue)

        try await manager.dbQueue.write { db in
            try Self.seedUserAndPrivacy(
                db: db,
                userId: userId,
                authId: authId,
                menstrualLocalOnly: false
            )

            var flags = UserHealthFlags(userId: userId)
            flags.menstrualTrackingEnabled = true
            try flags.insert(db)

            try MenstrualLog(userId: userId, date: "2026-02-24", flow: .heavy, painLevel: 4).insert(db)
            try MenstrualLog(userId: userId, date: "2026-02-20", flow: .light, painLevel: 1).insert(db)
        }

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
        }

        let context = try await store.fetchContext(date: "2026-02-24", historyLimit: 12)
        XCTAssertEqual(context.userId, userId)
        XCTAssertTrue(context.trackingEnabled)
        XCTAssertTrue(context.syncEnabled)
        XCTAssertEqual(context.currentLog?.date, "2026-02-24")
        XCTAssertEqual(context.currentLog?.flow, .heavy)
        XCTAssertEqual(context.recentLogs.map(\.date), ["2026-02-24", "2026-02-20"])

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(nil)
        }
    }

    func testFetchContextDefaultsWhenFlagsAreMissingOrLocalOnly() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let store = MenstrualStore(dbQueue: manager.dbQueue)

        try await manager.dbQueue.write { db in
            try Self.seedUserAndPrivacy(
                db: db,
                userId: userId,
                authId: authId,
                menstrualLocalOnly: true
            )
            try MenstrualLog(userId: userId, date: "2026-02-24", flow: .medium, painLevel: 2).insert(db)
        }

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
        }

        let context = try await store.fetchContext(date: "2026-02-24")
        XCTAssertEqual(context.userId, userId)
        XCTAssertFalse(context.trackingEnabled)
        XCTAssertFalse(context.syncEnabled)
        XCTAssertEqual(context.currentLog?.date, "2026-02-24")

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(nil)
        }
    }
}
