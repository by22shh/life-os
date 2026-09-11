import Foundation
import GRDB

enum LocalUserDataReset {
    static func purgeUserScopedData(in db: Database) throws {
        let userScopedTables = try String.fetchAll(
            db,
            sql: """
                SELECT DISTINCT m.name
                FROM sqlite_master AS m
                JOIN pragma_table_info(m.name) AS c
                  ON 1 = 1
                WHERE m.type = 'table'
                  AND m.name NOT LIKE 'sqlite_%'
                  AND c.name = 'user_id'
                """
        )

        for table in userScopedTables {
            try db.execute(sql: "DELETE FROM \(quotedIdentifier(table))")
        }

        try deleteAllRowsIfTableExists("users", db: db)
        try deleteAllRowsIfTableExists("deletion_audit_log", db: db)
        try deleteAllRowsIfTableExists("outbox_events", db: db)
        try deleteAllRowsIfTableExists("sync_row_state", db: db)
        try deleteAllRowsIfTableExists("sync_state", db: db)

        // Custom catalog rows are owned through created_by/created_by_user_id
        // instead of user_id. Remove them while keeping shared rows.
        try deleteCustomCatalogRows(in: db)
    }

    private static func deleteCustomCatalogRows(in db: Database) throws {
        if try tableExists("exercise_catalog", db: db) {
            try db.execute(
                sql: """
                    DELETE FROM \(quotedIdentifier("exercise_catalog"))
                    WHERE is_custom = 1 OR created_by IS NOT NULL
                    """
            )
        }
        if try tableExists("food_catalog_items", db: db) {
            try db.execute(
                sql: """
                    DELETE FROM \(quotedIdentifier("food_catalog_items"))
                    WHERE created_by_user_id IS NOT NULL
                    """
            )
        }
    }

    static func insertFreshUser(
        id userId: UUID,
        authId: UUID,
        in db: Database,
        now: Date = Date()
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO users (
                    id,
                    auth_id,
                    timezone,
                    units,
                    notification_enabled,
                    onboarding_completed,
                    calibration_days_remaining,
                    deletion_in_progress,
                    created_at,
                    updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                userId.uuidString,
                authId.uuidString,
                TimeZone.autoupdatingCurrent.identifier,
                UnitSystem.metric.rawValue,
                true,
                false,
                3,
                false,
                now,
                now,
            ]
        )
    }

    static func tableExists(_ table: String, db: Database) throws -> Bool {
        try Int.fetchOne(
            db,
            sql: "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            arguments: [table]
        ) == 1
    }

    static func deleteAllRowsIfTableExists(_ table: String, db: Database) throws {
        guard try tableExists(table, db: db) else { return }
        try db.execute(sql: "DELETE FROM \(quotedIdentifier(table))")
    }

    static func quotedIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

struct LocalPrivacyUserContext: Sendable {
    let userId: UUID
    let authId: UUID
}

private struct LocalPrivacyExportMetadata: Codable, Sendable {
    let exportId: String
    let generatedAt: String
    let scope: String
    let userId: String
    let authId: String
}

private struct LocalPrivacyExportDocument: Codable, Sendable {
    let metadata: LocalPrivacyExportMetadata
    let tables: [String: [[String: LocalPrivacyExportValue]]]
}

