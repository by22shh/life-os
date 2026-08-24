// MARK: - Setup Checklist
// Progressive disclosure model for new users.
// Determines which setup tasks are incomplete and shows contextual guidance
// on HomeView until baseline is established.

import Foundation
import GRDB
import ComposableArchitecture

@Reducer
struct SetupChecklistFeature {
    // MARK: - Checklist Items

    struct Item: Identifiable, Equatable {
        let id: String
        let icon: String
        let title: String
        let subtitle: String
        let isComplete: Bool
        let route: String?

        var isActionable: Bool {
            !isComplete && route != nil
        }
    }

    @ObservableState
    struct State: Equatable {
        var items: [Item] = []
        var isFullyComplete = true
        var baselineDaysCollected: Int = 0

        var progress: Double {
            guard !items.isEmpty else { return 1 }
            let completed = items.filter(\.isComplete).count
            return Double(completed) / Double(items.count)
        }

        var completedCount: Int { items.filter(\.isComplete).count }
        var totalCount: Int { items.count }
    }

    enum Action: Equatable {
        case refresh
        case refreshResponse(Result<State, ErrorData>)
    }
    
    struct ErrorData: Error, Equatable, Sendable {
        let message: String
        init(_ error: Error) { self.message = error.localizedDescription }
    }

    @Dependency(\.databaseQueue) var dbQueue

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .refresh:
                return .run { send in
                    do {
                        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
                        let newState = try await dbQueue.read { db -> State in
                            let checklistState = try Self.loadState(db: db, authId: authId)
                            let items = Self.buildItems(from: checklistState)
                            return State(
                                items: items,
                                isFullyComplete: items.allSatisfy(\.isComplete),
                                baselineDaysCollected: checklistState.baselineDays
                            )
                        }
                        await send(.refreshResponse(.success(newState)))
                    } catch {
                        await send(.refreshResponse(.failure(ErrorData(error))))
                    }
                }

            case let .refreshResponse(.success(newState)):
                state = newState
                return .none

            case .refreshResponse(.failure):
                state.items = []
                state.isFullyComplete = true
                return .none
            }
        }
    }

    // MARK: - Internal State

    private struct ChecklistState {
        var hasProfileWeight: Bool
        var healthKitAuthorized: Bool
        var baselineDays: Int
        var hasLoggedFood: Bool
        var hasLoggedWellness: Bool
    }

    private static func loadState(db: Database, authId: String?) throws -> ChecklistState {
        guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
            return ChecklistState(
                hasProfileWeight: false,
                healthKitAuthorized: false,
                baselineDays: 0,
                hasLoggedFood: false,
                hasLoggedWellness: false
            )
        }

        let hasProfileWeight = try Double.fetchOne(
            db,
            sql: """
                SELECT weight_kg
                FROM users
                WHERE (id = ? OR id = ?)
                  AND weight_kg > 0
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString]
        ) != nil
        let bodyCompWeightCount = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM body_composition
                WHERE (user_id = ? OR user_id = ?)
                  AND weight_kg > 0
                  AND deleted_at IS NULL
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString]
        )!
        let hasBodyCompWeight = bodyCompWeightCount > 0
        let hasWeight = hasProfileWeight || hasBodyCompWeight

        let baselineDaysCount = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(DISTINCT date)
                FROM physiological_states
                WHERE (user_id = ? OR user_id = ?)
                  AND recovery_score IS NOT NULL
                """,
            arguments: [userId, userId.uuidString]
        )!
        let baselineDays = baselineDaysCount

        let hkStep = try String.fetchOne(
            db,
            sql: """
                SELECT step
                FROM onboarding_state
                WHERE user_id = ? OR user_id = ?
                ORDER BY updated_at DESC
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString]
        )
        let hkGrantedSteps: Set<String> = [
            OnboardingStep.healthkitGranted.rawValue,
            OnboardingStep.backfillInProgress.rawValue,
            OnboardingStep.backfillComplete.rawValue
        ]
        let hkGranted = baselineDaysCount > 0 || hkStep.map(hkGrantedSteps.contains) == true

        let foodLogCount = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM food_logs
                WHERE (user_id = ? OR user_id = ?)
                  AND deleted_at IS NULL
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString]
        )!
        let hasFood = foodLogCount > 0
        let wellnessCount = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM wellness_checks
                WHERE (user_id = ? OR user_id = ?)
                  AND deleted_at IS NULL
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString]
        )!
        let hasWellness = wellnessCount > 0

        return ChecklistState(
            hasProfileWeight: hasWeight,
            healthKitAuthorized: hkGranted,
            baselineDays: baselineDays,
            hasLoggedFood: hasFood,
            hasLoggedWellness: hasWellness
        )
    }

    private static func buildItems(from state: ChecklistState) -> [Item] {
        let minimumBaselineDays = 5
        let baselineComplete = state.baselineDays >= minimumBaselineDays
        var list: [Item] = []

        list.append(Item(id: "healthkit", icon: "heart.fill", title: String(localized: "setup_connect_health"), subtitle: String(localized: "setup_connect_health_subtitle"), isComplete: state.healthKitAuthorized, route: "lifeos://settings"))
        list.append(Item(id: "weight", icon: "scalemass", title: String(localized: "setup_set_weight"), subtitle: String(localized: "setup_set_weight_subtitle"), isComplete: state.hasProfileWeight, route: "lifeos://body-composition"))

        let baselineSubtitle = baselineComplete ? String(localized: "setup_baseline_complete") : String(format: String(localized: "setup_baseline_progress_format"), state.baselineDays, minimumBaselineDays)
        list.append(Item(id: "baseline", icon: "chart.line.uptrend.xyaxis", title: String(localized: "setup_build_baseline"), subtitle: baselineSubtitle, isComplete: baselineComplete, route: nil))
        list.append(Item(id: "food", icon: "fork.knife", title: String(localized: "setup_log_first_meal"), subtitle: String(localized: "setup_log_first_meal_subtitle"), isComplete: state.hasLoggedFood, route: "lifeos://nutrition/log"))
        list.append(Item(id: "wellness", icon: "heart.text.square", title: String(localized: "setup_wellness_check"), subtitle: String(localized: "setup_wellness_check_subtitle"), isComplete: state.hasLoggedWellness, route: "lifeos://wellness"))

        return list
    }
}

#if DEBUG
extension SetupChecklistFeature {
    static func debugLoadState(
        db: Database,
        authId: String?
    ) throws -> (
        hasProfileWeight: Bool,
        healthKitAuthorized: Bool,
        baselineDays: Int,
        hasLoggedFood: Bool,
        hasLoggedWellness: Bool
    ) {
        let state = try loadState(db: db, authId: authId)
        return (
            hasProfileWeight: state.hasProfileWeight,
            healthKitAuthorized: state.healthKitAuthorized,
            baselineDays: state.baselineDays,
            hasLoggedFood: state.hasLoggedFood,
            hasLoggedWellness: state.hasLoggedWellness
        )
    }

    static func debugBuildItems(
        hasProfileWeight: Bool,
        healthKitAuthorized: Bool,
        baselineDays: Int,
        hasLoggedFood: Bool,
        hasLoggedWellness: Bool
    ) -> [Item] {
        buildItems(
            from: ChecklistState(
                hasProfileWeight: hasProfileWeight,
                healthKitAuthorized: healthKitAuthorized,
                baselineDays: baselineDays,
                hasLoggedFood: hasLoggedFood,
                hasLoggedWellness: hasLoggedWellness
            )
        )
    }
}
#endif
