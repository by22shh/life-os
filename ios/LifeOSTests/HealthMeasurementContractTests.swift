import XCTest
import GRDB
@testable import LifeOS

final class HealthMeasurementContractTests: XCTestCase {
    func testHealthMeasurementDecodesCanonicalServerPayload() throws {
        let data = Data("""
        {
          "id": "00000000-0000-0000-0000-000000000025",
          "user_id": "00000000-0000-0000-0000-000000000001",
          "created_at": "2026-02-20T06:45:00Z",
          "updated_at": "2026-02-20T06:46:00Z",
          "marker_id": "glucose",
          "value": 5.6,
          "unit": "mmol/L",
          "original_value": 5.6,
          "original_unit": "mmol/L",
          "original_label": "Glucose",
          "status": "optimal",
          "reference_range_low": 3.9,
          "reference_range_high": 5.6,
          "measured_at": "2026-02-20",
          "source_scan_id": "00000000-0000-0000-0000-000000000024",
          "source_type": "scan",
          "confidence": 0.87,
          "manually_verified": false,
          "notes": "Fasting sample"
        }
        """.utf8)

        let measurement = try makeSupabaseDecoder().decode(HealthMeasurement.self, from: data)

        XCTAssertEqual(measurement.markerId, "glucose")
        XCTAssertEqual(measurement.biomarkerName, "Glucose")
        XCTAssertEqual(measurement.medicalScanId?.uuidString, "00000000-0000-0000-0000-000000000024")
        XCTAssertEqual(measurement.sourceScanId?.uuidString, "00000000-0000-0000-0000-000000000024")
        XCTAssertEqual(measurement.resolvedMeasuredDate, "2026-02-20")
        XCTAssertEqual(measurement.canonicalStatus, .optimal)
        let confidence = try XCTUnwrap(measurement.confidence)
        XCTAssertEqual(confidence, 0.87, accuracy: 0.0001)
        XCTAssertFalse(measurement.userCorrected)
    }

    func testHealthMeasurementDecodesLegacyPayloadForBackwardCompatibility() throws {
        let data = Data("""
        {
          "id": "00000000-0000-0000-0000-000000000125",
          "user_id": "00000000-0000-0000-0000-000000000001",
          "created_at": "2026-02-20T06:45:00Z",
          "updated_at": "2026-02-20T06:46:00Z",
          "medical_scan_id": "00000000-0000-0000-0000-000000000024",
          "biomarker_name": "Vitamin D",
          "value": 24,
          "unit": "ng/mL",
          "reference_range_low": 30,
          "reference_range_high": 100,
          "measured_date": "2026-02-20",
          "ai_confidence": 0.72,
          "user_corrected": true,
          "status": "out_of_range"
        }
        """.utf8)

        let measurement = try makeSupabaseDecoder().decode(HealthMeasurement.self, from: data)

        XCTAssertEqual(measurement.markerId, "vitamin_d")
        XCTAssertEqual(measurement.biomarkerName, "Vitamin D")
        XCTAssertEqual(measurement.medicalScanId?.uuidString, "00000000-0000-0000-0000-000000000024")
        XCTAssertEqual(measurement.sourceScanId?.uuidString, "00000000-0000-0000-0000-000000000024")
        XCTAssertEqual(measurement.resolvedMeasuredDate, "2026-02-20")
        let aiConfidence = try XCTUnwrap(measurement.aiConfidence)
        let confidence = try XCTUnwrap(measurement.confidence)
        XCTAssertEqual(aiConfidence, 0.72, accuracy: 0.0001)
        XCTAssertEqual(confidence, 0.72, accuracy: 0.0001)
        XCTAssertEqual(measurement.canonicalStatus, .low)
        XCTAssertTrue(measurement.userCorrected)
    }

