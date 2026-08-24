// MARK: - Health & Wellness Models
// Source of truth: life_os_api_specification.md
// Tables: wellness_checks, body_composition, hydration_logs,
//         medical_scans, health_measurements, insights,
//         experiments, experiment_measurements

import Foundation

// MARK: - Wellness Check

/// Daily morning wellness questionnaire (self-reported).
struct WellnessCheck: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var checkedAt: Date                 // Representative timestamp for the recorded local day
    var date: String                    // YYYY-MM-DD authoritative local day
    var checkedTimezone: String?        // IANA timezone for the recorded local day
    var checkedUtcOffsetMinutes: Int?   // UTC offset for the recorded local day

    // Core wellness scores (1-5)
    var perceivedSleepQuality: Int?
    var energyLevel: Int?
    var muscleSoreness: Int?            // 5 = very sore
    var stressLevel: Int?
    var mood: Int?

    // PSS-4 (0-4 each, total 0-16)
    var pss4Q1: Int?                    // Unable to control
    var pss4Q2: Int?                    // Confident (reverse scored)
    var pss4Q3: Int?                    // Going your way (reverse scored)
    var pss4Q4: Int?                    // Difficulties piling up
    var pss4Total: Int?

    /// PSS-4 total score (0–16). Higher = more perceived stress.
    /// Q2 ("Confident") and Q3 ("Going your way") are positively worded,
    /// so they are reverse-scored: `(4 - Qn)` per Cohen & Williamson (1988).
    var derivedPss4Total: Int? {
        guard let q1 = pss4Q1, let q2 = pss4Q2,
              let q3 = pss4Q3, let q4 = pss4Q4 else { return nil }
        return q1 + (4 - q2) + (4 - q3) + q4
    }

    mutating func refreshPss4Total() {
        pss4Total = derivedPss4Total
    }

    // Illness
    var feelingIll: Bool
    var headache: Bool
    var digestiveIssues: Bool
    var notes: String?

    var wellnessScore: Double?
    var mentalHealthResourcesShown: Bool

    var deletedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), userId: UUID, date: String) {
        let now = Date()
        let timeZone = TimeZone.current
        self.id = id
        self.userId = userId
        self.checkedAt = now
        self.date = date
        self.checkedTimezone = timeZone.identifier
        self.checkedUtcOffsetMinutes = timeZone.secondsFromGMT(for: now) / 60
        self.feelingIll = false
        self.headache = false
        self.digestiveIssues = false
        self.pss4Total = nil
        self.mentalHealthResourcesShown = false
        self.createdAt = now
        self.updatedAt = now
    }
}

// MARK: - Body Composition

