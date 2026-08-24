import Foundation
import GRDB

protocol TrainingPlanManaging: Sendable {
    func generatePlan(_ draft: TrainingPlanGenerationDraft) async throws
    func updatePlan(_ draft: TrainingPlanUpdateDraft) async throws
    func adjustPlan(_ draft: TrainingPlanAdjustmentDraft) async throws
}

protocol TrainingPlanRouteAPIClient: Sendable {
    func generateTrainingPlan(_ payload: TrainingPlanEdgeGeneratePayload) async throws -> TrainingPlanEdgeGenerateResponse
    func updateTrainingPlan(id: UUID, payload: TrainingPlanEdgeUpdatePayload) async throws -> TrainingPlanEdgeUpdateResponse
    func adjustTrainingPlan(id: UUID, payload: TrainingPlanEdgeAdjustPayload) async throws -> TrainingPlanEdgeAdjustResponse
}

struct TrainingPlanGenerationDraft: Sendable {
    var name: String?
    var goal: TrainingGoal
    var availableDays: [Int]
    var durationWeeks: Int
    var sessionDurationMinutes: Int
    var experienceLevel: TrainingPlanExperienceLevel
    var equipmentAccess: TrainingPlanEquipmentAccess
    var injuries: [String]

    var normalizedName: String? {
        Self.normalizedText(name)
    }

    var normalizedAvailableDays: [Int] {
        Array(Set(availableDays))
            .filter { (0...6).contains($0) }
            .sorted()
    }

