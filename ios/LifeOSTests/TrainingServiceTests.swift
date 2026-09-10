import Foundation
import GRDB
import XCTest
@testable import LifeOS

private actor WorkoutDetailClientMock: WorkoutSessionDetailAPIClient {
    private let response: WorkoutSessionRemoteDetailResponse
    private(set) var requestedIds: [UUID] = []

    init(response: WorkoutSessionRemoteDetailResponse) {
        self.response = response
    }

    func fetchWorkoutDetail(id: UUID) async throws -> WorkoutSessionRemoteDetailResponse {
        requestedIds.append(id)
        return response
    }

    func requestCount() -> Int {
        requestedIds.count
    }
}

private actor WorkoutSessionManagerMock: WorkoutSessionManaging {
    private var createdDrafts: [WorkoutSessionDraft] = []
    private var loadedDetails: [UUID: WorkoutSessionDetail?] = [:]
    private var updatedDrafts: [WorkoutSessionUpdateDraft] = []
    private var deletedIds: [UUID] = []
    private var undoneIds: [UUID] = []

    func createManualWorkout(_ draft: WorkoutSessionDraft) async throws {
        createdDrafts.append(draft)
    }

    func loadWorkoutDetail(id: UUID, preferRemote: Bool) async throws -> WorkoutSessionDetail? {
        _ = preferRemote
        return loadedDetails[id] ?? nil
    }

    func updateWorkout(_ draft: WorkoutSessionUpdateDraft) async throws {
        updatedDrafts.append(draft)
    }

    func deleteWorkout(id: UUID) async throws -> Date {
        deletedIds.append(id)
        return Date()
    }

    func undoDeleteWorkout(id: UUID) async throws {
        undoneIds.append(id)
    }

    func setLoadedDetail(_ detail: WorkoutSessionDetail?, for id: UUID) {
        loadedDetails[id] = detail
    }

    func createdDraftsSnapshot() -> [WorkoutSessionDraft] {
        createdDrafts
    }
}

private actor TrainingPlanRouteAPIClientMock: TrainingPlanRouteAPIClient {
    private(set) var generatePayloads: [TrainingPlanEdgeGeneratePayload] = []
    private(set) var updateRequests: [(UUID, TrainingPlanEdgeUpdatePayload)] = []
    private(set) var adjustRequests: [(UUID, TrainingPlanEdgeAdjustPayload)] = []

    func generateTrainingPlan(_ payload: TrainingPlanEdgeGeneratePayload) async throws -> TrainingPlanEdgeGenerateResponse {
        generatePayloads.append(payload)
        return TrainingPlanEdgeGenerateResponse(planId: UUID(), status: "active", weeksGenerated: payload.durationWeeks)
    }

    func updateTrainingPlan(id: UUID, payload: TrainingPlanEdgeUpdatePayload) async throws -> TrainingPlanEdgeUpdateResponse {
        updateRequests.append((id, payload))
        return TrainingPlanEdgeUpdateResponse(ok: true, planId: id, status: payload.status ?? "active")
    }

    func adjustTrainingPlan(id: UUID, payload: TrainingPlanEdgeAdjustPayload) async throws -> TrainingPlanEdgeAdjustResponse {
        adjustRequests.append((id, payload))
        return TrainingPlanEdgeAdjustResponse(planId: id, adjusted: true, effectiveFrom: "2026-03-12")
    }
}

@MainActor
final class TrainingServiceTests: XCTestCase {

    override func tearDown() {
        AuthManager.setActiveAuthIdForTests(nil)
        AuthManager._testSetActiveHasCloudSession(false)
        super.tearDown()
    }

    nonisolated private static func insertUser(_ db: Database, userId: UUID, authId: UUID) throws {
        var user = User(id: userId, authId: authId, timezone: "UTC", units: .metric)
        user.weightKg = 78
        try user.insert(db)
    }

