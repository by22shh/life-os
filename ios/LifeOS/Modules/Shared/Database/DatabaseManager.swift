// MARK: - Database Manager
// Source of truth: life_os_engineering_blueprint.md (GRDB + SQLite)
// life_os_sync_engine_spec.md §4

import Foundation
import GRDB

/// Central database manager wrapping a GRDB DatabaseQueue.
/// WAL mode enabled for concurrent reads during writes.
final class DatabaseManager: Sendable {

    struct PersistentStartupFailure: Error, Sendable {
        enum Kind: Sendable {
            case lockedStorage
            case insufficientSpace
            case inaccessibleStore
            case corruptedStore
            case migrationFailed
            case unknown

            var symbolName: String {
                switch self {
                case .lockedStorage:
                    return "lock.circle.fill"
                case .insufficientSpace:
                    return "externaldrive.badge.exclamationmark"
                case .inaccessibleStore:
                    return "externaldrive.badge.xmark"
                case .corruptedStore:
                    return "externaldrive.badge.xmark"
                case .migrationFailed:
                    return "wrench.and.screwdriver.fill"
                case .unknown:
                    return "exclamationmark.triangle.fill"
                }
            }

            var title: String {
                switch self {
                case .lockedStorage:
                    return "Device storage is still locked"
                case .insufficientSpace:
                    return "Not enough device storage"
                case .inaccessibleStore:
                    return "Life OS storage is unavailable"
                case .corruptedStore:
                    return "Life OS storage needs repair"
                case .migrationFailed:
                    return "Life OS could not open its data schema"
                case .unknown:
                    return "Life OS could not open local storage"
                }
            }

            var message: String {
                switch self {
                case .lockedStorage:
                    return "Life OS paused startup because iOS has not made the encrypted app container writable yet."
                case .insufficientSpace:
                    return "Life OS paused startup to avoid partial writes while the device is out of space."
                case .inaccessibleStore:
                    return "Life OS paused startup because the app container or database file is not writable right now."
                case .corruptedStore:
                    return "Life OS paused startup to avoid overwriting existing health data after detecting database corruption."
                case .migrationFailed:
                    return "Life OS paused startup because the local database schema could not be migrated safely."
                case .unknown:
                    return "Life OS paused startup because persistent local storage could not be opened safely."
                }
            }

            var recoverySteps: [String] {
                switch self {
                case .lockedStorage:
                    return [
                        "Unlock the device once after restart, then reopen Life OS.",
                        "If the issue persists, fully restart the device."
                    ]
                case .insufficientSpace:
                    return [
                        "Free up device storage, then reopen Life OS.",
                        "Avoid deleting Life OS files manually so the existing database remains intact."
                    ]
                case .inaccessibleStore:
                    return [
                        "Restart the device and reopen Life OS.",
                        "If the problem persists, verify the app container is writable before attempting any repair."
                    ]
                case .corruptedStore:
                    return [
                        "Do not continue with a temporary database session.",
                        "Preserve the existing database files and repair or recover them before reopening the app."
                    ]
                case .migrationFailed:
                    return [
                        "Do not continue with a temporary database session.",
                        "Inspect the migration failure and only reopen Life OS after the schema issue is resolved."
                    ]
                case .unknown:
                    return [
                        "Restart the device and reopen Life OS.",
                        "If the issue persists, inspect the startup diagnostic before attempting repair."
                    ]
                }
            }
        }

        let kind: Kind
        let reason: String
        let databaseURL: URL?
        let databaseDirectoryURL: URL?

        var protectionMessage: String {
            "Life OS stopped before enabling local writes, so no session-only data can be created and lost on the next launch."
        }
    }

    enum PersistentStartupState: Sendable {
        case available(DatabaseManager)
        case unavailable(PersistentStartupFailure)

        var manager: DatabaseManager? {
            switch self {
            case .available(let manager):
                return manager
            case .unavailable:
                return nil
            }
        }

        var failure: PersistentStartupFailure? {
            switch self {
            case .available:
                return nil
            case .unavailable(let failure):
                return failure
            }
        }

        var isAvailable: Bool {
            manager != nil
        }
    }

    /// Shared persistent startup state for the app.
    static let sharedStartupState = makePersistentStartupState()

    /// Shared singleton for the app after persistent storage is available.
    static var shared: DatabaseManager {
        guard case .available(let manager) = sharedStartupState else {
            preconditionFailure(
                "Persistent database is unavailable. Check DatabaseManager.sharedStartupState before accessing DatabaseManager.shared."
            )
        }
        return manager
    }

    /// The database queue (thread-safe).
    let dbQueue: DatabaseQueue

