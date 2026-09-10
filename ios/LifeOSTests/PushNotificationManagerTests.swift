import Foundation
import GRDB
import UserNotifications
import XCTest
@testable import LifeOS

@MainActor
final class PushNotificationManagerTests: XCTestCase {
    private let tokenDefaultsKey = "lifeos.push.apns_token"
    private let registrationErrorDefaultsKey = "lifeos.push.apns_registration_error"

    func testLocalReminderPermissionWorksWithoutAPNsAndDenialDoesNotPretendToSchedule() async {
        var requested = false
        let manager = PushNotificationManager(
            notificationAuthorizationStatusProvider: { .notDetermined },
            requestAuthorizationHandler: { requested = true; return true },
            isRunningTestsProvider: { false },
            isRemotePushAvailableProvider: { false },
            notificationDeliveryUnlockedProvider: { true }
        )
        let granted = await manager.requestLocalReminderAuthorizationIfNeeded()
        XCTAssertTrue(granted)
        XCTAssertTrue(requested)
        let denied = PushNotificationManager(
            notificationAuthorizationStatusProvider: { .denied },
            addNotificationRequestHandler: { _ in XCTFail("Denied authorization must not add a request") },
            isRunningTestsProvider: { false }
        )
        let scheduled = await denied.scheduleLocalNotification(
            LifeOSNotification(category: .experiment, priority: .active, title: "Test", body: "Value"), at: Date().addingTimeInterval(600)
        )
        XCTAssertFalse(scheduled)
    }

    func testLocalReminderReportsSystemSchedulingFailure() async {
        let manager = PushNotificationManager(
            notificationAuthorizationStatusProvider: { .authorized },
            addNotificationRequestHandler: { _ in throw NSError(domain: "test", code: 1) },
            isRunningTestsProvider: { false }
        )
        let scheduled = await manager.scheduleLocalNotification(
            LifeOSNotification(category: .experiment, priority: .active, title: "Test", body: "Value"), at: Date().addingTimeInterval(600)
        )
        XCTAssertFalse(scheduled)
    }

    func testSyncAuthorizationStateWhenDeniedCancelsPendingRegistrationAndQueuesUnregistration() async throws {
        let dbManager = try DatabaseManager.inMemory()
        let syncEngine = makeNoopPushSyncEngine(dbQueue: dbManager.dbQueue)
        let suiteName = "push.tests.denied.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let seedManager = makePushManager(
            defaults: defaults,
            syncEngine: syncEngine,
            authorizationStatus: .authorized
        )
        await seedManager.handleDidRegisterForRemoteNotifications(deviceToken: Data([0xab, 0xcd]))
        defaults.set("stale-registration-error", forKey: registrationErrorDefaultsKey)

        let deniedManager = makePushManager(
            defaults: defaults,
            syncEngine: syncEngine,
            authorizationStatus: .denied
        )
        await deniedManager.syncAuthorizationState()

