// MARK: - Client-visible Rate Limit Policy
// Mirrors life_os_invariants.md §11 and API response handling.

import Foundation

enum RateLimitPolicy {
    static let standardPerMinute = 120
    static let writeHeavyPerMinute = 30
    static let aiVisionPerMinute = 10
    static let aiVisionPerHour = 30
    static let aiParsePerMinute = 20
    static let aiParsePerDay = 200
    static let searchPerMinute = 60
    static let authPerMinute = 5
    static let deleteAccountPerHour = 3
    static let exportPerHour = 1
    static let analyticsPerMinute = 10

    // Outbox replay exemption: 300 requests per 5 minutes.
    static let outboxReplayPerFiveMinutes = 300

    /// Tiers whose budgets the `X-Outbox-Replay` header may bypass, mirroring
    /// `OUTBOX_REPLAY_EXEMPTABLE_TIERS` in supabase/functions/_shared/rate_limit.ts.
    /// Cost-sensitive tiers (AI, search, auth, deletion, export) always enforce
    /// their interactive budgets, even during outbox replay.
    static let replayExemptibleTiers: Set<Tier> = [.standard, .writeHeavy, .analytics]

    /// Returns true when a request carrying the replay header may substitute
    /// its tier budget with the replay window.
    static func isReplayExemptible(headers: [String: String], function name: String) -> Bool {
        isOutboxReplay(headers: headers)
            && replayExemptibleTiers.contains(tier(forFunction: name))
    }

    static func isOutboxReplay(headers: [String: String]) -> Bool {
        guard let rawValue = headers.first(where: {
            $0.key.caseInsensitiveCompare("X-Outbox-Replay") == .orderedSame
        })?.value else {
            return false
        }
        return rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "true"
    }

    enum Tier {
        case standard
        case writeHeavy
        case aiVision
        case aiParse
        case search
        case auth
        case deleteAccount
        case export
        case analytics
    }

    static func tier(forFunction name: String) -> Tier {
        switch name {
        case "api-analytics-batch":
            return .analytics
        case "api-account-delete":
            return .deleteAccount
        case "api-user-export":
            return .export
        case "api-food-log",
             "api-workouts",
             "api-workouts-log",
             "api-workout-log", // legacy alias
             "api-hydration",
             "api-hydration-log", // legacy alias
             "api-body-composition",
             "api-wellness",
             "api-wellness-check", // legacy alias
             "api-training-plan",
             "api-user-supplements",
             "api-experiments",
             "api-sleep-log",
             "api-labs":
            return .writeHeavy
        case "api-supplements-log",
             "api-supplement-log", // legacy alias
             "api-menstrual-sync":
            return .writeHeavy
        case "api-insights-predict":
            return .aiVision
        case "analyze-food-image":
            return .aiVision
        case "parse-food-text":
            return .aiParse
        case "ai-openrouter-gateway":
            return .aiVision
        case "api-search", "api-foods":
            return .search
        case "auth-signin", "auth-refresh":
            return .auth
        case "api-account-delete-cancel",
             "api-account-delete-status",
             "api-config-feature-flags",
             "api-diary-daily",
             "api-diary-calendar",
             "api-insight-acknowledge",
             "api-insights-daily",
             "api-nutrition-batches",
             "api-nutrition-daily",
             "api-nutrition-calendar",
             "api-nutrition-templates",
             "api-recovery",
             "api-recommendations",
             "api-sleep-daily",
             "api-sleep-calendar",
             "api-supplements-daily",
             "api-supplements-calendar",
             "api-workouts-daily",
             "api-workouts-summary",
             "api-workouts-weekly",
             "api-user-export-status",
             "api-weekly-strategy",
             "api-settings-consent",
             "api-settings-notifications",
             "api-settings-privacy",
             "api-watch-snapshot",
             "send-notification":
            return .standard
        default:
            return .standard
        }
    }
}
