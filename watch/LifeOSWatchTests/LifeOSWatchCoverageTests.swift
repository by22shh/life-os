import SwiftUI
import WatchConnectivity
import WidgetKit
import XCTest
@testable import LifeOSComplications
@testable import LifeOSWatch

private struct LegacyWatchSnapshotPayload: Codable {
    struct SupplementsDueSoon: Codable {
        let time: String
        let count: Int
    }

    let date: String?
    let recoveryScore: Double?
    let recoveryZone: String?
    let confidenceScore: Double?
    let nextBestActionType: String?
    let nextBestActionCopyId: String?
    let nextBestActionDeepLink: String?
    let sleepDurationHours: Double?
    let sleepQualityPercent: Double?
    let nutritionAdherencePercent: Double?
    let supplementsDueSoon: SupplementsDueSoon?
    let updatedAt: Date
    let wasTruncated: Bool
}

private struct ComplicationSnapshotPayload: Codable {
    var lastUpdatedAt: String = ISO8601DateFormatter().string(from: Date())
    let recoveryScore: Double?
    let recoveryZone: String?

    enum CodingKeys: String, CodingKey {
        case lastUpdatedAt = "last_updated_at"
        case recoveryScore = "recovery_score"
        case recoveryZone = "recovery_zone"
    }
}

private enum TestWatchSessionError: Error {
    case sendFailed
}

private final class TestWatchSession: WatchSessionRouting, @unchecked Sendable {
    var isReachable: Bool
    var activationState: WCSessionActivationState
    var isCompanionAppInstalled: Bool
    var stateAfterSendFailure: (
        isReachable: Bool,
        activationState: WCSessionActivationState,
        isCompanionAppInstalled: Bool
    )?
    var sendError: Error?
    private(set) var sentMessages: [[String: Any]] = []
    private(set) var transferredUserInfo: [[String: Any]] = []

    init(
        isReachable: Bool,
        activationState: WCSessionActivationState,
        isCompanionAppInstalled: Bool
    ) {
        self.isReachable = isReachable
        self.activationState = activationState
        self.isCompanionAppInstalled = isCompanionAppInstalled
    }

    func sendMessage(_ message: [String: Any], errorHandler: ((Error) -> Void)?) {
        sentMessages.append(message)
        guard let sendError else { return }
        if let stateAfterSendFailure {
            isReachable = stateAfterSendFailure.isReachable
            activationState = stateAfterSendFailure.activationState
            isCompanionAppInstalled = stateAfterSendFailure.isCompanionAppInstalled
        }
        errorHandler?(sendError)
    }

    func enqueueUserInfo(_ userInfo: [String: Any]) {
        transferredUserInfo.append(userInfo)
    }
}

final class LifeOSWatchCoverageTests: XCTestCase {
    private let pendingActionsKey = "watch.pending_lightweight_actions"
    private let complicationSnapshotKey = "latestSnapshot"

