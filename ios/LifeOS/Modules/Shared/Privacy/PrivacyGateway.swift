import Foundation
import GRDB

struct PrivacyDownloadedExportArchive: Sendable, Equatable {
    let data: Data
    let suggestedFilename: String
    let contentType: String?
}

protocol PrivacyStatusAPIClient: Sendable {
    func callPrivacyStatusEdgeFunction<T: Decodable & Sendable>(
        _ name: String,
        body: Data
    ) async throws -> T

    func downloadPrivacyExport(from url: URL) async throws -> PrivacyDownloadedExportArchive
}

actor PrivacyGateway {
    private let apiClient: any PrivacyStatusAPIClient
    private let dbQueue: DatabaseQueue
    private let isRuntimeConfiguredProvider: @Sendable () -> Bool

    init(
        apiClient: any PrivacyStatusAPIClient = APIClient(),
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue,
        isRuntimeConfiguredProvider: @escaping @Sendable () -> Bool = { SupabaseConfig.isRuntimeConfigured }
    ) {
        self.apiClient = apiClient
        self.dbQueue = dbQueue
        self.isRuntimeConfiguredProvider = isRuntimeConfiguredProvider
    }

    func requestExport() async throws -> ExportRequestResponse {
        let exportId = UUID().uuidString
        let requestedAt = Date()
        guard let user = try await latestUserContext() else {
            throw SettingsError.exportFailed
        }

        if !isRuntimeConfiguredProvider() {
            do {
                let fileURL = try await LocalPrivacyExportWriter.createExport(
                    exportId: exportId,
                    user: user,
                    dbQueue: dbQueue
                )
                try await upsertLocalExportJob(
                    exportId: exportId,
                    userId: user.userId,
                    status: "ready",
                    downloadUrl: fileURL.absoluteString,
                    requestedAt: requestedAt,
                    completedAt: Date(),
                    failureReason: nil
                )
                return ExportRequestResponse(exportId: exportId, status: "ready")
            } catch {
                try await upsertLocalExportJob(
                    exportId: exportId,
                    userId: user.userId,
                    status: "failed",
                    downloadUrl: nil,
                    requestedAt: requestedAt,
                    completedAt: Date(),
                    failureReason: Self.friendlyPrivacyMessage(error)
                )
                throw error
            }
        }

        try await ensureActiveCloudSession()
        try await enqueueWriteIntent(
            path: "api-user-export",
            method: .POST,
            body: ["export_id": exportId],
            priority: 60
        )
        try await upsertLocalExportJob(
            exportId: exportId,
            userId: user.userId,
            status: "queued",
            downloadUrl: nil,
            requestedAt: requestedAt,
            completedAt: nil,
            failureReason: nil
        )
        return ExportRequestResponse(exportId: exportId, status: "queued")
    }

    func exportStatus(exportId: String) async throws -> ExportStatusResponse {
        if !isRuntimeConfiguredProvider() {
            return try await localExportStatus(exportId: exportId)
        }

        guard await hasActiveCloudSession() else {
            return try await localExportStatus(exportId: exportId)
        }

        let body = try JSONSerialization.data(withJSONObject: ["export_id": exportId])
        let response: ExportStatusResponse = try await apiClient.callPrivacyStatusEdgeFunction(
            "api-user-export-status",
            body: body
        )
        if let userId = try await latestUserId() {
            let completedAt: Date? = (response.status == "ready" || response.downloadUrl != nil) ? Date() : nil
            try await upsertLocalExportJob(
                exportId: response.exportId,
                userId: userId,
                status: response.status,
                downloadUrl: response.downloadUrl,
                requestedAt: nil,
                completedAt: completedAt,
                failureReason: nil
            )
        }
        return response
    }

    func downloadExportArchive(exportId: String) async throws -> URL {
        let status: ExportStatusResponse
        if isRuntimeConfiguredProvider(), !(await hasActiveCloudSession()) {
            status = try await localExportStatus(exportId: exportId)
        } else {
            status = try await exportStatus(exportId: exportId)
        }
        guard let downloadUrl = status.downloadUrl,
              let url = URL(string: downloadUrl) else {
            throw PrivacyError.exportNotReady
        }

        if url.isFileURL {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PrivacyError.exportNotReady
            }
            return url
        }

        try Self.validateTrustedRemoteExportDownloadURL(url)

        do {
            let archive = try await apiClient.downloadPrivacyExport(from: url)
            return try DownloadedPrivacyExportStore.persist(archive: archive)
        } catch {
            if Self.httpStatusCode(error) == 404 {
                let refreshedStatus = try await exportStatus(exportId: exportId)
                if refreshedStatus.downloadUrl == nil {
                    throw PrivacyError.exportNotReady
                }
            }
            throw error
        }
    }

    func requestErasure(reason: String = "user_requested") async throws {
        guard let user = try await latestUserContext() else {
            throw SettingsError.deletionFailed
        }

        if !isRuntimeConfiguredProvider() {
            _ = try await LocalPrivacyErasureExecutor.execute(
                reason: reason,
                user: user,
                dbQueue: dbQueue
            )
            return
        }

        try await ensureActiveCloudSession()
        try await enqueueWriteIntent(
            path: "api-account-delete",
            method: .POST,
            body: [
                "reason": reason,
                "immediate": false
            ],
            priority: 55
        )
    }

    func erasureStatus() async throws -> ErasureStatusResponse {
        if !isRuntimeConfiguredProvider() {
            guard let user = try await latestUserContext(),
                  let response = try await LocalPrivacyErasureExecutor.latestStatus(
                      userId: user.userId,
                      dbQueue: dbQueue
                  ) else {
                return ErasureStatusResponse(
                    scheduled: false,
                    deletionDate: nil,
                    deletionInProgress: false,
                    reason: nil,
                    deletionState: nil,
                    deletionMode: nil,
                    deletionAttemptCount: nil,
                    retryAfterSeconds: nil,
                    idempotencyKey: nil
                )
            }
            return response
        }

        try await ensureActiveCloudSession()
        let body = try JSONSerialization.data(withJSONObject: [:])
        return try await apiClient.callPrivacyStatusEdgeFunction(
            "api-account-delete-status",
            body: body
        )
    }

    func cancelScheduledErasure() async throws -> ErasureCancelResponse {
        if !isRuntimeConfiguredProvider() {
            return ErasureCancelResponse(cancelled: false, status: "not_applicable", deletionState: "completed")
        }

        try await ensureActiveCloudSession()
        try await enqueueWriteIntent(
            path: "api-account-delete-cancel",
            method: .POST,
            body: [:],
            priority: 65
        )
        return ErasureCancelResponse(cancelled: false, status: "queued", deletionState: nil)
    }

    func recordConsent(
        userId: UUID,
        consentType: ConsentType,
        granted: Bool,
        version: String,
        ipAddress: String? = nil
    ) async throws {
        let record = ConsentRecord(
            userId: userId,
            consentType: consentType,
            granted: granted,
            version: version,
            ipAddress: ipAddress
        )

        try await dbQueue.write { db in
            try record.insert(db)
        }

        if let syncEngine = AppContainer.shared?.syncEngine {
            let body = try JSONSerialization.data(withJSONObject: [
                "id": record.id.uuidString,
                "user_id": userId.uuidString,
                "consent_type": consentType.rawValue,
                "granted": granted,
                "version": version,
                "ip_address": ipAddress as Any,
                "timestamp": ISO8601DateFormatter.supabaseString(from: record.timestamp)
            ])

            let event = OutboxEvent(
                httpMethod: .POST,
                path: "api-settings-consent",
                bodyJson: body,
                priority: 70
            )
            try await syncEngine.enqueueMutation(event)
        }
    }

    func latestConsent(userId: UUID, type: ConsentType) async throws -> ConsentRecord? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, user_id, consent_type, granted, timestamp, version, ip_address, created_at
                    FROM consent_records
                    WHERE consent_type = ?
                      AND (user_id = ? OR lower(CAST(user_id AS TEXT)) = lower(?))
                    ORDER BY timestamp DESC
                    LIMIT 1
                    """,
                arguments: [type.rawValue, userId, userId.uuidString]
            ) else {
                return nil
            }

            guard
                let id = Self.decodeUUID(from: row, column: "id"),
                let resolvedUserId = Self.decodeUUID(from: row, column: "user_id"),
                let consentTypeRaw: String = row["consent_type"],
                let consentType = ConsentType(rawValue: consentTypeRaw),
                let granted: Bool = row["granted"],
                let timestamp: Date = row["timestamp"],
                let version: String = row["version"],
                let createdAt: Date = row["created_at"]
            else {
                throw NSError(
                    domain: "PrivacyGateway",
                    code: 1001,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to decode consent record"]
                )
            }

            let ipAddress: String? = row["ip_address"]
            return ConsentRecord(
                id: id,
                userId: resolvedUserId,
                consentType: consentType,
                granted: granted,
                timestamp: timestamp,
                version: version,
                ipAddress: ipAddress,
                createdAt: createdAt
            )
        }
    }

    private func enqueueWriteIntent(
        path: String,
        method: HTTPMethod,
        body: [String: Any],
        priority: Int
    ) async throws {
        let payload = try JSONSerialization.data(withJSONObject: body)
        let event = OutboxEvent(
            httpMethod: method,
            path: path,
            bodyJson: payload,
            priority: priority
        )
        if let syncEngine = AppContainer.shared?.syncEngine {
            try await syncEngine.enqueueMutation(event)
            return
        }

        // Fallback path when AppContainer is not initialized (e.g. tests).
        try await dbQueue.write { db in
            try event.insert(db)
        }
    }

    private func latestUserId() async throws -> UUID? {
        try await latestUserContext()?.userId
    }

    private func hasActiveCloudSession() async -> Bool {
        await MainActor.run {
            AuthManager.activeAuthId != nil && AuthManager.activeHasCloudSession
        }
    }

    private func ensureActiveCloudSession() async throws {
        guard await hasActiveCloudSession() else {
            throw AuthError.cloudSessionReconnectRequired
        }
    }

    private func latestUserContext() async throws -> LocalPrivacyUserContext? {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        guard let authId else { return nil }
        return try await dbQueue.read { db in
            guard let user = try UserIdentityLookup.fetchUser(authId: authId, db: db) else {
                return nil
            }
            return LocalPrivacyUserContext(userId: user.id, authId: user.authId)
        }
    }

    private func localExportStatus(exportId: String) async throws -> ExportStatusResponse {
        let row = try dbQueue.read { db in
            return try Row.fetchOne(
                db,
                sql: """
                    SELECT status, download_url, failure_reason
                    FROM export_jobs
                    WHERE id = ?
                    LIMIT 1
                    """,
                arguments: [exportId]
            )
        }

        guard let row else {
            throw PrivacyError.exportNotReady
        }

        let status: String = row["status"] ?? "pending"
        let downloadUrl: String? = row["download_url"]
        if let downloadUrl,
           let fileURL = URL(string: downloadUrl),
           fileURL.isFileURL,
           !FileManager.default.fileExists(atPath: fileURL.path) {
            if let userId = try await latestUserId() {
                try await upsertLocalExportJob(
                    exportId: exportId,
                    userId: userId,
                    status: "failed",
                    downloadUrl: nil,
                    requestedAt: nil,
                    completedAt: Date(),
                    failureReason: String(localized: "settings_export_local_missing_file")
                )
            }
            return ExportStatusResponse(exportId: exportId, status: "failed", downloadUrl: nil)
        }

        return ExportStatusResponse(exportId: exportId, status: status, downloadUrl: downloadUrl)
    }

    private func upsertLocalExportJob(
        exportId: String,
        userId: UUID,
        status: String,
        downloadUrl: String?,
        requestedAt: Date?,
        completedAt: Date?,
        failureReason: String?
    ) async throws {
        try await dbQueue.write { db in
            let existingRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT requested_at, created_at
                    FROM export_jobs
                    WHERE id = ?
                    LIMIT 1
                    """,
                arguments: [exportId]
            )
            let now = Date()
            let resolvedRequestedAt = requestedAt ?? (existingRow?["requested_at"] as Date?) ?? now
            let createdAt = (existingRow?["created_at"] as Date?) ?? now

            try db.execute(
                sql: """
                    INSERT INTO export_jobs (
                        id, user_id, status, download_url, requested_at,
                        completed_at, failure_reason, created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        user_id = excluded.user_id,
                        status = excluded.status,
                        download_url = excluded.download_url,
                        requested_at = excluded.requested_at,
                        completed_at = excluded.completed_at,
                        failure_reason = excluded.failure_reason,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    exportId,
                    userId.uuidString,
                    status,
                    downloadUrl,
                    resolvedRequestedAt,
                    completedAt,
                    failureReason,
                    createdAt,
                    now
                ]
            )
        }
    }

    private static func friendlyPrivacyMessage(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return SettingsError.exportFailed.errorDescription ?? "Export failed"
    }

    private static func validateTrustedRemoteExportDownloadURL(_ url: URL) throws {
        guard let resolvedComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let expectedComponents = URLComponents(url: SupabaseConfig.url, resolvingAgainstBaseURL: false),
              resolvedComponents.scheme?.lowercased() == expectedComponents.scheme?.lowercased(),
              resolvedComponents.host?.lowercased() == expectedComponents.host?.lowercased(),
              resolvedComponents.port == expectedComponents.port,
              resolvedComponents.path == "/functions/v1/api-user-export-download" else {
            throw SettingsError.exportFailed
        }
    }

    private static func httpStatusCode(_ error: Error) -> Int? {
        let nsError = error as NSError
        guard nsError.domain == "APIClientHTTPErrorDomain" else { return nil }
        return nsError.code
    }
}

extension PrivacyGateway {
    nonisolated private static func decodeUUID(from row: Row, column: String) -> UUID? {
        let value: DatabaseValue = row[column]

        if let uuidString = String.fromDatabaseValue(value), let uuid = UUID(uuidString: uuidString) {
            return uuid
        }
        if let uuid = UUID.fromDatabaseValue(value) {
            return uuid
        }
        if let uuidData = Data.fromDatabaseValue(value) {
            return decodeUUID(from: uuidData)
        }
        return nil
    }

    nonisolated private static func decodeUUID(from data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        let bytes = Array(data)
        let uuidTuple = uuid_t(
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuidTuple)
    }
}

#if DEBUG
extension PrivacyGateway {
    nonisolated static func _testDecodeUUID(from row: Row, column: String) -> UUID? {
        decodeUUID(from: row, column: column)
    }

    nonisolated static func _testDecodeUUID(from data: Data) -> UUID? {
        decodeUUID(from: data)
    }
}
#endif

extension APIClient: PrivacyStatusAPIClient {
    func callPrivacyStatusEdgeFunction<T: Decodable & Sendable>(
        _ name: String,
        body: Data
    ) async throws -> T {
        try await callEdgeFunction(
            name,
            body: body,
            headers: [:],
            maxAttempts: 3
        )
    }

    func downloadPrivacyExport(from url: URL) async throws -> PrivacyDownloadedExportArchive {
        try await downloadAuthenticatedFile(from: url)
    }
}

struct ExportRequestResponse: Codable, Sendable {
    let exportId: String
    let status: String?

    enum CodingKeys: String, CodingKey {
        case exportId = "export_id"
        case status
    }
}

struct ExportStatusResponse: Codable, Sendable {
    let exportId: String
    let status: String
    let downloadUrl: String?

    enum CodingKeys: String, CodingKey {
        case exportId = "export_id"
        case status
        case downloadUrl = "download_url"
    }
}

struct ErasureStatusResponse: Codable, Sendable {
    let scheduled: Bool
    let deletionDate: String?
    let deletionInProgress: Bool
    let reason: String?
    let deletionState: String?
    let deletionMode: String?
    let deletionAttemptCount: Int?
    let retryAfterSeconds: Int?
    let idempotencyKey: String?

    enum CodingKeys: String, CodingKey {
        case scheduled
        case deletionDate = "deletion_date"
        case deletionInProgress = "deletion_in_progress"
        case reason
        case deletionState = "deletion_state"
        case deletionMode = "deletion_mode"
        case deletionAttemptCount = "deletion_attempt_count"
        case retryAfterSeconds = "retry_after_seconds"
        case idempotencyKey = "idempotency_key"
    }
}

struct ErasureCancelResponse: Codable, Sendable {
    let cancelled: Bool
    let status: String?
    let deletionState: String?

    enum CodingKeys: String, CodingKey {
        case cancelled
        case status
        case deletionState = "deletion_state"
    }
}

private enum DownloadedPrivacyExportStore {
    private static let staleArchiveLifetime: TimeInterval = 24 * 60 * 60

    static func persist(archive: PrivacyDownloadedExportArchive) throws -> URL {
        let directory = try exportsDirectory()
        try pruneStaleArchives(in: directory)

        let fileURL = directory.appendingPathComponent(
            sanitizedFilename(
                archive.suggestedFilename,
                contentType: archive.contentType
            ),
            isDirectory: false
        )

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try archive.data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private static func exportsDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent("PrivacyExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func pruneStaleArchives(in directory: URL) throws {
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )

        let expirationDate = Date().addingTimeInterval(-staleArchiveLifetime)
        for url in urls {
            let values = try url.resourceValues(forKeys: resourceKeys)
            if values.isDirectory == true {
                continue
            }
            let modifiedAt = values.contentModificationDate ?? .distantPast
            if modifiedAt < expirationDate {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private static func sanitizedFilename(_ suggestedFilename: String, contentType: String?) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let trimmed = suggestedFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.components(separatedBy: invalidCharacters).joined(separator: "-")
        let collapsed = cleaned.replacingOccurrences(
            of: #"[\r\n\t]+"#,
            with: "-",
            options: .regularExpression
        )
        let fallbackName = fallbackFilename(contentType: contentType)
        let resolved = collapsed.isEmpty ? fallbackName : collapsed

        if URL(fileURLWithPath: resolved).pathExtension.isEmpty,
           let fallbackExtension = URL(fileURLWithPath: fallbackName).pathExtension.nilIfEmpty {
            return "\(resolved).\(fallbackExtension)"
        }
        return resolved
    }

    private static func fallbackFilename(contentType: String?) -> String {
        let normalizedContentType = contentType?
            .split(separator: ";")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalizedContentType {
        case "application/json":
            return "lifeos-export.json"
        case "application/zip":
            return "lifeos-export.zip"
        default:
            return "lifeos-export"
        }
    }
}