struct BodyComposition: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var measuredAt: Date
    var measuredDate: String?           // YYYY-MM-DD authoritative local day
    var measuredTimezone: String?       // IANA timezone at measurement time
    var measuredUtcOffsetMinutes: Int?  // UTC offset at measurement time
    var inputType: BodyCompInputType?

    // Core
    var weightKg: Double
    var bodyFatPercent: Double?
    var muscleMassKg: Double?
    var waterPercent: Double?
    var boneMassKg: Double?
    var visceralFatLevel: Int?
    var metabolicAge: Int?

    // Additional
    var bmi: Double?
    var bmrKcal: Int?
    var skeletalMusclePercent: Double?
    var proteinKg: Double?
    var mineralsKg: Double?

    // Derived
    var leanBodyMassKg: Double?
    var fatMassKg: Double?
    var targetWeightKg: Double?
    var weightControlKg: Double?
    var fatControlKg: Double?
    var muscleControlKg: Double?
    var segmentalLean: Data?
    var segmentalFat: Data?
    var impedanceData: Data?

    // Professional extras
    var fitnessScore: Int?
    var waistHipRatio: Double?

    // Data source
    var source: BodyCompSource?
    var deviceName: String?
    var reportDate: String?             // YYYY-MM-DD

    // Photo scan data
    var scanImageUrl: String?
    var aiExtractionRaw: Data?
    var aiConfidence: Double?
    var userCorrected: Bool

    var previousMeasurementId: UUID?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(id: UUID = UUID(), userId: UUID, measuredAt: Date = Date(), weightKg: Double) {
        let timeZone = TimeZone.current
        self.id = id
        self.userId = userId
        self.measuredAt = measuredAt
        self.measuredDate = HistoricalLocalDayContext.dayString(for: measuredAt, timeZone: timeZone)
        self.measuredTimezone = timeZone.identifier
        self.measuredUtcOffsetMinutes = timeZone.secondsFromGMT(for: measuredAt) / 60
        self.weightKg = weightKg
        self.userCorrected = false
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Hydration Log

struct HydrationLog: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var loggedAt: Date
    var loggedDate: String              // YYYY-MM-DD
    var loggedTimezone: String?
    var loggedUtcOffsetMinutes: Int?
    var waterMl: Int                    // 1-5000
    var source: HydrationSource
    var notes: String?
    var deletedAt: Date?
    var deletedReason: String?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), userId: UUID, loggedDate: String, waterMl: Int, source: HydrationSource = .manual) {
        self.id = id
        self.userId = userId
        self.loggedAt = Date()
        self.loggedDate = loggedDate
        self.waterMl = waterMl
        self.source = source
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Medical Scan

struct MedicalScan: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var createdAt: Date
    var updatedAt: Date

    var scanType: ScanType
    var status: ScanStatus
    var imageUrl: String?
    var imageUploadedAt: Date?
    var originalImageUrl: String?

    // AI extraction
    var aiExtractionRaw: Data?          // Full AI response
    var aiConfidence: Double?           // 0-1
    var ocrConfidence: Double?
    var extractionStatus: String?
    var extractionError: String?
    var markersExtracted: Int?
    var diagnosesExtracted: Int?
    var processedData: Data?
    var needsReview: Bool
    var userReviewed: Bool
    var userReviewedAt: Date?
    var manuallyVerified: Bool
    var pinnedByUser: Bool

    var scanDate: String?
    var labName: String?
    var documentLanguage: String?
    var sourceFileSha256: String?
    var storageMode: String?
    var storeOriginalInCloud: Bool?
    var scheduledDeletionAt: Date?
    var notes: String?
    var deletedAt: Date?

    init(id: UUID = UUID(), userId: UUID, scanType: ScanType) {
        self.id = id
        self.userId = userId
        self.createdAt = Date()
        self.updatedAt = Date()
        self.scanType = scanType
        self.status = .pending
        self.needsReview = false
        self.userReviewed = false
        self.manuallyVerified = false
        self.pinnedByUser = false
    }

    /// Invariant: low-confidence OCR extraction requires manual review.
    var requiresReview: Bool {
        guard let aiConfidence else { return false }
        return aiConfidence < 0.65
    }

    mutating func applyReviewGate() {
        needsReview = requiresReview
    }
}

// MARK: - Health Measurement

