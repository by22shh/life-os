import Foundation
import OSLog
import WatchConnectivity

private let watchPendingLightweightActionsDefaultsKey = "watch.pending_lightweight_actions"
private let watchSnapshotStoreLogger = Logger(subsystem: "com.lifeos.watch", category: "WatchSnapshotStore")

protocol WatchSessionRouting: AnyObject, Sendable {
    var isReachable: Bool { get }
    var activationState: WCSessionActivationState { get }
    var isCompanionAppInstalled: Bool { get }

    func sendMessage(_ message: [String: Any], errorHandler: ((Error) -> Void)?)
    func enqueueUserInfo(_ userInfo: [String: Any])
}

extension WCSession: WatchSessionRouting, @retroactive @unchecked Sendable {
    func sendMessage(_ message: [String: Any], errorHandler: ((Error) -> Void)?) {
        sendMessage(message, replyHandler: nil, errorHandler: errorHandler)
    }

    func enqueueUserInfo(_ userInfo: [String: Any]) {
        transferUserInfo(userInfo)
    }
}

// MARK: - Watch Snapshot Store
// Source of truth: life_os_watchos_spec.md §3

@MainActor
final class WatchSnapshotStore: NSObject, ObservableObject {
    @Published private(set) var snapshot: WatchSnapshot?
    @Published private(set) var isReachable: Bool = false
    @Published private(set) var lightweightActionAvailability: WatchOpenOnIPhoneAvailability = .unavailable
    @Published private(set) var openOnIPhoneAvailability: WatchOpenOnIPhoneAvailability = .unavailable
    @Published private(set) var isCurrentNextBestActionPending: Bool = false
    @Published private(set) var lastActionFeedback: WatchActionFeedback?

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private var feedbackResetTask: Task<Void, Never>?

    override init() {
        super.init()
        activate()
    }

    init(activatesSession: Bool) {
        super.init()
        if activatesSession {
            activate()
        }
    }

    // MARK: - Activation

    private func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()

        // Restore last known snapshot from application context
        if let data = session.receivedApplicationContext["snapshot"] as? Data {
            applySnapshot(data)
        }

