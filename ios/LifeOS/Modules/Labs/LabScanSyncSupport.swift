import Foundation

enum LabScanCloudStorage {
    static let bucketName = "medical-scans"
    static let signedURLLifetimeSeconds = 60 * 60

    static func objectPath(authId: UUID, scanId: UUID, fileExtension: String) -> String {
        let normalizedExtension = sanitizeFileExtension(fileExtension)
        return "\(authId.uuidString.lowercased())/\(scanId.uuidString.lowercased())/original.\(normalizedExtension)"
    }

    static func sanitizeFileExtension(_ rawValue: String?) -> String {
        let trimmed = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ".", with: "") ?? ""
        if trimmed.isEmpty { return "bin" }
        return trimmed
    }

    static func contentType(forFileExtension rawValue: String?) -> String {
        switch sanitizeFileExtension(rawValue) {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "heic", "heif":
            return "image/heic"
        case "pdf":
            return "application/pdf"
        default:
            return "application/octet-stream"
        }
    }

    static func directURL(from rawValue: String?) -> URL? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              let url = URL(string: rawValue) else {
            return nil
        }

        if url.isFileURL {
            return url
        }

        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        return url
    }

    static func storagePath(from rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        if directURL(from: rawValue) != nil {
            return nil
        }

        if rawValue.hasPrefix("\(bucketName)/") {
            return String(rawValue.dropFirst(bucketName.count + 1))
        }

        return rawValue
    }
}

struct LabScanProcessedMarkersEnvelope: Codable, Equatable, Sendable {
    let markers: [LabScanProcessedMarker]
}

struct LabScanProcessedMarker: Codable, Equatable, Sendable {
    let measurementId: String?
    let markerId: String
    let value: Double?
    let unit: String
    let status: String?
    let originalLabel: String?
    let confidence: Double?
    let referenceRangeLow: Double?
    let referenceRangeHigh: Double?

    enum CodingKeys: String, CodingKey {
        case measurementId = "measurement_id"
        case markerId = "marker_id"
        case value
        case unit
        case status
        case originalLabel = "original_label"
        case confidence
        case referenceRangeLow = "reference_range_low"
        case referenceRangeHigh = "reference_range_high"
    }
}

struct LabScanCloudAssetReference: Codable, Equatable, Sendable {
    let localFileURL: String
    let contentType: String
    let fileExtension: String

    enum CodingKeys: String, CodingKey {
        case localFileURL = "local_file_url"
        case contentType = "content_type"
        case fileExtension = "file_extension"
    }
}

enum LabScanSyncPayloadBuilder {
    static func buildBody(scan: MedicalScan, measurements: [HealthMeasurement] = []) throws -> Data {
        var payload: [String: Any] = [
            "scan_id": scan.id.uuidString,
            "user_id": scan.userId.uuidString,
            "scan_type": scan.scanType.rawValue,
            "status": scan.status.rawValue,
            "needs_review": scan.needsReview,
            "user_reviewed": scan.userReviewed,
            "manually_verified": scan.manuallyVerified,
            "pinned_by_user": scan.pinnedByUser,
            "created_at": DateFormatting.iso8601FullString(from: scan.createdAt),
            "updated_at": DateFormatting.iso8601FullString(from: scan.updatedAt),
        ]

        assignIfPresent(scan.aiConfidence, to: "ai_confidence", in: &payload)
        assignIfPresent(scan.ocrConfidence, to: "ocr_confidence", in: &payload)
        assignIfPresent(scan.extractionStatus, to: "extraction_status", in: &payload)
        assignIfPresent(scan.extractionError, to: "extraction_error", in: &payload)
        assignIfPresent(scan.markersExtracted, to: "markers_extracted", in: &payload)
        assignIfPresent(scan.userReviewedAt, to: "user_reviewed_at", in: &payload)
        assignIfPresent(scan.scanDate, to: "scan_date", in: &payload)
        assignIfPresent(scan.labName, to: "lab_name", in: &payload)
        assignIfPresent(scan.documentLanguage, to: "document_language", in: &payload)
        assignIfPresent(scan.sourceFileSha256, to: "source_file_sha256", in: &payload)
        assignIfPresent(scan.storageMode, to: "storage_mode", in: &payload)
        assignIfPresent(scan.storeOriginalInCloud, to: "store_original_in_cloud", in: &payload)
        assignIfPresent(scan.scheduledDeletionAt, to: "scheduled_deletion_at", in: &payload)
        assignIfPresent(scan.notes, to: "notes", in: &payload)
        assignIfPresent(scan.deletedAt, to: "deleted_at", in: &payload)
        assignIfPresent(scan.imageUploadedAt, to: "image_uploaded_at", in: &payload)

        if let storedAssetPath = LabScanCloudStorage.storagePath(from: scan.originalImageUrl)
            ?? LabScanCloudStorage.storagePath(from: scan.imageUrl) {
            payload["stored_asset_path"] = storedAssetPath
        }

        if let processedData = normalizedProcessedDataJSONObject(from: scan.processedData, measurements: measurements) {
            payload["processed_data"] = processedData
        }

        if let originalAsset = cloudAssetReference(for: scan) {
            payload["original_asset"] = [
                "local_file_url": originalAsset.localFileURL,
                "content_type": originalAsset.contentType,
                "file_extension": originalAsset.fileExtension,
            ]
        }

        return try JSONSerialization.data(withJSONObject: payload)
    }

    static func processedData(from markers: [LabScanProcessedMarker]) throws -> Data {
        try JSONEncoder().encode(LabScanProcessedMarkersEnvelope(markers: markers))
    }

