import Foundation
import GRDB

enum ExerciseCatalogSupport {
    private struct BuiltInDefinition {
        let id: UUID
        let name: String
        let category: ExerciseCategory
    }

    private static let seedTimestamp = Date(timeIntervalSince1970: 1_700_000_000)

    private static let builtInDefinitions: [BuiltInDefinition] = [
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, name: "Back Squat", category: .strength),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, name: "Bench Press", category: .strength),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!, name: "Deadlift", category: .strength),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!, name: "Overhead Press", category: .strength),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000005")!, name: "Pull-Up", category: .strength),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000006")!, name: "Barbell Row", category: .strength),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000007")!, name: "Romanian Deadlift", category: .strength),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000008")!, name: "Leg Press", category: .strength),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000009")!, name: "Running", category: .cardio),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-00000000000a")!, name: "Cycling", category: .cardio),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-00000000000b")!, name: "Walking", category: .cardio),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-00000000000c")!, name: "Rowing Machine", category: .cardio),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-00000000000d")!, name: "Jump Rope", category: .cardio),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-00000000000e")!, name: "Elliptical", category: .cardio),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-00000000000f")!, name: "Yoga Flow", category: .mobility),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000010")!, name: "Dynamic Stretching", category: .mobility),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000011")!, name: "Foam Rolling", category: .mobility),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000012")!, name: "Mobility Circuit", category: .mobility),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000013")!, name: "Swimming", category: .sport),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000014")!, name: "Tennis", category: .sport),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000015")!, name: "Basketball", category: .sport),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000016")!, name: "Football Match", category: .sport),
        .init(id: UUID(uuidString: "00000000-0000-4000-8000-000000000017")!, name: "Other Exercise", category: .other),
    ]

    static func defaultCategory(for workoutType: WorkoutType?) -> ExerciseCategory {
        switch workoutType {
        case .strength: return .strength
        case .cardio: return .cardio
        case .mobility: return .mobility
        case .sport: return .sport
        default: return .other
        }
    }

    static func ensureSeeded(in db: Database) throws {
        for definition in builtInDefinitions {
            let existingCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM exercise_catalog
                    WHERE lower(name) = lower(?)
                      AND COALESCE(is_custom, 0) = 0
                    """,
                arguments: [definition.name]
            ) ?? 0

            guard existingCount == 0 else { continue }

            var entry = ExerciseCatalogEntry(
                id: definition.id,
                name: definition.name,
                category: definition.category
            )
            entry.createdAt = seedTimestamp
            entry.updatedAt = seedTimestamp
            try entry.insert(db)
        }
    }

    static func loadVisibleCatalog(in db: Database, userId: UUID?) throws -> [ExerciseCatalogEntry] {
        try ensureSeeded(in: db)

        if let userId {
            return try ExerciseCatalogEntry.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM exercise_catalog
                    WHERE COALESCE(is_custom, 0) = 0
                       OR created_by IN (?, ?)
                       OR created_by IS NULL
                    ORDER BY lower(name) ASC, created_at ASC
                    """,
                arguments: [userId, userId.uuidString]
            )
        }

        return try ExerciseCatalogEntry.fetchAll(
            db,
            sql: """
                SELECT *
                FROM exercise_catalog
                WHERE COALESCE(is_custom, 0) = 0
                   OR created_by IS NULL
                ORDER BY lower(name) ASC, created_at ASC
                """
        )
    }

    static func resolveEntry(
        requestedId: UUID?,
        name: String?,
        category: ExerciseCategory?,
        userId: UUID?,
        in db: Database
    ) throws -> ExerciseCatalogEntry? {
        try ensureSeeded(in: db)

        if let requestedId,
           let entry = try visibleEntry(id: requestedId, userId: userId, in: db) {
            return entry
        }

        guard let normalizedName = normalizedName(name) else {
            return nil
        }

        if let existing = try visibleEntry(named: normalizedName, userId: userId, in: db) {
            return existing
        }

        var entry = ExerciseCatalogEntry(
            id: requestedId ?? UUID(),
            name: normalizedName,
            category: category ?? .other
        )
        entry.isCustom = true
        entry.createdBy = userId
        entry.createdAt = Date()
        entry.updatedAt = entry.createdAt
        try entry.insert(db)
        return entry
    }

    static func normalizedName(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func visibleEntry(
        id: UUID,
        userId: UUID?,
        in db: Database
    ) throws -> ExerciseCatalogEntry? {
        if let userId {
            return try ExerciseCatalogEntry.fetchOne(
                db,
                sql: """
                    SELECT *
                    FROM exercise_catalog
                    WHERE (id = ? OR id = ?)
                      AND (
                        COALESCE(is_custom, 0) = 0
                        OR created_by IN (?, ?)
                        OR created_by IS NULL
                      )
                    LIMIT 1
                    """,
                arguments: [id, id.uuidString, userId, userId.uuidString]
            )
        }

        return try ExerciseCatalogEntry.fetchOne(
            db,
            sql: """
                SELECT *
                FROM exercise_catalog
                WHERE (id = ? OR id = ?)
                  AND (
                    COALESCE(is_custom, 0) = 0
                    OR created_by IS NULL
                  )
                LIMIT 1
                """,
            arguments: [id, id.uuidString]
        )
    }

    private static func visibleEntry(
        named name: String,
        userId: UUID?,
        in db: Database
    ) throws -> ExerciseCatalogEntry? {
        if let userId {
            return try ExerciseCatalogEntry.fetchOne(
                db,
                sql: """
                    SELECT *
                    FROM exercise_catalog
                    WHERE lower(name) = lower(?)
                      AND (
                        COALESCE(is_custom, 0) = 0
                        OR created_by IN (?, ?)
                        OR created_by IS NULL
                      )
                    ORDER BY COALESCE(is_custom, 0) ASC, created_at ASC
                    LIMIT 1
                    """,
                arguments: [name, userId, userId.uuidString]
            )
        }

        return try ExerciseCatalogEntry.fetchOne(
            db,
            sql: """
                SELECT *
                FROM exercise_catalog
                WHERE lower(name) = lower(?)
                  AND (
                    COALESCE(is_custom, 0) = 0
                    OR created_by IS NULL
                  )
                ORDER BY created_at ASC
                LIMIT 1
                """,
            arguments: [name]
        )
    }
}
