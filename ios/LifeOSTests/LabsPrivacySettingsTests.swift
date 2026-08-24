import Foundation
import GRDB
import XCTest
@testable import LifeOS

final class LabsPrivacySettingsTests: XCTestCase {

    private func insertUser(
        _ db: Database,
        userId: UUID,
        authId: UUID
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO users (id, auth_id, timezone, units, onboarding_completed, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                userId.uuidString,
                authId.uuidString,
                "UTC",
                "metric",
                false,
                Date(),
                Date()
            ]
        )
    }

    private func insertPrivacySettings(
        _ db: Database,
        id: UUID = UUID(),
        userId: UUID,
        medicalScanLocalOnly: Bool,
        cloudBackupEnabled: Bool,
        updatedAt: Date
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO privacy_settings (
                    id, user_id, menstrual_local_only, medical_scan_local_only, cloud_backup_enabled,
                    vector_opt_in, analytics_consent, cloud_ocr_enabled, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                id.uuidString,
                userId.uuidString,
                true,
                medicalScanLocalOnly,
                cloudBackupEnabled,
                false,
                false,
                true,
                updatedAt,
                updatedAt
            ]
        )
    }

    func testScopedPrivacySettingsIgnoresLatestRowFromAnotherUser() throws {
        let manager = try DatabaseManager.inMemory()
        let targetUserId = UUID()
        let targetAuthId = UUID()
        let otherUserId = UUID()
        let otherAuthId = UUID()
        let now = Date()

        try manager.dbQueue.write { db in
            try insertUser(db, userId: targetUserId, authId: targetAuthId)
            try insertUser(db, userId: otherUserId, authId: otherAuthId)

            try insertPrivacySettings(
                db,
                userId: targetUserId,
                medicalScanLocalOnly: true,
                cloudBackupEnabled: false,
                updatedAt: now
            )
            try insertPrivacySettings(
                db,
                userId: otherUserId,
                medicalScanLocalOnly: false,
                cloudBackupEnabled: true,
                updatedAt: now.addingTimeInterval(60)
            )
        }

        let resolvedSettings = try manager.dbQueue.read { db in
            try LabsScanCaptureView._testLoadScopedPrivacySettings(
                authId: targetAuthId.uuidString,
                db: db
            )
        }

        XCTAssertEqual(resolvedSettings?.userId, targetUserId)
        XCTAssertEqual(resolvedSettings?.medicalScanLocalOnly, true)
        XCTAssertEqual(resolvedSettings?.cloudBackupEnabled, false)
    }

    func testScopedPrivacySettingsFallsBackToLocalOnlyWhenRowIsMissing() throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()

        try manager.dbQueue.write { db in
            try insertUser(db, userId: userId, authId: authId)
        }

        let resolvedSettings = try manager.dbQueue.read { db in
            try LabsScanCaptureView._testLoadScopedPrivacySettings(
                authId: authId.uuidString,
                db: db
            )
        }

        XCTAssertEqual(resolvedSettings?.userId, userId)
        XCTAssertEqual(resolvedSettings?.medicalScanLocalOnly, true)
        XCTAssertEqual(resolvedSettings?.cloudBackupEnabled, false)
    }
}
