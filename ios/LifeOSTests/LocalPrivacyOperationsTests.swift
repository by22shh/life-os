import Foundation
import CryptoKit
import GRDB
import XCTest
@testable import LifeOS

final class LocalPrivacyOperationsTests: XCTestCase {

    func testPortableExportIncludesWorkoutChildrenAndDecryptedLocalHealthValues() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let sessionId = UUID()
        let exerciseId = UUID()
        let directory = try makeTempExportsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            try WorkoutSession(id: sessionId, userId: userId, startedAt: Date(), sessionDate: "2026-09-09", source: .manual).insert(db)
            try WorkoutExercise(id: exerciseId, sessionId: sessionId, exerciseId: nil, orderInSession: 1).insert(db)
            try WorkoutSet(exerciseEntryId: exerciseId, userId: userId, setNumber: 1).insert(db)
            try HealthMeasurement(userId: userId, biomarkerName: "Ferritin", value: 78.4, unit: "ng/mL").insert(db)
        }
        let url = try await LocalPrivacyExportWriter.createExport(exportId: UUID().uuidString, user: LocalPrivacyUserContext(userId: userId, authId: authId), dbQueue: manager.dbQueue, exportsDirectoryOverride: directory)
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tables = try XCTUnwrap(root["tables"] as? [String: [[String: Any]]])
        XCTAssertEqual(tables["workout_exercises"]?.first?["id"] as? String, exerciseId.uuidString.lowercased())
        XCTAssertEqual(tables["workout_sets"]?.first?["exercise_entry_id"] as? String, exerciseId.uuidString.lowercased())
        XCTAssertEqual(tables["health_measurements"]?.first?["value"] as? String, "78.4")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("enc:v1:"))
    }

    func testErasureDoesNotCertifyCompletionWhenBackupCleanupFails() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        try await manager.dbQueue.write { db in try Self.insertUser(db, userId: userId, authId: authId) }
        do {
            _ = try await LocalPrivacyErasureExecutor.execute(reason: "user_requested", user: LocalPrivacyUserContext(userId: userId, authId: authId), dbQueue: manager.dbQueue, dependencies: .init(removeLocalExports: {}, deleteDeviceKey: {}, removeRawAssetsAndBackups: { throw TestFailure.exportCleanup }))
            XCTFail("Expected cleanup failure")
        } catch { XCTAssertEqual(error as? TestFailure, .exportCleanup) }
        let status = try await LocalPrivacyErasureExecutor.latestStatus(userId: userId, dbQueue: manager.dbQueue)
        XCTAssertEqual(status?.deletionState, "failed")
        let count = try await manager.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM users") }
        XCTAssertEqual(count, 1)
    }

    func testArchiveImportRestoresLocalSnapshotFromEnvelope() async throws {
        let source = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let sessionId = UUID()
        let exerciseId = UUID()
        let catalogId = UUID()
        let directory = try makeTempExportsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await source.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            try WorkoutSession(id: sessionId, userId: userId, startedAt: Date(), sessionDate: "2026-09-10", source: .manual).insert(db)
            try WorkoutExercise(id: exerciseId, sessionId: sessionId, exerciseId: nil, orderInSession: 1).insert(db)
            try WorkoutSet(exerciseEntryId: exerciseId, userId: userId, setNumber: 1).insert(db)
            try db.execute(
                sql: """
                    INSERT INTO exercise_catalog
                        (id, name, category, is_custom, created_by, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [catalogId.uuidString, "Custom Move", "strength", true, userId.uuidString, Date(), Date()]
            )
        }

        let exportURL = try await LocalPrivacyExportWriter.createExport(
            exportId: UUID().uuidString,
            user: LocalPrivacyUserContext(userId: userId, authId: authId),
            dbQueue: source.dbQueue,
            exportsDirectoryOverride: directory
        )
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: exportURL))
        let envelope = try JSONSerialization.data(withJSONObject: [
            "export_version": "2.0",
            "cloud_snapshot": [:],
            "local_snapshot": document
        ])

        let destination = try DatabaseManager.inMemory()
        let summary = try await LocalPrivacyArchiveImporter.importArchive(
            data: envelope,
            user: LocalPrivacyUserContext(userId: userId, authId: authId),
            dbQueue: destination.dbQueue
        )

        XCTAssertGreaterThan(summary.importedRows, 0)
        try await destination.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM users"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workout_sessions"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workout_exercises"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workout_sets"), 1)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM exercise_catalog WHERE created_by = ?", arguments: [userId.uuidString]),
                1
            )
        }
    }

    func testArchiveImportSkipsForeignUsersAndDeviceScopedState() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let foreignUserId = UUID()
        let foreignAuthId = UUID()
        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
        }

        let archive: [String: Any] = [
            "metadata": [
                "exportId": UUID().uuidString,
                "generatedAt": "2026-09-10T00:00:00Z",
                "scope": "local_only",
                "userId": userId.uuidString,
                "authId": authId.uuidString
            ],
            "tables": [
                "users": [[
                    "id": foreignUserId.uuidString,
                    "auth_id": foreignAuthId.uuidString,
                    "timezone": "UTC"
                ]],
                "food_logs": [[
                    "id": UUID().uuidString,
                    "user_id": foreignUserId.uuidString,
                    "logged_date": "2026-09-10",
                    "calories": 500
                ]],
                "outbox_events": [[
                    "id": UUID().uuidString,
                    "status": "pending",
                    "path": "api-food-log"
                ]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: archive)

        let summary = try await LocalPrivacyArchiveImporter.importArchive(
            data: data,
            user: LocalPrivacyUserContext(userId: userId, authId: authId),
            dbQueue: manager.dbQueue
        )

        XCTAssertEqual(summary.importedRows, 0)
        try await manager.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM users"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM food_logs"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox_events"), 0)
        }
    }

    func testArchiveImportKeepsExistingRows() async throws {
        let source = try DatabaseManager.inMemory()
        let destination = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let logId = UUID()
        let directory = try makeTempExportsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await source.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            try db.execute(
                sql: """
                    INSERT INTO food_logs
                        (id, user_id, logged_at, logged_date, input_method, calories, protein_g, fat_g, carbs_g, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [logId.uuidString, userId.uuidString, Date(), "2026-09-10", "manual", 300, 10, 10, 30, Date(), Date()]
            )
        }
        try await destination.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            try db.execute(
                sql: """
                    INSERT INTO food_logs
                        (id, user_id, logged_at, logged_date, input_method, calories, protein_g, fat_g, carbs_g, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [logId.uuidString, userId.uuidString, Date(), "2026-09-10", "manual", 777, 10, 10, 30, Date(), Date()]
            )
        }

        let exportURL = try await LocalPrivacyExportWriter.createExport(
            exportId: UUID().uuidString,
            user: LocalPrivacyUserContext(userId: userId, authId: authId),
            dbQueue: source.dbQueue,
            exportsDirectoryOverride: directory
        )
        _ = try await LocalPrivacyArchiveImporter.importArchive(
            data: Data(contentsOf: exportURL),
            user: LocalPrivacyUserContext(userId: userId, authId: authId),
            dbQueue: destination.dbQueue
        )

        let calories = try await destination.dbQueue.read { db in
            try Double.fetchOne(
                db,
                sql: "SELECT calories FROM food_logs WHERE id = ?",
                arguments: [logId.uuidString]
            )
        }
        XCTAssertEqual(calories, 777)
    }

    func testArchiveImportNormalizesUUIDsAndEncryptsHealthValuesAtRest() async throws {
        let fixedKey = SymmetricKey(size: .bits256)
        FieldEncryption._testSetDeviceKeyOverride { fixedKey }
        defer { FieldEncryption._testResetOverrides() }
        let source = try DatabaseManager.inMemory()
        let destination = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let directory = try makeTempExportsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await source.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            try HealthMeasurement(
                userId: userId,
                biomarkerName: "Ferritin",
                value: 78.4,
                unit: "ng/mL"
            ).insert(db)
        }
        try await destination.dbQueue.write { db in
            // GRDB stores this UUID upper-case. The portable archive carries
            // it lower-case, which used to create a second local profile.
            try Self.insertUser(db, userId: userId, authId: authId)
        }

        let archiveURL = try await LocalPrivacyExportWriter.createExport(
            exportId: UUID().uuidString,
            user: LocalPrivacyUserContext(userId: userId, authId: authId),
            dbQueue: source.dbQueue,
            exportsDirectoryOverride: directory
        )
        _ = try await LocalPrivacyArchiveImporter.importArchive(
            data: Data(contentsOf: archiveURL),
            user: LocalPrivacyUserContext(userId: userId, authId: authId),
            dbQueue: destination.dbQueue
        )

        try await destination.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM users"), 1)
            let encryptedValue = try XCTUnwrap(String.fetchOne(
                db,
                sql: "SELECT value FROM health_measurements LIMIT 1"
            ))
            XCTAssertTrue(encryptedValue.hasPrefix("enc:v1:"))
        }
    }

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

    func testPurgeUserScopedDataAlsoRemovesDeviceScopedAICache() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            try db.execute(
                sql: """
                    INSERT INTO ai_cache (id, cache_key, payload, created_at, expires_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "cache-1",
                    "insight-summary",
                    Data([0x01, 0x02, 0x03]),
                    Date(),
                    Date().addingTimeInterval(3600),
                ]
            )
            try LocalUserDataReset.purgeUserScopedData(in: db)
        }

        try await manager.dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ai_cache") ?? -1, 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM users") ?? -1, 0)
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
            XCTAssertFalse(audit.storageDeleted)
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
