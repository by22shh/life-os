import Foundation
import GRDB
import XCTest
@testable import LifeOS

final class LocalPrivacyOperationsTests: XCTestCase {

    private enum TestFailure: LocalizedError, Equatable {
        case exportCleanup
        case keyDeletion

        var errorDescription: String? {
            switch self {
            case .exportCleanup:
                return "Export cleanup failed."
            case .keyDeletion:
                return "Key deletion failed."
            }
        }
    }

    private static func insertUser(_ db: Database, userId: UUID, authId: UUID) throws {
        var user = User(id: userId, authId: authId, timezone: "UTC", units: .metric)
        user.weightKg = 68
        try user.insert(db)
    }

    private func makeTempExportsDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-local-exports-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testNutritionPhotoDraftStorePersistsListsAndDeletesOfflineDraft() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-photo-drafts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageData = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let loggedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let draft = try NutritionPhotoDraftStore.save(
            imageData: imageData,
            targetDay: "2026-07-30",
            loggedAt: loggedAt,
            directoryOverride: directory
        )

        let listed = try NutritionPhotoDraftStore.list(
            targetDay: "2026-07-30",
            directoryOverride: directory
        )
        XCTAssertEqual(listed.map(\.id), [draft.id])
        XCTAssertEqual(
            try NutritionPhotoDraftStore.imageData(
                id: draft.id,
                directoryOverride: directory
            ),
            imageData
        )

