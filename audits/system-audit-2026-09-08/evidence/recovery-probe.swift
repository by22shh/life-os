import Foundation
// Actual pure production function bodies extracted unchanged; zone below is an unused carrier stub.
enum RecoveryZone { case unused; static func from(score: Double) -> Self { .unused } }
struct RecoveryScoreValue {
struct Components: Codable, Equatable, Sendable {
        var hrvScore: Double?
        var sleepScore: Double?
        var rhrScore: Double?
        var tempScore: Double?
    }
}
struct SleepData: Sendable {
    var totalHours: Double
    var deepMinutes: Int
    var remMinutes: Int
    var lightMinutes: Int
    var awakeMinutes: Int
    var efficiency: Double?         // 0-100
    var bedTime: Date?
    var wakeTime: Date?

    /// Quality score 0-100 based on duration, deep sleep %, and efficiency.
    var qualityScore: Double {
        var score = 0.0

        // Duration component (max 40 points for 7-9 hours)
        let durationScore: Double
        switch totalHours {
        case 7...9: durationScore = 40
        case 6..<7: durationScore = 30
        case 9..<10: durationScore = 35
        default: durationScore = max(0, 40 - abs(totalHours - 8) * 10)
        }
        score += durationScore

        // Deep sleep component (max 30 points for 15-25% of total)
        let totalMinutes = deepMinutes + remMinutes + lightMinutes
        if totalMinutes > 0 {
            let deepPct = Double(deepMinutes) / Double(totalMinutes) * 100
            if deepPct >= 15 && deepPct <= 25 {
                score += 30
            } else {
                score += max(0, 30 - abs(deepPct - 20) * 2)
            }
        }

        // Efficiency component (max 30 points for > 85%)
        if let eff = efficiency {
            score += min(30, eff / 100 * 35)
        }

        return min(100, max(0, score))
    }
}
enum RecoveryEngine {
static let minimumBaselineDays = 5
private enum Weight {
        static let hrv: Double = 0.40
        static let sleep: Double = 0.30
        static let rhr: Double = 0.15
        static let temp: Double = 0.15
    }
static func zScoreToScale(_ z: Double) -> Double {
        min(100, max(0, 50 + z * 15))
    }
static func temperatureDeviationScore(_ deviation: Double) -> Double {
        let absDev = Swift.abs(deviation)
        if absDev <= 0.2 { return 100 }
        if absDev <= 0.5 { return 100 - ((absDev - 0.2) * 100) }   // 100→70
        if absDev <= 1.0 { return 70 - ((absDev - 0.5) * 80) }     // 70→30
        if absDev <= 1.5 { return 30 - ((absDev - 1.0) * 60) }     // 30→0
        return 0
    }
static func rhrPercentageScore(current: Double, baseline: Double) -> Double {
        guard baseline > 0 else { return 50 }
        let pct = ((current - baseline) / baseline) * 100
        if pct <= -10 { return 100 }
        if pct <= 0   { return 60 + (Swift.abs(pct) * 4) }   // -10%→100, 0%→60
        if pct <= 10  { return 60 - (pct * 4) }               // 0%→60, +10%→20
        if pct <= 15  { return 20 - ((pct - 10) * 4) }        // +10%→20, +15%→0
        return 0
    }
static func componentConfidence(totalWeight: Double) -> Double {
        min(1, max(0, totalWeight))
    }
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
struct ComputedScore {
        let score: Double
        let zone: RecoveryZone
        let confidence: Double
        let components: RecoveryScoreValue.Components
    }
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
}

let baseline = RecoveryEngine.Baseline(hrvMean: 4, hrvStd: 0.1, rhrMean: 60, tempMean: 0, dataDays: 7)
let sleep = SleepData(totalHours: 8, deepMinutes: 96, remMinutes: 120, lightMinutes: 264, awakeMinutes: 0, efficiency: 90)
let withHrv = RecoveryEngine.computeScore(hrv: 3.7, sleep: sleep, restingHeartRate: 60, wristTempDeviation: 0, baseline: baseline)
let excludedHrv = RecoveryEngine.computeScore(hrv: nil, sleep: sleep, restingHeartRate: 60, wristTempDeviation: 0, baseline: baseline)
print("raw score with HRV=", withHrv.score, "excluded HRV=", excludedHrv.score)
let noStages = SleepData(totalHours: 8, deepMinutes: 0, remMinutes: 0, lightMinutes: 480, awakeMinutes: 0, efficiency: nil)
print("8h unspecified sleep / no inBed score=", noStages.qualityScore)
var noRem = sleep; noRem.remMinutes = 0; noRem.lightMinutes = 384
print("with REM=",sleep.qualityScore,"without REM=",noRem.qualityScore)
precondition(abs(withHrv.score - 56) < 0.001)
precondition(abs(excludedHrv.score - 90) < 0.001)
precondition(noStages.qualityScore == 40)
precondition(sleep.qualityScore == noRem.qualityScore)
