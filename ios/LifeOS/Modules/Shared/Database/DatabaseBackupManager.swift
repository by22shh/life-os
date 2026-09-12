// MARK: - Database Backup Manager
// Source of truth: life_os_error_handling.md (Crash Recovery & Database Corruption)

import Foundation
import GRDB
import OSLog

/// Daily local SQLite backups with three-copy retention supporting the
/// corruption-recovery ladder. All failures are logged and swallowed so
/// backups can never crash the app.
actor DatabaseBackupManager {

    /// Shared manager backing up the persistent LifeOS store.
    static let shared = DatabaseBackupManager()

    private static let logger = Logger(subsystem: "com.lifeos.app", category: "DatabaseBackup")

    static let lastBackupDayDefaultsKey = "lifeos.last_db_backup_day"
    private static let backupFilePrefix = "lifeos_backup_"
    private static let retentionCount = 3
    private static let sidecarSuffixes = ["-wal", "-shm"]

    private let dbQueueProvider: @Sendable () -> DatabaseQueue?
    private let defaultsProvider: @Sendable () -> UserDefaults?
    private let backupsDirectoryProvider: @Sendable () -> URL?
    private var erasureInProgress = false
    private let now: @Sendable () -> Date

    init(
        dbQueueProvider: @escaping @Sendable () -> DatabaseQueue? = { DatabaseManager.sharedStartupState.manager?.dbQueue },
        defaultsProvider: @escaping @Sendable () -> UserDefaults? = { .standard },
        backupsDirectoryProvider: @escaping @Sendable () -> URL? = { DatabaseBackupManager.defaultBackupsDirectory() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dbQueueProvider = dbQueueProvider
        self.defaultsProvider = defaultsProvider
        self.backupsDirectoryProvider = backupsDirectoryProvider
        self.now = now
    }

    // MARK: - Backup

    /// Copies the SQLite store plus its WAL sidecar files into the backup
    /// directory at most once per calendar day.
    func performBackupIfDue() async {
        guard !erasureInProgress else { return }
        guard let dbQueue = dbQueueProvider() else {
            Self.logger.info("Database backup skipped: persistent store unavailable")
            return
        }
        let databasePath = dbQueue.path
        guard !databasePath.isEmpty else {
            Self.logger.info("Database backup skipped: store has no file path")
            return
        }
        guard let defaults = defaultsProvider(), let directory = backupsDirectoryProvider() else {
            Self.logger.info("Database backup skipped: backup destination unavailable")
            return
        }

        let currentDate = now()
        let today = Self.dayString(for: currentDate)
        guard defaults.string(forKey: Self.lastBackupDayDefaultsKey) != today else { return }


        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            Self.excludeFromDeviceBackups(directory)
            let backupURL = directory.appendingPathComponent("\(Self.backupFilePrefix)\(Self.backupTimestampString(for: currentDate)).sqlite")
            // SQLite online backup takes a consistent snapshot, including committed WAL pages.
            let destination = try DatabaseQueue(path: backupURL.path)
            try dbQueue.backup(to: destination)
            try destination.close()
            guard Self.isValidDatabase(at: backupURL) else { throw CocoaError(.fileReadCorruptFile) }
            Self.applyFileProtection(toFilesMatching: backupURL)
            try Self.pruneBackups(in: directory)
            defaults.set(today, forKey: Self.lastBackupDayDefaultsKey)
            Self.logger.info("Created database backup \(backupURL.lastPathComponent, privacy: .public)")
        } catch {
            Self.logger.error("Database backup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Restore

    /// Returns the newest restorable backup for a corrupt primary database.
    /// A backup qualifies when its file exists and is non-empty; the caller
    /// decides whether to copy it over the primary store.
    nonisolated static func newestValidBackupURL(primaryDatabaseURL: URL) -> URL? {
        guard let backupsDirectory = defaultBackupsDirectory() else { return nil }
        return newestValidBackupURL(in: backupsDirectory)
    }

    /// Newest backup file passing basic sanity checks within a directory,
    /// injected so restore lookup stays testable without the app container.
    nonisolated static func newestValidBackupURL(in backupsDirectory: URL) -> URL? {
        let backupURLs = (try? sortedBackupFileURLs(in: backupsDirectory)) ?? []
        for backupURL in backupURLs where !isSidecar(backupURL) {
            if isValidDatabase(at: backupURL) { return backupURL }
        }
        return nil
    }

    nonisolated static func isValidDatabase(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            // SQLite considers a zero-byte file a new empty database, which is
            // not a recoverable snapshot of an existing user's history.
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber, size.int64Value >= 100 else { return false }
            let handle = try FileHandle(forReadingFrom: url)
            let header = try handle.read(upToCount: 16)
            try handle.close()
            guard header == Data("SQLite format 3\0".utf8) else { return false }
            var config = Configuration()
            config.readonly = true
            let queue = try DatabaseQueue(path: url.path, configuration: config)
            defer { try? queue.close() }
            return try queue.read { db in
                let integrity = try String.fetchAll(db, sql: "PRAGMA integrity_check")
                let foreignKeys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
                return integrity == ["ok"] && foreignKeys.isEmpty
            }
        } catch { return false }
    }

    /// Never overwrite damaged evidence: preserve it in a protected quarantine first.
    @discardableResult
    nonisolated static func restoreBackup(primaryDatabaseURL: URL, backupsDirectory: URL? = nil) throws -> Bool {
        guard let directory = backupsDirectory ?? defaultBackupsDirectory(),
              let backup = newestValidBackupURL(in: directory) else { return false }
        let fm = FileManager.default
        let quarantine = primaryDatabaseURL.deletingLastPathComponent()
            .appendingPathComponent("RecoveryQuarantine", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
        excludeFromDeviceBackups(quarantine)
        // Prepare and validate a standalone copy before touching the primary files.
        let staging = quarantine.appendingPathComponent("restored.sqlite")
        let source = try DatabaseQueue(path: backup.path)
        let destination = try DatabaseQueue(path: staging.path)
        try source.backup(to: destination)
        try source.close()
        try destination.close()
        guard isValidDatabase(at: staging) else { throw CocoaError(.fileReadCorruptFile) }
        for suffix in [""] + sidecarSuffixes {
            let original = URL(fileURLWithPath: primaryDatabaseURL.path + suffix)
            if fm.fileExists(atPath: original.path) {
                try fm.copyItem(at: original, to: quarantine.appendingPathComponent(original.lastPathComponent))
            }
        }
        for suffix in sidecarSuffixes {
            let original = URL(fileURLWithPath: primaryDatabaseURL.path + suffix)
            if fm.fileExists(atPath: original.path) { try fm.removeItem(at: original) }
        }
        // Atomic replacement: a failed write leaves the primary itself intact.
        try Data(contentsOf: staging).write(to: primaryDatabaseURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try fm.removeItem(at: staging)
        applyFileProtection(toFilesMatching: primaryDatabaseURL)
        return true
    }

    func removeAllBackupsForErasure() throws {
        erasureInProgress = true
        if let directory = backupsDirectoryProvider(), FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw CocoaError(.fileWriteUnknown) }
        }
        defaultsProvider()?.removeObject(forKey: Self.lastBackupDayDefaultsKey)
    }

    /// Releases the temporary erasure fence after the caller has completed the
    /// database purge. Keeping this state forever made every subsequent fresh
    /// profile in the same process permanently ineligible for backups.
    func finishErasure() {
        erasureInProgress = false
    }

    // MARK: - Retention

    /// Keeps only the newest `keepingNewest` backups, deleting older ones.
    nonisolated static func pruneBackups(
        in directory: URL,
        keepingNewest retentionCount: Int = DatabaseBackupManager.retentionCount
    ) throws {
        let backupURLs = try sortedBackupFileURLs(in: directory)
        var seenGroupNames: Set<String> = []
        var outdatedGroupNames: Set<String> = []
        var keptGroupCount = 0
        for groupName in backupURLs.map(groupName(of:)) where !seenGroupNames.contains(groupName) {
            seenGroupNames.insert(groupName)
            if keptGroupCount < retentionCount {
                keptGroupCount += 1
            } else {
                outdatedGroupNames.insert(groupName)
            }
        }

        guard !outdatedGroupNames.isEmpty else { return }
        for backupURL in backupURLs where outdatedGroupNames.contains(groupName(of: backupURL)) {
            try FileManager.default.removeItem(at: backupURL)
        }
    }

    // MARK: - File Helpers

    private static func copyDatabase(
        at databaseURL: URL,
        timestamp: Date,
        into directory: URL
    ) throws -> URL {
        let fileManager = FileManager.default
        let backupName = "\(backupFilePrefix)\(backupTimestampString(for: timestamp)).sqlite"
        let backupURL = directory.appendingPathComponent(backupName)
        try fileManager.copyItem(at: databaseURL, to: backupURL)

        for suffix in sidecarSuffixes {
            let sidecarURL = URL(fileURLWithPath: databaseURL.path + suffix)
            guard fileManager.fileExists(atPath: sidecarURL.path) else { continue }
            try fileManager.copyItem(at: sidecarURL, to: URL(fileURLWithPath: backupURL.path + suffix))
        }
        return backupURL
    }

    /// Best-effort TRUNCATE checkpoint before copying so the main file holds
    /// every committed page and WAL sidecars stay empty during the copy.
    private static func checkpointWal(on dbQueue: DatabaseQueue) async {
        do {
            try await dbQueue.write { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
        } catch {
            logger.error("WAL checkpoint before backup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Keeps raw health database copies out of iCloud/iTunes device backups.
    /// Field-encrypted columns stay ciphertext regardless (the key never
    /// leaves the Keychain), but plaintext health columns must not leave the
    /// sandbox via a backup channel the user does not associate with Life OS.
    private static func excludeFromDeviceBackups(_ directory: URL) {
        do {
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableDirectory = directory
            try mutableDirectory.setResourceValues(resourceValues)
        } catch {
            logger.error(
                "Failed to exclude backups directory from device backups: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Pins data-at-rest protection on backup copies, matching the primary
    /// database handling in DatabaseManager.
    private static func applyFileProtection(toFilesMatching backupURL: URL) {
        let fileManager = FileManager.default
        let protectedURLs = [
            backupURL,
            URL(fileURLWithPath: backupURL.path + "-wal"),
            URL(fileURLWithPath: backupURL.path + "-shm"),
        ]
        for url in protectedURLs where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: url.path
                )
            } catch {
                logger.error("Failed to apply backup file protection: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func sortedBackupFileURLs(in directory: URL) throws -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix(backupFilePrefix) && name.contains(".sqlite")
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private static func groupName(of backupURL: URL) -> String {
        let name = backupURL.lastPathComponent
        for suffix in sidecarSuffixes where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    private static func isSidecar(_ backupURL: URL) -> Bool {
        sidecarSuffixes.contains { backupURL.lastPathComponent.hasSuffix($0) }
    }

    private nonisolated static func defaultBackupsDirectory() -> URL? {
        let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport?.appendingPathComponent("LifeOSBackups", isDirectory: true)
    }

    private static func dayString(for date: Date) -> String {
        string(from: date, dateFormat: "yyyy-MM-dd")
    }

    private static func backupTimestampString(for date: Date) -> String {
        string(from: date, dateFormat: "yyyy-MM-dd_HHmmss")
    }

    private static func string(from date: Date, dateFormat: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = dateFormat
        return formatter.string(from: date)
    }
}