    static func processedData(from measurements: [HealthMeasurement]) throws -> Data {
        try processedData(from: makeProcessedMarkers(from: measurements))
    }

    static func makeProcessedMarkers(from extractedMarkers: [ExtractedLabMarker], confidence: Double?) -> [LabScanProcessedMarker] {
        extractedMarkers.map { marker in
            let normalizedValue = Self.numericValue(from: marker.value)
            let referenceBounds = LabsMarkerCatalog.bounds(for: marker)
            let catalogMarkerId = LabsMarkerCatalog.markerIdentifier(for: marker.name)
            let canonicalMarkerId = HealthMeasurement.canonicalMarkerId(
                markerId: catalogMarkerId,
                biomarkerName: marker.name,
                originalLabel: marker.name
            ) ?? catalogMarkerId
            let status = HealthMeasurementStatus.canonicalRawValue(
                for: marker.isNormal ? HealthMeasurementStatus.optimal.rawValue : nil,
                value: normalizedValue,
                referenceRangeLow: referenceBounds.low,
                referenceRangeHigh: referenceBounds.high
            ) ?? (marker.isNormal ? HealthMeasurementStatus.optimal.rawValue : nil)

            return LabScanProcessedMarker(
                measurementId: nil,
                markerId: canonicalMarkerId,
                value: normalizedValue,
                unit: marker.unit,
                status: status,
                originalLabel: marker.name,
                confidence: confidence,
                referenceRangeLow: referenceBounds.low,
                referenceRangeHigh: referenceBounds.high
            )
        }
    }

    static func makeProcessedMarkers(from measurements: [HealthMeasurement]) -> [LabScanProcessedMarker] {
        measurements.map { measurement in
            let markerId = HealthMeasurement.canonicalMarkerId(
                markerId: measurement.markerId,
                biomarkerName: measurement.biomarkerName,
                originalLabel: measurement.originalLabel
            ) ?? measurement.markerId
                ?? LabsMarkerCatalog.markerIdentifier(for: measurement.biomarkerName)
            return LabScanProcessedMarker(
                measurementId: measurement.id.uuidString,
                markerId: markerId,
                value: measurement.originalValue ?? measurement.value,
                unit: measurement.originalUnit ?? measurement.unit,
                status: HealthMeasurementStatus.canonicalRawValue(
                    for: measurement.status,
                    value: measurement.value,
                    referenceRangeLow: measurement.referenceRangeLow,
                    referenceRangeHigh: measurement.referenceRangeHigh
                ),
                originalLabel: measurement.originalLabel ?? measurement.biomarkerName,
                confidence: measurement.confidence,
                referenceRangeLow: measurement.referenceRangeLow,
                referenceRangeHigh: measurement.referenceRangeHigh
            )
        }
    }

    static func normalizedProcessedDataEnvelope(
        from data: Data?,
        measurements: [HealthMeasurement] = []
    ) -> LabScanProcessedMarkersEnvelope? {
        if !measurements.isEmpty {
            return LabScanProcessedMarkersEnvelope(markers: makeProcessedMarkers(from: measurements))
        }

        guard let data else { return nil }

        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(LabScanProcessedMarkersEnvelope.self, from: data) {
            return envelope
        }

        if let extractedMarkers = try? decoder.decode([ExtractedLabMarker].self, from: data) {
            return LabScanProcessedMarkersEnvelope(
                markers: makeProcessedMarkers(from: extractedMarkers, confidence: nil)
            )
        }

        return nil
    }

    static func normalizedProcessedDataJSONObject(
        from data: Data?,
        measurements: [HealthMeasurement] = []
    ) -> Any? {
        guard let envelope = normalizedProcessedDataEnvelope(from: data, measurements: measurements),
              let encoded = try? JSONEncoder().encode(envelope) else {
            return nil
        }

        return try? JSONSerialization.jsonObject(with: encoded)
    }

    private static func cloudAssetReference(for scan: MedicalScan) -> LabScanCloudAssetReference? {
        guard scan.storageMode?.lowercased() == "cloud",
              scan.storeOriginalInCloud == true else {
            return nil
        }

        for rawValue in [scan.originalImageUrl, scan.imageUrl] {
            guard let rawValue,
                  let url = URL(string: rawValue),
                  url.isFileURL else {
                continue
            }

            let fileExtension = LabScanCloudStorage.sanitizeFileExtension(url.pathExtension)
            return LabScanCloudAssetReference(
                localFileURL: rawValue,
                contentType: LabScanCloudStorage.contentType(forFileExtension: fileExtension),
                fileExtension: fileExtension
            )
        }

        return nil
    }

    private static func numericValue(from rawValue: String) -> Double? {
        Double(
            rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: ".")
        )
    }

    private static func assignIfPresent(_ value: String?, to key: String, in payload: inout [String: Any]) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return
        }
        payload[key] = value
    }

    private static func assignIfPresent(_ value: Int?, to key: String, in payload: inout [String: Any]) {
        guard let value else { return }
        payload[key] = value
    }

    private static func assignIfPresent(_ value: Double?, to key: String, in payload: inout [String: Any]) {
        guard let value else { return }
        payload[key] = value
    }

    private static func assignIfPresent(_ value: Bool?, to key: String, in payload: inout [String: Any]) {
        guard let value else { return }
        payload[key] = value
    }

    private static func assignIfPresent(_ value: Date?, to key: String, in payload: inout [String: Any]) {
        guard let value else { return }
        payload[key] = DateFormatting.iso8601FullString(from: value)
    }
}
