import XCTest
import SwiftUI
import GRDB
import ComposableArchitecture
@testable import LifeOS

final class LabsViewCoverageTests: XCTestCase {
    private func seedLabsUser(
        dbQueue: DatabaseQueue,
        userId: UUID,
        authId: UUID,
        medicalScanLocalOnly: Bool,
        cloudBackupEnabled: Bool
    ) async throws {
        try await dbQueue.write { db in
            var user = User(id: userId, authId: authId, timezone: "UTC", units: .metric)
            try user.insert(db)

            var settings = PrivacySettings(userId: userId)
            settings.medicalScanLocalOnly = medicalScanLocalOnly
            settings.cloudBackupEnabled = cloudBackupEnabled
            try settings.insert(db)
        }
    }

    func testLabsMarkerCatalogParsesAliasesDeduplicatesAndUsesCatalogFallbacks() {
        let text = """
        Hgb 13.4 g/dL (12-17.5)
        WBC 12.1 10^3/uL
        Ferritin 85
        Vitamin D: 21 ng/mL
        Custom Marker 7.2 mg/dL
        Hgb 13.4 g/dL
        Broken Value abc mg/dL
        """

        let markers = LabsMarkerCatalog.extractMarkers(from: text)

        XCTAssertEqual(markers.count, 5)
        XCTAssertEqual(markers.filter { $0.name == "Hemoglobin" }.count, 1)
        XCTAssertEqual(markers.first(where: { $0.name == "Hemoglobin" })?.referenceRange, "12-17.5")
        XCTAssertFalse(markers.first(where: { $0.name == "WBC" })?.isNormal ?? true)
        XCTAssertEqual(markers.first(where: { $0.name == "Ferritin" })?.unit, "ng/mL")
        XCTAssertFalse(markers.first(where: { $0.name == "Vitamin D" })?.isNormal ?? true)
        XCTAssertEqual(markers.first(where: { $0.name == "Custom Marker" })?.unit, "mg/dL")
    }

    func testLabsMarkerCatalogBoundsAndIdentifierBranches() {
        let explicitRangeMarker = ExtractedLabMarker(
            id: UUID(),
            name: "Custom Marker",
            value: "5.0",
            unit: "mg/dL",
            referenceRange: "4,5-6,5",
            isNormal: true
        )
        let catalogRangeMarker = ExtractedLabMarker(
            id: UUID(),
            name: "ALT",
            value: "30",
            unit: "U/L",
            referenceRange: nil,
            isNormal: true
        )
        let unknownMarker = ExtractedLabMarker(
            id: UUID(),
            name: "Mystery",
            value: "9",
            unit: "units",
            referenceRange: nil,
            isNormal: true
        )

        let explicitBounds = LabsMarkerCatalog.bounds(for: explicitRangeMarker)
        let catalogBounds = LabsMarkerCatalog.bounds(for: catalogRangeMarker)
        let unknownBounds = LabsMarkerCatalog.bounds(for: unknownMarker)

        XCTAssertEqual(explicitBounds.low ?? 0, 4.5, accuracy: 0.0001)
        XCTAssertEqual(explicitBounds.high ?? 0, 6.5, accuracy: 0.0001)
        XCTAssertEqual(catalogBounds.low ?? 0, 0.0, accuracy: 0.0001)
        XCTAssertEqual(catalogBounds.high ?? 0, 55.0, accuracy: 0.0001)
        XCTAssertNil(unknownBounds.low)
        XCTAssertNil(unknownBounds.high)
        XCTAssertEqual(LabsMarkerCatalog.markerIdentifier(for: "Vitamin D/25 OH"), "vitamin_d_25_oh")
    }

    @MainActor
    func testLabsReviewViewRendersSavingErrorAndMarkerStates() {
        func render<V: View>(_ view: V, file: StaticString = #filePath, line: UInt = #line) {
            let host = UIHostingController(rootView: view)
            _ = host.view
            XCTAssertNotNil(host.viewIfLoaded, file: file, line: line)
        }

        var editableMarkers = [
            ExtractedLabMarker(
                id: UUID(),
                name: "Hemoglobin",
                value: "13.4",
                unit: "g/dL",
                referenceRange: "12-17.5",
                isNormal: true
            ),
            ExtractedLabMarker(
                id: UUID(),
                name: "CRP",
                value: "8.2",
                unit: "mg/L",
                referenceRange: "0-5",
                isNormal: false
            )
        ]
        let editableView = LabsReviewView(
            markers: Binding(get: { editableMarkers }, set: { editableMarkers = $0 }),
            isSaving: false,
            errorMessage: nil,
            onSave: { }
        )

        var savingMarkers = editableMarkers
        let savingView = LabsReviewView(
            markers: Binding(get: { savingMarkers }, set: { savingMarkers = $0 }),
            isSaving: true,
            errorMessage: "save-error",
            onSave: { }
        )

        render(editableView)
        render(savingView)
    }

