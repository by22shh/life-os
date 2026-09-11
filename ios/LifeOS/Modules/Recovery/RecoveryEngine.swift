// MARK: - Recovery Engine
// Source of truth: life_os_recovery_algorithms.md
// Composite: HRV=0.40, Sleep=0.30, RHR=0.15, Temp=0.15
// INVARIANT: Score must be 0-100. Zone boundaries per life_os_invariants.md.

import Foundation
import GRDB

/// Computes recovery scores using a weighted composite of biomarker sub-scores.
///
/// ## Algorithm Flow
/// 1. Fetch 7-day rolling baseline (IQR outlier exclusion, min 5 days)
/// 2. HRV: z-score transform `50 + (z × 15)` clamped [0, 100]
/// 3. Sleep: weighted composite (Duration 20%, Efficiency 15%, Deep 30%, REM 25%, Continuity 10%)
/// 4. RHR: percentage-deviation from baseline (spec thresholds: -10%→100, 0%→60, +10%→20, +15%→0)
/// 5. Temp: piecewise deviation scoring (≤0.2°C→100, 0.5→70, 1.0→30, 1.5→0)
/// 6. Apply weights (HRV=0.40, Sleep=0.30, RHR=0.15, Temp=0.15)
/// 7. Proportionally reweight if components are missing
/// 8. Clamp final score to [0, 100]
enum RecoveryEngine {

    // MARK: - Weights (per spec)

    private enum Weight {
        static let hrv: Double = 0.40
        static let sleep: Double = 0.30
        static let rhr: Double = 0.15
        static let temp: Double = 0.15
    }

    /// Minimum data days required for a valid baseline.
    static let minimumBaselineDays = 5

    // MARK: - Public API