    /// Reserved for explicit test-only ephemeral stores.
    /// Live app startup no longer falls back to an in-memory database.
    let isUsingInMemoryFallback: Bool
    let wasRestoredFromBackup: Bool

    /// For unit tests: create an in-memory database.
    static func inMemory() throws -> DatabaseManager {
        let dbQueue = try DatabaseQueue(configuration: Self.configuration)
        let manager = DatabaseManager(dbQueue: dbQueue, isInMemoryFallback: false)
        try manager.runMigrations()
        return manager
    }

    private enum DatabaseInitializationError: Error, Equatable {
        case forcedPersistentFailure
        case corruptedStore
    }

    /// Testable init with a pre-configured queue.
    init(dbQueue: DatabaseQueue, isInMemoryFallback: Bool = false, wasRestoredFromBackup: Bool = false) {
        self.dbQueue = dbQueue
        self.isUsingInMemoryFallback = isInMemoryFallback
        self.wasRestoredFromBackup = wasRestoredFromBackup
    }

    // MARK: - Configuration

    private static var configuration: Configuration {
        var config = Configuration()
        // WAL mode for concurrent reads
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return config
    }

    private nonisolated static func logPersistentInitFailure(error: Error, forcePersistentFailure: Bool) {
#if DEBUG
        let prefix = forcePersistentFailure
            ? "Forced persistent database startup failure"
            : "Failed to initialize persistent database"
        fputs("\(prefix): \(error)\n", stderr)
#else
        _ = (error, forcePersistentFailure)
#endif
    }

    // MARK: - Database Location

    private struct DatabaseLocations: Sendable {
        let databaseDirectoryURL: URL
        let databaseURL: URL
    }

    static func persistentStartupState() -> PersistentStartupState {
        makePersistentStartupState()
    }

    private static func makePersistentStartupState(forcePersistentFailure: Bool = false) -> PersistentStartupState {
        var locations: DatabaseLocations?

        do {
            if forcePersistentFailure {
                throw DatabaseInitializationError.forcedPersistentFailure
            }

            let resolvedLocations = try databaseLocations()
            locations = resolvedLocations

            let queue = try DatabaseQueue(
                path: resolvedLocations.databaseURL.path,
                configuration: configuration
            )
            applyDatabaseFileProtection(databaseURL: resolvedLocations.databaseURL)
            do {
                let valid = try queue.read { db in
                    try String.fetchAll(db, sql: "PRAGMA integrity_check") == ["ok"]
                }
                guard valid else { throw DatabaseInitializationError.corruptedStore }
                try runMigrations(on: queue)
            } catch {
                try? queue.close()
                throw error
            }
            scheduleDailyBackupIfNeeded()

            return .available(DatabaseManager(dbQueue: queue))
        } catch {
            logPersistentInitFailure(error: error, forcePersistentFailure: forcePersistentFailure)
            // Only confirmed corruption permits recovery. Permission, disk-space and
            // migration errors must not replace a potentially newer healthy store.
            if classifyPersistentStartupFailure(error) == .corruptedStore, let locations {
                do {
                    if try DatabaseBackupManager.restoreBackup(primaryDatabaseURL: locations.databaseURL) {
                        let queue = try DatabaseQueue(path: locations.databaseURL.path, configuration: configuration)
                        try runMigrations(on: queue)
                        applyDatabaseFileProtection(databaseURL: locations.databaseURL)
                        scheduleDailyBackupIfNeeded()
                        return .available(DatabaseManager(dbQueue: queue, wasRestoredFromBackup: true))
                    }
                } catch { return .unavailable(startupFailure(from: error, locations: locations)) }
            }
            return .unavailable(startupFailure(from: error, locations: locations))
        }
    }

    private static func databaseURL() throws -> URL {
        try databaseLocations().databaseURL
    }