    @MainActor
    func testLabsOverviewViewRendersHistorySectionsWithMixedItems() throws {
        func render<V: View>(_ view: V, file: StaticString = #filePath, line: UInt = #line) {
            let host = UIHostingController(rootView: view)
            _ = host.view
            XCTAssertNotNil(host.viewIfLoaded, file: file, line: line)
        }

        let dbQueue = try DatabaseQueue(path: ":memory:")
        let reviewId = UUID()
        let pinnedId = UUID()
        let recentId = UUID()

        let historyItems = try dbQueue.write { db -> [LabScanHistoryItem] in
            try db.execute(sql: """
                CREATE TABLE tmp_labs_history (
                    id TEXT,
                    scan_type TEXT,
                    status TEXT,
                    created_at DATETIME,
                    scan_date TEXT,
                    lab_name TEXT,
                    needs_review BOOLEAN,
                    pinned_by_user BOOLEAN,
                    storage_mode TEXT,
                    marker_count INTEGER
                )
                """)
            try db.execute(
                sql: """
                    INSERT INTO tmp_labs_history (
                        id, scan_type, status, created_at, scan_date, lab_name,
                        needs_review, pinned_by_user, storage_mode, marker_count
                    ) VALUES
                    (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                    (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                    (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    reviewId.uuidString, ScanType.bloodTest.rawValue, ScanStatus.pending.rawValue, Date(), "2026-03-01", "CBC",
                    true, false, "cloud", 3,
                    pinnedId.uuidString, ScanType.dexa.rawValue, ScanStatus.completed.rawValue, Date(), nil, "",
                    false, true, "local_only", 1,
                    recentId.uuidString, ScanType.inbody.rawValue, ScanStatus.failed.rawValue, Date(), "2026-02-28", "Body Comp",
                    false, false, "archive", 0
                ]
            )

            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, scan_type, status, created_at, scan_date, lab_name,
                           needs_review, pinned_by_user, storage_mode, marker_count
                    FROM tmp_labs_history
                    ORDER BY created_at DESC
                    """
            )
            return rows.compactMap(LabScanHistoryItem.init(row:))
        }

        XCTAssertEqual(historyItems.map(\.id).count, 3)
        XCTAssertEqual(historyItems.first(where: { $0.id == reviewId })?.title, "CBC")
        XCTAssertTrue(historyItems.first(where: { $0.id == reviewId })?.statusText.isEmpty == false)
        XCTAssertTrue(historyItems.first(where: { $0.id == pinnedId })?.subtitle?.isEmpty == false)
        XCTAssertTrue(historyItems.first(where: { $0.id == recentId })?.accessibilitySummary.contains("Body Comp") == true)

        let store = Store(
            initialState: LabsFeature.State(
                summary: LabsSummary(latestStatus: "completed", markerCount: 4, scanCount: 3),
                metrics: LabsOverviewMetrics(
                    totalScanCount: 3,
                    totalMarkerCount: 4,
                    reviewRequiredCount: 1,
                    pinnedCount: 1
                ),
                scanHistory: historyItems,
                isLoading: false
            )
        ) {
            LabsFeature()
        }

        render(LabsOverviewView(store: store))
    }

    func testLabsScanCapturePersistMarkersCoversCloudStorageAndOutbox() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let scanId = UUID()
        let now = Date(timeIntervalSince1970: 1_742_774_400)

        try await seedLabsUser(
            dbQueue: manager.dbQueue,
            userId: userId,
            authId: authId,
            medicalScanLocalOnly: false,
            cloudBackupEnabled: true
        )

