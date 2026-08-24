import Foundation
import ComposableArchitecture
import GRDB

enum LabsLocalizedText {
    static func identifier(_ rawValue: String) -> String {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case ScanType.bloodTest.rawValue:
            return String(localized: "labs_identifier_blood_test")
        case ScanType.inbody.rawValue:
            return String(localized: "labs_identifier_inbody")
        case ScanType.dexa.rawValue:
            return String(localized: "labs_identifier_dexa")
        case ScanStatus.pending.rawValue:
            return String(localized: "labs_identifier_pending")
        case ScanStatus.processing.rawValue:
            return String(localized: "labs_identifier_processing")
        case ScanStatus.completed.rawValue:
            return String(localized: "labs_identifier_completed")
        case ScanStatus.failed.rawValue:
            return String(localized: "labs_identifier_failed")
        case ScanStatus.reviewRequired.rawValue:
            return String(localized: "labs_identifier_review_required")
        case HealthMeasurementStatus.criticalLow.rawValue:
            return String(localized: "labs_identifier_critical_low")
        case HealthMeasurementStatus.low.rawValue:
            return String(localized: "labs_identifier_low")
        case HealthMeasurementStatus.optimal.rawValue:
            return String(localized: "labs_identifier_optimal")
        case HealthMeasurementStatus.high.rawValue:
            return String(localized: "labs_identifier_high")
        case HealthMeasurementStatus.criticalHigh.rawValue:
            return String(localized: "labs_identifier_critical_high")
        default:
            let fallback = rawValue
                .replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = fallback.first else { return rawValue }
            return first.uppercased() + fallback.dropFirst()
        }
    }

    static func scansCountSummary(_ count: Int) -> String {
        String.localizedStringWithFormat(String(localized: "labs_count_scans_format"), count)
    }

    static func markersCountSummary(_ count: Int) -> String {
        String.localizedStringWithFormat(String(localized: "labs_count_markers_format"), count)
    }
}

struct LabsSummary: Equatable {
    let primaryText: String
    let secondaryText: String?
    let accessibilitySummary: String

    init(latestStatus: String?, markerCount: Int, scanCount: Int) {
        if let latestStatus, !latestStatus.isEmpty {
            primaryText = LabsLocalizedText.identifier(latestStatus)
        } else {
            primaryText = String(localized: "labs")
        }
        let metricParts = [
            scanCount > 0 ? LabsLocalizedText.scansCountSummary(scanCount) : nil,
            markerCount > 0 ? LabsLocalizedText.markersCountSummary(markerCount) : nil
        ]
        .compactMap { $0 }
        secondaryText = metricParts.isEmpty ? nil : metricParts.joined(separator: " • ")
        accessibilitySummary = [primaryText, secondaryText].compactMap { $0 }.joined(separator: ", ")
    }
}

struct LabsOverviewMetrics: Equatable {
    let totalScanCount: Int
    let totalMarkerCount: Int
    let reviewRequiredCount: Int
    let pinnedCount: Int
}

struct LabScanHistoryItem: Equatable, Identifiable {
    let id: UUID
    let title: String
    let subtitle: String?
    let statusText: String
    let statusRawValue: String
    let markerCount: Int
    let needsReview: Bool
    let isPinned: Bool
    let scanTypeRawValue: String
    let accessibilitySummary: String

    init?(row: Row) {
        guard let id = MixedUUIDStorage.decode(from: row, column: "id"),
              let rawScanType: String = row["scan_type"],
              let rawStatus: String = row["status"] else {
            return nil
        }

        let rawLabName: String? = row["lab_name"]
        let labName = rawLabName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = labName.flatMap { $0.isEmpty ? nil : $0 } ?? Self.humanized(rawScanType)
        let createdAt: Date = row["created_at"] ?? Date()
        let scanDate: String? = row["scan_date"]
        let storageMode: String? = row["storage_mode"]
        let markerCount: Int = row["marker_count"] ?? 0
        let needsReview: Bool = row["needs_review"] ?? false
        let isPinned: Bool = row["pinned_by_user"] ?? false
        let statusText = needsReview ? String(localized: "labs_review_section_header") : LabsLocalizedText.identifier(rawStatus)
        let subtitleParts = [
            Self.formattedScanDate(scanDate, createdAt: createdAt),
            Self.storageModeText(storageMode)
        ]
        .compactMap { $0 }
        let subtitle = subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " • ")
        let markerSummary = LabsLocalizedText.markersCountSummary(markerCount)

        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.statusText = statusText
        self.statusRawValue = rawStatus
        self.markerCount = markerCount
        self.needsReview = needsReview
        self.isPinned = isPinned
        self.scanTypeRawValue = rawScanType
        self.accessibilitySummary = [title, subtitle, statusText, markerSummary]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private static func formattedScanDate(_ scanDate: String?, createdAt: Date) -> String? {
        if let scanDate,
           let parsedDate = DiaryDateFormatter.parseDate(scanDate) {
            return DateFormatter.localizedString(from: parsedDate, dateStyle: .medium, timeStyle: .none)
        }
        return DateFormatter.localizedString(from: createdAt, dateStyle: .medium, timeStyle: .short)
    }

    private static func storageModeText(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !rawValue.isEmpty else {
            return nil
        }

        switch rawValue {
        case "local_only":
            return String(localized: "labs_detail_storage_local_only")
        case "cloud":
            return String(localized: "labs_detail_storage_cloud")
        default:
            return LabsLocalizedText.identifier(rawValue)
        }
    }

    private static func humanized(_ rawValue: String) -> String {
        LabsLocalizedText.identifier(rawValue)
    }
}

