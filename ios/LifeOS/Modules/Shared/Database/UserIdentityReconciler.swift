import Foundation
import GRDB

private protocol UserScopedSyncRecord: FetchableRecord, PersistableRecord {
    static var databaseTableName: String { get }
    var id: UUID { get }
    var userId: UUID { get set }
    var createdAt: Date { get set }
    var updatedAt: Date { get set }
}

extension NotificationSettings: UserScopedSyncRecord {}
extension UserHealthFlags: UserScopedSyncRecord {}
extension OnboardingState: UserScopedSyncRecord {}
extension UserBaseline: UserScopedSyncRecord {}
extension PrivacySettings: UserScopedSyncRecord {}
extension PhysiologicalState: UserScopedSyncRecord {}
extension DailyNutritionTarget: UserScopedSyncRecord {}
extension UserFoodFavorite: UserScopedSyncRecord {}
extension TrainingLoad: UserScopedSyncRecord {}
extension WellnessCheck: UserScopedSyncRecord {}
extension WeeklyStrategyReport: UserScopedSyncRecord {}

enum UserIdentityReconciler {
    private static let singletonUserTables: Set<String> = [
        NotificationSettings.databaseTableName,
        UserHealthFlags.databaseTableName,
        OnboardingState.databaseTableName,
        UserBaseline.databaseTableName,
        PrivacySettings.databaseTableName,
    ]

    private static let keyedUserTables: Set<String> = [
        PhysiologicalState.databaseTableName,
        DailyNutritionTarget.databaseTableName,
        UserFoodFavorite.databaseTableName,
        TrainingLoad.databaseTableName,
        WellnessCheck.databaseTableName,
        WeeklyStrategyReport.databaseTableName,
    ]

    private static let userReferenceColumns: [String] = [
        "user_id",
        "user_id_deleted",
        "created_by_user_id",
        "created_by",
    ]

    @discardableResult
    static func reconcileAuthenticatedIdentity(
        authId: UUID,
        email: String?,
        offlineAuthId: UUID?,
        db: Database,
        now: Date = Date()
    ) throws -> User {
        let targetUsers = try fetchUsers(authId: authId, db: db)
        let offlineSourceUser: User?
        if let offlineAuthId, offlineAuthId != authId {
            offlineSourceUser = try fetchPreferredUser(authId: offlineAuthId, db: db)
        } else {
            offlineSourceUser = nil
        }

        if let canonicalTarget = try chooseCanonicalUser(from: targetUsers, db: db) {
            var mergedUser = mergeUsers(
                canonicalBase: canonicalTarget,
                relatedUsers: targetUsers.filter { $0.id != canonicalTarget.id } + (offlineSourceUser.map { [$0] } ?? []),
                explicitEmail: email,
                preferRelatedPrimary: true
            )
            mergedUser.authId = authId
            mergedUser.updatedAt = max(mergedUser.updatedAt, now)
            try mergedUser.save(db)

            let duplicateIds = Set(
                targetUsers.map(\.id).filter { $0 != canonicalTarget.id } +
                (offlineSourceUser.map { [$0.id] } ?? []).filter { $0 != canonicalTarget.id }
            )
            for duplicateId in duplicateIds {
                try mergeUserReferences(from: duplicateId, into: canonicalTarget.id, db: db)
            }

            return mergedUser
        }

        if var offlineSourceUser {
            offlineSourceUser.authId = authId
            if let normalizedEmail = normalizedEmail(email) {
                offlineSourceUser.email = normalizedEmail
            }
            offlineSourceUser.updatedAt = max(offlineSourceUser.updatedAt, now)
            try offlineSourceUser.save(db)
            return offlineSourceUser
        }

        var user = User(id: authId, authId: authId)
        if let normalizedEmail = normalizedEmail(email) {
            user.email = normalizedEmail
        }
        user.createdAt = now
        user.updatedAt = now
        try user.save(db)
        return user
    }

    @discardableResult
    static func reconcileCloudAuthenticatedIdentity(
        authId: UUID,
        email: String?,
        offlineAuthId: UUID?,
        db: Database,
        now: Date = Date()
    ) throws -> User {
        let reconciledUser = try reconcileAuthenticatedIdentity(
            authId: authId,
            email: email,
            offlineAuthId: offlineAuthId,
            db: db,
            now: now
        )

        let canonicalUser: User
        if reconciledUser.id == authId {
            canonicalUser = reconciledUser
        } else {
            canonicalUser = try reconcileCanonicalUser(
                makeCloudCanonicalUser(
                    from: reconciledUser,
                    authId: authId,
                    email: email,
                    now: now
                ),
                db: db,
                updateSyncMirror: false
            )
        }

        return canonicalUser
    }

