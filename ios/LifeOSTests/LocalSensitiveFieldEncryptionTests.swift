import XCTest
import GRDB
import CryptoKit
@testable import LifeOS

final class LocalSensitiveFieldEncryptionTests: XCTestCase {
    func testEncryptForStorageDoesNotTrustPlaintextThatLooksLikeEnvelope() throws {
        let plaintext = "enc:v1:https://example.com/private-scan.jpg"

        let storedValue = try XCTUnwrap(FieldEncryption.encryptForStorage(plaintext))

        XCTAssertTrue(FieldEncryption.isStorageEncrypted(storedValue))
        XCTAssertNotEqual(storedValue, plaintext)
        XCTAssertEqual(FieldEncryption.decryptStoredString(storedValue), plaintext)
    }

    func testV25MigrationEncryptsLegacyPlaintextRowsAndKeepsModelsReadable() throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        let foodLogId = UUID()
        let scanId = UUID()
        let measurementId = UUID()
        let now = Date()
        let imageURL = "file:///private/var/mobile/Containers/Data/Application/scan-preview.jpg"
        let originalImageURL = "medical-scans/\(scanId.uuidString.lowercased())/original.pdf"

        try manager.dbQueue.write { db in
            try user.insert(db)

            try db.execute(
                sql: """
                    INSERT INTO food_logs (
                        id, user_id, created_at, updated_at, logged_at, logged_date, input_method,
                        pre_workout, post_workout, calories, protein_g, fat_g, carbs_g,
                        user_corrected, synced_to_vector_db, needs_review, location_lat, location_lng
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    foodLogId.uuidString,
                    user.id.uuidString,
                    now,
                    now,
                    now,
                    "2026-03-16",
                    NutritionInputMethod.manual.rawValue,
                    false,
                    false,
                    620.0,
                    32.0,
                    18.0,
                    58.0,
                    false,
                    false,
                    false,
                    55.0415,
                    82.9346,
                ]
            )

            try db.execute(
                sql: """
                    INSERT INTO medical_scans (
                        id, user_id, scan_type, status, image_url, original_image_url,
                        user_reviewed, needs_review, manually_verified, pinned_by_user,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    scanId.uuidString,
                    user.id.uuidString,
                    ScanType.bloodTest.rawValue,
                    ScanStatus.completed.rawValue,
                    imageURL,
                    originalImageURL,
                    false,
                    false,
                    false,
                    false,
                    now,
                    now,
                ]
            )

            try db.execute(
                sql: """
                    INSERT INTO health_measurements (
                        id, user_id, medical_scan_id, biomarker_name, value, unit, original_value,
                        user_corrected, manually_verified, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    measurementId.uuidString,
                    user.id.uuidString,
                    scanId.uuidString,
                    "Glucose",
                    5.6,
                    "mmol/L",
                    5.6,
                    false,
                    false,
                    now,
                    now,
                ]
            )

            try Migrations._testApplyV25LocalSensitiveFieldEncryptionMigration(db: db)

            let storedLocationLat = try XCTUnwrap(
                String.fetchOne(
                    db,
                    sql: "SELECT location_lat FROM food_logs WHERE id = ?",
                    arguments: [foodLogId.uuidString]
                )
            )
            let storedLocationLng = try XCTUnwrap(
                String.fetchOne(
                    db,
                    sql: "SELECT location_lng FROM food_logs WHERE id = ?",
                    arguments: [foodLogId.uuidString]
                )
            )
            let storedImageURL = try XCTUnwrap(
                String.fetchOne(
                    db,
                    sql: "SELECT image_url FROM medical_scans WHERE id = ?",
                    arguments: [scanId.uuidString]
                )
            )
            let storedOriginalImageURL = try XCTUnwrap(
                String.fetchOne(
                    db,
                    sql: "SELECT original_image_url FROM medical_scans WHERE id = ?",
                    arguments: [scanId.uuidString]
                )
            )
            let storedValue = try XCTUnwrap(
                String.fetchOne(
                    db,
                    sql: "SELECT value FROM health_measurements WHERE id = ?",
                    arguments: [measurementId.uuidString]
                )
            )
            let storedOriginalValue = try XCTUnwrap(
                String.fetchOne(
                    db,
                    sql: "SELECT original_value FROM health_measurements WHERE id = ?",
                    arguments: [measurementId.uuidString]
                )
            )

            XCTAssertTrue(FieldEncryption.isStorageEncrypted(storedLocationLat))
            XCTAssertTrue(FieldEncryption.isStorageEncrypted(storedLocationLng))
            XCTAssertTrue(FieldEncryption.isStorageEncrypted(storedImageURL))
            XCTAssertTrue(FieldEncryption.isStorageEncrypted(storedOriginalImageURL))
            XCTAssertTrue(FieldEncryption.isStorageEncrypted(storedValue))
            XCTAssertTrue(FieldEncryption.isStorageEncrypted(storedOriginalValue))

            let foodLog = try XCTUnwrap(
                FoodLog.fetchOne(
                    db,
                    sql: "SELECT * FROM food_logs WHERE id = ?",
                    arguments: [foodLogId.uuidString]
                )
            )
            XCTAssertEqual(try XCTUnwrap(foodLog.locationLat), 55.0415, accuracy: 0.0001)
            XCTAssertEqual(try XCTUnwrap(foodLog.locationLng), 82.9346, accuracy: 0.0001)

            let scan = try XCTUnwrap(
                MedicalScan.fetchOne(
                    db,
                    sql: "SELECT * FROM medical_scans WHERE id = ?",
                    arguments: [scanId.uuidString]
                )
            )
            XCTAssertEqual(scan.imageUrl, imageURL)
            XCTAssertEqual(scan.originalImageUrl, originalImageURL)

            let measurement = try XCTUnwrap(
                HealthMeasurement.fetchOne(
                    db,
                    sql: "SELECT * FROM health_measurements WHERE id = ?",
                    arguments: [measurementId.uuidString]
                )
            )
            XCTAssertEqual(measurement.value, 5.6, accuracy: 0.0001)
            XCTAssertEqual(try XCTUnwrap(measurement.originalValue), 5.6, accuracy: 0.0001)
        }
    }

    func testNewModelWritesPersistSensitiveFieldsEncryptedAtRest() throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        let scanId = UUID()
        let now = Date()

        try manager.dbQueue.write { db in
            try user.insert(db)

            var foodLog = FoodLog(
                userId: user.id,
                loggedAt: now,
                loggedDate: "2026-03-16",
                inputMethod: .manual,
                calories: 540,
                proteinG: 30,
                fatG: 20,
                carbsG: 52
            )
            foodLog.locationLat = 40.7128
            foodLog.locationLng = -74.0060
            try foodLog.insert(db)

            var medicalScan = MedicalScan(id: scanId, userId: user.id, scanType: .bloodTest)
            medicalScan.status = .completed
            medicalScan.imageUrl = "file:///private/var/mobile/Containers/Data/Application/latest-scan.jpg"
            medicalScan.originalImageUrl = "medical-scans/\(scanId.uuidString.lowercased())/original.jpg"
            try medicalScan.insert(db)

            var measurement = HealthMeasurement(
                userId: user.id,
                biomarkerName: "Ferritin",
                value: 78.4,
                unit: "ng/mL"
            )
            measurement.medicalScanId = scanId
            measurement.sourceScanId = scanId
            measurement.originalValue = 78.4
            try measurement.insert(db)

            let storedFoodLat = try XCTUnwrap(
                String.fetchOne(
                    db,
                    sql: "SELECT location_lat FROM food_logs WHERE id = ?",
                    arguments: [foodLog.id.uuidString]
                )
            )
            let storedFoodLng = try XCTUnwrap(
                String.fetchOne(
                    db,
                    sql: "SELECT location_lng FROM food_logs WHERE id = ?",
                    arguments: [foodLog.id.uuidString]
                )
            )
            let storedImageURL = try XCTUnwrap(
                String.fetchOne(
                    db,
                    sql: "SELECT image_url FROM medical_scans WHERE id = ?",
                    arguments: [scanId.uuidString]
                )
            )
            let storedOriginalImageURL = try XCTUnwrap(
                String.fetchOne(
                    db,
                    sql: "SELECT original_image_url FROM medical_scans WHERE id = ?",
                    arguments: [scanId.uuidString]
                )
            )
            let storedMeasurementValue = try XCTUnwrap(
                String.fetchOne(
                    db,
                    sql: "SELECT value FROM health_measurements WHERE id = ?",
                    arguments: [measurement.id.uuidString]
                )
            )
            let storedMeasurementOriginalValue = try XCTUnwrap(
                String.fetchOne(
                    db,
                    sql: "SELECT original_value FROM health_measurements WHERE id = ?",
                    arguments: [measurement.id.uuidString]
                )
            )

            XCTAssertTrue(FieldEncryption.isStorageEncrypted(storedFoodLat))
            XCTAssertTrue(FieldEncryption.isStorageEncrypted(storedFoodLng))
            XCTAssertTrue(FieldEncryption.isStorageEncrypted(storedImageURL))
            XCTAssertTrue(FieldEncryption.isStorageEncrypted(storedOriginalImageURL))
            XCTAssertTrue(FieldEncryption.isStorageEncrypted(storedMeasurementValue))
            XCTAssertTrue(FieldEncryption.isStorageEncrypted(storedMeasurementOriginalValue))
        }
    }

    func testDeviceKeyConcurrentFirstUseReturnsSingleStableKey() throws {
        let cleanup = configureIsolatedEncryptionKeychain()
        defer { cleanup() }

        let lock = NSLock()
        var serializedKeys: [Data] = []
        var failures = 0

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            do {
                let keyData = serializeKey(try FieldEncryption.deviceKey())
                lock.lock()
                serializedKeys.append(keyData)
                lock.unlock()
            } catch {
                lock.lock()
                failures += 1
                lock.unlock()
            }
        }

        XCTAssertEqual(failures, 0)
        XCTAssertEqual(serializedKeys.count, 32)
        XCTAssertEqual(Set(serializedKeys).count, 1)

        let persistedKey = try FieldEncryption.deviceKey()
        XCTAssertEqual(try XCTUnwrap(Set(serializedKeys).first), serializeKey(persistedKey))
    }

    func testSensitiveInsertRollsBackWhenDeviceKeyPreparationFails() throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())

        try manager.dbQueue.write { db in
            try user.insert(db)
        }

        FieldEncryption._testSetDeviceKeyOverride { throw FieldEncryptionTestError.deviceKeyUnavailable }
        defer { FieldEncryption._testResetOverrides() }

        var foodLog = FoodLog(
            userId: user.id,
            loggedAt: Date(),
            loggedDate: "2026-03-16",
            inputMethod: .manual,
            calories: 420,
            proteinG: 28,
            fatG: 14,
            carbsG: 51
        )
        foodLog.locationLat = 55.0415
        foodLog.locationLng = 82.9346

        XCTAssertThrowsError(
            try manager.dbQueue.write { db in
                try foodLog.insert(db)
            }
        ) { error in
            XCTAssertEqual(error as? FieldEncryptionTestError, .deviceKeyUnavailable)
        }

        try manager.dbQueue.read { db in
            XCTAssertEqual(
                try XCTUnwrap(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM food_logs")),
                0
            )
        }
    }

    func testSensitiveInsertRollsBackWhenEncryptionFailsDuringEncoding() throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        let scanId = UUID()

        try manager.dbQueue.write { db in
            try user.insert(db)
        }

        FieldEncryption._testSetDeviceKeyOverride { SymmetricKey(size: .bits256) }
        FieldEncryption._testSetRawEncryptionOverride { _, _ in
            throw FieldEncryptionTestError.rawEncryptionUnavailable
        }
        defer { FieldEncryption._testResetOverrides() }

        var medicalScan = MedicalScan(id: scanId, userId: user.id, scanType: .bloodTest)
        medicalScan.status = .completed
        medicalScan.imageUrl = "file:///private/var/mobile/Containers/Data/Application/failing-scan.jpg"
        medicalScan.originalImageUrl = "medical-scans/\(scanId.uuidString.lowercased())/original.jpg"

        XCTAssertThrowsError(
            try manager.dbQueue.write { db in
                try medicalScan.insert(db)
            }
        ) { error in
            guard let fieldError = error as? FieldEncryptionError else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            guard case let .persistenceEncryptionFailure(column, reason) = fieldError else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(column, "image_url")
            XCTAssertTrue(reason.contains("rawEncryptionUnavailable"))
        }

        try manager.dbQueue.read { db in
            XCTAssertEqual(
                try XCTUnwrap(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM medical_scans")),
                0
            )
        }
    }
}

private enum FieldEncryptionTestError: LocalizedError, Equatable {
    case deviceKeyUnavailable
    case rawEncryptionUnavailable

    var errorDescription: String? {
        switch self {
        case .deviceKeyUnavailable:
            return "deviceKeyUnavailable"
        case .rawEncryptionUnavailable:
            return "rawEncryptionUnavailable"
        }
    }
}

private extension LocalSensitiveFieldEncryptionTests {
    func configureIsolatedEncryptionKeychain() -> () -> Void {
        FieldEncryption._testResetOverrides()

        let namespace = UUID().uuidString.lowercased()
        FieldEncryption._testSetKeychainIdentityOverride(
            service: "com.lifeos.field-encryption.tests.\(namespace)",
            account: "aes256-gcm-device-key"
        )
        try? FieldEncryption.deleteDeviceKey()

        return {
            try? FieldEncryption.deleteDeviceKey()
            FieldEncryption._testResetOverrides()
        }
    }

    func serializeKey(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}
