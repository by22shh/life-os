// MARK: - Force Update Manager
// Source of truth: life_os_invariants.md §14
// Checks X-Min-App-Version header from API responses.

import Foundation

/// Checks whether the app version meets the minimum required by the server.
@Observable
@MainActor
final class ForceUpdateManager {
    static let shared = ForceUpdateManager()

    enum UpdateStatus: Equatable {
        case upToDate
        case softUpdate(minVersion: String)
        case forceUpdate(minVersion: String)
    }

    private(set) var status: UpdateStatus
    private(set) var appStoreURL: URL = ForceUpdateManager.resolveAppStoreURL(infoDictionary: Bundle.main.infoDictionary)
    private var hasPresentedSoftUpdateThisSession = false

    private let defaults = UserDefaults.standard
    private let observedMinVersionKey = "force_update_observed_min_version"
    private let observedMinVersionAtKey = "force_update_observed_min_version_at"

    private static let gracePeriodSeconds: TimeInterval = 48 * 60 * 60

    init() {
        let infoDictionary = Bundle.main.infoDictionary
        self.appStoreURL = Self.resolveAppStoreURL(infoDictionary: infoDictionary)
        self.status = Self.resolveConfiguredUpdateStatus(
            infoDictionary: infoDictionary,
            currentVersion: Self.resolveCurrentVersion(infoDictionary: infoDictionary)
        )
        if status != .upToDate, Self.shouldResolveDirectAppStoreURL(appStoreURL) {
            Task { [weak self] in
                await self?.refreshAppStoreURLIfNeeded()
            }
        }
    }

    var isForceUpdateRequired: Bool {
        if case .forceUpdate = status { return true }
        return false
    }

    /// Current app version from bundle.
    var currentVersion: String {
        Self.resolveCurrentVersion(infoDictionary: Bundle.main.infoDictionary)
    }

    func refreshAppStoreURLIfNeeded() async {
        let resolvedURL = await Self.resolveBestAppStoreURL(
            infoDictionary: Bundle.main.infoDictionary,
            currentURL: appStoreURL
        )
        if resolvedURL != appStoreURL {
            appStoreURL = resolvedURL
        }
    }

    static func resolveStoreURLForOpening(currentURL: URL, infoDictionary: [String: Any]?) async -> URL {
        await resolveBestAppStoreURL(
            infoDictionary: infoDictionary,
            currentURL: currentURL
        )
    }

    private static func resolveCurrentVersion(infoDictionary: [String: Any]?) -> String {
        if let version = infoDictionary?["CFBundleShortVersionString"] as? String {
            return version
        }
        return "0.0.0"
    }

    private static func resolveAppStoreURL(infoDictionary: [String: Any]?) -> URL {
        if let preferredURL = resolvePreferredAppStoreURL(infoDictionary: infoDictionary) {
            return preferredURL
        }
        return fallbackAppStoreSearchURL(infoDictionary: infoDictionary)
    }

    private static func resolvePreferredAppStoreURL(
        infoDictionary: [String: Any]?,
        currentURL: URL? = nil
    ) -> URL? {
        if let currentURL, let normalizedCurrentURL = normalizeStoreDestinationURL(currentURL) {
            return normalizedCurrentURL
        }

        if let configuredURL = parseAbsoluteURL(infoDictionary?["APP_STORE_URL"] as? String),
           let normalizedConfiguredURL = normalizeStoreDestinationURL(configuredURL) {
            return normalizedConfiguredURL
        }

        if let appStoreID = normalizeAppStoreID(infoDictionary?["APP_STORE_ID"] as? String) {
            return directAppStoreURL(for: appStoreID)
        }

        return nil
    }

    private static func resolveBestAppStoreURL(
        infoDictionary: [String: Any]?,
        currentURL: URL
    ) async -> URL {
        if let preferredURL = resolvePreferredAppStoreURL(
            infoDictionary: infoDictionary,
            currentURL: currentURL
        ) {
            return preferredURL
        }

        if let lookedUpURL = await lookupAppStoreURL(infoDictionary: infoDictionary) {
            return lookedUpURL
        }

        return fallbackAppStoreSearchURL(infoDictionary: infoDictionary)
    }

    private static func fallbackAppStoreSearchURL(infoDictionary: [String: Any]?) -> URL {
        let query = (infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (infoDictionary?["CFBundleName"] as? String)
            ?? "Life OS"
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            ?? "Life%20OS"
        return URL(string: "https://apps.apple.com/us/search?term=\(encodedQuery)")!
    }

    private static func parseAbsoluteURL(_ rawValue: String?) -> URL? {
        guard let rawValue = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty,
            let parsed = URL(string: rawValue),
            let scheme = parsed.scheme?.lowercased(),
            ["http", "https", "itms-apps"].contains(scheme),
            parsed.host != nil
        else {
            return nil
        }
        return parsed
    }

    private static func normalizeStoreDestinationURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased() else {
            return nil
        }

        switch scheme {
        case "itms-apps":
            if let appStoreID = appStoreIdentifier(from: url) {
                return directAppStoreURL(for: appStoreID)
            }
            return url
        case "http", "https":
            if isAppStoreSearchURL(url) {
                return nil
            }
            if let appStoreID = appStoreIdentifier(from: url) {
                return directAppStoreURL(for: appStoreID)
            }
            return url
        default:
            return nil
        }
    }

