// MARK: - Recovery & Physiological State Models
// Source of truth: life_os_api_specification.md — Table: physiological_states

import Foundation

// MARK: - Physiological State

/// Daily recovery scores and biomarkers.
/// One row per user per date.
struct PhysiologicalState: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var date: String  // YYYY-MM-DD, local date
    var localTimezone: String?
    var localUtcOffsetMinutes: Int?
    var createdAt: Date
    var updatedAt: Date

    // Recovery Score Components
    // NOTE: `hrvMs` is the persisted DB column name (hrv_ms) for GRDB compatibility.
    // The actual value is ln(RMSSD), NOT raw milliseconds.
    // Use the `hrvLnRmssd` computed alias in algorithm code for clarity.
    var hrvMs: Double?
    var hrvScore: Double?                // 0-100, weighted by baseline

    /// Semantic alias: the stored `hrvMs` column actually holds ln(RMSSD), not raw ms.
    /// Use this accessor in algorithm/engine code for clarity.
    var hrvLnRmssd: Double? {
        get { hrvMs }
        set { hrvMs = newValue }
    }
    var restingHeartRateBpm: Int?
    var rhrScore: Double?                // 0-100
    var wristTemperatureDeviationC: Double?  // °C deviation from baseline
    var tempScore: Double?               // 0-100
    var sleepDurationHours: Double?
    var sleepQualityPercent: Double?      // 0-100
    var sleepScore: Double?              // 0-100

    // Composite
    var recoveryScore: Double            // 0-100 (final weighted score)
    var recoveryZone: RecoveryZone       // .critical | .caution | .ready | .optimal
    var microZone: MicroZone?            // Only if optimal

    // Additional biomarkers
    var respiratoryRateBpm: Double?
    var bloodOxygenPercent: Double?
    var autonomicState: AutonomicState?
    var allostaticLoad: Double?          // 0-10 scale

    // Sleep breakdown
    var deepSleepPercent: Double?
    var remSleepPercent: Double?
    var lightSleepPercent: Double?
    var awakePercent: Double?

    // Activity
    var activeCalories: Int?
    var totalCalories: Int?
    var steps: Int?
    var exerciseMinutes: Int?

    // Context
    var environmentalContext: EnvironmentalContext?

    // Metadata
    var dataCompleteness: Double?        // 0-1
    var confidenceScore: Double?         // 0-1

    init(
        id: UUID = UUID(),
        userId: UUID,
        date: String,
        recoveryScore: Double
    ) {
        self.id = id
        self.userId = userId
        self.date = date
        self.localTimezone = nil
        self.localUtcOffsetMinutes = nil
        self.createdAt = Date()
        self.updatedAt = Date()
        let clampedScore = min(max(recoveryScore, 0), 100)
        self.recoveryScore = clampedScore
        self.recoveryZone = RecoveryZone.from(score: clampedScore)
        self.microZone = MicroZone.from(score: clampedScore)
    }
}

// MARK: - Environmental Context

/// External factors influencing biology and recovery. (V2 feature)
struct EnvironmentalContext: Codable, Equatable, Sendable {
    var weatherCondition: String?
    var temperatureC: Double?
    var pressureHpa: Double?
    var pressureDeltaHpa24h: Double? // Drop/Rise of atmospheric pressure
    var aqi: Int?
    var indoorCo2Ppm: Int?           // E.g., from HomeKit during sleep
    var moonPhase: String?            // E.g., "Full Moon", "New Moon"
    var daylightHours: Double?
    var city: String?
}

// MARK: - Autonomic State

enum AutonomicState: String, Codable, Sendable {
    case sympathetic
    case parasympathetic
    case balanced
}

// MARK: - Recovery Score (Value Object)

/// Lightweight value object for passing recovery data around.
struct RecoveryScoreValue: Codable, Equatable, Sendable {
    let score: Double         // 0-100
    let zone: RecoveryZone
    let confidence: Double    // 0-1
    let components: Components

    /// Derived on-device menstrual phase, when cycle tracking is enabled and
    /// at least two periods establish a cycle.
    let menstrualPhase: String?
    /// Points added to compensate for the current phase (spec §Menstrual).
    let menstrualAdjustment: Double?

    struct Components: Codable, Equatable, Sendable {
        var hrvScore: Double?
        var sleepScore: Double?
        var rhrScore: Double?
        var tempScore: Double?
    }

    init(
        score: Double,
        confidence: Double,
        components: Components,
        menstrualPhase: String? = nil,
        menstrualAdjustment: Double? = nil
    ) {
        self.score = min(max(score, 0), 100)
        self.zone = RecoveryZone.from(score: self.score)
        self.confidence = min(max(confidence, 0), 1)
        self.components = components
        self.menstrualPhase = menstrualPhase
        self.menstrualAdjustment = menstrualAdjustment
    }

    /// Whether this score is low-confidence and requires review.
    /// INVARIANT: Low-confidence threshold < 0.65
    var isLowConfidence: Bool {
        confidence < 0.65
    }

    /// Alias used by review-gated flows and sync payloads.
    var needsReview: Bool {
        isLowConfidence
    }
}
