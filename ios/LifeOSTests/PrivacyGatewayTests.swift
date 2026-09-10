import Foundation
import GRDB
import XCTest
@testable import LifeOS

private actor PrivacyStatusClientMock: PrivacyStatusAPIClient {
    struct Invocation: Sendable {
        let name: String
        let body: Data
    }

    enum MockError: Error {
        case missingResponse(String)
        case missingDownloadResponse(String)
    }

    private let responses: [String: Data]
    private let downloadResponses: [String: PrivacyDownloadedExportArchive]
    private let receiptResponse: ErasureStatusResponse?
    private var invocations: [Invocation] = []
    private var downloadInvocations: [URL] = []

    init(
        responses: [String: Data] = [:],
        downloadResponses: [String: PrivacyDownloadedExportArchive] = [:],
        receiptResponse: ErasureStatusResponse? = nil
    ) {
        self.responses = responses
        self.downloadResponses = downloadResponses
        self.receiptResponse = receiptResponse
    }

    func deletionReceiptStatus(_ receipt: String) async throws -> ErasureStatusResponse {
        guard receipt.count == 64, let receiptResponse else { throw MockError.missingResponse("receipt") }
        return receiptResponse
    }

    func callPrivacyStatusEdgeFunction<T: Decodable & Sendable>(
        _ name: String,
        body: Data
    ) async throws -> T {
        invocations.append(Invocation(name: name, body: body))
        guard let payload = responses[name] else {
            throw MockError.missingResponse(name)
        }
        return try JSONDecoder().decode(T.self, from: payload)
    }

    func downloadPrivacyExport(from url: URL) async throws -> PrivacyDownloadedExportArchive {
        downloadInvocations.append(url)
        guard let archive = downloadResponses[url.absoluteString] else {
            throw MockError.missingDownloadResponse(url.absoluteString)
        }
        return archive
    }

    func allInvocations() -> [Invocation] {
        invocations
    }

    func allDownloadInvocations() -> [URL] {
        downloadInvocations
    }
}

final class PrivacyGatewayTests: XCTestCase {

    @MainActor
    func testDeletionReceiptSurvivesLostSessionAndConfirmsCompletionWithoutAuthRequest() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        try AccountDeletionReceiptStore.clear()
        defer {
            try? AccountDeletionReceiptStore.clear()
            AuthManager.setActiveAuthIdForTests(nil)
            AuthManager._testSetActiveHasCloudSession(false)
        }
        try await manager.dbQueue.write { db in try Self.insertUser(db, userId: authId, authId: authId) }
        let token = try AccountDeletionReceiptStore.prepare(authId: authId)
        XCTAssertEqual(token.count, 64)
        XCTAssertTrue(token.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(try AccountDeletionReceiptStore.prepare(authId: authId), token, "Retries retain the pre-request receipt")
        try AccountDeletionReceiptStore.save(.init(token: token, expiresAt: nil, authId: authId, completed: false, localErased: true))
        AuthManager.setActiveAuthIdForTests(authId)
        AuthManager._testSetActiveHasCloudSession(false)
        let client = PrivacyStatusClientMock(receiptResponse: AccountDeletionReceiptStore.status(state: "completed"))
        let gateway = PrivacyGateway(apiClient: client, dbQueue: manager.dbQueue, isRuntimeConfiguredProvider: { true })
        let status = try await gateway.erasureStatus()
        XCTAssertEqual(status.deletionState, "completed")
        XCTAssertTrue(try XCTUnwrap(AccountDeletionReceiptStore.load()).completed)
        XCTAssertNil(try AccountDeletionReceiptStore.load()?.token)
        let authenticatedRequests = await client.allInvocations()
        XCTAssertTrue(authenticatedRequests.isEmpty)
    }

    private static func insertUser(_ db: Database, userId: UUID, authId: UUID = UUID()) throws {
        var user = User(id: userId, authId: authId, timezone: "UTC", units: .metric)
        user.weightKg = 72
        try user.insert(db)
    }

