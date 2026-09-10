import Foundation
import GRDB

protocol WorkoutSessionManaging: Sendable {
    func createManualWorkout(_ draft: WorkoutSessionDraft) async throws
    func loadWorkoutDetail(id: UUID, preferRemote: Bool) async throws -> WorkoutSessionDetail?
    func updateWorkout(_ draft: WorkoutSessionUpdateDraft) async throws
    func deleteWorkout(id: UUID) async throws -> Date
    func undoDeleteWorkout(id: UUID) async throws
}

protocol WorkoutSessionDetailAPIClient: Sendable {
    func fetchWorkoutDetail(id: UUID) async throws -> WorkoutSessionRemoteDetailResponse
}

struct WorkoutSessionDraft: Sendable {
    var id: UUID
    var startedAt: Date
    var sessionDate: String
    var startedTimezone: String?
    var startedUtcOffsetMinutes: Int?
    var endedAt: Date?
    var durationMinutes: Int?
    var workoutType: WorkoutType?
    var location: WorkoutLocation?
    var notes: String?
    var trainingPlanId: UUID?
    var perceivedExertionRpe: Int?
    var postFeeling: Int?
    var estimatedCalories: Int?
    var trimpScore: Double?
    var exercises: [WorkoutSessionDraftExercise]
}

struct WorkoutSessionUpdateDraft: Sendable {
    var id: UUID
    var startedAt: Date
    var sessionDate: String
    var startedTimezone: String?
    var startedUtcOffsetMinutes: Int?
    var endedAt: Date?
    var durationMinutes: Int?
    var workoutType: WorkoutType?
    var location: WorkoutLocation?
    var notes: String?
    var trainingPlanId: UUID?
    var perceivedExertionRpe: Int?
    var postFeeling: Int?
    var estimatedCalories: Int?
    var trimpScore: Double?
    var exercises: [WorkoutSessionDraftExercise]?
}

struct WorkoutSessionDraftExercise: Sendable {
    var id: UUID
    var exerciseId: UUID?
    var name: String?
    var category: ExerciseCategory? = nil
    var orderInSession: Int
    var durationSeconds: Int?
    var notes: String?
    var sets: [WorkoutSessionDraftSet]
}

struct WorkoutSessionDraftSet: Sendable {
    var id: UUID
    var setNumber: Int
    var weight: Double?
    var reps: Int?
    var rpe: Int?
    var restAfterSeconds: Int?
    var isWarmup: Bool
    var isFailure: Bool
    var isDropset: Bool
}

struct WorkoutSessionDetail: Equatable, Sendable {
    var session: WorkoutSession
    var exercises: [WorkoutSessionDetailExercise]
}

struct WorkoutSessionDetailExercise: Equatable, Sendable, Identifiable {
    var exercise: WorkoutExercise
    var name: String?
    var category: ExerciseCategory?
    var sets: [WorkoutSet]

    var id: UUID { exercise.id }
}

struct WorkoutSessionRemoteDetailResponse: Decodable, Sendable {
    struct Exercise: Decodable, Sendable {
        struct Set: Decodable, Sendable {
            let id: UUID
            var createdAt: Date? = nil
            var updatedAt: Date? = nil
            let setNumber: Int
            let weight: Double?
            let reps: Int?
            let rpe: Int?
            let restAfterSeconds: Int?
            let isWarmup: Bool
            let isFailure: Bool
            let isDropset: Bool

            enum CodingKeys: String, CodingKey {
                case id
                case createdAt = "created_at"
                case updatedAt = "updated_at"
                case setNumber = "set_number"
                case weight
                case reps
                case rpe
                case restAfterSeconds = "rest_after_seconds"
                case isWarmup = "is_warmup"
                case isFailure = "is_failure"
                case isDropset = "is_dropset"
            }
        }

        let id: UUID
        var createdAt: Date? = nil
        var updatedAt: Date? = nil
        let exerciseId: UUID?
        let name: String?
        var category: ExerciseCategory? = nil
        let orderInSession: Int?
        let totalSets: Int?
        let totalReps: Int?
        let totalVolume: Double?
        let maxWeight: Double?
        let durationSeconds: Int?
        let notes: String?
        let sets: [Set]

        enum CodingKeys: String, CodingKey {
            case id
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case exerciseId = "exercise_id"
            case name
            case category
            case orderInSession = "order_in_session"
            case totalSets = "total_sets"
            case totalReps = "total_reps"
            case totalVolume = "total_volume"
            case maxWeight = "max_weight"
            case durationSeconds = "duration_seconds"
            case notes
            case sets
        }
    }

    let id: UUID
    var createdAt: Date? = nil
    let startedAt: Date
    let endedAt: Date?
    let sessionDate: String
    let startedTimezone: String?
    let startedUtcOffsetMinutes: Int?
    let workoutType: WorkoutType?
    let source: WorkoutSource
    let totalVolume: Double?
    let totalSets: Int?
    let totalReps: Int?
    let estimatedCalories: Int?
    let trimpScore: Double?
    let perceivedExertionRpe: Int?
    let durationMinutes: Int?
    let location: WorkoutLocation?
    let trainingPlanId: UUID?
    let postFeeling: Int?
    let notes: String?
    let exercises: [Exercise]
    var updatedAt: Date? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case sessionDate = "session_date"
        case startedTimezone = "started_timezone"
        case startedUtcOffsetMinutes = "started_utc_offset_minutes"
        case workoutType = "workout_type"
        case source
        case totalVolume = "total_volume"
        case totalSets = "total_sets"
        case totalReps = "total_reps"
        case estimatedCalories = "estimated_calories"
        case trimpScore = "trimp_score"
        case perceivedExertionRpe = "perceived_exertion_rpe"
        case durationMinutes = "duration_minutes"
        case location
        case trainingPlanId = "training_plan_id"
        case postFeeling = "post_feeling"
        case notes
        case exercises
        case updatedAt = "updated_at"
    }
}