        try NutritionPhotoDraftStore.delete(id: draft.id, directoryOverride: directory)
        XCTAssertTrue(
            try NutritionPhotoDraftStore.list(directoryOverride: directory).isEmpty
        )
    }

    func testLocalErasureRemovesExportsDeletesKeyAndMarksAuditCompliant() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let exportsDirectory = try makeTempExportsDirectory()
        defer {
            if FileManager.default.fileExists(atPath: exportsDirectory.path) {
                try? FileManager.default.removeItem(at: exportsDirectory)
            }
        }

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
        }

        let user = LocalPrivacyUserContext(userId: userId, authId: authId)
        let exportURL = try await LocalPrivacyExportWriter.createExport(
            exportId: UUID().uuidString,
            user: user,
            dbQueue: manager.dbQueue,
            exportsDirectoryOverride: exportsDirectory
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))

        final class DeleteKeyProbe: @unchecked Sendable {
            var callCount = 0
            var photoCleanupCallCount = 0
        }
        let probe = DeleteKeyProbe()

        let response = try await LocalPrivacyErasureExecutor.execute(
            reason: "user_requested",
            user: user,
            dbQueue: manager.dbQueue,
            dependencies: LocalPrivacyErasureDependencies(
                removeLocalExports: {
                    try LocalPrivacyExportWriter.removeAllExports(exportsDirectoryOverride: exportsDirectory)
                },
                deleteDeviceKey: {
                    probe.callCount += 1
                },
                removeNutritionPhotoDrafts: {
                    probe.photoCleanupCallCount += 1
                }
            )
        )

        XCTAssertEqual(response.deletionState, "completed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportsDirectory.path))
        XCTAssertEqual(probe.callCount, 1)
        XCTAssertEqual(probe.photoCleanupCallCount, 1)

        let latestStatus = try await LocalPrivacyErasureExecutor.latestStatus(
            userId: userId,
            dbQueue: manager.dbQueue
        )
        XCTAssertEqual(latestStatus?.deletionState, "completed")
        XCTAssertEqual(latestStatus?.deletionMode, "local_only")

        try await manager.dbQueue.read { db in
            let userCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM users") ?? 0
            XCTAssertEqual(userCount, 1)

            let audit = try XCTUnwrap(
                DeletionAuditLog.fetchOne(
                    db,
                    sql: "SELECT * FROM deletion_audit_log WHERE user_id_deleted = ? LIMIT 1",
                    arguments: [userId.uuidString]
                )
            )
            XCTAssertTrue(audit.storageDeleted)
            XCTAssertTrue(audit.complianceVerified)
            XCTAssertEqual(audit.notes, "local_only:user_requested")

            let failureCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM deletion_failures") ?? 0
            XCTAssertEqual(failureCount, 0)
        }
    }

    func testLocalErasureRecordsFailedStatusWhenExportCleanupFails() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
        }

        do {
            _ = try await LocalPrivacyErasureExecutor.execute(
                reason: "user_requested",
                user: LocalPrivacyUserContext(userId: userId, authId: authId),
                dbQueue: manager.dbQueue,
                dependencies: LocalPrivacyErasureDependencies(
                    removeLocalExports: {
                        throw TestFailure.exportCleanup
                    },
                    deleteDeviceKey: {}
                )
            )
            XCTFail("Expected export cleanup failure")
        } catch {
            XCTAssertEqual((error as? TestFailure), .exportCleanup)
        }

        let latestStatus = try await LocalPrivacyErasureExecutor.latestStatus(
            userId: userId,
            dbQueue: manager.dbQueue
        )
        XCTAssertEqual(latestStatus?.deletionState, "failed")
        XCTAssertEqual(latestStatus?.deletionMode, "local_only")

        try await manager.dbQueue.read { db in
            let userCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM users") ?? 0
            XCTAssertEqual(userCount, 1)

            let auditCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM deletion_audit_log") ?? 0
            XCTAssertEqual(auditCount, 0)

            let failure = try XCTUnwrap(
                DeletionFailure.fetchOne(
                    db,
                    sql: "SELECT * FROM deletion_failures WHERE user_id = ? LIMIT 1",
                    arguments: [userId.uuidString]
                )
            )
            XCTAssertEqual(failure.failureType, "local_export_cleanup")
            XCTAssertEqual(failure.error, "Export cleanup failed.")
            XCTAssertFalse(failure.resolved)
        }
    }

    func testLocalErasureMarksAuditIncompleteWhenKeyDeletionFails() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let exportsDirectory = try makeTempExportsDirectory()
        defer {
            if FileManager.default.fileExists(atPath: exportsDirectory.path) {
                try? FileManager.default.removeItem(at: exportsDirectory)
            }
        }

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
        }

        let user = LocalPrivacyUserContext(userId: userId, authId: authId)
        _ = try await LocalPrivacyExportWriter.createExport(
            exportId: UUID().uuidString,
            user: user,
            dbQueue: manager.dbQueue,
            exportsDirectoryOverride: exportsDirectory
        )

        do {
            _ = try await LocalPrivacyErasureExecutor.execute(
                reason: "user_requested",
                user: user,
                dbQueue: manager.dbQueue,
                dependencies: LocalPrivacyErasureDependencies(
                    removeLocalExports: {
                        try LocalPrivacyExportWriter.removeAllExports(exportsDirectoryOverride: exportsDirectory)
                    },
                    deleteDeviceKey: {
                        throw TestFailure.keyDeletion
                    }
                )
            )
            XCTFail("Expected key deletion failure")
        } catch {
            XCTAssertEqual((error as? TestFailure), .keyDeletion)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: exportsDirectory.path))

        let latestStatus = try await LocalPrivacyErasureExecutor.latestStatus(
            userId: userId,
            dbQueue: manager.dbQueue
        )
        XCTAssertEqual(latestStatus?.deletionState, "failed")
        XCTAssertEqual(latestStatus?.deletionMode, "local_only")

        try await manager.dbQueue.read { db in
            let userCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM users") ?? 0
            XCTAssertEqual(userCount, 1)

            let audit = try XCTUnwrap(
                DeletionAuditLog.fetchOne(
                    db,
                    sql: "SELECT * FROM deletion_audit_log WHERE user_id_deleted = ? LIMIT 1",
                    arguments: [userId.uuidString]
                )
            )
            XCTAssertTrue(audit.storageDeleted)
            XCTAssertFalse(audit.complianceVerified)
            XCTAssertEqual(audit.notes, "local_only:user_requested")

            let failure = try XCTUnwrap(
                DeletionFailure.fetchOne(
                    db,
                    sql: "SELECT * FROM deletion_failures WHERE user_id = ? LIMIT 1",
                    arguments: [userId.uuidString]
                )
            )
            XCTAssertEqual(failure.failureType, "local_device_key_cleanup")
            XCTAssertEqual(failure.error, "Key deletion failed.")
            XCTAssertFalse(failure.resolved)
        }
    }

    func testLatestLocalErasureStatusPrefersNewerFailureOverOlderCompletedAudit() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let oldDate = Date(timeIntervalSince1970: 1_000)
        let newDate = Date(timeIntervalSince1970: 2_000)

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            try DeletionAuditLog(
                userIdDeleted: userId,
                deletedAt: oldDate,
                storageDeleted: true,
                complianceVerified: true,
                notes: "local_only:user_requested"
            ).insert(db)
            try DeletionFailure(
                userId: userId,
                failureType: "local_export_cleanup",
                error: "Export cleanup failed.",
                createdAt: newDate
            ).insert(db)
        }

        let latestStatus = try await LocalPrivacyErasureExecutor.latestStatus(
            userId: userId,
            dbQueue: manager.dbQueue
        )
        XCTAssertEqual(latestStatus?.deletionState, "failed")
        XCTAssertEqual(latestStatus?.deletionMode, "local_only")
        XCTAssertEqual(latestStatus?.deletionDate, DateFormatting.iso8601FullString(from: newDate))
    }
}