    /// Compute recovery score for a user on a given date.
    /// Uses local DB for baseline data and today's biomarkers from `PhysiologicalState`.
    static func computeScore(
        userId: UUID,
        date: String,
        db: Database,
        importedSleep: SleepData? = nil
    ) throws -> RecoveryScoreValue {
        // Fetch today's physiological state
        guard let state = try PhysiologicalState
            .filter((Column("user_id") == userId || Column("user_id") == userId.uuidString) && Column("date") == date)
            .fetchOne(db)
        else {
            return RecoveryScoreValue(
                score: 50,
                confidence: 0,
                components: .init()
            )
        }

        // Fetch baseline
        let baseline = try fetchBaseline(userId: userId, currentDate: date, db: db)

        // Compute component scores
        var components: [(weight: Double, score: Double)] = []
        var compResult = RecoveryScoreValue.Components()

        // INVARIANT §8: Cardiac conditions MUST disable HRV scoring
        let healthFlags = try UserHealthFlags
            .filter((Column("user_id") == userId || Column("user_id") == userId.uuidString))
            .fetchOne(db)
        let hrvDisabled = healthFlags?.disableHrv ?? false
        // Beta blockers blunt absolute HRV. The baseline still adapts, but the
        // HRV contribution carries extra uncertainty.
        let hrvInterpretationCaveat = (healthFlags?.onBetaBlockers ?? false) && !hrvDisabled

        // Opt-in cycle personalization: on-device derivation only. The derived
        // phase never leaves the device.
        var menstrualDerivation: MenstrualPhaseDerivation?
        if healthFlags?.menstrualTrackingEnabled == true {
            let flowDates = try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT date
                    FROM menstrual_logs
                    WHERE (user_id = ? OR user_id = ?)
                      AND deleted_at IS NULL
                      AND flow IS NOT NULL
                      AND flow <> 'spotting'
                    """,
                arguments: [userId, userId.uuidString]
            )
            menstrualDerivation = MenstrualCycleAdjustment.derivePhase(flowDates: flowDates, on: date)
        }
        let lutealTemperatureCompensation = menstrualDerivation?.phase == .luteal
            ? MenstrualCycleAdjustment.lutealTemperatureCompensation
            : 0

        // HRV component (0.40) — skipped if cardiac condition present
        if !hrvDisabled,
           let hrv = state.hrvLnRmssd, let baselineHrv = baseline.hrvMean, let hrvStd = baseline.hrvStd, hrvStd > 0 {
            let z = (hrv - baselineHrv) / hrvStd
            let score = zScoreToScale(z)
            compResult.hrvScore = score
            components.append((Weight.hrv, score))
        }

        // Sleep component (0.30) — weighted composite via SleepScorer (spec §3.5 Sleep Score)
        // Sub-weights: Duration 20%, Efficiency 15%, Deep 30%, REM 25%, Continuity 10%
        let userAge = resolvedUserAge {
            try User
                .filter(Column("id") == userId.uuidString)
                .fetchOne(db)
        }
        let storedSleep = try SleepRecordSelection.daily(userId: userId, day: date, db: db)
        let sleepLog = storedSleep?.overridesImportedSleep == true ? storedSleep : (importedSleep?.scoringLog ?? storedSleep)
        let recentSleepLogs = try SleepRecordSelection.recent(userId: userId, before: date, limit: 7, db: db)
        if let sleepScore = SleepScorer.compositeScore(
            sleepLog: sleepLog,
            physiologicalState: state,
            age: userAge,
            recentLogs: recentSleepLogs
        ) {
            compResult.sleepScore = sleepScore
            components.append((Weight.sleep, sleepScore))
        } else if let quality = state.sleepQualityPercent {
            // Ultimate fallback: raw quality percent if SleepScorer has no data
            compResult.sleepScore = quality
            components.append((Weight.sleep, quality))
        }

        // RHR component (0.15) — percentage-deviation from baseline (spec §3.5 RHR Score)
        // -10% from baseline → 100, baseline → 60, +10% → 20, +15%+ → 0
        if let rhr = state.restingHeartRateBpm, let baseRhr = baseline.rhrMean, baseRhr > 0 {
            let score = rhrPercentageScore(current: Double(rhr), baseline: baseRhr)
            compResult.rhrScore = score
            components.append((Weight.rhr, score))
        }

        // Temperature component (0.15) — piecewise deviation scoring (spec §3.5 Temperature Score)
        // |dev| ≤ 0.2°C → 100, 0.2–0.5 → 70–100, 0.5–1.0 → 30–70, 1.0–1.5 → 0–30, >1.5 → 0
        if let temp = state.wristTemperatureDeviationC, let baseTemp = baseline.tempMean {
            let deviation = temp - baseTemp
            let score = temperatureDeviationScore(deviation - lutealTemperatureCompensation)
            compResult.tempScore = score
            components.append((Weight.temp, score))
        } else if let temp = state.wristTemperatureDeviationC {
            // Fallback: temp is already deviation from Apple's personal baseline
            let score = temperatureDeviationScore(temp - lutealTemperatureCompensation)
            compResult.tempScore = score
            components.append((Weight.temp, score))
        }

        // Compute totals and normalize
        let totalWeight = components.reduce(0) { $0 + $1.weight }
        let finalScore: Double
        let confidence: Double

        if totalWeight > 0 {
            // Renormalize: sum(score * weight) / sum(weights)
            let rawSum = components.reduce(0) { $0 + ($1.score * $1.weight) }
            let weightedSum = rawSum / totalWeight
            
            finalScore = min(100, max(0, weightedSum))
            confidence = componentConfidence(totalWeight: totalWeight)
        } else {
            // P1 #7: Fallback to neutral (50) if state exists but no valid metrics
            finalScore = 50
            confidence = 0
        }

        let phaseAdjustment = menstrualDerivation?.phase.scoreAdjustment ?? 0
        let adjustedScore = min(100, max(0, finalScore + phaseAdjustment))
        let adjustedConfidence = hrvInterpretationCaveat && compResult.hrvScore != nil
            ? max(0, confidence - 0.15)
            : confidence

        return RecoveryScoreValue(
            score: adjustedScore,
            confidence: adjustedConfidence,
            components: compResult,
            menstrualPhase: menstrualDerivation?.phase.rawValue,
            menstrualAdjustment: phaseAdjustment > 0 ? phaseAdjustment : nil
        )
    }

    // MARK: - Z-Score Transform

    /// Transform z-score to 0-100 scale: `50 + (z × 15)`, clamped [0, 100].
    static func zScoreToScale(_ z: Double) -> Double {
        min(100, max(0, 50 + z * 15))
    }
    
    /// Spec-conformant piecewise temperature deviation scoring (§3.5 Temperature Score).
    /// |dev| ≤ 0.2°C → 100; 0.2–0.5 → 100–70; 0.5–1.0 → 70–30; 1.0–1.5 → 30–0; >1.5 → 0
    static func temperatureDeviationScore(_ deviation: Double) -> Double {
        let absDev = Swift.abs(deviation)
        if absDev <= 0.2 { return 100 }
        if absDev <= 0.5 { return 100 - ((absDev - 0.2) * 100) }   // 100→70
        if absDev <= 1.0 { return 70 - ((absDev - 0.5) * 80) }     // 70→30
        if absDev <= 1.5 { return 30 - ((absDev - 1.0) * 60) }     // 30→0
        return 0
    }

    /// Spec-conformant RHR percentage-deviation scoring (§3.5 RHR Score).
    /// -10% → 100, baseline → 60, +10% → 20, +15%+ → 0
    static func rhrPercentageScore(current: Double, baseline: Double) -> Double {
        guard baseline > 0 else { return 50 }
        let pct = ((current - baseline) / baseline) * 100
        if pct <= -10 { return 100 }
        if pct <= 0   { return 60 + (Swift.abs(pct) * 4) }   // -10%→100, 0%→60
        if pct <= 10  { return 60 - (pct * 4) }               // 0%→60, +10%→20
        if pct <= 15  { return 20 - ((pct - 10) * 4) }        // +10%→20, +15%→0
        return 0
    }

    /// Converts available component weights into a normalized confidence score.
    static func componentConfidence(totalWeight: Double) -> Double {
        min(1, max(0, totalWeight))
    }

    private static func resolvedUserAge(fetchUser: () throws -> User?) -> Int {
        do {
            guard let user = try fetchUser() else { return 30 }
            if let dateOfBirth = user.dateOfBirth {
                return ageFromDateOfBirth(dateOfBirth)
            }
            if let ageRange = user.ageRange {
                return ageRange.representativeAge
            }
            return 30
        } catch {
            return 30
        }
    }

    private static func ageFromDateOfBirth(_ dateOfBirth: Date?) -> Int {
        guard let dateOfBirth else { return 30 }
        let components = Calendar.current.dateComponents([.year], from: dateOfBirth, to: Date())
        let years = components.year!
        return max(13, min(100, years))
    }

    // MARK: - Baseline Computation

    /// 7-day rolling baseline with IQR outlier exclusion.
    /// Requires minimum 5 days of data.
    static func fetchBaseline(
        userId: UUID,
        currentDate: String,
        db: Database
    ) throws -> Baseline {
        // Strict 7-day rolling baseline window per canonical algorithm.
        let states = try PhysiologicalState
            .filter((Column("user_id") == userId || Column("user_id") == userId.uuidString) && Column("date") < currentDate)
            .order(Column("date").desc)
            .limit(7)
            .fetchAll(db)

        guard states.count >= minimumBaselineDays else {
            return Baseline() // Empty baseline — insufficient data
        }

        // Extract arrays for each metric
        let hrvValues = states.compactMap(\.hrvLnRmssd)
        let sleepValues = states.compactMap(\.sleepDurationHours)
        let rhrValues = states.compactMap(\.restingHeartRateBpm).map(Double.init)
        
        // Temperature baseline (needed for Z-score)
        // Note: We use absolute deviation from 0 usually, but here we track mean?
        // Actually, wristTemperatureDeviationC is already relative to personal baseline.
        // So baseline of deviations should be near 0.
        // However, to compute Z-score of deviation, we need the StdDev of the past deviations.
        let tempValues = states.compactMap(\.wristTemperatureDeviationC)

        return Baseline(
            hrvMean: iqrFilteredMean(hrvValues),
            hrvStd: iqrFilteredStd(hrvValues),
            sleepMean: iqrFilteredMean(sleepValues),
            sleepStd: iqrFilteredStd(sleepValues),
            rhrMean: iqrFilteredMean(rhrValues),
            rhrStd: iqrFilteredStd(rhrValues),
            tempMean: iqrFilteredMean(tempValues),
            tempStd: iqrFilteredStd(tempValues),
            dataDays: states.count
        )
    }

    // MARK: - IQR Outlier Exclusion

    /// Compute mean after removing values outside 1.5×IQR.
    private static func iqrFilteredMean(_ values: [Double]) -> Double? {
        let filtered = iqrFilter(values)
        guard !filtered.isEmpty else { return nil }
        return filtered.reduce(0, +) / Double(filtered.count)
    }

    /// Compute standard deviation after IQR filtering.
    private static func iqrFilteredStd(_ values: [Double]) -> Double? {
        let filtered = iqrFilter(values)
        guard filtered.count >= 2 else { return nil }
        let mean = filtered.reduce(0, +) / Double(filtered.count)
        let variance = filtered.reduce(0) { $0 + pow($1 - mean, 2) } / Double(filtered.count - 1)
        return sqrt(variance)
    }

    /// Filter values using IQR method (remove outliers beyond 1.5×IQR).
    /// P1 #5: Uses linear interpolation for Q1/Q3.
    private static func iqrFilter(_ values: [Double]) -> [Double] {
        guard values.count >= 4 else { return values }

        let sorted = values.sorted()
        
        // Linear Interpolation for Quartiles
        // Method: (N-1) * p + 1 (1-based index) -> converted to 0-based
        // Ref: NIST, Hyndman & Fan Type 7 (standard in R/Excel)
        func percentile(_ p: Double, sorted: [Double]) -> Double {
            let n = Double(sorted.count)
            let pos = (n - 1) * p
            let index = Int(pos)
            let fraction = pos - Double(index)

            let v0 = sorted[index]
            let v1 = sorted[index + 1]
            return v0 + (v1 - v0) * fraction
        }

        let q1 = percentile(0.25, sorted: sorted)
        let q3 = percentile(0.75, sorted: sorted)
        let iqr = q3 - q1
        let lowerBound = q1 - 1.5 * iqr
        let upperBound = q3 + 1.5 * iqr

        return sorted.filter { $0 >= lowerBound && $0 <= upperBound }
    }
}

// MARK: - Baseline

extension RecoveryEngine {
    struct Baseline {
        var hrvMean: Double?
        var hrvStd: Double?
        var sleepMean: Double?
        var sleepStd: Double?
        var rhrMean: Double?
        var rhrStd: Double?
        var tempMean: Double? // Added for P1 #4
        var tempStd: Double?  // Added for P1 #4
        var dataDays: Int = 0

        var hasSufficientData: Bool { dataDays >= RecoveryEngine.minimumBaselineDays }
    }

    /// Result of a recovery score computation.
    struct ComputedScore {
        let score: Double
        let zone: RecoveryZone
        let confidence: Double
        let components: RecoveryScoreValue.Components
    }

    /// Test-only overload for raw biomarker math. Production paths must use the
    /// DB overload so health flags, canonical sleep scoring and cycle
    /// personalization are always applied.
#if DEBUG
    static func computeScore(
        hrv: Double?,
        sleep: SleepData?,
        restingHeartRate: Int?,
        wristTempDeviation: Double?,
        baseline: Baseline
    ) -> ComputedScore {
        var components: [(weight: Double, score: Double)] = []
        var compResult = RecoveryScoreValue.Components()

        // HRV component (0.40)
        if let hrv, let baselineHrv = baseline.hrvMean, let hrvStd = baseline.hrvStd, hrvStd > 0 {
            let z = (hrv - baselineHrv) / hrvStd
            let score = zScoreToScale(z)
            compResult.hrvScore = score
            components.append((Weight.hrv, score))
        }

        // Sleep component (0.30)
        if let sleep {
            let sleepScore = sleep.qualityScore
            compResult.sleepScore = sleepScore
            components.append((Weight.sleep, sleepScore))
        }

        // RHR component (0.15)
        if let rhr = restingHeartRate, let baseRhr = baseline.rhrMean, baseRhr > 0 {
            let score = rhrPercentageScore(current: Double(rhr), baseline: baseRhr)
            compResult.rhrScore = score
            components.append((Weight.rhr, score))
        }

        // Temperature component (0.15)
        if let temp = wristTempDeviation {
            let score: Double
            if let baseTemp = baseline.tempMean {
                score = temperatureDeviationScore(temp - baseTemp)
            } else {
                // Fallback: temp is already deviation from Apple's personal baseline
                score = temperatureDeviationScore(temp)
            }
            compResult.tempScore = score
            components.append((Weight.temp, score))
        }

        // Compute totals and normalize
        let totalWeight = components.reduce(0) { $0 + $1.weight }
        let finalScore: Double
        let confidence: Double

        if totalWeight > 0 {
            let rawSum = components.reduce(0) { $0 + ($1.score * $1.weight) }
            let weightedSum = rawSum / totalWeight
            finalScore = min(100, max(0, weightedSum))
            confidence = componentConfidence(totalWeight: totalWeight)
        } else {
            finalScore = 50
            confidence = 0
        }

        return ComputedScore(
            score: finalScore,
            zone: RecoveryZone.from(score: finalScore),
            confidence: confidence,
            components: compResult
        )
    }
#endif
}

#if DEBUG
extension RecoveryEngine {
    nonisolated static func _testAgeFromDateOfBirth(_ dateOfBirth: Date?) -> Int {
        ageFromDateOfBirth(dateOfBirth)
    }

    nonisolated static func _testResolvedUserAge(fetchUser: () throws -> User?) -> Int {
        resolvedUserAge(fetchUser: fetchUser)
    }
}
#endif


/// A single authoritative record per local morning date. Handles both legacy
/// GRDB UUID blobs and text identifiers without duplicating source rows.
enum SleepRecordSelection {
    static func daily(userId: UUID, day: String, includeDeleted: Bool = false, db: Database) throws -> SleepLog? {
        try SleepLog.fetchOne(db, sql: """
            SELECT * FROM sleep_logs
            WHERE (user_id = ? OR user_id = ?)
              AND COALESCE(sleep_date, date) = ?
              \(includeDeleted ? "" : "AND deleted_at IS NULL")
            ORDER BY (deleted_at IS NULL) DESC, (source = 'manual') DESC, updated_at DESC, created_at DESC
            LIMIT 1
            """, arguments: [userId, userId.uuidString, day])
    }

    static func recent(userId: UUID, before day: String, limit: Int, db: Database) throws -> [SleepLog] {
        try SleepLog.fetchAll(db, sql: """
            SELECT * FROM (
                SELECT *, ROW_NUMBER() OVER (
                    PARTITION BY COALESCE(sleep_date, date)
                    ORDER BY (source = 'manual') DESC, updated_at DESC, created_at DESC
                ) AS daily_rank
                FROM sleep_logs
                WHERE (user_id = ? OR user_id = ?)
                  AND COALESCE(sleep_date, date) < ? AND deleted_at IS NULL
            ) WHERE daily_rank = 1
            ORDER BY COALESCE(sleep_date, date) DESC LIMIT ?
            """, arguments: [userId, userId.uuidString, day, limit])
    }

    /// Preserve old source snapshots as tombstones, never as competing active
    /// days. Their pending imports are handled by the server's manual-first rule.
    static func supersedeOtherRecords(with log: SleepLog, db: Database) throws {
        try log.save(db)
        try db.execute(sql: """
            UPDATE sleep_logs SET deleted_at = ?, updated_at = ?
            WHERE (user_id = ? OR user_id = ?) AND COALESCE(sleep_date, date) = ?
              AND id != ? AND deleted_at IS NULL
            """, arguments: [log.updatedAt, log.updatedAt, log.userId, log.userId.uuidString, log.sleepDate ?? log.date, log.id])
    }

    static func applySleepFields(_ log: SleepLog?, to state: inout PhysiologicalState) {
        // Subjective-only legacy diary entries contain no replacement for the
        // physiological measurements already synced for this day.
        if let log, log.deletedAt == nil, log.totalDurationMinutes == nil { return }
        state.sleepDurationHours = log?.totalDurationMinutes.map { Double($0) / 60 }
        state.deepSleepPercent = log?.deepSleepPercent
        state.remSleepPercent = log?.remSleepPercent
        if let total = log?.totalDurationMinutes, total > 0 {
            state.lightSleepPercent = log?.lightSleepMinutes.map { Double($0) / Double(total) * 100 }
            state.awakePercent = log?.awakeMinutes.map { Double($0) / Double(total) * 100 }
        } else {
            state.lightSleepPercent = nil
            state.awakePercent = nil
        }
        state.sleepQualityPercent = nil
        state.sleepScore = nil
    }

    static func outboxEvent(for log: SleepLog) throws -> OutboxEvent {
        var event = OutboxEvent(httpMethod: .POST, path: "api-sleep-log", bodyJson: try JSONEncoder.supabase.encode(log), priority: 90)
        event.headersJson = try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
        return event
    }
}
