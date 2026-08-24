// MARK: - Additional API-Spec Models
// Tables added for schema parity with life_os_api_specification.md.

import Foundation

// MARK: - Recommendations

struct Recommendation: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var createdAt: Date
    var updatedAt: Date

    var recommendationDate: String         // YYYY-MM-DD
    var timeOfDay: String?
    var category: String
    var priority: String
    var title: String
    var description: String
    var reasoning: String
    var insightId: UUID?
    var actionType: String?
    var actionParameters: Data?
    var autoExecute: Bool
    var dismissed: Bool
    var followed: Bool?
    var userFeedback: String?
    var recoveryScoreAtTime: Double?
    var triggerCondition: String?

    init(
        id: UUID = UUID(),
        userId: UUID,
        recommendationDate: String,
        category: String,
        priority: String,
        title: String,
        description: String,
        reasoning: String
    ) {
        self.id = id
        self.userId = userId
        self.createdAt = Date()
        self.updatedAt = Date()
        self.recommendationDate = recommendationDate
        self.category = category
        self.priority = priority
        self.title = title
        self.description = Recommendation.withClinicianCaveatIfNeeded(description, category: category)
        self.reasoning = reasoning
        self.autoExecute = false
        self.dismissed = false
    }

    var needsReview: Bool {
        priority == "critical"
    }

    var descriptionWithClinicianCaveat: String {
        let disclaimer = String(localized: "clinician_disclaimer")
        guard category == "health" || category == "recovery" || category == "sleep" else {
            return description
        }
        if description.localizedCaseInsensitiveContains(disclaimer) {
            return description
        }
        return "\(description) \(disclaimer)"
    }

    private static func withClinicianCaveatIfNeeded(_ description: String, category: String) -> String {
        let disclaimer = String(localized: "clinician_disclaimer")
        guard category == "health" || category == "recovery" || category == "sleep" else {
            return description
        }
        if description.localizedCaseInsensitiveContains(disclaimer) {
            return description
        }
        return "\(description) \(disclaimer)"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case recommendationDate = "recommendation_date"
        case timeOfDay = "time_of_day"
        case category
        case priority
        case title
        case description
        case reasoning
        case insightId = "insight_id"
        case actionType = "action_type"
        case actionParameters = "action_parameters"
        case autoExecute = "auto_execute"
        case dismissed
        case followed
        case userFeedback = "user_feedback"
        case recoveryScoreAtTime = "recovery_score_at_time"
        case triggerCondition = "trigger_condition"
    }
}

// MARK: - Weekly Strategy Reports

struct WeeklyStrategyReport: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var createdAt: Date
    var updatedAt: Date
    var weekStart: String                 // YYYY-MM-DD
    var weekEnd: String                   // YYYY-MM-DD
    var summaryStats: Data
    var reportMarkdown: String
    var modelUsed: String?
    var promptVersion: String?

    init(
        id: UUID = UUID(),
        userId: UUID,
        weekStart: String,
        weekEnd: String,
        summaryStats: Data,
        reportMarkdown: String
    ) {
        self.id = id
        self.userId = userId
        self.createdAt = Date()
        self.updatedAt = Date()
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.summaryStats = summaryStats
        self.reportMarkdown = reportMarkdown
    }

    var reportMarkdownWithClinicianCaveat: String {
        let disclaimer = String(localized: "clinician_disclaimer")
        if reportMarkdown.localizedCaseInsensitiveContains(disclaimer) {
            return reportMarkdown
        }
        return "\(reportMarkdown)\n\n\(disclaimer)"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case weekStart = "week_start"
        case weekEnd = "week_end"
        case summaryStats = "summary_stats"
        case reportMarkdown = "report_markdown"
        case modelUsed = "model_used"
        case promptVersion = "prompt_version"
    }
}

// MARK: - Health Marker Catalog

