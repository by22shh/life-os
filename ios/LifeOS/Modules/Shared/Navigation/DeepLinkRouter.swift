// MARK: - Deep Link Router
// Source of truth: life_os_invariants.md §15
// All lifeos:// schemes from the registry. Fallback: unrecognized → Home.

import Foundation
import SwiftUI
import GRDB

/// Routes `lifeos://` deep links to the appropriate screen.
@Observable
final class DeepLinkRouter {

    var selectedTab: AppTab = .home
    var pendingNavigation: DeepLinkDestination?

    // MARK: - Handle URL

    /// Parse and route a lifeos:// URL. Returns false if URL not recognized.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme == "lifeos" else { return false }

        let destination = parseDestination(url)
        if destination == .home, !(url.host() == "home") {
            DeepLinkAudit.logFallback(url)
        }
        navigate(to: destination)
        return true
    }

    func consumePendingNavigation() -> DeepLinkDestination? {
        let destination = pendingNavigation
        pendingNavigation = nil
        return destination
    }

    // MARK: - Parsing

    private func parseDestination(_ url: URL) -> DeepLinkDestination {
        let host: String
        if let resolvedHost = url.host() {
            host = resolvedHost
        } else {
            host = ""
        }
        let path = url.path()
        let pathComponent = pathPathComponent(path)

        switch host {
        // Tab-level navigation
        case "home":
            return .home
        case "diary":
            return parseDiaryLink(path, url: url)

        // Recovery
        case "recovery":
            let date = url.queryValue(for: "date") ?? normalizedDatePath(pathComponent)
            return .recoveryDetail(date: date)

        // Nutrition registry
        case "nutrition":
            if path == "/log" {
                let method = NutritionLogMethod(rawValue: (url.queryValue(for: "method") ?? "").lowercased())
                let confidence = parsedConfidence(url.queryValue(for: "confidence"))
                return .nutritionLog(method: method, aiConfidence: confidence)
            }
            return .nutrition(date: url.queryValue(for: "date") ?? normalizedDatePath(pathComponent))

        // Backward-compatible alias from API notifications table.
        case "food":
            if path == "/log" {
                let confidence = parsedConfidence(url.queryValue(for: "confidence"))
                return .nutritionLog(method: nil, aiConfidence: confidence)
            }
            return .nutrition(date: url.queryValue(for: "date") ?? normalizedDatePath(pathComponent))

        // Supplements registry
        case "supplements":
            if path == "/log" {
                return .supplementsLog(date: url.queryValue(for: "date"))
            }
            return .supplements(date: url.queryValue(for: "date") ?? normalizedDatePath(pathComponent))

        // Workout registry
        case "workout":
            if path == "/log" {
                return .workoutLog
            }
            return .workout(date: url.queryValue(for: "date") ?? normalizedDatePath(pathComponent))

        // Auth
        case "auth":
            if path.hasPrefix("/callback") {
                return .authCallback
            }
            return .home

        // Insights registry: lifeos://insights/{id}
        case "insights":
            if path == "/simulate" || path == "/simulation" {
                return .simulation
            }
            if let id = UUID(uuidString: pathPathComponent(path)) {
                return .insightDetail(id: id)
            }
            return .insights

        case "simulation":
            return .simulation

        // Experiments registry: lifeos://experiments/{id}
        case "experiments":
            // Support both lifeos://experiments/{id} and legacy lifeos://experiments/{id}/log.
            let experimentPathId = firstPathComponent(path)
            if let id = UUID(uuidString: experimentPathId) {
                return .experiment(id: id)
            }
            return .insights

        // Backward-compatible achievement route.
        case "achievements":
            return .insights

        // Settings registry
        case "settings":
            switch path {
            case "/sync":
                return .settingsSync
            case "/notifications":
                return .settingsNotifications
            case "/privacy":
                return .settingsPrivacy
            default:
                return .settings
            }

        // Labs registry: lifeos://labs/{id}
        case "labs":
            if let scanId = UUID(uuidString: pathPathComponent(path)) {
                return .labScan(id: scanId)
            }
            return .labs

        // Hydration registry: lifeos://hydration?date=YYYY-MM-DD
        case "hydration":
            return .hydration(date: url.queryValue(for: "date") ?? normalizedDatePath(pathComponent))

        // Wellness registry: lifeos://wellness?date=YYYY-MM-DD
        case "wellness":
            return .wellness(date: url.queryValue(for: "date") ?? normalizedDatePath(pathComponent))

        // Menstrual registry: lifeos://menstrual?date=YYYY-MM-DD
        case "menstrual", "cycle":
            return .menstrual(date: url.queryValue(for: "date") ?? normalizedDatePath(pathComponent))

        // Body Composition registry: lifeos://body-composition
        case "body-composition", "bodyComposition":
            return .bodyComposition

        // Sleep registry: lifeos://sleep?date=YYYY-MM-DD
        case "sleep":
            return .sleep(date: url.queryValue(for: "date") ?? normalizedDatePath(pathComponent))

        default:
            // INVARIANT: Unrecognized → Home
            return .home
        }
    }

    private func parseDiaryLink(_ path: String, url: URL) -> DeepLinkDestination {
        let date = url.queryValue(for: "date") ?? normalizedDatePath(pathPathComponent(path))
        if url.queryValue(for: "mode")?.lowercased() == "review" {
            return .diaryReview(date: date)
        }
        return .diary(date: date)
    }

    // MARK: - Navigation

    private func navigate(to destination: DeepLinkDestination) {
        // Set the tab first
        switch destination {
        case .home, .recoveryDetail, .authCallback:
            selectedTab = .home
        case .diary, .diaryReview, .nutrition, .nutritionLog, .supplements, .supplementsLog, .workout, .workoutLog, .labs, .labScan,
             .hydration, .wellness, .menstrual, .bodyComposition, .sleep:
            selectedTab = .diary
        case .insights, .insightDetail, .experiment:
            selectedTab = .insights
        case .simulation:
            break
        case .settings, .settingsSync, .settingsNotifications, .settingsPrivacy:
            selectedTab = .settings
        }

        // Then set the pending navigation for the target view to handle
        pendingNavigation = destination
    }
}