        refreshConnectivityState(for: session)
    }

    // MARK: - Snapshot Handling

    private func applySnapshot(_ data: Data) {
        if let decoded = try? decoder.decode(WatchSnapshot.self, from: data) {
            snapshot = decoded
            reconcilePendingLightweightActionState(for: decoded)
            setActionFeedback(nil)
            return
        }

        if let legacy = try? decoder.decode(LegacyWatchSnapshot.self, from: data) {
            let currentSnapshot = legacy.asCurrentSnapshot
            snapshot = currentSnapshot
            reconcilePendingLightweightActionState(for: currentSnapshot)
            setActionFeedback(nil)
        }
    }

    // MARK: - Lightweight Actions (§1.3)

    /// Send a watch action back to the iPhone via WCSession.
    /// Lightweight mutations use `sendMessage`; "open on iPhone" may fall back to queued delivery.
    func sendAction(_ action: WatchAction) {
        guard WCSession.isSupported() else {
            setActionFeedback(Self.unsupportedFeedback(for: action))
            return
        }

        let session = WCSession.default

        switch action {
        case .openOnIphone(let deepLink):
            routeOpenOnIPhone(deepLink: deepLink, session: session)

        case .supplementTaken, .insightAcknowledge:
            routeLightweightAction(action, session: session)
        }
    }

    private func routeOpenOnIPhone(deepLink: String?, session: any WatchSessionRouting) {
        setActionFeedback(nil)
        let resolvedDeepLink = Self.resolvedDeepLink(from: deepLink)
        let message: [String: Any] = [
            "action": "open_on_iphone",
            "deep_link": resolvedDeepLink
        ]

        if session.isReachable {
            session.sendMessage(message, errorHandler: { error in
                watchSnapshotStoreLogger.error("Watch action send failed: \(error.localizedDescription, privacy: .public)")

                Task { @MainActor in
                    if Self.resolveOpenOnIPhoneAvailability(for: session) == .queued {
                        session.enqueueUserInfo([
                            "action": "open_on_iphone",
                            "deep_link": resolvedDeepLink
                        ])
                        self.setActionFeedback(.openOnIPhoneQueued)
                    } else {
                        self.setActionFeedback(.openOnIPhoneUnavailable)
                    }
                    self.refreshConnectivityState(for: session)
                }
            })
            return
        }

        guard Self.resolveOpenOnIPhoneAvailability(for: session) == .queued else {
            setActionFeedback(.openOnIPhoneUnavailable)
            refreshConnectivityState(for: session)
            return
        }

        session.enqueueUserInfo(message)
        setActionFeedback(.openOnIPhoneQueued)
        refreshConnectivityState(for: session)
    }

    private func routeLightweightAction(_ action: WatchAction, session: any WatchSessionRouting) {
        setActionFeedback(nil)
        let availability = Self.resolveQueuedActionAvailability(for: session)
        let actionSignature = Self.lightweightActionSignature(for: action)

        if let actionSignature,
           Self.pendingLightweightActionSignatures().contains(actionSignature) {
            isCurrentNextBestActionPending = true
            setActionFeedback(.lightweightActionQueued)
            refreshConnectivityState(for: session)
            return
        }

        let actionId = UUID()
        let message = messagePayload(for: action, actionId: actionId)

        if session.isReachable {
            session.sendMessage(message, errorHandler: { error in
                watchSnapshotStoreLogger.error("Watch action send failed: \(error.localizedDescription, privacy: .public)")

                Task { @MainActor in
                    if Self.resolveQueuedActionAvailability(for: session) == .queued {
                        self.queueLightweightAction(
                            message,
                            actionSignature: actionSignature,
                            session: session
                        )
                    } else {
                        self.setActionFeedback(.lightweightActionUnavailable)
                        self.refreshConnectivityState(for: session)
                    }
                }
            })
            return
        }

        guard availability == .queued else {
            setActionFeedback(.lightweightActionUnavailable)
            refreshConnectivityState(for: session)
            return
        }

        queueLightweightAction(message, actionSignature: actionSignature, session: session)
    }

    private func queueLightweightAction(
        _ message: [String: Any],
        actionSignature: String?,
        session: any WatchSessionRouting
    ) {
        session.enqueueUserInfo(message)
        if let actionSignature {
            Self.enqueuePendingLightweightActionSignature(actionSignature)
        }
        reconcilePendingLightweightActionState(for: snapshot)
        setActionFeedback(.lightweightActionQueued)
        refreshConnectivityState(for: session)
    }

    private func messagePayload(for action: WatchAction, actionId: UUID? = nil) -> [String: Any] {
        switch action {
        case .supplementTaken(let name, let scheduledTime):
            var message: [String: Any] = ["action": "supplement_taken"]
            if let actionId { message["action_id"] = actionId.uuidString.lowercased() }
            if let name { message["supplement_name"] = name }
            if let scheduledTime { message["scheduled_time"] = scheduledTime }
            return message

        case .insightAcknowledge(let insightId):
            var message: [String: Any] = ["action": "insight_acknowledge"]
            if let actionId { message["action_id"] = actionId.uuidString.lowercased() }
            if let insightId { message["insight_id"] = insightId }
            return message

        case .openOnIphone(let deepLink):
            return [
                "action": "open_on_iphone",
                "deep_link": Self.resolvedDeepLink(from: deepLink)
            ]
        }
    }

    private func refreshConnectivityState(for session: any WatchSessionRouting) {
        applyReachabilityState(
            isReachable: session.isReachable,
            activationState: session.activationState,
            isCompanionAppInstalled: session.isCompanionAppInstalled
        )
    }

    private func setActionFeedback(_ feedback: WatchActionFeedback?) {
        feedbackResetTask?.cancel()
        lastActionFeedback = feedback

        guard let feedback else { return }
        feedbackResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, self.lastActionFeedback == feedback else { return }
            self.lastActionFeedback = nil
        }
    }

    private func reconcilePendingLightweightActionState(for snapshot: WatchSnapshot?) {
        var pendingSignatures = Self.pendingLightweightActionSignatures()
        let currentSignature = Self.lightweightActionSignature(from: snapshot?.nextBestAction)

        if let currentSignature {
            pendingSignatures = pendingSignatures.filter { $0 == currentSignature }
        } else {
            pendingSignatures = []
        }

        Self.writePendingLightweightActionSignatures(pendingSignatures)
        isCurrentNextBestActionPending = currentSignature.map { pendingSignatures.contains($0) } ?? false
    }

    private func applyIncomingPayload(_ payload: [String: Any]) {
        applyIncomingSnapshotData(payload["snapshot"] as? Data)
    }

    private func applyIncomingSnapshotData(_ data: Data?) {
        guard let data else { return }
        applySnapshot(data)
    }

    private func applyReachabilityState(
        isReachable: Bool,
        activationState: WCSessionActivationState,
        isCompanionAppInstalled: Bool
    ) {
        self.isReachable = isReachable
        let availability = Self.resolveOpenOnIPhoneAvailability(
            isReachable: isReachable,
            activationState: activationState,
            isCompanionAppInstalled: isCompanionAppInstalled
        )
        lightweightActionAvailability = availability
        openOnIPhoneAvailability = availability
    }

    nonisolated private func deliverIncomingSnapshotData(_ data: Data?) {
        Task { @MainActor in
            applyIncomingSnapshotData(data)
        }
    }

    nonisolated private func deliverReachabilityState(
        isReachable: Bool,
        activationState: WCSessionActivationState,
        isCompanionAppInstalled: Bool
    ) {
        Task { @MainActor in
            applyReachabilityState(
                isReachable: isReachable,
                activationState: activationState,
                isCompanionAppInstalled: isCompanionAppInstalled
            )
        }
    }

    nonisolated private static func unsupportedFeedback(for action: WatchAction) -> WatchActionFeedback {
        switch action {
        case .openOnIphone:
            return .openOnIPhoneUnavailable
        case .supplementTaken, .insightAcknowledge:
            return .lightweightActionUnavailable
        }
    }

    nonisolated private static func resolveQueuedActionAvailability(for session: any WatchSessionRouting) -> WatchOpenOnIPhoneAvailability {
        resolveQueuedActionAvailability(
            isReachable: session.isReachable,
            activationState: session.activationState,
            isCompanionAppInstalled: session.isCompanionAppInstalled
        )
    }

    nonisolated private static func resolveOpenOnIPhoneAvailability(for session: any WatchSessionRouting) -> WatchOpenOnIPhoneAvailability {
        resolveQueuedActionAvailability(for: session)
    }

    nonisolated private static func resolveOpenOnIPhoneAvailability(
        isReachable: Bool,
        activationState: WCSessionActivationState,
        isCompanionAppInstalled: Bool
    ) -> WatchOpenOnIPhoneAvailability {
        resolveQueuedActionAvailability(
            isReachable: isReachable,
            activationState: activationState,
            isCompanionAppInstalled: isCompanionAppInstalled
        )
    }

    nonisolated private static func resolveQueuedActionAvailability(
        isReachable: Bool,
        activationState: WCSessionActivationState,
        isCompanionAppInstalled: Bool
    ) -> WatchOpenOnIPhoneAvailability {
        if isReachable {
            return .immediate
        }

        guard activationState == .activated, isCompanionAppInstalled else {
            return .unavailable
        }

        return .queued
    }

    nonisolated private static func resolvedDeepLink(from deepLink: String?) -> String {
        let trimmed = deepLink?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }

        return "lifeos://home"
    }

    nonisolated private static func lightweightActionSignature(for action: WatchAction) -> String? {
        switch action {
        case .supplementTaken(let name, let scheduledTime):
            let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !normalizedName.isEmpty else { return nil }
            let normalizedScheduledTime = scheduledTime?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            return "supplement_taken|\(normalizedName.lowercased())|\(normalizedScheduledTime)"

        case .insightAcknowledge(let insightId):
            let normalizedInsightId = insightId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !normalizedInsightId.isEmpty else { return nil }
            return "insight_acknowledge|\(normalizedInsightId.lowercased())"

        case .openOnIphone:
            return nil
        }
    }

    nonisolated private static func lightweightActionSignature(
        from nextBestAction: WatchSnapshot.NextBestAction?
    ) -> String? {
        guard let nextBestAction else { return nil }

        switch nextBestAction.type {
        case "supplement_taken":
            return lightweightActionSignature(
                for: .supplementTaken(
                    name: nextBestAction.payload?.supplementName,
                    scheduledTime: nextBestAction.payload?.scheduledTime
                )
            )
        case "insight_acknowledge":
            return lightweightActionSignature(
                for: .insightAcknowledge(
                    insightId: nextBestAction.payload?.insightId
                )
            )
        default:
            return nil
        }
    }

    nonisolated private static func pendingLightweightActionSignatures(
        defaults: UserDefaults = .standard
    ) -> [String] {
        defaults.stringArray(forKey: watchPendingLightweightActionsDefaultsKey) ?? []
    }

    nonisolated private static func writePendingLightweightActionSignatures(
        _ signatures: [String],
        defaults: UserDefaults = .standard
    ) {
        if signatures.isEmpty {
            defaults.removeObject(forKey: watchPendingLightweightActionsDefaultsKey)
            return
        }

        defaults.set(signatures, forKey: watchPendingLightweightActionsDefaultsKey)
    }

    nonisolated private static func enqueuePendingLightweightActionSignature(
        _ signature: String,
        defaults: UserDefaults = .standard
    ) {
        var signatures = pendingLightweightActionSignatures(defaults: defaults)
        if !signatures.contains(signature) {
            signatures.append(signature)
        }
        writePendingLightweightActionSignatures(signatures, defaults: defaults)
    }
}