struct HealthMarkerCatalogEntry: Codable, Equatable, Sendable, Identifiable {
    let id: String
    var category: String
    var displayName: String
    var displayNameRu: String?
    var aliases: String                   // JSON array string
    var standardUnit: String
    var alternativeUnits: Data?
    var optimalRangeMale: String?
    var optimalRangeFemale: String?
    var criticalLow: Double?
    var criticalHigh: Double?
    var affectsRecovery: Bool
    var recoveryWeight: Double?
    var description: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        category: String,
        displayName: String,
        standardUnit: String
    ) {
        self.id = id
        self.category = category
        self.displayName = displayName
        self.aliases = "[]"
        self.standardUnit = standardUnit
        self.affectsRecovery = false
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    enum CodingKeys: String, CodingKey {
        case id
        case category
        case displayName = "display_name"
        case displayNameRu = "display_name_ru"
        case aliases
        case standardUnit = "standard_unit"
        case alternativeUnits = "alternative_units"
        case optimalRangeMale = "optimal_range_male"
        case optimalRangeFemale = "optimal_range_female"
        case criticalLow = "critical_low"
        case criticalHigh = "critical_high"
        case affectsRecovery = "affects_recovery"
        case recoveryWeight = "recovery_weight"
        case description
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Health Diagnoses

struct HealthDiagnosis: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var conditionId: String?
    var originalText: String
    var severity: String?
    var diagnosedAt: String?              // YYYY-MM-DD
    var sourceScanId: UUID?
    var isResolved: Bool
    var resolvedAt: String?               // YYYY-MM-DD
    var resolutionNotes: String?
    var confidence: Double?
    var notes: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        userId: UUID,
        originalText: String
    ) {
        self.id = id
        self.userId = userId
        self.originalText = originalText
        self.isResolved = false
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case conditionId = "condition_id"
        case originalText = "original_text"
        case severity
        case diagnosedAt = "diagnosed_at"
        case sourceScanId = "source_scan_id"
        case isResolved = "is_resolved"
        case resolvedAt = "resolved_at"
        case resolutionNotes = "resolution_notes"
        case confidence
        case notes
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Vector Memory

struct VectorMemoryEntry: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var createdAt: Date
    var updatedAt: Date
    var vectorId: String
    var vectorNamespace: String?
    var sourceType: String
    var sourceId: UUID
    var eventDate: String                 // YYYY-MM-DD
    var summary: String?
    var tags: String                      // JSON array string
    var searchableText: String?

    init(
        id: UUID = UUID(),
        userId: UUID,
        vectorId: String,
        sourceType: String,
        sourceId: UUID,
        eventDate: String
    ) {
        self.id = id
        self.userId = userId
        self.createdAt = Date()
        self.updatedAt = Date()
        self.vectorId = vectorId
        self.sourceType = sourceType
        self.sourceId = sourceId
        self.eventDate = eventDate
        self.tags = "[]"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case vectorId = "vector_id"
        case vectorNamespace = "vector_namespace"
        case sourceType = "source_type"
        case sourceId = "source_id"
        case eventDate = "event_date"
        case summary
        case tags
        case searchableText = "searchable_text"
    }
}

// MARK: - Analytics Events

struct AnalyticsEvent: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID?
    var eventName: String
    var properties: Data
    var sessionId: UUID?
    var appVersion: String?
    var osVersion: String?
    var deviceModel: String?
    var createdAt: Date

    init(id: UUID = UUID(), userId: UUID? = nil, eventName: String, properties: Data = Data("{}".utf8)) {
        self.id = id
        self.userId = userId
        self.eventName = eventName
        self.properties = properties
        self.createdAt = Date()
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case eventName = "event_name"
        case properties
        case sessionId = "session_id"
        case appVersion = "app_version"
        case osVersion = "os_version"
        case deviceModel = "device_model"
        case createdAt = "created_at"
    }
}

// MARK: - Training Templates

