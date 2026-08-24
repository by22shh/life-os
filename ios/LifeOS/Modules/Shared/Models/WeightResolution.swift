// MARK: - Dynamic Weight Resolution
// Source of truth: life_os_invariants.md §13
// RULE: Never read `users.weight_kg` directly. Always use `getEffectiveWeight()`.
// Fallback chain:
//   1. Rolling 7-day average from body_composition
//   2. Latest body_composition measurement
//   3. Static `users.weight_kg`

import Foundation
import GRDB

enum WeightResolution {

    // MARK: - Public API

    /// Returns the effective weight in kg using the invariant §13 fallback chain.
    /// - Parameters:
    ///   - userId: The user whose weight to resolve.
    ///   - db: An active GRDB database connection (read or write).
    /// - Returns: Effective weight in kg, or `nil` if no weight data exists anywhere.
    static func getEffectiveWeight(userId: UUID, db: Database) throws -> Double? {
        // Step 1: Rolling 7-day average from body_composition
        if let rollingAvg = try rolling7DayAverage(userId: userId, db: db) {
            return rollingAvg
        }

        // Step 2: Latest body_composition measurement
        if let latest = try latestBodyComposition(userId: userId, db: db) {
            return latest
        }

        // Step 3: Static users.weight_kg
        return try staticUserWeight(userId: userId, db: db)
    }

    /// Async convenience wrapper for use with DatabaseQueue.
    static func getEffectiveWeight(userId: UUID, dbQueue: DatabaseQueue) async throws -> Double? {
        try await dbQueue.read { db in
            try getEffectiveWeight(userId: userId, db: db)
        }
    }

    // MARK: - Fallback Chain Steps

    /// Step 1: Rolling 7-day average weight from body_composition table.
    /// Requires at least 2 measurements in the last 14 days.
    private static func rolling7DayAverage(userId: UUID, db: Database) throws -> Double? {
        let start = Date()
        let now = Date()
        let fourteenDaysAgo = daysAgo(14, from: now)
        let sevenDaysAgo = daysAgo(7, from: now)

        let avg = try Double.fetchOne(db, sql: """
            WITH recent_count AS (
                SELECT COUNT(*) AS count_14d
                FROM body_composition
                WHERE (user_id = ? OR user_id = ?)
                  AND measured_at >= ?
                  AND deleted_at IS NULL
                  AND weight_kg > 0
            )
            SELECT AVG(weight_kg)
            FROM body_composition
            WHERE (user_id = ? OR user_id = ?)
              AND measured_at >= ?
              AND deleted_at IS NULL
              AND weight_kg > 0
              AND (SELECT count_14d FROM recent_count) >= 2
            """,
            arguments: [userId, userId.uuidString, fourteenDaysAgo, userId, userId.uuidString, sevenDaysAgo]
        )
        PerformanceMonitor.trackLocalQuery(
            durationMs: Date().timeIntervalSince(start) * 1000,
            label: "weight_rolling_avg"
        )

        return avg
    }

    /// Step 2: Latest single body_composition measurement.
    private static func latestBodyComposition(userId: UUID, db: Database) throws -> Double? {
        let start = Date()
        let thirtyDaysAgo = daysAgo(30)
        let value = try Double.fetchOne(db, sql: """
            SELECT weight_kg
            FROM body_composition
            WHERE (user_id = ? OR user_id = ?)
              AND deleted_at IS NULL
              AND weight_kg > 0
              AND measured_at >= ?
            ORDER BY measured_at DESC
            LIMIT 1
            """,
            arguments: [userId, userId.uuidString, thirtyDaysAgo]
        )
        PerformanceMonitor.trackLocalQuery(
            durationMs: Date().timeIntervalSince(start) * 1000,
            label: "weight_latest_body_composition"
        )
        return value
    }

    /// Step 3: Static weight from users table (profile weight).
    private static func staticUserWeight(userId: UUID, db: Database) throws -> Double? {
        let start = Date()
        let value = try Double.fetchOne(db, sql: """
            SELECT weight_kg
            FROM users
            WHERE (id = ? OR id = ?)
              AND weight_kg > 0
            """,
            arguments: [userId, userId.uuidString]
        )
        PerformanceMonitor.trackLocalQuery(
            durationMs: Date().timeIntervalSince(start) * 1000,
            label: "weight_static_user"
        )
        return value
    }

    // MARK: - Weight Divergence (§13 + §17)

    /// Returns `true` if the effective weight diverges from the static profile weight.
    /// Two invariant rules apply (OR logic — either triggers the prompt):
    ///   - §13: absolute divergence > 2 kg
    ///   - §17: relative divergence > 5%
    /// UI layer should surface `profile.weight_divergence_prompt` when this returns `true`.
    static func checkDivergence(userId: UUID, db: Database) throws -> Bool {
        guard let effectiveWeight = try getEffectiveWeight(userId: userId, db: db),
              let profileWeight = try staticUserWeight(userId: userId, db: db),
              profileWeight > 0 else {
            return false
        }
        return divergenceExceedsThreshold(resolved: effectiveWeight, profileWeight: profileWeight)
    }

    /// Pure-function helper for unit testing.
    /// Uses OR logic: absolute > `absoluteThresholdKg` OR relative > `relativeThreshold`.
    static func divergenceExceedsThreshold(
        resolved: Double,
        profileWeight: Double,
        absoluteThresholdKg: Double = 2.0,
        relativeThreshold: Double = 0.05
    ) -> Bool {
        guard profileWeight > 0 else { return false }
        let absoluteDiff = abs(resolved - profileWeight)
        let relativeDiff = absoluteDiff / profileWeight
        // §13: absolute > 2kg  OR  §17: relative > 5%
        return absoluteDiff > absoluteThresholdKg || relativeDiff > relativeThreshold
    }

    private static func daysAgo(_ days: Int, from now: Date = Date()) -> Date {
        let clampedDays = max(days, 0)
        return Calendar.current.date(byAdding: .day, value: -clampedDays, to: now)!
    }
}