    var normalizedInjuries: [String] {
        injuries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizedText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

struct TrainingPlanUpdateDraft: Sendable {
    let id: UUID
    var name: String?
    var status: TrainingPlanStatus?

    var normalizedName: String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

struct TrainingPlanAdjustmentDraft: Sendable {
    let id: UUID
    var reason: TrainingPlanAdjustmentReason
    var adjustment: TrainingPlanAdjustmentKind
}

enum TrainingPlanExperienceLevel: String, CaseIterable, Sendable, Identifiable {
    case beginner
    case intermediate
    case advanced

    var id: String { rawValue }
}

enum TrainingPlanEquipmentAccess: String, CaseIterable, Sendable, Identifiable {
    case bodyweight
    case homeGym = "home_gym"
    case gym
    case mixed

    var id: String { rawValue }
}

enum TrainingPlanAdjustmentReason: String, CaseIterable, Sendable, Identifiable {
    case recoveryLow = "recovery_low"
    case recoveryCritical = "recovery_critical"
    case fatigueAccumulation = "fatigue_accumulation"
    case injuryFlag = "injury_flag"
    case userRequest = "user_request"
    case scheduleConflict = "schedule_conflict"
    case loadSpikeAcwr = "load_spike_acwr"

    var id: String { rawValue }

    var recommendedAdjustment: TrainingPlanAdjustmentKind {
        switch self {
        case .recoveryLow:
            return .reduceVolume30
        case .recoveryCritical:
            return .swapToMobility
        case .fatigueAccumulation:
            return .deloadWeek
        case .injuryFlag:
            return .skipSession
        case .userRequest:
            return .reduceIntensity20
        case .scheduleConflict:
            return .extendRestDay
        case .loadSpikeAcwr:
            return .reduceVolume30
        }
    }
}

enum TrainingPlanAdjustmentKind: String, CaseIterable, Sendable, Identifiable {
    case reduceVolume30 = "reduce_volume_30"
    case reduceIntensity20 = "reduce_intensity_20"
    case skipSession = "skip_session"
    case swapToMobility = "swap_to_mobility"
    case extendRestDay = "extend_rest_day"
    case deloadWeek = "deload_week"

    var id: String { rawValue }
}

struct TrainingPlanEdgeGeneratePayload: Encodable, Sendable {
    let name: String?
    let goal: String
    let availableDays: [Int]
    let durationWeeks: Int
    let sessionDurationMinutes: Int
    let experienceLevel: String
    let equipmentAccess: String
    let injuries: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case goal
        case availableDays = "available_days"
        case durationWeeks = "duration_weeks"
        case sessionDurationMinutes = "session_duration_minutes"
        case experienceLevel = "experience_level"
        case equipmentAccess = "equipment_access"
        case injuries
    }
}

struct TrainingPlanEdgeUpdatePayload: Encodable, Sendable {
    let name: String?
    let status: String?
}

struct TrainingPlanEdgeAdjustPayload: Encodable, Sendable {
    let reason: String
    let adjustment: String
}

struct TrainingPlanEdgeGenerateResponse: Decodable, Sendable {
    let planId: UUID
    let status: String
    let weeksGenerated: Int

    enum CodingKeys: String, CodingKey {
        case planId = "plan_id"
        case status
        case weeksGenerated = "weeks_generated"
    }
}

struct TrainingPlanEdgeUpdateResponse: Decodable, Sendable {
    let ok: Bool
    let planId: UUID
    let status: String

    enum CodingKeys: String, CodingKey {
        case ok
        case planId = "plan_id"
        case status
    }
}

struct TrainingPlanEdgeAdjustResponse: Decodable, Sendable {
    let planId: UUID
    let adjusted: Bool
    let effectiveFrom: String

    enum CodingKeys: String, CodingKey {
        case planId = "plan_id"
        case adjusted
        case effectiveFrom = "effective_from"
    }
}

actor TrainingPlanService: TrainingPlanManaging {
    private let dbQueue: DatabaseQueue
    private let apiClient: any TrainingPlanRouteAPIClient
    private let syncEngineProvider: @Sendable () -> SyncEngine?
    private let runtimeConfigured: @Sendable () -> Bool
    private let hasCloudSessionProvider: @Sendable () async -> Bool

    init(
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue,
        apiClient: any TrainingPlanRouteAPIClient = APIClient(),
        syncEngineProvider: @escaping @Sendable () -> SyncEngine? = { AppContainer.shared?.syncEngine },
        runtimeConfigured: @escaping @Sendable () -> Bool = { SupabaseConfig.isRuntimeConfigured },
        hasCloudSessionProvider: @escaping @Sendable () async -> Bool = {
            await MainActor.run { AuthManager.activeHasCloudSession }
        }
    ) {
        self.dbQueue = dbQueue
        self.apiClient = apiClient
        self.syncEngineProvider = syncEngineProvider
        self.runtimeConfigured = runtimeConfigured
        self.hasCloudSessionProvider = hasCloudSessionProvider
    }

    func generatePlan(_ draft: TrainingPlanGenerationDraft) async throws {
        try await requireCloudPlanAccess()

        let availableDays = draft.normalizedAvailableDays
        guard !availableDays.isEmpty else {
            throw TrainingError.invalidSet(reason: "Choose at least one training day")
        }

        try await ensureNoOtherActivePlan(excluding: nil)

        let payload = TrainingPlanEdgeGeneratePayload(
            name: draft.normalizedName,
            goal: draft.goal.rawValue,
            availableDays: availableDays,
            durationWeeks: min(max(draft.durationWeeks, 1), 24),
            sessionDurationMinutes: min(max(draft.sessionDurationMinutes, 10), 240),
            experienceLevel: draft.experienceLevel.rawValue,
            equipmentAccess: draft.equipmentAccess.rawValue,
            injuries: draft.normalizedInjuries
        )
        _ = try await apiClient.generateTrainingPlan(payload)
        try await refreshPlanState()
    }

    func updatePlan(_ draft: TrainingPlanUpdateDraft) async throws {
        try await requireCloudPlanAccess()

        if draft.status == .active {
            try await ensureNoOtherActivePlan(excluding: draft.id)
        }

        let payload = TrainingPlanEdgeUpdatePayload(
            name: draft.normalizedName,
            status: draft.status?.rawValue
        )
        guard payload.name != nil || payload.status != nil else {
            throw TrainingError.invalidSet(reason: "Update at least one field")
        }

        _ = try await apiClient.updateTrainingPlan(id: draft.id, payload: payload)
        try await refreshPlanState()
    }

    func adjustPlan(_ draft: TrainingPlanAdjustmentDraft) async throws {
        try await requireCloudPlanAccess()

        let payload = TrainingPlanEdgeAdjustPayload(
            reason: draft.reason.rawValue,
            adjustment: draft.adjustment.rawValue
        )
        _ = try await apiClient.adjustTrainingPlan(id: draft.id, payload: payload)
        try await refreshPlanState()
    }

    private func refreshPlanState() async throws {
        if let syncEngine = syncEngineProvider() {
            try await syncEngine.runSyncLoop()
        }
        await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
    }

    private func requireCloudPlanAccess() async throws {
        let hasCloudSession = await hasCloudSessionProvider()
        guard runtimeConfigured(), hasCloudSession else {
            throw TrainingError.planRequiresCloudSync
        }
    }

    private func ensureNoOtherActivePlan(excluding planId: UUID?) async throws {
        let userId = try await resolvedUserId()
        let hasOtherActivePlan = try await dbQueue.read { db in
            let sql: String
            let arguments: StatementArguments
            if let planId {
                sql = """
                    SELECT EXISTS(
                        SELECT 1
                        FROM training_plans
                        WHERE (user_id = ? OR user_id = ?)
                          AND status = 'active'
                          AND id NOT IN (?, ?)
                    )
                    """
                arguments = [userId, userId.uuidString, planId, planId.uuidString]
            } else {
                sql = """
                    SELECT EXISTS(
                        SELECT 1
                        FROM training_plans
                        WHERE (user_id = ? OR user_id = ?)
                          AND status = 'active'
                    )
                    """
                arguments = [userId, userId.uuidString]
            }
            return try Bool.fetchOne(db, sql: sql, arguments: arguments) ?? false
        }

        guard !hasOtherActivePlan else {
            throw TrainingError.planLimitReached(max: 1)
        }
    }

    private func resolvedUserId() async throws -> UUID {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        guard let authId else {
            throw TrainingError.planRequiresCloudSync
        }
        return try await dbQueue.read { db in
            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                throw TrainingError.planRequiresCloudSync
            }
            return userId
        }
    }
}

extension APIClient: TrainingPlanRouteAPIClient {
    func generateTrainingPlan(_ payload: TrainingPlanEdgeGeneratePayload) async throws -> TrainingPlanEdgeGenerateResponse {
        try await callEdgeRoute(
            function: "api-training-plan",
            route: "generate",
            method: "POST",
            queryItems: [],
            body: try JSONEncoder.supabase.encode(payload),
            headers: [:],
            maxAttempts: 3
        )
    }

    func updateTrainingPlan(id: UUID, payload: TrainingPlanEdgeUpdatePayload) async throws -> TrainingPlanEdgeUpdateResponse {
        try await callEdgeRoute(
            function: "api-training-plan",
            route: id.uuidString,
            method: "PATCH",
            queryItems: [],
            body: try JSONEncoder.supabase.encode(payload),
            headers: [:],
            maxAttempts: 3
        )
    }

    func adjustTrainingPlan(id: UUID, payload: TrainingPlanEdgeAdjustPayload) async throws -> TrainingPlanEdgeAdjustResponse {
        try await callEdgeRoute(
            function: "api-training-plan",
            route: "\(id.uuidString)/adjust",
            method: "PATCH",
            queryItems: [],
            body: try JSONEncoder.supabase.encode(payload),
            headers: [:],
            maxAttempts: 3
        )
    }
}