private struct WorkoutEdgePayload: Encodable {
    let id: UUID
    let startedAt: Date
    let sessionDate: String
    let startedTimezone: String?
    let startedUtcOffsetMinutes: Int?
    let endedAt: Date?
    let durationMinutes: Int?
    let workoutType: String?
    let location: String?
    let notes: String?
    let trainingPlanId: UUID?
    let perceivedExertionRpe: Int?
    let postFeeling: Int?
    let estimatedCalories: Int?
    let trimpScore: Double?
    let exercises: [WorkoutEdgeExercisePayload]

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case sessionDate = "session_date"
        case startedTimezone = "started_timezone"
        case startedUtcOffsetMinutes = "started_utc_offset_minutes"
        case endedAt = "ended_at"
        case durationMinutes = "duration_minutes"
        case workoutType = "workout_type"
        case location
        case notes
        case trainingPlanId = "training_plan_id"
        case perceivedExertionRpe = "perceived_exertion_rpe"
        case postFeeling = "post_feeling"
        case estimatedCalories = "estimated_calories"
        case trimpScore = "trimp_score"
        case exercises
    }
}

private struct WorkoutEdgePatchPayload: Encodable {
    let startedAt: Date
    let sessionDate: String
    let startedTimezone: String?
    let startedUtcOffsetMinutes: Int?
    let endedAt: Date?
    let durationMinutes: Int?
    let workoutType: String?
    let location: String?
    let notes: String?
    let trainingPlanId: UUID?
    let perceivedExertionRpe: Int?
    let postFeeling: Int?
    let estimatedCalories: Int?
    let trimpScore: Double?
    let exercises: [WorkoutEdgeExercisePayload]?

    enum CodingKeys: String, CodingKey {
        case startedAt = "started_at"
        case sessionDate = "session_date"
        case startedTimezone = "started_timezone"
        case startedUtcOffsetMinutes = "started_utc_offset_minutes"
        case endedAt = "ended_at"
        case durationMinutes = "duration_minutes"
        case workoutType = "workout_type"
        case location
        case notes
        case trainingPlanId = "training_plan_id"
        case perceivedExertionRpe = "perceived_exertion_rpe"
        case postFeeling = "post_feeling"
        case estimatedCalories = "estimated_calories"
        case trimpScore = "trimp_score"
        case exercises
    }
}

private struct WorkoutEdgeExercisePayload: Encodable {
    let id: UUID
    let exerciseId: UUID?
    let name: String?
    let category: String?
    let orderInSession: Int
    let durationSeconds: Int?
    let notes: String?
    let sets: [WorkoutEdgeSetPayload]

    enum CodingKeys: String, CodingKey {
        case id
        case exerciseId = "exercise_id"
        case name
        case category
        case orderInSession = "order_in_session"
        case durationSeconds = "duration_seconds"
        case notes
        case sets
    }
}

private struct WorkoutEdgeSetPayload: Encodable {
    let id: UUID
    let setNumber: Int
    let weight: Double?
    let reps: Int?
    let rpe: Int?
    let restAfterSeconds: Int?
    let isWarmup: Bool
    let isFailure: Bool
    let isDropset: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case setNumber = "set_number"
        case weight
        case reps
        case rpe
        case restAfterSeconds = "rest_after_seconds"
        case isWarmup = "is_warmup"
        case isFailure = "is_failure"
        case isDropset = "is_dropset"
    }
}