#if DEBUG
extension WatchSnapshotStore {
    func _testApplySnapshot(_ data: Data) {
        applySnapshot(data)
    }

    func _testSetActionFeedback(_ feedback: WatchActionFeedback?) {
        setActionFeedback(feedback)
    }

    func _testMessagePayload(
        for action: WatchAction,
        actionId: UUID? = nil
    ) -> [String: Any] {
        messagePayload(for: action, actionId: actionId)
    }

    func _testReconcilePendingLightweightActionState(for snapshot: WatchSnapshot?) {
        reconcilePendingLightweightActionState(for: snapshot)
    }

    func _testApplyIncomingPayload(_ payload: [String: Any]) {
        applyIncomingPayload(payload)
    }

    func _testRouteOpenOnIPhone(
        deepLink: String?,
        session: any WatchSessionRouting
    ) {
        routeOpenOnIPhone(deepLink: deepLink, session: session)
    }

    func _testRouteLightweightAction(
        _ action: WatchAction,
        session: any WatchSessionRouting
    ) {
        routeLightweightAction(action, session: session)
    }

    func _testApplyReachabilityState(
        isReachable: Bool,
        activationState: WCSessionActivationState,
        isCompanionAppInstalled: Bool
    ) {
        applyReachabilityState(
            isReachable: isReachable,
            activationState: activationState,
            isCompanionAppInstalled: isCompanionAppInstalled
        )
    }

