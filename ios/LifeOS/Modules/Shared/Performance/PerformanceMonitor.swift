import Foundation
import os

enum PerformanceMonitor {
    private static let logger = Logger(subsystem: "com.lifeos.app", category: "performance")

    private struct LaunchState {
        var coldLaunchStartedAt: Date?
        var warmLaunchStartedAt: Date?
    }

    private static let launchStateLock = OSAllocatedUnfairLock<LaunchState>(
        initialState: LaunchState()
    )

    static let coldLaunchBudgetMs: Double = 2_000
    static let warmLaunchBudgetMs: Double = 500
    static let diaryLoadBudgetMs: Double = 200
    static let localQueryBudgetMs: Double = 50

    static func trackColdLaunchStart() {
        launchStateLock.withLock { state in
            state.coldLaunchStartedAt = Date()
        }
        logger.notice("perf.cold_launch.start")
    }

    static func trackColdLaunchEnd() {
        let durationMs = launchStateLock.withLock { state -> Double in
            guard let startedAt = state.coldLaunchStartedAt else { return 0 }
            state.coldLaunchStartedAt = nil
            return Date().timeIntervalSince(startedAt) * 1000
        }
        logger.notice("perf.cold_launch.end ms=\(durationMs, format: .fixed(precision: 2))")
        if durationMs > coldLaunchBudgetMs {
            logger.error("perf.budget_exceeded.cold_launch ms=\(durationMs, format: .fixed(precision: 2)) budget_ms=\(coldLaunchBudgetMs, format: .fixed(precision: 2))")
        }
    }

    static func trackWarmLaunchStart() {
        launchStateLock.withLock { state in
            state.warmLaunchStartedAt = Date()
        }
        logger.notice("perf.warm_launch.start")
    }

    static func trackWarmLaunchEnd() {
        guard let durationMs = launchStateLock.withLock({ state -> Double? in
            guard let startedAt = state.warmLaunchStartedAt else { return nil }
            state.warmLaunchStartedAt = nil
            return Date().timeIntervalSince(startedAt) * 1000
        }) else {
            return
        }
        logger.notice("perf.warm_launch ms=\(durationMs, format: .fixed(precision: 2))")
        if durationMs > warmLaunchBudgetMs {
            logger.error("perf.budget_exceeded.warm_launch ms=\(durationMs, format: .fixed(precision: 2)) budget_ms=\(warmLaunchBudgetMs, format: .fixed(precision: 2))")
        }
    }

    static func trackWarmLaunch(durationMs: Double? = nil) {
        if let durationMs {
            logger.notice("perf.warm_launch ms=\(durationMs, format: .fixed(precision: 2))")
            if durationMs > warmLaunchBudgetMs {
                logger.error("perf.budget_exceeded.warm_launch ms=\(durationMs, format: .fixed(precision: 2)) budget_ms=\(warmLaunchBudgetMs, format: .fixed(precision: 2))")
            }
        } else {
            let hasPendingWarmLaunch = launchStateLock.withLock { state in
                state.warmLaunchStartedAt != nil
            }
            if hasPendingWarmLaunch {
                trackWarmLaunchEnd()
            } else {
                logger.notice("perf.warm_launch")
            }
        }
    }

    static func trackDiaryLoad(durationMs: Double) {
        logger.notice("perf.diary_load_ms=\(durationMs, format: .fixed(precision: 2))")
        if durationMs > diaryLoadBudgetMs {
            logger.error("perf.budget_exceeded.diary_load ms=\(durationMs, format: .fixed(precision: 2)) budget_ms=\(diaryLoadBudgetMs, format: .fixed(precision: 2))")
        }
    }

    static func trackLocalQuery(durationMs: Double, label: String) {
        logger.notice("perf.query.\(label, privacy: .public)=\(durationMs, format: .fixed(precision: 2))")
        if durationMs > localQueryBudgetMs {
            logger.error("perf.budget_exceeded.query.\(label, privacy: .public) ms=\(durationMs, format: .fixed(precision: 2)) budget_ms=\(localQueryBudgetMs, format: .fixed(precision: 2))")
        }
    }

    static func isWithinColdLaunchBudget(_ durationMs: Double) -> Bool {
        durationMs <= coldLaunchBudgetMs
    }

    static func isWithinWarmLaunchBudget(_ durationMs: Double) -> Bool {
        durationMs <= warmLaunchBudgetMs
    }

    static func isWithinDiaryLoadBudget(_ durationMs: Double) -> Bool {
        durationMs <= diaryLoadBudgetMs
    }

    static func isWithinLocalQueryBudget(_ durationMs: Double) -> Bool {
        durationMs <= localQueryBudgetMs
    }
}
