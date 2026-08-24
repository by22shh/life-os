// MARK: - Training Models
// Source of truth: life_os_api_specification.md
// Tables: workout_sessions, workout_exercises, workout_sets,
//         exercise_catalog, training_plans, training_plan_sessions, training_loads

import Foundation

// MARK: - Workout Session

struct WorkoutSession: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var createdAt: Date
    var updatedAt: Date

    var startedAt: Date
    var sessionDate: String             // YYYY-MM-DD user-local date (authoritative)
    var startedTimezone: String?        // IANA timezone
    var startedUtcOffsetMinutes: Int?
    var endedAt: Date?
    var durationMinutes: Int?

    var source: WorkoutSource
    var importProvider: ImportProvider?
    var importSourceId: String?         // External stable ID for de-dupe
    var workoutType: WorkoutType?
    var location: WorkoutLocation?

    // Pre-workout state
    var preRecoveryScore: Double?
    var preEnergyLevel: Int?            // 1-5

    // Session aggregates
    var totalVolume: Double?
    var totalSets: Int?
    var totalReps: Int?
    var estimatedCalories: Int?
    var trimpScore: Double?
    var perceivedExertionRpe: Int?      // 1-10

    // Post-workout
    var postFeeling: Int?               // 1-5
    var notes: String?

    // Soft delete
    var deletedAt: Date?
    var deletedReason: DeletedReason?

    // Plan linkage
    var trainingPlanId: UUID?

    init(
        id: UUID = UUID(),
        userId: UUID,
        startedAt: Date,
        sessionDate: String,
        source: WorkoutSource
    ) {
        self.id = id
        self.userId = userId
        self.createdAt = Date()
        self.updatedAt = Date()
        self.startedAt = startedAt
        self.sessionDate = sessionDate
        self.source = source
    }
}

// MARK: - Workout Exercise

struct WorkoutExercise: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var sessionId: UUID
    var exerciseId: UUID?               // Reference to exercise_catalog
    var orderInSession: Int?
    var totalSets: Int?
    var totalReps: Int?
    var totalVolume: Double?
    var maxWeight: Double?
    var durationSeconds: Int?
    var notes: String?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), sessionId: UUID, exerciseId: UUID? = nil, orderInSession: Int? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.exerciseId = exerciseId
        self.orderInSession = orderInSession
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Workout Set