/// Extracted biomarker from labs.
struct HealthMeasurement: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var medicalScanId: UUID?
    var createdAt: Date
    var updatedAt: Date

    var biomarkerName: String
    var markerId: String?
    var value: Double
    var unit: String
    var originalValue: Double?
    var originalUnit: String?
    var originalLabel: String?
    var status: String?
    var referenceRangeLow: Double?
    var referenceRangeHigh: Double?
    var measuredAt: Date?
    var measuredDate: String?           // YYYY-MM-DD
    var sourceScanId: UUID?
    var sourceType: String?

    // AI extraction — single canonical confidence field.
    // Historically both `aiConfidence` and `confidence` existed; unified to `confidence`.
    // `aiConfidence` is a computed alias for backward-compatible read access.
    var confidence: Double?
    var userCorrected: Bool
    var manuallyVerified: Bool
    var notes: String?

    /// Backward-compatible alias. Always reads/writes via `confidence`.
    var aiConfidence: Double? {
        get { confidence }
        set { confidence = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case userId
        case medicalScanId
        case createdAt
        case updatedAt
        case biomarkerName
        case markerId
        case value
        case unit
        case originalValue
        case originalUnit
        case originalLabel
        case status
        case referenceRangeLow
        case referenceRangeHigh
        case measuredAt
        case measuredDate
        case sourceScanId
        case sourceType
        case confidence
        case userCorrected
        case manuallyVerified
        case notes
    }

    init(
        id: UUID = UUID(),
        userId: UUID,
        biomarkerName: String,
        value: Double,
        unit: String
    ) {
        self.id = id
        self.userId = userId
        self.createdAt = Date()
        self.updatedAt = Date()
        self.biomarkerName = biomarkerName
        self.value = value
        self.unit = unit
        self.sourceType = "scan"
        self.userCorrected = false
        self.manuallyVerified = false
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        userId = try container.decode(UUID.self, forKey: .userId)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        let decodedMedicalScanId = try container.decodeIfPresent(UUID.self, forKey: .medicalScanId)
        let decodedSourceScanId = try container.decodeIfPresent(UUID.self, forKey: .sourceScanId)
        medicalScanId = decodedMedicalScanId ?? decodedSourceScanId
        sourceScanId = decodedSourceScanId ?? decodedMedicalScanId

        let decodedOriginalLabel = Self.normalizedOptionalString(
            try container.decodeIfPresent(String.self, forKey: .originalLabel)
        )
        originalLabel = decodedOriginalLabel

        let decodedBiomarkerName = Self.normalizedOptionalString(
            try container.decodeIfPresent(String.self, forKey: .biomarkerName)
        )
        let decodedMarkerId = Self.canonicalMarkerId(
            markerId: try container.decodeIfPresent(String.self, forKey: .markerId),
            biomarkerName: decodedBiomarkerName,
            originalLabel: decodedOriginalLabel
        )
        markerId = decodedMarkerId
        biomarkerName = Self.resolvedBiomarkerName(
            biomarkerName: decodedBiomarkerName,
            originalLabel: decodedOriginalLabel,
            markerId: decodedMarkerId
        )

        value = try Self.decodeRequiredPossiblyEncryptedDouble(from: container, forKey: .value)
        unit = Self.normalizedOptionalString(
            try container.decodeIfPresent(String.self, forKey: .unit)
        ) ?? ""
        originalValue = try Self.decodeOptionalPossiblyEncryptedDouble(from: container, forKey: .originalValue)
        originalUnit = Self.normalizedOptionalString(
            try container.decodeIfPresent(String.self, forKey: .originalUnit)
        )

        referenceRangeLow = try container.decodeIfPresent(Double.self, forKey: .referenceRangeLow)
        referenceRangeHigh = try container.decodeIfPresent(Double.self, forKey: .referenceRangeHigh)

        let decodedMeasuredAt = try container.decodeIfPresent(Date.self, forKey: .measuredAt)
        let decodedMeasuredDate = Self.normalizedOptionalString(
            try container.decodeIfPresent(String.self, forKey: .measuredDate)
        )
        measuredAt = decodedMeasuredAt ?? decodedMeasuredDate.flatMap(Self.dateOnlyDate(from:))
        measuredDate = decodedMeasuredDate ?? decodedMeasuredAt.map(Self.dateOnlyString(from:))

        sourceType = Self.normalizedSourceType(
            try container.decodeIfPresent(String.self, forKey: .sourceType)
        )

        // Unify: server may send `confidence` or legacy `ai_confidence` key.
        // We decode `confidence` from the canonical key. For backward compatibility with
        // older server payloads that only send `ai_confidence`, fall back via dynamic key.
        let decodedConfidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        if let decodedConfidence {
            confidence = decodedConfidence
        } else {
            // Fallback: try legacy snake_case key "ai_confidence" via dynamic container.
            struct LegacyKey: CodingKey {
                var stringValue: String; var intValue: Int?
                init(_ s: String) { stringValue = s; intValue = nil }
                init?(stringValue: String) { self.init(stringValue) }
                init?(intValue: Int) { return nil }
            }
            let dynamic = try decoder.container(keyedBy: LegacyKey.self)
            confidence =
                try dynamic.decodeIfPresent(Double.self, forKey: LegacyKey("ai_confidence"))
                ?? dynamic.decodeIfPresent(Double.self, forKey: LegacyKey("aiConfidence"))
        }

        let rawStatus = try container.decodeIfPresent(String.self, forKey: .status)
        status = HealthMeasurementStatus.canonicalRawValue(
            for: rawStatus,
            value: value,
            referenceRangeLow: referenceRangeLow,
            referenceRangeHigh: referenceRangeHigh
        )

        userCorrected = try container.decodeIfPresent(Bool.self, forKey: .userCorrected) ?? false
        manuallyVerified = try container.decodeIfPresent(Bool.self, forKey: .manuallyVerified) ?? false
        notes = Self.normalizedOptionalString(try container.decodeIfPresent(String.self, forKey: .notes))
    }

    var resolvedMeasuredDate: String? {
        measuredDate ?? measuredAt.map(Self.dateOnlyString(from:))
    }

    var canonicalStatus: HealthMeasurementStatus? {
        HealthMeasurementStatus(
            normalizedRawValue: status,
            value: value,
            referenceRangeLow: referenceRangeLow,
            referenceRangeHigh: referenceRangeHigh
        )
    }

    nonisolated static func canonicalMarkerId(
        markerId: String?,
        biomarkerName: String?,
        originalLabel: String?
    ) -> String? {
        if let normalizedMarkerId = normalizedOptionalString(markerId)?
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_") {
            return normalizedMarkerId
        }

        let displayName = normalizedOptionalString(biomarkerName) ?? normalizedOptionalString(originalLabel)
        return displayName?
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
    }

    nonisolated static func resolvedBiomarkerName(
        biomarkerName: String?,
        originalLabel: String?,
        markerId: String?
    ) -> String {
        if let biomarkerName = normalizedOptionalString(biomarkerName) {
            return biomarkerName
        }
        if let originalLabel = normalizedOptionalString(originalLabel) {
            return originalLabel
        }
        if let markerId = normalizedOptionalString(markerId) {
            return markerId
                .replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .capitalized
        }
        return "Unknown Marker"
    }

    nonisolated static func normalizedSourceType(_ rawValue: String?) -> String? {
        guard let normalized = normalizedOptionalString(rawValue)?.lowercased() else {
            return nil
        }

        switch normalized {
        case "scan", "manual", "healthkit":
            return normalized
        default:
            return "scan"
        }
    }

    nonisolated static func dateOnlyString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    nonisolated static func dateOnlyDate(from rawValue: String?) -> Date? {
        guard let rawValue = normalizedOptionalString(rawValue) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: rawValue)
    }

    nonisolated private static func decodeRequiredPossiblyEncryptedDouble<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) throws -> Double {
        if let numericValue = try? container.decode(Double.self, forKey: key) {
            return numericValue
        }

        if let storedValue = try? container.decode(String.self, forKey: key),
           let decryptedValue = FieldEncryption.decryptStoredDouble(storedValue) {
            return decryptedValue
        }

        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "Expected numeric value or encrypted numeric payload."
        )
    }

    nonisolated private static func decodeOptionalPossiblyEncryptedDouble<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) throws -> Double? {
        guard container.contains(key),
              (try? container.decodeNil(forKey: key)) != true else {
            return nil
        }

        if let numericValue = try? container.decode(Double.self, forKey: key) {
            return numericValue
        }

        if let storedValue = try? container.decode(String.self, forKey: key) {
            return FieldEncryption.decryptStoredDouble(storedValue)
        }

        return nil
    }

    nonisolated private static func normalizedOptionalString(_ rawValue: String?) -> String? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