    private static func insertExportJob(
        _ db: Database,
        exportId: String,
        userId: UUID,
        status: String,
        downloadURL: String?,
        requestedAt: Date = Date(),
        completedAt: Date? = nil,
        failureReason: String? = nil
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO export_jobs (
                    id, user_id, status, download_url, requested_at,
                    completed_at, failure_reason, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                exportId,
                userId.uuidString,
                status,
                downloadURL,
                requestedAt,
                completedAt,
                failureReason,
                requestedAt,
                requestedAt
            ]
        )
    }

    @MainActor
    func testRequestExportQueuesOutboxEventAndReturnsQueuedResponse() async throws {
        let manager = try DatabaseManager.inMemory()
        let previousContainer = AppContainer.shared
        let authId = UUID()
        let userId = UUID()
        AppContainer.shared = nil
        AuthManager.setActiveAuthIdForTests(authId)
        AuthManager._testSetActiveHasCloudSession(true)
        defer {
            AppContainer.shared = previousContainer
            AuthManager.setActiveAuthIdForTests(nil)
            AuthManager._testSetActiveHasCloudSession(false)
        }

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
        }

        let gateway = PrivacyGateway(
            apiClient: PrivacyStatusClientMock(),
            dbQueue: manager.dbQueue,
            isRuntimeConfiguredProvider: { true }
        )

        let response = try await gateway.requestExport()
        XCTAssertEqual(response.status, "queued")
        XCTAssertFalse(response.exportId.isEmpty)

        try await manager.dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT path, priority, body_json FROM outbox_events WHERE path = ? LIMIT 1",
                arguments: ["api-user-export"]
            )
            XCTAssertEqual(row?["path"], "api-user-export")
            XCTAssertEqual(row?["priority"], 60)

            let bodyData: Data? = row?["body_json"]
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try XCTUnwrap(bodyData)) as? [String: Any]
            )
            XCTAssertEqual(payload["export_id"] as? String, response.exportId)
        }
    }

    @MainActor
    func testRequestExportPersistsLocalExportJobForResolvedUser() async throws {
        let manager = try DatabaseManager.inMemory()
        let previousContainer = AppContainer.shared
        let authId = UUID()
        let userId = UUID()
        AppContainer.shared = nil
        AuthManager.setActiveAuthIdForTests(authId)
        AuthManager._testSetActiveHasCloudSession(true)
        defer {
            AppContainer.shared = previousContainer
            AuthManager.setActiveAuthIdForTests(nil)
            AuthManager._testSetActiveHasCloudSession(false)
        }

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
        }

        let gateway = PrivacyGateway(
            apiClient: PrivacyStatusClientMock(),
            dbQueue: manager.dbQueue,
            isRuntimeConfiguredProvider: { true }
        )

        let response = try await gateway.requestExport()

        try await manager.dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT user_id, status, download_url FROM export_jobs WHERE id = ? LIMIT 1",
                arguments: [response.exportId]
            )
            let status: String? = row?["status"]
            let downloadUrl: String? = row?["download_url"]
            let storedUserId: String? = row?["user_id"]
            XCTAssertEqual(status, "queued")
            XCTAssertNil(downloadUrl)
            XCTAssertEqual(storedUserId, userId.uuidString)
        }
    }

    @MainActor
    func testRequestErasureAndCancelQueueExpectedEvents() async throws {
        let manager = try DatabaseManager.inMemory()
        let previousContainer = AppContainer.shared
        let authId = UUID()
        let userId = UUID()
        AppContainer.shared = nil
        AuthManager.setActiveAuthIdForTests(authId)
        AuthManager._testSetActiveHasCloudSession(true)
        defer {
            AppContainer.shared = previousContainer
            AuthManager.setActiveAuthIdForTests(nil)
            AuthManager._testSetActiveHasCloudSession(false)
        }

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
        }

        let gateway = PrivacyGateway(
            apiClient: PrivacyStatusClientMock(),
            dbQueue: manager.dbQueue,
            isRuntimeConfiguredProvider: { true }
        )

        try await gateway.requestErasure(reason: "cleanup")
        let cancel = try await gateway.cancelScheduledErasure()
        XCTAssertEqual(cancel.status, "queued")
        XCTAssertFalse(cancel.cancelled)

        try await manager.dbQueue.read { db in
            let deleteCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?",
                arguments: ["api-account-delete"]
            ) ?? 0
            let cancelCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?",
                arguments: ["api-account-delete-cancel"]
            ) ?? 0
            XCTAssertEqual(deleteCount, 1)
            XCTAssertEqual(cancelCount, 1)

            let row = try Row.fetchOne(
                db,
                sql: "SELECT body_json FROM outbox_events WHERE path = ? LIMIT 1",
                arguments: ["api-account-delete"]
            )
            let bodyData: Data? = row?["body_json"]
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try XCTUnwrap(bodyData)) as? [String: Any]
            )
            XCTAssertEqual(payload["reason"] as? String, "cleanup")
            XCTAssertEqual(payload["immediate"] as? Bool, false)
        }
    }

    @MainActor
    func testExportStatusAndErasureStatusUseApiClientPayloads() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        AuthManager.setActiveAuthIdForTests(authId)
        AuthManager._testSetActiveHasCloudSession(true)
        defer {
            AuthManager.setActiveAuthIdForTests(nil)
            AuthManager._testSetActiveHasCloudSession(false)
        }
        let exportPayload = Data(
            """
            {
              "export_id": "exp_123",
              "status": "ready",
              "download_url": "https://example.com/export.zip"
            }
            """.utf8
        )
        let erasurePayload = Data(
            """
            {
              "scheduled": true,
              "deletion_date": "2026-03-01",
              "deletion_in_progress": false,
              "reason": "user_requested",
              "deletion_state": "scheduled",
              "deletion_mode": "scheduled",
              "deletion_attempt_count": 2,
              "retry_after_seconds": 180,
              "idempotency_key": "idem-123"
            }
            """.utf8
        )
        let client = PrivacyStatusClientMock(
            responses: [
                "api-user-export-status": exportPayload,
                "api-account-delete-status": erasurePayload
            ]
        )
        let gateway = PrivacyGateway(
            apiClient: client,
            dbQueue: manager.dbQueue,
            isRuntimeConfiguredProvider: { true }
        )

        let exportStatus = try await gateway.exportStatus(exportId: "exp_123")
        XCTAssertEqual(exportStatus.exportId, "exp_123")
        XCTAssertEqual(exportStatus.status, "ready")
        XCTAssertEqual(exportStatus.downloadUrl, "https://example.com/export.zip")

        let erasureStatus = try await gateway.erasureStatus()
        XCTAssertTrue(erasureStatus.scheduled)
        XCTAssertEqual(erasureStatus.deletionDate, "2026-03-01")
        XCTAssertFalse(erasureStatus.deletionInProgress)
        XCTAssertEqual(erasureStatus.reason, "user_requested")
        XCTAssertEqual(erasureStatus.deletionState, "scheduled")
        XCTAssertEqual(erasureStatus.deletionMode, "scheduled")
        XCTAssertEqual(erasureStatus.deletionAttemptCount, 2)
        XCTAssertEqual(erasureStatus.retryAfterSeconds, 180)
        XCTAssertEqual(erasureStatus.idempotencyKey, "idem-123")

        let invocations = await client.allInvocations()
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[0].name, "api-user-export-status")
        XCTAssertEqual(invocations[1].name, "api-account-delete-status")

        let exportBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: invocations[0].body) as? [String: Any]
        )
        XCTAssertEqual(exportBody["export_id"] as? String, "exp_123")

        let erasureBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: invocations[1].body) as? [String: Any]
        )
        XCTAssertTrue(erasureBody.isEmpty)
    }

    @MainActor
    func testDownloadExportArchiveReturnsExistingLocalArchiveFile() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let exportId = UUID().uuidString
        let localFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("privacy-export-\(UUID().uuidString)")
            .appendingPathExtension("json")
        try Data("{\"local\":true}".utf8).write(to: localFileURL, options: .atomic)

        AuthManager.setActiveAuthIdForTests(authId)
        defer {
            AuthManager.setActiveAuthIdForTests(nil)
            try? FileManager.default.removeItem(at: localFileURL)
        }

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            try Self.insertExportJob(
                db,
                exportId: exportId,
                userId: userId,
                status: "ready",
                downloadURL: localFileURL.absoluteString,
                completedAt: Date()
            )
        }

        let client = PrivacyStatusClientMock()
        let gateway = PrivacyGateway(apiClient: client, dbQueue: manager.dbQueue)

        let archiveURL = try await gateway.downloadExportArchive(exportId: exportId)
        XCTAssertEqual(archiveURL, localFileURL)
        let downloadInvocations = await client.allDownloadInvocations()
        XCTAssertEqual(downloadInvocations, [URL]())
    }

    @MainActor
    func testDownloadExportArchivePersistsTrustedRemoteArchiveToTemporaryFile() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let exportId = UUID().uuidString
        var components = URLComponents(
            url: SupabaseConfig.url.appendingPathComponent("functions/v1/api-user-export-download"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "export_id", value: exportId),
            URLQueryItem(name: "token", value: "download-token")
        ]
        let remoteURL = try XCTUnwrap(components?.url)
        let archivePayload = Data("{\"remote\":true}".utf8)

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            try Self.insertExportJob(
                db,
                exportId: exportId,
                userId: userId,
                status: "ready",
                downloadURL: remoteURL.absoluteString,
                completedAt: Date()
            )
        }

        let client = PrivacyStatusClientMock(
            downloadResponses: [
                remoteURL.absoluteString: PrivacyDownloadedExportArchive(
                    data: archivePayload,
                    suggestedFilename: "lifeos_export_test.json",
                    contentType: "application/json"
                )
            ]
        )
        let gateway = PrivacyGateway(apiClient: client, dbQueue: manager.dbQueue)

        let archiveURL = try await gateway.downloadExportArchive(exportId: exportId)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        XCTAssertTrue(archiveURL.isFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
        let bundle = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: archiveURL)) as? [String: Any])
        XCTAssertEqual((bundle["cloud_snapshot"] as? [String: Any])?["remote"] as? Bool, true)
        let local = try XCTUnwrap(bundle["local_snapshot"] as? [String: Any])
        let tables = try XCTUnwrap(local["tables"] as? [String: Any])
        XCTAssertNotNil(tables["users"])
        XCTAssertEqual(archiveURL.lastPathComponent, "lifeos_export_test.json")
        let downloadInvocations = await client.allDownloadInvocations()
        XCTAssertEqual(downloadInvocations, [remoteURL])
    }

    @MainActor
    func testDownloadExportArchiveRejectsUntrustedRemoteDownloadURL() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let exportId = UUID().uuidString
        let remoteURL = URL(string: "https://example.com/functions/v1/api-user-export-download?export_id=\(exportId)&token=download-token")!

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            try Self.insertExportJob(
                db,
                exportId: exportId,
                userId: userId,
                status: "ready",
                downloadURL: remoteURL.absoluteString,
                completedAt: Date()
            )
        }

        let client = PrivacyStatusClientMock()
        let gateway = PrivacyGateway(apiClient: client, dbQueue: manager.dbQueue)

        do {
            _ = try await gateway.downloadExportArchive(exportId: exportId)
            XCTFail("Expected untrusted remote export URL to be rejected")
        } catch let error as SettingsError {
            guard case .exportFailed = error else {
                return XCTFail("Expected exportFailed, got \(error.localizedDescription)")
            }
        }
        let downloadInvocations = await client.allDownloadInvocations()
        XCTAssertEqual(downloadInvocations, [URL]())
    }

    @MainActor
    func testExportStatusUpdatesLocalExportJobSnapshot() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let exportId = UUID().uuidString
        AuthManager.setActiveAuthIdForTests(authId)
        AuthManager._testSetActiveHasCloudSession(true)
        defer {
            AuthManager.setActiveAuthIdForTests(nil)
            AuthManager._testSetActiveHasCloudSession(false)
        }

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
        }

        let client = PrivacyStatusClientMock(
            responses: [
                "api-user-export-status": Data(
                    """
                    {
                      "export_id": "\(exportId)",
                      "status": "ready",
                      "download_url": "https://example.com/archive.zip"
                    }
                    """.utf8
                )
            ]
        )
        let gateway = PrivacyGateway(
            apiClient: client,
            dbQueue: manager.dbQueue,
            isRuntimeConfiguredProvider: { true }
        )

        let response = try await gateway.exportStatus(exportId: exportId)
        XCTAssertEqual(response.status, "ready")

        try await manager.dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT user_id, status, download_url, completed_at FROM export_jobs WHERE id = ? LIMIT 1",
                arguments: [exportId]
            )
            let storedUserId: String? = row?["user_id"]
            let status: String? = row?["status"]
            let downloadUrl: String? = row?["download_url"]
            let completedAt: Date? = row?["completed_at"]
            XCTAssertEqual(storedUserId, userId.uuidString)
            XCTAssertEqual(status, "ready")
            XCTAssertEqual(downloadUrl, "https://example.com/archive.zip")
            XCTAssertNotNil(completedAt)
        }
    }

    func testErasureCancelResponseDecodesDeletionState() throws {
        let payload = Data(
            """
            {
              "cancelled": true,
              "deletion_state": "cancelled"
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(ErasureCancelResponse.self, from: payload)
        XCTAssertTrue(decoded.cancelled)
        XCTAssertEqual(decoded.deletionState, "cancelled")
        XCTAssertNil(decoded.status)
    }

    func testRecordConsentPersistsAndLatestConsentReturnsNewest() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let previousContainer = AppContainer.shared
        AppContainer.shared = nil
        defer { AppContainer.shared = previousContainer }

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId)
        }

        let gateway = PrivacyGateway(
            apiClient: PrivacyStatusClientMock(),
            dbQueue: manager.dbQueue
        )

        try await gateway.recordConsent(
            userId: userId,
            consentType: .privacyPolicy,
            granted: true,
            version: "v1"
        )
        try await Task.sleep(nanoseconds: 2_000_000)
        try await gateway.recordConsent(
            userId: userId,
            consentType: .privacyPolicy,
            granted: false,
            version: "v2"
        )

        let latest = try await gateway.latestConsent(userId: userId, type: .privacyPolicy)
        XCTAssertEqual(latest?.version, "v2")
        XCTAssertEqual(latest?.granted, false)

        try await manager.dbQueue.read { db in
            let consentCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM consent_records WHERE consent_type = ?",
                arguments: [ConsentType.privacyPolicy.rawValue]
            ) ?? 0
            XCTAssertEqual(consentCount, 2)

            let outboxCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?",
                arguments: ["api-settings-consent"]
            ) ?? 0
            XCTAssertEqual(outboxCount, 0)
        }
    }

    func testRecordConsentQueuesOutboxWhenSyncEngineIsAvailable() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let previousContainer = AppContainer.shared
        defer { AppContainer.shared = previousContainer }

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId)
        }

        AppContainer.shared = AppContainer(
            syncEngine: SyncEngine(
                dbQueue: manager.dbQueue,
                apiClient: FakeSyncAPIClient(),
                pushTransportOverride: { _ in }
            )
        )
        let gateway = PrivacyGateway(
            apiClient: PrivacyStatusClientMock(),
            dbQueue: manager.dbQueue
        )

        try await gateway.recordConsent(
            userId: userId,
            consentType: .termsOfService,
            granted: true,
            version: "v3",
            ipAddress: "127.0.0.1"
        )

        try await manager.dbQueue.read { db in
            let outboxCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?",
                arguments: ["api-settings-consent"]
            ) ?? 0
            XCTAssertEqual(outboxCount, 1)
        }
    }

    func testLatestConsentReturnsNilWhenNoMatchingRows() async throws {
        let manager = try DatabaseManager.inMemory()
        let gateway = PrivacyGateway(apiClient: PrivacyStatusClientMock(), dbQueue: manager.dbQueue)

        let result = try await gateway.latestConsent(userId: UUID(), type: .privacyPolicy)
        XCTAssertNil(result)
    }

    func testLatestConsentThrowsWhenStoredRowCannotDecode() async throws {
        let manager = try DatabaseManager.inMemory()
        let gateway = PrivacyGateway(apiClient: PrivacyStatusClientMock(), dbQueue: manager.dbQueue)
        let userId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId)
            try db.execute(
                sql: """
                    INSERT INTO consent_records (
                        id, user_id, consent_type, granted, timestamp, version, ip_address, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "not-a-uuid",
                    userId.uuidString,
                    ConsentType.privacyPolicy.rawValue,
                    true,
                    Date(),
                    "v1",
                    nil as String?,
                    Date(),
                ]
            )
        }

        do {
            _ = try await gateway.latestConsent(userId: userId, type: .privacyPolicy)
            XCTFail("Expected malformed consent row to throw")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "PrivacyGateway")
            XCTAssertEqual(error.code, 1001)
        }
    }

    func testDecodeUUIDHelpersCoverRowAndDataVariants() async throws {
        let manager = try DatabaseManager.inMemory()
        let validUUID = UUID()
        let validUUIDBytes = withUnsafeBytes(of: validUUID.uuid) { Data($0) }

        try await manager.dbQueue.read { db in
            let uuidRow = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT ? AS value", arguments: [validUUID]))
            XCTAssertEqual(PrivacyGateway._testDecodeUUID(from: uuidRow, column: "value"), validUUID)

            let invalidStringRow = try XCTUnwrap(
                Row.fetchOne(db, sql: "SELECT ? AS value", arguments: ["definitely-not-uuid"])
            )
            XCTAssertNil(PrivacyGateway._testDecodeUUID(from: invalidStringRow, column: "value"))

            let dataRow = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT ? AS value", arguments: [validUUIDBytes]))
            XCTAssertEqual(PrivacyGateway._testDecodeUUID(from: dataRow, column: "value"), validUUID)

            let invalidDataRow = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT ? AS value", arguments: [Data([1, 2, 3])]))
            XCTAssertNil(PrivacyGateway._testDecodeUUID(from: invalidDataRow, column: "value"))

            let nullRow = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT NULL AS value"))
            XCTAssertNil(PrivacyGateway._testDecodeUUID(from: nullRow, column: "value"))
        }

        XCTAssertEqual(PrivacyGateway._testDecodeUUID(from: validUUIDBytes), validUUID)
        XCTAssertNil(PrivacyGateway._testDecodeUUID(from: Data([1, 2, 3])))
    }

    func testAPIClientPrivacyStatusBridgeUsesEdgeFunctionCall() async throws {
        let responsePayload = Data(
            """
            {
              "export_id": "bridge_export",
              "status": "queued",
              "download_url": null
            }
            """.utf8
        )
        APIClient._testSetEdgeInvokeOverride { name, _ in
            XCTAssertEqual(name, "api-user-export-status")
            return (
                responsePayload,
                HTTPURLResponse(
                    url: URL(string: "https://example.com")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
        defer { APIClient._testSetEdgeInvokeOverride(nil) }

        let apiClient = APIClient()
        let result: ExportStatusResponse = try await apiClient.callPrivacyStatusEdgeFunction(
            "api-user-export-status",
            body: Data("{\"export_id\":\"bridge_export\"}".utf8)
        )
        XCTAssertEqual(result.exportId, "bridge_export")
        XCTAssertEqual(result.status, "queued")
        XCTAssertNil(result.downloadUrl)
    }

    func testAPIClientDownloadAuthenticatedFileUsesBearerHeadersAndFilenameMetadata() async throws {
        APIClient._testResetOverrides()
        APIClient._testSetPostgrestAccessTokenOverride("privacy-download-token")
        APIClient._testSetEdgeRouteDataForRequestOverride { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), SupabaseConfig.anonKey)
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer privacy-download-token"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "*/*")
            XCTAssertFalse((request.value(forHTTPHeaderField: "X-Correlation-Id") ?? "").isEmpty)

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url ?? URL(string: "https://example.com")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "application/json; charset=utf-8",
                        "Content-Disposition": "attachment; filename*=UTF-8''lifeos_export_remote.json"
                    ]
                )
            )
            return (Data("{\"downloaded\":true}".utf8), response)
        }
        defer { APIClient._testResetOverrides() }

        var components = URLComponents(
            url: SupabaseConfig.url.appendingPathComponent("functions/v1/api-user-export-download"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "export_id", value: "bridge_export"),
            URLQueryItem(name: "token", value: "bridge_token")
        ]
        let archive = try await APIClient().downloadAuthenticatedFile(
            from: try XCTUnwrap(components?.url)
        )

        XCTAssertEqual(archive.data, Data("{\"downloaded\":true}".utf8))
        XCTAssertEqual(archive.suggestedFilename, "lifeos_export_remote.json")
        XCTAssertEqual(archive.contentType, "application/json; charset=utf-8")
    }
}
