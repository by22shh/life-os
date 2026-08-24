// MARK: - Rate Limit Tracker
// Source of truth: life_os_invariants.md §11 (Rate Limiting)
// Client-side sliding window enforcement for all tiers.
// INVARIANT: AI Vision ≤10/min AND ≤30/hour.

import Foundation

/// Actor-isolated sliding-window rate limiter.
/// Tracks request timestamps per key and rejects requests that exceed the configured limit.
actor RateLimitTracker {
    static let shared = RateLimitTracker()

    /// Keyed sliding windows: [bucketKey: [timestamps]]
    private var windows: [String: [Date]] = [:]

    /// Check if a request is allowed under the given limit and window.
    /// If allowed, records the timestamp; if not, returns `false`.
    func checkAndRecord(key: String, limit: Int, windowSeconds: TimeInterval) -> Bool {
        let now = Date()
        var timestamps = prunedWindow(for: key, windowSeconds: windowSeconds, now: now)

        guard timestamps.count < limit else {
            windows[key] = timestamps
            return false
        }

        timestamps.append(now)
        windows[key] = timestamps
        return true
    }

    /// Convenience: check all applicable rate limits for a given function name.
    /// Returns `true` if the request is allowed under all applicable tiers.
    func checkAllLimits(forFunction name: String) -> Bool {
        let tier = RateLimitPolicy.tier(forFunction: name)

        switch tier {
        case .standard:
            return checkAndRecord(key: "standard_perMin", limit: RateLimitPolicy.standardPerMinute, windowSeconds: 60)
        case .writeHeavy:
            return checkAndRecord(key: "writeHeavy_perMin", limit: RateLimitPolicy.writeHeavyPerMinute, windowSeconds: 60)
        case .aiVision:
            let now = Date()
            let minuteKey = "aiVision_perMin"
            let hourKey = "aiVision_perHour"

            var minuteWindow = prunedWindow(for: minuteKey, windowSeconds: 60, now: now)
            var hourWindow = prunedWindow(for: hourKey, windowSeconds: 3600, now: now)

            guard minuteWindow.count < RateLimitPolicy.aiVisionPerMinute,
                  hourWindow.count < RateLimitPolicy.aiVisionPerHour else {
                windows[minuteKey] = minuteWindow
                windows[hourKey] = hourWindow
                return false
            }

            minuteWindow.append(now)
            hourWindow.append(now)
            windows[minuteKey] = minuteWindow
            windows[hourKey] = hourWindow
            return true
        case .aiParse:
            let now = Date()
            let minuteKey = "aiParse_perMin"
            let dayKey = "aiParse_perDay"

            var minuteWindow = prunedWindow(for: minuteKey, windowSeconds: 60, now: now)
            var dayWindow = prunedWindow(for: dayKey, windowSeconds: 86_400, now: now)

            guard minuteWindow.count < RateLimitPolicy.aiParsePerMinute,
                  dayWindow.count < RateLimitPolicy.aiParsePerDay else {
                windows[minuteKey] = minuteWindow
                windows[dayKey] = dayWindow
                return false
            }

            minuteWindow.append(now)
            dayWindow.append(now)
            windows[minuteKey] = minuteWindow
            windows[dayKey] = dayWindow
            return true
        case .search:
            return checkAndRecord(key: "search_perMin", limit: RateLimitPolicy.searchPerMinute, windowSeconds: 60)
        case .auth:
            return checkAndRecord(key: "auth_perMin", limit: RateLimitPolicy.authPerMinute, windowSeconds: 60)
        case .deleteAccount:
            return checkAndRecord(key: "deleteAccount_perHour", limit: RateLimitPolicy.deleteAccountPerHour, windowSeconds: 3600)
        case .export:
            return checkAndRecord(key: "export_perHour", limit: RateLimitPolicy.exportPerHour, windowSeconds: 3600)
        case .analytics:
            return checkAndRecord(key: "analytics_perMin", limit: RateLimitPolicy.analyticsPerMinute, windowSeconds: 60)
        }
    }

    /// Reset all windows (useful for testing).
    func reset() {
        windows.removeAll()
    }

    private func prunedWindow(for key: String, windowSeconds: TimeInterval, now: Date) -> [Date] {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        return windows[key, default: []].filter { $0 >= cutoff }
    }
}
