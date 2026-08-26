import Foundation
import GRDB
import XCTest
@testable import LifeOS

struct SyncAPIUpsertCall: Sendable {
    let table: String
    let bodyJson: Data
    let headers: [String: String]
}

struct SyncAPIEdgeCall: Sendable {
    let name: String
    let route: String
    let method: String
    let body: Data
    let headers: [String: String]
    let maxAttempts: Int
}

struct SyncAPIStorageUploadCall: Sendable {
    let bucket: String
    let path: String
    let fileURL: URL
    let contentType: String
}

struct StubbedAPIError: Error, Sendable {
    let domain: String
    let code: Int
    let status: Int?
    let retryAfterSeconds: TimeInterval?
    let message: String

    func asNSError() -> NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let status {
            userInfo["status"] = status
        }
        if let retryAfterSeconds {
            userInfo["retry_after_seconds"] = retryAfterSeconds
        }
        return NSError(domain: domain, code: code, userInfo: userInfo)
    }
}

actor FakeSyncAPIClient: SyncAPIClient {
    private var blockMutations = false
    private var authenticatedUserId = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private var fetchedTables: [String] = []
    private var usersPages: [[User]] = []
    private var queuedUpsertErrors: [StubbedAPIError] = []
    private var queuedEdgeErrors: [StubbedAPIError] = []
    private var queuedEdgeResponses: [Data] = []
    private var upsertCalls: [SyncAPIUpsertCall] = []
    private var edgeCalls: [SyncAPIEdgeCall] = []
    private var storageUploadCalls: [SyncAPIStorageUploadCall] = []

    func setBlockMutations(_ value: Bool) {
        blockMutations = value
    }

    func setUsersPages(_ pages: [[User]]) {
        usersPages = pages
    }

    func setUpsertErrors(_ errors: [StubbedAPIError]) {
        queuedUpsertErrors = errors
    }

    func setEdgeErrors(_ errors: [StubbedAPIError]) {
        queuedEdgeErrors = errors
    }

    func setEdgeResponses(_ responses: [Data]) {
        queuedEdgeResponses = responses
    }

    func setAuthenticatedUserId(_ userId: UUID) {
        authenticatedUserId = userId
    }

    func shouldBlockMutationsForForceUpdate() async -> Bool {
        blockMutations
    }

    func fetchSyncPage<T: Decodable & Sendable>(
        from table: String,
        since: Date?,
        cursor: APIClient.SyncPageCursor?,
        limit: Int,
        activeWindowDays: Int?
    ) async throws -> [T] {
        fetchedTables.append(table)
        _ = since
        _ = cursor
        _ = limit
        _ = activeWindowDays

        if table == "users", T.self == User.self, !usersPages.isEmpty {
            let page = usersPages.removeFirst()
            // swiftlint:disable:next force_cast
            return page as! [T]
        }
        return []
    }

    func upsertRow(
        table: String,
        bodyJson: Data,
        headers: [String: String]
    ) async throws {
        upsertCalls.append(SyncAPIUpsertCall(table: table, bodyJson: bodyJson, headers: headers))
        if !queuedUpsertErrors.isEmpty {
            throw queuedUpsertErrors.removeFirst().asNSError()
        }
    }

    func callEdgeFunction<T: Decodable & Sendable>(
        _ name: String,
        body: Data,
        headers: [String: String],
        maxAttempts: Int
    ) async throws -> T {
        edgeCalls.append(
            SyncAPIEdgeCall(
                name: name,
                route: "",
                method: HTTPMethod.POST.rawValue,
                body: body,
                headers: headers,
                maxAttempts: maxAttempts
            )
        )
        if !queuedEdgeErrors.isEmpty {
            throw queuedEdgeErrors.removeFirst().asNSError()
        }
        let responseData = queuedEdgeResponses.isEmpty ? Data("{}".utf8) : queuedEdgeResponses.removeFirst()
        return try JSONDecoder().decode(T.self, from: responseData)
    }

    func callEdgeRoute<T: Decodable & Sendable>(
        function name: String,
        route: String,
        method: String,
        queryItems: [URLQueryItem],
        body: Data?,
        headers: [String: String],
        maxAttempts: Int
    ) async throws -> T {
        _ = queryItems
        edgeCalls.append(
            SyncAPIEdgeCall(
                name: name,
                route: route,
                method: method,
                body: body ?? Data("{}".utf8),
                headers: headers,
                maxAttempts: maxAttempts
            )
        )
        if !queuedEdgeErrors.isEmpty {
            throw queuedEdgeErrors.removeFirst().asNSError()
        }
        let responseData = queuedEdgeResponses.isEmpty ? Data("{}".utf8) : queuedEdgeResponses.removeFirst()
        return try JSONDecoder().decode(T.self, from: responseData)
    }

    func currentAuthUserId() async throws -> UUID {
        authenticatedUserId
    }

    func uploadStorageObject(
        bucket: String,
        path: String,
        fileURL: URL,
        contentType: String
    ) async throws {
        storageUploadCalls.append(
            SyncAPIStorageUploadCall(
                bucket: bucket,
                path: path,
                fileURL: fileURL,
                contentType: contentType
            )
        )
    }

    func fetchCallCount() -> Int {
        fetchedTables.count
    }

    func upsertCallCount() -> Int {
        upsertCalls.count
    }

    func edgeCallCount() -> Int {
        edgeCalls.count
    }

    func latestUpsertCall() -> SyncAPIUpsertCall? {
        upsertCalls.last
    }

    func latestEdgeCall() -> SyncAPIEdgeCall? {
        edgeCalls.last
    }

    func uploadCallCount() -> Int {
        storageUploadCalls.count
    }

    func latestUploadCall() -> SyncAPIStorageUploadCall? {
        storageUploadCalls.last
    }
}

@MainActor
final class SyncEngineControlFlowTests: XCTestCase {

    func testRunSyncLoopPullsTablesAndCleansOldSucceededEvents() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(
            dbQueue: manager.dbQueue,
            apiClient: api,
            pushTransportOverride: { _ in }
        )

        let staleSucceededId = UUID()
        try await manager.dbQueue.write { db in
            var stale = OutboxEvent(
                id: staleSucceededId,
                httpMethod: .POST,
                path: "api-settings-privacy",
                bodyJson: Data("{}".utf8)
            )
            stale.status = .succeeded
            stale.updatedAtLocal = Date().addingTimeInterval(-8 * 24 * 3600)
            stale.createdAtLocal = stale.updatedAtLocal
            try stale.insert(db)
        }

        try await engine.runSyncLoop()

        let fetchCalls = await api.fetchCallCount()
        XCTAssertGreaterThan(fetchCalls, 20, "runSyncLoop should fan out through pull phases")

        try await manager.dbQueue.read { db in
            let staleCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE id = ?",
                arguments: [staleSucceededId]
            ) ?? 0
            XCTAssertEqual(staleCount, 0)