    func testSyncEngineNormalizesLegacyHealthMeasurementPayload() async throws {
        let manager = try DatabaseManager.inMemory()
        let syncEngine = SyncEngine(dbQueue: manager.dbQueue)
        let scanId = UUID(uuidString: "00000000-0000-0000-0000-000000000024")!
        let body = Data("""
        {
          "id": "00000000-0000-0000-0000-000000000225",
          "user_id": "00000000-0000-0000-0000-000000000001",
          "medical_scan_id": "\(scanId.uuidString)",
          "biomarker_name": "Vitamin D",
          "value": 24,
          "unit": "ng/mL",
          "status": "out_of_range",
          "reference_range_low": 30,
          "reference_range_high": 100,
          "measured_at": "2026-02-20T06:45:00Z",
          "ai_confidence": 0.72,
          "user_corrected": true,
          "created_at": "2026-02-20T06:45:00Z",
          "updated_at": "2026-02-20T06:46:00Z"
        }
        """.utf8)

        let normalizedData = try await syncEngine._testSanitizeOutboundBody(
            body,
            path: "rest/v1/health_measurements"
        )
        let normalizedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: normalizedData) as? [String: Any]
        )

        XCTAssertEqual(normalizedObject["marker_id"] as? String, "vitamin_d")
        XCTAssertEqual(normalizedObject["source_scan_id"] as? String, scanId.uuidString)
        XCTAssertEqual(normalizedObject["status"] as? String, "low")
        XCTAssertEqual(normalizedObject["measured_at"] as? String, "2026-02-20")
        let confidence = try XCTUnwrap((normalizedObject["confidence"] as? NSNumber)?.doubleValue)
        XCTAssertEqual(confidence, 0.72, accuracy: 0.0001)
        XCTAssertEqual(normalizedObject["source_type"] as? String, "scan")
        XCTAssertEqual(normalizedObject["manually_verified"] as? Bool, false)
        XCTAssertNil(normalizedObject["medical_scan_id"])
        XCTAssertNil(normalizedObject["biomarker_name"])
        XCTAssertNil(normalizedObject["ai_confidence"])
        XCTAssertNil(normalizedObject["user_corrected"])
    }

    func testV23MigrationCanonicalizesLegacyRowsAndOutboxEvents() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        let scanId = UUID()
        let measurementId = UUID()
        let eventId = UUID()
        let measuredAt = try XCTUnwrap(HealthMeasurement.dateOnlyDate(from: "2026-02-20"))
        let createdAt = try XCTUnwrap(parseTestDate("2026-02-20T06:45:00Z"))
        let updatedAt = try XCTUnwrap(parseTestDate("2026-02-20T06:46:00Z"))

        try await manager.dbQueue.write { db in
            try user.insert(db)

            try db.execute(
                sql: """
                    INSERT INTO health_measurements (
                        id, user_id, medical_scan_id, biomarker_name, marker_id, value, unit,
                        original_label, status, reference_range_low, reference_range_high,
                        measured_at, source_type, ai_confidence, user_corrected, manually_verified,
                        created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    measurementId.uuidString,
                    user.id.uuidString,
                    scanId.uuidString,
                    "Vitamin D",
                    nil as String?,
                    24.0,
                    "ng/mL",
                    nil as String?,
                    "out_of_range",
                    30.0,
                    100.0,
                    measuredAt,
                    "scan",
                    0.72,
                    true,
                    false,
                    createdAt,
                    updatedAt,
                ]
            )

            var event = OutboxEvent(
                id: eventId,
                httpMethod: .POST,
                path: "rest/v1/health_measurements",
                bodyJson: Data("""
                {
                  "id": "\(measurementId.uuidString)",
                  "user_id": "\(user.id.uuidString)",
                  "medical_scan_id": "\(scanId.uuidString)",
                  "biomarker_name": "Vitamin D",
                  "value": 24,
                  "unit": "ng/mL",
                  "status": "out_of_range",
                  "reference_range_low": 30,
                  "reference_range_high": 100,
                  "measured_at": "2026-02-20T06:45:00Z",
                  "ai_confidence": 0.72,
                  "user_corrected": true,
                  "created_at": "2026-02-20T06:45:00Z",
                  "updated_at": "2026-02-20T06:46:00Z"
                }
                """.utf8)
            )
            event.headersJson = try JSONSerialization.data(
                withJSONObject: ["Content-Type": "application/json"]
            )
            try event.insert(db)

            try Migrations._testApplyV23HealthMeasurementsContractHardeningMigration(db: db)

            let row = try XCTUnwrap(
                Row.fetchOne(
                    db,
                    sql: """
                        SELECT marker_id, source_scan_id, status, confidence, source_type, measured_date
                        FROM health_measurements
                        WHERE id = ?
                        """,
                    arguments: [measurementId.uuidString]
                )
            )
            XCTAssertEqual(row["marker_id"] as String?, "vitamin_d")
            XCTAssertEqual(row["source_scan_id"] as String?, scanId.uuidString)
            XCTAssertEqual(row["status"] as String?, "low")
            let confidence = try XCTUnwrap(row["confidence"] as Double?)
            XCTAssertEqual(confidence, 0.72, accuracy: 0.0001)
            XCTAssertEqual(row["source_type"] as String?, "scan")
            XCTAssertEqual(row["measured_date"] as String?, "2026-02-20")

            let bodyData = try XCTUnwrap(
                Data.fetchOne(
                    db,
                    sql: "SELECT body_json FROM outbox_events WHERE id = ?",
                    arguments: [eventId.uuidString]
                )
            )
            let normalizedObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            )
            XCTAssertEqual(normalizedObject["marker_id"] as? String, "vitamin_d")
            XCTAssertEqual(normalizedObject["status"] as? String, "low")
            XCTAssertEqual(normalizedObject["source_scan_id"] as? String, scanId.uuidString)
            XCTAssertEqual(normalizedObject["measured_at"] as? String, "2026-02-20")
            XCTAssertNil(normalizedObject["medical_scan_id"])
            XCTAssertNil(normalizedObject["biomarker_name"])
        }
    }

    private func makeSupabaseDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { nestedDecoder in
            let container = try nestedDecoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            if let parsed = self.parseTestDate(rawValue) {
                return parsed
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported test date value: \(rawValue)"
            )
        }
        return decoder
    }

    private func parseTestDate(_ rawValue: String) -> Date? {
        ISO8601DateFormatter.supabaseDate(from: rawValue)
            ?? ISO8601DateFormatter.noFractionalDate(from: rawValue)
            ?? HealthMeasurement.dateOnlyDate(from: rawValue)
    }
}
