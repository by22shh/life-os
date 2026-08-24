// MARK: - Supplement Models
// Source of truth: life_os_api_specification.md
// Tables: supplement_catalog, user_supplements, supplement_logs

import Foundation

// MARK: - Supplement Catalog Entry

/// Master list of common supplements (reference data only).
/// RULE: This catalog MUST NOT contain dosing or medical guidance.
struct SupplementCatalogEntry: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var category: SupplementCategory
    var description: String?
    var bestTime: SupplementTiming?
    var takeWithFood: Bool
    var evidenceLevel: EvidenceLevel?
    var primaryBenefits: [String]
    var avoidWith: [String]
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, category: SupplementCategory) {
        self.id = id
        self.name = name
        self.category = category
        self.takeWithFood = false
        self.primaryBenefits = []
        self.avoidWith = []
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - User Supplement

/// User's supplement stack (what they take regularly).
/// RULE: All doses are user-entered. The app must not prescribe or adjust dosages.
struct UserSupplement: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var catalogId: UUID?
    var customName: String?
    var doseAmount: Double?
    var doseUnit: String
    var frequency: SupplementFrequency
    var scheduledTimes: [String]    // ["08:00", "20:00"]
    var daysOfWeek: [Int]?          // 0=Sun, 6=Sat (nil = every day)
    var takeWithFood: Bool
    var notes: String?
    var active: Bool
    var startedAt: String           // YYYY-MM-DD
    var endedAt: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        userId: UUID,
        frequency: SupplementFrequency = .daily,
        doseUnit: String = "mg"
    ) {
        self.id = id
        self.userId = userId
        self.doseUnit = doseUnit
        self.frequency = frequency
        self.scheduledTimes = []
        self.takeWithFood = false
        self.active = true
        self.startedAt = ISO8601DateFormatter.string(from: Date(),
            timeZone: .current, formatOptions: [.withFullDate])
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Supplement Log

struct SupplementLog: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var userSupplementId: UUID?
    var takenAt: Date
    var takenDate: String               // YYYY-MM-DD user-local date
    var takenTimezone: String?
    var takenUtcOffsetMinutes: Int?
    var supplementName: String
    var doseAmount: Double?
    var doseUnit: String
    var withFood: Bool?
    var notes: String?
    var wasScheduled: Bool
    var scheduledTime: String?          // "HH:mm"
    var feltEffect: FeltEffect?
    var deletedAt: Date?
    var deletedReason: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        userId: UUID,
        supplementName: String,
        takenAt: Date = Date(),
        takenDate: String,
        doseUnit: String = "mg"
    ) {
        self.id = id
        self.userId = userId
        self.supplementName = supplementName
        self.takenAt = takenAt
        self.takenDate = takenDate
        self.doseUnit = doseUnit
        self.wasScheduled = false
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Supporting Enums

enum SupplementCategory: String, Codable, Sendable {
    case vitamin
    case mineral
    case aminoAcid = "amino_acid"
    case herbal
    case probiotic
    case omega
    case nootropic
    case performance
    case other
}

enum SupplementTiming: String, Codable, Sendable {
    case morning
    case withFood = "with_food"
    case beforeBed = "before_bed"
    case emptyStomach = "empty_stomach"
    case any
}

enum EvidenceLevel: String, Codable, Sendable {
    case strong
    case moderate
    case weak
    case anecdotal
}

enum SupplementFrequency: String, Codable, Sendable {
    case daily
    case twiceDaily = "twice_daily"
    case weekly
    case asNeeded = "as_needed"
}

enum FeltEffect: String, Codable, Sendable {
    case positive
    case negative
    case neutral
    case none
}