struct WorkoutSet: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var exerciseEntryId: UUID
    var userId: UUID
    var setNumber: Int
    var weight: Double?
    var reps: Int?
    var rpe: Int?                       // 1-10
    var tempo: String?                  // "3-1-2-1"
    var isWarmup: Bool
    var isFailure: Bool
    var isDropset: Bool
    var restAfterSeconds: Int?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        exerciseEntryId: UUID,
        userId: UUID,
        setNumber: Int
    ) {
        self.id = id
        self.exerciseEntryId = exerciseEntryId
        self.userId = userId
        self.setNumber = setNumber
        self.isWarmup = false
        self.isFailure = false
        self.isDropset = false
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Exercise Catalog

struct ExerciseCatalogEntry: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var category: ExerciseCategory
    var primaryMuscles: [String]
    var secondaryMuscles: [String]
    var equipment: [String]
    var movementPattern: String?
    var unilateral: Bool
    var difficulty: ExerciseDifficulty?
    var instructions: String?
    var videoUrl: String?
    var isCustom: Bool
    var createdBy: UUID?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, category: ExerciseCategory) {
        self.id = id
        self.name = name
        self.category = category
        self.primaryMuscles = []
        self.secondaryMuscles = []
        self.equipment = []
        self.unilateral = false
        self.isCustom = false
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Training Plan

struct TrainingPlan: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var name: String
    var goal: TrainingGoal
    var status: TrainingPlanStatus
    var startDate: String?              // YYYY-MM-DD
    var endDate: String?
    var durationWeeks: Int?
    var daysPerWeek: Int?
    var currentWeek: Int
    var aiGenerated: Bool
    var planJson: Data                  // Full plan structure
    var adaptiveRules: Data?            // JSON of reason→adjustment
    var lastAdjustedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        userId: UUID,
        name: String,
        goal: TrainingGoal,
        planJson: Data
    ) {
        self.id = id
        self.userId = userId
        self.name = name
        self.goal = goal
        self.status = .active
        self.currentWeek = 1
        self.aiGenerated = false
        self.planJson = planJson
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Training Plan Session

struct TrainingPlanSession: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var trainingPlanId: UUID
    var userId: UUID
    var plannedDate: String             // YYYY-MM-DD
    var sessionType: SessionType
    var plannedDurationMinutes: Int?
    var title: String?
    var sessionJson: Data?              // Planned exercises
    var plannedExercises: Data?
    var status: PlanSessionStatus
    var linkedWorkoutId: UUID?
    var actualSessionId: UUID?
    var skippedReason: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        trainingPlanId: UUID,
        userId: UUID,
        plannedDate: String,
        sessionType: SessionType
    ) {
        self.id = id
        self.trainingPlanId = trainingPlanId
        self.userId = userId
        self.plannedDate = plannedDate
        self.sessionType = sessionType
        self.status = .planned
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Training Load

/// Daily training load calculations (TRIMP, ACWR).
struct TrainingLoad: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var date: String                    // YYYY-MM-DD

    // Daily load
    var dailyTrimp: Double?
    var dailyDurationMinutes: Int?
    var dailyActiveCalories: Int?
    var workoutCount: Int

    // HR summary
    var avgHeartRateBpm: Int?
    var peakHeartRateBpm: Int?

    // HR zone minutes
    var zone1Minutes: Int
    var zone2Minutes: Int
    var zone3Minutes: Int
    var zone4Minutes: Int
    var zone5Minutes: Int

    // Rolling averages (EWMA — Williams et al., 2017)
    var acuteLoad7d: Double?
    var chronicLoad28d: Double?
    var acwr: Double?                   // Acute:Chronic Workload Ratio
    var ewmaLambdaAcute: Double?
    var ewmaLambdaChronic: Double?

    // Training state
    var trainingZone: TrainingZoneState?
    var weeklyTrend: WeeklyTrend?

    // Monotony & strain
    var monotony7d: Double?
    var strain7d: Double?

    // Fitness & fatigue
    var fitnessCtl: Double?
    var fatigueAtl: Double?
    var formTsb: Double?

    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), userId: UUID, date: String) {
        self.id = id
        self.userId = userId
        self.date = date
        self.workoutCount = 0
        self.zone1Minutes = 0
        self.zone2Minutes = 0
        self.zone3Minutes = 0
        self.zone4Minutes = 0
        self.zone5Minutes = 0
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// Cold-start safe ACWR calculation.
    /// Returns nil until enough history exists and denominator is non-zero.
    static func safeACWR(
        acuteLoad7d: Double?,
        chronicLoad28d: Double?,
        daysOfData: Int
    ) -> Double? {
        guard daysOfData >= 21,
              let acuteLoad7d,
              let chronicLoad28d,
              chronicLoad28d > 0 else {
            return nil
        }
        return acuteLoad7d / chronicLoad28d
    }
}

// MARK: - Supporting Enums

enum WorkoutSource: String, Codable, Sendable {
    case manual
    case wearable
    case plan
    case `import` = "import"
}

enum ImportProvider: String, Codable, Sendable {
    case healthkit
    case strava
    case garmin
    case other
}

enum WorkoutType: String, Codable, Sendable, CaseIterable {
    case strength
    case cardio
    case mobility
    case mixed
    case sport
    case other
}

enum WorkoutLocation: String, Codable, Sendable {
    case home
    case gym
    case outdoor
    case studio
    case other
}

enum ExerciseCategory: String, Codable, Sendable {
    case strength
    case cardio
    case mobility
    case sport
    case other
}

enum ExerciseDifficulty: String, Codable, Sendable {
    case beginner
    case intermediate
    case advanced
}

enum TrainingGoal: String, Codable, Sendable, CaseIterable {
    case strength
    case hypertrophy
    case endurance
    case weightLoss = "weight_loss"
    case sportSpecific = "sport_specific"
    case generalFitness = "general_fitness"
}

enum TrainingPlanStatus: String, Codable, Sendable {
    case active
    case paused
    case completed
    case archived
}

enum SessionType: String, Codable, Sendable {
    case strength
    case cardio
    case mobility
    case mixed
    case recovery
}

enum PlanSessionStatus: String, Codable, Sendable {
    case planned
    case completed
    case skipped
    case rescheduled

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        let normalized = Self.normalized(rawValue)
        guard let value = Self(rawValue: normalized) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported training plan session status: \(rawValue)"
            )
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func normalized(_ rawValue: String) -> String {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "scheduled":
            return Self.planned.rawValue
        case "modified":
            return Self.rescheduled.rawValue
        default:
            return rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }
}

enum TrainingZoneState: String, Codable, Sendable {
    case undertraining
    case optimal
    case overreaching
    case injuryRisk = "injury_risk"
}

enum WeeklyTrend: String, Codable, Sendable {
    case increasing
    case stable
    case decreasing
}