    func testComplicationDoesNotPresentStaleOrUndatedScoresAsCurrent() throws {
        let suite = "watch.freshness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = RecoveryTimelineProvider()
        var payload = ComplicationSnapshotPayload(recoveryScore: 89, recoveryZone: "optimal")
        payload.lastUpdatedAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-48 * 3600))
        defaults.set(try JSONEncoder().encode(payload), forKey: "latestSnapshot")
        XCTAssertNil(provider._testLoadCurrentEntry(defaults: defaults))
        XCTAssertNil(provider._testSnapshotEntry(defaults: defaults).score)
        defaults.set(Data("{\"recovery_score\":89,\"recovery_zone\":\"optimal\"}".utf8), forKey: "latestSnapshot")
        XCTAssertNil(provider._testLoadCurrentEntry(defaults: defaults))
    }

    override func setUp() {
        super.setUp()
        clearStandardPendingActions()
    }

    override func tearDown() {
        clearStandardPendingActions()
        super.tearDown()
    }

    @MainActor
    func testWatchSnapshotStoreHooksDecodeSnapshotsAndManagePendingActions() throws {
        XCTAssertEqual(
            WatchSnapshotStore._testResolvedDeepLink(from: nil),
            "lifeos://home"
        )
        XCTAssertEqual(
            WatchSnapshotStore._testResolvedDeepLink(from: "  lifeos://sleep  "),
            "lifeos://sleep"
        )
        XCTAssertEqual(
            WatchSnapshotStore._testResolveQueuedActionAvailability(
                isReachable: true,
                activationState: .notActivated,
                isCompanionAppInstalled: false
            ),
            .immediate
        )
        XCTAssertEqual(
            WatchSnapshotStore._testResolveQueuedActionAvailability(
                isReachable: false,
                activationState: .activated,
                isCompanionAppInstalled: true
            ),
            .queued
        )
        XCTAssertEqual(
            WatchSnapshotStore._testResolveOpenOnIPhoneAvailability(
                isReachable: false,
                activationState: .notActivated,
                isCompanionAppInstalled: false
            ),
            .unavailable
        )
        XCTAssertEqual(
            WatchSnapshotStore._testLightweightActionSignature(
                for: .supplementTaken(name: " Magnesium ", scheduledTime: " 21:00 ")
            ),
            "supplement_taken|magnesium|21:00"
        )
        XCTAssertEqual(
            WatchSnapshotStore._testLightweightActionSignature(
                for: .insightAcknowledge(insightId: " Insight-1 ")
            ),
            "insight_acknowledge|insight-1"
        )
        XCTAssertEqual(
            WatchSnapshotStore._testLightweightActionSignature(
                from: WatchSnapshot.NextBestAction(
                    type: "supplement_taken",
                    labelCopyId: "watch.action.supplement_taken",
                    payload: WatchSnapshot.NextBestAction.Payload(
                        deepLink: nil,
                        supplementName: "Magnesium",
                        scheduledTime: "21:00",
                        insightId: nil,
                        date: nil
                    )
                )
            ),
            "supplement_taken|magnesium|21:00"
        )
        XCTAssertEqual(
            WatchSnapshotStore._testLightweightActionSignature(
                from: WatchSnapshot.NextBestAction(
                    type: "insight_acknowledge",
                    labelCopyId: "watch.action.acknowledge",
                    payload: WatchSnapshot.NextBestAction.Payload(
                        deepLink: nil,
                        supplementName: nil,
                        scheduledTime: nil,
                        insightId: "Insight-1",
                        date: nil
                    )
                )
            ),
            "insight_acknowledge|insight-1"
        )
        XCTAssertNil(
            WatchSnapshotStore._testLightweightActionSignature(
                from: WatchSnapshot.NextBestAction(
                    type: "open_on_iphone",
                    labelCopyId: "watch.action.open_sleep",
                    payload: WatchSnapshot.NextBestAction.Payload(
                        deepLink: "lifeos://sleep",
                        supplementName: nil,
                        scheduledTime: nil,
                        insightId: nil,
                        date: nil
                    )
                )
            )
        )
        XCTAssertNil(
            WatchSnapshotStore._testLightweightActionSignature(
                for: .openOnIphone(deepLink: nil)
            )
        )

        WatchSnapshotStore._testWritePendingLightweightActionSignatures([], defaults: .standard)
        WatchSnapshotStore._testEnqueuePendingLightweightActionSignature(
            "supplement_taken|magnesium|21:00",
            defaults: .standard
        )
        WatchSnapshotStore._testEnqueuePendingLightweightActionSignature(
            "supplement_taken|magnesium|21:00",
            defaults: .standard
        )
        XCTAssertEqual(
            WatchSnapshotStore._testPendingLightweightActionSignatures(defaults: .standard),
            ["supplement_taken|magnesium|21:00"]
        )

        let currentSnapshot = WatchSnapshot(
            date: "2026-03-19",
            lastUpdatedAt: Date(timeIntervalSince1970: 1_710_836_400),
            recoveryScore: 78,
            recoveryZone: "ready",
            confidenceScore: 0.52,
            nextBestAction: WatchSnapshot.NextBestAction(
                type: "supplement_taken",
                labelCopyId: "watch.action.supplement_taken",
                payload: WatchSnapshot.NextBestAction.Payload(
                    deepLink: "lifeos://supplements",
                    supplementName: "Magnesium",
                    scheduledTime: "21:00",
                    insightId: nil,
                    date: nil
                )
            ),
            sleepDurationHours: 7.4,
            sleepQualityPercent: 86,
            nutritionAdherencePercent: 91,
            supplementsDueSoon: WatchSnapshot.SupplementsDueSoon(time: "21:00", count: 2),
            wasTruncated: false
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let currentData = try encoder.encode(currentSnapshot)

        let store = WatchSnapshotStore(activatesSession: false)
        store._testApplySnapshot(currentData)
        XCTAssertEqual(store.snapshot?.recoveryZone, "ready")
        XCTAssertEqual(store.snapshot?.nextBestAction?.payload?.supplementName, "Magnesium")
        XCTAssertTrue(store.isCurrentNextBestActionPending)
        XCTAssertNil(store.lastActionFeedback)

        store._testSetActionFeedback(.lightweightActionQueued)
        XCTAssertEqual(store.lastActionFeedback, .lightweightActionQueued)
        store._testSetActionFeedback(nil)
        XCTAssertNil(store.lastActionFeedback)

        let legacyEncoder = JSONEncoder()
        legacyEncoder.dateEncodingStrategy = .iso8601
        let legacyData = try legacyEncoder.encode(
            LegacyWatchSnapshotPayload(
                date: "2026-03-18",
                recoveryScore: 63,
                recoveryZone: "caution",
                confidenceScore: 0.9,
                nextBestActionType: "open_sleep",
                nextBestActionCopyId: "watch.action.open_sleep",
                nextBestActionDeepLink: "lifeos://sleep",
                sleepDurationHours: 6.2,
                sleepQualityPercent: 74,
                nutritionAdherencePercent: 80,
                supplementsDueSoon: LegacyWatchSnapshotPayload.SupplementsDueSoon(
                    time: "08:00",
                    count: 1
                ),
                updatedAt: Date(timeIntervalSince1970: 1_710_750_000),
                wasTruncated: true
            )
        )

        store._testApplySnapshot(legacyData)
        XCTAssertEqual(store.snapshot?.recoveryZone, "caution")
        XCTAssertEqual(store.snapshot?.nextBestAction?.payload?.deepLink, "lifeos://sleep")
        XCTAssertEqual(store.snapshot?.supplementsDueSoon?.count, 1)
        XCTAssertEqual(store.snapshot?.wasTruncated, true)
    }

    @MainActor
    func testWatchSnapshotStorePayloadReachabilityAndIncomingPayloadHelpers() throws {
        let store = WatchSnapshotStore(activatesSession: false)
        let actionId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

        let supplementPayload = store._testMessagePayload(
            for: .supplementTaken(name: "Magnesium", scheduledTime: "21:00"),
            actionId: actionId
        )
        XCTAssertEqual(supplementPayload["action"] as? String, "supplement_taken")
        XCTAssertEqual(supplementPayload["action_id"] as? String, actionId.uuidString.lowercased())
        XCTAssertEqual(supplementPayload["supplement_name"] as? String, "Magnesium")
        XCTAssertEqual(supplementPayload["scheduled_time"] as? String, "21:00")

        let insightPayload = store._testMessagePayload(
            for: .insightAcknowledge(insightId: "insight-1"),
            actionId: actionId
        )
        XCTAssertEqual(insightPayload["action"] as? String, "insight_acknowledge")
        XCTAssertEqual(insightPayload["insight_id"] as? String, "insight-1")

        let openPayload = store._testMessagePayload(for: .openOnIphone(deepLink: "lifeos://sleep"))
        XCTAssertEqual(openPayload["action"] as? String, "open_on_iphone")
        XCTAssertEqual(openPayload["deep_link"] as? String, "lifeos://sleep")

        XCTAssertEqual(
            WatchSnapshotStore._testUnsupportedFeedback(for: .openOnIphone(deepLink: nil)),
            .openOnIPhoneUnavailable
        )
        XCTAssertEqual(
            WatchSnapshotStore._testUnsupportedFeedback(
                for: .supplementTaken(name: "Magnesium", scheduledTime: "21:00")
            ),
            .lightweightActionUnavailable
        )

        store._testApplyReachabilityState(
            isReachable: true,
            activationState: .notActivated,
            isCompanionAppInstalled: false
        )
        XCTAssertTrue(store.isReachable)
        XCTAssertEqual(store.lightweightActionAvailability, .immediate)
        XCTAssertEqual(store.openOnIPhoneAvailability, .immediate)

        store._testApplyReachabilityState(
            isReachable: false,
            activationState: .activated,
            isCompanionAppInstalled: true
        )
        XCTAssertFalse(store.isReachable)
        XCTAssertEqual(store.lightweightActionAvailability, .queued)
        XCTAssertEqual(store.openOnIPhoneAvailability, .queued)

        store._testApplyReachabilityState(
            isReachable: false,
            activationState: .notActivated,
            isCompanionAppInstalled: false
        )
        XCTAssertEqual(store.lightweightActionAvailability, .unavailable)
        XCTAssertEqual(store.openOnIPhoneAvailability, .unavailable)

        let snapshot = WatchSnapshot(
            date: "2026-03-19",
            lastUpdatedAt: Date(timeIntervalSince1970: 1_710_836_400),
            recoveryScore: 74,
            recoveryZone: "optimal",
            confidenceScore: 0.41,
            nextBestAction: WatchSnapshot.NextBestAction(
                type: "open_on_iphone",
                labelCopyId: "watch.action.open_sleep",
                payload: WatchSnapshot.NextBestAction.Payload(
                    deepLink: "lifeos://sleep",
                    supplementName: nil,
                    scheduledTime: nil,
                    insightId: nil,
                    date: nil
                )
            ),
            sleepDurationHours: 7.2,
            sleepQualityPercent: 83,
            nutritionAdherencePercent: 87,
            supplementsDueSoon: nil,
            wasTruncated: false
        )

        WatchSnapshotStore._testWritePendingLightweightActionSignatures(
            ["supplement_taken|magnesium|21:00"],
            defaults: .standard
        )
        store._testReconcilePendingLightweightActionState(for: snapshot)
        XCTAssertFalse(store.isCurrentNextBestActionPending)
        XCTAssertEqual(
            WatchSnapshotStore._testPendingLightweightActionSignatures(defaults: .standard),
            []
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        store._testApplyIncomingPayload([:])
        XCTAssertNil(store.snapshot)
        store._testApplyIncomingPayload(["snapshot": data])
        XCTAssertEqual(store.snapshot?.recoveryZone, "optimal")
        XCTAssertEqual(store.snapshot?.nextBestAction?.payload?.deepLink, "lifeos://sleep")
    }

    @MainActor
    func testWatchSnapshotStoreRoutesActionsAcrossSendQueueAndUnavailableBranches() {
        let store = WatchSnapshotStore(activatesSession: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let openQueuedSession = TestWatchSession(
            isReachable: false,
            activationState: .activated,
            isCompanionAppInstalled: true
        )
        store._testRouteOpenOnIPhone(deepLink: "lifeos://sleep", session: openQueuedSession)
        XCTAssertEqual(openQueuedSession.transferredUserInfo.count, 1)
        XCTAssertEqual(openQueuedSession.transferredUserInfo.first?["action"] as? String, "open_on_iphone")
        XCTAssertEqual(store.lastActionFeedback, .openOnIPhoneQueued)
        XCTAssertEqual(store.openOnIPhoneAvailability, .queued)

        let openUnavailableSession = TestWatchSession(
            isReachable: false,
            activationState: .notActivated,
            isCompanionAppInstalled: false
        )
        store._testRouteOpenOnIPhone(deepLink: nil, session: openUnavailableSession)
        XCTAssertTrue(openUnavailableSession.transferredUserInfo.isEmpty)
        XCTAssertEqual(store.lastActionFeedback, .openOnIPhoneUnavailable)
        XCTAssertEqual(store.openOnIPhoneAvailability, .unavailable)

        let openFailureQueuedSession = TestWatchSession(
            isReachable: true,
            activationState: .activated,
            isCompanionAppInstalled: true
        )
        openFailureQueuedSession.sendError = TestWatchSessionError.sendFailed
        openFailureQueuedSession.stateAfterSendFailure = (
            isReachable: false,
            activationState: .activated,
            isCompanionAppInstalled: true
        )
        store._testRouteOpenOnIPhone(deepLink: "lifeos://journal", session: openFailureQueuedSession)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        XCTAssertEqual(openFailureQueuedSession.sentMessages.count, 1)
        XCTAssertEqual(openFailureQueuedSession.transferredUserInfo.count, 1)
        XCTAssertEqual(store.lastActionFeedback, .openOnIPhoneQueued)
        XCTAssertEqual(store.openOnIPhoneAvailability, .queued)

        let profileOwnerId = UUID().uuidString
        let supplementId = UUID().uuidString
        let supplementSnapshot = WatchSnapshot(
            date: "2026-03-19",
            profileOwnerId: profileOwnerId,
            lastUpdatedAt: Date(timeIntervalSince1970: 1_710_836_400),
            recoveryScore: 82,
            recoveryZone: "optimal",
            confidenceScore: 0.58,
            nextBestAction: WatchSnapshot.NextBestAction(
                type: "supplement_taken",
                labelCopyId: "watch.action.supplement_taken",
                payload: WatchSnapshot.NextBestAction.Payload(
                    deepLink: nil,
                    supplementName: "Magnesium",
                    supplementId: supplementId,
                    scheduledTime: "21:00",
                    insightId: nil,
                    date: nil
                )
            ),
            sleepDurationHours: 8,
            sleepQualityPercent: 90,
            nutritionAdherencePercent: 93,
            supplementsDueSoon: nil,
            wasTruncated: false
        )
        store._testApplySnapshot(try! encoder.encode(supplementSnapshot))

        let queuedLightweightSession = TestWatchSession(
            isReachable: false,
            activationState: .activated,
            isCompanionAppInstalled: true
        )
        store._testRouteLightweightAction(
            .supplementTaken(name: "Magnesium", scheduledTime: "21:00"),
            session: queuedLightweightSession
        )
        XCTAssertEqual(queuedLightweightSession.transferredUserInfo.count, 1)
        XCTAssertEqual(
            queuedLightweightSession.transferredUserInfo.first?["action"] as? String,
            "supplement_taken"
        )
        XCTAssertEqual(
            queuedLightweightSession.transferredUserInfo.first?["profile_owner_id"] as? String,
            profileOwnerId
        )
        XCTAssertEqual(
            queuedLightweightSession.transferredUserInfo.first?["supplement_id"] as? String,
            supplementId
        )
        XCTAssertNotNil(queuedLightweightSession.transferredUserInfo.first?["occurred_at"] as? String)
        XCTAssertNotNil(queuedLightweightSession.transferredUserInfo.first?["occurred_timezone"] as? String)
        XCTAssertNotNil(queuedLightweightSession.transferredUserInfo.first?["occurred_local_date"] as? String)
        XCTAssertTrue(store.isCurrentNextBestActionPending)
        XCTAssertEqual(store.lastActionFeedback, .lightweightActionQueued)

        let duplicateQueuedSession = TestWatchSession(
            isReachable: false,
            activationState: .activated,
            isCompanionAppInstalled: true
        )
        store._testRouteLightweightAction(
            .supplementTaken(name: "Magnesium", scheduledTime: "21:00"),
            session: duplicateQueuedSession
        )
        XCTAssertTrue(duplicateQueuedSession.sentMessages.isEmpty)
        XCTAssertTrue(duplicateQueuedSession.transferredUserInfo.isEmpty)
        XCTAssertTrue(store.isCurrentNextBestActionPending)
        XCTAssertEqual(store.lastActionFeedback, .lightweightActionQueued)

        WatchSnapshotStore._testWritePendingLightweightActionSignatures([], defaults: .standard)
        store._testReconcilePendingLightweightActionState(for: nil)
        let insightSnapshot = WatchSnapshot(
            date: "2026-03-19",
            profileOwnerId: profileOwnerId,
            lastUpdatedAt: Date(timeIntervalSince1970: 1_710_836_400),
            recoveryScore: 67,
            recoveryZone: "caution",
            confidenceScore: 0.73,
            nextBestAction: WatchSnapshot.NextBestAction(
                type: "insight_acknowledge",
                labelCopyId: "watch.action.acknowledge",
                payload: WatchSnapshot.NextBestAction.Payload(
                    deepLink: nil,
                    supplementName: nil,
                    scheduledTime: nil,
                    insightId: "insight-42",
                    date: nil
                )
            ),
            sleepDurationHours: 6.6,
            sleepQualityPercent: 72,
            nutritionAdherencePercent: 84,
            supplementsDueSoon: nil,
            wasTruncated: false
        )
        store._testApplySnapshot(try! encoder.encode(insightSnapshot))

        let lightweightUnavailableSession = TestWatchSession(
            isReachable: false,
            activationState: .notActivated,
            isCompanionAppInstalled: false
        )
        store._testRouteLightweightAction(
            .insightAcknowledge(insightId: "insight-42"),
            session: lightweightUnavailableSession
        )
        XCTAssertTrue(lightweightUnavailableSession.sentMessages.isEmpty)
        XCTAssertTrue(lightweightUnavailableSession.transferredUserInfo.isEmpty)
        XCTAssertEqual(store.lastActionFeedback, .lightweightActionUnavailable)
        XCTAssertEqual(store.lightweightActionAvailability, .unavailable)

        let lightweightFailureQueuedSession = TestWatchSession(
            isReachable: true,
            activationState: .activated,
            isCompanionAppInstalled: true
        )
        lightweightFailureQueuedSession.sendError = TestWatchSessionError.sendFailed
        lightweightFailureQueuedSession.stateAfterSendFailure = (
            isReachable: false,
            activationState: .activated,
            isCompanionAppInstalled: true
        )
        store._testRouteLightweightAction(
            .insightAcknowledge(insightId: "insight-42"),
            session: lightweightFailureQueuedSession
        )
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        XCTAssertEqual(lightweightFailureQueuedSession.sentMessages.count, 1)
        XCTAssertEqual(lightweightFailureQueuedSession.transferredUserInfo.count, 1)
        XCTAssertEqual(store.lastActionFeedback, .lightweightActionQueued)
        XCTAssertEqual(store.lightweightActionAvailability, .queued)
        XCTAssertEqual(
            WatchSnapshotStore._testPendingLightweightActionSignatures(defaults: .standard),
            ["insight_acknowledge|insight-42"]
        )
    }

    @MainActor
    func testWatchSnapshotStoreDeliveryHelpersApplyAsyncStateChanges() async throws {
        let store = WatchSnapshotStore(activatesSession: false)
        let snapshot = WatchSnapshot(
            date: "2026-03-19",
            lastUpdatedAt: Date(timeIntervalSince1970: 1_710_836_400),
            recoveryScore: 80,
            recoveryZone: "ready",
            confidenceScore: 0.62,
            nextBestAction: nil,
            sleepDurationHours: 7.8,
            sleepQualityPercent: 89,
            nutritionAdherencePercent: 92,
            supplementsDueSoon: nil,
            wasTruncated: false
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)

        await store._testDeliverIncomingSnapshotData(data)
        XCTAssertEqual(store.snapshot?.recoveryScore, 80)

        await store._testDeliverReachabilityState(
            isReachable: false,
            activationState: .activated,
            isCompanionAppInstalled: true
        )
        XCTAssertEqual(store.lightweightActionAvailability, .queued)
        XCTAssertEqual(store.openOnIPhoneAvailability, .queued)
    }

    @MainActor
    func testWatchViewsAndZonesRenderAcrossBranches() {
        let supplementSnapshot = WatchSnapshot(
            date: "2026-03-19",
            lastUpdatedAt: Date(),
            recoveryScore: 81,
            recoveryZone: "optimal",
            confidenceScore: 0.51,
            nextBestAction: WatchSnapshot.NextBestAction(
                type: "supplement_taken",
                labelCopyId: "watch.action.supplement_taken",
                payload: WatchSnapshot.NextBestAction.Payload(
                    deepLink: nil,
                    supplementName: "Magnesium",
                    scheduledTime: "21:00",
                    insightId: nil,
                    date: nil
                )
            ),
            sleepDurationHours: 8,
            sleepQualityPercent: 88,
            nutritionAdherencePercent: 90,
            supplementsDueSoon: WatchSnapshot.SupplementsDueSoon(time: "21:00", count: 2),
            wasTruncated: true
        )
        let insightSnapshot = WatchSnapshot(
            date: "2026-03-19",
            lastUpdatedAt: Date(timeIntervalSinceNow: -7_200),
            recoveryScore: 58,
            recoveryZone: "critical",
            confidenceScore: 0.88,
            nextBestAction: WatchSnapshot.NextBestAction(
                type: "insight_acknowledge",
                labelCopyId: "watch.action.acknowledge",
                payload: WatchSnapshot.NextBestAction.Payload(
                    deepLink: nil,
                    supplementName: nil,
                    scheduledTime: nil,
                    insightId: "insight-42",
                    date: nil
                )
            ),
            sleepDurationHours: nil,
            sleepQualityPercent: nil,
            nutritionAdherencePercent: nil,
            supplementsDueSoon: nil,
            wasTruncated: false
        )
        let openOnPhoneSnapshot = WatchSnapshot(
            date: "2026-03-19",
            lastUpdatedAt: Date(),
            recoveryScore: 72,
            recoveryZone: "ready",
            confidenceScore: 0.72,
            nextBestAction: WatchSnapshot.NextBestAction(
                type: "open_sleep",
                labelCopyId: "watch.action.open_sleep",
                payload: WatchSnapshot.NextBestAction.Payload(
                    deepLink: "lifeos://sleep",
                    supplementName: nil,
                    scheduledTime: nil,
                    insightId: nil,
                    date: nil
                )
            ),
            sleepDurationHours: nil,
            sleepQualityPercent: nil,
            nutritionAdherencePercent: nil,
            supplementsDueSoon: nil,
            wasTruncated: false
        )

        render(
            WatchHomeView(
                snapshot: nil,
                isReachable: false,
                lightweightActionAvailability: .unavailable,
                openOnIPhoneAvailability: .unavailable,
                isCurrentNextBestActionPending: false,
                actionFeedback: nil,
                onAction: { _ in }
            )
        )
        render(
            WatchHomeView(
                snapshot: supplementSnapshot,
                isReachable: false,
                lightweightActionAvailability: .queued,
                openOnIPhoneAvailability: .queued,
                isCurrentNextBestActionPending: true,
                actionFeedback: .lightweightActionQueued,
                onAction: { _ in }
            )
        )
        render(
            WatchHomeView(
                snapshot: insightSnapshot,
                isReachable: false,
                lightweightActionAvailability: .unavailable,
                openOnIPhoneAvailability: .queued,
                isCurrentNextBestActionPending: false,
                actionFeedback: .openOnIPhoneQueued,
                onAction: { _ in }
            )
        )
        render(
            WatchHomeView(
                snapshot: openOnPhoneSnapshot,
                isReachable: true,
                lightweightActionAvailability: .immediate,
                openOnIPhoneAvailability: .immediate,
                isCurrentNextBestActionPending: false,
                actionFeedback: .openOnIPhoneUnavailable,
                onAction: { _ in }
            )
        )

        XCTAssertEqual(WatchRecoveryZone.allCases.count, 4)
        XCTAssertEqual(WatchRecoveryZone.ready.iconName, "arrow.up.right.circle.fill")
        XCTAssertFalse(WatchRecoveryZone.optimal.label.isEmpty)
        XCTAssertFalse(WatchRecoveryZone.caution.accessibilityAnnouncement(score: 48).isEmpty)
        XCTAssertFalse(String(describing: WatchRecoveryZone.critical.color).isEmpty)

        _ = LifeOSWatchApp(testSnapshotStore: WatchSnapshotStore(activatesSession: false)).body
    }

    @MainActor
    func testComplicationHooksLoadSnapshotAndRenderFamilies() throws {
        let defaults = UserDefaults(suiteName: "LifeOSWatchCoverageTests.complication")!
        defaults.removeObject(forKey: complicationSnapshotKey)

        let provider = RecoveryTimelineProvider()
        XCTAssertNil(provider._testLoadCurrentEntry(defaults: defaults))
        XCTAssertNil(provider._testSnapshotEntry(defaults: defaults).score)
        XCTAssertNil(provider._testTimelineEntry(defaults: defaults).score)
        XCTAssertEqual(RecoveryComplicationEntry.placeholder.zone, "ready")
        XCTAssertNil(RecoveryComplicationEntry.empty.zone)

        let complicationData = try JSONEncoder().encode(
            ComplicationSnapshotPayload(recoveryScore: 69, recoveryZone: "ready")
        )
        defaults.set(complicationData, forKey: complicationSnapshotKey)

        let entry = try XCTUnwrap(provider._testLoadCurrentEntry(defaults: defaults))
        XCTAssertEqual(entry.score, 69)
        XCTAssertEqual(entry.zone, "ready")
        XCTAssertFalse(entry.zoneLabel.isEmpty)
        XCTAssertEqual(provider._testZoneIcon(for: "optimal"), "checkmark.circle.fill")
        XCTAssertEqual(provider._testZoneIcon(for: "ready"), "arrow.up.right.circle.fill")
        XCTAssertEqual(provider._testZoneIcon(for: "caution"), "exclamationmark.triangle.fill")
        XCTAssertFalse(provider._testZoneLabel(for: "unknown").isEmpty)
        XCTAssertFalse(provider._testZoneLabel(for: "ready").isEmpty)
        XCTAssertFalse(provider._testZoneLabel(for: "caution").isEmpty)
        XCTAssertEqual(provider._testSnapshotEntry(defaults: defaults).score, 69)
        XCTAssertEqual(provider._testTimelineEntry(defaults: defaults).score, 69)

        let criticalData = try JSONEncoder().encode(
            ComplicationSnapshotPayload(recoveryScore: nil, recoveryZone: nil)
        )
        defaults.set(criticalData, forKey: complicationSnapshotKey)
        XCTAssertNil(provider._testLoadCurrentEntry(defaults: defaults))
        let criticalEntry = provider._testTimelineEntry(defaults: defaults)
        XCTAssertNil(criticalEntry.score)
        XCTAssertNil(criticalEntry.zone)
        XCTAssertFalse(criticalEntry.zoneLabel.isEmpty)
        XCTAssertEqual(criticalEntry.zoneIcon, "questionmark.circle")

        render(CircularComplicationView(entry: entry), size: CGSize(width: 96, height: 96))
        render(RectangularComplicationView(entry: entry), size: CGSize(width: 180, height: 80))
        render(CornerComplicationView(entry: entry), size: CGSize(width: 96, height: 96))
        render(CircularComplicationView(entry: criticalEntry), size: CGSize(width: 96, height: 96))
        render(RectangularComplicationView(entry: criticalEntry), size: CGSize(width: 180, height: 80))
        render(CornerComplicationView(entry: criticalEntry), size: CGSize(width: 96, height: 96))
        render(
            RecoveryComplicationTestHooks.rootView(
                entry: entry,
                family: .accessoryCircular
            ),
            size: CGSize(width: 96, height: 96)
        )
        render(
            RecoveryComplicationTestHooks.rootView(
                entry: entry,
                family: .accessoryRectangular
            ),
            size: CGSize(width: 180, height: 80)
        )
        render(
            RecoveryComplicationTestHooks.rootView(
                entry: entry,
                family: .accessoryCorner
            ),
            size: CGSize(width: 96, height: 96)
        )
        render(
            RecoveryComplicationTestHooks.rootView(
                entry: .empty,
                family: .accessoryInline
            ),
            size: CGSize(width: 180, height: 48)
        )

        _ = RecoveryComplicationWidget().body
        _ = LifeOSComplicationsBundle().body
    }

    private func clearStandardPendingActions() {
        UserDefaults.standard.removeObject(forKey: pendingActionsKey)
    }

    @MainActor
    private func render(
        _ view: some View,
        size: CGSize = CGSize(width: 176, height: 176),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let renderer = ImageRenderer(
            content: view
                .frame(width: size.width, height: size.height)
        )
        renderer.scale = 1
        XCTAssertNotNil(renderer.cgImage, file: file, line: line)
    }
}