            let syncStateCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_state") ?? 0
            XCTAssertGreaterThan(syncStateCount, 10)
        }
    }

    func testPullUsersTableMarksEmptyPullAsSuccessful() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)

        try await engine._testPullUsersTable()

        try await manager.dbQueue.read { db in
            let state = try SyncState.fetchOne(db, key: "users")
            XCTAssertNotNil(state?.lastPullAttemptAt)
            XCTAssertNotNil(state?.lastPullSuccessAt)
        }
    }

    func testPushPendingEventsReturnsEarlyWhenMutationsBlockedByForceUpdate() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        await api.setBlockMutations(true)
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)

        let pendingId = UUID()
        try await manager.dbQueue.write { db in
            var event = OutboxEvent(
                id: pendingId,
                httpMethod: .POST,
                path: "api-settings-privacy",
                bodyJson: Data("{}".utf8)
            )
            event.status = .pending
            try event.insert(db)
        }

        try await engine.pushPendingEvents()

        try await manager.dbQueue.read { db in
            let status = try String.fetchOne(
                db,
                sql: "SELECT status FROM outbox_events WHERE id = ? OR id = ?",
                arguments: [pendingId, pendingId.uuidString]
            )
            let attempts = try Int.fetchOne(
                db,
                sql: "SELECT attempt_count FROM outbox_events WHERE id = ? OR id = ?",
                arguments: [pendingId, pendingId.uuidString]
            ) ?? 0
            XCTAssertEqual(status, OutboxStatus.pending.rawValue)
            XCTAssertEqual(attempts, 0)
        }
    }

    func testEnqueueMutationSkipsUserHealthFlagsWhenCloudBackupDisabled() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)
        let authId = UUID()
        let userId = UUID()
        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [userId.uuidString, authId.uuidString, "UTC", "metric", Date(), Date()]
            )
            try db.execute(
                sql: """
                    INSERT INTO privacy_settings (
                        id, user_id, menstrual_local_only, medical_scan_local_only,
                        cloud_backup_enabled, vector_opt_in, analytics_consent, cloud_ocr_enabled,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    true,
                    true,
                    false,
                    false,
                    false,
                    true,
                    Date(),
                    Date(),
                ]
            )
        }

        let event = OutboxEvent(
            httpMethod: .POST,
            path: "rest/v1/user_health_flags",
            bodyJson: Data("{}".utf8)
        )
        try await engine.enqueueMutation(event)

        try await manager.dbQueue.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?",
                arguments: ["rest/v1/user_health_flags"]
            ) ?? 0
            XCTAssertEqual(count, 0)
        }
    }

    func testPushPendingEventsCancelsQueuedUserHealthFlagsWhenCloudBackupDisabled() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)
        let authId = UUID()
        let userId = UUID()
        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [userId.uuidString, authId.uuidString, "UTC", "metric", Date(), Date()]
            )
            try db.execute(
                sql: """
                    INSERT INTO privacy_settings (
                        id, user_id, menstrual_local_only, medical_scan_local_only,
                        cloud_backup_enabled, vector_opt_in, analytics_consent, cloud_ocr_enabled,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    true,
                    true,
                    false,
                    false,
                    false,
                    true,
                    Date(),
                    Date(),
                ]
            )

            var event = OutboxEvent(
                httpMethod: .POST,
                path: "rest/v1/user_health_flags",
                bodyJson: Data("{}".utf8)
            )
            event.status = .pending
            try event.insert(db)
        }

        try await engine.pushPendingEvents()

        let upsertCallCount = await api.upsertCallCount()
        let edgeCallCount = await api.edgeCallCount()
        XCTAssertEqual(upsertCallCount, 0)
        XCTAssertEqual(edgeCallCount, 0)

        try await manager.dbQueue.read { db in
            let status = try String.fetchOne(
                db,
                sql: "SELECT status FROM outbox_events WHERE path = ?",
                arguments: ["rest/v1/user_health_flags"]
            )
            XCTAssertEqual(status, OutboxStatus.cancelled.rawValue)
        }
    }

    func testPushPendingEventsRecoversStaleInFlightRows() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(
            dbQueue: manager.dbQueue,
            apiClient: api,
            pushTransportOverride: { _ in }
        )

        let staleInFlightId = UUID()
        try await manager.dbQueue.write { db in
            var event = OutboxEvent(
                id: staleInFlightId,
                httpMethod: .POST,
                path: "api-settings-privacy",
                bodyJson: Data("{}".utf8)
            )
            event.status = .inFlight
            event.updatedAtLocal = Date().addingTimeInterval(-11 * 60)
            event.lastAttemptAt = Date().addingTimeInterval(-11 * 60)
            try event.insert(db)
        }

        try await engine.pushPendingEvents()

        try await manager.dbQueue.read { db in
            let status = try String.fetchOne(
                db,
                sql: "SELECT status FROM outbox_events WHERE id = ? OR id = ?",
                arguments: [staleInFlightId, staleInFlightId.uuidString]
            )
            let nextAttempt = try Date.fetchOne(
                db,
                sql: "SELECT next_attempt_at FROM outbox_events WHERE id = ? OR id = ?",
                arguments: [staleInFlightId, staleInFlightId.uuidString]
            )
            XCTAssertEqual(status, OutboxStatus.succeeded.rawValue)
            XCTAssertNotNil(nextAttempt)
        }
    }

    func testPushPendingEventsUploadsLabScanAssetAndUpgradesLegacyMedicalScanOutbox() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)
        let authId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let userId = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let scanId = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let measurementId = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let uploadAuthId = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let assetURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lab-scan-\(scanId.uuidString.lowercased()).pdf")
        try Data("%PDF-1.7".utf8).write(to: assetURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: assetURL) }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }
        await api.setAuthenticatedUserId(uploadAuthId)

        try await manager.dbQueue.write { db in
            var user = User(id: userId, authId: authId)
            try user.insert(db)

            var settings = PrivacySettings(userId: userId)
            settings.medicalScanLocalOnly = false
            settings.cloudBackupEnabled = true
            try settings.insert(db)

            var scan = MedicalScan(id: scanId, userId: userId, scanType: .bloodTest)
            scan.status = .completed
            scan.scanDate = "2026-03-14"
            scan.storageMode = "cloud"
            scan.storeOriginalInCloud = true
            scan.originalImageUrl = assetURL.absoluteString

            var measurement = HealthMeasurement(
                id: measurementId,
                userId: userId,
                biomarkerName: "Ferritin",
                value: 58,
                unit: "ng/mL"
            )
            measurement.medicalScanId = scanId
            measurement.sourceScanId = scanId
            measurement.markerId = "ferritin"
            measurement.originalValue = 58
            measurement.originalUnit = "ng/mL"
            measurement.originalLabel = "Ferritin"
            measurement.referenceRangeLow = 30
            measurement.referenceRangeHigh = 400
            measurement.status = HealthMeasurementStatus.optimal.rawValue
            measurement.measuredDate = "2026-03-14"
            measurement.measuredAt = ISO8601DateFormatter.supabaseDate(from: "2026-03-14T09:00:00Z")
            measurement.confidence = 0.88
            measurement.manuallyVerified = true
            try measurement.insert(db)

            scan.processedData = try LabScanSyncPayloadBuilder.processedData(from: [measurement])
            try scan.insert(db)

            var event = OutboxEvent(
                httpMethod: .POST,
                path: "rest/v1/medical_scans",
                bodyJson: try JSONSerialization.data(
                    withJSONObject: [
                        "id": scanId.uuidString,
                        "scan_type": "bloodwork",
                    ]
                )
            )
            event.headersJson = try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
            try event.insert(db)
        }

        try await engine.pushPendingEvents()

        let uploadCallCount = await api.uploadCallCount()
        let edgeCallCount = await api.edgeCallCount()
        XCTAssertEqual(uploadCallCount, 1)
        XCTAssertEqual(edgeCallCount, 1)

        let latestUploadCall = await api.latestUploadCall()
        let uploadCall = try XCTUnwrap(latestUploadCall)
        XCTAssertEqual(uploadCall.bucket, LabScanCloudStorage.bucketName)
        XCTAssertEqual(uploadCall.contentType, "application/pdf")
        XCTAssertEqual(uploadCall.fileURL, assetURL)

        let expectedStoragePath = LabScanCloudStorage.objectPath(
            authId: uploadAuthId,
            scanId: scanId,
            fileExtension: "pdf"
        )
        XCTAssertEqual(uploadCall.path, expectedStoragePath)

        let latestEdgeCall = await api.latestEdgeCall()
        let edgeCall = try XCTUnwrap(latestEdgeCall)
        XCTAssertEqual(edgeCall.name, "api-labs")

        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: edgeCall.body) as? [String: Any]
        )
        XCTAssertEqual(payload["scan_id"] as? String, scanId.uuidString)
        XCTAssertEqual(payload["stored_asset_path"] as? String, expectedStoragePath)
        XCTAssertNil(payload["original_asset"])
        let processedData = try XCTUnwrap(payload["processed_data"] as? [String: Any])
        let markers = try XCTUnwrap(processedData["markers"] as? [[String: Any]])
        XCTAssertEqual(markers.first?["measurement_id"] as? String, measurementId.uuidString)

        try await manager.dbQueue.read { db in
            let persistedPath = try String.fetchOne(
                db,
                sql: "SELECT path FROM outbox_events ORDER BY created_at_local DESC LIMIT 1"
            )
            XCTAssertEqual(persistedPath, "api-labs")

            let persistedBody = try Data.fetchOne(
                db,
                sql: "SELECT body_json FROM outbox_events ORDER BY created_at_local DESC LIMIT 1"
            )
            let persistedPayload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try XCTUnwrap(persistedBody)) as? [String: Any]
            )
            XCTAssertEqual(persistedPayload["stored_asset_path"] as? String, expectedStoragePath)
        }
    }

    func testPushPendingEventsCancelsQueuedUserHealthFlagsWhenCloudBackupRevoked() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)
        let authId = UUID()
        let userId = UUID()
        let eventId = UUID()

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        try await manager.dbQueue.write { db in
            var user = User(id: userId, authId: authId)
            try user.insert(db)

            var settings = PrivacySettings(userId: userId)
            settings.cloudBackupEnabled = false
            try settings.insert(db)

            var event = OutboxEvent(
                id: eventId,
                httpMethod: .POST,
                path: "rest/v1/user_health_flags",
                bodyJson: try JSONSerialization.data(
                    withJSONObject: [
                        "id": UUID().uuidString,
                        "user_id": userId.uuidString,
                    ]
                )
            )
            event.headersJson = try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
            try event.insert(db)
        }

        try await engine.pushPendingEvents()

        let upsertCallCount = await api.upsertCallCount()
        let edgeCallCount = await api.edgeCallCount()
        XCTAssertEqual(upsertCallCount, 0)
        XCTAssertEqual(edgeCallCount, 0)

        try await manager.dbQueue.read { db in
            let status = try String.fetchOne(
                db,
                sql: "SELECT status FROM outbox_events WHERE id = ? OR id = ?",
                arguments: [eventId, eventId.uuidString]
            )
            XCTAssertEqual(status, OutboxStatus.cancelled.rawValue)
        }
    }

    func testPushPendingEventsStripsLabCloudBackupFieldsWhenCloudBackupDisabled() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)
        let authId = UUID()
        let userId = UUID()
        let scanId = UUID()
        let measurementId = UUID()
        let uploadAuthId = UUID()
        let assetURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lab-scan-no-backup-\(scanId.uuidString.lowercased()).pdf")
        try Data("%PDF-1.7".utf8).write(to: assetURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: assetURL) }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }
        await api.setAuthenticatedUserId(uploadAuthId)

        try await manager.dbQueue.write { db in
            var user = User(id: userId, authId: authId)
            try user.insert(db)

            var settings = PrivacySettings(userId: userId)
            settings.medicalScanLocalOnly = false
            settings.cloudBackupEnabled = false
            try settings.insert(db)

            var scan = MedicalScan(id: scanId, userId: userId, scanType: .bloodTest)
            scan.status = .completed
            scan.scanDate = "2026-03-14"
            scan.storageMode = "cloud"
            scan.storeOriginalInCloud = true
            scan.originalImageUrl = assetURL.absoluteString
            scan.scheduledDeletionAt = Date().addingTimeInterval(90 * 24 * 60 * 60)

            var measurement = HealthMeasurement(
                id: measurementId,
                userId: userId,
                biomarkerName: "Ferritin",
                value: 58,
                unit: "ng/mL"
            )
            measurement.medicalScanId = scanId
            measurement.sourceScanId = scanId
            measurement.markerId = "ferritin"
            measurement.originalValue = 58
            measurement.originalUnit = "ng/mL"
            measurement.originalLabel = "Ferritin"
            measurement.referenceRangeLow = 30
            measurement.referenceRangeHigh = 400
            measurement.status = HealthMeasurementStatus.optimal.rawValue
            measurement.measuredDate = "2026-03-14"
            measurement.measuredAt = ISO8601DateFormatter.supabaseDate(from: "2026-03-14T09:00:00Z")
            measurement.confidence = 0.88
            measurement.manuallyVerified = true
            try measurement.insert(db)

            scan.processedData = try LabScanSyncPayloadBuilder.processedData(from: [measurement])
            try scan.insert(db)

            var event = OutboxEvent(
                httpMethod: .POST,
                path: "rest/v1/medical_scans",
                bodyJson: try JSONSerialization.data(
                    withJSONObject: [
                        "id": scanId.uuidString,
                        "scan_type": "bloodwork",
                    ]
                )
            )
            event.headersJson = try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
            try event.insert(db)
        }

        try await engine.pushPendingEvents()

        let uploadCallCount = await api.uploadCallCount()
        let edgeCallCount = await api.edgeCallCount()
        XCTAssertEqual(uploadCallCount, 0)
        XCTAssertEqual(edgeCallCount, 1)

        let latestEdgeCall = await api.latestEdgeCall()
        let edgeCall = try XCTUnwrap(latestEdgeCall)
        XCTAssertEqual(edgeCall.name, "api-labs")
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: edgeCall.body) as? [String: Any]
        )
        XCTAssertEqual(payload["scan_id"] as? String, scanId.uuidString)
        XCTAssertEqual(payload["store_original_in_cloud"] as? Bool, false)
        XCTAssertTrue(payload["stored_asset_path"] is NSNull)
        XCTAssertTrue(payload["image_uploaded_at"] is NSNull)
        XCTAssertTrue(payload["scheduled_deletion_at"] is NSNull)
        XCTAssertNil(payload["original_asset"])
    }

    func testPushPendingEventsRoutesExperimentCreateThroughEdgeRoute() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)

        try await manager.dbQueue.write { db in
            var event = OutboxEvent(
                httpMethod: .POST,
                path: "api-experiments/create",
                bodyJson: try JSONSerialization.data(
                    withJSONObject: [
                        "id": UUID().uuidString,
                        "title": "Sleep consistency",
                        "primary_metric": "sleep_quality",
                    ]
                )
            )
            event.headersJson = try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
            try event.insert(db)
        }

        try await engine.pushPendingEvents()

        let latestEdgeCall = await api.latestEdgeCall()
        let edgeCall = try XCTUnwrap(latestEdgeCall)
        XCTAssertEqual(edgeCall.name, "api-experiments")
        XCTAssertEqual(edgeCall.route, "create")
        XCTAssertEqual(edgeCall.method, HTTPMethod.POST.rawValue)
        let edgeCallCount = await api.edgeCallCount()
        XCTAssertEqual(edgeCallCount, 1)
    }

    func testPushPendingEventsRollsBackOptimisticExperimentOnPermanentCreateFailure() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)
        let experimentId = UUID()
        let measurementId = UUID()
        let userId = UUID()

        await api.setEdgeErrors([
            StubbedAPIError(
                domain: "experiments",
                code: 409,
                status: 409,
                retryAfterSeconds: nil,
                message: "experiment_already_active"
            )
        ])

        try await manager.dbQueue.write { db in
            var user = User(id: userId, authId: UUID(), timezone: "UTC", units: .metric)
            try user.insert(db)

            var experiment = Experiment(
                id: experimentId,
                userId: userId,
                title: "Sleep consistency",
                variable: "bedtime",
                metric: "sleep_quality",
                durationDays: 21
            )
            experiment.status = .baseline
            try experiment.insert(db)

            var measurement = ExperimentMeasurement(
                id: measurementId,
                experimentId: experimentId,
                userId: userId,
                date: "2026-03-16",
                value: 80,
                unit: nil,
                measurementPhase: .baseline,
                metricName: "sleep_quality"
            )
            try measurement.insert(db)

            var createEvent = OutboxEvent(
                id: experimentId,
                httpMethod: .POST,
                path: "api-experiments/create",
                bodyJson: Data("{}".utf8)
            )
            createEvent.headersJson = try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
            try createEvent.insert(db)

            var logEvent = OutboxEvent(
                id: measurementId,
                httpMethod: .POST,
                path: "api-experiments/\(experimentId.uuidString)/log",
                bodyJson: Data("{}".utf8),
                priority: 101
            )
            logEvent.dependsOn = experimentId
            logEvent.headersJson = try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
            try logEvent.insert(db)
        }

        try await engine.pushPendingEvents()

        try await manager.dbQueue.read { db in
            let createStatus = try String.fetchOne(
                db,
                sql: "SELECT status FROM outbox_events WHERE id = ? OR id = ?",
                arguments: [experimentId, experimentId.uuidString]
            )
            let logStatus = try String.fetchOne(
                db,
                sql: "SELECT status FROM outbox_events WHERE id = ? OR id = ?",
                arguments: [measurementId, measurementId.uuidString]
            )
            let experimentCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM experiments WHERE id = ? OR id = ?",
                arguments: [experimentId, experimentId.uuidString]
            ) ?? 0
            let measurementCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM experiment_measurements WHERE experiment_id = ? OR experiment_id = ?",
                arguments: [experimentId, experimentId.uuidString]
            ) ?? 0

            XCTAssertEqual(createStatus, OutboxStatus.failedPermanent.rawValue)
            XCTAssertEqual(logStatus, OutboxStatus.cancelled.rawValue)
            // User-authored records are quarantined instead of destroyed:
            // the rows survive with a quarantine marker and stay hidden from
            // lists until bootstrap recovery replays the event.
            XCTAssertEqual(experimentCount, 1)
            XCTAssertEqual(measurementCount, 1)
            let quarantineReason = try String.fetchOne(
                db,
                sql: "SELECT sync_quarantine_reason FROM experiments WHERE id = ? OR id = ?",
                arguments: [experimentId, experimentId.uuidString]
            )
            XCTAssertEqual(quarantineReason, "permanent_create_failure:\(experimentId.uuidString)")
        }
    }

    func testPushPendingEventsRollsBackRemoteOnlyNotificationLogWhenServerDrops() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)
        let eventId = UUID()
        let userId = UUID()
        await api.setEdgeResponses([
            Data(#"{"status":"dropped","reason":"daily_cap"}"#.utf8),
        ])

        try await manager.dbQueue.write { db in
            let log = NotificationLog(
                id: eventId,
                userId: userId,
                category: .insight,
                priority: .active,
                title: "Insight",
                deliveredAt: Date()
            )
            try log.save(db)

            var event = OutboxEvent(
                id: eventId,
                httpMethod: .POST,
                path: "send-notification",
                bodyJson: try JSONSerialization.data(withJSONObject: [
                    "title": "Insight",
                    "body": "Body",
                    "category": NotificationCategory.insight.rawValue,
                    "priority": NotificationPriority.active.rawValue,
                    "delivery_mode": NotificationOutboxDeliveryMode.remoteOnly.rawValue,
                ])
            )
            event.headersJson = try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
            try event.insert(db)
        }

        try await engine.pushPendingEvents()

        try await manager.dbQueue.read { db in
            let logCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM notification_log WHERE id = ? OR id = ?",
                arguments: [eventId, eventId.uuidString]
            ) ?? 0
            let status = try String.fetchOne(
                db,
                sql: "SELECT status FROM outbox_events WHERE id = ? OR id = ?",
                arguments: [eventId, eventId.uuidString]
            )
            XCTAssertEqual(logCount, 0)
            XCTAssertEqual(status, OutboxStatus.succeeded.rawValue)
        }
    }

    func testPushPendingEventsBackfillsLegacyRemoteOnlyNotificationModeBeforeRollback() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)
        let eventId = UUID()
        let userId = UUID()
        await MainActor.run {
            AuthManager._testSetActiveHasCloudSession(true)
        }
        await api.setEdgeResponses([
            Data(#"{"status":"dropped","reason":"daily_cap"}"#.utf8),
        ])

        try await manager.dbQueue.write { db in
            let log = NotificationLog(
                id: eventId,
                userId: userId,
                category: .insight,
                priority: .active,
                title: "Insight",
                deliveredAt: Date()
            )
            try log.save(db)

            var event = OutboxEvent(
                id: eventId,
                httpMethod: .POST,
                path: "send-notification",
                bodyJson: try JSONSerialization.data(withJSONObject: [
                    "title": "Insight",
                    "body": "Body",
                    "category": NotificationCategory.insight.rawValue,
                    "priority": NotificationPriority.active.rawValue,
                ])
            )
            event.headersJson = try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
            try event.insert(db)
        }

        try await engine.pushPendingEvents()

        try await manager.dbQueue.read { db in
            let logCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM notification_log WHERE id = ? OR id = ?",
                arguments: [eventId, eventId.uuidString]
            ) ?? 0
            let persistedBody = try Data.fetchOne(
                db,
                sql: "SELECT body_json FROM outbox_events WHERE id = ? OR id = ?",
                arguments: [eventId, eventId.uuidString]
            )
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try XCTUnwrap(persistedBody)) as? [String: Any]
            )
            XCTAssertEqual(logCount, 0)
            XCTAssertEqual(payload["delivery_mode"] as? String, NotificationOutboxDeliveryMode.remoteOnly.rawValue)
        }

        await MainActor.run {
            AuthManager._testSetActiveHasCloudSession(false)
        }
    }

    func testPushPendingEventsRollsBackRemoteOnlyNotificationLogWhenAcceptedWithoutDelivery() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)
        let eventId = UUID()
        let userId = UUID()
        await api.setEdgeResponses([
            Data(#"{"status":"accepted","delivery_state":"no_devices","dispatch":{"configured":true,"attempted":0,"sent":0,"failed":0,"invalid_tokens":[],"delivery_state":"no_devices"}}"#.utf8),
        ])

        try await manager.dbQueue.write { db in
            let log = NotificationLog(
                id: eventId,
                userId: userId,
                category: .insight,
                priority: .active,
                title: "Insight",
                deliveredAt: Date()
            )
            try log.save(db)

            var event = OutboxEvent(
                id: eventId,
                httpMethod: .POST,
                path: "send-notification",
                bodyJson: try JSONSerialization.data(withJSONObject: [
                    "title": "Insight",
                    "body": "Body",
                    "category": NotificationCategory.insight.rawValue,
                    "priority": NotificationPriority.active.rawValue,
                    "delivery_mode": NotificationOutboxDeliveryMode.remoteOnly.rawValue,
                ])
            )
            event.headersJson = try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
            try event.insert(db)
        }

        try await engine.pushPendingEvents()

        try await manager.dbQueue.read { db in
            let logCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM notification_log WHERE id = ? OR id = ?",
                arguments: [eventId, eventId.uuidString]
            ) ?? 0
            let status = try String.fetchOne(
                db,
                sql: "SELECT status FROM outbox_events WHERE id = ? OR id = ?",
                arguments: [eventId, eventId.uuidString]
            )
            XCTAssertEqual(logCount, 0)
            XCTAssertEqual(status, OutboxStatus.succeeded.rawValue)
        }
    }

    func testPushPendingEventsRollsBackRemoteOnlyNotificationLogWhenDispatchFailsPermanently() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)
        let eventId = UUID()
        let userId = UUID()
        await api.setEdgeErrors([
            StubbedAPIError(
                domain: "SyncTests",
                code: 422,
                status: 422,
                retryAfterSeconds: nil,
                message: "validation failed"
            ),
        ])

        try await manager.dbQueue.write { db in
            let log = NotificationLog(
                id: eventId,
                userId: userId,
                category: .insight,
                priority: .active,
                title: "Insight",
                deliveredAt: Date()
            )
            try log.save(db)

            var event = OutboxEvent(
                id: eventId,
                httpMethod: .POST,
                path: "send-notification",
                bodyJson: try JSONSerialization.data(withJSONObject: [
                    "title": "Insight",
                    "body": "Body",
                    "category": NotificationCategory.insight.rawValue,
                    "priority": NotificationPriority.active.rawValue,
                    "delivery_mode": NotificationOutboxDeliveryMode.remoteOnly.rawValue,
                ])
            )
            event.headersJson = try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
            try event.insert(db)
        }

        try await engine.pushPendingEvents()

        try await manager.dbQueue.read { db in
            let logCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM notification_log WHERE id = ? OR id = ?",
                arguments: [eventId, eventId.uuidString]
            ) ?? 0
            let status = try String.fetchOne(
                db,
                sql: "SELECT status FROM outbox_events WHERE id = ? OR id = ?",
                arguments: [eventId, eventId.uuidString]
            )
            XCTAssertEqual(logCount, 0)
            XCTAssertEqual(status, OutboxStatus.failedPermanent.rawValue)
        }
    }

    func testPushPendingEventsKeepsLocalScheduledNotificationLogWhenServerDrops() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)
        let eventId = UUID()
        let userId = UUID()
        await api.setEdgeResponses([
            Data(#"{"status":"dropped","reason":"category_dedup"}"#.utf8),
        ])

        try await manager.dbQueue.write { db in
            let log = NotificationLog(
                id: eventId,
                userId: userId,
                category: .insight,
                priority: .active,
                title: "Insight",
                deliveredAt: Date()
            )
            try log.save(db)

            var event = OutboxEvent(
                id: eventId,
                httpMethod: .POST,
                path: "send-notification",
                bodyJson: try JSONSerialization.data(withJSONObject: [
                    "title": "Insight",
                    "body": "Body",
                    "category": NotificationCategory.insight.rawValue,
                    "priority": NotificationPriority.active.rawValue,
                    "delivery_mode": NotificationOutboxDeliveryMode.localScheduled.rawValue,
                ])
            )
            event.headersJson = try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
            try event.insert(db)
        }

        try await engine.pushPendingEvents()

        try await manager.dbQueue.read { db in
            let logCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM notification_log WHERE id = ? OR id = ?",
                arguments: [eventId, eventId.uuidString]
            ) ?? 0
            XCTAssertEqual(logCount, 1)
        }
    }

    func testRetryFailedPermanentAndHealthMetricsAndBlockerLookup() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)

        let blockedId = UUID()
        try await manager.dbQueue.write { db in
            var event = OutboxEvent(
                id: blockedId,
                httpMethod: .POST,
                path: "api-settings-privacy",
                bodyJson: Data("{}".utf8)
            )
            event.status = .failedPermanent
            event.userVisibleBlocker = true
            event.lastErrorCategory = .validation
            event.lastErrorMessage = "invalid payload"
            event.createdAtLocal = Date().addingTimeInterval(-8 * 24 * 3600)
            event.updatedAtLocal = Date()
            try event.insert(db)
        }

        let blocker = try await engine.userVisibleBlocker()
        XCTAssertEqual(blocker?.id, blockedId)
        XCTAssertEqual(blocker?.errorCategory, .validation)

        try await engine.retryFailedPermanentEvent(blockedId)
        let blockerAfterRetry = try await engine.userVisibleBlocker()
        XCTAssertNil(blockerAfterRetry)

        let metrics = try await engine.healthMetrics()
        XCTAssertEqual(metrics.pendingCount, 1)
        XCTAssertEqual(metrics.failedPermanentCount, 0)
        XCTAssertTrue(metrics.needsAttention)
        XCTAssertTrue(metrics.isBlocked)
    }

    func testRunSyncLoopEnqueuesSLOAnalyticsEventWhenSeverityNotNone() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(
            dbQueue: manager.dbQueue,
            apiClient: api,
            pushTransportOverride: { _ in }
        )

        try await manager.dbQueue.write { db in
            for _ in 0..<30 {
                var event = OutboxEvent(
                    httpMethod: .POST,
                    path: "api-settings-privacy",
                    bodyJson: Data("{}".utf8)
                )
                event.status = .failedPermanent
                event.userVisibleBlocker = true
                event.updatedAtLocal = Date()
                event.createdAtLocal = Date()
                try event.insert(db)
            }
        }

        try await engine.runSyncLoop()

        try await manager.dbQueue.read { db in
            let analyticsCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?",
                arguments: ["api-analytics-batch"]
            ) ?? 0
            XCTAssertGreaterThanOrEqual(analyticsCount, 1)
        }
    }

    func testPullUsersTableHandlesEmptyAndNonEmptyPages() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)

        let user: User = {
            var value = User(id: UUID(), authId: UUID(), timezone: "UTC", units: .metric)
            value.updatedAt = Date(timeIntervalSince1970: 1_700_000_100)
            return value
        }()

        await api.setUsersPages([[], [user]])

        try await engine._testPullUsersTable()
        let stateAfterEmpty = try await engine.syncState(for: .users)
        XCTAssertNotNil(stateAfterEmpty?.lastPullAttemptAt)
        XCTAssertNil(stateAfterEmpty?.lastPulledAtServer)

        try await engine._testPullUsersTable()
        let stateAfterRows = try await engine.syncState(for: .users)
        XCTAssertEqual(stateAfterRows?.lastPulledAtServer, user.updatedAt)
        XCTAssertNotNil(stateAfterRows?.lastPullSuccessAt)

        try await manager.dbQueue.read { db in
            let usersCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM users WHERE id = ? OR id = ?",
                arguments: [user.id, user.id.uuidString]
            ) ?? 0
            XCTAssertEqual(usersCount, 1)

            let mirrorCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sync_row_state WHERE table_name = ? AND row_id = ?",
                arguments: ["users", user.id.uuidString]
            ) ?? 0
            XCTAssertEqual(mirrorCount, 1)
        }
    }

    func testPullUsersTableBatchBoundaryContinuesWithCursor() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)

        let base = Date(timeIntervalSince1970: 1_700_100_000)
        let firstPage: [User] = (0..<1000).map { offset in
            var user = User(id: UUID(), authId: UUID(), timezone: "UTC", units: .metric)
            user.updatedAt = base.addingTimeInterval(Double(offset))
            return user
        }
        var lastUser = User(id: UUID(), authId: UUID(), timezone: "UTC", units: .metric)
        lastUser.updatedAt = base.addingTimeInterval(2_000)

        await api.setUsersPages([firstPage, [lastUser]])

        try await engine._testPullUsersTable()

        let fetchCalls = await api.fetchCallCount()
        XCTAssertEqual(fetchCalls, 2)

        let state = try await engine.syncState(for: .users)
        XCTAssertEqual(state?.lastPulledAtServer, lastUser.updatedAt)

        try await manager.dbQueue.read { db in
            let usersCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM users") ?? -1
            XCTAssertEqual(usersCount, 1001)

            let mirrorCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sync_row_state WHERE table_name = ?",
                arguments: ["users"]
            ) ?? -1
            XCTAssertEqual(mirrorCount, 1001)
        }
    }

    func testPushPendingEventsUsesBothTransportsAndSanitizesPayload() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)

        let restBody = try JSONSerialization.data(withJSONObject: [
            "safe": "ok",
            "location_lat": 40.1,
            "nested": [
                "gps_longitude": 49.9,
                "keep": "yes",
            ],
        ])
        let restHeaders = try JSONSerialization.data(withJSONObject: [
            "X-Correlation-Id": "existing-corr-id",
            "X-Custom": "value",
        ])

        try await manager.dbQueue.write { db in
            var restEvent = OutboxEvent(
                httpMethod: .POST,
                path: "rest/v1/users",
                headersJson: restHeaders,
                bodyJson: restBody
            )
            restEvent.priority = 1
            try restEvent.insert(db)

            var edgeEvent = OutboxEvent(
                httpMethod: .POST,
                path: "api-analytics-batch",
                bodyJson: Data("{\"events\":[]}".utf8)
            )
            edgeEvent.priority = 2
            try edgeEvent.insert(db)
        }

        try await engine.pushPendingEvents()

        let upsertCount = await api.upsertCallCount()
        let edgeCount = await api.edgeCallCount()
        XCTAssertEqual(upsertCount, 1)
        XCTAssertEqual(edgeCount, 1)

        let latestUpsertCall = await api.latestUpsertCall()
        let upsertCall = try XCTUnwrap(latestUpsertCall)
        XCTAssertEqual(upsertCall.table, "users")
        XCTAssertEqual(upsertCall.headers["X-Outbox-Replay"], "true")
        XCTAssertEqual(upsertCall.headers["X-Correlation-Id"], "existing-corr-id")
        XCTAssertNotNil(upsertCall.headers["Idempotency-Key"])
        XCTAssertNotNil(upsertCall.headers["X-Device-Id"])

        let sanitized = try XCTUnwrap(try JSONSerialization.jsonObject(with: upsertCall.bodyJson) as? [String: Any])
        XCTAssertNil(sanitized["location_lat"])
        let nested = try XCTUnwrap(sanitized["nested"] as? [String: Any])
        XCTAssertNil(nested["gps_longitude"])
        XCTAssertEqual(nested["keep"] as? String, "yes")

        try await manager.dbQueue.read { db in
            let succeeded = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE status = ?",
                arguments: [OutboxStatus.succeeded.rawValue]
            ) ?? 0
            XCTAssertEqual(succeeded, 2)
        }
    }

    func testPushPendingEventsClassifiesErrorsAndRateLimitBreaksReplay() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)

        await api.setEdgeErrors([
            StubbedAPIError(
                domain: "SyncTests",
                code: 401,
                status: 401,
                retryAfterSeconds: nil,
                message: "unauthorized"
            ),
        ])

        try await manager.dbQueue.write { db in
            var first = OutboxEvent(httpMethod: .POST, path: "api-first", bodyJson: Data("{}".utf8))
            first.priority = 1
            try first.insert(db)

            var second = OutboxEvent(httpMethod: .POST, path: "api-second", bodyJson: Data("{}".utf8))
            second.priority = 2
            try second.insert(db)
        }

        try await engine.pushPendingEvents()

        try await manager.dbQueue.read { db in
            let firstStatus = try String.fetchOne(
                db,
                sql: "SELECT status FROM outbox_events WHERE path = ?",
                arguments: ["api-first"]
            )
            let secondStatus = try String.fetchOne(
                db,
                sql: "SELECT status FROM outbox_events WHERE path = ?",
                arguments: ["api-second"]
            )
            XCTAssertEqual(firstStatus, OutboxStatus.failedPermanent.rawValue)
            XCTAssertEqual(secondStatus, OutboxStatus.pending.rawValue)
        }

        try await manager.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM outbox_events")
        }
        await api.setEdgeErrors([
            StubbedAPIError(
                domain: "SyncTests",
                code: 429,
                status: 429,
                retryAfterSeconds: 120,
                message: "too many requests"
            ),
        ])

        try await manager.dbQueue.write { db in
            var first = OutboxEvent(httpMethod: .POST, path: "api-rate-1", bodyJson: Data("{}".utf8))
            first.priority = 1
            try first.insert(db)

            var second = OutboxEvent(httpMethod: .POST, path: "api-rate-2", bodyJson: Data("{}".utf8))
            second.priority = 2
            try second.insert(db)
        }

        try await engine.pushPendingEvents()

        try await manager.dbQueue.read { db in
            let firstStatus = try String.fetchOne(
                db,
                sql: "SELECT status FROM outbox_events WHERE path = ?",
                arguments: ["api-rate-1"]
            )
            let secondStatus = try String.fetchOne(
                db,
                sql: "SELECT status FROM outbox_events WHERE path = ?",
                arguments: ["api-rate-2"]
            )
            let nextAttempt = try Date.fetchOne(
                db,
                sql: "SELECT next_attempt_at FROM outbox_events WHERE path = ?",
                arguments: ["api-rate-1"]
            )
            XCTAssertEqual(firstStatus, OutboxStatus.failedRetryable.rawValue)
            XCTAssertEqual(secondStatus, OutboxStatus.pending.rawValue)
            XCTAssertNotNil(nextAttempt)
        }
    }

    @MainActor
    func testSyncEngineDebugPrivacyAndMetaHelpers() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)

        let status401 = await engine._testClassifyHTTPStatus(401)
        let status429 = await engine._testClassifyHTTPStatus(429)
        let status422 = await engine._testClassifyHTTPStatus(422)
        let status503 = await engine._testClassifyHTTPStatus(503)
        let status200 = await engine._testClassifyHTTPStatus(200)
        XCTAssertEqual(status401, .auth)
        XCTAssertEqual(status429, .rateLimited)
        XCTAssertEqual(status422, .validation)
        XCTAssertEqual(status503, .server)
        XCTAssertEqual(status200, .unknown)

        let timedOutCategory = await engine._testClassifyError(
            NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue)
        )
        let serverCategory = await engine._testClassifyError(
            NSError(domain: "SyncTests", code: 500)
        )
        let rateLimitedCategory = await engine._testClassifyError(
            NSError(domain: "SyncTests", code: 0, userInfo: ["status": 429])
        )
        XCTAssertEqual(timedOutCategory, .network)
        XCTAssertEqual(serverCategory, .server)
        XCTAssertEqual(rateLimitedCategory, .rateLimited)

        XCTAssertEqual(SyncEngine._testDecodeHeaders(Data("not-json".utf8)), [:])
        let uuid = UUID()
        let uuidData = withUnsafeBytes(of: uuid.uuid) { Data($0) }
        XCTAssertEqual(SyncEngine._testDecodeUUID(from: uuidData), uuid)
        XCTAssertNil(SyncEngine._testDecodeUUID(from: Data([1, 2, 3])))

        let untouched = await engine._testSanitizeOutboundBody(Data("raw-text".utf8))
        XCTAssertEqual(untouched, Data("raw-text".utf8))

        let normalizedMedicalScanBody = await engine._testSanitizeOutboundBody(
            Data("""
                {
                  "scan_type": "bloodwork",
                  "raw_image": "s3://private-artifact"
                }
                """.utf8),
            path: "rest/v1/medical_scans"
        )
        let normalizedMedicalScanObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: normalizedMedicalScanBody) as? [String: Any]
        )
        XCTAssertEqual(normalizedMedicalScanObject["scan_type"] as? String, "blood_test")
        XCTAssertNil(normalizedMedicalScanObject["raw_image"])

        try await manager.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM local_meta")
            try db.execute(
                sql: "INSERT INTO local_meta (device_id, schema_version) VALUES (?, ?)",
                arguments: ["device-a", 1]
            )
        }
        SyncEngine._testEnsureLocalMetaDeviceId(dbQueue: manager.dbQueue, deviceId: "device-a")
        try await manager.dbQueue.read { db in
            let schemaVersion = try Int.fetchOne(
                db,
                sql: "SELECT schema_version FROM local_meta WHERE device_id = ?",
                arguments: ["device-a"]
            )
            XCTAssertEqual(schemaVersion, Migrations.latestSchemaVersion)
        }

        SyncEngine._testEnsureLocalMetaDeviceId(dbQueue: manager.dbQueue, deviceId: "device-b")
        try await manager.dbQueue.read { db in
            let rows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM local_meta WHERE device_id = ?", arguments: ["device-b"]) ?? 0
            XCTAssertEqual(rows, 1)
        }

        let authId = UUID()
        let userId = UUID()
        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    userId.uuidString,
                    authId.uuidString,
                    "UTC",
                    "metric",
                    Date(),
                    Date(),
                ]
            )

            try db.execute(
                sql: """
                    INSERT INTO privacy_settings (
                        id, user_id, menstrual_local_only, medical_scan_local_only, cloud_backup_enabled,
                        vector_opt_in, analytics_consent, cloud_ocr_enabled, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    false,
                    false,
                    true,
                    true,
                    false,
                    true,
                    Date(),
                    Date(),
                ]
            )
        }

        let initialShouldPullRestricted = try await engine._testShouldPullRestrictedMedicalData()
        let initialShouldPullVector = try await engine._testShouldPullVectorMemory()
        let initialShouldSyncHealthFlags = try await engine._testShouldSyncUserHealthFlags()
        let initialShouldSyncMenstrual = try await engine._testShouldSyncMenstrualData()
        XCTAssertTrue(initialShouldPullRestricted)
        XCTAssertTrue(initialShouldPullVector)
        XCTAssertTrue(initialShouldSyncHealthFlags)
        XCTAssertTrue(initialShouldSyncMenstrual)

        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE privacy_settings
                    SET
                        medical_scan_local_only = ?,
                        vector_opt_in = ?,
                        cloud_backup_enabled = ?,
                        menstrual_local_only = ?,
                        updated_at = ?
                    WHERE user_id = ?
                    """,
                arguments: [
                    true,
                    false,
                    false,
                    true,
                    Date().addingTimeInterval(1),
                    userId.uuidString,
                ]
            )
        }

        let updatedShouldPullRestricted = try await engine._testShouldPullRestrictedMedicalData()
        let updatedShouldPullVector = try await engine._testShouldPullVectorMemory()
        let updatedShouldSyncHealthFlags = try await engine._testShouldSyncUserHealthFlags()
        let updatedShouldSyncMenstrual = try await engine._testShouldSyncMenstrualData()
        XCTAssertFalse(updatedShouldPullRestricted)
        XCTAssertFalse(updatedShouldPullVector)
        XCTAssertFalse(updatedShouldSyncHealthFlags)
        XCTAssertFalse(updatedShouldSyncMenstrual)

        try await engine._testUpdatePullAttempt(table: "users")
        let stateAfterPullAttempt = try await engine.syncState(for: .users)
        XCTAssertNotNil(stateAfterPullAttempt)
        try await engine.updateSyncWatermark(table: "users", serverTimestamp: Date(timeIntervalSince1970: 1_700_000_500))
        let stateAfterWatermark = try await engine.syncState(for: .users)
        XCTAssertNotNil(stateAfterWatermark?.lastPullSuccessAt)
    }

    func testSyncEngineSLOHelpersAndTelemetryThrottle() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api, pushTransportOverride: { _ in })

        let warningSnapshot = OutboxSLOSnapshot(
            totalEvents: 100,
            pendingEvents: 0,
            inFlightEvents: 0,
            succeededEvents: 94,
            retryableFailures: 6,
            permanentFailures: 0,
            windowHours: 24,
            evaluatedAt: Date()
        )
        XCTAssertEqual(SyncEngine._testOutboxSLOSeverity(for: warningSnapshot), .warning)

        try await manager.dbQueue.write { db in
            for _ in 0..<30 {
                var event = OutboxEvent(
                    httpMethod: .POST,
                    path: "api-settings-privacy",
                    bodyJson: Data("{}".utf8)
                )
                event.status = .failedPermanent
                event.updatedAtLocal = Date()
                event.createdAtLocal = Date()
                try event.insert(db)
            }
        }

        try await engine._testEvaluateAndEmitOutboxSLOAlert()
        try await engine._testEvaluateAndEmitOutboxSLOAlert()

        try await manager.dbQueue.read { db in
            let analyticsEvents = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?",
                arguments: ["api-analytics-batch"]
            ) ?? 0
            XCTAssertEqual(analyticsEvents, 1)
        }
    }

    func testSyncEligibilityDefaultsAndWatermarkInsertPath() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)

        let authId = UUID()
        let userId = UUID()
        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
        }

        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [userId.uuidString, authId.uuidString, "UTC", "metric", Date(), Date()]
            )
        }

        let shouldPullRestricted = try await engine._testShouldPullRestrictedMedicalData()
        let shouldPullVector = try await engine._testShouldPullVectorMemory()
        let shouldSyncHealthFlags = try await engine._testShouldSyncUserHealthFlags()
        let shouldSyncMenstrual = try await engine._testShouldSyncMenstrualData()
        XCTAssertFalse(shouldPullRestricted)
        XCTAssertFalse(shouldPullVector)
        XCTAssertFalse(shouldSyncHealthFlags)
        XCTAssertFalse(shouldSyncMenstrual)

        let timestamp = Date(timeIntervalSince1970: 1_700_555_000)
        try await engine.updateSyncWatermark(table: "food_logs", serverTimestamp: timestamp)
        let syncState = try await manager.dbQueue.read { db in
            try SyncState.fetchOne(db, key: "food_logs")
        }
        XCTAssertEqual(syncState?.lastPulledAtServer, timestamp)
        XCTAssertNotNil(syncState?.lastPullSuccessAt)
        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(nil)
        }
    }

    func testUserVisibleBlockerUUIDDecodingFallbacks() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)

        let blockerWhenEmpty = try await engine.userVisibleBlocker()
        XCTAssertNil(blockerWhenEmpty)

        try await manager.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM outbox_events")
            let validId = UUID()
            let idBytes = withUnsafeBytes(of: validId.uuid) { Data($0) }
            try db.execute(
                sql: """
                    INSERT INTO outbox_events (
                        id, created_at_local, updated_at_local, status, priority, http_method, path,
                        headers_json, body_json, idempotency_key, attempt_count, user_visible_blocker
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    idBytes,
                    Date(),
                    Date(),
                    OutboxStatus.failedPermanent.rawValue,
                    1,
                    "POST",
                    "api-good-id",
                    Data(),
                    Data("{}".utf8),
                    UUID().uuidString,
                    1,
                    true,
                ]
            )
        }

        let blockerAfterBinaryId = try await engine.userVisibleBlocker()
        XCTAssertNotNil(blockerAfterBinaryId)
    }

    func testSyncEngineDebugSendToServerAndPullSyncableTableSwitches() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)

        let restEvent = OutboxEvent(
            httpMethod: .POST,
            path: "rest/v1/users",
            bodyJson: Data("{\"id\":\"\(UUID().uuidString)\"}".utf8)
        )
        try await engine._testSendToServer(restEvent)
        let upsertCalls = await api.upsertCallCount()
        XCTAssertEqual(upsertCalls, 1)

        let edgeEvent = OutboxEvent(
            httpMethod: .POST,
            path: "api-settings-privacy",
            bodyJson: Data("{}".utf8)
        )
        try await engine._testSendToServer(edgeEvent)
        let edgeCalls = await api.edgeCallCount()
        XCTAssertEqual(edgeCalls, 1)

        let pullSwitchCoverageTables: [SyncableTable] = [
            .foodLogs,
            .foodItems,
            .userFoods,
            .userFoodFavorites,
            .mealTemplates,
            .batchRecipes,
            .batchRecipeIngredients,
            .workoutSessions,
            .workoutExercises,
            .workoutSets,
            .trainingPlans,
            .trainingPlanSessions,
            .userSupplements,
            .supplementLogs,
            .sleepLogs,
            .menstrualLogs,
            .medicalScans,
            .healthMeasurements,
            .healthDiagnoses,
            .trainingLoads,
            .dailyNutritionTargets,
            .foodCatalogItems,
            .supplementCatalog,
            .exerciseCatalog,
            .healthMarkerCatalog,
            .users,
        ]
        for table in pullSwitchCoverageTables {
            try await engine._testPullSyncableTable(table)
        }
    }

    func testUserVisibleBlockerUUIDDecodingFromString() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)

        let validId = UUID()
        try await manager.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM outbox_events")
            try db.execute(
                sql: """
                    INSERT INTO outbox_events (
                        id, created_at_local, updated_at_local, status, priority, http_method, path,
                        headers_json, body_json, idempotency_key, attempt_count, user_visible_blocker
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    validId.uuidString,
                    Date(),
                    Date(),
                    OutboxStatus.failedPermanent.rawValue,
                    1,
                    "POST",
                    "api-string-id",
                    Data(),
                    Data("{}".utf8),
                    UUID().uuidString,
                    1,
                    true,
                ]
            )
        }
        let blockerFromString = try await engine.userVisibleBlocker()
        XCTAssertEqual(blockerFromString?.id, validId)
    }

    func testDecodeUUIDFromRowVariantsHelper() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)

        let decoded = try await engine._testDecodeUUIDFromRowVariants()
        XCTAssertNotNil(decoded.uuid)
        XCTAssertNotNil(decoded.string)
        XCTAssertNotNil(decoded.data)
        XCTAssertNil(decoded.nilValue)
    }

    func testPullAllCoversOptInTaskBranchesAndMissingUserEligibilityFallbacks() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)

        let authId = UUID()
        let userId = UUID()
        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
        }

        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [userId.uuidString, authId.uuidString, "UTC", "metric", Date(), Date()]
            )
            try db.execute(
                sql: """
                    INSERT INTO privacy_settings (
                        id, user_id, menstrual_local_only, medical_scan_local_only,
                        cloud_backup_enabled, vector_opt_in, analytics_consent, cloud_ocr_enabled,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    false,
                    false,
                    true,
                    true,
                    false,
                    true,
                    Date(),
                    Date(),
                ]
            )
        }

        try await engine.pullAll()
        let fetchCount = await api.fetchCallCount()
        XCTAssertGreaterThan(fetchCount, 20)

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(UUID())
        }
        let shouldPullRestricted = try await engine._testShouldPullRestrictedMedicalData()
        let shouldPullVector = try await engine._testShouldPullVectorMemory()
        let shouldSyncFlags = try await engine._testShouldSyncUserHealthFlags()
        let shouldSyncMenstrual = try await engine._testShouldSyncMenstrualData()
        XCTAssertFalse(shouldPullRestricted)
        XCTAssertFalse(shouldPullVector)
        XCTAssertFalse(shouldSyncFlags)
        XCTAssertFalse(shouldSyncMenstrual)

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(nil)
        }
    }

    func testPushPendingEventsSkipsUnmetDependencyAndBackfillsIdempotencyKey() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)

        let missingDependency = UUID()
        let dependentEventId = UUID()
        try await manager.dbQueue.write { db in
            var dependent = OutboxEvent(
                id: dependentEventId,
                httpMethod: .POST,
                path: "api-dependent",
                bodyJson: Data("{}".utf8)
            )
            dependent.dependsOn = missingDependency
            dependent.priority = 99
            try dependent.insert(db)
        }

        var emptyIdempotencyEvent = OutboxEvent(
            httpMethod: .POST,
            path: "api-idempotency-backfill",
            bodyJson: Data("{}".utf8)
        )
        emptyIdempotencyEvent.idempotencyKey = ""
        let expectedIdempotencyKey = emptyIdempotencyEvent.id.uuidString
        try await engine.enqueueMutation(emptyIdempotencyEvent)

        try await engine.pushPendingEvents()

        try await manager.dbQueue.read { db in
            let dependentStatus = try String.fetchOne(
                db,
                sql: "SELECT status FROM outbox_events WHERE id = ? OR id = ?",
                arguments: [dependentEventId, dependentEventId.uuidString]
            )
            XCTAssertEqual(dependentStatus, OutboxStatus.pending.rawValue)

            let storedIdempotency = try String.fetchOne(
                db,
                sql: "SELECT idempotency_key FROM outbox_events WHERE path = ? LIMIT 1",
                arguments: ["api-idempotency-backfill"]
            )
            XCTAssertEqual(storedIdempotency, expectedIdempotencyKey)
        }
    }

    func testUserVisibleBlockerReturnsNilWhenIdCannotDecode() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)

        try await manager.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM outbox_events")
            try db.execute(
                sql: """
                    INSERT INTO outbox_events (
                        id, created_at_local, updated_at_local, status, priority, http_method, path,
                        headers_json, body_json, idempotency_key, attempt_count, user_visible_blocker
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "not-a-uuid",
                    Date(),
                    Date(),
                    OutboxStatus.failedPermanent.rawValue,
                    1,
                    "POST",
                    "api-invalid-id",
                    Data(),
                    Data("{}".utf8),
                    UUID().uuidString,
                    1,
                    true,
                ]
            )
        }

        let blocker = try await engine.userVisibleBlocker()
        XCTAssertNil(blocker)
    }

    func testEvaluateOutboxSLOCoversAnalyticsEnqueueFailureCatch() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)

        try await manager.dbQueue.write { db in
            for _ in 0..<25 {
                var event = OutboxEvent(
                    httpMethod: .POST,
                    path: "api-slo-failure",
                    bodyJson: Data("{}".utf8)
                )
                event.status = .failedPermanent
                event.updatedAtLocal = Date()
                event.createdAtLocal = Date()
                try event.insert(db)
            }
        }

        SyncEngine._testSetEnqueueOutboxSLOAnalyticsOverride { _, _ in
            throw NSError(domain: "SLOTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "enqueue failed"])
        }
        defer {
            SyncEngine._testSetEnqueueOutboxSLOAnalyticsOverride(nil)
        }

        try await engine._testEvaluateAndEmitOutboxSLOAlert()

        try await manager.dbQueue.read { db in
            let analyticsEvents = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?",
                arguments: ["api-analytics-batch"]
            ) ?? 0
            XCTAssertEqual(analyticsEvents, 0)
        }
    }

    func testEnsureLocalMetaDeviceIdFailureHandlerRunsWhenTableMissing() async throws {
        final class FailureRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var didRecord = false

            func mark() {
                lock.lock()
                didRecord = true
                lock.unlock()
            }

            func value() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return didRecord
            }
        }

        let manager = try DatabaseManager.inMemory()
        let recorder = FailureRecorder()
        try await manager.dbQueue.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS local_meta")
        }

        SyncEngine._testSetEnsureLocalMetaFailureHandler { _ in
            recorder.mark()
        }
        defer {
            SyncEngine._testSetEnsureLocalMetaFailureHandler(nil)
        }

        SyncEngine._testEnsureLocalMetaDeviceId(dbQueue: manager.dbQueue, deviceId: "broken-device")
        XCTAssertTrue(recorder.value())
    }

    func testEnsureLocalMetaDeviceIdFailureWithoutHandlerIsIgnoredDuringTests() async throws {
        let manager = try DatabaseManager.inMemory()
        try await manager.dbQueue.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS local_meta")
        }

        SyncEngine._testSetEnsureLocalMetaFailureHandler(nil)
        SyncEngine._testEnsureLocalMetaDeviceId(dbQueue: manager.dbQueue, deviceId: "broken-device-no-handler")
    }

    func testPushPendingEventsRateLimitWithoutRetryAfterUsesDefaultDelay() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)

        await api.setEdgeErrors([
            StubbedAPIError(
                domain: "SyncTests",
                code: 429,
                status: 429,
                retryAfterSeconds: nil,
                message: "too many requests no retry-after"
            ),
        ])

        try await manager.dbQueue.write { db in
            var event = OutboxEvent(httpMethod: .POST, path: "api-rate-default-delay", bodyJson: Data("{}".utf8))
            event.priority = 1
            try event.insert(db)
        }

        let before = Date()
        try await engine.pushPendingEvents()

        try await manager.dbQueue.read { db in
            let status = try String.fetchOne(
                db,
                sql: "SELECT status FROM outbox_events WHERE path = ?",
                arguments: ["api-rate-default-delay"]
            )
            let nextAttempt = try Date.fetchOne(
                db,
                sql: "SELECT next_attempt_at FROM outbox_events WHERE path = ?",
                arguments: ["api-rate-default-delay"]
            )
            XCTAssertEqual(status, OutboxStatus.failedRetryable.rawValue)
            let resolvedNextAttempt = try XCTUnwrap(nextAttempt)
            let delta = resolvedNextAttempt.timeIntervalSince(before)
            XCTAssertGreaterThan(delta, 45)
            XCTAssertLessThan(delta, 90)
        }
    }

    func testSanitizeOutboundBodyArrayAndSerializationFallbackBranches() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)

        let arrayPayload = Data(
            """
            {
              "items": [
                {"location_lat": 40.1, "keep": "ok"},
                {"raw_image": "x", "safe": 2}
              ]
            }
            """.utf8
        )
        let sanitizedArrayPayload = await engine._testSanitizeOutboundBody(arrayPayload)
        let sanitizedObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: sanitizedArrayPayload) as? [String: Any]
        )
        let items = try XCTUnwrap(sanitizedObject["items"] as? [[String: Any]])
        XCTAssertNil(items.first?["location_lat"])
        XCTAssertEqual(items.first?["keep"] as? String, "ok")
        XCTAssertNil(items.last?["raw_image"])
        XCTAssertEqual(items.last?["safe"] as? Int, 2)

        let topLevelScalar = Data("1".utf8)
        let fallback = await engine._testSanitizeOutboundBody(topLevelScalar)
        XCTAssertEqual(fallback, topLevelScalar)
    }

    func testMarkFailedWithoutExistingRowUsesZeroAttemptFallback() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)

        try await engine.markFailed(
            UUID(),
            category: .network,
            code: "500",
            message: "missing row",
            retryable: true
        )

        try await manager.dbQueue.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox_events") ?? -1
            XCTAssertEqual(total, 0)
        }
    }

    func testSyncHealthMetricsNeedsAttentionAndBlockedFallbackBranches() {
        let failedPermanentNeedsAttention = SyncHealthMetrics(
            pendingCount: 0,
            failedPermanentCount: 1,
            oldestPendingAgeHours: nil
        )
        XCTAssertTrue(failedPermanentNeedsAttention.needsAttention)

        let idleMetrics = SyncHealthMetrics(
            pendingCount: 0,
            failedPermanentCount: 0,
            oldestPendingAgeHours: nil
        )
        XCTAssertFalse(idleMetrics.needsAttention)
        XCTAssertFalse(idleMetrics.isBlocked)
    }
}
