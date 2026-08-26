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

        await Self.checkpointWal(on: dbQueue)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let backupURL = try Self.copyDatabase(
                at: URL(fileURLWithPath: databasePath),
                timestamp: currentDate,
                into: directory
            )
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
            let attributes = try? FileManager.default.attributesOfItem(atPath: backupURL.path)
            if let fileSize = attributes?[.size] as? Int, fileSize > 0 {
                return backupURL
            }
        }
        return nil
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
