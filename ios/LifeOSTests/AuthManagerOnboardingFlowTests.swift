import XCTest
import GRDB
@testable import LifeOS

@MainActor
final class AuthManagerOnboardingFlowTests: XCTestCase {

    func testSignOutPreservesLocalHistoryAndLocksVaultToOriginalIdentity() async throws {
        let manager = try DatabaseManager.inMemory()
        let auth = AuthManager(client: SupabaseConfig.client, db: manager)
        let authId = UUID()
        try await manager.dbQueue.write { db in
            try User(id: authId, authId: authId).insert(db)
            try HealthMeasurement(userId: authId, biomarkerName: "Ferritin", value: 78.4, unit: "ng/mL").insert(db)
            try OutboxEvent(httpMethod: .POST, path: "api-food-log", bodyJson: Data("{}".utf8)).insert(db)
        }
        auth._testSetState(authState: .authenticated, userId: authId, isAnonymous: false)
        try await auth.signOut()
        XCTAssertEqual(auth.authState, .signedOut)
        let counts = try await manager.dbQueue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM health_measurements"), try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox_events"))
        }
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
        auth._testApplyCloudIdentity(UUID())
        XCTAssertNil(auth.userId, "A different account must not unlock retained local data")
        auth._testApplyCloudIdentity(authId)
        XCTAssertEqual(auth.userId, authId)
    }

    override func tearDown() async throws {
        try await super.tearDown()
        await MainActor.run {
            AuthManager._testResetOverrides()
            AuthManager.setActiveAuthIdForTests(nil)
            AuthManager._testSetActiveHasCloudSession(false)
        }
    }

    func testAnonymousIdentityRequiresOnboardingUntilLocalCompletion() async throws {
        let manager = try DatabaseManager.inMemory()
        let auth = AuthManager(client: SupabaseConfig.client, db: manager)
        let authId = UUID()
        let userId = UUID()

        auth._testSetState(authState: .loading, userId: authId, isAnonymous: true)
        await auth._testRefreshPostAuthState(hasSession: false)
        let postRefreshState = auth.authState
        XCTAssertEqual(postRefreshState, .needsOnboarding)

        try await manager.dbQueue.write { db in
            try Self.insertUser(
                db: db,
                userId: userId,
                authId: authId,
                onboardingCompleted: true
            )
        }

        await auth._testRefreshPostAuthState(hasSession: false)
        let finalState = auth.authState
        XCTAssertEqual(finalState, .anonymous)
    }

    func testAnonymousIdentityHonorsPersistedOnboardingCompletionMilestone() async throws {
        let manager = try DatabaseManager.inMemory()
        let auth = AuthManager(client: SupabaseConfig.client, db: manager)
        let authId = UUID()
        let userId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(
                db: db,
                userId: userId,
                authId: authId,
                onboardingCompleted: false
            )
            try Self.insertOnboardingState(
                db: db,
                userId: userId,
                step: .onboardingComplete
            )
        }

        auth._testSetState(authState: .loading, userId: authId, isAnonymous: true)
        await auth._testRefreshPostAuthState(hasSession: false)
        let postRefreshState = auth.authState
        XCTAssertEqual(postRefreshState, .anonymous)
    }

    func testRecoveredLocalIdentityRemainsAuthenticatedWhenCloudReconnectIsRequired() async throws {
        let manager = try DatabaseManager.inMemory()
        let auth = AuthManager(client: SupabaseConfig.client, db: manager)
        let authId = UUID()
        let userId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(
                db: db,
                userId: userId,
                authId: authId,
                onboardingCompleted: true
            )
        }

        auth._testSetState(
            authState: .loading,
            userId: authId,
            isAnonymous: false,
            requiresCloudReauthentication: true
        )
        await auth._testRefreshPostAuthState(hasSession: false)
        let postRefreshState = auth.authState
        let requiresCloudReauthentication = auth.requiresCloudReauthentication
        XCTAssertEqual(postRefreshState, .authenticated)
        XCTAssertTrue(requiresCloudReauthentication)
    }

    func testRecoveredLocalIdentityStillShowsOnboardingWhenCloudReconnectIsRequired() async throws {
        let manager = try DatabaseManager.inMemory()
        let auth = AuthManager(client: SupabaseConfig.client, db: manager)
        let authId = UUID()
        let userId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(
                db: db,
                userId: userId,
                authId: authId,
                onboardingCompleted: false
            )
        }

        auth._testSetState(
            authState: .loading,
            userId: authId,
            isAnonymous: false,
            requiresCloudReauthentication: true
        )
        await auth._testRefreshPostAuthState(hasSession: false)
        let postRefreshState = auth.authState
        let requiresCloudReauthentication = auth.requiresCloudReauthentication
        XCTAssertEqual(postRefreshState, .needsOnboarding)
        XCTAssertTrue(requiresCloudReauthentication)
    }

    func testRecoveredLocalIdentityWithoutCloudReconnectStillLoadsLocalProfile() async throws {
        let manager = try DatabaseManager.inMemory()
        let auth = AuthManager(client: SupabaseConfig.client, db: manager)
        let authId = UUID()
        let userId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(
                db: db,
                userId: userId,
                authId: authId,
                onboardingCompleted: true
            )
        }

        auth._testSetState(
            authState: .loading,
            userId: authId,
            isAnonymous: false,
            requiresCloudReauthentication: false,
            hasRecoveredLocalIdentity: true
        )
        await auth._testRefreshPostAuthState(hasSession: false)
        let postRefreshState = auth.authState
        let requiresCloudReauthentication = auth.requiresCloudReauthentication
        XCTAssertEqual(postRefreshState, .authenticated)
        XCTAssertFalse(requiresCloudReauthentication)
    }

    nonisolated private static func insertUser(
        db: Database,
        userId: UUID,
        authId: UUID,
        onboardingCompleted: Bool
    ) throws {
        let now = Date()
        try db.execute(
            sql: """
                INSERT INTO users (
                    id, auth_id, timezone, units, onboarding_completed, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                userId.uuidString,
                authId.uuidString,
                "UTC",
                "metric",
                onboardingCompleted,
                now,
                now,
            ]
        )
    }

    nonisolated private static func insertOnboardingState(
        db: Database,
        userId: UUID,
        step: OnboardingStep
    ) throws {
        let now = Date()
        try db.execute(
            sql: """
                INSERT INTO onboarding_state (
                    id, user_id, step, completed_at, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                UUID().uuidString,
                userId.uuidString,
                step.rawValue,
                now,
                now,
                now,
            ]
        )
    }
}