    @discardableResult
    static func reconcilePulledServerUser(_ serverUser: User, db: Database) throws -> User {
        try reconcileCanonicalUser(
            serverUser,
            db: db,
            updateSyncMirror: true
        )
    }

    static func hasLocalUser(authId: UUID, db: Database) throws -> Bool {
        try fetchPreferredUser(authId: authId, db: db) != nil
    }

    static func preferredLocalUser(authId: UUID, db: Database) throws -> User? {
        try fetchPreferredUser(authId: authId, db: db)
    }

    private static func mergeUserReferences(from sourceUserId: UUID, into targetUserId: UUID, db: Database) throws {
        guard sourceUserId != targetUserId else { return }

        try mergeNotificationSettings(sourceUserId: sourceUserId, targetUserId: targetUserId, db: db)
        try mergeUserHealthFlags(sourceUserId: sourceUserId, targetUserId: targetUserId, db: db)
        try mergeOnboardingState(sourceUserId: sourceUserId, targetUserId: targetUserId, db: db)
        try mergeUserBaselines(sourceUserId: sourceUserId, targetUserId: targetUserId, db: db)
        try mergePrivacySettings(sourceUserId: sourceUserId, targetUserId: targetUserId, db: db)
        try mergePhysiologicalStates(sourceUserId: sourceUserId, targetUserId: targetUserId, db: db)
        try mergeDailyNutritionTargets(sourceUserId: sourceUserId, targetUserId: targetUserId, db: db)
        try mergeUserFoodFavorites(sourceUserId: sourceUserId, targetUserId: targetUserId, db: db)
        try mergeTrainingLoads(sourceUserId: sourceUserId, targetUserId: targetUserId, db: db)
        try mergeWellnessChecks(sourceUserId: sourceUserId, targetUserId: targetUserId, db: db)
        try mergeWeeklyStrategyReports(sourceUserId: sourceUserId, targetUserId: targetUserId, db: db)

        try updateGenericUserReferences(from: sourceUserId, to: targetUserId, db: db)
        try rewritePendingOutboxUserReferences(from: sourceUserId, to: targetUserId, db: db)
        try migrateUserSyncMirror(from: sourceUserId, to: targetUserId, db: db)
        try db.execute(
            sql: """
                DELETE FROM users
                WHERE id = ? OR lower(CAST(id AS TEXT)) = lower(?)
                """,
            arguments: [sourceUserId, sourceUserId.uuidString]
        )
    }

    private static func mergeNotificationSettings(sourceUserId: UUID, targetUserId: UUID, db: Database) throws {
        try mergeSingletonRecords(
            NotificationSettings.self,
            sourceUserId: sourceUserId,
            targetUserId: targetUserId,
            db: db
        ) { records in
            guard !records.isEmpty else { return nil }
            let freshest = freshestRecord(in: records)
            var merged = rebasedRecord(freshest, records: records, targetUserId: targetUserId)
            merged = merged.normalizedForInvariants()
            return merged
        }
    }

    private static func mergeUserHealthFlags(sourceUserId: UUID, targetUserId: UUID, db: Database) throws {
        try mergeSingletonRecords(
            UserHealthFlags.self,
            sourceUserId: sourceUserId,
            targetUserId: targetUserId,
            db: db
        ) { records in
            guard !records.isEmpty else { return nil }
            let freshest = freshestRecord(in: records)
            var merged = rebasedRecord(freshest, records: records, targetUserId: targetUserId)
            merged.refreshDerivedFlags()
            return merged
        }
    }

    private static func mergeOnboardingState(sourceUserId: UUID, targetUserId: UUID, db: Database) throws {
        try mergeSingletonRecords(
            OnboardingState.self,
            sourceUserId: sourceUserId,
            targetUserId: targetUserId,
            db: db
        ) { records in
            let orderedByProgress = records.sorted(by: { lhs, rhs in
                if lhs.step.progressionRank != rhs.step.progressionRank {
                    return lhs.step.progressionRank > rhs.step.progressionRank
                }
                return compareFreshness(lhs.updatedAt, lhs.createdAt, lhs.id, rhs.updatedAt, rhs.createdAt, rhs.id)
            })
            guard let winner = orderedByProgress.first else {
                return nil
            }

            var merged = rebasedRecord(winner, records: records, targetUserId: targetUserId)
            merged.step = winner.step
            merged.completedAt = records.compactMap(\.completedAt).max()
            merged.updatedAt = records.map(\.updatedAt).max() ?? merged.updatedAt
            return merged
        }
    }