    nonisolated private static func insertSession(
        _ db: Database,
        id: UUID,
        userId: UUID,
        source: WorkoutSource = .manual
    ) throws -> WorkoutSession {
        var session = WorkoutSession(
            id: id,
            userId: userId,
            startedAt: Date(timeIntervalSince1970: 1_773_331_200),
            sessionDate: "2026-03-12",
            source: source
        )
        session.workoutType = .strength
        session.durationMinutes = 45
        session.totalSets = 2
        session.totalReps = 10
        session.totalVolume = 1_000
        session.perceivedExertionRpe = 7
        session.startedTimezone = "UTC"
        session.startedUtcOffsetMinutes = 0
        try session.insert(db)
        return session
    }

    private func makeTrainingPlanService(
        dbQueue: DatabaseQueue,
        apiClient: TrainingPlanRouteAPIClientMock = TrainingPlanRouteAPIClientMock(),
        runtimeConfigured: @escaping @Sendable () -> Bool = { true },
        hasCloudSession: @escaping @Sendable () async -> Bool = { true }
    ) -> TrainingPlanService {
        TrainingPlanService(
            dbQueue: dbQueue,
            apiClient: apiClient,
            syncEngineProvider: { nil },
            runtimeConfigured: runtimeConfigured,
            hasCloudSessionProvider: hasCloudSession
        )
    }

