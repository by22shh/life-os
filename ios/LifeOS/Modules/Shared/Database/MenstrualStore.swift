// MARK: - Menstrual Store
// Privacy: Handles local-only persistence for menstrual data by default.
// When menstrual_local_only = false, mutations are pushed via the outbox pattern.

import Foundation
import GRDB

actor MenstrualStore {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue) {
        self.dbQueue = dbQueue
    }

    func saveLog(_ log: MenstrualLog) async throws {
        let authId = await MainActor.run { AuthManager.activeAuthId }
        try await dbQueue.write { db in
            try log.save(db)

            if Self.isSyncEnabled(db: db, authId: authId) {
                try Self.enqueueOutbox(db: db, log: log, method: .PUT)
            }
        }
    }

    /// Soft-delete: sets `deleted_at` instead of physically removing the row.
    func deleteLog(id: UUID) async throws {
        let authId = await MainActor.run { AuthManager.activeAuthId }
            try await dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE menstrual_logs
                    SET deleted_at = ?
                    WHERE (id = ? OR id = ?)
                      AND deleted_at IS NULL
                    """,
                arguments: [Date(), id, MixedUUIDStorage.encode(id)]
            )

            if Self.isSyncEnabled(db: db, authId: authId) {
                // Tombstone push so server can replicate the soft-delete.
                let payload: [String: Any] = ["id": id.uuidString, "deleted": true]
                let body = try JSONSerialization.data(withJSONObject: payload)
                var event = OutboxEvent(
                    httpMethod: .POST,
                    path: "api-menstrual-sync",
                    bodyJson: body,
                    priority: 80
                )
                event.idempotencyKey = "menstrual-delete-\(id.uuidString)"
                try event.insert(db)
            }
        }
    }

    func fetchLog(date: String) async throws -> MenstrualLog? {
        let authId = await MainActor.run { AuthManager.activeAuthId }
        return try await dbQueue.read { db in
            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId?.uuidString, db: db) else {
                return nil
            }

            return try Self.fetchLog(db: db, userId: userId, date: date)
        }
    }

    func fetchContext(date: String, historyLimit: Int = 12) async throws -> MenstrualTrackingContext {
        let authId = await MainActor.run { AuthManager.activeAuthId }
        return try await dbQueue.read { db in
            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId?.uuidString, db: db) else {
                return MenstrualTrackingContext(
                    userId: nil,
                    trackingEnabled: false,
                    syncEnabled: false,
                    currentLog: nil,
                    recentLogs: []
                )
            }

            let currentLog = try Self.fetchLog(db: db, userId: userId, date: date)
            let recentLogs = try Self.fetchRecentLogs(db: db, userId: userId, limit: historyLimit)
            let trackingEnabled = try Bool.fetchOne(
                db,
                sql: """
                    SELECT menstrual_tracking_enabled
                    FROM user_health_flags
                    WHERE (user_id = ? OR user_id = ?)
                    ORDER BY updated_at DESC
                    LIMIT 1
                    """,
                arguments: [userId, userId.uuidString]
            ) ?? false

            return MenstrualTrackingContext(
                userId: userId,
                trackingEnabled: trackingEnabled,
                syncEnabled: Self.isSyncEnabled(db: db, userId: userId),
                currentLog: currentLog,
                recentLogs: recentLogs
            )
        }
    }

    // MARK: - Sync Helpers

    /// Reads the `menstrual_local_only` privacy setting. Default: true (local-only).
    private static func isSyncEnabled(db: Database, authId: UUID?) -> Bool {
        guard let userId = try? UserIdentityLookup.resolveUserId(authId: authId?.uuidString, db: db) else {
            return false
        }
        return isSyncEnabled(db: db, userId: userId)
    }

    private static func isSyncEnabled(db: Database, userId: UUID) -> Bool {
        let localOnly = try? Bool.fetchOne(db, sql: """
            SELECT menstrual_local_only
            FROM privacy_settings
            WHERE user_id = ? OR user_id = ?
            ORDER BY updated_at DESC
            LIMIT 1
            """, arguments: [userId, userId.uuidString])
        return !(localOnly ?? true)
    }

    private static func fetchLog(db: Database, userId: UUID, date: String) throws -> MenstrualLog? {
        try MenstrualLog.fetchOne(
            db,
            sql: """
                SELECT *
                FROM menstrual_logs
                WHERE (user_id = ? OR user_id = ?)
                  AND date = ?
                  AND deleted_at IS NULL
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString, date]
        )
    }

    private static func fetchRecentLogs(db: Database, userId: UUID, limit: Int) throws -> [MenstrualLog] {
        try MenstrualLog.fetchAll(
            db,
            sql: """
                SELECT *
                FROM menstrual_logs
                WHERE (user_id = ? OR user_id = ?)
                  AND deleted_at IS NULL
                ORDER BY date DESC, updated_at DESC
                LIMIT ?
                """,
            arguments: [userId, userId.uuidString, max(limit, 1)]
        )
    }

    private static func enqueueOutbox(db: Database, log: MenstrualLog, method: HTTPMethod) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(log)
        var event = OutboxEvent(
            httpMethod: method,
            path: "api-menstrual-sync",
            bodyJson: body,
            priority: 80
        )
        event.idempotencyKey = "menstrual-\(log.id.uuidString)-\(ISO8601DateFormatter.supabaseString(from: Date()))"
        try event.insert(db)
    }
}

struct MenstrualTrackingContext: Sendable, Equatable {
    let userId: UUID?
    let trackingEnabled: Bool
    let syncEnabled: Bool
    let currentLog: MenstrualLog?
    let recentLogs: [MenstrualLog]
}