// MARK: - Insight

/// AI-generated insight.
struct Insight: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var createdAt: Date
    var updatedAt: Date

    var category: InsightCategory
    var type: String?
    var title: String
    var description: String?
    var body: String
    var confidence: Double              // 0-1 (canonical field)

    /// Backward-compatible alias. Always reads/writes via `confidence`.
    var confidenceScore: Double? {
        get { confidence }
        set { if let newValue { confidence = newValue } }
    }
    var inputsUsed: String?             // High-level, no raw sensitive data
    var reasoning: String?
    var dataPoints: Int?
    var correlationMethod: String?
    var correlationCoefficient: Double?
    var pValue: Double?
    var lagDays: Int?
    var confounders: String?
    var relatedMetrics: Data?
    var relatedDates: Data?
    var suggestedExperimentId: UUID?
    var priority: Int                   // 1 = highest
    var actionable: Bool
    var actionType: String?

    // Status
    var shownToUser: Bool?
    var shownAt: Date?
    var read: Bool
    var readAt: Date?
    var acknowledged: Bool
    var acknowledgedAt: Date?
    var dismissed: Bool
    var dismissedAt: Date?
    var actedUpon: Bool?
    var actionTaken: String?

    // Expiry
    var expiresAt: Date?
    var needsReview: Bool

    init(
        id: UUID = UUID(),
        userId: UUID,
        category: InsightCategory,
        title: String,
        body: String,
        confidence: Double
    ) {
        self.id = id
        self.userId = userId
        self.createdAt = Date()
        self.updatedAt = Date()
        self.category = category
        self.title = title
        self.body = Insight.withClinicianCaveatIfNeeded(body, category: category)
        self.confidence = confidence
        self.priority = 5
        self.actionable = false
        self.shownToUser = false
        self.read = false
        self.acknowledged = false
        self.dismissed = false
        self.actedUpon = false
        self.needsReview = confidence < 0.65
    }

    /// Invariant: low-confidence AI output requires review.
    var requiresReview: Bool {
        confidence < 0.65
    }

    /// Medical guardrail: all health-related AI text includes clinician caveat.
    var bodyWithClinicianCaveat: String {
        let disclaimer = String(localized: "clinician_disclaimer")
        guard category == .health || category == .recovery || category == .sleep else { return body }
        if body.localizedCaseInsensitiveContains(disclaimer) {
            return body
        }
        return "\(body) \(disclaimer)"
    }

    private static func withClinicianCaveatIfNeeded(_ body: String, category: InsightCategory) -> String {
        let disclaimer = String(localized: "clinician_disclaimer")
        guard category == .health || category == .recovery || category == .sleep else { return body }
        if body.localizedCaseInsensitiveContains(disclaimer) {
            return body
        }
        return "\(body) \(disclaimer)"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case category
        case type
        case title
        case description
        case body
        case confidence
        case inputsUsed = "inputs_used"
        case reasoning
        case dataPoints = "data_points"
        case correlationMethod = "correlation_method"
        case correlationCoefficient = "correlation_coefficient"
        case pValue = "p_value"
        case lagDays = "lag_days"
        case confounders
        case relatedMetrics = "related_metrics"
        case relatedDates = "related_dates"
        case suggestedExperimentId = "suggested_experiment_id"
        case priority
        case actionable
        case actionType = "action_type"
        case shownToUser = "shown_to_user"
        case shownAt = "shown_at"
        case read
        case readAt = "read_at"
        case acknowledged
        case acknowledgedAt = "acknowledged_at"
        case dismissed
        case dismissedAt = "dismissed_at"
        case actedUpon = "acted_upon"
        case actionTaken = "action_taken"
        case expiresAt = "expires_at"
        case needsReview = "needs_review"
    }
}