    func _testDeliverIncomingSnapshotData(_ data: Data?) async {
        deliverIncomingSnapshotData(data)
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    func _testDeliverReachabilityState(
        isReachable: Bool,
        activationState: WCSessionActivationState,
        isCompanionAppInstalled: Bool
    ) async {
        deliverReachabilityState(
            isReachable: isReachable,
            activationState: activationState,
            isCompanionAppInstalled: isCompanionAppInstalled
        )
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    static func _testResolveQueuedActionAvailability(
        isReachable: Bool,
        activationState: WCSessionActivationState,
        isCompanionAppInstalled: Bool
    ) -> WatchOpenOnIPhoneAvailability {
        resolveQueuedActionAvailability(
            isReachable: isReachable,
            activationState: activationState,
            isCompanionAppInstalled: isCompanionAppInstalled
        )
    }

    static func _testResolveOpenOnIPhoneAvailability(
        isReachable: Bool,
        activationState: WCSessionActivationState,
        isCompanionAppInstalled: Bool
    ) -> WatchOpenOnIPhoneAvailability {
        resolveOpenOnIPhoneAvailability(
            isReachable: isReachable,
            activationState: activationState,
            isCompanionAppInstalled: isCompanionAppInstalled
        )
    }

    static func _testResolvedDeepLink(from deepLink: String?) -> String {
        resolvedDeepLink(from: deepLink)
    }

    static func _testLightweightActionSignature(for action: WatchAction) -> String? {
        lightweightActionSignature(for: action)
    }

    static func _testLightweightActionSignature(
        from nextBestAction: WatchSnapshot.NextBestAction?
    ) -> String? {
        lightweightActionSignature(from: nextBestAction)
    }

    static func _testPendingLightweightActionSignatures(
        defaults: UserDefaults
    ) -> [String] {
        pendingLightweightActionSignatures(defaults: defaults)
    }

    static func _testWritePendingLightweightActionSignatures(
        _ signatures: [String],
        defaults: UserDefaults
    ) {
        writePendingLightweightActionSignatures(signatures, defaults: defaults)
    }

    static func _testEnqueuePendingLightweightActionSignature(
        _ signature: String,
        defaults: UserDefaults
    ) {
        enqueuePendingLightweightActionSignature(signature, defaults: defaults)
    }

    static func _testUnsupportedFeedback(for action: WatchAction) -> WatchActionFeedback {
        unsupportedFeedback(for: action)
    }
}
#endif

enum WatchOpenOnIPhoneAvailability: Equatable, Sendable {
    case immediate
    case queued
    case unavailable
}

enum WatchActionFeedback: Equatable, Sendable {
    case openOnIPhoneQueued
    case openOnIPhoneUnavailable
    case lightweightActionQueued
    case lightweightActionUnavailable
}

// MARK: - WCSessionDelegate

extension WatchSnapshotStore: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        deliverReachabilityState(
            isReachable: session.isReachable,
            activationState: activationState,
            isCompanionAppInstalled: session.isCompanionAppInstalled
        )
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        deliverIncomingSnapshotData(userInfo["snapshot"] as? Data)
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        deliverIncomingSnapshotData(applicationContext["snapshot"] as? Data)
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        deliverReachabilityState(
            isReachable: session.isReachable,
            activationState: session.activationState,
            isCompanionAppInstalled: session.isCompanionAppInstalled
        )
    }
}

