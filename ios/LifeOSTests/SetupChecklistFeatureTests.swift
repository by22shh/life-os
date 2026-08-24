import Foundation
import GRDB
import ComposableArchitecture
import XCTest
@testable import LifeOS

final class SetupChecklistFeatureTests: XCTestCase {

    private func insertUser(
        _ db: Database,
        userId: UUID,
        authId: UUID,
        weightKg: Double?
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO users (id, auth_id, timezone, units, weight_kg, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                userId.uuidString,
                authId.uuidString,
                "UTC",
                "metric",
                weightKg,
                Date(),
                Date()
            ]
        )
    }

    private func insertGRDBUser(
        _ db: Database,
        userId: UUID,
        authId: UUID,
        weightKg: Double?
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO users (id, auth_id, timezone, units, weight_kg, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                MixedUUIDStorage.rawData(userId),
                MixedUUIDStorage.rawData(authId),
                "UTC",
                "metric",
                weightKg,
                Date(),
                Date()
            ]
        )
    }

    private func insertBodyComposition(
        _ db: Database,
        userId: UUID,
        measuredAt: Date,
        weightKg: Double
    ) throws {
        var bodyComposition = BodyComposition(
            userId: userId,
            measuredAt: measuredAt,
            weightKg: weightKg
        )
        bodyComposition.createdAt = measuredAt
        bodyComposition.updatedAt = measuredAt
        try bodyComposition.insert(db)
    }

    func testDebugLoadStateReturnsDefaultsWhenAuthMissingOrUnknown() throws {
        let manager = try DatabaseManager.inMemory()

        let missingAuth = try manager.dbQueue.read { db in
            try SetupChecklistFeature.debugLoadState(db: db, authId: nil)
        }
        XCTAssertFalse(missingAuth.hasProfileWeight)
        XCTAssertFalse(missingAuth.healthKitAuthorized)
        XCTAssertEqual(missingAuth.baselineDays, 0)
        XCTAssertFalse(missingAuth.hasLoggedFood)
        XCTAssertFalse(missingAuth.hasLoggedWellness)

        let unknownAuth = try manager.dbQueue.read { db in
            try SetupChecklistFeature.debugLoadState(db: db, authId: UUID().uuidString)
        }
        XCTAssertFalse(unknownAuth.hasProfileWeight)
        XCTAssertFalse(unknownAuth.healthKitAuthorized)
        XCTAssertEqual(unknownAuth.baselineDays, 0)
        XCTAssertFalse(unknownAuth.hasLoggedFood)
        XCTAssertFalse(unknownAuth.hasLoggedWellness)
    }

    func testDebugLoadStateAggregatesCompletionSignals() throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()

        try manager.dbQueue.write { db in
            try insertUser(db, userId: userId, authId: authId, weightKg: nil)

            try insertBodyComposition(
                db,
                userId: userId,
                measuredAt: Date(),
                weightKg: 74.2
            )

            try db.execute(
                sql: """
                    INSERT INTO onboarding_state (id, user_id, step, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [UUID().uuidString, userId.uuidString, "backfill_in_progress", Date(), Date()]
            )

            try db.execute(
                sql: """
                    INSERT INTO physiological_states (
                        id, user_id, date, recovery_score, recovery_zone, created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [UUID().uuidString, userId.uuidString, "2026-02-20", 58.0, "caution", Date(), Date()]
            )
            try db.execute(
                sql: """
                    INSERT INTO physiological_states (
                        id, user_id, date, recovery_score, recovery_zone, created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [UUID().uuidString, userId.uuidString, "2026-02-21", 67.0, "ready", Date(), Date()]
            )

            try db.execute(
                sql: """
                    INSERT INTO food_logs (
                        id, user_id, logged_at, logged_date, input_method, calories, protein_g, fat_g, carbs_g,
                        pre_workout, post_workout, needs_review, user_corrected, synced_to_vector_db, created_at, updated_at, deleted_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    Date(),
                    "2026-02-24",
                    "manual",
                    500.0,
                    30.0,
                    15.0,
                    60.0,
                    false,
                    false,
                    false,
                    false,
                    false,
                    Date(),
                    Date(),
                    nil
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO food_logs (
                        id, user_id, logged_at, logged_date, input_method, calories, protein_g, fat_g, carbs_g,
                        pre_workout, post_workout, needs_review, user_corrected, synced_to_vector_db, created_at, updated_at, deleted_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    Date(),
                    "2026-02-24",
                    "manual",
                    200.0,
                    10.0,
                    7.0,
                    20.0,
                    false,
                    false,
                    false,
                    false,
                    false,
                    Date(),
                    Date(),
                    Date()
                ]
            )

            try db.execute(
                sql: """
                    INSERT INTO wellness_checks (
                        id, user_id, checked_at, date, feeling_ill, headache, digestive_issues,
                        mental_health_resources_shown, created_at, updated_at, deleted_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [UUID().uuidString, userId.uuidString, Date(), "2026-02-24", false, false, false, false, Date(), Date(), nil]
            )
            try db.execute(
                sql: """
                    INSERT INTO wellness_checks (
                        id, user_id, checked_at, date, feeling_ill, headache, digestive_issues,
                        mental_health_resources_shown, created_at, updated_at, deleted_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [UUID().uuidString, userId.uuidString, Date(), "2026-02-23", false, false, false, false, Date(), Date(), Date()]
            )
        }

        let state = try manager.dbQueue.read { db in
            try SetupChecklistFeature.debugLoadState(db: db, authId: authId.uuidString)
        }

        XCTAssertTrue(state.hasProfileWeight)
        XCTAssertTrue(state.healthKitAuthorized)
        XCTAssertEqual(state.baselineDays, 2)
        XCTAssertTrue(state.hasLoggedFood)
        XCTAssertTrue(state.hasLoggedWellness)
    }

    func testDebugLoadStateIgnoresDeletedRowsAndNonGrantedHealthKitStep() throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()

        try manager.dbQueue.write { db in
            try insertUser(db, userId: userId, authId: authId, weightKg: 0)

            try db.execute(
                sql: """
                    INSERT INTO onboarding_state (id, user_id, step, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [UUID().uuidString, userId.uuidString, "healthkit_prompted", Date(), Date()]
            )

            try db.execute(
                sql: """
                    INSERT INTO food_logs (
                        id, user_id, logged_at, logged_date, input_method, calories, protein_g, fat_g, carbs_g,
                        pre_workout, post_workout, needs_review, user_corrected, synced_to_vector_db, created_at, updated_at, deleted_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    Date(),
                    "2026-02-24",
                    "manual",
                    100.0,
                    8.0,
                    2.0,
                    15.0,
                    false,
                    false,
                    false,
                    false,
                    false,
                    Date(),
                    Date(),
                    Date()
                ]
            )

            try db.execute(
                sql: """
                    INSERT INTO wellness_checks (
                        id, user_id, checked_at, date, feeling_ill, headache, digestive_issues,
                        mental_health_resources_shown, created_at, updated_at, deleted_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [UUID().uuidString, userId.uuidString, Date(), "2026-02-24", false, false, false, false, Date(), Date(), Date()]
            )
        }

        let state = try manager.dbQueue.read { db in
            try SetupChecklistFeature.debugLoadState(db: db, authId: authId.uuidString)
        }

        XCTAssertFalse(state.hasProfileWeight)
        XCTAssertFalse(state.healthKitAuthorized)
        XCTAssertEqual(state.baselineDays, 0)
        XCTAssertFalse(state.hasLoggedFood)
        XCTAssertFalse(state.hasLoggedWellness)
    }

    func testDebugLoadStateHandlesMixedUUIDStorageForUserAndRelatedRows() throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let now = Date()

        try manager.dbQueue.write { db in
            try insertGRDBUser(db, userId: userId, authId: authId, weightKg: 81.5)

            try db.execute(
                sql: """
                    INSERT INTO onboarding_state (id, user_id, step, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [UUID(), userId, "onboarding_complete", now, now]
            )

            try db.execute(
                sql: """
                    INSERT INTO physiological_states (
                        id, user_id, date, recovery_score, recovery_zone, created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [UUID(), userId, "2026-03-05", 74.0, "ready", now, now]
            )

            try db.execute(
                sql: """
                    INSERT INTO food_logs (
                        id, user_id, logged_at, logged_date, input_method, calories, protein_g, fat_g, carbs_g,
                        pre_workout, post_workout, needs_review, user_corrected, synced_to_vector_db, created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [UUID(), userId, now, "2026-03-05", "manual", 600.0, 40.0, 18.0, 55.0, false, false, false, false, false, now, now]
            )

            try db.execute(
                sql: """
                    INSERT INTO wellness_checks (
                        id, user_id, checked_at, date, feeling_ill, headache, digestive_issues,
                        mental_health_resources_shown, created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [UUID(), userId, now, "2026-03-05", false, false, false, false, now, now]
            )
        }

        let state = try manager.dbQueue.read { db in
            try SetupChecklistFeature.debugLoadState(db: db, authId: authId.uuidString)
        }

        XCTAssertTrue(state.hasProfileWeight)
        XCTAssertTrue(state.healthKitAuthorized)
        XCTAssertEqual(state.baselineDays, 1)
        XCTAssertTrue(state.hasLoggedFood)
        XCTAssertTrue(state.hasLoggedWellness)
    }

    func testDebugLoadStateTreatsMissingOnboardingStepAsNotAuthorized() throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()

        try manager.dbQueue.write { db in
            try insertUser(db, userId: userId, authId: authId, weightKg: 72.0)
        }

        let state = try manager.dbQueue.read { db in
            try SetupChecklistFeature.debugLoadState(db: db, authId: authId.uuidString)
        }

        XCTAssertTrue(state.hasProfileWeight)
        XCTAssertFalse(state.healthKitAuthorized)
        XCTAssertEqual(state.baselineDays, 0)
        XCTAssertFalse(state.hasLoggedFood)
        XCTAssertFalse(state.hasLoggedWellness)
    }

    func testDebugBuildItemsAndProgressHelpers() {
        let incompleteItems = SetupChecklistFeature.debugBuildItems(
            hasProfileWeight: false,
            healthKitAuthorized: true,
            baselineDays: 2,
            hasLoggedFood: false,
            hasLoggedWellness: true
        )
        XCTAssertEqual(incompleteItems.count, 5)
        XCTAssertEqual(incompleteItems.map(\.id), ["healthkit", "weight", "baseline", "food", "wellness"])
        XCTAssertTrue(incompleteItems.first(where: { $0.id == "healthkit" })?.isComplete ?? false)
        XCTAssertFalse(incompleteItems.first(where: { $0.id == "baseline" })?.isComplete ?? true)
        XCTAssertNil(incompleteItems.first(where: { $0.id == "baseline" })?.route)

        let completedItems = SetupChecklistFeature.debugBuildItems(
            hasProfileWeight: true,
            healthKitAuthorized: true,
            baselineDays: 5,
            hasLoggedFood: true,
            hasLoggedWellness: true
        )
        XCTAssertTrue(completedItems.allSatisfy(\.isComplete))

        let partialState = SetupChecklistFeature.State(
            items: incompleteItems,
            isFullyComplete: false,
            baselineDaysCollected: 2
        )
        XCTAssertEqual(partialState.completedCount, 2)
        XCTAssertEqual(partialState.totalCount, 5)
        XCTAssertEqual(partialState.progress, 0.4, accuracy: 0.0001)

        XCTAssertEqual(SetupChecklistFeature.State().progress, 1.0, accuracy: 0.0001)
    }

    @MainActor
    func testRefreshResponseFailureResetsStateToSafeDefaults() async {
        let initialItems = SetupChecklistFeature.debugBuildItems(
            hasProfileWeight: true,
            healthKitAuthorized: true,
            baselineDays: 7,
            hasLoggedFood: true,
            hasLoggedWellness: true
        )

        let store = TestStore(
            initialState: SetupChecklistFeature.State(
                items: initialItems,
                isFullyComplete: false,
                baselineDaysCollected: 7
            )
        ) {
            SetupChecklistFeature()
        }

        await store.send(
            .refreshResponse(
                .failure(
                    SetupChecklistFeature.ErrorData(
                        NSError(domain: "setup-checklist", code: 1)
                    )
                )
            )
        ) {
            $0.items = []
            $0.isFullyComplete = true
        }
    }
}