struct TrainingTemplate: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var createdAt: Date
    var updatedAt: Date
    var name: String
    var category: String?
    var estimatedDurationMinutes: Int?
    var templateExercises: Data
    var timesUsed: Int
    var lastUsedAt: Date?
    var archived: Bool
    var deletedAt: Date?
    var deletedReason: String?

    init(
        id: UUID = UUID(),
        userId: UUID,
        name: String,
        templateExercises: Data
    ) {
        self.id = id
        self.userId = userId
        self.createdAt = Date()
        self.updatedAt = Date()
        self.name = name
        self.templateExercises = templateExercises
        self.timesUsed = 0
        self.archived = false
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case name
        case category
        case estimatedDurationMinutes = "estimated_duration_minutes"
        case templateExercises = "template_exercises"
        case timesUsed = "times_used"
        case lastUsedAt = "last_used_at"
        case archived
        case deletedAt = "deleted_at"
        case deletedReason = "deleted_reason"
    }
}

// MARK: - GDPR Deletion Audit

struct DeletionAuditLog: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userIdDeleted: UUID
    var deletedAt: Date
    var postgresDeleted: Bool
    var vectorsDeleted: Bool
    var storageDeleted: Bool
    var complianceVerified: Bool
    var notes: String?

    init(
        id: UUID = UUID(),
        userIdDeleted: UUID,
        deletedAt: Date = Date(),
        postgresDeleted: Bool = false,
        vectorsDeleted: Bool = false,
        storageDeleted: Bool = false,
        complianceVerified: Bool = false,
        notes: String? = nil
    ) {
        self.id = id
        self.userIdDeleted = userIdDeleted
        self.deletedAt = deletedAt
        self.postgresDeleted = postgresDeleted
        self.vectorsDeleted = vectorsDeleted
        self.storageDeleted = storageDeleted
        self.complianceVerified = complianceVerified
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userIdDeleted = "user_id_deleted"
        case deletedAt = "deleted_at"
        case postgresDeleted = "postgres_deleted"
        case vectorsDeleted = "vectors_deleted"
        case storageDeleted = "storage_deleted"
        case complianceVerified = "compliance_verified"
        case notes
    }
}

struct DeletionFailure: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var failureType: String
    var error: String
    var resolved: Bool
    var retriedAt: Date?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        userId: UUID,
        failureType: String,
        error: String,
        resolved: Bool = false,
        retriedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.userId = userId
        self.failureType = failureType
        self.error = error
        self.resolved = resolved
        self.retriedAt = retriedAt
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case failureType = "failure_type"
        case error
        case resolved
        case retriedAt = "retried_at"
        case createdAt = "created_at"
    }
}

// MARK: - Consent Records

enum ConsentType: String, Codable, Sendable, CaseIterable {
    case termsOfService = "terms_of_service"
    case privacyPolicy = "privacy_policy"
    case healthDataProcessing = "health_data_processing"
    case analyticsTracking = "analytics_tracking"
    case marketingEmails = "marketing_emails"
    case thirdPartySharing = "third_party_sharing"
}

struct ConsentRecord: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var consentType: ConsentType
    var granted: Bool
    var timestamp: Date
    var version: String
    var ipAddress: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        userId: UUID,
        consentType: ConsentType,
        granted: Bool,
        timestamp: Date = Date(),
        version: String,
        ipAddress: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.userId = userId
        self.consentType = consentType
        self.granted = granted
        self.timestamp = timestamp
        self.version = version
        self.ipAddress = ipAddress
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case consentType = "consent_type"
        case granted
        case timestamp
        case version
        case ipAddress = "ip_address"
        case createdAt = "created_at"
    }
}

// MARK: - AI Cache

struct AICacheEntry: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var cacheKey: String
    var payload: Data
    var createdAt: Date
    var expiresAt: Date

    init(id: UUID = UUID(), cacheKey: String, payload: Data, createdAt: Date = Date(), expiresAt: Date) {
        self.id = id
        self.cacheKey = cacheKey
        self.payload = payload
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case cacheKey = "cache_key"
        case payload
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}