// MARK: - Experiment

/// N-of-1 experiment.
struct Experiment: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var createdAt: Date
    var updatedAt: Date

    var title: String
    var hypothesis: String?
    var variable: String                // What's being tested
    var controlDescription: String?
    var interventionDescription: String?
    var metric: String                  // What's being measured
    var primaryMetric: String?
    var secondaryMetrics: [String]?
    var measurementFrequency: MeasurementFrequency?
    var reminderTime: String?
    var durationDays: Int
    var status: ExperimentStatus
    var startDate: String?              // YYYY-MM-DD
    var endDate: String?
    var baselineStartDate: String?
    var baselineEndDate: String?
    var baselineDurationDays: Int?
    var interventionStartDate: String?
    var interventionEndDate: String?
    var interventionDurationDays: Int?
    var washoutStartDate: String?
    var washoutEndDate: String?
    var washoutDurationDays: Int?
    var baselineData: Data?             // JSON
    var baselineMean: Double?
    var baselineStdDev: Double?
    var interventionMean: Double?
    var interventionStdDev: Double?
    var effectSize: Double?
    var pValue: Double?
    var confidenceIntervalLower: Double?
    var confidenceIntervalUpper: Double?
    var significant: Bool?
    var effectDirection: EffectDirection?
    var resultSummary: String?
    var aiAnalysis: String?
    var aiInterpretation: String?
    var aiRecommendation: String?
    var notes: String?
    var userNotes: String?
    var compliancePercent: Double?
    var deletedAt: Date?
    var deletedReason: String?

    init(
        id: UUID = UUID(),
        userId: UUID,
        title: String,
        variable: String,
        metric: String,
        durationDays: Int
    ) {
        self.id = id
        self.userId = userId
        self.createdAt = Date()
        self.updatedAt = Date()
        self.title = title
        self.variable = variable
        self.metric = metric
        self.primaryMetric = metric
        self.durationDays = durationDays
        self.status = .design
    }

    var aiAnalysisWithClinicianCaveat: String? {
        let disclaimer = String(localized: "clinician_disclaimer")
        guard let aiAnalysis else { return nil }
        if aiAnalysis.localizedCaseInsensitiveContains(disclaimer) {
            return aiAnalysis
        }
        return "\(aiAnalysis) \(disclaimer)"
    }
}

