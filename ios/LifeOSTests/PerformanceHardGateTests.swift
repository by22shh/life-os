import XCTest
@testable import LifeOS
import GRDB
import Darwin

final class PerformanceHardGateTests: XCTestCase {
    private enum GateDefaults {
        static let syncLatencyBudgetMs: Double = 2_500
        static let syncMemoryBudgetMB: Double = 450
        static let syncMemoryGrowthBudgetMB: Double = 64
        static let syncEventCount = 600
    }

    func testSyncPushLatencyHardGate() async throws {
        await MainActor.run {
            ForceUpdateManager.shared._testSetStatus(.upToDate)
        }
        let manager = try DatabaseManager.inMemory()
        let syncEngine = SyncEngine(
            dbQueue: manager.dbQueue,
            pushTransportOverride: { _ in }
        )

        try await enqueueEvents(syncEngine: syncEngine, total: GateDefaults.syncEventCount)

        let startedAt = Date()
        try await syncEngine.pushPendingEvents()
        let elapsedMs = Date().timeIntervalSince(startedAt) * 1000

        let succeededCount = try await manager.dbQueue.read { db in
            try OutboxEvent
                .filter(Column("status") == OutboxStatus.succeeded.rawValue)
                .fetchCount(db)
        }
        XCTAssertEqual(succeededCount, GateDefaults.syncEventCount)
        XCTAssertLessThanOrEqual(
            elapsedMs,
            syncLatencyBudgetMs,
            "Sync push latency exceeded hard gate: \(elapsedMs)ms > \(syncLatencyBudgetMs)ms"
        )
    }

    func testSyncPushResidentMemoryHardGate() async throws {
        await MainActor.run {
            ForceUpdateManager.shared._testSetStatus(.upToDate)
        }
        let manager = try DatabaseManager.inMemory()
        let syncEngine = SyncEngine(
            dbQueue: manager.dbQueue,
            pushTransportOverride: { _ in }
        )

        try await enqueueEvents(syncEngine: syncEngine, total: GateDefaults.syncEventCount * 2)
        let baselineMB = Self.currentResidentMemoryMB() ?? 0

        try await syncEngine.pushPendingEvents()
        let finalMB = Self.currentResidentMemoryMB() ?? baselineMB
        let peakMB = max(baselineMB, finalMB)
        let growthMB = max(0, finalMB - baselineMB)

        XCTAssertLessThanOrEqual(
            growthMB,
            syncMemoryGrowthBudgetMB,
            "Sync push resident memory growth exceeded hard gate: \(growthMB)MB > \(syncMemoryGrowthBudgetMB)MB"
        )

        guard enforcesAbsoluteResidentMemoryBudget else { return }

        XCTAssertLessThanOrEqual(
            peakMB,
            syncMemoryBudgetMB,
            "Sync push resident memory exceeded isolated hard gate: \(peakMB)MB > \(syncMemoryBudgetMB)MB"
        )
    }

    private var syncLatencyBudgetMs: Double {
        let raw = ProcessInfo.processInfo.environment["LIFEOS_SYNC_LATENCY_BUDGET_MS"] ?? ""
        return Double(raw) ?? GateDefaults.syncLatencyBudgetMs
    }

    private var syncMemoryBudgetMB: Double {
        let raw = ProcessInfo.processInfo.environment["LIFEOS_SYNC_MEMORY_BUDGET_MB"] ?? ""
        return Double(raw) ?? GateDefaults.syncMemoryBudgetMB
    }

    private var syncMemoryGrowthBudgetMB: Double {
        let raw = ProcessInfo.processInfo.environment["LIFEOS_SYNC_MEMORY_GROWTH_BUDGET_MB"] ?? ""
        return Double(raw) ?? GateDefaults.syncMemoryGrowthBudgetMB
    }

    private var enforcesAbsoluteResidentMemoryBudget: Bool {
        ProcessInfo.processInfo.environment["LIFEOS_PERFORMANCE_HARD_GATES"] == "1"
    }

    private func enqueueEvents(syncEngine: SyncEngine, total: Int) async throws {
        for index in 0..<total {
            let id = UUID()
            let payload = try JSONSerialization.data(withJSONObject: [
                "id": id.uuidString,
                "updated_at": ISO8601DateFormatter.supabaseString(from: Date()),
                "index": index
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

    private static func currentResidentMemoryMB() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPointer,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.resident_size) / (1024 * 1024)
    }
}