    private func assertTrainingPlanError(
        _ expression: @autoclosure () async throws -> Void,
        matches matcher: (TrainingError) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected TrainingError", file: file, line: line)
        } catch let error as TrainingError {
            XCTAssertTrue(matcher(error), "Unexpected TrainingError: \(error)", file: file, line: line)
        } catch {
            XCTFail("Expected TrainingError, got \(error)", file: file, line: line)
        }
    }

    nonisolated private static func insertExercise(
        _ db: Database,
        id: UUID,
        sessionId: UUID,
        catalogId: UUID
    ) throws -> WorkoutExercise {
        var exercise = WorkoutExercise(
            id: id,
            sessionId: sessionId,
            exerciseId: catalogId,
            orderInSession: 1
        )
        exercise.totalSets = 1
        exercise.totalReps = 5
        exercise.totalVolume = 500
        exercise.maxWeight = 100
        try exercise.insert(db)
        return exercise
    }

    nonisolated private static func insertSet(
        _ db: Database,
        id: UUID,
        exerciseId: UUID,
        userId: UUID,
        setNumber: Int = 1
    ) throws -> WorkoutSet {
        var set = WorkoutSet(
            id: id,
            exerciseEntryId: exerciseId,
            userId: userId,
            setNumber: setNumber
        )
        set.weight = 100
        set.reps = 5
        set.rpe = 8
        set.restAfterSeconds = 90
        try set.insert(db)
        return set
    }

    func testCreateManualWorkoutPersistsNestedRecordsAndQueuesEdgeEvent() async throws {
        let manager = try DatabaseManager.inMemory()
        let service = TrainingService(dbQueue: manager.dbQueue)
        let authId = UUID()
        let userId = UUID()
        let sessionId = UUID()
        let catalogId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)

            var catalog = ExerciseCatalogEntry(id: catalogId, name: "Back Squat", category: .strength)
            catalog.createdAt = Date()
            catalog.updatedAt = Date()
            try catalog.insert(db)
        }

        AuthManager.setActiveAuthIdForTests(authId)

        try await service.createManualWorkout(
            WorkoutSessionDraft(
                id: sessionId,
                startedAt: Date(timeIntervalSince1970: 1_773_331_200),
                sessionDate: "2026-03-12",
                startedTimezone: "UTC",
                startedUtcOffsetMinutes: 0,
                endedAt: Date(timeIntervalSince1970: 1_773_334_800),
                durationMinutes: nil,
                workoutType: .strength,
                location: .gym,
                notes: "Heavy day",
                trainingPlanId: nil,
                perceivedExertionRpe: 8,
                postFeeling: nil,
                estimatedCalories: 420,
                trimpScore: 54,
                exercises: [
                    WorkoutSessionDraftExercise(
                        id: UUID(),
                        exerciseId: catalogId,
                        name: "Back Squat",
                        orderInSession: 1,
                        durationSeconds: nil,
                        notes: "Top set focus",
                        sets: [
                            WorkoutSessionDraftSet(
                                id: UUID(),
                                setNumber: 1,
                                weight: 100,
                                reps: 5,
                                rpe: 8,
                                restAfterSeconds: 120,
                                isWarmup: false,
                                isFailure: false,
                                isDropset: false
                            ),
                            WorkoutSessionDraftSet(
                                id: UUID(),
                                setNumber: 2,
                                weight: 110,
                                reps: 3,
                                rpe: 9,
                                restAfterSeconds: 150,
                                isWarmup: false,
                                isFailure: false,
                                isDropset: false
                            )
                        ]
                    )
                ]
            )
        )

        try await manager.dbQueue.read { db in
            XCTAssertEqual(try WorkoutSession.fetchCount(db), 1)
            XCTAssertEqual(try WorkoutExercise.fetchCount(db), 1)
            XCTAssertEqual(try WorkoutSet.fetchCount(db), 2)

            let session = try XCTUnwrap(
                WorkoutSession.fetchOne(
                    db,
                    sql: "SELECT * FROM workout_sessions WHERE id = ? OR id = ? LIMIT 1",
                    arguments: [sessionId, sessionId.uuidString]
                )
            )
            XCTAssertEqual(session.userId, userId)
            XCTAssertEqual(try XCTUnwrap(session.durationMinutes), 60)
            XCTAssertEqual(try XCTUnwrap(session.totalSets), 2)
            XCTAssertEqual(try XCTUnwrap(session.totalReps), 8)
            XCTAssertEqual(try XCTUnwrap(session.totalVolume), 830, accuracy: 0.001)

            let event = try XCTUnwrap(
                OutboxEvent.fetchOne(
                    db,
                    sql: "SELECT * FROM outbox_events WHERE path = 'api-workouts-log' LIMIT 1"
                )
            )
            XCTAssertEqual(event.httpMethod, .POST)
            XCTAssertEqual(event.id, sessionId)
        }
    }

    func testUpdateDeleteAndUndoWorkoutUseRouteEvents() async throws {
        let manager = try DatabaseManager.inMemory()
        let service = TrainingService(dbQueue: manager.dbQueue)
        let authId = UUID()
        let userId = UUID()
        let sessionId = UUID()
        let exerciseId = UUID()
        let catalogId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            _ = try Self.insertSession(db, id: sessionId, userId: userId)
            _ = try Self.insertExercise(db, id: exerciseId, sessionId: sessionId, catalogId: catalogId)
            _ = try Self.insertSet(db, id: UUID(), exerciseId: exerciseId, userId: userId)
        }

        try await service.updateWorkout(
            WorkoutSessionUpdateDraft(
                id: sessionId,
                startedAt: Date(timeIntervalSince1970: 1_773_331_200),
                sessionDate: "2026-03-12",
                startedTimezone: "UTC",
                startedUtcOffsetMinutes: 0,
                endedAt: Date(timeIntervalSince1970: 1_773_334_200),
                durationMinutes: 50,
                workoutType: .cardio,
                location: .outdoor,
                notes: "Edited workout",
                trainingPlanId: nil,
                perceivedExertionRpe: 6,
                postFeeling: nil,
                estimatedCalories: 510,
                trimpScore: 45,
                exercises: [
                    WorkoutSessionDraftExercise(
                        id: exerciseId,
                        exerciseId: catalogId,
                        name: "Back Squat",
                        orderInSession: 1,
                        durationSeconds: nil,
                        notes: nil,
                        sets: [
                            WorkoutSessionDraftSet(
                                id: UUID(),
                                setNumber: 1,
                                weight: 90,
                                reps: 8,
                                rpe: 7,
                                restAfterSeconds: 60,
                                isWarmup: false,
                                isFailure: false,
                                isDropset: false
                            )
                        ]
                    )
                ]
            )
        )

        let deletedAt = try await service.deleteWorkout(id: sessionId)
        XCTAssertLessThan(abs(deletedAt.timeIntervalSinceNow), 5)
        try await service.undoDeleteWorkout(id: sessionId)

        try await manager.dbQueue.read { db in
            let session = try XCTUnwrap(
                WorkoutSession.fetchOne(
                    db,
                    sql: "SELECT * FROM workout_sessions WHERE id = ? OR id = ? LIMIT 1",
                    arguments: [sessionId, sessionId.uuidString]
                )
            )
            XCTAssertEqual(session.workoutType, .cardio)
            XCTAssertEqual(session.location, .outdoor)
            XCTAssertEqual(session.notes, "Edited workout")
            XCTAssertNil(session.deletedAt)

            let patchEvent = try XCTUnwrap(
                OutboxEvent.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM outbox_events
                        WHERE path = ?
                        ORDER BY created_at_local ASC
                        LIMIT 1
                        """,
                    arguments: ["api-workouts/\(sessionId.uuidString)"]
                )
            )
            XCTAssertEqual(patchEvent.httpMethod, .PATCH)

            let deleteEvent = try XCTUnwrap(
                OutboxEvent.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM outbox_events
                        WHERE path = ?
                        ORDER BY created_at_local DESC
                        LIMIT 1
                        """,
                    arguments: ["api-workouts/\(sessionId.uuidString)"]
                )
            )
            XCTAssertEqual(deleteEvent.httpMethod, .DELETE)

            let undoEvent = try XCTUnwrap(
                OutboxEvent.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM outbox_events
                        WHERE path = ?
                        ORDER BY created_at_local DESC
                        LIMIT 1
                        """,
                    arguments: ["api-workouts/\(sessionId.uuidString)/undo"]
                )
            )
            XCTAssertEqual(undoEvent.httpMethod, .POST)
        }
    }

    func testLoadWorkoutDetailPrefersRemoteAndCachesSnapshot() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let sessionId = UUID()
        let catalogId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            var catalog = ExerciseCatalogEntry(id: catalogId, name: "Bench Press", category: .strength)
            catalog.createdAt = Date()
            catalog.updatedAt = Date()
            try catalog.insert(db)
            _ = try Self.insertSession(db, id: sessionId, userId: userId)
        }

        var remote = WorkoutSessionRemoteDetailResponse(
            id: sessionId,
            startedAt: Date(timeIntervalSince1970: 1_773_420_000),
            endedAt: Date(timeIntervalSince1970: 1_773_423_600),
            sessionDate: "2026-03-14",
            startedTimezone: "UTC",
            startedUtcOffsetMinutes: 0,
            workoutType: .strength,
            source: .manual,
            totalVolume: 1_200,
            totalSets: 3,
            totalReps: 15,
            estimatedCalories: 480,
            trimpScore: 52,
            perceivedExertionRpe: 8,
            durationMinutes: 60,
            location: .gym,
            trainingPlanId: nil,
            postFeeling: nil,
            notes: "Remote detail",
            exercises: [
                .init(
                    id: UUID(),
                    exerciseId: catalogId,
                    name: "Bench Press",
                    orderInSession: 1,
                    totalSets: 3,
                    totalReps: 15,
                    totalVolume: 1_200,
                    maxWeight: 90,
                    durationSeconds: nil,
                    notes: "Remote exercise",
                    sets: [
                        .init(
                            id: UUID(),
                            setNumber: 1,
                            weight: 80,
                            reps: 5,
                            rpe: 7,
                            restAfterSeconds: 90,
                            isWarmup: false,
                            isFailure: false,
                            isDropset: false
                        )
                    ]
                )
            ]
        )
        remote.updatedAt = Date().addingTimeInterval(60)
        let client = WorkoutDetailClientMock(response: remote)
        let service = TrainingService(dbQueue: manager.dbQueue, detailAPIClient: client)

        AuthManager.setActiveAuthIdForTests(authId)
        AuthManager._testSetActiveHasCloudSession(true)

        let detail = try await service.loadWorkoutDetail(id: sessionId, preferRemote: true)
        let snapshot = try XCTUnwrap(detail)
        XCTAssertEqual(snapshot.session.notes, "Remote detail")
        XCTAssertEqual(snapshot.exercises.count, 1)
        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 1)

        try await manager.dbQueue.read { db in
            let cachedSession = try XCTUnwrap(
                WorkoutSession.fetchOne(
                    db,
                    sql: "SELECT * FROM workout_sessions WHERE id = ? OR id = ? LIMIT 1",
                    arguments: [sessionId, sessionId.uuidString]
                )
            )
            XCTAssertEqual(cachedSession.notes, "Remote detail")

            let exerciseCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM workout_exercises WHERE session_id = ? OR session_id = ?",
                arguments: [sessionId, sessionId.uuidString]
            ) ?? -1
            XCTAssertEqual(exerciseCount, 1)
        }
        // An outbox edit must survive a newer-looking remote response too.
        try await manager.dbQueue.write { db in
            try db.execute(sql: "UPDATE workout_sessions SET notes = ? WHERE id = ? OR id = ?", arguments: ["Offline correction", sessionId, sessionId.uuidString])
            try OutboxEvent(httpMethod: .PATCH, path: "api-edit/\(sessionId.uuidString)", bodyJson: Data("{}".utf8)).insert(db)
        }
        let reloaded = try await service.loadWorkoutDetail(id: sessionId, preferRemote: true)
        let retained = try XCTUnwrap(reloaded)
        XCTAssertEqual(retained.session.notes, "Offline correction")

    }

    @MainActor
    func testWorkoutLogViewModelLoadsImportedWorkoutAsReadOnly() async throws {
        let manager = try DatabaseManager.inMemory()
        let workoutId = UUID()
        let exerciseId = UUID()
        let managerMock = WorkoutSessionManagerMock()

        let importedSession = WorkoutSession(
            id: workoutId,
            userId: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_773_331_200),
            sessionDate: "2026-03-12",
            source: .import
        )
        let exercise = WorkoutExercise(
            id: exerciseId,
            sessionId: workoutId,
            exerciseId: nil,
            orderInSession: 1
        )
        let set = WorkoutSet(
            id: UUID(),
            exerciseEntryId: exerciseId,
            userId: importedSession.userId,
            setNumber: 1
        )
        await managerMock.setLoadedDetail(
            WorkoutSessionDetail(
            session: importedSession,
            exercises: [
                WorkoutSessionDetailExercise(
                    exercise: exercise,
                    name: "Imported Run",
                    category: .cardio,
                    sets: [set]
                )
            ]
        ),
            for: workoutId
        )

        let viewModel = WorkoutLogViewModel(
            existingSessionId: workoutId,
            workoutManager: managerMock,
            dbQueue: manager.dbQueue,
            targetDate: Date()
        )

        await viewModel.loadWorkoutDetailIfNeeded()

        XCTAssertEqual(viewModel.workoutSource, .import)
        XCTAssertFalse(viewModel.canEditExercises)
        XCTAssertEqual(viewModel.exercises.count, 1)
        XCTAssertEqual(viewModel.exercises[0].name, "Imported Run")
    }

    @MainActor
    func testWorkoutLogViewModelStartsRestTimerAndCreatesDraft() async throws {
        let manager = try DatabaseManager.inMemory()
        let managerMock = WorkoutSessionManagerMock()
        let exerciseCatalog = ExerciseCatalogEntry(id: UUID(), name: "Deadlift", category: .strength)

        let viewModel = WorkoutLogViewModel(
            workoutManager: managerMock,
            dbQueue: manager.dbQueue,
            targetDate: Date(timeIntervalSince1970: 1_773_331_200),
            defaultRestAfterSeconds: 1,
            restTimerTickNanoseconds: 1_000_000
        )

        viewModel.addExercise(exerciseCatalog)
        viewModel.exercises[0].sets[0].weight = 140
        viewModel.exercises[0].sets[0].reps = 5
        viewModel.exercises[0].sets[0].rpe = 8

        viewModel.toggleSetCompletion(exerciseId: viewModel.exercises[0].id, at: 0)
        XCTAssertNotNil(viewModel.activeRestTimer)

        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(viewModel.activeRestTimer)

        let didSave = await viewModel.save()
        XCTAssertTrue(didSave)

        let createdDrafts = await managerMock.createdDraftsSnapshot()
        XCTAssertEqual(createdDrafts.count, 1)
        XCTAssertEqual(createdDrafts[0].exercises.count, 1)
        XCTAssertEqual(try XCTUnwrap(createdDrafts[0].exercises[0].sets[0].weight), 140)
        XCTAssertEqual(try XCTUnwrap(createdDrafts[0].exercises[0].sets[0].reps), 5)
        XCTAssertEqual(try XCTUnwrap(createdDrafts[0].exercises[0].sets[0].restAfterSeconds), 1)
    }

    @MainActor
    func testWorkoutLogViewModelSeedsCatalogAndCreatesCustomExerciseFromSearch() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
        }

        AuthManager.setActiveAuthIdForTests(authId)

        let viewModel = WorkoutLogViewModel(dbQueue: manager.dbQueue)
        await viewModel.loadCatalog()

        viewModel.exerciseSearch = "bench"
        XCTAssertTrue(viewModel.filteredCatalog.contains {
            $0.name.localizedCaseInsensitiveContains("bench")
        })

        viewModel.exerciseSearch = "Sled Push"
        await viewModel.addExerciseFromSearch()

        XCTAssertEqual(viewModel.exercises.count, 1)
        XCTAssertEqual(viewModel.exercises[0].name, "Sled Push")
        XCTAssertEqual(viewModel.exercises[0].category, .strength)

        try await manager.dbQueue.read { db in
            let customEntry = try XCTUnwrap(
                ExerciseCatalogEntry.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM exercise_catalog
                        WHERE lower(name) = lower(?)
                          AND COALESCE(is_custom, 0) = 1
                        LIMIT 1
                        """,
                    arguments: ["Sled Push"]
                )
            )
            XCTAssertEqual(customEntry.category, .strength)
            XCTAssertEqual(customEntry.createdBy, userId)
        }
    }

    func testCreateManualWorkoutCreatesCustomCatalogEntryAndCarriesPayloadMetadata() async throws {
        let manager = try DatabaseManager.inMemory()
        let service = TrainingService(dbQueue: manager.dbQueue)
        let authId = UUID()
        let userId = UUID()
        let sessionId = UUID()
        let customCatalogId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
        }

        AuthManager.setActiveAuthIdForTests(authId)

        try await service.createManualWorkout(
            WorkoutSessionDraft(
                id: sessionId,
                startedAt: Date(timeIntervalSince1970: 1_773_331_200),
                sessionDate: "2026-03-12",
                startedTimezone: "UTC",
                startedUtcOffsetMinutes: 0,
                endedAt: Date(timeIntervalSince1970: 1_773_332_400),
                durationMinutes: nil,
                workoutType: .cardio,
                location: .gym,
                notes: "Push work",
                trainingPlanId: nil,
                perceivedExertionRpe: 7,
                postFeeling: nil,
                estimatedCalories: 280,
                trimpScore: 31.5,
                exercises: [
                    WorkoutSessionDraftExercise(
                        id: UUID(),
                        exerciseId: customCatalogId,
                        name: "Sled Push",
                        category: .cardio,
                        orderInSession: 1,
                        durationSeconds: 600,
                        notes: "Heavy sled",
                        sets: [
                            WorkoutSessionDraftSet(
                                id: UUID(),
                                setNumber: 1,
                                weight: 80,
                                reps: 6,
                                rpe: 7,
                                restAfterSeconds: 90,
                                isWarmup: false,
                                isFailure: false,
                                isDropset: false
                            )
                        ]
                    )
                ]
            )
        )

        try await manager.dbQueue.read { db in
            let customEntry = try XCTUnwrap(
                ExerciseCatalogEntry.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM exercise_catalog
                        WHERE id = ? OR id = ?
                        LIMIT 1
                        """,
                    arguments: [customCatalogId, customCatalogId.uuidString]
                )
            )
            XCTAssertEqual(customEntry.name, "Sled Push")
            XCTAssertEqual(customEntry.category, .cardio)
            XCTAssertTrue(customEntry.isCustom)
            XCTAssertEqual(customEntry.createdBy, userId)

            let storedExercise = try XCTUnwrap(
                WorkoutExercise.fetchOne(
                    db,
                    sql: "SELECT * FROM workout_exercises WHERE session_id = ? OR session_id = ? LIMIT 1",
                    arguments: [sessionId, sessionId.uuidString]
                )
            )
            XCTAssertEqual(storedExercise.exerciseId, customCatalogId)

            let event = try XCTUnwrap(
                OutboxEvent.fetchOne(
                    db,
                    sql: "SELECT * FROM outbox_events WHERE path = 'api-workouts-log' LIMIT 1"
                )
            )
            let payloadObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: event.bodyJson) as? [String: Any]
            )
            let exercises = try XCTUnwrap(payloadObject["exercises"] as? [[String: Any]])
            XCTAssertEqual(exercises.count, 1)
            XCTAssertEqual((exercises[0]["exercise_id"] as? String)?.lowercased(), customCatalogId.uuidString.lowercased())
            XCTAssertEqual(exercises[0]["name"] as? String, "Sled Push")
            XCTAssertEqual(exercises[0]["category"] as? String, "cardio")
        }
    }

    func testTrainingPlanServiceGenerateNormalizesDraftAndCallsEdgeRoute() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = TrainingPlanRouteAPIClientMock()
        let service = makeTrainingPlanService(dbQueue: manager.dbQueue, apiClient: api)
        let authId = UUID()
        let userId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
        }
        AuthManager.setActiveAuthIdForTests(authId)

        try await service.generatePlan(
            TrainingPlanGenerationDraft(
                name: "  Hypertrophy block  ",
                goal: .strength,
                availableDays: [5, 1, 1, 9, -1, 3],
                durationWeeks: 99,
                sessionDurationMinutes: 4,
                experienceLevel: .advanced,
                equipmentAccess: .mixed,
                injuries: ["  shoulder  ", "", " knee "]
            )
        )

        let payloads = await api.generatePayloads
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].name, "Hypertrophy block")
        XCTAssertEqual(payloads[0].goal, TrainingGoal.strength.rawValue)
        XCTAssertEqual(payloads[0].availableDays, [1, 3, 5])
        XCTAssertEqual(payloads[0].durationWeeks, 24)
        XCTAssertEqual(payloads[0].sessionDurationMinutes, 10)
        XCTAssertEqual(payloads[0].experienceLevel, TrainingPlanExperienceLevel.advanced.rawValue)
        XCTAssertEqual(payloads[0].equipmentAccess, TrainingPlanEquipmentAccess.mixed.rawValue)
        XCTAssertEqual(payloads[0].injuries, ["shoulder", "knee"])
    }

    func testTrainingPlanServiceRejectsInvalidAccessDaysAndExistingActivePlans() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = TrainingPlanRouteAPIClientMock()
        let service = makeTrainingPlanService(dbQueue: manager.dbQueue, apiClient: api)
        let authId = UUID()
        let userId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
        }
        AuthManager.setActiveAuthIdForTests(authId)

        await assertTrainingPlanError(
            try await service.generatePlan(
                TrainingPlanGenerationDraft(
                    name: nil,
                    goal: .strength,
                    availableDays: [-1, 7],
                    durationWeeks: 4,
                    sessionDurationMinutes: 45,
                    experienceLevel: .beginner,
                    equipmentAccess: .bodyweight,
                    injuries: []
                )
            )
        ) { error in
            if case .invalidSet(let reason) = error {
                return reason == "Choose at least one training day"
            }
            return false
        }

        try await manager.dbQueue.write { db in
            var plan = TrainingPlan(
                userId: userId,
                name: "Active plan",
                goal: .strength,
                planJson: Data("{}".utf8)
            )
            plan.status = .active
            try plan.insert(db)
        }

        await assertTrainingPlanError(
            try await service.generatePlan(
                TrainingPlanGenerationDraft(
                    name: "Another",
                    goal: .strength,
                    availableDays: [1],
                    durationWeeks: 4,
                    sessionDurationMinutes: 45,
                    experienceLevel: .intermediate,
                    equipmentAccess: .gym,
                    injuries: []
                )
            )
        ) { error in
            if case .planLimitReached(let max) = error {
                return max == 1
            }
            return false
        }

        let payloads = await api.generatePayloads
        XCTAssertTrue(payloads.isEmpty)
    }

    func testTrainingPlanServiceUpdateValidatesPayloadAndAllowsOwnActivePlan() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = TrainingPlanRouteAPIClientMock()
        let service = makeTrainingPlanService(dbQueue: manager.dbQueue, apiClient: api)
        let authId = UUID()
        let userId = UUID()
        let planId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            var plan = TrainingPlan(
                id: planId,
                userId: userId,
                name: "Current",
                goal: .strength,
                planJson: Data("{}".utf8)
            )
            plan.status = .active
            try plan.insert(db)
        }
        AuthManager.setActiveAuthIdForTests(authId)

        await assertTrainingPlanError(
            try await service.updatePlan(
                TrainingPlanUpdateDraft(id: planId, name: "   ", status: nil)
            )
        ) { error in
            if case .invalidSet(let reason) = error {
                return reason == "Update at least one field"
            }
            return false
        }

        try await service.updatePlan(
            TrainingPlanUpdateDraft(id: planId, name: "  Current plus  ", status: .active)
        )

        let requests = await api.updateRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].0, planId)
        XCTAssertEqual(requests[0].1.name, "Current plus")
        XCTAssertEqual(requests[0].1.status, TrainingPlanStatus.active.rawValue)
    }

    func testTrainingPlanServiceUpdateBlocksAnotherActivePlanAndAdjustsByReason() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = TrainingPlanRouteAPIClientMock()
        let service = makeTrainingPlanService(dbQueue: manager.dbQueue, apiClient: api)
        let authId = UUID()
        let userId = UUID()
        let targetPlanId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId)
            var otherPlan = TrainingPlan(
                userId: userId,
                name: "Other active",
                goal: .strength,
                planJson: Data("{}".utf8)
            )
            otherPlan.status = .active
            try otherPlan.insert(db)
        }
        AuthManager.setActiveAuthIdForTests(authId)

        await assertTrainingPlanError(
            try await service.updatePlan(
                TrainingPlanUpdateDraft(id: targetPlanId, name: nil, status: .active)
            )
        ) { error in
            if case .planLimitReached(let max) = error {
                return max == 1
            }
            return false
        }

        for reason in TrainingPlanAdjustmentReason.allCases {
            XCTAssertFalse(reason.id.isEmpty)
            XCTAssertTrue(TrainingPlanAdjustmentKind.allCases.contains(reason.recommendedAdjustment))
        }
        XCTAssertEqual(TrainingPlanExperienceLevel.beginner.id, "beginner")
        XCTAssertEqual(TrainingPlanEquipmentAccess.homeGym.id, "home_gym")
        XCTAssertEqual(TrainingPlanAdjustmentKind.deloadWeek.id, "deload_week")

        try await service.adjustPlan(
            TrainingPlanAdjustmentDraft(
                id: targetPlanId,
                reason: .recoveryCritical,
                adjustment: .swapToMobility
            )
        )

        let adjustRequests = await api.adjustRequests
        XCTAssertEqual(adjustRequests.count, 1)
        XCTAssertEqual(adjustRequests[0].0, targetPlanId)
        XCTAssertEqual(adjustRequests[0].1.reason, TrainingPlanAdjustmentReason.recoveryCritical.rawValue)
        XCTAssertEqual(adjustRequests[0].1.adjustment, TrainingPlanAdjustmentKind.swapToMobility.rawValue)
    }

    func testTrainingPlanServiceRequiresRuntimeAndCloudSessionBeforeMutating() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = TrainingPlanRouteAPIClientMock()
        let service = makeTrainingPlanService(
            dbQueue: manager.dbQueue,
            apiClient: api,
            runtimeConfigured: { false },
            hasCloudSession: { true }
        )

        await assertTrainingPlanError(
            try await service.adjustPlan(
                TrainingPlanAdjustmentDraft(
                    id: UUID(),
                    reason: .userRequest,
                    adjustment: .reduceIntensity20
                )
            )
        ) { error in
            if case .planRequiresCloudSync = error {
                return true
            }
            return false
        }

        let adjustRequests = await api.adjustRequests
        XCTAssertTrue(adjustRequests.isEmpty)
    }
}