    private static func shouldResolveDirectAppStoreURL(_ url: URL) -> Bool {
        isAppStoreSearchURL(url)
    }

    private static func isAppStoreSearchURL(_ url: URL) -> Bool {
        guard isAppleAppStoreHost(url.host) else {
            return false
        }

        if url.path.lowercased().contains("/search") {
            return true
        }

        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return queryItems.contains { $0.name.caseInsensitiveCompare("term") == .orderedSame }
    }

    private static func isAppleAppStoreHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else {
            return false
        }
        return host == "itunes.apple.com" || host.hasSuffix("apps.apple.com")
    }

    private static func normalizeAppStoreID(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty,
            let range = rawValue.range(of: #"\d{5,}"#, options: .regularExpression)
        else {
            return nil
        }
        return String(rawValue[range])
    }

    private static func appStoreIdentifier(from url: URL) -> String? {
        let rawValue = url.absoluteString
        guard let range = rawValue.range(of: #"id\d{5,}"#, options: .regularExpression) else {
            return nil
        }
        return String(rawValue[range].dropFirst(2))
    }

    private static func directAppStoreURL(for appStoreID: String) -> URL {
        URL(string: "itms-apps://itunes.apple.com/app/id\(appStoreID)")!
    }

    private static func lookupAppStoreURL(infoDictionary: [String: Any]?) async -> URL? {
        guard let bundleIdentifier = resolveBundleIdentifier(infoDictionary: infoDictionary),
              let lookupURL = appStoreLookupURL(bundleIdentifier: bundleIdentifier) else {
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: lookupURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }

            let decoded = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data)
            guard let result = decoded.results.first else {
                return nil
            }

            if let trackViewURL = parseAbsoluteURL(result.trackViewUrl),
               let normalizedTrackViewURL = normalizeStoreDestinationURL(trackViewURL) {
                return normalizedTrackViewURL
            }

            if let trackID = result.trackId {
                return directAppStoreURL(for: String(trackID))
            }
        } catch {
            return nil
        }

        return nil
    }

    private static func resolveBundleIdentifier(infoDictionary: [String: Any]?) -> String? {
        if let bundleIdentifier = infoDictionary?["CFBundleIdentifier"] as? String {
            let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.contains("$(") {
                return trimmed
            }
        }

        if let bundleIdentifier = Bundle.main.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        return nil
    }

    private static func appStoreLookupURL(bundleIdentifier: String) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleIdentifier),
            URLQueryItem(name: "country", value: appStoreCountryCode())
        ]
        return components?.url
    }

    private static func appStoreCountryCode() -> String {
        Locale.current.region?.identifier.lowercased() ?? "us"
    }

    private static func resolveConfiguredUpdateStatus(
        infoDictionary: [String: Any]?,
        currentVersion: String
    ) -> UpdateStatus {
        let forceVersion = (infoDictionary?["MIN_SUPPORTED_APP_VERSION"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let forceVersion, !forceVersion.isEmpty,
           compareVersions(currentVersion, isLessThanStatic: forceVersion) {
            return .forceUpdate(minVersion: forceVersion)
        }

        let softVersion = (infoDictionary?["SOFT_UPDATE_VERSION"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let softVersion, !softVersion.isEmpty,
           compareVersions(currentVersion, isLessThanStatic: softVersion) {
            return .softUpdate(minVersion: softVersion)
        }

        return .upToDate
    }

    // MARK: - Check Version

    /// Called after every authenticated API response.
    /// Inspects `X-Min-App-Version` and `X-Soft-Update-Version` headers.
    func checkHeaders(_ headers: [AnyHashable: Any]) {
        defer {
            if status != .upToDate, Self.shouldResolveDirectAppStoreURL(appStoreURL) {
                Task { [weak self] in
                    await self?.refreshAppStoreURLIfNeeded()
                }
            }
        }

        let normalized = normalize(headers)

        if let storeURLRaw = normalized["x-app-store-url"],
           let parsedStoreURL = Self.parseAbsoluteURL(storeURLRaw) {
            appStoreURL = Self.resolvePreferredAppStoreURL(
                infoDictionary: Bundle.main.infoDictionary,
                currentURL: parsedStoreURL
            ) ?? Self.fallbackAppStoreSearchURL(infoDictionary: Bundle.main.infoDictionary)
        }

        // Sticky behavior: once forced within a session, keep blocking until app version is updated.
        if case .forceUpdate(let forcedVersion) = status,
           compareVersions(currentVersion, isLessThan: forcedVersion) {
            return
        }

        if let forceVersion = normalized["x-min-app-version"],
           compareVersions(currentVersion, isLessThan: forceVersion) {
            let firstSeen = firstSeenAt(for: forceVersion)
            if Date().timeIntervalSince(firstSeen) >= Self.gracePeriodSeconds {
                status = .forceUpdate(minVersion: forceVersion)
                return
            }
            presentSoftUpdateOnce(minVersion: forceVersion)
            return
        } else {
            clearObservedMinVersion()
        }

        if let softVersion = normalized["x-soft-update-version"],
           compareVersions(currentVersion, isLessThan: softVersion) {
            presentSoftUpdateOnce(minVersion: softVersion)
            return
        }

        status = Self.resolveConfiguredUpdateStatus(
            infoDictionary: Bundle.main.infoDictionary,
            currentVersion: currentVersion
        )
    }

    /// Dismisses non-blocking soft update banner.
    func dismissSoftUpdate() {
        if case .softUpdate = status {
            status = .upToDate
        }
    }

    // MARK: - Version Comparison

    /// Semantic version comparison. Returns true if `lhs < rhs`.
    func compareVersions(_ lhs: String, isLessThan rhs: String) -> Bool {
        Self.compareVersions(lhs, isLessThanStatic: rhs)
    }

    private static func compareVersions(_ lhs: String, isLessThanStatic rhs: String) -> Bool {
        let lhsParts = normalizedVersionComponents(lhs)
        let rhsParts = normalizedVersionComponents(rhs)

        let maxLen = max(lhsParts.count, rhsParts.count)
        for i in 0..<maxLen {
            let l = i < lhsParts.count ? lhsParts[i] : 0
            let r = i < rhsParts.count ? rhsParts[i] : 0
            if l < r { return true }
            if l > r { return false }
        }
        return false
    }

    private func normalizedVersionComponents(_ version: String) -> [Int] {
        Self.normalizedVersionComponents(version)
    }

    private static func normalizedVersionComponents(_ version: String) -> [Int] {
        version
            .split(separator: ".", omittingEmptySubsequences: false)
            .map(Self.numericVersionComponent)
    }

    private static func numericVersionComponent(_ component: Substring) -> Int {
        let raw = String(component).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = raw.range(of: #"\d+"#, options: .regularExpression) else {
            return 0
        }
        if let parsed = Int(raw[range]) {
            return parsed
        }
        return 0
    }

    private func presentSoftUpdateOnce(minVersion: String) {
        guard !hasPresentedSoftUpdateThisSession else {
            return
        }
        hasPresentedSoftUpdateThisSession = true
        status = .softUpdate(minVersion: minVersion)
    }

    private func normalize(_ headers: [AnyHashable: Any]) -> [String: String] {
        var normalized: [String: String] = [:]
        for (key, value) in headers {
            let keyString = String(describing: key).lowercased()
            if let stringValue = value as? String {
                normalized[keyString] = stringValue
            } else {
                normalized[keyString] = String(describing: value)
            }
        }
        return normalized
    }

    private func firstSeenAt(for minVersion: String) -> Date {
        let knownVersion = defaults.string(forKey: observedMinVersionKey)
        if knownVersion != minVersion {
            let now = Date()
            defaults.set(minVersion, forKey: observedMinVersionKey)
            defaults.set(now, forKey: observedMinVersionAtKey)
            return now
        }

        if let observedAt = defaults.object(forKey: observedMinVersionAtKey) as? Date {
            return observedAt
        }

        let now = Date()
        defaults.set(now, forKey: observedMinVersionAtKey)
        return now
    }

    private func clearObservedMinVersion() {
        defaults.removeObject(forKey: observedMinVersionKey)
        defaults.removeObject(forKey: observedMinVersionAtKey)
    }

}

private struct AppStoreLookupResponse: Decodable {
    let results: [AppStoreLookupResult]
}

private struct AppStoreLookupResult: Decodable {
    let trackId: Int?
    let trackViewUrl: String?
}

#if DEBUG
extension ForceUpdateManager {
    func _testSetStatus(_ status: UpdateStatus, appStoreURL: URL? = nil) {
        self.status = status
        if let appStoreURL {
            self.appStoreURL = appStoreURL
        }
    }

    func _testResetSoftPresentationFlag() {
        hasPresentedSoftUpdateThisSession = false
    }

    static func _testResolveAppStoreURL(infoDictionary: [String: Any]?) -> URL {
        resolveAppStoreURL(infoDictionary: infoDictionary)
    }

    static func _testResolveCurrentVersion(infoDictionary: [String: Any]?) -> String {
        resolveCurrentVersion(infoDictionary: infoDictionary)
    }
}
#endif
