import XCTest
@testable import LifeOS
import GRDB

final class SyncEngineLoadTests: XCTestCase {

    func testPushPendingEventsHandlesLargeOutboxVolume() async throws {
        let manager = try DatabaseManager.inMemory()
        let tracker = PushTransportTracker(failFirstAttempts: 0)
        let syncEngine = SyncEngine(
            dbQueue: manager.dbQueue,
            pushTransportOverride: { event in
                try await tracker.handle(event)
            }
        )

        let totalEvents = 500
        try await enqueueEvents(syncEngine: syncEngine, total: totalEvents)

        try await syncEngine.pushPendingEvents()

        let succeeded = try await manager.dbQueue.read { db in
            try OutboxEvent
                .filter(Column("status") == OutboxStatus.succeeded.rawValue)
                .fetchCount(db)
        }

        XCTAssertEqual(succeeded, totalEvents)
        let pendingCount = try await syncEngine.pendingEventCount()
        XCTAssertEqual(pendingCount, 0)
    }

    func testPushPendingEventsRetriesAndPreservesIdempotencyAcrossRounds() async throws {
        let manager = try DatabaseManager.inMemory()
        let tracker = PushTransportTracker(failFirstAttempts: 2)
        let syncEngine = SyncEngine(
            dbQueue: manager.dbQueue,
            pushTransportOverride: { event in
                try await tracker.handle(event)
            }
        )

        let totalEvents = 120
        let eventIds = try await enqueueEvents(syncEngine: syncEngine, total: totalEvents)

        for round in 0..<3 {
            try await syncEngine.pushPendingEvents()

            if round < 2 {
                try await manager.dbQueue.write { db in
                    try db.execute(
                        sql: """
                            UPDATE outbox_events
                            SET next_attempt_at = ?
                            WHERE status = ?
                            """,
                        arguments: [Date().addingTimeInterval(-1), OutboxStatus.failedRetryable.rawValue]
                    )
                }
            }
        }

        let succeededCount = try await manager.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE status = ?",
                arguments: [OutboxStatus.succeeded.rawValue]
            ) ?? 0
        }
        XCTAssertEqual(succeededCount, totalEvents)

        for eventId in eventIds {
            let attempts = await tracker.attemptCount(for: eventId)
            XCTAssertEqual(attempts, 3, "Expected 2 retries + 1 success per event")

            let observedIdempotencyKeys = await tracker.observedIdempotencyKeys(for: eventId)
            XCTAssertEqual(observedIdempotencyKeys.count, 1, "Idempotency key must stay stable across retries")
            XCTAssertEqual(observedIdempotencyKeys.sorted().first, eventId.uuidString)
        }
    }

    func testConcurrentEnqueueMaintainsIdempotencyKeyUniqueness() async throws {
        let manager = try DatabaseManager.inMemory()
        let syncEngine = SyncEngine(
            dbQueue: manager.dbQueue,
            pushTransportOverride: { _ in }
        )

        let totalEvents = 800
        _ = try await enqueueEvents(syncEngine: syncEngine, total: totalEvents)

        let counts: (total: Int, distinct: Int) = try await manager.dbQueue.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox_events") ?? 0
            let distinct = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(DISTINCT idempotency_key) FROM outbox_events"
            ) ?? 0
            return (total: total, distinct: distinct)
        }

        XCTAssertEqual(counts.total, totalEvents)
        XCTAssertEqual(counts.distinct, totalEvents)
    }

    func testOutboxSLOSnapshotNoAlertWhenWithinBudget() async throws {
        let manager = try DatabaseManager.inMemory()
        let syncEngine = SyncEngine(
            dbQueue: manager.dbQueue,
            pushTransportOverride: { _ in }
        )

        try await seedOutboxStatuses(
            manager: manager,
            statuses: Array(repeating: .succeeded, count: 31) +
                Array(repeating: .pending, count: 8) +
                Array(repeating: .failedRetryable, count: 1)
        )

        let evaluation = try await syncEngine.evaluateOutboxSLO(windowHours: 24)
        XCTAssertEqual(evaluation.snapshot.totalEvents, 40)
        XCTAssertEqual(evaluation.snapshot.retryableFailures, 1)
        XCTAssertEqual(evaluation.snapshot.permanentFailures, 0)
        XCTAssertLessThan(evaluation.snapshot.failureRate, 0.05)
        XCTAssertEqual(evaluation.severity, .none)
    }

    func testOutboxSLOSnapshotCriticalAlertForDeadLetterRate() async throws {
        let manager = try DatabaseManager.inMemory()
        let syncEngine = SyncEngine(
            dbQueue: manager.dbQueue,
            pushTransportOverride: { _ in }
        )

        try await seedOutboxStatuses(
            manager: manager,
            statuses: Array(repeating: .succeeded, count: 20) +
                Array(repeating: .failedRetryable, count: 6) +
                Array(repeating: .failedPermanent, count: 4)
        )

        let evaluation = try await syncEngine.evaluateOutboxSLO(windowHours: 24)
        XCTAssertEqual(evaluation.snapshot.totalEvents, 30)
        XCTAssertEqual(evaluation.snapshot.permanentFailures, 4)
        XCTAssertGreaterThan(evaluation.snapshot.deadLetterRate, 0.03)
        XCTAssertEqual(evaluation.severity, .critical)
    }

    @discardableResult
    private func enqueueEvents(syncEngine: SyncEngine, total: Int) async throws -> [UUID] {
        var eventIds = [UUID]()
        eventIds.reserveCapacity(total)

        for _ in 0..<total {
            eventIds.append(UUID())
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for eventId in eventIds {
                group.addTask {
                    let payload = try JSONSerialization.data(withJSONObject: [
                        "id": eventId.uuidString,
                        "updated_at": ISO8601DateFormatter.supabaseString(from: Date())
                    ])
                    let event = OutboxEvent(
                        id: eventId,
                        httpMethod: .POST,
                        path: "api-settings-privacy",
                        bodyJson: payload,
                        priority: Int.random(in: 1...100)
                    )
                    try await syncEngine.enqueueMutation(event)
                }
            }
            try await group.waitForAll()
        }

        return eventIds
    }

    private func seedOutboxStatuses(
        manager: DatabaseManager,
        statuses: [OutboxStatus]
    ) async throws {
        try await manager.dbQueue.write { db in
            for (index, status) in statuses.enumerated() {
                let payload = try JSONSerialization.data(withJSONObject: [
                    "id": UUID().uuidString,
                    "updated_at": ISO8601DateFormatter.supabaseString(from: Date())
                ])
                var event = OutboxEvent(
                    id: UUID(),
                    httpMethod: .POST,
                    path: "api-settings-privacy",
                    bodyJson: payload,
                    priority: 100 + index
                )
                event.status = status
                event.updatedAtLocal = Date()
                event.attemptCount = status == .failedRetryable || status == .failedPermanent ? 1 : 0
                if status == .failedPermanent {
                    event.userVisibleBlocker = true
                    event.lastErrorCategory = .validation
                    event.lastErrorMessage = "Seeded dead-letter event"
                }
                try event.insert(db)
            }
        }
    }
}