extension ExperimentStatus {
    static let lifecycleActiveStatuses: Set<ExperimentStatus> = [
        .baseline,
        .intervention,
        .washout,
        .active,
    ]

    static let lifecycleTerminalStatuses: Set<ExperimentStatus> = [
        .completed,
        .abandoned,
        .cancelled,
    ]
}

extension Experiment {
    var lifecycleEndDate: String? {
        washoutEndDate ?? interventionEndDate ?? baselineEndDate ?? endDate
    }

    private var hasExplicitLifecycleSchedule: Bool {
        baselineStartDate != nil ||
            baselineEndDate != nil ||
            interventionStartDate != nil ||
            interventionEndDate != nil ||
            washoutStartDate != nil ||
            washoutEndDate != nil ||
            startDate != nil ||
            endDate != nil
    }

    func scheduledPhase(forLocalDate localDate: String) -> ExperimentPhase? {
        if let washoutStartDate,
           let washoutEndDate,
           localDate >= washoutStartDate,
           localDate <= washoutEndDate {
            return .washout
        }

        if let interventionStartDate,
           let interventionEndDate,
           localDate >= interventionStartDate,
           localDate <= interventionEndDate {
            return .intervention
        }

        if let baselineStartDate,
           let baselineEndDate,
           localDate >= baselineStartDate,
           localDate <= baselineEndDate {
            return .baseline
        }

        guard !hasExplicitLifecycleSchedule else { return nil }

        switch status {
        case .intervention:
            return .intervention
        case .washout:
            return .washout
        default:
            return .baseline
        }
    }

    func resolvedLifecycleStatus(forLocalDate localDate: String) -> ExperimentStatus {
        if ExperimentStatus.lifecycleTerminalStatuses.contains(status) {
            return status
        }

        if let lifecycleEndDate, localDate > lifecycleEndDate {
            return .completed
        }

        if let scheduledPhase = scheduledPhase(forLocalDate: localDate) {
            switch scheduledPhase {
            case .baseline:
                return .baseline
            case .intervention:
                return .intervention
            case .washout:
                return .washout
            }
        }

        if hasExplicitLifecycleSchedule {
            switch status {
            case .design:
                return .design
            case .active:
                return .baseline
            default:
                return status
            }
        }

        switch status {
        case .active:
            return .baseline
        default:
            return status
        }
    }

    func isLifecycleActive(forLocalDate localDate: String) -> Bool {
        ExperimentStatus.lifecycleActiveStatuses.contains(
            resolvedLifecycleStatus(forLocalDate: localDate)
        )
    }
}

// MARK: - Experiment Measurement