    private static func mergeUserBaselines(sourceUserId: UUID, targetUserId: UUID, db: Database) throws {
        try mergeSingletonRecords(
            UserBaseline.self,
            sourceUserId: sourceUserId,
            targetUserId: targetUserId,
            db: db
        ) { records in
            let ordered = records.sorted(by: fresherRecord)
            guard var merged = ordered.first else { return nil }
            merged.userId = targetUserId
            merged.createdAt = records.map(\.createdAt).min() ?? merged.createdAt
            merged.updatedAt = records.map(\.updatedAt).max() ?? merged.updatedAt
            merged.hrvLnRmssdBaseline = pickFirstNonNil(ordered, value: \.hrvLnRmssdBaseline)
            merged.rhrBaseline = pickFirstNonNil(ordered, value: \.rhrBaseline)
            merged.sleepBaselineHours = pickFirstNonNil(ordered, value: \.sleepBaselineHours)
            merged.dataDaysAvailable = records.map(\.dataDaysAvailable).max() ?? merged.dataDaysAvailable
            merged.baselineConfidence = records.map(\.baselineConfidence).max() ?? merged.baselineConfidence
            merged.lastComputedAt = records.map(\.lastComputedAt).max() ?? merged.lastComputedAt
            return merged
        }
    }

    private static func mergePrivacySettings(sourceUserId: UUID, targetUserId: UUID, db: Database) throws {
        try mergeSingletonRecords(
            PrivacySettings.self,
            sourceUserId: sourceUserId,
            targetUserId: targetUserId,
            db: db
        ) {
            rebasedRecord(freshestRecord(in: $0), records: $0, targetUserId: targetUserId)
        }
    }

    private static func mergePhysiologicalStates(sourceUserId: UUID, targetUserId: UUID, db: Database) throws {
        try mergeKeyedRecords(
            PhysiologicalState.self,
            sourceUserId: sourceUserId,
            targetUserId: targetUserId,
            db: db,
            keyPath: \.date
        )
    }

    private static func mergeDailyNutritionTargets(sourceUserId: UUID, targetUserId: UUID, db: Database) throws {
        try mergeKeyedRecords(
            DailyNutritionTarget.self,
            sourceUserId: sourceUserId,
            targetUserId: targetUserId,
            db: db,
            keyPath: \.date
        )
    }

    private static func mergeUserFoodFavorites(sourceUserId: UUID, targetUserId: UUID, db: Database) throws {
        try mergeKeyedRecords(UserFoodFavorite.self, sourceUserId: sourceUserId, targetUserId: targetUserId, db: db) {
            "\($0.refType.rawValue)|\($0.refId.uuidString.lowercased())"
        }
    }

    private static func mergeTrainingLoads(sourceUserId: UUID, targetUserId: UUID, db: Database) throws {
        try mergeKeyedRecords(
            TrainingLoad.self,
            sourceUserId: sourceUserId,
            targetUserId: targetUserId,
            db: db,
            keyPath: \.date
        )
    }

    private static func mergeWellnessChecks(sourceUserId: UUID, targetUserId: UUID, db: Database) throws {
        try mergeKeyedRecords(
            WellnessCheck.self,
            sourceUserId: sourceUserId,
            targetUserId: targetUserId,
            db: db,
            keyPath: \.date
        )
    }

    private static func mergeWeeklyStrategyReports(sourceUserId: UUID, targetUserId: UUID, db: Database) throws {
        try mergeKeyedRecords(
            WeeklyStrategyReport.self,
            sourceUserId: sourceUserId,
            targetUserId: targetUserId,
            db: db,
            keyPath: \.weekStart
        )
    }

    private static func mergeSingletonRecords<Record: UserScopedSyncRecord>(
        _: Record.Type,
        sourceUserId: UUID,
        targetUserId: UUID,
        db: Database,
        merge: ([Record]) -> Record?
    ) throws {
        let records = try fetchUserScopedRecords(
            Record.self,
            sourceUserId: sourceUserId,
            targetUserId: targetUserId,
            db: db
        )
        guard !records.isEmpty else { return }
        guard let merged = merge(records) else { return }

        let keptId = merged.id
        try deleteRecords(for: Record.self, sourceUserId: sourceUserId, targetUserId: targetUserId, db: db)
        try merged.save(db)

        let removedIds = records.map(\.id).filter { $0 != keptId }
        try deleteSyncMirrors(tableName: Record.databaseTableName, rowIds: removedIds, db: db)
    }

