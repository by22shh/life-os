import Foundation

// MARK: - Watch Snapshot Model
// Source of truth: life_os_watchos_spec.md §2

public struct WatchSnapshot: Codable, Sendable {

    // MARK: - Nested Types

    public struct NextBestAction: Codable, Sendable {
        public struct Payload: Codable, Sendable {
            public var deepLink: String?
            public var supplementName: String?
            public var scheduledTime: String?
            public var insightId: String?
            public var date: String?

            enum CodingKeys: String, CodingKey {
                case deepLink = "deep_link"
                case supplementName = "supplement_name"
                case scheduledTime = "scheduled_time"
                case insightId = "insight_id"
                case date
            }
        }

        public var type: String
        public var labelCopyId: String
        public var payload: Payload?

        enum CodingKeys: String, CodingKey {
            case type
            case labelCopyId = "label_copy_id"
            case payload
        }
    }

    public struct SupplementsDueSoon: Codable, Sendable {
        public var time: String
        public var count: Int
    }

    // MARK: - Core Fields (never dropped per §2 truncation rules)

    public var date: String?
    public var lastUpdatedAt: Date
    public var recoveryScore: Double?
    public var recoveryZone: String?
    public var confidenceScore: Double?
    public var nextBestAction: NextBestAction?

    // MARK: - Optional Fields (dropped in priority order per §2)

    public var sleepDurationHours: Double?
    public var sleepQualityPercent: Double?
    public var nutritionAdherencePercent: Double?
    public var supplementsDueSoon: SupplementsDueSoon?

    // MARK: - Metadata

    public var wasTruncated: Bool?

    // MARK: - Init

    public init(
        date: String? = nil,
        lastUpdatedAt: Date = Date(),
        recoveryScore: Double? = nil,
        recoveryZone: String? = nil,
        confidenceScore: Double? = nil,
        nextBestAction: NextBestAction? = nil,
        sleepDurationHours: Double? = nil,
        sleepQualityPercent: Double? = nil,
        nutritionAdherencePercent: Double? = nil,
        supplementsDueSoon: SupplementsDueSoon? = nil,
        wasTruncated: Bool? = nil
    ) {
        self.date = date
        self.lastUpdatedAt = lastUpdatedAt
        self.recoveryScore = recoveryScore
        self.recoveryZone = recoveryZone
        self.confidenceScore = confidenceScore
        self.nextBestAction = nextBestAction
        self.sleepDurationHours = sleepDurationHours
        self.sleepQualityPercent = sleepQualityPercent
        self.nutritionAdherencePercent = nutritionAdherencePercent
        self.supplementsDueSoon = supplementsDueSoon
        self.wasTruncated = wasTruncated
    }

    // MARK: - Coding Keys

    enum CodingKeys: String, CodingKey {
        case date
        case lastUpdatedAt = "last_updated_at"
        case recoveryScore = "recovery_score"
        case recoveryZone = "recovery_zone"
        case confidenceScore = "confidence_score"
        case nextBestAction = "next_best_action"
        case sleepDurationHours = "sleep_duration_hours"
        case sleepQualityPercent = "sleep_quality_percent"
        case nutritionAdherencePercent = "nutrition_adherence_percent"
        case supplementsDueSoon = "supplements_due_soon"
        case wasTruncated = "was_truncated"
    }
}
