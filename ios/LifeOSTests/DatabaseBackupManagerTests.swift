import Foundation
import GRDB
import XCTest
@testable import LifeOS

final class DatabaseBackupManagerTests: XCTestCase {

    private func makeTempDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "lifeos.db-backup-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    private func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func mainBackupFileNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("lifeos_backup_") && $0.hasSuffix(".sqlite") }
            .sorted()
    }

    func testPruneBackupsKeepsNewestThreeGroupsAndDeletesOlderSidecars() throws {
        let directory = try makeTempDirectory(named: "lifeos-db-backup-prune")
        defer { try? FileManager.default.removeItem(at: directory) }

        let backupFilesByName: [String: Data] = [
            "lifeos_backup_2026-08-21_100000.sqlite": Data([0x01]),
            "lifeos_backup_2026-08-22_100000.sqlite": Data([0x02]),
            "lifeos_backup_2026-08-22_100000.sqlite-wal": Data([0x03]),
            "lifeos_backup_2026-08-23_100000.sqlite": Data([0x04]),
            "lifeos_backup_2026-08-24_100000.sqlite": Data([0x05]),
            "lifeos_backup_2026-08-24_100000.sqlite-shm": Data([0x06]),
            "lifeos_backup_2026-08-25_100000.sqlite": Data([0x07]),
        ]
        for (name, contents) in backupFilesByName {
            try contents.write(to: directory.appendingPathComponent(name))
        }

        try DatabaseBackupManager.pruneBackups(in: directory)

        XCTAssertEqual(try mainBackupFileNames(in: directory), [
            "lifeos_backup_2026-08-23_100000.sqlite",
            "lifeos_backup_2026-08-24_100000.sqlite",
            "lifeos_backup_2026-08-25_100000.sqlite",
        ])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("lifeos_backup_2026-08-21_100000.sqlite").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("lifeos_backup_2026-08-22_100000.sqlite-wal").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("lifeos_backup_2026-08-24_100000.sqlite-shm").path
            )
        )
    }

    func testPerformBackupIfDueCreatesAtMostOneBackupPerCalendarDay() async throws {
        let tempRoot = try makeTempDirectory(named: "lifeos-db-backup-due")
        let databaseDirectory = tempRoot.appendingPathComponent("LifeOS", isDirectory: true)
        let backupsDirectory = tempRoot.appendingPathComponent("LifeOSBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let databaseURL = databaseDirectory.appendingPathComponent("lifeos.db")
        let dbQueue = try DatabaseQueue(path: databaseURL.path)
        try await dbQueue.write { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "CREATE TABLE demo (id INTEGER PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO demo (id) VALUES (1)")
        }
        nonisolated(unsafe) let sendableDefaults = defaults

        let firstBackupDay = Date(timeIntervalSince1970: 1_788_000_000)
        let firstManager = DatabaseBackupManager(
            dbQueueProvider: { dbQueue },
            defaultsProvider: { sendableDefaults },
            backupsDirectoryProvider: { backupsDirectory },
            now: { firstBackupDay }
        )
        await firstManager.performBackupIfDue()

        var mainBackups = try mainBackupFileNames(in: backupsDirectory)
        XCTAssertEqual(mainBackups.count, 1)
        XCTAssertEqual(
            defaults.string(forKey: DatabaseBackupManager.lastBackupDayDefaultsKey),
            dayString(for: firstBackupDay)
        )
        if FileManager.default.fileExists(atPath: databaseURL.path + "-wal") {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: backupsDirectory.appendingPathComponent(mainBackups[0] + "-wal").path
                )
            )
        }

        // A second run on the same calendar day must not duplicate the backup,
        // even from a fresh manager instance sharing the persisted due-check.
        let sameDayManager = DatabaseBackupManager(
            dbQueueProvider: { dbQueue },
            defaultsProvider: { sendableDefaults },
            backupsDirectoryProvider: { backupsDirectory },
            now: { firstBackupDay }
        )
        await sameDayManager.performBackupIfDue()
        mainBackups = try mainBackupFileNames(in: backupsDirectory)
        XCTAssertEqual(mainBackups.count, 1)

        // The next calendar day produces a second retained copy.
        let nextBackupDay = firstBackupDay.addingTimeInterval(86_400)
        let nextDayManager = DatabaseBackupManager(
            dbQueueProvider: { dbQueue },
            defaultsProvider: { sendableDefaults },
            backupsDirectoryProvider: { backupsDirectory },
            now: { nextBackupDay }
        )
        await nextDayManager.performBackupIfDue()
        mainBackups = try mainBackupFileNames(in: backupsDirectory)
        XCTAssertEqual(mainBackups.count, 2)
        XCTAssertEqual(
            defaults.string(forKey: DatabaseBackupManager.lastBackupDayDefaultsKey),
            dayString(for: nextBackupDay)
        )
    }

    func testNewestValidBackupURLRequiresSQLiteIntegrityAndSkipsCorruptFiles() throws {
        let directory = try makeTempDirectory(named: "lifeos-db-backup-restore")
        defer { try? FileManager.default.removeItem(at: directory) }

        let valid = try DatabaseQueue(path: directory.appendingPathComponent("lifeos_backup_2026-08-20_120000.sqlite").path)
        try valid.write { db in
            try db.execute(sql: "CREATE TABLE history (value TEXT)")
            try db.execute(sql: "INSERT INTO history VALUES (?)", arguments: ["preserved"])
        }
        try valid.close()
        try Data([0x01, 0x02]).write(to: directory.appendingPathComponent("lifeos_backup_2026-08-24_120000.sqlite"))
        try Data().write(to: directory.appendingPathComponent("lifeos_backup_2026-08-25_120000.sqlite"))
        try Data([0x09]).write(to: directory.appendingPathComponent("unrelated.sqlite"))

        let restoredURL = DatabaseBackupManager.newestValidBackupURL(in: directory)

        XCTAssertEqual(restoredURL?.lastPathComponent, "lifeos_backup_2026-08-20_120000.sqlite")

        let emptyDirectory = try makeTempDirectory(named: "lifeos-db-backup-restore-empty")
        defer { try? FileManager.default.removeItem(at: emptyDirectory) }

        XCTAssertNil(DatabaseBackupManager.newestValidBackupURL(in: emptyDirectory))
    }

    func testFinishErasureReleasesBackupFenceForFreshProfile() async throws {
        let root = try makeTempDirectory(named: "lifeos-backup-erasure-fence")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("lifeos.db")
        let backupsURL = root.appendingPathComponent("backups", isDirectory: true)
        let queue = try DatabaseQueue(path: databaseURL.path)
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE data (value INTEGER)")
        }
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        nonisolated(unsafe) let sendableDefaults = defaults
        let manager = DatabaseBackupManager(
            dbQueueProvider: { queue },
            defaultsProvider: { sendableDefaults },
            backupsDirectoryProvider: { backupsURL },
            now: Date.init
        )

        try await manager.removeAllBackupsForErasure()
        await manager.performBackupIfDue()
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupsURL.path))

        await manager.finishErasure()
        await manager.performBackupIfDue()
        XCTAssertEqual(try mainBackupFileNames(in: backupsURL).count, 1)
    }
    func testRestorePreservesDamagedPrimaryAndRecoversCommittedHistory() throws {
        let directory = try makeTempDirectory(named: "lifeos-recovery")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backup = directory.appendingPathComponent("lifeos_backup_2026-09-09_120000.sqlite")
        let queue = try DatabaseQueue(path: backup.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE history (value TEXT)")
            try db.execute(sql: "INSERT INTO history VALUES (?)", arguments: ["valuable history"])
        }
        try queue.close()
        let primary = directory.appendingPathComponent("lifeos.db")
        let damagedBytes = Data("damaged SQLite evidence".utf8)
        try damagedBytes.write(to: primary)
        XCTAssertTrue(try DatabaseBackupManager.restoreBackup(primaryDatabaseURL: primary, backupsDirectory: directory))
        XCTAssertTrue(DatabaseBackupManager.isValidDatabase(at: primary))
        let restored = try DatabaseQueue(path: primary.path)
        XCTAssertEqual(try restored.read { try String.fetchOne($0, sql: "SELECT value FROM history") }, "valuable history")
        try restored.close()
        let quarantine = directory.appendingPathComponent("RecoveryQuarantine")
        let snapshots = try FileManager.default.contentsOfDirectory(at: quarantine, includingPropertiesForKeys: nil)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(try Data(contentsOf: snapshots[0].appendingPathComponent("lifeos.db")), damagedBytes)
    }

}