struct LabsOverviewSnapshot: Equatable {
    let summary: LabsSummary?
    let metrics: LabsOverviewMetrics?
    let scanHistory: [LabScanHistoryItem]
}

@Reducer
struct LabsFeature {
    @ObservableState
    struct State: Equatable {
        var summary: LabsSummary?
        var metrics: LabsOverviewMetrics?
        var scanHistory: [LabScanHistoryItem] = []
        var isLoading = false
    }

    enum Action: Equatable {
        case task
        case loadResponse(Result<LabsOverviewSnapshot, ErrorData>)
    }

    // Since Error does not conform to Equatable easily, we wrap it
    struct ErrorData: Error, Equatable, Sendable {
        let message: String
        init(_ error: Error) {
            self.message = error.localizedDescription
        }
    }

    @Dependency(\.databaseQueue) var dbQueue

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                state.isLoading = true
                return .run { send in
                    do {
                        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
                        let snapshot: LabsOverviewSnapshot = try await dbQueue.read { db in
                            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                                return LabsOverviewSnapshot(summary: nil, metrics: nil, scanHistory: [])
                            }

                            let latestStatus = try String.fetchOne(
                                db,
                                sql: """
                                    SELECT status
                                    FROM medical_scans
                                    WHERE (user_id = ? OR user_id = ?)
                                      AND deleted_at IS NULL
                                    ORDER BY created_at DESC
                                    LIMIT 1
                                    """,
                                arguments: [userId, userId.uuidString]
                            )
                            let scanCount = try Int.fetchOne(
                                db,
                                sql: """
                                    SELECT COUNT(*)
                                    FROM medical_scans
                                    WHERE (user_id = ? OR user_id = ?)
                                      AND deleted_at IS NULL
                                    """,
                                arguments: [userId, userId.uuidString]
                            ) ?? 0
                            let markerCount = try Int.fetchOne(
                                db,
                                sql: """
                                    SELECT COUNT(*)
                                    FROM health_measurements
                                    WHERE (user_id = ? OR user_id = ?)
                                    """,
                                arguments: [userId, userId.uuidString]
                            ) ?? 0
                            let reviewRequiredCount = try Int.fetchOne(
                                db,
                                sql: """
                                    SELECT COUNT(*)
                                    FROM medical_scans
                                    WHERE (user_id = ? OR user_id = ?)
                                      AND deleted_at IS NULL
                                      AND needs_review = 1
                                    """,
                                arguments: [userId, userId.uuidString]
                            ) ?? 0
                            let pinnedCount = try Int.fetchOne(
                                db,
                                sql: """
                                    SELECT COUNT(*)
                                    FROM medical_scans
                                    WHERE (user_id = ? OR user_id = ?)
                                      AND deleted_at IS NULL
                                      AND pinned_by_user = 1
                                    """,
                                arguments: [userId, userId.uuidString]
                            ) ?? 0
                            let historyRows = try Row.fetchAll(
                                db,
                                sql: """
                                    SELECT
                                        ms.id,
                                        ms.scan_type,
                                        ms.status,
                                        ms.created_at,
                                        ms.scan_date,
                                        ms.lab_name,
                                        ms.needs_review,
                                        ms.pinned_by_user,
                                        ms.storage_mode,
                                        COUNT(DISTINCT hm.id) AS marker_count
                                    FROM medical_scans ms
                                    LEFT JOIN health_measurements hm
                                      ON hm.medical_scan_id = ms.id
                                      OR hm.source_scan_id = ms.id
                                    WHERE (ms.user_id = ? OR ms.user_id = ?)
                                      AND ms.deleted_at IS NULL
                                    GROUP BY
                                        ms.id,
                                        ms.scan_type,
                                        ms.status,
                                        ms.created_at,
                                        ms.scan_date,
                                        ms.lab_name,
                                        ms.needs_review,
                                        ms.pinned_by_user,
                                        ms.storage_mode
                                    ORDER BY
                                        CASE WHEN ms.needs_review = 1 THEN 0 ELSE 1 END,
                                        CASE WHEN ms.pinned_by_user = 1 THEN 0 ELSE 1 END,
                                        COALESCE(ms.scan_date, strftime('%Y-%m-%d', ms.created_at)) DESC,
                                        ms.created_at DESC
                                    """,
                                arguments: [userId, userId.uuidString]
                            )
                            let scanHistory = historyRows.compactMap(LabScanHistoryItem.init(row:))

                            let summary: LabsSummary?
                            let metrics: LabsOverviewMetrics?
                            if latestStatus != nil || scanCount > 0 || markerCount > 0 {
                                summary = LabsSummary(
                                    latestStatus: latestStatus,
                                    markerCount: markerCount,
                                    scanCount: scanCount
                                )
                                metrics = LabsOverviewMetrics(
                                    totalScanCount: scanCount,
                                    totalMarkerCount: markerCount,
                                    reviewRequiredCount: reviewRequiredCount,
                                    pinnedCount: pinnedCount
                                )
                            } else {
                                summary = nil
                                metrics = nil
                            }

                            return LabsOverviewSnapshot(
                                summary: summary,
                                metrics: metrics,
                                scanHistory: scanHistory
                            )
                        }
                        await send(.loadResponse(.success(snapshot)))
                    } catch {
                        await send(.loadResponse(.failure(ErrorData(error))))
                    }
                }

            case let .loadResponse(.success(snapshot)):
                state.summary = snapshot.summary
                state.metrics = snapshot.metrics
                state.scanHistory = snapshot.scanHistory
                state.isLoading = false
                return .none

            case .loadResponse(.failure):
                state.summary = nil
                state.metrics = nil
                state.scanHistory = []
                state.isLoading = false
                return .none
            }
        }
    }
}