    /// Pins data-at-rest protection for the SQLite store and its WAL sidecar
    /// files. `.completeUntilFirstUserAuthentication` keeps health data
    /// encrypted on disk after reboot until first unlock while still allowing
    /// the background sync engine to run once the device has been unlocked.
    ///
    /// This complements field-level AES encryption (FieldEncryption) for the
    /// most sensitive columns; full-page SQLCipher was evaluated and deferred:
    /// it requires a CocoaPods-based GRDB build that conflicts with the
    /// XcodeGen + SPM release pipeline.
    private static func applyDatabaseFileProtection(databaseURL: URL) {
        let fileManager = FileManager.default
        let protectedURLs = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]
        for url in protectedURLs where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: url.path
                )
            } catch {
                #if DEBUG
                fputs("Failed to apply database file protection: \(error)\n", stderr)
                #endif
            }
        }
    }

    private static func databaseLocations() throws -> DatabaseLocations {
        let fileManager = FileManager.default
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dbDirectory = appSupport.appendingPathComponent("LifeOS", isDirectory: true)
        try fileManager.createDirectory(at: dbDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedDirectory = dbDirectory
        try protectedDirectory.setResourceValues(values)
        return DatabaseLocations(
            databaseDirectoryURL: dbDirectory,
            databaseURL: dbDirectory.appendingPathComponent("lifeos.db")
        )
    }

    // MARK: - Daily Backup

    /// Kicks off the daily local SQLite backup off the startup critical path.
    /// Backup failures are logged and swallowed inside DatabaseBackupManager.
    private static func scheduleDailyBackupIfNeeded() {
        guard !UITestBootstrap.disableBackgroundWork else { return }
        Task.detached {
            await DatabaseBackupManager.shared.performBackupIfDue()
        }
    }

    private static func startupFailure(
        from error: Error,
        locations: DatabaseLocations?
    ) -> PersistentStartupFailure {
        PersistentStartupFailure(
            kind: classifyPersistentStartupFailure(error),
            reason: error.localizedDescription,
            databaseURL: locations?.databaseURL,
            databaseDirectoryURL: locations?.databaseDirectoryURL
        )
    }

    private static func classifyPersistentStartupFailure(_ error: Error) -> PersistentStartupFailure.Kind {
        if error as? DatabaseInitializationError == .corruptedStore { return .corruptedStore }
        if let initializationError = error as? DatabaseInitializationError,
           initializationError == .forcedPersistentFailure {
            return .unknown
        }

        let nsError = error as NSError
        let diagnostic = [
            nsError.domain,
            nsError.localizedDescription,
            String(describing: error)
        ]
            .joined(separator: " ")
            .lowercased()

        if diagnostic.contains("migration") || diagnostic.contains("schema") {
            return .migrationFailed
        }
        if diagnostic.contains("sqlite_corrupt")
            || diagnostic.contains("sqlite_notadb")
            || diagnostic.contains("malformed")
            || diagnostic.contains("not a database") {
            return .corruptedStore
        }
        if diagnostic.contains("sqlite_full")
            || diagnostic.contains("database or disk is full")
            || diagnostic.contains("no space left") {
            return .insufficientSpace
        }
        if diagnostic.contains("sqlite_locked")
            || diagnostic.contains("sqlite_busy")
            || diagnostic.contains("before first unlock")
            || diagnostic.contains("resource temporarily unavailable")
            || diagnostic.contains("protected data") {
            return .lockedStorage
        }
        if diagnostic.contains("sqlite_cantopen")
            || diagnostic.contains("permission")
            || diagnostic.contains("not permitted")
            || diagnostic.contains("could not open")
            || diagnostic.contains("read-only file system") {
            return .inaccessibleStore
        }

        switch nsError.domain {
        case NSCocoaErrorDomain:
            switch nsError.code {
            case NSFileWriteOutOfSpaceError:
                return .insufficientSpace
            case NSFileNoSuchFileError,
                 NSFileReadNoPermissionError,
                 NSFileWriteNoPermissionError,
                 NSFileWriteUnknownError:
                return .inaccessibleStore
            default:
                break
            }
        default:
            break
        }

        return .unknown
    }

    // MARK: - Migrations

    func runMigrations() throws {
        try Self.runMigrations(on: dbQueue)
    }

    private static func runMigrations(on dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        // In development, wipe DB on schema mismatch for fast iteration.
        // Remove in production.
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        Migrations.registerAll(migrator: &migrator)

        try migrator.migrate(dbQueue)
    }
}

#if DEBUG
extension DatabaseManager {
    static func _testMakeManagerWithForcedPersistentFailure() -> DatabaseManager {
        let fallbackQueue: DatabaseQueue
        do {
            fallbackQueue = try DatabaseQueue(configuration: configuration)
            try Self.runMigrations(on: fallbackQueue)
        } catch {
            preconditionFailure("Failed to initialize test-only in-memory database: \(error)")
        }
        return DatabaseManager(dbQueue: fallbackQueue, isInMemoryFallback: true)
    }

    static func _testMakePersistentStartupStateWithForcedPersistentFailure() -> PersistentStartupState {
        makePersistentStartupState(forcePersistentFailure: true)
    }

    static func _testLogPersistentInitFailure(error: Error, forcePersistentFailure: Bool) {
        logPersistentInitFailure(error: error, forcePersistentFailure: forcePersistentFailure)
    }
}
#endif

enum MixedUUIDStorage {
    static func encode(_ uuid: UUID) -> String {
        uuid.uuidString
    }

    static func rawData(_ uuid: UUID) -> Data {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }

