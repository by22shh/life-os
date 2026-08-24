import XCTest
import GRDB
@testable import LifeOS

@MainActor
final class UserIdentityReconcilerTests: XCTestCase {
    override func tearDown() {
        AuthManager._testResetOverrides()
        AuthManager.setActiveAuthIdForTests(nil)
        super.tearDown()
    }

    func testAuthenticatedIdentityMergeReusesCanonicalUserAndRewritesLocalReferences() async throws {
        let manager = try DatabaseManager.inMemory()
        let offlineAuthId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let cloudAuthId = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let canonicalUserId = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let bodyEventId = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let flagsEventId = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!

        try await manager.dbQueue.write { db in
            var offlineUser = User(id: offlineAuthId, authId: offlineAuthId)
            offlineUser.displayName = "Offline First"
            offlineUser.onboardingCompleted = true
            offlineUser.updatedAt = Date(timeIntervalSince1970: 2_000)
            try offlineUser.insert(db)

            var canonicalUser = User(id: canonicalUserId, authId: cloudAuthId)
            canonicalUser.email = "cloud@example.com"
            canonicalUser.updatedAt = Date(timeIntervalSince1970: 1_000)
            try canonicalUser.insert(db)

            var food = UserFood(
                id: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!,
                userId: offlineAuthId,
                name: "Offline oats",
                caloriesPer100g: 380,
                proteinPer100g: 13,
                fatPer100g: 7,
                carbsPer100g: 68
            )
            food.updatedAt = Date(timeIntervalSince1970: 2_100)
            try food.insert(db)

            var flags = UserHealthFlags(
                id: UUID(uuidString: "77777777-7777-4777-8777-777777777777")!,
                userId: offlineAuthId
            )
            flags.hasPacemaker = true
            flags.updatedAt = Date(timeIntervalSince1970: 2_200)
            try flags.insert(db)

            var userEvent = OutboxEvent(
                id: bodyEventId,
                httpMethod: .POST,
                path: "rest/v1/users",
                bodyJson: try JSONSerialization.data(withJSONObject: [
                    "id": offlineAuthId.uuidString,
                    "auth_id": offlineAuthId.uuidString,
                    "display_name": "Offline First",
                ])
            )
            userEvent.status = .pending
            try userEvent.insert(db)

            var flagsEvent = OutboxEvent(
                id: flagsEventId,
                httpMethod: .POST,
                path: "rest/v1/user_health_flags",
                bodyJson: try JSONSerialization.data(withJSONObject: [
                    "id": UUID().uuidString,
                    "user_id": offlineAuthId.uuidString,
                    "has_pacemaker": true,
                ])
            )
            flagsEvent.status = .pending
            try flagsEvent.insert(db)
        }

        let reconciledUser = try await manager.dbQueue.write { db in
            try UserIdentityReconciler.reconcileAuthenticatedIdentity(
                authId: cloudAuthId,
                email: "merged@example.com",
                offlineAuthId: offlineAuthId,
                db: db,
                now: Date(timeIntervalSince1970: 3_000)
            )
        }

        XCTAssertEqual(reconciledUser.id, canonicalUserId)
        XCTAssertEqual(reconciledUser.authId, cloudAuthId)
        XCTAssertEqual(reconciledUser.email, "merged@example.com")
        XCTAssertEqual(reconciledUser.displayName, "Offline First")
        XCTAssertTrue(reconciledUser.onboardingCompleted)

        try await manager.dbQueue.read { db in
            let userCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM users") ?? 0
            XCTAssertEqual(userCount, 1)

            let resolvedUserId = try UserIdentityLookup.resolveUserId(authId: cloudAuthId.uuidString, db: db)
            XCTAssertEqual(resolvedUserId, canonicalUserId)

            let userFoodOwner = try String.fetchOne(
                db,
                sql: "SELECT user_id FROM user_foods LIMIT 1"
            )
            XCTAssertEqual(userFoodOwner?.lowercased(), canonicalUserId.uuidString.lowercased())

            let flagsOwner = try String.fetchOne(
                db,
                sql: "SELECT user_id FROM user_health_flags LIMIT 1"
            )
            XCTAssertEqual(flagsOwner?.lowercased(), canonicalUserId.uuidString.lowercased())

            let userBody = try XCTUnwrap(
                Data.fetchOne(
                    db,
                    sql: "SELECT body_json FROM outbox_events WHERE id = ? OR id = ? LIMIT 1",
                    arguments: [bodyEventId, bodyEventId.uuidString]
                )
            )
            let userPayload = try XCTUnwrap(try JSONSerialization.jsonObject(with: userBody) as? [String: Any])
            XCTAssertEqual(userPayload["id"] as? String, canonicalUserId.uuidString)
            XCTAssertEqual(userPayload["auth_id"] as? String, cloudAuthId.uuidString)

            let flagsBody = try XCTUnwrap(
                Data.fetchOne(
                    db,
                    sql: "SELECT body_json FROM outbox_events WHERE id = ? OR id = ? LIMIT 1",
                    arguments: [flagsEventId, flagsEventId.uuidString]
                )
            )
            let flagsPayload = try XCTUnwrap(try JSONSerialization.jsonObject(with: flagsBody) as? [String: Any])
            XCTAssertEqual(flagsPayload["user_id"] as? String, canonicalUserId.uuidString)

            let oldUserCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM users WHERE id = ? OR lower(CAST(id AS TEXT)) = lower(?)",
                arguments: [offlineAuthId, offlineAuthId.uuidString]
            ) ?? 0
            XCTAssertEqual(oldUserCount, 0)
        }
    }

    func testCloudAuthenticatedIdentityCanonicalizesOfflineUserIdToAuthIdAndRewritesUserPayload() async throws {
        let manager = try DatabaseManager.inMemory()
        let offlineAuthId = UUID(uuidString: "81818181-1111-4111-8111-111111111111")!
        let cloudAuthId = UUID(uuidString: "92929292-2222-4222-8222-222222222222")!
        let userEventId = UUID(uuidString: "93939393-3333-4333-8333-333333333333")!

        try await manager.dbQueue.write { db in
            var offlineUser = User(id: offlineAuthId, authId: offlineAuthId)
            offlineUser.displayName = "Offline canonical"
            offlineUser.onboardingCompleted = true
            offlineUser.updatedAt = Date(timeIntervalSince1970: 2_000)
            try offlineUser.insert(db)

            var food = UserFood(
                id: UUID(uuidString: "94949494-4444-4444-8444-444444444444")!,
                userId: offlineAuthId,
                name: "Offline yogurt",
                caloriesPer100g: 60,
                proteinPer100g: 5,
                fatPer100g: 2,
                carbsPer100g: 4
            )
            food.updatedAt = Date(timeIntervalSince1970: 2_050)
            try food.insert(db)

            var userEvent = OutboxEvent(
                id: userEventId,
                httpMethod: .POST,
                path: "rest/v1/users",
                bodyJson: try JSONSerialization.data(withJSONObject: [
                    "id": offlineAuthId.uuidString,
                    "auth_id": offlineAuthId.uuidString,
                    "display_name": "Offline canonical",
                    "onboarding_completed": true,
                ])
            )
            userEvent.status = .pending
            try userEvent.insert(db)
        }

        let reconciledUser = try await manager.dbQueue.write { db in
            try UserIdentityReconciler.reconcileCloudAuthenticatedIdentity(
                authId: cloudAuthId,
                email: "cloud@example.com",
                offlineAuthId: offlineAuthId,
                db: db,
                now: Date(timeIntervalSince1970: 3_000)
            )
        }

        XCTAssertEqual(reconciledUser.id, cloudAuthId)
        XCTAssertEqual(reconciledUser.authId, cloudAuthId)
        XCTAssertEqual(reconciledUser.email, "cloud@example.com")
        XCTAssertEqual(reconciledUser.displayName, "Offline canonical")
        XCTAssertTrue(reconciledUser.onboardingCompleted)

        try await manager.dbQueue.read { db in
            let userCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM users") ?? 0
            XCTAssertEqual(userCount, 1)

            let resolvedUserId = try UserIdentityLookup.resolveUserId(authId: cloudAuthId.uuidString, db: db)
            XCTAssertEqual(resolvedUserId, cloudAuthId)

            let userFoodOwner = try String.fetchOne(
                db,
                sql: "SELECT user_id FROM user_foods LIMIT 1"
            )
            XCTAssertEqual(userFoodOwner?.lowercased(), cloudAuthId.uuidString.lowercased())

            let userBody = try XCTUnwrap(
                Data.fetchOne(
                    db,
                    sql: "SELECT body_json FROM outbox_events WHERE id = ? OR id = ? LIMIT 1",
                    arguments: [userEventId, userEventId.uuidString]
                )
            )
            let userPayload = try XCTUnwrap(try JSONSerialization.jsonObject(with: userBody) as? [String: Any])
            XCTAssertEqual(userPayload["id"] as? String, cloudAuthId.uuidString)
            XCTAssertEqual(userPayload["auth_id"] as? String, cloudAuthId.uuidString)

            let oldUserCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM users WHERE id = ? OR lower(CAST(id AS TEXT)) = lower(?)",
                arguments: [offlineAuthId, offlineAuthId.uuidString]
            ) ?? 0
            XCTAssertEqual(oldUserCount, 0)
        }
    }

    func testPullUsersTableCanonicalizesLocalUserIdToServerUserId() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = FakeSyncAPIClient()
        let engine = SyncEngine(dbQueue: manager.dbQueue, apiClient: api)

        let authId = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let localUserId = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let serverUserId = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        let userEventId = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!

        try await manager.dbQueue.write { db in
            var localUser = User(id: localUserId, authId: authId)
            localUser.displayName = "Local profile"
            localUser.onboardingCompleted = true
            localUser.updatedAt = Date(timeIntervalSince1970: 2_500)
            try localUser.insert(db)

            var food = UserFood(
                id: UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!,
                userId: localUserId,
                name: "Local kefir",
                caloriesPer100g: 60,
                proteinPer100g: 3,
                fatPer100g: 2,
                carbsPer100g: 5
            )
            food.updatedAt = Date(timeIntervalSince1970: 2_510)
            try food.insert(db)

            var event = OutboxEvent(
                id: userEventId,
                httpMethod: .POST,
                path: "rest/v1/users",
                bodyJson: try JSONSerialization.data(withJSONObject: [
                    "id": localUserId.uuidString,
                    "display_name": "Local profile",
                    "onboarding_completed": true,
                ])
            )
            event.status = .pending
            try event.insert(db)
        }

        var serverUser = User(id: serverUserId, authId: authId)
        serverUser.email = "server@example.com"
        serverUser.updatedAt = Date(timeIntervalSince1970: 1_500)
        await api.setUsersPages([[serverUser]])

        try await engine._testPullUsersTable()

        try await manager.dbQueue.read { db in
            let userCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM users") ?? 0
            XCTAssertEqual(userCount, 1)

            let resolvedUserId = try UserIdentityLookup.resolveUserId(authId: authId.uuidString, db: db)
            XCTAssertEqual(resolvedUserId, serverUserId)

            let mergedUser = try XCTUnwrap(
                User.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM users
                        WHERE id = ? OR lower(CAST(id AS TEXT)) = lower(?)
                        LIMIT 1
                        """,
                    arguments: [serverUserId, serverUserId.uuidString]
                )
            )
            XCTAssertEqual(mergedUser.displayName, "Local profile")
            XCTAssertTrue(mergedUser.onboardingCompleted)
            XCTAssertEqual(mergedUser.email, "server@example.com")

            let userFoodOwner = try String.fetchOne(
                db,
                sql: "SELECT user_id FROM user_foods LIMIT 1"
            )
            XCTAssertEqual(userFoodOwner?.lowercased(), serverUserId.uuidString.lowercased())

            let mirrorRowId = try String.fetchOne(
                db,
                sql: "SELECT row_id FROM sync_row_state WHERE table_name = ? LIMIT 1",
                arguments: [User.databaseTableName]
            )
            XCTAssertEqual(mirrorRowId?.lowercased(), serverUserId.uuidString.lowercased())

            let oldMirrorCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM sync_row_state
                    WHERE table_name = ?
                      AND (row_id = ? OR lower(CAST(row_id AS TEXT)) = lower(?))
                    """,
                arguments: [User.databaseTableName, localUserId.uuidString, localUserId.uuidString]
            ) ?? 0
            XCTAssertEqual(oldMirrorCount, 0)

            let userBody = try XCTUnwrap(
                Data.fetchOne(
                    db,
                    sql: "SELECT body_json FROM outbox_events WHERE id = ? OR id = ? LIMIT 1",
                    arguments: [userEventId, userEventId.uuidString]
                )
            )
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: userBody) as? [String: Any])
            XCTAssertEqual(payload["id"] as? String, serverUserId.uuidString)
        }
    }

    @MainActor
    func testBootstrapFallsBackToExistingLocalProfileWithoutCreatingOfflineSplit() async throws {
        let manager = try DatabaseManager.inMemory()
        let auth = AuthManager(client: SupabaseConfig.client, db: manager)
        let authId = UUID(uuidString: "ffffffff-ffff-4fff-8fff-ffffffffffff")!
        let profileUserId = UUID(uuidString: "12121212-1212-4212-8212-121212121212")!

        try await manager.dbQueue.write { db in
            var user = User(id: profileUserId, authId: authId)
            user.displayName = "Recovered profile"
            user.onboardingCompleted = true
            try user.insert(db)
        }

        AuthManager._testResetOverrides()
        AuthManager._testSetRunningTestsOverride(false)
        AuthManager._testSetLastCloudAuthId(authId)
        AuthManager._testSetBootstrapSessionOverride {
            throw NSError(domain: "UserIdentityReconcilerTests.bootstrap", code: 1)
        }
        AuthManager._testSetAnonymousSignInOverride {
            throw NSError(domain: "UserIdentityReconcilerTests.anonymous", code: 2)
        }

        await auth.bootstrap()

        XCTAssertEqual(auth.userId, authId)
        XCTAssertEqual(auth.authState, .authenticated)
        XCTAssertFalse(auth.isAnonymous)
        XCTAssertFalse(auth.hasCloudSession)

        try await manager.dbQueue.read { db in
            let userCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM users") ?? 0
            XCTAssertEqual(userCount, 1)
            let resolvedUserId = try UserIdentityLookup.resolveUserId(authId: authId.uuidString, db: db)
            XCTAssertEqual(resolvedUserId, profileUserId)
        }
    }
}