// MARK: - Destinations

enum DeepLinkDestination: Equatable, Hashable {
    case home
    case diary(date: String?)
    case diaryReview(date: String?)
    case insights
    case simulation
    case insightDetail(id: UUID)
    case settings
    case settingsSync
    case settingsNotifications
    case settingsPrivacy
    case recoveryDetail(date: String?)
    case nutrition(date: String?)
    case nutritionLog(method: NutritionLogMethod?, aiConfidence: Double?)
    case supplements(date: String?)
    case supplementsLog(date: String?)
    case workout(date: String?)
    case workoutLog
    case authCallback
    case experiment(id: UUID)
    case labs
    case labScan(id: UUID)
    case hydration(date: String?)
    case wellness(date: String?)
    case menstrual(date: String?)
    case bodyComposition
    case sleep(date: String?)
}

enum NutritionLogMethod: String, Codable, Sendable, Hashable {
    case photo
    case barcode
    case voice
    case manual
    case batch
    case template
}

// MARK: - URL Helper

private extension URL {
    func queryValue(for key: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == key })?
            .value
    }
}

private func pathPathComponent(_ path: String) -> String {
    if let component = path.split(separator: "/").last {
        return String(component)
    }
    return ""
}

private func firstPathComponent(_ path: String) -> String {
    if let component = path.split(separator: "/").first {
        return String(component)
    }
    return ""
}

private func normalizedDatePath(_ value: String) -> String? {
    guard !value.isEmpty else { return nil }
    let pattern = #"^\d{4}-\d{2}-\d{2}$"#
    if value.range(of: pattern, options: .regularExpression) != nil {
        return value
    }
    return nil
}

private func parsedConfidence(_ value: String?) -> Double? {
    guard let value, let confidence = Double(value) else { return nil }
    return min(max(confidence, 0), 1)
}

private enum DeepLinkAudit {
    static func logFallback(_ url: URL) {
        logFallback(
            url,
            isRunningTests: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        )
    }

    static func logFallback(_ url: URL, isRunningTests: Bool) {
        if isRunningTests {
            return
        }
        let payload: [String: String] = [
            "url": url.absoluteString,
            "host": url.host() ?? "",
            "path": url.path()
        ]
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let event = AnalyticsEvent(eventName: "analytics.deeplink_fallback", properties: payloadData)

        Task.detached {
            do {
                try DatabaseManager.shared.dbQueue.write { db in
                    try event.insert(db)

                    let rawPropertiesObject = try JSONSerialization.jsonObject(with: event.properties)
                    let propertiesObject = propertiesDictionary(from: rawPropertiesObject)
                    let body = try JSONSerialization.data(withJSONObject: [
                        "events": [[
                            "name": event.eventName,
                            "timestamp": ISO8601DateFormatter.supabaseString(from: event.createdAt),
                            "properties": propertiesObject
                        ]]
                    ])
                    let headers = try JSONSerialization.data(withJSONObject: [
                        "Content-Type": "application/json",
                        "X-Outbox-Replay": "true"
                    ])
                    var outbox = OutboxEvent(
                        httpMethod: .POST,
                        path: "api-analytics-batch",
                        headersJson: headers,
                        bodyJson: body,
                        priority: 200
                    )
                    outbox.idempotencyKey = event.id.uuidString
                    try outbox.insert(db)
                }
            } catch {
                // Non-blocking analytics write.
            }
        }
    }

    static func propertiesDictionary(from rawPropertiesObject: Any) -> [String: Any] {
        if let resolvedPropertiesObject = rawPropertiesObject as? [String: Any] {
            return resolvedPropertiesObject
        }
        return [:]
    }
}

#if DEBUG
extension DeepLinkRouter {
    static func _testLogFallback(_ url: URL, isRunningTests: Bool) {
        DeepLinkAudit.logFallback(url, isRunningTests: isRunningTests)
    }

    static func _testFirstPathComponent(_ path: String) -> String {
        firstPathComponent(path)
    }

    static func _testAuditPropertiesDictionary(_ value: Any) -> [String: Any] {
        DeepLinkAudit.propertiesDictionary(from: value)
    }
}
#endif
