// MARK: - Sleep Log Model
// Source of truth: life_os_api_specification.md — Table: sleep_logs

import Foundation
import GRDB

/// Daily sleep record pulled from HealthKit or entered manually.
struct SleepLog: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var date: String                    // YYYY-MM-DD (the morning date)
    var sleepDate: String?
    var createdAt: Date
    var updatedAt: Date

    // Core sleep metrics
    var bedTime: Date?
    var bedtimeIntended: Date?
    var bedtimeActual: Date?
    var wakeTime: Date?
    var waketime: Date?
    var totalDurationMinutes: Int?
    var timeInBedMinutes: Int?

    // Sleep stages (minutes)
    var deepSleepMinutes: Int?
    var remSleepMinutes: Int?
    var lightSleepMinutes: Int?
    var awakeMinutes: Int?

    // Derived percentages
    var deepSleepPercent: Double? {
        guard let total = totalDurationMinutes, total > 0, let deep = deepSleepMinutes else { return nil }
        return Double(deep) / Double(total) * 100
    }
    var remSleepPercent: Double? {
        guard let total = totalDurationMinutes, total > 0, let rem = remSleepMinutes else { return nil }
        return Double(rem) / Double(total) * 100
    }

    // Quality
    var sleepEfficiency: Double?        // 0-100 (time asleep / time in bed × 100)
    var sleepQualityScore: Double?      // 0-100 composite
    var perceivedQuality: Int?
    var morningEnergy: Int?
    var interruptions: Int?
    var timeToFallAsleepMinutes: Int?
    var numberOfAwakenings: Int?
    var notes: String?
    var alcohol: Double?
    var caffeineAfter14: Bool?
    var heavyMealLate: Bool?
    var exerciseEvening: Bool?
    var stressfulDay: Bool?
    var screenBeforeBed: Bool?
    var roomDarkness: Int?
    var roomTemperature: Double?
    var noiseLevel: Int?
    var dreamRecall: Bool?

    // Source
    var source: SleepSource
    var deviceName: String?

    // Timezone context
    var sleepTimezone: String?
    var sleepUtcOffsetMinutes: Int?

    // Soft delete
    var deletedAt: Date?

    init(id: UUID = UUID(), userId: UUID, date: String, source: SleepSource = .healthkit) {
        self.id = id
        self.userId = userId
        self.date = date
        self.sleepDate = date
        self.createdAt = Date()
        self.updatedAt = Date()
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId
        case date
        case sleepDate
        case createdAt
        case updatedAt
        case bedTime
        case bedtimeIntended
        case bedtimeActual
        case wakeTime
        case waketime
        case totalDurationMinutes
        case timeInBedMinutes
        case deepSleepMinutes
        case remSleepMinutes
        case lightSleepMinutes
        case awakeMinutes
        case sleepEfficiency
        case sleepQualityScore
        case perceivedQuality
        case morningEnergy
        case interruptions
        case timeToFallAsleepMinutes
        case numberOfAwakenings
        case notes
        case alcohol
        case caffeineAfter14 = "caffeine_after_14"
        case heavyMealLate
        case exerciseEvening
        case stressfulDay
        case screenBeforeBed
        case roomDarkness
        case roomTemperature
        case noiseLevel
        case dreamRecall
        case source
        case deviceName
        case sleepTimezone
        case sleepUtcOffsetMinutes
        case deletedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        userId = try container.decode(UUID.self, forKey: .userId)
        let fallbackDate = try container.decodeIfPresent(String.self, forKey: .date)
        guard let normalizedDate = try container.decodeIfPresent(String.self, forKey: .sleepDate) ?? fallbackDate else {
            throw DecodingError.keyNotFound(
                CodingKeys.sleepDate,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Expected either `sleep_date` or legacy `date`."
                )
            )
        }
        date = normalizedDate
        sleepDate = normalizedDate
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        bedTime = try container.decodeIfPresent(Date.self, forKey: .bedTime)
        bedtimeIntended = try container.decodeIfPresent(Date.self, forKey: .bedtimeIntended)
        bedtimeActual = try container.decodeIfPresent(Date.self, forKey: .bedtimeActual)
        wakeTime = try container.decodeIfPresent(Date.self, forKey: .wakeTime)
        waketime = try container.decodeIfPresent(Date.self, forKey: .waketime)
        totalDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .totalDurationMinutes)
        timeInBedMinutes = try container.decodeIfPresent(Int.self, forKey: .timeInBedMinutes)
        deepSleepMinutes = try container.decodeIfPresent(Int.self, forKey: .deepSleepMinutes)
        remSleepMinutes = try container.decodeIfPresent(Int.self, forKey: .remSleepMinutes)
        lightSleepMinutes = try container.decodeIfPresent(Int.self, forKey: .lightSleepMinutes)
        awakeMinutes = try container.decodeIfPresent(Int.self, forKey: .awakeMinutes)
        sleepEfficiency = try container.decodeIfPresent(Double.self, forKey: .sleepEfficiency)
        sleepQualityScore = try container.decodeIfPresent(Double.self, forKey: .sleepQualityScore)
        perceivedQuality = try container.decodeIfPresent(Int.self, forKey: .perceivedQuality)
        morningEnergy = try container.decodeIfPresent(Int.self, forKey: .morningEnergy)
        interruptions = try container.decodeIfPresent(Int.self, forKey: .interruptions)
        timeToFallAsleepMinutes = try container.decodeIfPresent(Int.self, forKey: .timeToFallAsleepMinutes)
        numberOfAwakenings = try container.decodeIfPresent(Int.self, forKey: .numberOfAwakenings)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        alcohol = try container.decodeIfPresent(Double.self, forKey: .alcohol)
        if let decodedCaffeine = try container.decodeIfPresent(Bool.self, forKey: .caffeineAfter14) {
            caffeineAfter14 = decodedCaffeine
        } else {
            let dynamicContainer = try decoder.container(keyedBy: AnyCodingKey.self)
            caffeineAfter14 = try dynamicContainer.decodeIfPresent(Bool.self, forKey: AnyCodingKey("caffeineAfter14"))
        }
        heavyMealLate = try container.decodeIfPresent(Bool.self, forKey: .heavyMealLate)
        exerciseEvening = try container.decodeIfPresent(Bool.self, forKey: .exerciseEvening)
        stressfulDay = try container.decodeIfPresent(Bool.self, forKey: .stressfulDay)
        screenBeforeBed = try container.decodeIfPresent(Bool.self, forKey: .screenBeforeBed)
        roomDarkness = try container.decodeIfPresent(Int.self, forKey: .roomDarkness)
        roomTemperature = try container.decodeIfPresent(Double.self, forKey: .roomTemperature)
        noiseLevel = try container.decodeIfPresent(Int.self, forKey: .noiseLevel)
        dreamRecall = try container.decodeIfPresent(Bool.self, forKey: .dreamRecall)
        source = try container.decodeIfPresent(SleepSource.self, forKey: .source) ?? .healthkit
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
        sleepTimezone = try container.decodeIfPresent(String.self, forKey: .sleepTimezone)
        sleepUtcOffsetMinutes = try container.decodeIfPresent(Int.self, forKey: .sleepUtcOffsetMinutes)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
    }
}

// MARK: - GRDB

extension SleepLog: FetchableRecord, PersistableRecord {
    static let databaseTableName = "sleep_logs"

    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy {
        .convertFromSnakeCase
    }

    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy {
        .convertToSnakeCase
    }
}

// MARK: - SyncTimestamped

extension SleepLog: SyncTimestamped {}

// MARK: - Sleep Source

enum SleepSource: String, Codable, Sendable {
    case healthkit
    case manual
    case wearable
    case `import` = "import"
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ value: String) {
        self.stringValue = value
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        return nil
    }
}

#if DEBUG
extension SleepLog {
    nonisolated static func _testAnyCodingKeyFromStringValue(_ value: String) -> Bool {
        AnyCodingKey(stringValue: value) != nil
    }

    nonisolated static func _testAnyCodingKeyFromIntValue(_ value: Int) -> Bool {
        AnyCodingKey(intValue: value) != nil
    }
}
#endif