private enum LocalPrivacyExportValue: Codable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case data(String)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .int(value ? 1 : 0)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported export value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .data(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

struct LocalPrivacyErasureDependencies: Sendable {
    let removeLocalExports: @Sendable () throws -> Void
    let removeNutritionPhotoDrafts: @Sendable () throws -> Void
    let deleteDeviceKey: @Sendable () throws -> Void
    let removeRawAssetsAndBackups: @Sendable () async throws -> Void

    init(
        removeLocalExports: @escaping @Sendable () throws -> Void,
        deleteDeviceKey: @escaping @Sendable () throws -> Void,
        removeNutritionPhotoDrafts: @escaping @Sendable () throws -> Void = {},
        removeRawAssetsAndBackups: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.removeLocalExports = removeLocalExports
        self.removeNutritionPhotoDrafts = removeNutritionPhotoDrafts
        self.deleteDeviceKey = deleteDeviceKey
        self.removeRawAssetsAndBackups = removeRawAssetsAndBackups
    }

    static let live = LocalPrivacyErasureDependencies(
        removeLocalExports: {
            try LocalPrivacyExportWriter.removeAllExports()
        },
        deleteDeviceKey: {
            try FieldEncryption.deleteDeviceKey()
        },
        removeNutritionPhotoDrafts: {
            try NutritionPhotoDraftStore.removeAll()
        },
        removeRawAssetsAndBackups: {
            // Serialize with the backup actor so an in-progress backup cannot
            // recreate an erased snapshot after cleanup has reported success.
            try await DatabaseBackupManager.shared.removeAllBackupsForErasure()
            let fm = FileManager.default
            let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let directories = [
                support.appendingPathComponent("LifeOS/MedicalScans"),
                support.appendingPathComponent("LifeOS/RecoveryQuarantine"),
                fm.temporaryDirectory.appendingPathComponent("LifeOS/PrivacyExports")
            ]
            for directory in directories where fm.fileExists(atPath: directory.path) {
                try fm.removeItem(at: directory)
                guard !fm.fileExists(atPath: directory.path) else {
                    throw LocalPrivacyOperationError.exportCleanupVerificationFailed(directory)
                }
            }
        }
    )
}

private enum LocalPrivacyOperationError: LocalizedError {
    case exportCleanupVerificationFailed(URL)

    var errorDescription: String? {
        switch self {
        case .exportCleanupVerificationFailed(let url):
            return "Local export artifacts still exist after cleanup at \(url.path)."
        }
    }
}

enum LocalPrivacyExportWriter {
    static func createExport(
        exportId: String,
        user: LocalPrivacyUserContext,
        dbQueue: DatabaseQueue,
        exportsDirectoryOverride: URL? = nil
    ) async throws -> URL {
        let document = try await dbQueue.read { db in
            try buildDocument(exportId: exportId, user: user, db: db)
        }

        let directory = try exportsDirectory(
            createIfNeeded: true,
            overrideDirectory: exportsDirectoryOverride
        )
        let fileURL = directory.appendingPathComponent("lifeos-export-\(exportId).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return fileURL
    }

    private static func buildDocument(
        exportId: String,
        user: LocalPrivacyUserContext,
        db: Database
    ) throws -> LocalPrivacyExportDocument {
        let tableNames = try String.fetchAll(
            db,
            sql: """
                SELECT name
                FROM sqlite_master
                WHERE type = 'table'
                  AND name NOT LIKE 'sqlite_%'
                  AND name NOT LIKE 'grdb_%'
                ORDER BY name ASC
                """
        )

        var tables: [String: [[String: LocalPrivacyExportValue]]] = [:]
        for table in tableNames {
            guard let request = try selectRequest(for: table, user: user, db: db) else {
                continue
            }
            let rows = try Row.fetchAll(db, sql: request.sql, arguments: request.arguments)
            guard !rows.isEmpty else { continue }
            tables[table] = try rows.map { try serializedRow(from: $0) }
        }

        return LocalPrivacyExportDocument(
            metadata: LocalPrivacyExportMetadata(
                exportId: exportId,
                generatedAt: DateFormatting.iso8601FullString(from: Date()),
                scope: "local_only",
                userId: user.userId.uuidString,
                authId: user.authId.uuidString
            ),
            tables: tables
        )
    }

    private static func selectRequest(
        for table: String,
        user: LocalPrivacyUserContext,
        db: Database
    ) throws -> (sql: String, arguments: StatementArguments)? {
        let columns = Set(try db.columns(in: table).map { $0.name.lowercased() })
        let tableName = LocalUserDataReset.quotedIdentifier(table)

        // These children have no user_id: select through their owned parent.
        let parentLinks: [String: (String, String)] = [
            "workout_exercises": ("workout_sessions", "session_id"),
            "batch_recipe_ingredients": ("batch_recipes", "batch_recipe_id")
        ]
        if let (parent, foreignKey) = parentLinks[table] {
            return ("SELECT child.* FROM \(tableName) child JOIN \(parent) parent ON child.\(foreignKey) = parent.id WHERE parent.user_id = ? OR lower(CAST(parent.user_id AS TEXT)) = lower(?) ORDER BY child.rowid", [user.userId, user.userId.uuidString])
        }

        // User-owned catalog rows do not have a user_id column.
        if table == "exercise_catalog", columns.contains("created_by") {
            return (
                """
                SELECT *
                FROM \(tableName)
                WHERE created_by = ? OR lower(CAST(created_by AS TEXT)) = lower(?)
                ORDER BY rowid ASC
                """,
                [user.userId, user.userId.uuidString]
            )
        }

        if table == "food_catalog_items", columns.contains("created_by_user_id") {
            return (
                """
                SELECT *
                FROM \(tableName)
                WHERE created_by_user_id = ? OR lower(CAST(created_by_user_id AS TEXT)) = lower(?)
                ORDER BY rowid ASC
                """,
                [user.userId, user.userId.uuidString]
            )
        }

        if columns.contains("user_id") {
            return (
                """
                SELECT *
                FROM \(tableName)
                WHERE user_id = ? OR lower(CAST(user_id AS TEXT)) = lower(?)
                ORDER BY rowid ASC
                """,
                [user.userId, user.userId.uuidString]
            )
        }

        if columns.contains("user_id_deleted") {
            return (
                """
                SELECT *
                FROM \(tableName)
                WHERE user_id_deleted = ? OR lower(CAST(user_id_deleted AS TEXT)) = lower(?)
                ORDER BY rowid ASC
                """,
                [user.userId, user.userId.uuidString]
            )
        }

        if table == "users" {
            return (
                """
                SELECT *
                FROM \(tableName)
                WHERE id = ?
                   OR lower(CAST(id AS TEXT)) = lower(?)
                   OR auth_id = ?
                   OR lower(CAST(auth_id AS TEXT)) = lower(?)
                ORDER BY rowid ASC
                """,
                [user.userId, user.userId.uuidString, user.authId, user.authId.uuidString]
            )
        }

        if columns.contains("auth_id") {
            return (
                """
                SELECT *
                FROM \(tableName)
                WHERE auth_id = ? OR lower(CAST(auth_id AS TEXT)) = lower(?)
                ORDER BY rowid ASC
                """,
                [user.authId, user.authId.uuidString]
            )
        }

        let deviceScopedTables: Set<String> = [
            "local_meta",
            "outbox_events",
            "sync_row_state",
            "sync_state"
        ]
        if deviceScopedTables.contains(table) {
            return ("SELECT * FROM \(tableName) ORDER BY rowid ASC", StatementArguments())
        }

        return nil
    }

    private static func serializedRow(from row: Row) throws -> [String: LocalPrivacyExportValue] {
        try Dictionary(uniqueKeysWithValues: Array(row.columnNames).enumerated().map { index, columnName in
            if (columnName == "id" || columnName.hasSuffix("_id")),
               let uuid = MixedUUIDStorage.decode(from: row, column: columnName) {
                return (columnName, .string(uuid.uuidString.lowercased()))
            }
            return (columnName, try serializedValue(from: row[index]))
        })
    }

    private static func serializedValue(from value: (any DatabaseValueConvertible)?) throws -> LocalPrivacyExportValue {
        guard let value else { return .null }
        switch value {
        case let value as Int64:
            return .int(value)
        case let value as Int:
            return .int(Int64(value))
        case let value as Double:
            return .double(value)
        case let value as Float:
            return .double(Double(value))
        case let value as String:
            if FieldEncryption.isStorageEncrypted(value) {
                // Fail the export instead of silently exporting unreadable ciphertext.
                guard let plaintext = FieldEncryption.decryptStoredString(value) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return .string(plaintext)
            }
            return .string(value)
        case let value as Data:
            return .data(value.base64EncodedString())
        default:
            return .string(String(describing: value))
        }
    }

    static func removeAllExports(exportsDirectoryOverride: URL? = nil) throws {
        let directory = try exportsDirectory(
            createIfNeeded: false,
            overrideDirectory: exportsDirectoryOverride
        )
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw LocalPrivacyOperationError.exportCleanupVerificationFailed(directory)
        }
    }

    private static func exportsDirectory(
        createIfNeeded: Bool,
        overrideDirectory: URL? = nil
    ) throws -> URL {
        if let overrideDirectory {
            if createIfNeeded {
                try FileManager.default.createDirectory(
                    at: overrideDirectory,
                    withIntermediateDirectories: true
                )
            }
            return overrideDirectory
        }

        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: createIfNeeded
        )
        let directory = appSupport
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent("Exports", isDirectory: true)
        if createIfNeeded {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}

enum LocalPrivacyErasureExecutor {
    static func execute(
        reason: String,
        user: LocalPrivacyUserContext,
        dbQueue: DatabaseQueue,
        dependencies: LocalPrivacyErasureDependencies = .live
    ) async throws -> ErasureStatusResponse {
        let completedAt = Date()
        do {
            try await dependencies.removeRawAssetsAndBackups()
        } catch {
            try await recordFailure(for: user.userId, type: "local_raw_asset_backup_cleanup", error: error, dbQueue: dbQueue, createdAt: completedAt)
            throw error
        }
        do {
            try dependencies.removeLocalExports()
        } catch {
            try await recordFailure(
                for: user.userId,
                type: "local_export_cleanup",
                error: error,
                dbQueue: dbQueue,
                createdAt: completedAt
            )
            throw error
        }

        do {
            try dependencies.removeNutritionPhotoDrafts()
        } catch {
            try await recordFailure(
                for: user.userId,
                type: "local_nutrition_photo_cleanup",
                error: error,
                dbQueue: dbQueue,
                createdAt: completedAt
            )
            throw error
        }

        let auditId = UUID()
        try await dbQueue.write { db in
            try LocalUserDataReset.purgeUserScopedData(in: db)
            try LocalUserDataReset.insertFreshUser(
                id: user.userId,
                authId: user.authId,
                in: db,
                now: completedAt
            )
            let auditEntry = DeletionAuditLog(
                id: auditId,
                userIdDeleted: user.userId,
                deletedAt: completedAt,
                postgresDeleted: false,
                vectorsDeleted: false,
                storageDeleted: false,
                complianceVerified: false,
                notes: "local_only:\(reason)"
            )
            try auditEntry.insert(db)
        }

        do {
            try dependencies.deleteDeviceKey()
        } catch {
            try await dbQueue.write { db in
                try db.execute(
                    sql: """
                        UPDATE deletion_audit_log
                        SET compliance_verified = 0
                        WHERE id = ?
                        """,
                    arguments: [auditId.uuidString]
                )
            }
            try await recordFailure(
                for: user.userId,
                type: "local_device_key_cleanup",
                error: error,
                dbQueue: dbQueue,
                createdAt: completedAt
            )
            throw error
        }

        // Erase freed SQLite pages and truncate WAL before certifying deletion.
        try await dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            try db.execute(sql: "VACUUM")
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }

        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE deletion_audit_log
                    SET compliance_verified = 1,
                        storage_deleted = 1
                    WHERE id = ?
                    """,
                arguments: [auditId.uuidString]
            )
        }

        return ErasureStatusResponse(
            scheduled: false,
            deletionDate: DateFormatting.iso8601FullString(from: completedAt),
            deletionInProgress: false,
            reason: reason,
            deletionState: "completed",
            deletionMode: "local_only",
            deletionAttemptCount: 1,
            retryAfterSeconds: nil,
            idempotencyKey: nil
        )
    }

    static func latestStatus(
        userId: UUID,
        dbQueue: DatabaseQueue
    ) async throws -> ErasureStatusResponse? {
        try await dbQueue.read { db in
            let audit = try DeletionAuditLog.fetchOne(
                db,
                sql: """
                    SELECT *
                    FROM deletion_audit_log
                    WHERE user_id_deleted = ? OR lower(CAST(user_id_deleted AS TEXT)) = lower(?)
                    ORDER BY deleted_at DESC
                    LIMIT 1
                    """,
                arguments: [userId, userId.uuidString]
            )
            let failure = try DeletionFailure.fetchOne(
                db,
                sql: """
                    SELECT *
                    FROM deletion_failures
                    WHERE (user_id = ? OR lower(CAST(user_id AS TEXT)) = lower(?))
                      AND resolved = 0
                    ORDER BY created_at DESC
                    LIMIT 1
                    """,
                arguments: [userId, userId.uuidString]
            )

            if let failure,
               audit == nil || failure.createdAt >= (audit?.deletedAt ?? .distantPast) {
                return ErasureStatusResponse(
                    scheduled: false,
                    deletionDate: DateFormatting.iso8601FullString(from: failure.createdAt),
                    deletionInProgress: false,
                    reason: nil,
                    deletionState: "failed",
                    deletionMode: "local_only",
                    deletionAttemptCount: 1,
                    retryAfterSeconds: nil,
                    idempotencyKey: nil
                )
            }

            if let audit {
                return ErasureStatusResponse(
                    scheduled: false,
                    deletionDate: DateFormatting.iso8601FullString(from: audit.deletedAt),
                    deletionInProgress: false,
                    reason: audit.notes?.split(separator: ":").dropFirst().joined(separator: ":"),
                    deletionState: audit.complianceVerified ? "completed" : "failed",
                    deletionMode: "local_only",
                    deletionAttemptCount: 1,
                    retryAfterSeconds: nil,
                    idempotencyKey: nil
                )
            }
            return nil
        }
    }

    private static func recordFailure(
        for userId: UUID,
        type: String,
        error: Error,
        dbQueue: DatabaseQueue,
        createdAt: Date
    ) async throws {
        let entry = DeletionFailure(
            userId: userId,
            failureType: type,
            error: friendlyMessage(for: error),
            createdAt: createdAt
        )
        try await dbQueue.write { db in
            try entry.insert(db)
        }
    }

    private static func friendlyMessage(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return error.localizedDescription
    }
}

// MARK: - Manual archive import

struct LocalPrivacyImportSummary: Sendable, Equatable {
    var importedRows: Int
    var skippedRows: Int
    var tables: [String: Int]
}

enum LocalPrivacyImportError: LocalizedError {
    case invalidArchive
    case noActiveUser

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            return String(localized: "settings_import_error_invalid_archive")
        case .noActiveUser:
            return String(localized: "settings_import_error_no_user")
        }
    }
}

enum LocalPrivacyArchiveImporter {
    /// Runtime state that belongs to the current device/installation. It is
    /// exported for completeness, but restoring it would replay stale network
    /// work or overwrite live sync bookkeeping.
    static let deviceScopedTables: Set<String> = [
        "local_meta",
        "outbox_events",
        "sync_row_state",
        "sync_state",
        "ai_cache"
    ]

    private struct ArchiveEnvelope: Decodable {
        var localSnapshot: LocalPrivacyExportDocument?

        enum CodingKeys: String, CodingKey {
            case localSnapshot = "local_snapshot"
        }
    }

    static func importArchive(
        data: Data,
        user: LocalPrivacyUserContext,
        dbQueue: DatabaseQueue
    ) async throws -> LocalPrivacyImportSummary {
        let snapshot = try decodeSnapshot(from: data)
        return try await dbQueue.write { db in
            try importSnapshot(snapshot, user: user, db: db)
        }
    }

    private static func decodeSnapshot(from data: Data) throws -> LocalPrivacyExportDocument {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(ArchiveEnvelope.self, from: data),
           let localSnapshot = envelope.localSnapshot {
            return localSnapshot
        }
        if let document = try? decoder.decode(LocalPrivacyExportDocument.self, from: data) {
            return document
        }
        throw LocalPrivacyImportError.invalidArchive
    }

    private static func importSnapshot(
        _ snapshot: LocalPrivacyExportDocument,
        user: LocalPrivacyUserContext,
        db: Database
    ) throws -> LocalPrivacyImportSummary {
        var remaining: [String: [[String: LocalPrivacyExportValue]]] = [:]
        for (table, rows) in snapshot.tables where !rows.isEmpty {
            guard !deviceScopedTables.contains(table) else { continue }
            guard try LocalUserDataReset.tableExists(table, db: db) else { continue }
            let columns = Set(try db.columns(in: table).map { $0.name.lowercased() })
            let ownedRows = rows.filter {
                rowBelongsToUser($0, table: table, columns: columns, user: user)
            }
            if !ownedRows.isEmpty {
                remaining[table] = ownedRows
            }
        }

        var summary = LocalPrivacyImportSummary(importedRows: 0, skippedRows: 0, tables: [:])
        var passes = 0
        while !remaining.isEmpty && passes < 8 {
            passes += 1
            var madeProgress = false
            for (table, rows) in remaining {
                var deferred: [[String: LocalPrivacyExportValue]] = []
                for row in rows {
                    do {
                        if try insert(row, into: table, db: db) {
                            summary.importedRows += 1
                            summary.tables[table, default: 0] += 1
                        } else {
                            summary.skippedRows += 1
                        }
                    } catch let error as DatabaseError
                        where error.extendedResultCode == .SQLITE_CONSTRAINT_FOREIGNKEY {
                        // Parent rows may arrive later in the archive; retry on
                        // the next pass once more tables are restored.
                        deferred.append(row)
                    } catch {
                        summary.skippedRows += 1
                    }
                }
                if deferred.isEmpty {
                    remaining.removeValue(forKey: table)
                } else {
                    remaining[table] = deferred
                }
                if deferred.count < rows.count {
                    madeProgress = true
                }
            }
            if !madeProgress {
                break
            }
        }
        for (_, rows) in remaining {
            summary.skippedRows += rows.count
        }
        return summary
    }

    private static func insert(
        _ row: [String: LocalPrivacyExportValue],
        into table: String,
        db: Database
    ) throws -> Bool {
        let validColumns = Set(try db.columns(in: table).map { $0.name.lowercased() })
        var names: [String] = []
        var values: [any DatabaseValueConvertible] = []
        for (key, value) in row {
            let name = key.lowercased()
            guard validColumns.contains(name),
                  let databaseValue = databaseValue(for: value) else { continue }
            names.append(LocalUserDataReset.quotedIdentifier(name))
            values.append(databaseValue)
        }
        guard !names.isEmpty else { return false }

        let tableName = LocalUserDataReset.quotedIdentifier(table)
        let placeholders = Array(repeating: "?", count: names.count).joined(separator: ", ")
        try db.execute(
            sql: "INSERT OR IGNORE INTO \(tableName) (\(names.joined(separator: ", "))) VALUES (\(placeholders))",
            arguments: StatementArguments(values)
        )
        return db.changesCount > 0
    }

    private static func databaseValue(
        for value: LocalPrivacyExportValue
    ) -> (any DatabaseValueConvertible)? {
        switch value {
        case .null:
            return nil
        case .string(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .data(let value):
            return Data(base64Encoded: value) ?? value
        }
    }

    private static func rowBelongsToUser(
        _ row: [String: LocalPrivacyExportValue],
        table: String,
        columns: Set<String>,
        user: LocalPrivacyUserContext
    ) -> Bool {
        func stringValue(_ name: String) -> String? {
            guard let stored = row.first(where: { $0.key.lowercased() == name })?.value else {
                return nil
            }
            if case .string(let value) = stored { return value }
            return nil
        }

        func matches(_ value: String?, _ expected: UUID) -> Bool {
            guard let value, let uuid = UUID(uuidString: value) else { return false }
            return uuid == expected
        }

        if columns.contains("user_id") {
            return matches(stringValue("user_id"), user.userId)
        }
        if table == "users" {
            return matches(stringValue("id"), user.userId)
                || matches(stringValue("auth_id"), user.authId)
        }
        if columns.contains("auth_id") {
            return matches(stringValue("auth_id"), user.authId)
        }
        if table == "exercise_catalog" {
            return matches(stringValue("created_by"), user.userId)
        }
        if table == "food_catalog_items" {
            return matches(stringValue("created_by_user_id"), user.userId)
        }
        if table == "workout_exercises" || table == "batch_recipe_ingredients" {
            // Ownership is enforced through the parent foreign key below.
            return true
        }
        return false
    }
}
