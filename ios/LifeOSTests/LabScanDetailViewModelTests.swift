import XCTest
import GRDB
import CryptoKit
@testable import LifeOS

@MainActor
final class LabScanDetailViewModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Health measurements are encrypted at rest. Keep these database tests
        // independent of the simulator's Keychain availability.
        let fixedKey = SymmetricKey(size: .bits256)
        FieldEncryption._testSetDeviceKeyOverride { fixedKey }
    }

    override func tearDown() {
        FieldEncryption._testResetOverrides()
        super.tearDown()
    }

    func testLoadUsesLocalMeasurementsWhenPresent() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        let scanId = UUID()

        try await manager.dbQueue.write { db in
            try user.insert(db)

            var scan = MedicalScan(id: scanId, userId: user.id, scanType: .bloodTest)
            scan.status = .reviewRequired
            scan.scanDate = "2026-03-01"
            scan.storageMode = "cloud"
            scan.notes = "Hemoglobin 13.4 g/dL"
            try scan.insert(db)

            var measurement = HealthMeasurement(
                userId: user.id,
                biomarkerName: "Hemoglobin",
                value: 13.4,
                unit: "g/dL"
            )
            measurement.medicalScanId = scanId
            measurement.sourceScanId = scanId
            measurement.status = HealthMeasurementStatus.optimal.rawValue
            measurement.referenceRangeLow = 12.0
            measurement.referenceRangeHigh = 17.5
            measurement.measuredDate = "2026-03-01"
            try measurement.insert(db)
        }

        let viewModel = LabScanDetailViewModel(
            scanId: scanId,
            dbQueue: manager.dbQueue,
            remoteLoader: { _ in nil },
            shouldFetchRemote: false
        )

        await viewModel.load()

        XCTAssertNotNil(viewModel.scan)
        XCTAssertEqual(viewModel.markerSummaries.count, 1)
        XCTAssertEqual(viewModel.markerSummaries.first?.name, "Hemoglobin")
        XCTAssertEqual(viewModel.markerSummaries.first?.valueText, "13.4 g/dL")
    }

    func testLoadFallsBackToProcessedDataMarkers() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        let scanId = UUID()
        let processedMarkers = [
            ExtractedLabMarker(
                id: UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!,
                name: "CRP",
                value: "4.8",
                unit: "mg/L",
                referenceRange: "0-5",
                isNormal: true
            )
        ]

        try await manager.dbQueue.write { db in
            try user.insert(db)

            var scan = MedicalScan(id: scanId, userId: user.id, scanType: .bloodTest)
            scan.status = .completed
            scan.storageMode = "cloud"
            scan.processedData = try JSONEncoder().encode(processedMarkers)
            try scan.insert(db)
        }

        let viewModel = LabScanDetailViewModel(
            scanId: scanId,
            dbQueue: manager.dbQueue,
            remoteLoader: { _ in nil },
            shouldFetchRemote: false
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.markerSummaries.count, 1)
        XCTAssertEqual(viewModel.markerSummaries.first?.name, "CRP")
        XCTAssertEqual(viewModel.markerSummaries.first?.referenceRangeText, "0-5")
    }

    func testLoadKeepsLegacyMeasurementStatusReadable() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        let scanId = UUID()

        try await manager.dbQueue.write { db in
            try user.insert(db)

            var scan = MedicalScan(id: scanId, userId: user.id, scanType: .bloodTest)
            scan.status = .completed
            scan.scanDate = "2026-03-01"
            scan.storageMode = "cloud"
            try scan.insert(db)

            var measurement = HealthMeasurement(
                userId: user.id,
                biomarkerName: "Vitamin D",
                value: 24,
                unit: "ng/mL"
            )
            measurement.medicalScanId = scanId
            measurement.sourceScanId = scanId
            measurement.status = "normal"
            measurement.referenceRangeLow = 20
            measurement.referenceRangeHigh = 50
            measurement.measuredDate = "2026-03-01"
            try measurement.insert(db)
        }

        let viewModel = LabScanDetailViewModel(
            scanId: scanId,
            dbQueue: manager.dbQueue,
            remoteLoader: { _ in nil },
            shouldFetchRemote: false
        )

        await viewModel.load()

        XCTAssertEqual(
            viewModel.markerSummaries.first?.statusText,
            String(localized: "labs_within_range")
        )
    }

    func testMarkReviewedPersistsAndQueuesOutboxForCloudScan() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        let scanId = UUID()

        try await manager.dbQueue.write { db in
            try user.insert(db)

            var scan = MedicalScan(id: scanId, userId: user.id, scanType: .bloodTest)
            scan.status = .reviewRequired
            scan.needsReview = true
            scan.userReviewed = false
            scan.manuallyVerified = false
            scan.storageMode = "cloud"
            scan.scanDate = "2026-03-01"
            try scan.insert(db)
        }

        let viewModel = LabScanDetailViewModel(
            scanId: scanId,
            dbQueue: manager.dbQueue,
            remoteLoader: { _ in nil },
            shouldFetchRemote: false
        )

        await viewModel.load()
        await viewModel.markReviewed()

        try await manager.dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT status, needs_review, user_reviewed, manually_verified
                    FROM medical_scans
                    WHERE id = ?
                    """,
                arguments: [scanId.uuidString]
            )

            XCTAssertEqual(row?["status"] as String?, ScanStatus.completed.rawValue)
            XCTAssertEqual(row?["needs_review"] as Bool?, false)
            XCTAssertEqual(row?["user_reviewed"] as Bool?, true)
            XCTAssertEqual(row?["manually_verified"] as Bool?, true)

            let outboxCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?",
                arguments: ["api-labs"]
            ) ?? 0
            XCTAssertEqual(outboxCount, 1)

            let bodyData = try Data.fetchOne(
                db,
                sql: """
                    SELECT body_json
                    FROM outbox_events
                    WHERE path = ?
                    ORDER BY created_at_local DESC
                    LIMIT 1
                    """,
                arguments: ["api-labs"]
            )
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try XCTUnwrap(bodyData)) as? [String: Any]
            )
            XCTAssertEqual(payload["status"] as? String, ScanStatus.completed.rawValue)
            XCTAssertEqual(payload["needs_review"] as? Bool, false)
            XCTAssertEqual(payload["user_reviewed"] as? Bool, true)
        }
    }

    func testTogglePinnedSkipsOutboxForLocalOnlyScan() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        let scanId = UUID()

        try await manager.dbQueue.write { db in
            try user.insert(db)

            var scan = MedicalScan(id: scanId, userId: user.id, scanType: .bloodTest)
            scan.status = .completed
            scan.storageMode = "local_only"
            scan.pinnedByUser = false
            try scan.insert(db)
        }

        let viewModel = LabScanDetailViewModel(
            scanId: scanId,
            dbQueue: manager.dbQueue,
            remoteLoader: { _ in nil },
            shouldFetchRemote: false
        )

        await viewModel.load()
        await viewModel.togglePinned()

        try await manager.dbQueue.read { db in
            let pinned = try Bool.fetchOne(
                db,
                sql: "SELECT pinned_by_user FROM medical_scans WHERE id = ?",
                arguments: [scanId.uuidString]
            )
            XCTAssertEqual(pinned, true)

            let outboxCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?",
                arguments: ["api-labs"]
            ) ?? 0
            XCTAssertEqual(outboxCount, 0)
        }
    }

    func testLoadUsesRemoteSnapshotWhenLocalRowMissing() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        let scanId = UUID()

        try await manager.dbQueue.write { db in
            try user.insert(db)
        }

        let remoteSnapshot: LabScanDetailSnapshot = {
            var scan = MedicalScan(id: scanId, userId: user.id, scanType: .bloodTest)
            scan.status = .completed
            scan.storageMode = "cloud"
            scan.scanDate = "2026-03-02"

            var measurement = HealthMeasurement(
                userId: user.id,
                biomarkerName: "Ferritin",
                value: 58,
                unit: "ng/mL"
            )
            measurement.medicalScanId = scanId
            measurement.sourceScanId = scanId
            measurement.status = HealthMeasurementStatus.optimal.rawValue
            measurement.referenceRangeLow = 30
            measurement.referenceRangeHigh = 400

            return LabScanDetailSnapshot(scan: scan, measurements: [measurement])
        }()

        let viewModel = LabScanDetailViewModel(
            scanId: scanId,
            dbQueue: manager.dbQueue,
            remoteLoader: { id in
                guard id == scanId else {
                    throw NSError(domain: "LabScanDetailViewModelTests", code: 1)
                }
                return remoteSnapshot
            },
            shouldFetchRemote: true
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.scan?.id, scanId)
        XCTAssertEqual(viewModel.markerSummaries.first?.name, "Ferritin")

        try await manager.dbQueue.read { db in
            let scanCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM medical_scans WHERE id = ?",
                arguments: [scanId.uuidString]
            ) ?? 0
            let measurementCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM health_measurements WHERE source_scan_id = ?",
                arguments: [scanId.uuidString]
            ) ?? 0

            XCTAssertEqual(scanCount, 1)
            XCTAssertEqual(measurementCount, 1)
        }
    }

    func testLoadResolvesSignedDocumentURLForStoragePath() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        let scanId = UUID()
        let storagePath = "medical-scans/\(user.authId.uuidString.lowercased())/\(scanId.uuidString.lowercased())/original.pdf"
        let signedURL = try XCTUnwrap(URL(string: "https://example.com/signed/original.pdf"))

        try await manager.dbQueue.write { db in
            try user.insert(db)

            var scan = MedicalScan(id: scanId, userId: user.id, scanType: .bloodTest)
            scan.status = .completed
            scan.storageMode = "cloud"
            scan.originalImageUrl = storagePath
            scan.scanDate = "2026-03-14"
            try scan.insert(db)
        }

        let viewModel = LabScanDetailViewModel(
            scanId: scanId,
            dbQueue: manager.dbQueue,
            remoteLoader: { _ in nil },
            documentURLResolver: { scan in
                XCTAssertEqual(
                    LabScanCloudStorage.storagePath(from: scan.originalImageUrl),
                    "\(user.authId.uuidString.lowercased())/\(scanId.uuidString.lowercased())/original.pdf"
                )
                return signedURL
            },
            shouldFetchRemote: false
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.documentURL, signedURL)
        XCTAssertEqual(viewModel.documentName, "original.pdf")
    }

    func testCorrectAndDeleteMeasurementPersistLocallyAndQueueReplacementPayload() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        let scanId = UUID()
        let measurementId = UUID()

        try await manager.dbQueue.write { db in
            try user.insert(db)
            var scan = MedicalScan(id: scanId, userId: user.id, scanType: .bloodTest)
            scan.status = .completed
            scan.storageMode = "cloud"
            try scan.insert(db)

            var measurement = HealthMeasurement(
                id: measurementId,
                userId: user.id,
                biomarkerName: "Ferritin",
                value: 20,
                unit: "ng/mL"
            )
            measurement.medicalScanId = scanId
            measurement.sourceScanId = scanId
            try measurement.insert(db)
        }

        let viewModel = LabScanDetailViewModel(
            scanId: scanId,
            dbQueue: manager.dbQueue,
            remoteLoader: { _ in nil },
            shouldFetchRemote: false
        )
        await viewModel.load()
        var corrected = try XCTUnwrap(viewModel.measurements.first)
        corrected.value = 42
        corrected.unit = "µg/L"
        await viewModel.updateMeasurement(corrected)

        try await manager.dbQueue.read { db in
            let saved = try XCTUnwrap(HealthMeasurement.fetchOne(db, key: measurementId))
            XCTAssertEqual(saved.value, 42, accuracy: 0.001)
            XCTAssertEqual(saved.unit, "µg/L")
            XCTAssertTrue(saved.userCorrected)
            XCTAssertTrue(saved.manuallyVerified)
        }

        await viewModel.deleteMeasurement(id: measurementId)

        try await manager.dbQueue.read { db in
            XCTAssertNil(try HealthMeasurement.fetchOne(db, key: measurementId))
            let payload = try XCTUnwrap(
                Data.fetchOne(
                    db,
                    sql: "SELECT body_json FROM outbox_events WHERE path = ? ORDER BY created_at_local DESC LIMIT 1",
                    arguments: ["api-labs"]
                )
            )
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            let processedData = try XCTUnwrap(json["processed_data"] as? [String: Any])
            XCTAssertEqual((processedData["markers"] as? [[String: Any]])?.count, 0)
        }
    }

    func testRemoteMeasurementTombstoneDeletesLocalMarkerAndCancelsStaleOutbox() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        let scanId = UUID()
        let measurementId = UUID()
        let outboxId = UUID()
        var configuredRemoteScan = MedicalScan(id: scanId, userId: user.id, scanType: .bloodTest)
        configuredRemoteScan.status = .completed
        configuredRemoteScan.storageMode = "cloud"
        configuredRemoteScan.updatedAt = Date().addingTimeInterval(60)
        let remoteScan = configuredRemoteScan

        try await manager.dbQueue.write { db in
            try user.insert(db)
            var localScan = remoteScan
            localScan.updatedAt = Date().addingTimeInterval(-60)
            try localScan.insert(db)

            var measurement = HealthMeasurement(
                id: measurementId,
                userId: user.id,
                biomarkerName: "CRP",
                value: 4.2,
                unit: "mg/L"
            )
            measurement.medicalScanId = scanId
            measurement.sourceScanId = scanId
            try measurement.insert(db)

            var event = OutboxEvent(
                id: outboxId,
                httpMethod: .POST,
                path: "api-labs",
                bodyJson: Data("{\"measurement_id\":\"\(measurementId.uuidString)\"}".utf8)
            )
            event.status = .pending
            try event.insert(db)
        }

        let staleRemoteMeasurement = HealthMeasurement(
            id: measurementId,
            userId: user.id,
            biomarkerName: "CRP",
            value: 4.2,
            unit: "mg/L"
        )
        let remoteSnapshot = LabScanDetailSnapshot(
            scan: remoteScan,
            measurements: [staleRemoteMeasurement],
            deletedMeasurementIDs: [measurementId]
        )
        let viewModel = LabScanDetailViewModel(
            scanId: scanId,
            dbQueue: manager.dbQueue,
            remoteLoader: { _ in remoteSnapshot },
            shouldFetchRemote: true
        )
        await viewModel.load()
        await viewModel.refresh()

        try await manager.dbQueue.read { db in
            let remaining = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM health_measurements WHERE id = ?",
                arguments: [measurementId.uuidString]
            ) ?? -1
            XCTAssertEqual(remaining, 0)
            let status = try String.fetchOne(
                db,
                sql: "SELECT status FROM outbox_events WHERE id = ?",
                arguments: [outboxId.uuidString]
            )
            XCTAssertEqual(status, OutboxStatus.cancelled.rawValue)
        }
    }
}