    private static func mergeKeyedRecords<Record: UserScopedSyncRecord, Key: Hashable>(
        _: Record.Type,
        sourceUserId: UUID,
        targetUserId: UUID,
        db: Database,
        key: (Record) -> Key
    ) throws {
        let records = try fetchUserScopedRecords(
            Record.self,
            sourceUserId: sourceUserId,
            targetUserId: targetUserId,
            db: db
        )
        guard !records.isEmpty else { return }

        let grouped = Dictionary(grouping: records, by: key)
        let mergedRecords = grouped.values.map { group -> Record in
            let freshest = freshestRecord(in: group)
            return rebasedRecord(freshest, records: group, targetUserId: targetUserId)
        }

        let keptIds = Set(mergedRecords.map(\.id))
        try deleteRecords(for: Record.self, sourceUserId: sourceUserId, targetUserId: targetUserId, db: db)
        for record in mergedRecords {
            try record.save(db)
        }

        let removedIds = records.map(\.id).filter { !keptIds.contains($0) }
        try deleteSyncMirrors(tableName: Record.databaseTableName, rowIds: removedIds, db: db)
    }

    private static func mergeKeyedRecords<Record: UserScopedSyncRecord, Key: Hashable>(
        _ recordType: Record.Type,
        sourceUserId: UUID,
        targetUserId: UUID,
        db: Database,
        keyPath: KeyPath<Record, Key>
    ) throws {
        try mergeKeyedRecords(
            recordType,
            sourceUserId: sourceUserId,
            targetUserId: targetUserId,
            db: db
        ) { $0[keyPath: keyPath] }
    }

    private static func fetchUserScopedRecords<Record: UserScopedSyncRecord>(
        _: Record.Type,
        sourceUserId: UUID,
        targetUserId: UUID,
        db: Database
    ) throws -> [Record] {
        try Record.fetchAll(
            db,
            sql: """
                SELECT *
                FROM \(quotedIdentifier(Record.databaseTableName))
                WHERE user_id = ? OR lower(CAST(user_id AS TEXT)) = lower(?)
                   OR user_id = ? OR lower(CAST(user_id AS TEXT)) = lower(?)
                ORDER BY updated_at DESC, created_at DESC, rowid DESC
                """,
            arguments: [
                sourceUserId,
                sourceUserId.uuidString,
                targetUserId,
                targetUserId.uuidString,
            ]
        )
    }