        let events = try await fetchPushLifecycleEvents(dbQueue: dbManager.dbQueue)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].path, "api-notifications-register-device")
        XCTAssertEqual(events[0].status, .cancelled)
        XCTAssertEqual(events[1].path, "api-notifications-unregister-device")
        XCTAssertEqual(events[1].status, .pending)
        XCTAssertEqual(try pushToken(from: events[1]), "abcd")
        XCTAssertNil(deniedManager.remotePushStatusMessage)
    }

    func testSyncAuthorizationStateWhenReauthorizedCancelsPendingUnregistrationAndQueuesRegistration() async throws {
        let dbManager = try DatabaseManager.inMemory()
        let syncEngine = makeNoopPushSyncEngine(dbQueue: dbManager.dbQueue)
        let suiteName = "push.tests.reauthorized.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initialManager = makePushManager(
            defaults: defaults,
            syncEngine: syncEngine,
            authorizationStatus: .authorized
        )
        await initialManager.handleDidRegisterForRemoteNotifications(deviceToken: Data([0xde, 0xad, 0xbe, 0xef]))

        let deniedManager = makePushManager(
            defaults: defaults,
            syncEngine: syncEngine,
            authorizationStatus: .denied
        )
        await deniedManager.syncAuthorizationState()

        let reauthorizedManager = makePushManager(
            defaults: defaults,
            syncEngine: syncEngine,
            authorizationStatus: .authorized
        )
        await reauthorizedManager.syncAuthorizationState()

        let events = try await fetchPushLifecycleEvents(dbQueue: dbManager.dbQueue)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].path, "api-notifications-register-device")
        XCTAssertEqual(events[0].status, .cancelled)
        XCTAssertEqual(events[1].path, "api-notifications-unregister-device")
        XCTAssertEqual(events[1].status, .cancelled)
        XCTAssertEqual(events[2].path, "api-notifications-register-device")
        XCTAssertEqual(events[2].status, .pending)
        XCTAssertEqual(try pushToken(from: events[2]), "deadbeef")
    }

    func testSyncAuthorizationStateUsesLegacyStoredTokenOnlyOnceWhenDenied() async throws {
        let dbManager = try DatabaseManager.inMemory()
        let syncEngine = makeNoopPushSyncEngine(dbQueue: dbManager.dbQueue)
        let suiteName = "push.tests.legacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("feedface", forKey: tokenDefaultsKey)
        defaults.set("stale-registration-error", forKey: registrationErrorDefaultsKey)

        let firstManager = makePushManager(
            defaults: defaults,
            syncEngine: syncEngine,
            authorizationStatus: .denied
        )
        await firstManager.syncAuthorizationState()

        let secondManager = makePushManager(
            defaults: defaults,
            syncEngine: syncEngine,
            authorizationStatus: .denied
        )
        await secondManager.syncAuthorizationState()

        let events = try await fetchPushLifecycleEvents(dbQueue: dbManager.dbQueue)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].path, "api-notifications-unregister-device")
        XCTAssertEqual(events[0].status, .pending)
        XCTAssertEqual(try pushToken(from: events[0]), "feedface")
        XCTAssertNil(secondManager.remotePushStatusMessage)
    }

    func testSyncAuthorizationStateDoesNotUnregisterWhenPermissionNotDetermined() async throws {
        let dbManager = try DatabaseManager.inMemory()
        let syncEngine = makeNoopPushSyncEngine(dbQueue: dbManager.dbQueue)
        let suiteName = "push.tests.not-determined.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("cafebabe", forKey: tokenDefaultsKey)

        let manager = makePushManager(
            defaults: defaults,
            syncEngine: syncEngine,
            authorizationStatus: .notDetermined
        )
        await manager.syncAuthorizationState()

        let events = try await fetchPushLifecycleEvents(dbQueue: dbManager.dbQueue)
        XCTAssertTrue(events.isEmpty)
    }

    func testHandleDidRegisterForRemoteNotificationsUsesCapabilityDerivedEnvironment() async throws {
        let dbManager = try DatabaseManager.inMemory()
        let syncEngine = makeNoopPushSyncEngine(dbQueue: dbManager.dbQueue)
        let suiteName = "push.tests.environment.production.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = makePushManager(
            defaults: defaults,
            syncEngine: syncEngine,
            authorizationStatus: .authorized,
            remotePushEnvironment: "production"
        )
        await manager.handleDidRegisterForRemoteNotifications(deviceToken: Data([0xca, 0xfe]))

        let events = try await fetchPushLifecycleEvents(dbQueue: dbManager.dbQueue)
        let payload = try payload(from: try XCTUnwrap(events.first))
        XCTAssertEqual(payload["environment"] as? String, "production")
    }

    func testHandleDidRegisterForRemoteNotificationsDoesNotQueueRegistrationWithoutEnvironment() async throws {
        let dbManager = try DatabaseManager.inMemory()
        let syncEngine = makeNoopPushSyncEngine(dbQueue: dbManager.dbQueue)
        let suiteName = "push.tests.environment.missing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = makePushManager(
            defaults: defaults,
            syncEngine: syncEngine,
            authorizationStatus: .authorized,
            isRemotePushAvailable: true,
            remotePushEnvironment: nil
        )

        XCTAssertEqual(
            manager.remotePushStatusMessage,
            AppCapabilityAvailability.remotePushUnavailableMessage
        )

        await manager.handleDidRegisterForRemoteNotifications(deviceToken: Data([0xfa, 0xce]))

        let events = try await fetchPushLifecycleEvents(dbQueue: dbManager.dbQueue)
        XCTAssertTrue(events.isEmpty)
    }

    private func makePushManager(
        defaults: UserDefaults,
        syncEngine: SyncEngine,
        authorizationStatus: UNAuthorizationStatus,
        isRemotePushAvailable: Bool = true,
        remotePushEnvironment: String? = "development"
    ) -> PushNotificationManager {
        PushNotificationManager(
            defaults: defaults,
            deviceId: "push-test-device",
            notificationAuthorizationStatusProvider: { authorizationStatus },
            requestAuthorizationHandler: { authorizationStatus == .authorized },
            registerForRemoteNotificationsHandler: {},
            isRunningTestsProvider: { false },
            isRemotePushAvailableProvider: { isRemotePushAvailable },
            remotePushEnvironmentProvider: { remotePushEnvironment },
            isRuntimeConfiguredProvider: { true },
            notificationDeliveryUnlockedProvider: { true },
            syncEngineProvider: { syncEngine }
        )
    }

    private func fetchPushLifecycleEvents(dbQueue: DatabaseQueue) async throws -> [OutboxEvent] {
        try await dbQueue.read { db in
            try OutboxEvent.fetchAll(db)
                .filter { event in
                    event.path == "api-notifications-register-device"
                        || event.path == "api-notifications-unregister-device"
                }
                .sorted { lhs, rhs in
                    if lhs.createdAtLocal == rhs.createdAtLocal {
                        return lhs.priority < rhs.priority
                    }
                    return lhs.createdAtLocal < rhs.createdAtLocal
                }
        }
    }

    private func pushToken(from event: OutboxEvent) throws -> String? {
        let payload = try payload(from: event)
        return payload["push_token"] as? String
    }

    private func payload(from event: OutboxEvent) throws -> [String: Any] {
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: event.bodyJson) as? [String: Any]
        )
        return payload
    }

    private func makeNoopPushSyncEngine(dbQueue: DatabaseQueue) -> SyncEngine {
        SyncEngine(
            dbQueue: dbQueue,
            apiClient: FakeSyncAPIClient(),
            pushTransportOverride: { _ in }
        )
    }
}
