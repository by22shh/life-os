import Foundation
import GRDB

enum SleepSyncHandler: SyncModuleHandler {
    static let ownedTables: [SyncableTable] = [
        .sleepLogs
    ]

    static func reconcileParentChild(in db: Database) throws {
        // Two devices may have created different UUIDs for the same morning.
        // Keep the authoritative source once after pull, then derive every UI's
        // state from that record rather than an independently imported duration.
        let records = try SleepLog.fetchAll(db, sql: """
            SELECT * FROM sleep_logs
            ORDER BY (source = 'manual') DESC, updated_at DESC,
                     (deleted_at IS NULL) DESC, created_at DESC
            """)
        var seen = Set<String>()
        for log in records {
            let day = log.sleepDate ?? log.date
            guard seen.insert("\(log.userId.uuidString)/\(day)").inserted else { continue }
            try SleepRecordSelection.supersedeOtherRecords(with: log, db: db)
            guard var state = try PhysiologicalState.fetchOne(db, sql: """
                SELECT * FROM physiological_states
                WHERE (user_id = ? OR user_id = ?) AND date = ? LIMIT 1
                """, arguments: [log.userId, log.userId.uuidString, day]) else { continue }
            SleepRecordSelection.applySleepFields(log.deletedAt == nil ? log : nil, to: &state)
            try state.update(db)
            let score = try RecoveryEngine.computeScore(userId: log.userId, date: day, db: db)
            state.recoveryScore = score.score
            state.recoveryZone = score.zone
            state.confidenceScore = score.confidence
            state.sleepScore = score.components.sleepScore
            state.sleepQualityPercent = score.components.sleepScore
            state.hrvScore = score.components.hrvScore
            state.rhrScore = score.components.rhrScore
            state.tempScore = score.components.tempScore
            try state.update(db)
        }
    }
}