    private static func deleteRecords<Record: UserScopedSyncRecord>(
        for _: Record.Type,
        sourceUserId: UUID,
        targetUserId: UUID,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                DELETE FROM \(quotedIdentifier(Record.databaseTableName))
                WHERE user_id = ? OR lower(CAST(user_id AS TEXT)) = lower(?)
                   OR user_id = ? OR lower(CAST(user_id AS TEXT)) = lower(?)
                """,
            arguments: [
                sourceUserId,
                sourceUserId.uuidString,
                targetUserId,
                targetUserId.uuidString,
            ]
        )
    }

    private static func updateGenericUserReferences(from sourceUserId: UUID, to targetUserId: UUID, db: Database) throws {
        let tables = try String.fetchAll(
            db,
            sql: """
                SELECT DISTINCT m.name
                FROM sqlite_master AS m
                JOIN pragma_table_info(m.name) AS c
                  ON 1 = 1
                WHERE m.type = 'table'
                  AND m.name NOT LIKE 'sqlite_%'
                  AND m.name NOT LIKE 'grdb_%'
                  AND c.name IN (\(userReferenceColumns.map { "'\($0)'" }.joined(separator: ", ")))
                ORDER BY m.name ASC
                """
        )

        let excludedUserIdTables = singletonUserTables.union(keyedUserTables).union([User.databaseTableName])
        for table in tables {
            let columns = Set(try db.columns(in: table).map { $0.name.lowercased() })
            for column in userReferenceColumns where columns.contains(column) {
                if column == "user_id" && excludedUserIdTables.contains(table) {
                    continue
                }
                try db.execute(
                    sql: """
                        UPDATE \(quotedIdentifier(table))
                        SET \(quotedIdentifier(column)) = ?
                        WHERE \(quotedIdentifier(column)) = ?
                           OR lower(CAST(\(quotedIdentifier(column)) AS TEXT)) = lower(?)
                        """,
                    arguments: [
                        targetUserId.uuidString,
                        sourceUserId,
                        sourceUserId.uuidString,
                    ]
                )
            }
        }
    }

    private static func rewritePendingOutboxUserReferences(from sourceUserId: UUID, to targetUserId: UUID, db: Database) throws {
        let targetAuthId = try fetchAuthIdentifier(for: targetUserId, db: db)
        let events = try Row.fetchAll(
            db,
            sql: """
                SELECT id, path, body_json
                FROM outbox_events
                WHERE status IN (?, ?, ?)
                ORDER BY created_at_local ASC
                """,
            arguments: [
                OutboxStatus.pending.rawValue,
                OutboxStatus.failedRetryable.rawValue,
                OutboxStatus.inFlight.rawValue,
            ]
        )

        for row in events {
            guard let eventId = MixedUUIDStorage.decode(from: row, column: "id"),
                  let path: String = row["path"],
                  let bodyJson: Data = row["body_json"] else {
                continue
            }

            let rewrittenBody = rewriteOutboxBody(
                bodyJson,
                path: path,
                sourceUserId: sourceUserId.uuidString,
                targetUserId: targetUserId.uuidString,
                targetAuthId: targetAuthId
            )
            guard rewrittenBody != bodyJson else { continue }

            try db.execute(
                sql: """
                    UPDATE outbox_events
                    SET body_json = ?, updated_at_local = ?
                    WHERE id = ? OR lower(CAST(id AS TEXT)) = lower(?)
                    """,
                arguments: [
                    rewrittenBody,
                    Date(),
                    eventId,
                    eventId.uuidString,
                ]
            )
        }
    }

    private static func fetchAuthIdentifier(for userId: UUID, db: Database) throws -> String? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT auth_id
                FROM users
                WHERE id = ? OR lower(CAST(id AS TEXT)) = lower(?)
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString]
        ) else {
            return nil
        }

        if let decoded = MixedUUIDStorage.decode(from: row, column: "auth_id") {
            return decoded.uuidString
        }
        return row["auth_id"]
    }

    private static func migrateUserSyncMirror(from sourceUserId: UUID, to targetUserId: UUID, db: Database) throws {
        let sourceTimestamp = try Date.fetchOne(
            db,
            sql: """
                SELECT updated_at_server
                FROM sync_row_state
                WHERE table_name = ? AND (row_id = ? OR lower(CAST(row_id AS TEXT)) = lower(?))
                LIMIT 1
                """,
            arguments: [
                User.databaseTableName,
                sourceUserId.uuidString,
                sourceUserId.uuidString,
            ]
        )

        if let sourceTimestamp {
            let targetTimestamp = try Date.fetchOne(
                db,
                sql: """
                    SELECT updated_at_server
                    FROM sync_row_state
                    WHERE table_name = ? AND (row_id = ? OR lower(CAST(row_id AS TEXT)) = lower(?))
                    LIMIT 1
                    """,
                arguments: [
                    User.databaseTableName,
                    targetUserId.uuidString,
                    targetUserId.uuidString,
                ]
            )
            try upsertSyncMirror(
                tableName: User.databaseTableName,
                rowId: targetUserId,
                updatedAtServer: max(sourceTimestamp, targetTimestamp ?? sourceTimestamp),
                db: db
            )
        }

        try deleteSyncMirrors(tableName: User.databaseTableName, rowIds: [sourceUserId], db: db)
    }

    private static func rewriteOutboxBody(
        _ bodyJson: Data,
        path: String,
        sourceUserId: String,
        targetUserId: String,
        targetAuthId: String?
    ) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: bodyJson) else {
            return bodyJson
        }

        let rewrittenObject = rewriteJSONObject(
            object,
            sourceUserId: sourceUserId,
            targetUserId: targetUserId,
            targetAuthId: targetAuthId,
            replaceTopLevelId: path == "rest/v1/users",
            isRoot: true
        )

        guard rewrittenObject.changed,
              JSONSerialization.isValidJSONObject(rewrittenObject.value),
              let data = try? JSONSerialization.data(withJSONObject: rewrittenObject.value) else {
            return bodyJson
        }

        return data
    }

    private static func rewriteJSONObject(
        _ value: Any,
        sourceUserId: String,
        targetUserId: String,
        targetAuthId: String?,
        replaceTopLevelId: Bool,
        isRoot: Bool
    ) -> (value: Any, changed: Bool) {
        if let dictionary = value as? [String: Any] {
            var rewritten: [String: Any] = [:]
            var changed = false

            for (key, nestedValue) in dictionary {
                if replaceTopLevelId,
                   isRoot,
                   let stringValue = nestedValue as? String,
                   stringValue.caseInsensitiveCompare(sourceUserId) == .orderedSame,
                   topLevelUserIdentityJSONKeySet.contains(key) {
                    rewritten[key] = key == "auth_id" || key == "authId"
                        ? (targetAuthId ?? targetUserId)
                        : targetUserId
                    changed = true
                    continue
                }

                if userReferenceJSONKeySet.contains(key),
                   let stringValue = nestedValue as? String,
                   stringValue.caseInsensitiveCompare(sourceUserId) == .orderedSame {
                    rewritten[key] = targetUserId
                    changed = true
                    continue
                }

                let nestedRewrite = rewriteJSONObject(
                    nestedValue,
                    sourceUserId: sourceUserId,
                    targetUserId: targetUserId,
                    targetAuthId: targetAuthId,
                    replaceTopLevelId: replaceTopLevelId,
                    isRoot: false
                )
                rewritten[key] = nestedRewrite.value
                changed = changed || nestedRewrite.changed
            }

            return (rewritten, changed)
        }

        if let array = value as? [Any] {
            var rewritten: [Any] = []
            var changed = false
            for item in array {
                let nestedRewrite = rewriteJSONObject(
                    item,
                    sourceUserId: sourceUserId,
                    targetUserId: targetUserId,
                    targetAuthId: targetAuthId,
                    replaceTopLevelId: replaceTopLevelId,
                    isRoot: false
                )
                rewritten.append(nestedRewrite.value)
                changed = changed || nestedRewrite.changed
            }
            return (rewritten, changed)
        }

        return (value, false)
    }

    private static let userReferenceJSONKeySet: Set<String> = [
        "user_id",
        "userId",
        "user_id_deleted",
        "userIdDeleted",
        "created_by_user_id",
        "createdByUserId",
        "created_by",
        "createdBy",
    ]

    private static let topLevelUserIdentityJSONKeySet: Set<String> = [
        "id",
        "auth_id",
        "authId",
    ]

    private static func fetchUsers(authId: UUID, db: Database) throws -> [User] {
        try User.fetchAll(
            db,
            sql: """
                SELECT *
                FROM users
                WHERE auth_id = ? OR lower(CAST(auth_id AS TEXT)) = lower(?)
                ORDER BY updated_at DESC, created_at DESC, rowid DESC
                """,
            arguments: [authId, authId.uuidString]
        )
    }

    private static func fetchUsers(userId: UUID, authId: UUID, db: Database) throws -> [User] {
        try User.fetchAll(
            db,
            sql: """
                SELECT *
                FROM users
                WHERE id = ? OR lower(CAST(id AS TEXT)) = lower(?)
                   OR auth_id = ? OR lower(CAST(auth_id AS TEXT)) = lower(?)
                ORDER BY updated_at DESC, created_at DESC, rowid DESC
                """,
            arguments: [
                userId,
                userId.uuidString,
                authId,
                authId.uuidString,
            ]
        )
    }

    private static func fetchPreferredUser(authId: UUID, db: Database) throws -> User? {
        try chooseCanonicalUser(from: fetchUsers(authId: authId, db: db), db: db)
    }

    private static func chooseCanonicalUser(from users: [User], db: Database) throws -> User? {
        guard !users.isEmpty else { return nil }
        let scored = try users.map { user -> (user: User, hasMirror: Bool) in
            (user, try hasServerMirror(for: user.id, db: db))
        }
        return scored.sorted { lhs, rhs in
            if lhs.hasMirror != rhs.hasMirror {
                return lhs.hasMirror && !rhs.hasMirror
            }
            return fresherUser(lhs.user, rhs.user)
        }.first?.user
    }

    private static func hasServerMirror(for userId: UUID, db: Database) throws -> Bool {
        let count = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM sync_row_state
                WHERE table_name = ?
                  AND (row_id = ? OR lower(CAST(row_id AS TEXT)) = lower(?))
                """,
            arguments: [
                User.databaseTableName,
                userId.uuidString,
                userId.uuidString,
            ]
        ) ?? 0
        return count > 0
    }

    private static func reconcileCanonicalUser(
        _ canonicalUser: User,
        db: Database,
        updateSyncMirror: Bool
    ) throws -> User {
        let relatedUsers = try fetchUsers(userId: canonicalUser.id, authId: canonicalUser.authId, db: db)
        let localDuplicates = relatedUsers.filter { $0.id != canonicalUser.id }
        let preferRelatedPrimary = try hasPendingUserMutation(
            userIds: Set(relatedUsers.map(\.id)).union([canonicalUser.id]),
            db: db
        )

        let mergedUser = mergeUsers(
            canonicalBase: canonicalUser,
            relatedUsers: relatedUsers,
            explicitEmail: canonicalUser.email,
            preferRelatedPrimary: preferRelatedPrimary
        )
        try mergedUser.save(db)

        for duplicateId in Set(localDuplicates.map(\.id)) {
            try mergeUserReferences(from: duplicateId, into: canonicalUser.id, db: db)
        }

        if updateSyncMirror {
            try upsertSyncMirror(
                tableName: User.databaseTableName,
                rowId: canonicalUser.id,
                updatedAtServer: canonicalUser.updatedAt,
                db: db
            )
        }

        return mergedUser
    }

    private static func makeCloudCanonicalUser(
        from localUser: User,
        authId: UUID,
        email: String?,
        now: Date
    ) -> User {
        var canonicalUser = User(
            id: authId,
            authId: authId,
            timezone: localUser.timezone,
            units: localUser.units
        )
        canonicalUser.createdAt = localUser.createdAt
        canonicalUser.updatedAt = max(localUser.updatedAt, now)
        canonicalUser.email = normalizedEmail(email) ?? localUser.email
        canonicalUser.displayName = localUser.displayName
        canonicalUser.dateOfBirth = localUser.dateOfBirth
        canonicalUser.ageRange = localUser.ageRange
        canonicalUser.sex = localUser.sex
        canonicalUser.heightCm = localUser.heightCm
        canonicalUser.weightKg = localUser.weightKg
        canonicalUser.primaryGoal = localUser.primaryGoal
        canonicalUser.activityLevel = localUser.activityLevel
        canonicalUser.baselineHrvMs = localUser.baselineHrvMs
        canonicalUser.baselineRhrBpm = localUser.baselineRhrBpm
        canonicalUser.baselineSleepHours = localUser.baselineSleepHours
        canonicalUser.notificationEnabled = localUser.notificationEnabled
        canonicalUser.onboardingCompleted = localUser.onboardingCompleted
        canonicalUser.calibrationDaysRemaining = localUser.calibrationDaysRemaining
        canonicalUser.deletionScheduledAt = localUser.deletionScheduledAt
        canonicalUser.deletionReason = localUser.deletionReason
        canonicalUser.deletionInProgress = localUser.deletionInProgress
        return canonicalUser
    }

    private static func mergeUsers(
        canonicalBase: User,
        relatedUsers: [User],
        explicitEmail: String?,
        preferRelatedPrimary: Bool
    ) -> User {
        let localOrdered = relatedUsers.sorted(by: fresherUser)
        let orderedUsers = deduplicatedUsers(
            preferRelatedPrimary
                ? localOrdered + [canonicalBase]
                : [canonicalBase] + localOrdered
        )
        let primary = orderedUsers.first ?? canonicalBase

        var merged = canonicalBase
        merged.createdAt = orderedUsers.map(\.createdAt).min() ?? canonicalBase.createdAt
        merged.updatedAt = orderedUsers.map(\.updatedAt).max() ?? canonicalBase.updatedAt
        merged.authId = canonicalBase.authId
        merged.email = normalizedEmail(explicitEmail) ?? pickFirstNonEmptyString(orderedUsers, value: \.email)
        merged.displayName = pickFirstNonEmptyString(orderedUsers, value: \.displayName)
        merged.dateOfBirth = pickFirstNonNil(orderedUsers, value: \.dateOfBirth)
        merged.ageRange = pickFirstNonNil(orderedUsers, value: \.ageRange)
        merged.sex = pickFirstNonNil(orderedUsers, value: \.sex)
        merged.heightCm = pickFirstNonNil(orderedUsers, value: \.heightCm)
        merged.weightKg = pickFirstNonNil(orderedUsers, value: \.weightKg)
        merged.primaryGoal = pickFirstNonNil(orderedUsers, value: \.primaryGoal)
        merged.activityLevel = pickFirstNonNil(orderedUsers, value: \.activityLevel)
        merged.baselineHrvMs = pickFirstNonNil(orderedUsers, value: \.baselineHrvMs)
        merged.baselineRhrBpm = pickFirstNonNil(orderedUsers, value: \.baselineRhrBpm)
        merged.baselineSleepHours = pickFirstNonNil(orderedUsers, value: \.baselineSleepHours)
        merged.timezone = primary.timezone
        merged.units = primary.units
        merged.notificationEnabled = primary.notificationEnabled
        merged.onboardingCompleted = orderedUsers.contains { $0.onboardingCompleted }
        merged.calibrationDaysRemaining = orderedUsers.map(\.calibrationDaysRemaining).min() ?? primary.calibrationDaysRemaining
        merged.deletionScheduledAt = pickFirstNonNil(orderedUsers, value: \.deletionScheduledAt)
        merged.deletionReason = pickFirstNonEmptyString(orderedUsers, value: \.deletionReason)
        merged.deletionInProgress = orderedUsers.contains { $0.deletionInProgress }
        return merged
    }

    private static func hasPendingUserMutation(userIds: Set<UUID>, db: Database) throws -> Bool {
        guard !userIds.isEmpty else { return false }
        let bodies = try Data.fetchAll(
            db,
            sql: """
                SELECT body_json
                FROM outbox_events
                WHERE path = ?
                  AND status IN (?, ?, ?)
                ORDER BY created_at_local DESC
                """,
            arguments: [
                "rest/v1/users",
                OutboxStatus.pending.rawValue,
                OutboxStatus.failedRetryable.rawValue,
                OutboxStatus.inFlight.rawValue,
            ]
        )

        let expectedIds = Set(userIds.map { $0.uuidString.lowercased() })
        for body in bodies {
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let id = (object["id"] as? String)?.lowercased() else {
                continue
            }
            if expectedIds.contains(id) {
                return true
            }
        }
        return false
    }

    private static func deduplicatedUsers(_ users: [User]) -> [User] {
        var seen = Set<UUID>()
        var ordered: [User] = []
        for user in users {
            if seen.insert(user.id).inserted {
                ordered.append(user)
            }
        }
        return ordered
    }

    private static func fresherUser(_ lhs: User, _ rhs: User) -> Bool {
        compareFreshness(lhs.updatedAt, lhs.createdAt, lhs.id, rhs.updatedAt, rhs.createdAt, rhs.id)
    }

    private static func deleteSyncMirrors(tableName: String, rowIds: [UUID], db: Database) throws {
        guard !rowIds.isEmpty else { return }
        for rowId in rowIds {
            try db.execute(
                sql: """
                    DELETE FROM sync_row_state
                    WHERE table_name = ?
                      AND (row_id = ? OR lower(CAST(row_id AS TEXT)) = lower(?))
                    """,
                arguments: [tableName, rowId.uuidString, rowId.uuidString]
            )
        }
    }

    private static func upsertSyncMirror(
        tableName: String,
        rowId: UUID,
        updatedAtServer: Date,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO sync_row_state (table_name, row_id, updated_at_server)
                VALUES (?, ?, ?)
                ON CONFLICT(table_name, row_id)
                DO UPDATE SET updated_at_server = excluded.updated_at_server
                """,
            arguments: [tableName, rowId.uuidString, updatedAtServer]
        )
    }

    private static func freshestRecord<Record: UserScopedSyncRecord>(in records: [Record]) -> Record {
        records.sorted(by: fresherRecord).first ?? records[0]
    }

    private static func rebasedRecord<Record: UserScopedSyncRecord>(
        _ record: Record,
        records: [Record],
        targetUserId: UUID
    ) -> Record {
        var rebased = record
        rebased.userId = targetUserId
        rebased.createdAt = records.map(\.createdAt).min() ?? rebased.createdAt
        rebased.updatedAt = records.map(\.updatedAt).max() ?? rebased.updatedAt
        return rebased
    }

    private static func fresherRecord<Record: UserScopedSyncRecord>(_ lhs: Record, _ rhs: Record) -> Bool {
        compareFreshness(lhs.updatedAt, lhs.createdAt, lhs.id, rhs.updatedAt, rhs.createdAt, rhs.id)
    }

    private static func compareFreshness(
        _ lhsUpdatedAt: Date,
        _ lhsCreatedAt: Date,
        _ lhsId: UUID,
        _ rhsUpdatedAt: Date,
        _ rhsCreatedAt: Date,
        _ rhsId: UUID
    ) -> Bool {
        if lhsUpdatedAt != rhsUpdatedAt {
            return lhsUpdatedAt > rhsUpdatedAt
        }
        if lhsCreatedAt != rhsCreatedAt {
            return lhsCreatedAt > rhsCreatedAt
        }
        return lhsId.uuidString.lowercased() < rhsId.uuidString.lowercased()
    }

    private static func pickFirstNonNil<RowType, Value>(
        _ rows: [RowType],
        value: (RowType) -> Value?
    ) -> Value? {
        for row in rows {
            if let value = value(row) {
                return value
            }
        }
        return nil
    }

    private static func pickFirstNonEmptyString<RowType>(
        _ rows: [RowType],
        value: (RowType) -> String?
    ) -> String? {
        for row in rows {
            guard let rawValue = value(row)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawValue.isEmpty else {
                continue
            }
            return rawValue
        }
        return nil
    }

    private static func normalizedEmail(_ email: String?) -> String? {
        guard let email else { return nil }
        let normalized = email
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func quotedIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