private struct LegacyWatchSnapshot: Codable {
    struct SupplementsDueSoon: Codable {
        var time: String
        var count: Int
    }

    var date: String?
    var recoveryScore: Double?
    var recoveryZone: String?
    var confidenceScore: Double?
    var nextBestActionType: String?
    var nextBestActionCopyId: String?
    var nextBestActionDeepLink: String?
    var sleepDurationHours: Double?
    var sleepQualityPercent: Double?
    var nutritionAdherencePercent: Double?
    var supplementsDueSoon: SupplementsDueSoon?
    var updatedAt: Date
    var wasTruncated: Bool

    var asCurrentSnapshot: WatchSnapshot {
        WatchSnapshot(
            date: date,
            lastUpdatedAt: updatedAt,
            recoveryScore: recoveryScore,
            recoveryZone: recoveryZone,
            confidenceScore: confidenceScore,
            nextBestAction: nextBestActionType.map { type in
                WatchSnapshot.NextBestAction(
                    type: type,
                    labelCopyId: nextBestActionCopyId ?? "watch.action.open_on_iphone",
                    payload: WatchSnapshot.NextBestAction.Payload(
                        deepLink: nextBestActionDeepLink,
                        supplementName: nil,
                        scheduledTime: nil,
                        insightId: nil,
                        date: nil
                    )
                )
            },
            sleepDurationHours: sleepDurationHours,
            sleepQualityPercent: sleepQualityPercent,
            nutritionAdherencePercent: nutritionAdherencePercent,
            supplementsDueSoon: supplementsDueSoon.map { .init(time: $0.time, count: $0.count) },
            wasTruncated: wasTruncated
        )
    }
}
