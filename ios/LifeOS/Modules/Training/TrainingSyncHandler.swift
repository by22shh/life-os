import Foundation
import GRDB

enum TrainingSyncHandler: SyncModuleHandler {
    static let ownedTables: [SyncableTable] = [
        .workoutSessions,
        .workoutExercises,
        .workoutSets,
        .trainingPlans,
        .trainingPlanSessions,
        .trainingLoads,
        .trainingTemplates,
        .exerciseCatalog
    ]

    static let pullTables: [SyncableTable] = [
        .workoutSessions,
        .workoutExercises,
        .workoutSets,
        .trainingPlans,
        .trainingPlanSessions
    ]

    static func reconcileParentChild(in db: Database) throws {
        // workout_sessions <- workout_exercises <- workout_sets
        try db.execute(sql: """
            UPDATE workout_sessions
            SET total_sets = COALESCE((
                    SELECT COUNT(*)
                    FROM workout_sets ws
                    JOIN workout_exercises we ON ws.exercise_entry_id = we.id
                    WHERE we.session_id = workout_sessions.id
                ), 0),
                total_volume = COALESCE((
                    SELECT SUM(COALESCE(ws.weight, 0) * COALESCE(ws.reps, 0))
                    FROM workout_sets ws
                    JOIN workout_exercises we ON ws.exercise_entry_id = we.id
                    WHERE we.session_id = workout_sessions.id
                ), 0)
            WHERE EXISTS (
                SELECT 1
                FROM (
                    SELECT we.session_id AS session_id,
                           MAX(COALESCE(set_sync.updated_at_server, exercise_sync.updated_at_server)) AS child_updated_at
                    FROM workout_exercises we
                    LEFT JOIN workout_sets ws ON ws.exercise_entry_id = we.id
                    LEFT JOIN sync_row_state exercise_sync
                      ON exercise_sync.table_name = 'workout_exercises'
                     AND (
                            exercise_sync.row_id = we.id
                         OR lower(CAST(exercise_sync.row_id AS TEXT)) = lower(CAST(we.id AS TEXT))
                     )
                    LEFT JOIN sync_row_state set_sync
                      ON set_sync.table_name = 'workout_sets'
                     AND (
                            set_sync.row_id = ws.id
                         OR lower(CAST(set_sync.row_id AS TEXT)) = lower(CAST(ws.id AS TEXT))
                     )
                    WHERE we.session_id = workout_sessions.id
                ) child
                LEFT JOIN sync_row_state parent_sync
                  ON parent_sync.table_name = 'workout_sessions'
                 AND (
                        parent_sync.row_id = workout_sessions.id
                     OR lower(CAST(parent_sync.row_id AS TEXT)) = lower(CAST(workout_sessions.id AS TEXT))
                 )
                WHERE child.child_updated_at IS NOT NULL
                  AND (
                    parent_sync.updated_at_server IS NULL
                    OR child.child_updated_at > parent_sync.updated_at_server
                  )
            )
            """)
    }
}
