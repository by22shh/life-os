import Foundation
import GRDB

/// Ensures the authenticated cloud user has a canonical `public.users` upsert
/// queued before any user-scoped sync work starts.
enum CloudUserBootstrapper {
    private static let bootstrapPriority = 10

    static func scheduleCanonicalUserUpsertIfNeeded(
        authId: UUID,
        email: String?,
        dbQueue: DatabaseQueue,
        syncEngine: SyncEngine
    ) async throws {
        let hasCloudSession = await MainActor.run { AuthManager.activeHasCloudSession }
        try await scheduleCanonicalUserUpsertIfNeeded(
            authId: authId,
            email: email,
            dbQueue: dbQueue,
            syncEngine: syncEngine,
            isRuntimeConfigured: SupabaseConfig.isRuntimeConfigured,
            hasCloudSession: hasCloudSession
        )
    }

    private static func scheduleCanonicalUserUpsertIfNeeded(
        authId: UUID,
        email: String?,
        dbQueue: DatabaseQueue,
        syncEngine: SyncEngine,
        isRuntimeConfigured: Bool,
        hasCloudSession: Bool
    ) async throws {
        guard isRuntimeConfigured, hasCloudSession else {
            return
        }

        guard let user = try await dbQueue.read({ db in
            try UserIdentityReconciler.preferredLocalUser(authId: authId, db: db)
        }) else {
            return
        }

        let payload = try canonicalUserUpsertPayload(
            for: user,
            canonicalUserId: authId,
            explicitEmail: email
        )
        try await syncEngine.enqueueOrRefreshCanonicalUserUpsert(
            bodyJson: payload,
            userId: authId,
            priority: bootstrapPriority
        )
        try await syncEngine.retryFailedPermanentEventsRecoverableFromUserBootstrap()
    }

    private static func canonicalUserUpsertPayload(
        for user: User,
        canonicalUserId: UUID,
        explicitEmail: String?
    ) throws -> Data {
        var payload: [String: Any] = [
            "id": canonicalUserId.uuidString,
            "auth_id": canonicalUserId.uuidString,
        ]

        assignIfPresent(normalized(explicitEmail) ?? normalized(user.email), to: "email", in: &payload)
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func assignIfPresent(
        _ value: Any?,
        to key: String,
        in payload: inout [String: Any]
    ) {
        guard let value else { return }
        payload[key] = value
    }
}

#if DEBUG
extension CloudUserBootstrapper {
    static func _testScheduleCanonicalUserUpsertIfNeeded(
        authId: UUID,
        email: String?,
        dbQueue: DatabaseQueue,
        syncEngine: SyncEngine,
        isRuntimeConfigured: Bool,
        hasCloudSession: Bool
    ) async throws {
        try await scheduleCanonicalUserUpsertIfNeeded(
            authId: authId,
            email: email,
            dbQueue: dbQueue,
            syncEngine: syncEngine,
            isRuntimeConfigured: isRuntimeConfigured,
            hasCloudSession: hasCloudSession
        )
    }

    static func _testCanonicalUserUpsertPayload(
        for user: User,
        canonicalUserId: UUID,
        explicitEmail: String?
    ) throws -> Data {
        try canonicalUserUpsertPayload(
            for: user,
            canonicalUserId: canonicalUserId,
            explicitEmail: explicitEmail
        )
    }

    static func _testNormalized(_ value: String?) -> String? {
        normalized(value)
    }
}
#endif