        let markers = [
            ExtractedLabMarker(
                id: UUID(),
                name: "Hemoglobin",
                value: "13.4",
                unit: "g/dL",
                referenceRange: "12-17.5",
                isNormal: true
            ),
            ExtractedLabMarker(
                id: UUID(),
                name: "Ferritin",
                value: "85",
                unit: "ng/mL",
                referenceRange: nil,
                isNormal: true
            ),
            ExtractedLabMarker(
                id: UUID(),
                name: "Broken",
                value: "abc",
                unit: "mg/dL",
                referenceRange: nil,
                isNormal: true
            )
        ]
        let asset = CapturedLabAsset(data: Data("pdf-data".utf8), fileExtension: "pdf")

        try await LabsScanCaptureView._testPersistMarkers(
            scanId: scanId,
            now: now,
            authId: authId.uuidString,
            dbQueue: manager.dbQueue,
            extractedMarkers: markers,
            ocrText: "Ferritin 85 ng/mL",
            sourceFileHash: LabsScanCaptureView._testSha256(Data("source".utf8)),
            capturedAsset: asset,
            captureConfidence: 0.91
        )

        let headers = try JSONSerialization.jsonObject(
            with: LabsScanCaptureView._testOutboxHeadersJson()
        ) as? [String: String]
        XCTAssertEqual(headers?["Content-Type"], "application/json")

        try await manager.dbQueue.read { db in
            let scan = try XCTUnwrap(
                MedicalScan.fetchOne(db, sql: "SELECT * FROM medical_scans WHERE id = ?", arguments: [scanId.uuidString])
            )
            XCTAssertEqual(scan.status, .completed)
            XCTAssertEqual(scan.storageMode, "cloud")
            XCTAssertEqual(scan.markersExtracted, 3)
            XCTAssertFalse(scan.needsReview)
            XCTAssertTrue(scan.userReviewed)
            XCTAssertTrue(scan.manuallyVerified)
            XCTAssertNotNil(scan.originalImageUrl)
            XCTAssertNotNil(scan.scheduledDeletionAt)

            let measurementCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM health_measurements WHERE medical_scan_id = ?",
                arguments: [scanId.uuidString]
            ) ?? 0
            XCTAssertEqual(measurementCount, 2)

            let outboxCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?",
                arguments: ["api-labs"]
            ) ?? 0
            XCTAssertEqual(outboxCount, 1)
        }
    }

    func testLabsScanCapturePersistMarkersCoversLocalOnlyAndMissingUserBranches() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let scanId = UUID()
        let now = Date(timeIntervalSince1970: 1_742_860_800)

        try await seedLabsUser(
            dbQueue: manager.dbQueue,
            userId: userId,
            authId: authId,
            medicalScanLocalOnly: true,
            cloudBackupEnabled: false
        )

        let markers = [
            ExtractedLabMarker(
                id: UUID(),
                name: "CRP",
                value: "8.2",
                unit: "mg/L",
                referenceRange: "0-5",
                isNormal: false
            )
        ]

        try await LabsScanCaptureView._testPersistMarkers(
            scanId: scanId,
            now: now,
            authId: authId.uuidString,
            dbQueue: manager.dbQueue,
            extractedMarkers: markers,
            ocrText: "CRP 8.2 mg/L",
            sourceFileHash: nil,
            capturedAsset: nil,
            captureConfidence: 0.52
        )

        try await manager.dbQueue.read { db in
            let scan = try XCTUnwrap(
                MedicalScan.fetchOne(db, sql: "SELECT * FROM medical_scans WHERE id = ?", arguments: [scanId.uuidString])
            )
            XCTAssertEqual(scan.status, .reviewRequired)
            XCTAssertEqual(scan.storageMode, "local_only")
            XCTAssertTrue(scan.needsReview)
            XCTAssertFalse(scan.userReviewed)
            XCTAssertFalse(scan.manuallyVerified)
            XCTAssertNil(scan.originalImageUrl)
            XCTAssertNil(scan.scheduledDeletionAt)

            let outboxCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?",
                arguments: ["api-labs"]
            ) ?? 0
            XCTAssertEqual(outboxCount, 0)
        }

        await XCTAssertThrowsErrorAsync {
            try await LabsScanCaptureView._testPersistMarkers(
                scanId: UUID(),
                now: now,
                authId: UUID().uuidString,
                dbQueue: manager.dbQueue,
                extractedMarkers: markers,
                ocrText: nil,
                sourceFileHash: nil,
                capturedAsset: nil,
                captureConfidence: 0.9
            )
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
    }
}
