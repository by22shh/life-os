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

    func testLabsMarkerCatalogParsesAliasesWithoutInventingUnitsOrReferenceIntervals() {
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
        XCTAssertEqual(markers.first(where: { $0.name == "Ferritin" })?.unit, "")
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
        XCTAssertNil(catalogBounds.low)
        XCTAssertNil(catalogBounds.high)
        XCTAssertNil(unknownBounds.low)
        XCTAssertNil(unknownBounds.high)
        XCTAssertEqual(LabsMarkerCatalog.markerIdentifier(for: "Vitamin D/25 OH"), "vitamin_d_25_oh")
    }

    func testAuditDecimalCommaCyrillicAndUnitExamplesNeverInventReferenceRanges() throws {
        for (input, name, value, unit) in [
            ("Glucose 5,6 mmol/L", "Glucose", "5.6", "mmol/L"),
            ("Glucose 5.6 mmol/L", "Glucose", "5.6", "mmol/L"),
            ("Глюкоза 5,6 ммоль/л", "Glucose", "5.6", "mmol/L"),
            ("Ferritin 85,5 ng/mL", "Ferritin", "85.5", "ng/mL"),
            ("Ферритин 85,5 нг/мл", "Ferritin", "85.5", "ng/mL"),
            ("Креатинин 78 мкмоль/л", "Creatinine", "78", "µmol/L"),
            ("Гемоглобин 134 г/л", "Hemoglobin", "134", "g/L")
        ] {
            let markers = LabsMarkerCatalog.extractMarkers(from: input)
            XCTAssertEqual(markers.count, 1, input)
            let marker = try XCTUnwrap(markers.first)
            XCTAssertEqual(marker.name, name, input)
            XCTAssertEqual(marker.value, value, input)
            XCTAssertEqual(marker.unit, unit, input)
            XCTAssertNil(marker.referenceRange, input)
            XCTAssertNil(LabsMarkerCatalog.bounds(for: marker).low, input)
            XCTAssertNil(LabsMarkerCatalog.normality(for: marker), input)
        }
    }

    func testDocumentReferenceIntervalsAndEditedValuesDriveNormality() throws {
        var marker = try XCTUnwrap(LabsMarkerCatalog.extractMarkers(from: "Глюкоза 5,6 ммоль/л (4,0–6,0)").first)
        XCTAssertEqual(LabsMarkerCatalog.normality(for: marker), true)
        marker.value = "9,1"
        // Deliberately stale UI flag must never control interpreted status.
        marker.isNormal = true
        XCTAssertEqual(LabsMarkerCatalog.normality(for: marker), false)
        marker.referenceRange = "6-4"
        XCTAssertNil(LabsMarkerCatalog.normality(for: marker))
        XCTAssertFalse(LabsMarkerCatalog.isValidForSave(marker))
        marker.referenceRange = nil
        XCTAssertNil(LabsMarkerCatalog.normality(for: marker))
    }

    func testMissingUnitsQualifiersAndNonfiniteValuesRequireCorrection() throws {
        let missingUnit = try XCTUnwrap(LabsMarkerCatalog.extractMarkers(from: "Ferritin 85").first)
        XCTAssertEqual(missingUnit.unit, "")
        XCTAssertFalse(LabsMarkerCatalog.isValidForSave(missingUnit))
        let censored = try XCTUnwrap(LabsMarkerCatalog.extractMarkers(from: "CRP <5 mg/L").first)
        XCTAssertEqual(censored.value, "<5", "Never turn a censored result into an exact number")
        XCTAssertFalse(LabsMarkerCatalog.isValidForSave(censored))
        for value in ["nan", "inf", "1e999", "5,6,7", "<5", ""] {
            XCTAssertNil(LabsMarkerCatalog.numericValue(value), value)
        }
        XCTAssertEqual(LabsMarkerCatalog.markerIdentifier(for: "Глюкоза"), "glucose")
        XCTAssertEqual(LabsMarkerCatalog.canonicalName(for: "Гликированный гемоглобин"), "HbA1c")
        XCTAssertEqual(LabsMarkerCatalog.canonicalName(for: "Glucose tolerance"), "Glucose tolerance")
    }

    func testDocumentDateRejectsBirthDatesInvalidDatesAndPreservesHistoricalDate() throws {
        let expected = try XCTUnwrap(LabsMarkerCatalog.documentDate(from: "Дата забора крови: 21.02.2024"))
        XCTAssertEqual(DiaryDateFormatter.formatDate(expected), "2024-02-21")
        XCTAssertEqual(LabsMarkerCatalog.documentDate(from: "Collection date: 2024-02-21"), expected)
        XCTAssertEqual(LabsMarkerCatalog.documentDate(from: "Дата анализа: 21/02/2024"), expected)
        XCTAssertNil(LabsMarkerCatalog.documentDate(from: "Дата рождения: 21.02.1980"))
        XCTAssertNil(LabsMarkerCatalog.documentDate(from: "Дата анализа: 31.02.2024"))
    }

    func testMarkerOverlapIncludesSixtyPercentBoundary() {
        let original: Set<String> = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(LabsMarkerCatalog.markerOverlap(incoming: original, existing: ["a", "b", "c", "x", "y"]), 0.6)
        XCTAssertEqual(LabsMarkerCatalog.markerOverlap(incoming: original, existing: ["a", "b", "x", "y", "z"]), 0.4)
        XCTAssertEqual(LabsMarkerCatalog.markerOverlap(incoming: [], existing: original), 0)
    }

    func testOfflineImportPersistsChosenDateRequiresExplicitReviewAndRejectsDuplicate() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID(), authId = UUID(), scanId = UUID()
        try await seedLabsUser(dbQueue: manager.dbQueue, userId: userId, authId: authId,
                               medicalScanLocalOnly: true, cloudBackupEnabled: false)
        let importedAt = Date()
        let selectedDate = try XCTUnwrap(LabsMarkerCatalog.documentDate(from: "Дата анализа: 21.02.2024"))
        let markers = LabsMarkerCatalog.extractMarkers(from: "Глюкоза 5,6 ммоль/л (4,0–6,0)")
        try await LabsScanCaptureView._testPersistMarkers(
            scanId: scanId, now: importedAt, authId: authId.uuidString, dbQueue: manager.dbQueue,
            extractedMarkers: markers, ocrText: nil, sourceFileHash: "same-document", capturedAsset: nil,
            captureConfidence: 0.99, measuredDate: selectedDate)
        try await manager.dbQueue.read { db in
            let scan = try XCTUnwrap(MedicalScan.fetchOne(db, key: scanId))
            XCTAssertEqual(scan.scanDate, "2024-02-21")
            XCTAssertTrue(scan.needsReview)
            XCTAssertFalse(scan.manuallyVerified, "High supplied confidence is not manual review")
            XCTAssertNil(scan.aiConfidence)
            XCTAssertNil(scan.ocrConfidence)
            let measurement = try XCTUnwrap(HealthMeasurement.fetchOne(db))
            XCTAssertEqual(measurement.measuredDate, "2024-02-21")
            XCTAssertEqual(measurement.measuredAt?.timeIntervalSince1970 ?? 0, selectedDate.timeIntervalSince1970, accuracy: 1)
            XCTAssertEqual(measurement.value, 5.6, accuracy: 0.0001)
            XCTAssertEqual(measurement.unit, "mmol/L")
            XCTAssertEqual(measurement.referenceRangeLow, 4)
            XCTAssertEqual(measurement.status, "optimal")
            XCTAssertNil(measurement.confidence)
            XCTAssertEqual(try OutboxEvent.fetchCount(db), 0)
        }
        // No hash supplied on repeat: same-day overlap alone must catch it offline.
        do {
            try await LabsScanCaptureView._testPersistMarkers(
                scanId: UUID(), now: importedAt, authId: authId.uuidString, dbQueue: manager.dbQueue,
                extractedMarkers: markers, ocrText: nil, sourceFileHash: nil, capturedAsset: nil,
                captureConfidence: 0, measuredDate: selectedDate, reviewConfirmed: true)
            XCTFail("Duplicate should require an explicit choice")
        } catch LabsScanCaptureView.LabsSaveError.duplicates(let ids) {
            XCTAssertEqual(ids, [scanId])
        }
        let separateScanId = UUID()
        try await LabsScanCaptureView._testPersistMarkers(
            scanId: separateScanId, now: importedAt, authId: authId.uuidString, dbQueue: manager.dbQueue,
            extractedMarkers: markers, ocrText: nil, sourceFileHash: nil, capturedAsset: nil,
            captureConfidence: 0, measuredDate: selectedDate, reviewConfirmed: true, allowDuplicate: true)
        try await manager.dbQueue.read { db in
            XCTAssertEqual(try MedicalScan.fetchCount(db), 2)
            let scan = try XCTUnwrap(MedicalScan.fetchOne(db, key: separateScanId))
            XCTAssertTrue(scan.userReviewed)
            XCTAssertFalse(scan.needsReview)
            XCTAssertEqual(scan.status, .completed)
            XCTAssertEqual(try OutboxEvent.fetchCount(db), 0)
        }
        // An identical file is still a duplicate if a user changes its date.
        await XCTAssertThrowsErrorAsync {
            try await LabsScanCaptureView._testPersistMarkers(
                scanId: UUID(), now: importedAt, authId: authId.uuidString, dbQueue: manager.dbQueue,
                extractedMarkers: markers, ocrText: nil, sourceFileHash: "same-document", capturedAsset: nil,
                captureConfidence: 0, measuredDate: importedAt, reviewConfirmed: true)
        }
    }

    func testInvalidImportIsAtomicAndUnknownRangeDoesNotBecomeNormal() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID(), authId = UUID()
        try await seedLabsUser(dbQueue: manager.dbQueue, userId: userId, authId: authId,
                               medicalScanLocalOnly: true, cloudBackupEnabled: false)
        let valid = LabsMarkerCatalog.extractMarkers(from: "Glucose 5.6 mmol/L")
        var invalid = try XCTUnwrap(valid.first)
        invalid.value = "abc"
        await XCTAssertThrowsErrorAsync {
            try await LabsScanCaptureView._testPersistMarkers(
                scanId: UUID(), now: Date(), authId: authId.uuidString, dbQueue: manager.dbQueue,
                extractedMarkers: valid + [invalid], ocrText: nil, sourceFileHash: nil, capturedAsset: nil,
                captureConfidence: 0.99, reviewConfirmed: true)
        }
        try await manager.dbQueue.read { db in
            XCTAssertEqual(try MedicalScan.fetchCount(db), 0)
            XCTAssertEqual(try HealthMeasurement.fetchCount(db), 0)
        }
        try await LabsScanCaptureView._testPersistMarkers(
            scanId: UUID(), now: Date(), authId: authId.uuidString, dbQueue: manager.dbQueue,
            extractedMarkers: valid, ocrText: nil, sourceFileHash: nil, capturedAsset: nil,
            captureConfidence: 0.99, reviewConfirmed: true)
        try await manager.dbQueue.read { db in
            let measurement = try XCTUnwrap(HealthMeasurement.fetchOne(db))
            XCTAssertNil(measurement.status)
            XCTAssertNil(measurement.referenceRangeLow)
            XCTAssertNil(measurement.referenceRangeHigh)
        }
    }

    func testMedicalAssetsExcludedFromBackupAndFileProtected() throws {
        let url = try LabScanAssetStore.persistAsset(scanId: UUID(), asset: CapturedLabAsset(data: Data("test".utf8), fileExtension: "pdf"))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
#if targetEnvironment(simulator)
        // Simulator's host filesystem may not expose iOS data-protection metadata.
        if let protection = attributes[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(protection, .complete)
        }
#else
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete)
#endif
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
            captureConfidence: 0.91,
            reviewConfirmed: true
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
            XCTAssertEqual(scan.markersExtracted, 2)
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