actor PushTransportTracker {
    private let failFirstAttempts: Int
    private var attemptsById: [UUID: Int] = [:]
    private var idempotencyKeysById: [UUID: Set<String>] = [:]

    init(failFirstAttempts: Int) {
        self.failFirstAttempts = max(0, failFirstAttempts)
    }

    func handle(_ event: OutboxEvent) throws {
        let nextAttempt = (attemptsById[event.id] ?? 0) + 1
        attemptsById[event.id] = nextAttempt

        var keys = idempotencyKeysById[event.id] ?? Set<String>()
        keys.insert(event.idempotencyKey)
        idempotencyKeysById[event.id] = keys

        if nextAttempt <= failFirstAttempts {
            throw NSError(
                domain: "SyncEngineLoadTests",
                code: 500,
                userInfo: [
                    "status": 500,
                    NSLocalizedDescriptionKey: "Simulated retryable failure"
                ]
            )
        }
    }

    func attemptCount(for eventId: UUID) -> Int {
        attemptsById[eventId] ?? 0
    }

    func observedIdempotencyKeys(for eventId: UUID) -> Set<String> {
        idempotencyKeysById[eventId] ?? []
    }
}

final class SyncEnginePerfBenchTests: XCTestCase {
    private enum BenchConfig {
        static let pushEvents = 1_500
        static let pullRows = 4_000
        static let hardCapMs = 30_000.0
        static let warmVsColdMultiplierCap = 2.5
    }

    func testSyncPushBenchColdAndWarmDB() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-push-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("push-bench.sqlite")
        let manager = try makeOnDiskManager(path: dbURL.path)
        let tracker = PushTransportTracker(failFirstAttempts: 0)
        let syncEngine = SyncEngine(
            dbQueue: manager.dbQueue,
            pushTransportOverride: { event in
                try await tracker.handle(event)
            }
        )

        try await enqueueEvents(syncEngine: syncEngine, total: BenchConfig.pushEvents, seed: 1)
        let coldPushMs = try await measureAsync {
            try await syncEngine.pushPendingEvents()
        }

        try await enqueueEvents(syncEngine: syncEngine, total: BenchConfig.pushEvents, seed: 100_000)
        let warmPushMs = try await measureAsync {
            try await syncEngine.pushPendingEvents()
        }