    static func decode(from row: Row, column: String) -> UUID? {
        let value: DatabaseValue = row[column]
        return decode(from: value)
    }

    static func decode(from value: DatabaseValue) -> UUID? {
        if let uuidString = String.fromDatabaseValue(value), let uuid = UUID(uuidString: uuidString) {
            return uuid
        }
        if let uuid = UUID.fromDatabaseValue(value) {
            return uuid
        }
        if let uuidData = Data.fromDatabaseValue(value) {
            return decode(from: uuidData)
        }
        return nil
    }

    static func decode(from data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        let bytes = [UInt8](data)
        let uuidTuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuidTuple)
    }
}

enum UserIdentityLookup {
    static func resolveUserId(authId: String?, db: Database) throws -> UUID? {
        guard let authId, !authId.isEmpty else { return nil }

        let row: Row?
        do {
            row = try fetchUserIdRow(authId: authId, db: db, orderedByUpdatedAt: true)
        } catch where isMissingUpdatedAtColumn(error: error) {
            row = try fetchUserIdRow(authId: authId, db: db, orderedByUpdatedAt: false)
        }

        guard let row else { return nil }
        return MixedUUIDStorage.decode(from: row, column: "id")
    }

    static func fetchUser(authId: String?, db: Database) throws -> User? {
        guard let authId, !authId.isEmpty else { return nil }

        do {
            return try fetchUser(authId: authId, db: db, orderedByUpdatedAt: true)
        } catch where isMissingUpdatedAtColumn(error: error) {
            return try fetchUser(authId: authId, db: db, orderedByUpdatedAt: false)
        }
    }

    private static func fetchUserIdRow(
        authId: String,
        db: Database,
        orderedByUpdatedAt: Bool
    ) throws -> Row? {
        let orderClause = orderedByUpdatedAt
            ? """
              ORDER BY
                  CASE WHEN sync.row_id IS NULL THEN 1 ELSE 0 END ASC,
                  users.updated_at DESC
              """
            : ""
        if let authUUID = UUID(uuidString: authId) {
            return try Row.fetchOne(
                db,
                sql: """
                    SELECT users.id
                    FROM users
                    LEFT JOIN sync_row_state AS sync
                      ON sync.table_name = 'users'
                     AND (
                            sync.row_id = users.id
                         OR lower(CAST(sync.row_id AS TEXT)) = lower(CAST(users.id AS TEXT))
                     )
                    WHERE users.auth_id = ? OR users.auth_id = ?
                    \(orderClause)
                    LIMIT 1
                    """,
                arguments: [authUUID, authId]
            )
        }

        return try Row.fetchOne(
            db,
            sql: """
                SELECT users.id
                FROM users
                LEFT JOIN sync_row_state AS sync
                  ON sync.table_name = 'users'
                 AND (
                        sync.row_id = users.id
                     OR lower(CAST(sync.row_id AS TEXT)) = lower(CAST(users.id AS TEXT))
                 )
                WHERE users.auth_id = ?
                \(orderClause)
                LIMIT 1
                """,
            arguments: [authId]
        )
    }

    private static func fetchUser(
        authId: String,
        db: Database,
        orderedByUpdatedAt: Bool
    ) throws -> User? {
        let orderClause = orderedByUpdatedAt
            ? """
              ORDER BY
                  CASE WHEN sync.row_id IS NULL THEN 1 ELSE 0 END ASC,
                  users.updated_at DESC
              """
            : ""
        if let authUUID = UUID(uuidString: authId) {
            return try User.fetchOne(
                db,
                sql: """
                    SELECT users.*
                    FROM users
                    LEFT JOIN sync_row_state AS sync
                      ON sync.table_name = 'users'
                     AND (
                            sync.row_id = users.id
                         OR lower(CAST(sync.row_id AS TEXT)) = lower(CAST(users.id AS TEXT))
                     )
                    WHERE users.auth_id = ? OR users.auth_id = ?
                    \(orderClause)
                    LIMIT 1
                    """,
                arguments: [authUUID, authId]
            )
        }

        return try User.fetchOne(
            db,
            sql: """
                SELECT users.*
                FROM users
                LEFT JOIN sync_row_state AS sync
                  ON sync.table_name = 'users'
                 AND (
                        sync.row_id = users.id
                     OR lower(CAST(sync.row_id AS TEXT)) = lower(CAST(users.id AS TEXT))
                 )
                WHERE users.auth_id = ?
                \(orderClause)
                LIMIT 1
                """,
            arguments: [authId]
        )
    }

    private static func isMissingUpdatedAtColumn(error: Error) -> Bool {
        guard let databaseError = error as? DatabaseError else { return false }
        return databaseError.message?.contains("no such column: updated_at") == true
    }
}