struct ExperimentMeasurement: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var experimentId: UUID
    var userId: UUID
    var date: String                    // YYYY-MM-DD
    var measurementDate: String?
    var measurementPhase: ExperimentPhase?
    var metricName: String?
    var metricValue: Double?
    var metricUnit: String?
    var protocolFollowed: Bool
    var value: Double
    var unit: String?
    var notes: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        experimentId: UUID,
        userId: UUID,
        date: String,
        value: Double,
        unit: String? = nil,
        measurementPhase: ExperimentPhase = .baseline,
        metricName: String = "primary_metric"
    ) {
        self.id = id
        self.experimentId = experimentId
        self.userId = userId
        self.date = date
        self.measurementDate = date
        self.measurementPhase = measurementPhase
        self.metricName = metricName
        self.metricValue = value
        self.metricUnit = unit
        self.protocolFollowed = true
        self.value = value
        self.unit = unit
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Supporting Enums

enum BodyCompInputType: String, Codable, Sendable {
    case homeScale = "home_scale"
    case professionalReport = "professional_report"
}

enum BodyCompSource: String, Codable, Sendable {
    case healthkit, manual, photoScan = "photo_scan"
    case withings, renpho, xiaomi, tanita, garmin
    case inbody, seca, dexa, other
}

enum HydrationSource: String, Codable, Sendable {
    case manual, wearable, `import` = "import", other
}

enum ScanType: String, Codable, Sendable {
    case bloodTest = "blood_test"
    case inbody
    case dexa
    case other

    /// Canonicalizes legacy/local aliases to the server contract.
    nonisolated static func canonicalRawValue(for rawValue: String?) -> String? {
        guard let normalized = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalized.isEmpty else {
            return nil
        }

        switch normalized {
        case Self.bloodTest.rawValue, "bloodwork":
            return Self.bloodTest.rawValue
        case Self.inbody.rawValue:
            return Self.inbody.rawValue
        case Self.dexa.rawValue:
            return Self.dexa.rawValue
        case Self.other.rawValue, "urine", "body_composition":
            return Self.other.rawValue
        default:
            return Self.other.rawValue
        }
    }

    init?(normalizedRawValue rawValue: String?) {
        guard let canonicalRawValue = Self.canonicalRawValue(for: rawValue),
              let scanType = Self(rawValue: canonicalRawValue) else {
            return nil
        }
        self = scanType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(normalizedRawValue: rawValue) ?? .other
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum ScanStatus: String, Codable, Sendable {
    case pending
    case processing
    case completed
    case failed
    case reviewRequired = "review_required"
}

enum HealthMeasurementStatus: String, Codable, Sendable {
    case criticalLow = "critical_low"
    case low
    case optimal
    case high
    case criticalHigh = "critical_high"

    nonisolated static func canonicalRawValue(
        for rawValue: String?,
        value: Double? = nil,
        referenceRangeLow: Double? = nil,
        referenceRangeHigh: Double? = nil
    ) -> String? {
        guard let normalized = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalized.isEmpty else {
            return inferredStatus(
                value: value,
                referenceRangeLow: referenceRangeLow,
                referenceRangeHigh: referenceRangeHigh
            )?.rawValue
        }

        switch normalized {
        case Self.criticalLow.rawValue:
            return Self.criticalLow.rawValue
        case Self.low.rawValue:
            return Self.low.rawValue
        case Self.optimal.rawValue, "normal", "within_range", "within range", "in_range":
            return Self.optimal.rawValue
        case Self.high.rawValue:
            return Self.high.rawValue
        case Self.criticalHigh.rawValue:
            return Self.criticalHigh.rawValue
        case "out_of_range", "out of range", "abnormal":
            return inferredStatus(
                value: value,
                referenceRangeLow: referenceRangeLow,
                referenceRangeHigh: referenceRangeHigh
            )?.rawValue
        default:
            return inferredStatus(
                value: value,
                referenceRangeLow: referenceRangeLow,
                referenceRangeHigh: referenceRangeHigh
            )?.rawValue
        }
    }

    init?(
        normalizedRawValue rawValue: String?,
        value: Double? = nil,
        referenceRangeLow: Double? = nil,
        referenceRangeHigh: Double? = nil
    ) {
        guard let canonicalRawValue = Self.canonicalRawValue(
                for: rawValue,
                value: value,
                referenceRangeLow: referenceRangeLow,
                referenceRangeHigh: referenceRangeHigh
              ),
              let status = Self(rawValue: canonicalRawValue) else {
            return nil
        }
        self = status
    }

    var isWithinRange: Bool {
        self == .optimal
    }

    var isCritical: Bool {
        self == .criticalLow || self == .criticalHigh
    }

    nonisolated private static func inferredStatus(
        value: Double?,
        referenceRangeLow: Double?,
        referenceRangeHigh: Double?
    ) -> Self? {
        guard let value else { return nil }
        if let referenceRangeLow, value < referenceRangeLow {
            return .low
        }
        if let referenceRangeHigh, value > referenceRangeHigh {
            return .high
        }
        if referenceRangeLow != nil || referenceRangeHigh != nil {
            return .optimal
        }
        return nil
    }
}

enum InsightCategory: String, Codable, Sendable, CaseIterable {
    case recovery, nutrition, training, sleep
    case supplement, health, experiment, general
}

enum ExperimentStatus: String, Codable, Sendable {
    case design
    case baseline
    case intervention
    case washout
    case completed
    case abandoned

    // Legacy statuses (pre-spec parity) kept for backward compatibility.
    case planned
    case active
    case paused
    case cancelled
}

enum ExperimentPhase: String, Codable, Sendable {
    case baseline
    case intervention
    case washout
}

enum MeasurementFrequency: String, Codable, Sendable {
    case daily
    case twiceDaily = "twice_daily"
    case weekly
}

enum EffectDirection: String, Codable, Sendable {
    case positive
    case negative
    case neutral
}