        XCTAssertLessThan(coldPushMs, BenchConfig.hardCapMs, "Cold push bench exceeded cap: \(coldPushMs)ms")
        XCTAssertLessThan(warmPushMs, BenchConfig.hardCapMs, "Warm push bench exceeded cap: \(warmPushMs)ms")
        XCTAssertLessThan(
            warmPushMs,
            coldPushMs * BenchConfig.warmVsColdMultiplierCap,
            "Warm push should not regress significantly vs cold."
        )
    }

    func testSyncPullApplyBenchColdAndWarmDB() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-pull-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("pull-bench.sqlite")
        let manager = try makeOnDiskManager(path: dbURL.path)
        let userId = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

        try manager.dbQueue.write { db in
            let user = User(id: userId, authId: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!)
            try user.insert(db)
        }

        let coldPullMs = try measure {
            try applyPulledFoodLogs(
                manager: manager,
                userId: userId,
                rows: BenchConfig.pullRows,
                seed: 1
            )
        }

        let warmPullMs = try measure {
            try applyPulledFoodLogs(
                manager: manager,
                userId: userId,
                rows: BenchConfig.pullRows,
                seed: 1
            )
        }

        XCTAssertLessThan(coldPullMs, BenchConfig.hardCapMs, "Cold pull bench exceeded cap: \(coldPullMs)ms")
        XCTAssertLessThan(warmPullMs, BenchConfig.hardCapMs, "Warm pull bench exceeded cap: \(warmPullMs)ms")
        XCTAssertLessThan(
            warmPullMs,
            coldPullMs * BenchConfig.warmVsColdMultiplierCap,
            "Warm pull should not regress significantly vs cold."
        )
    }

    private func makeOnDiskManager(path: String) throws -> DatabaseManager {
        let queue = try DatabaseQueue(path: path)
        let manager = DatabaseManager(dbQueue: queue)
        try manager.runMigrations()
        return manager
    }

    private func measureAsync(_ operation: () async throws -> Void) async throws -> Double {
        let start = Date()
        try await operation()
        return Date().timeIntervalSince(start) * 1000
    }

    private func measure(_ operation: () throws -> Void) throws -> Double {
        let start = Date()
        try operation()
        return Date().timeIntervalSince(start) * 1000
    }

    private func enqueueEvents(syncEngine: SyncEngine, total: Int, seed: Int) async throws {
        for offset in 0..<total {
            let eventId = stableUUID(seed + offset)
            let payload = try JSONSerialization.data(withJSONObject: [
                "id": eventId.uuidString,
                "updated_at": ISO8601DateFormatter.supabaseString(from: Date())
            ])
            let event = OutboxEvent(
                id: eventId,
                httpMethod: .POST,
                path: "api-settings-privacy",
                bodyJson: payload,
                priority: 100
            )
            try await syncEngine.enqueueMutation(event)
        }
    }

    private func applyPulledFoodLogs(
        manager: DatabaseManager,
        userId: UUID,
        rows: Int,
        seed: Int
    ) throws {
        let baseDate = Date(timeIntervalSince1970: 1_772_000_000)

        try manager.dbQueue.write { db in
            var maxUpdatedAt: Date?

            for offset in 0..<rows {
                let rowId = stableUUID(seed + offset)
                let eventDate = baseDate.addingTimeInterval(Double(offset))
                var log = FoodLog(
                    id: rowId,
                    userId: userId,
                    loggedAt: eventDate,
                    loggedDate: "2026-02-20",
                    inputMethod: .manual,
                    calories: 520,
                    proteinG: 36,
                    fatG: 18,
                    carbsG: 48
                )
                log.createdAt = eventDate
                log.updatedAt = eventDate
                try log.save(db)

                try db.execute(
                    sql: """
                        INSERT INTO sync_row_state (table_name, row_id, updated_at_server)
                        VALUES (?, ?, ?)
                        ON CONFLICT(table_name, row_id)
                        DO UPDATE SET updated_at_server = excluded.updated_at_server
                        """,
                    arguments: ["food_logs", rowId.uuidString, eventDate]
                )

                if let existing = maxUpdatedAt {
                    maxUpdatedAt = max(existing, eventDate)
                } else {
                    maxUpdatedAt = eventDate
                }
            }

            guard let maxUpdatedAt else { return }
            try db.execute(
                sql: """
                    INSERT INTO sync_state (
                        table_name, last_pulled_at_server, last_pull_attempt_at, last_pull_success_at, last_error_code
                    )
                    VALUES (?, ?, ?, ?, NULL)
                    ON CONFLICT(table_name)
                    DO UPDATE SET
                        last_pulled_at_server = excluded.last_pulled_at_server,
                        last_pull_attempt_at = excluded.last_pull_attempt_at,
                        last_pull_success_at = excluded.last_pull_success_at,
                        last_error_code = NULL
                    """,
                arguments: ["food_logs", maxUpdatedAt, Date(), Date()]
            )
        }
    }

    private func stableUUID(_ value: Int) -> UUID {
        let tail = String(format: "%012d", value)
        return UUID(uuidString: "20000000-0000-0000-0000-\(tail)")!
    }
}
