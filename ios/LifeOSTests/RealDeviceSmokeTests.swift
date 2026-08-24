import XCTest
import HealthKit
import UserNotifications
@testable import LifeOS
import GRDB
#if os(iOS)
import UIKit
#endif

final class RealDeviceSmokeTests: XCTestCase {

    private func skipIfSimulator() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Real-device smoke tests require physical iOS hardware.")
        #endif
    }

    func testHealthKitAvailabilityAndAuthorizationSnapshot() throws {
        try skipIfSimulator()
        XCTAssertTrue(HKHealthStore.isHealthDataAvailable(), "HealthKit must be available on real device")

        guard let restingHeartRate = HKObjectType.quantityType(forIdentifier: .restingHeartRate) else {
            XCTFail("restingHeartRate quantity type is unavailable")
            return
        }

        let status = HKHealthStore().authorizationStatus(for: restingHeartRate)
        XCTAssertTrue(
            status == .notDetermined || status == .sharingAuthorized || status == .sharingDenied,
            "Unexpected HealthKit authorization status: \\(status.rawValue)"
        )
    }

    func testNotificationSettingsCanBeReadForAPNsSmoke() async throws {
        try skipIfSimulator()

        let statusRaw = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { current in
                continuation.resume(returning: current.authorizationStatus.rawValue)
            }
        }
        let status = UNAuthorizationStatus(rawValue: statusRaw) ?? .notDetermined

        switch status {
        case .notDetermined, .denied, .authorized, .provisional, .ephemeral:
            XCTAssertTrue(true)
        @unknown default:
            XCTFail("Unexpected notification authorization status: \(statusRaw)")
        }
    }

    @MainActor
    func testBackgroundRefreshStatusIsReachable() throws {
        try skipIfSimulator()
        #if os(iOS)
        let status = UIApplication.shared.backgroundRefreshStatus
        XCTAssertTrue(
            status == .available || status == .denied || status == .restricted,
            "Unexpected background refresh status: \\(status.rawValue)"
        )
        #endif
    }

    func testOfflineOutboxReplayRecoversAfterConnectivityReturns() async throws {
        try skipIfSimulator()

        let manager = try DatabaseManager.inMemory()
        let transport = RealDeviceChaosTransport()
        let syncEngine = SyncEngine(
            dbQueue: manager.dbQueue,
            pushTransportOverride: { event in
                try await transport.handle(event)
            }
        )

        await transport.setMode(.offline)
        let totalEvents = 40
        try await enqueueOutboxEvents(syncEngine: syncEngine, total: totalEvents)

        try await syncEngine.pushPendingEvents()

        let retryableFailures = try await manager.dbQueue.read { db in
            try OutboxEvent
                .filter(Column("status") == OutboxStatus.failedRetryable.rawValue)
                .fetchCount(db)
        }
        XCTAssertGreaterThan(retryableFailures, 0, "Offline pass should create retryable failures")

        await transport.setMode(.online)
        for _ in 0..<4 {
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
            try await syncEngine.pushPendingEvents()
        }

        let succeededCount = try await manager.dbQueue.read { db in
            try OutboxEvent
                .filter(Column("status") == OutboxStatus.succeeded.rawValue)
                .fetchCount(db)
        }
        XCTAssertEqual(succeededCount, totalEvents, "All offline-queued events must replay after recovery")
    }

    func testChaosRetryProfileDrainsQueueWithoutDataLoss() async throws {
        try skipIfSimulator()

        let manager = try DatabaseManager.inMemory()
        let transport = RealDeviceChaosTransport()
        let syncEngine = SyncEngine(
            dbQueue: manager.dbQueue,
            pushTransportOverride: { event in
                try await transport.handle(event)
            }
        )

        let totalEvents = 80
        try await enqueueOutboxEvents(syncEngine: syncEngine, total: totalEvents)
        await transport.setMode(.chaos)

        for _ in 0..<8 {
            try await syncEngine.pushPendingEvents()
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

        let statusBreakdown: (succeeded: Int, pending: Int, retryable: Int, permanent: Int) = try await manager.dbQueue.read { db in
            let succeeded = try OutboxEvent
                .filter(Column("status") == OutboxStatus.succeeded.rawValue)
                .fetchCount(db)
            let pending = try OutboxEvent
                .filter(Column("status") == OutboxStatus.pending.rawValue)
                .fetchCount(db)
            let retryable = try OutboxEvent
                .filter(Column("status") == OutboxStatus.failedRetryable.rawValue)
                .fetchCount(db)
            let permanent = try OutboxEvent
                .filter(Column("status") == OutboxStatus.failedPermanent.rawValue)
                .fetchCount(db)
            return (succeeded: succeeded, pending: pending, retryable: retryable, permanent: permanent)
        }

        XCTAssertEqual(
            statusBreakdown.succeeded,
            totalEvents,
            "Chaos profile should eventually drain all events via retries"
        )
        XCTAssertEqual(statusBreakdown.pending + statusBreakdown.retryable + statusBreakdown.permanent, 0)
    }

    private func enqueueOutboxEvents(syncEngine: SyncEngine, total: Int) async throws {
        for index in 0..<total {
            let id = UUID()
            let payload = try JSONSerialization.data(withJSONObject: [
                "id": id.uuidString,
                "updated_at": ISO8601DateFormatter.supabaseString(from: Date()),
                "sample_index": index
            ])
            let event = OutboxEvent(
                id: id,
                httpMethod: .POST,
                path: "api-settings-privacy",
                bodyJson: payload,
                priority: 100 + index
            )
            try await syncEngine.enqueueMutation(event)
        }
    }
}

actor RealDeviceChaosTransport {
    enum Mode {
        case offline
        case chaos
        case online
    }

    private var mode: Mode = .online
    private var attempts: [UUID: Int] = [:]

    func setMode(_ nextMode: Mode) {
        mode = nextMode
    }

    func handle(_ event: OutboxEvent) throws {
        let attempt = (attempts[event.id] ?? 0) + 1
        attempts[event.id] = attempt

        switch mode {
        case .online:
            return
        case .offline:
            throw makeNetworkError(code: NSURLErrorNotConnectedToInternet)
        case .chaos:
            let entropy = trailingEntropy(of: event.id)
            if entropy % 11 == 0 && attempt == 1 {
                throw makeRateLimitedError(retryAfter: 1)
            }
            let failAttempts = entropy % 3
            if attempt <= failAttempts {
                throw makeNetworkError(code: NSURLErrorNetworkConnectionLost)
            }
        }
    }

    private func trailingEntropy(of id: UUID) -> Int {
        let hex = id.uuidString.replacingOccurrences(of: "-", with: "")
        let suffix = String(hex.suffix(2))
        return Int(suffix, radix: 16) ?? 0
    }

    private func makeNetworkError(code: Int) -> NSError {
        NSError(
            domain: NSURLErrorDomain,
            code: code,
            userInfo: [
                "status": 503,
                NSLocalizedDescriptionKey: "Simulated network failure"
            ]
        )
    }

    private func makeRateLimitedError(retryAfter: TimeInterval) -> NSError {
        NSError(
            domain: "RealDeviceChaosTransport",
            code: 429,
            userInfo: [
                "status": 429,
                "retry_after_seconds": retryAfter,
                NSLocalizedDescriptionKey: "Simulated rate limit"
            ]
        )
    }
}