actor TrainingService {
    private let dbQueue: DatabaseQueue
    private let timeZoneHistoryStore: TimeZoneHistoryStore
    private let detailAPIClient: any WorkoutSessionDetailAPIClient

    init(
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue,
        timeZoneHistoryStore: TimeZoneHistoryStore? = nil,
        detailAPIClient: any WorkoutSessionDetailAPIClient = APIClient()
    ) {
        self.dbQueue = dbQueue
        self.timeZoneHistoryStore = timeZoneHistoryStore ?? TimeZoneHistoryStore(dbQueue: dbQueue)
        self.detailAPIClient = detailAPIClient
    }

    func createManualWorkout(_ draft: WorkoutSessionDraft) async throws {
        let userId = try await resolvedUserId(fallback: nil)
        let normalizedDraft = try await normalizedWorkoutDraft(draft, userId: userId)
        try await dbQueue.write { db in
            var preparedDraft = normalizedDraft
            preparedDraft.exercises = try Self.prepareDraftExercises(
                normalizedDraft.exercises,
                userId: userId,
                in: db
            )
            let materialized = try Self.materialize(
                draft: preparedDraft,
                userId: userId,
                source: normalizedDraft.trainingPlanId == nil ? .manual : .plan
            )
            try materialized.session.insert(db)
            for exercise in materialized.exercises {
                try exercise.exercise.insert(db)
                for set in exercise.sets {
                    try set.insert(db)
                }
            }
            try Self.linkTrainingPlanSessionIfNeeded(
                for: materialized.session,
                updatedAt: materialized.session.updatedAt,
                in: db
            )

            var event = OutboxEvent(
                id: materialized.session.id,
                httpMethod: .POST,
                path: "api-workouts-log",
                bodyJson: try JSONEncoder.supabase.encode(Self.makeCreatePayload(from: materialized)),
                priority: 100
            )
            event.headersJson = try Self.headersJson()
            try event.insert(db)
        }
        await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
    }

    func loadWorkoutDetail(id: UUID, preferRemote: Bool = true) async throws -> WorkoutSessionDetail? {
        let localDetail = try await loadLocalWorkoutDetail(id: id)
        let hasCloudSession = await MainActor.run { AuthManager.activeHasCloudSession }
        let shouldFetchRemote = preferRemote && hasCloudSession

        guard shouldFetchRemote else {
            return localDetail
        }

        do {
            guard let remoteDetail = try await loadRemoteWorkoutDetail(id: id, localDetail: localDetail) else {
                return localDetail
            }
            try await cacheWorkoutDetail(remoteDetail)
            return try await loadLocalWorkoutDetail(id: id)
        } catch {
            if localDetail == nil {
                throw error
            }
            return localDetail
        }
    }

    func updateWorkout(_ draft: WorkoutSessionUpdateDraft) async throws {
        let userId = try await dbQueue.read { db in
            try Self.requireSession(id: draft.id, in: db).userId
        }
        let normalizedDraft = try await normalizedWorkoutUpdateDraft(draft, userId: userId)
        try await dbQueue.write { db in
            var session = try Self.requireSession(id: normalizedDraft.id, in: db)
            guard !(session.source == .import && normalizedDraft.exercises != nil) else {
                throw TrainingError.importedWorkoutEditRestricted
            }

            let previousTrainingPlanId = session.trainingPlanId
            let previousSessionDate = session.sessionDate

            session.startedAt = normalizedDraft.startedAt
            session.sessionDate = normalizedDraft.sessionDate
            session.startedTimezone = Self.normalizedText(normalizedDraft.startedTimezone)
            session.startedUtcOffsetMinutes = normalizedDraft.startedUtcOffsetMinutes
            session.endedAt = normalizedDraft.endedAt
            session.durationMinutes = normalizedDraft.durationMinutes
            session.workoutType = normalizedDraft.workoutType
            session.location = normalizedDraft.location
            session.notes = Self.normalizedText(normalizedDraft.notes)
            session.trainingPlanId = normalizedDraft.trainingPlanId
            if session.source != .import {
                session.source = normalizedDraft.trainingPlanId == nil ? .manual : .plan
            }
            session.perceivedExertionRpe = normalizedDraft.perceivedExertionRpe
            session.postFeeling = normalizedDraft.postFeeling
            session.estimatedCalories = normalizedDraft.estimatedCalories
            session.trimpScore = normalizedDraft.trimpScore
            session.updatedAt = Date()

            var materializedExercises: [WorkoutSessionDetailExercise]? = nil
            if let exercises = normalizedDraft.exercises {
                let preparedExercises = try Self.prepareDraftExercises(
                    exercises,
                    userId: session.userId,
                    in: db
                )
                let materialized = try Self.materializeExercises(
                    preparedExercises,
                    sessionId: session.id,
                    userId: session.userId
                )
                materializedExercises = materialized
                session.totalSets = materialized.reduce(0) { $0 + ($1.exercise.totalSets ?? 0) }
                session.totalReps = materialized.reduce(0) { $0 + ($1.exercise.totalReps ?? 0) }
                session.totalVolume = materialized.reduce(0) { $0 + ($1.exercise.totalVolume ?? 0) }
            }

            if session.durationMinutes == nil,
               let endedAt = session.endedAt {
                session.durationMinutes = max(0, Int(endedAt.timeIntervalSince(session.startedAt) / 60))
            }

            try session.update(db)
            try Self.reconcileTrainingPlanSessionLinkage(
                workoutId: session.id,
                previousTrainingPlanId: previousTrainingPlanId,
                previousSessionDate: previousSessionDate,
                session: session,
                in: db
            )

            if let materializedExercises {
                try db.execute(
                    sql: """
                        DELETE FROM workout_exercises
                        WHERE session_id = ? OR session_id = ?
                        """,
                    arguments: [session.id, session.id.uuidString]
                )

                for exercise in materializedExercises {
                    try exercise.exercise.insert(db)
                    for set in exercise.sets {
                        try set.insert(db)
                    }
                }
            }

            let payload = Self.makePatchPayload(
                session: session,
                exercises: materializedExercises
            )

            var event = OutboxEvent(
                id: UUID(),
                httpMethod: .PATCH,
                path: "api-workouts/\(session.id.uuidString)",
                bodyJson: try JSONEncoder.supabase.encode(payload),
                priority: 110
            )
            event.headersJson = try Self.headersJson()
            event.dependsOn = Self.latestMutationDependency(for: session.id, in: db)
            try event.insert(db)
        }
        await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
    }

    func deleteWorkout(id: UUID) async throws -> Date {
        let deletedAt = Date()
        try await dbQueue.write { db in
            var session = try Self.requireSession(id: id, in: db)
            guard session.deletedAt == nil else {
                throw TrainingError.workoutNotFound
            }

            session.deletedAt = deletedAt
            session.deletedReason = .userDeleted
            session.updatedAt = deletedAt
            try session.update(db)
            try Self.unlinkTrainingPlanSessionIfNeeded(
                workoutId: session.id,
                trainingPlanId: session.trainingPlanId,
                sessionDate: session.sessionDate,
                updatedAt: deletedAt,
                in: db
            )

            var event = OutboxEvent(
                id: UUID(),
                httpMethod: .DELETE,
                path: "api-workouts/\(id.uuidString)",
                bodyJson: Data("{}".utf8),
                priority: 120
            )
            event.headersJson = try Self.headersJson()
            event.dependsOn = Self.latestMutationDependency(for: id, in: db)
            try event.insert(db)
        }
        await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
        return deletedAt
    }

    func undoDeleteWorkout(id: UUID) async throws {
        try await dbQueue.write { db in
            var session = try Self.requireSession(id: id, in: db)
            guard let deletedAt = session.deletedAt else {
                throw TrainingError.workoutNotFound
            }
            guard deletedAt >= Date().addingTimeInterval(-24 * 60 * 60) else {
                throw TrainingError.undoExpired
            }

            session.deletedAt = nil
            session.deletedReason = nil
            session.updatedAt = Date()
            try session.update(db)
            try Self.linkTrainingPlanSessionIfNeeded(
                for: session,
                updatedAt: session.updatedAt,
                in: db
            )

            var event = OutboxEvent(
                id: UUID(),
                httpMethod: .POST,
                path: "api-workouts/\(id.uuidString)/undo",
                bodyJson: Data("{}".utf8),
                priority: 130
            )
            event.headersJson = try Self.headersJson()
            event.dependsOn = Self.latestMutationDependency(for: id, in: db)
            try event.insert(db)
        }
        await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
    }

    private func loadLocalWorkoutDetail(id: UUID) async throws -> WorkoutSessionDetail? {
        try await dbQueue.read { db in
            guard let session = try WorkoutSession.fetchOne(
                db,
                sql: """
                    SELECT *
                    FROM workout_sessions
                    WHERE id = ? OR id = ?
                    LIMIT 1
                    """,
                arguments: [id, id.uuidString]
            ) else {
                return nil
            }

            let exercises = try WorkoutExercise.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM workout_exercises
                    WHERE session_id = ? OR session_id = ?
                    ORDER BY order_in_session ASC, created_at ASC
                    """,
                arguments: [id, id.uuidString]
            )
            let exerciseIds = exercises.map(\.id)
            let sets: [WorkoutSet]
            if exerciseIds.isEmpty {
                sets = []
            } else {
                var arguments: StatementArguments = [session.userId, session.userId.uuidString]
                arguments += StatementArguments(exerciseIds)
                sets = try WorkoutSet.fetchAll(
                    db,
                    sql: """
                        SELECT *
                        FROM workout_sets
                        WHERE (user_id = ? OR user_id = ?)
                          AND exercise_entry_id IN (\(exerciseIds.map { _ in "?" }.joined(separator: ",")))
                        ORDER BY exercise_entry_id ASC, set_number ASC
                        """,
                    arguments: arguments
                )
            }

            let exerciseNames = try Self.exerciseNameMap(
                db: db,
                catalogIds: exercises.compactMap(\.exerciseId)
            )
            let exerciseCategories = try Self.exerciseCategoryMap(
                db: db,
                catalogIds: exercises.compactMap(\.exerciseId)
            )
            let setsByExercise = Dictionary(grouping: sets, by: \.exerciseEntryId)
            return WorkoutSessionDetail(
                session: session,
                exercises: exercises.map { exercise in
                    WorkoutSessionDetailExercise(
                        exercise: exercise,
                        name: exercise.exerciseId.flatMap { exerciseNames[$0] },
                        category: exercise.exerciseId.flatMap { exerciseCategories[$0] },
                        sets: setsByExercise[exercise.id] ?? []
                    )
                }
            )
        }
    }

    private func loadRemoteWorkoutDetail(
        id: UUID,
        localDetail: WorkoutSessionDetail?
    ) async throws -> WorkoutSessionDetail? {
        let response = try await detailAPIClient.fetchWorkoutDetail(id: id)
        let userId = try await resolvedUserId(fallback: localDetail?.session.userId)

        var session = localDetail?.session ?? WorkoutSession(
            id: response.id,
            userId: userId,
            startedAt: response.startedAt,
            sessionDate: response.sessionDate,
            source: response.source
        )
        session.userId = userId
        session.startedAt = response.startedAt
        session.endedAt = response.endedAt
        session.sessionDate = response.sessionDate
        session.startedTimezone = response.startedTimezone
        session.startedUtcOffsetMinutes = response.startedUtcOffsetMinutes
        session.workoutType = response.workoutType
        session.source = response.source
        session.totalVolume = response.totalVolume
        session.totalSets = response.totalSets
        session.totalReps = response.totalReps
        session.estimatedCalories = response.estimatedCalories
        session.trimpScore = response.trimpScore
        session.perceivedExertionRpe = response.perceivedExertionRpe
        session.durationMinutes = response.durationMinutes
        session.location = response.location
        session.trainingPlanId = response.trainingPlanId
        session.postFeeling = response.postFeeling
        session.notes = response.notes
        session.deletedAt = nil
        session.deletedReason = nil
        session.createdAt = response.createdAt ?? .distantPast
        session.updatedAt = response.updatedAt ?? .distantPast

        let categoryMap = try await dbQueue.read { db in
            try Self.exerciseCategoryMap(
                db: db,
                catalogIds: response.exercises.compactMap(\.exerciseId)
            )
        }

        let exercises = response.exercises.map { exercise in
            var entry = localDetail?.exercises.first(where: { $0.exercise.id == exercise.id })?.exercise ?? WorkoutExercise(
                id: exercise.id,
                sessionId: response.id,
                exerciseId: exercise.exerciseId,
                orderInSession: exercise.orderInSession
            )
            entry.sessionId = response.id
            entry.exerciseId = exercise.exerciseId
            entry.orderInSession = exercise.orderInSession
            entry.totalSets = exercise.totalSets
            entry.totalReps = exercise.totalReps
            entry.totalVolume = exercise.totalVolume
            entry.maxWeight = exercise.maxWeight
            entry.durationSeconds = exercise.durationSeconds
            entry.notes = exercise.notes
            entry.createdAt = exercise.createdAt ?? .distantPast
            entry.updatedAt = exercise.updatedAt ?? .distantPast

            let sets = exercise.sets.map { remoteSet in
                var set = localDetail?.exercises
                    .flatMap(\.sets)
                    .first(where: { $0.id == remoteSet.id }) ?? WorkoutSet(
                        id: remoteSet.id,
                        exerciseEntryId: exercise.id,
                        userId: userId,
                        setNumber: remoteSet.setNumber
                    )
                set.exerciseEntryId = exercise.id
                set.userId = userId
                set.setNumber = remoteSet.setNumber
                set.weight = remoteSet.weight
                set.reps = remoteSet.reps
                set.rpe = remoteSet.rpe
                set.restAfterSeconds = remoteSet.restAfterSeconds
                set.isWarmup = remoteSet.isWarmup
                set.isFailure = remoteSet.isFailure
                set.isDropset = remoteSet.isDropset
                set.createdAt = remoteSet.createdAt ?? .distantPast
                set.updatedAt = remoteSet.updatedAt ?? .distantPast
                return set
            }

            return WorkoutSessionDetailExercise(
                exercise: entry,
                name: exercise.name,
                category: exercise.category ?? exercise.exerciseId.flatMap { categoryMap[$0] },
                sets: sets
            )
        }

        return WorkoutSessionDetail(session: session, exercises: exercises)
    }

    private func cacheWorkoutDetail(_ detail: WorkoutSessionDetail) async throws {
        try await dbQueue.write { db in
            // Recheck in the write transaction: an edit may occur during the GET.
            let entityId = detail.session.id
            let pending = try OutboxEvent.fetchAll(db, sql: "SELECT * FROM outbox_events WHERE status NOT IN (?, ?)", arguments: [OutboxStatus.succeeded.rawValue, OutboxStatus.cancelled.rawValue])
            guard !pending.contains(where: { event in
                event.id == entityId || event.path.lowercased().contains(entityId.uuidString.lowercased()) ||
                String(data: event.bodyJson, encoding: .utf8)?.lowercased().contains(entityId.uuidString.lowercased()) == true
            }) else { return }
            if let existing = try WorkoutSession.fetchOne(db, sql: "SELECT * FROM workout_sessions WHERE id = ? OR id = ?", arguments: [entityId, entityId.uuidString]),
               existing.updatedAt > detail.session.updatedAt { return }
            try detail.session.save(db)
            try db.execute(
                sql: """
                    DELETE FROM workout_exercises
                    WHERE session_id = ? OR session_id = ?
                    """,
                arguments: [detail.session.id, detail.session.id.uuidString]
            )
            for exercise in detail.exercises {
                try exercise.exercise.insert(db)
                for set in exercise.sets {
                    try set.insert(db)
                }
            }
        }
    }

    private func resolvedUserId(fallback: UUID?) async throws -> UUID {
        if let fallback {
            return fallback
        }
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        guard let authId else {
            throw SyncError.networkUnavailable
        }
        return try await dbQueue.read { db in
            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                throw SyncError.networkUnavailable
            }
            return userId
        }
    }

    private func resolveManualLocalDayContext(
        forDayString dayString: String,
        referenceDate: Date,
        userId: UUID
    ) async throws -> HistoricalLocalDayContext {
        _ = try await timeZoneHistoryStore.captureCurrentTimeZoneIfNeeded(
            userId: userId,
            recordedAt: referenceDate,
            source: .manualEntry
        )
        return try await timeZoneHistoryStore.resolveLocalDayContext(
            forDayString: dayString,
            userId: userId,
            preferredDate: referenceDate
        )
    }

    private func normalizedWorkoutDraft(
        _ draft: WorkoutSessionDraft,
        userId: UUID
    ) async throws -> WorkoutSessionDraft {
        let dayContext = try await resolveManualLocalDayContext(
            forDayString: draft.sessionDate,
            referenceDate: draft.startedAt,
            userId: userId
        )
        var normalizedDraft = draft
        normalizedDraft.sessionDate = dayContext.dayString
        normalizedDraft.startedTimezone = dayContext.timeZoneIdentifier
        normalizedDraft.startedUtcOffsetMinutes = dayContext.utcOffsetMinutes
        return normalizedDraft
    }

    private func normalizedWorkoutUpdateDraft(
        _ draft: WorkoutSessionUpdateDraft,
        userId: UUID
    ) async throws -> WorkoutSessionUpdateDraft {
        let dayContext = try await resolveManualLocalDayContext(
            forDayString: draft.sessionDate,
            referenceDate: draft.startedAt,
            userId: userId
        )
        var normalizedDraft = draft
        normalizedDraft.sessionDate = dayContext.dayString
        normalizedDraft.startedTimezone = dayContext.timeZoneIdentifier
        normalizedDraft.startedUtcOffsetMinutes = dayContext.utcOffsetMinutes
        return normalizedDraft
    }

    private nonisolated static func prepareDraftExercises(
        _ exercises: [WorkoutSessionDraftExercise],
        userId: UUID,
        in db: Database
    ) throws -> [WorkoutSessionDraftExercise] {
        try exercises.map { draftExercise in
            let resolvedEntry = try ExerciseCatalogSupport.resolveEntry(
                requestedId: draftExercise.exerciseId,
                name: draftExercise.name,
                category: draftExercise.category,
                userId: userId,
                in: db
            )

            var prepared = draftExercise
            prepared.exerciseId = resolvedEntry?.id
            prepared.name = resolvedEntry?.name ?? normalizedText(draftExercise.name)
            prepared.category = resolvedEntry?.category ?? draftExercise.category
            return prepared
        }
    }

    private nonisolated static func materialize(
        draft: WorkoutSessionDraft,
        userId: UUID,
        source: WorkoutSource
    ) throws -> WorkoutSessionDetail {
        guard !draft.exercises.isEmpty else {
            throw TrainingError.invalidSet(reason: "At least one exercise is required")
        }

        let exercises = try materializeExercises(
            draft.exercises,
            sessionId: draft.id,
            userId: userId
        )
        let totalSets = exercises.reduce(0) { $0 + ($1.exercise.totalSets ?? 0) }
        let totalReps = exercises.reduce(0) { $0 + ($1.exercise.totalReps ?? 0) }
        let totalVolume = exercises.reduce(0.0) { $0 + ($1.exercise.totalVolume ?? 0) }

        var session = WorkoutSession(
            id: draft.id,
            userId: userId,
            startedAt: draft.startedAt,
            sessionDate: draft.sessionDate,
            source: source
        )
        session.startedTimezone = normalizedText(draft.startedTimezone)
        session.startedUtcOffsetMinutes = draft.startedUtcOffsetMinutes
        session.workoutType = draft.workoutType
        session.location = draft.location
        session.notes = normalizedText(draft.notes)
        session.trainingPlanId = draft.trainingPlanId
        session.perceivedExertionRpe = draft.perceivedExertionRpe
        session.postFeeling = draft.postFeeling
        session.estimatedCalories = draft.estimatedCalories
        session.trimpScore = draft.trimpScore
        session.endedAt = draft.endedAt
        session.durationMinutes = draft.durationMinutes
        session.totalSets = totalSets > 0 ? totalSets : nil
        session.totalReps = totalReps > 0 ? totalReps : nil
        session.totalVolume = totalVolume > 0 ? totalVolume : nil

        if session.durationMinutes == nil,
           let endedAt = session.endedAt {
            session.durationMinutes = max(0, Int(endedAt.timeIntervalSince(session.startedAt) / 60))
        }

        return WorkoutSessionDetail(session: session, exercises: exercises)
    }

    private nonisolated static func materializeExercises(
        _ exercises: [WorkoutSessionDraftExercise],
        sessionId: UUID,
        userId: UUID
    ) throws -> [WorkoutSessionDetailExercise] {
        guard !exercises.isEmpty else {
            throw TrainingError.invalidSet(reason: "At least one exercise is required")
        }

        return try exercises.enumerated().map { index, draftExercise in
            let sets = try materializeSets(
                draftExercise.sets,
                exerciseEntryId: draftExercise.id,
                userId: userId
            )
            let totalReps = sets.reduce(0) { $0 + ($1.reps ?? 0) }
            let totalVolume = sets.reduce(0.0) { $0 + (($1.weight ?? 0) * Double($1.reps ?? 0)) }
            let maxWeight = sets.compactMap(\.weight).max() ?? 0

            var exercise = WorkoutExercise(
                id: draftExercise.id,
                sessionId: sessionId,
                exerciseId: draftExercise.exerciseId,
                orderInSession: draftExercise.orderInSession > 0 ? draftExercise.orderInSession : (index + 1)
            )
            exercise.durationSeconds = draftExercise.durationSeconds
            exercise.notes = normalizedText(draftExercise.notes)
            exercise.totalSets = sets.count
            exercise.totalReps = totalReps
            exercise.totalVolume = totalVolume > 0 ? totalVolume : nil
            exercise.maxWeight = maxWeight > 0 ? maxWeight : nil
            return WorkoutSessionDetailExercise(
                exercise: exercise,
                name: normalizedText(draftExercise.name),
                category: draftExercise.category,
                sets: sets
            )
        }
    }

    private nonisolated static func materializeSets(
        _ sets: [WorkoutSessionDraftSet],
        exerciseEntryId: UUID,
        userId: UUID
    ) throws -> [WorkoutSet] {
        guard !sets.isEmpty else {
            throw TrainingError.invalidSet(reason: "Each exercise needs at least one set")
        }

        return try sets.enumerated().map { index, draftSet in
            if let reps = draftSet.reps, reps < 0 {
                throw TrainingError.invalidSet(reason: "Reps cannot be negative")
            }
            if let weight = draftSet.weight, weight < 0 {
                throw TrainingError.invalidSet(reason: "Weight cannot be negative")
            }
            if let restAfterSeconds = draftSet.restAfterSeconds, restAfterSeconds < 0 {
                throw TrainingError.invalidSet(reason: "Rest cannot be negative")
            }

            var set = WorkoutSet(
                id: draftSet.id,
                exerciseEntryId: exerciseEntryId,
                userId: userId,
                setNumber: draftSet.setNumber > 0 ? draftSet.setNumber : (index + 1)
            )
            set.weight = draftSet.weight
            set.reps = draftSet.reps
            set.rpe = draftSet.rpe
            set.restAfterSeconds = draftSet.restAfterSeconds
            set.isWarmup = draftSet.isWarmup
            set.isFailure = draftSet.isFailure
            set.isDropset = draftSet.isDropset
            return set
        }
    }

    private nonisolated static func makeCreatePayload(from detail: WorkoutSessionDetail) -> WorkoutEdgePayload {
        WorkoutEdgePayload(
            id: detail.session.id,
            startedAt: detail.session.startedAt,
            sessionDate: detail.session.sessionDate,
            startedTimezone: normalizedText(detail.session.startedTimezone),
            startedUtcOffsetMinutes: detail.session.startedUtcOffsetMinutes,
            endedAt: detail.session.endedAt,
            durationMinutes: detail.session.durationMinutes,
            workoutType: detail.session.workoutType?.rawValue,
            location: detail.session.location?.rawValue,
            notes: normalizedText(detail.session.notes),
            trainingPlanId: detail.session.trainingPlanId,
            perceivedExertionRpe: detail.session.perceivedExertionRpe,
            postFeeling: detail.session.postFeeling,
            estimatedCalories: detail.session.estimatedCalories,
            trimpScore: detail.session.trimpScore,
            exercises: detail.exercises.map(makeExercisePayload(_:))
        )
    }

    private nonisolated static func makePatchPayload(
        session: WorkoutSession,
        exercises: [WorkoutSessionDetailExercise]?
    ) -> WorkoutEdgePatchPayload {
        WorkoutEdgePatchPayload(
            startedAt: session.startedAt,
            sessionDate: session.sessionDate,
            startedTimezone: normalizedText(session.startedTimezone),
            startedUtcOffsetMinutes: session.startedUtcOffsetMinutes,
            endedAt: session.endedAt,
            durationMinutes: session.durationMinutes,
            workoutType: session.workoutType?.rawValue,
            location: session.location?.rawValue,
            notes: normalizedText(session.notes),
            trainingPlanId: session.trainingPlanId,
            perceivedExertionRpe: session.perceivedExertionRpe,
            postFeeling: session.postFeeling,
            estimatedCalories: session.estimatedCalories,
            trimpScore: session.trimpScore,
            exercises: exercises?.map(makeExercisePayload(_:))
        )
    }

    private nonisolated static func reconcileTrainingPlanSessionLinkage(
        workoutId: UUID,
        previousTrainingPlanId: UUID?,
        previousSessionDate: String,
        session: WorkoutSession,
        in db: Database
    ) throws {
        let didPlanReferenceChange =
            previousTrainingPlanId != session.trainingPlanId ||
            previousSessionDate != session.sessionDate

        if didPlanReferenceChange {
            try unlinkTrainingPlanSessionIfNeeded(
                workoutId: workoutId,
                trainingPlanId: previousTrainingPlanId,
                sessionDate: previousSessionDate,
                updatedAt: session.updatedAt,
                in: db
            )
        }

        try linkTrainingPlanSessionIfNeeded(
            for: session,
            updatedAt: session.updatedAt,
            in: db
        )
    }

    private nonisolated static func linkTrainingPlanSessionIfNeeded(
        for session: WorkoutSession,
        updatedAt: Date,
        in db: Database
    ) throws {
        guard let trainingPlanId = session.trainingPlanId else { return }

        guard let rowId = try findTrainingPlanSessionId(
            workoutId: session.id,
            trainingPlanId: trainingPlanId,
            sessionDate: session.sessionDate,
            in: db
        ) else {
            return
        }

        try db.execute(
            sql: """
                UPDATE training_plan_sessions
                SET status = 'completed',
                    actual_session_id = ?,
                    linked_workout_id = ?,
                    updated_at = ?
                WHERE id = ? OR id = ?
                """,
            arguments: [session.id, session.id.uuidString, updatedAt, rowId, rowId.uuidString]
        )
    }

    private nonisolated static func unlinkTrainingPlanSessionIfNeeded(
        workoutId: UUID,
        trainingPlanId: UUID?,
        sessionDate: String,
        updatedAt: Date,
        in db: Database
    ) throws {
        guard let rowId = try findTrainingPlanSessionId(
            workoutId: workoutId,
            trainingPlanId: trainingPlanId,
            sessionDate: sessionDate,
            in: db
        ) else {
            return
        }

        try db.execute(
            sql: """
                UPDATE training_plan_sessions
                SET status = 'planned',
                    actual_session_id = NULL,
                    linked_workout_id = NULL,
                    updated_at = ?
                WHERE id = ? OR id = ?
                """,
            arguments: [updatedAt, rowId, rowId.uuidString]
        )
    }

    private nonisolated static func findTrainingPlanSessionId(
        workoutId: UUID,
        trainingPlanId: UUID?,
        sessionDate: String,
        in db: Database
    ) throws -> UUID? {
        if let linkedRowId = try UUID.fetchOne(
            db,
            sql: """
                SELECT id
                FROM training_plan_sessions
                WHERE actual_session_id IN (?, ?)
                   OR linked_workout_id IN (?, ?)
                ORDER BY updated_at DESC
                LIMIT 1
                """,
            arguments: [workoutId, workoutId.uuidString, workoutId, workoutId.uuidString]
        ) {
            return linkedRowId
        }

        guard let trainingPlanId else { return nil }

        return try UUID.fetchOne(
            db,
            sql: """
                SELECT id
                FROM training_plan_sessions
                WHERE (training_plan_id = ? OR training_plan_id = ?)
                  AND planned_date = ?
                  AND status IN ('planned', 'rescheduled', 'scheduled', 'modified', 'completed')
                  AND (
                    actual_session_id IS NULL
                    OR actual_session_id IN (?, ?)
                    OR linked_workout_id IN (?, ?)
                  )
                ORDER BY
                  CASE
                    WHEN actual_session_id IN (?, ?) THEN 0
                    WHEN linked_workout_id IN (?, ?) THEN 0
                    WHEN status = 'completed' THEN 1
                    ELSE 2
                  END,
                  updated_at DESC
                LIMIT 1
                """,
            arguments: [
                trainingPlanId,
                trainingPlanId.uuidString,
                sessionDate,
                workoutId,
                workoutId.uuidString,
                workoutId,
                workoutId.uuidString,
                workoutId,
                workoutId.uuidString,
                workoutId,
                workoutId.uuidString
            ]
        )
    }

    private nonisolated static func makeExercisePayload(_ exercise: WorkoutSessionDetailExercise) -> WorkoutEdgeExercisePayload {
        WorkoutEdgeExercisePayload(
            id: exercise.exercise.id,
            exerciseId: exercise.exercise.exerciseId,
            name: normalizedText(exercise.name),
            category: exercise.category?.rawValue,
            orderInSession: exercise.exercise.orderInSession ?? 0,
            durationSeconds: exercise.exercise.durationSeconds,
            notes: normalizedText(exercise.exercise.notes),
            sets: exercise.sets.map {
                WorkoutEdgeSetPayload(
                    id: $0.id,
                    setNumber: $0.setNumber,
                    weight: $0.weight,
                    reps: $0.reps,
                    rpe: $0.rpe,
                    restAfterSeconds: $0.restAfterSeconds,
                    isWarmup: $0.isWarmup,
                    isFailure: $0.isFailure,
                    isDropset: $0.isDropset
                )
            }
        )
    }

    private nonisolated static func requireSession(id: UUID, in db: Database) throws -> WorkoutSession {
        guard let session = try WorkoutSession.fetchOne(
            db,
            sql: """
                SELECT *
                FROM workout_sessions
                WHERE id = ? OR id = ?
                LIMIT 1
                """,
            arguments: [id, id.uuidString]
        ) else {
            throw TrainingError.workoutNotFound
        }
        return session
    }

    private nonisolated static func exerciseNameMap(
        db: Database,
        catalogIds: [UUID]
    ) throws -> [UUID: String] {
        guard !catalogIds.isEmpty else { return [:] }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, name
                FROM exercise_catalog
                WHERE id IN (\(catalogIds.map { _ in "?" }.joined(separator: ",")))
                """,
            arguments: StatementArguments(catalogIds)
        )
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let id = MixedUUIDStorage.decode(from: row, column: "id"),
                  let name: String = row["name"] else {
                return nil
            }
            return (id, name)
        })
    }

    private nonisolated static func exerciseCategoryMap(
        db: Database,
        catalogIds: [UUID]
    ) throws -> [UUID: ExerciseCategory] {
        guard !catalogIds.isEmpty else { return [:] }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, category
                FROM exercise_catalog
                WHERE id IN (\(catalogIds.map { _ in "?" }.joined(separator: ",")))
                """,
            arguments: StatementArguments(catalogIds)
        )
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let id = MixedUUIDStorage.decode(from: row, column: "id"),
                  let rawCategory: String = row["category"],
                  let category = ExerciseCategory(rawValue: rawCategory) else {
                return nil
            }
            return (id, category)
        })
    }

    private nonisolated static func latestMutationDependency(for sessionId: UUID, in db: Database) -> UUID? {
        try? UUID.fetchOne(
            db,
            sql: """
                SELECT id
                FROM outbox_events
                WHERE (
                        id = ? OR id = ?
                     OR path = ?
                     OR path = ?
                  )
                  AND status IN (?, ?, ?)
                ORDER BY created_at_local DESC
                LIMIT 1
                """,
            arguments: [
                sessionId,
                sessionId.uuidString,
                "api-workouts/\(sessionId.uuidString)",
                "api-workouts/\(sessionId.uuidString)/undo",
                OutboxStatus.pending.rawValue,
                OutboxStatus.failedRetryable.rawValue,
                OutboxStatus.inFlight.rawValue
            ]
        ) ?? pendingCreateDependency(for: sessionId, in: db)
    }

    private nonisolated static func pendingCreateDependency(for sessionId: UUID, in db: Database) -> UUID? {
        (try? UUID.fetchOne(
            db,
            sql: """
                SELECT id
                FROM outbox_events
                WHERE (id = ? OR id = ?)
                  AND path = 'api-workouts-log'
                  AND status IN (?, ?, ?)
                LIMIT 1
                """,
            arguments: [
                sessionId,
                sessionId.uuidString,
                OutboxStatus.pending.rawValue,
                OutboxStatus.failedRetryable.rawValue,
                OutboxStatus.inFlight.rawValue
            ]
        )) ?? (try? UUID.fetchOne(
            db,
            sql: """
                SELECT id
                FROM outbox_events
                WHERE path = 'rest/v1/workout_sessions'
                  AND CAST(body_json AS TEXT) LIKE ?
                  AND status IN (?, ?, ?)
                ORDER BY created_at_local DESC
                LIMIT 1
                """,
            arguments: [
                "%\(sessionId.uuidString)%",
                OutboxStatus.pending.rawValue,
                OutboxStatus.failedRetryable.rawValue,
                OutboxStatus.inFlight.rawValue
            ]
        ))
    }

    private nonisolated static func headersJson() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
    }

    private nonisolated static func normalizedText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

extension TrainingService: WorkoutSessionManaging {}

extension APIClient: WorkoutSessionDetailAPIClient {
    func fetchWorkoutDetail(id: UUID) async throws -> WorkoutSessionRemoteDetailResponse {
        try await callEdgeRoute(
            function: "api-workouts",
            route: id.uuidString,
            method: "GET",
            queryItems: [],
            body: nil,
            headers: [:],
            maxAttempts: 3
        )
    }
}
