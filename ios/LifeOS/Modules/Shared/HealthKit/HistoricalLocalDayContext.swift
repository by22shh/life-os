import Foundation
import GRDB

struct HistoricalLocalDayContext: Equatable, Sendable {
    let referenceDate: Date
    let dayString: String
    let timeZoneIdentifier: String
    let utcOffsetMinutes: Int

    init(referenceDate: Date, dayString: String, timeZone: TimeZone) {
        self.referenceDate = referenceDate
        self.dayString = dayString
        self.timeZoneIdentifier = timeZone.identifier
        self.utcOffsetMinutes = timeZone.secondsFromGMT(for: referenceDate) / 60
    }

    init(referenceDate: Date, dayString: String, timeZoneIdentifier: String, utcOffsetMinutes: Int) {
        self.referenceDate = referenceDate
        self.dayString = dayString
        self.timeZoneIdentifier = timeZoneIdentifier
        self.utcOffsetMinutes = utcOffsetMinutes
    }

    var timeZone: TimeZone {
        Self.safeTimeZone(identifier: timeZoneIdentifier, fallbackOffsetMinutes: utcOffsetMinutes)
    }

    nonisolated static func dayString(for date: Date, timeZone: TimeZone) -> String {
        let components = calendar(timeZone: timeZone).dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    nonisolated static func referenceDate(
        for dayString: String,
        timeZone: TimeZone,
        hour: Int = 12
    ) -> Date? {
        let parts = dayString.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = 0
        components.second = 0
        return calendar(timeZone: timeZone).date(from: components)
    }

    nonisolated static func safeTimeZone(
        identifier: String,
        fallbackOffsetMinutes: Int? = nil
    ) -> TimeZone {
        if let timeZone = TimeZone(identifier: identifier) {
            return timeZone
        }
        if let fallbackOffsetMinutes,
           let timeZone = TimeZone(secondsFromGMT: fallbackOffsetMinutes * 60) {
            return timeZone
        }
        return .current
    }

    nonisolated private static func calendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }
}

enum TimeZoneHistorySource: String, Codable, Sendable {
    case healthSync = "health_sync"
    case manualEntry = "manual_entry"
}

struct TimeZoneHistoryEntry: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var recordedAt: Date
    var timeZoneIdentifier: String
    var utcOffsetMinutes: Int
    var source: TimeZoneHistorySource
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        userId: UUID,
        recordedAt: Date,
        timeZoneIdentifier: String,
        utcOffsetMinutes: Int,
        source: TimeZoneHistorySource = .healthSync,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.userId = userId
        self.recordedAt = recordedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.utcOffsetMinutes = utcOffsetMinutes
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var timeZone: TimeZone {
        HistoricalLocalDayContext.safeTimeZone(
            identifier: timeZoneIdentifier,
            fallbackOffsetMinutes: utcOffsetMinutes
        )
    }
}

actor TimeZoneHistoryStore {
    static let shared = TimeZoneHistoryStore()

    private let dbQueue: DatabaseQueue
    private let currentTimeZoneProvider: @Sendable () -> TimeZone
    private let nowProvider: @Sendable () -> Date

    init(
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue,
        currentTimeZoneProvider: @escaping @Sendable () -> TimeZone = { .autoupdatingCurrent },
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.dbQueue = dbQueue
        self.currentTimeZoneProvider = currentTimeZoneProvider
        self.nowProvider = nowProvider
    }

    @discardableResult
    func captureCurrentTimeZoneIfNeeded(
        userId: UUID,
        recordedAt: Date? = nil,
        source: TimeZoneHistorySource = .healthSync
    ) async throws -> TimeZoneHistoryEntry {
        let timestamp = recordedAt ?? nowProvider()
        let timeZone = currentTimeZoneProvider()
        let offsetMinutes = timeZone.secondsFromGMT(for: timestamp) / 60
        let targetDay = HistoricalLocalDayContext.dayString(for: timestamp, timeZone: timeZone)

        return try await dbQueue.write { db in
            if let latest = try TimeZoneHistoryEntry
                .filter(Column("user_id") == userId.uuidString)
                .order(Column("recorded_at").desc)
                .fetchOne(db) {
                let latestDay = HistoricalLocalDayContext.dayString(for: latest.recordedAt, timeZone: timeZone)
                let isSameDay = latestDay == targetDay
                let isSameZone = latest.timeZoneIdentifier == timeZone.identifier &&
                    latest.utcOffsetMinutes == offsetMinutes
                if isSameDay && isSameZone {
                    return latest
                }
            }

            let entry = TimeZoneHistoryEntry(
                userId: userId,
                recordedAt: timestamp,
                timeZoneIdentifier: timeZone.identifier,
                utcOffsetMinutes: offsetMinutes,
                source: source,
                createdAt: timestamp,
                updatedAt: timestamp
            )
            try entry.insert(db)
            return entry
        }
    }

    func hasRelevantSnapshot(for date: Date, userId: UUID) async throws -> Bool {
        try await dbQueue.read { db in
            let snapshots = try Self.loadSnapshots(userId: userId, db: db)
            return Self.bestSnapshot(forTimestamp: date, snapshots: snapshots) != nil
        }
    }

    func resolveLocalDayContext(for date: Date, userId: UUID) async throws -> HistoricalLocalDayContext {
        try await dbQueue.read { db in
            try Self.resolveLocalDayContext(for: date, userId: userId, db: db)
        }
    }

    func resolveLocalDayContext(
        forDayString dayString: String,
        userId: UUID,
        preferredDate: Date? = nil
    ) async throws -> HistoricalLocalDayContext {
        try await dbQueue.read { db in
            try Self.resolveLocalDayContext(
                forDayString: dayString,
                userId: userId,
                preferredDate: preferredDate,
                db: db
            )
        }
    }

    nonisolated static func resolveLocalDayContext(
        for date: Date,
        userId: UUID,
        db: Database
    ) throws -> HistoricalLocalDayContext {
        let fallbackTimeZone = try fetchFallbackTimeZone(userId: userId, db: db)
        let snapshots = try loadSnapshots(userId: userId, db: db)
        let snapshotTimeZone = bestSnapshot(forTimestamp: date, snapshots: snapshots)?.timeZone
        let candidateTimeZone = snapshotTimeZone ?? fallbackTimeZone
        let candidateDayString = HistoricalLocalDayContext.dayString(
            for: date,
            timeZone: candidateTimeZone
        )

        if let existingState = try PhysiologicalState
            .filter(Column("user_id") == userId.uuidString)
            .filter(Column("date") == candidateDayString)
            .fetchOne(db),
           let context = context(from: existingState, preferredDate: date) {
            return context
        }

        return HistoricalLocalDayContext(
            referenceDate: date,
            dayString: candidateDayString,
            timeZoneIdentifier: candidateTimeZone.identifier,
            utcOffsetMinutes: candidateTimeZone.secondsFromGMT(for: date) / 60
        )
    }

    nonisolated static func resolveLocalDayContext(
        forDayString dayString: String,
        userId: UUID,
        preferredDate: Date? = nil,
        db: Database
    ) throws -> HistoricalLocalDayContext {
        if let existingState = try PhysiologicalState
            .filter(Column("user_id") == userId.uuidString && Column("date") == dayString)
            .fetchOne(db),
           let context = context(from: existingState, preferredDate: preferredDate) {
            return context
        }

        let fallbackTimeZone = try fetchFallbackTimeZone(userId: userId, db: db)
        let snapshots = try loadSnapshots(userId: userId, db: db)

        if let snapshot = bestSnapshot(
            forDayString: dayString,
            snapshots: snapshots,
            fallbackTimeZone: fallbackTimeZone
        ) {
            return makeContext(
                dayString: dayString,
                timeZone: snapshot.timeZone,
                preferredDate: preferredDate
            )
        }

        return makeContext(
            dayString: dayString,
            timeZone: fallbackTimeZone,
            preferredDate: preferredDate
        )
    }

    func recentLocalDayContexts(
        days: Int,
        userId: UUID,
        referenceNow: Date? = nil
    ) async throws -> [HistoricalLocalDayContext] {
        guard days > 0 else { return [] }

        let now = referenceNow ?? nowProvider()
        let currentContext = try await resolveLocalDayContext(for: now, userId: userId)
        let currentNoon = HistoricalLocalDayContext.referenceDate(
            for: currentContext.dayString,
            timeZone: currentContext.timeZone
        ) ?? currentContext.referenceDate
        let calendar = Self.calendar(timeZone: currentContext.timeZone)

        var contexts: [HistoricalLocalDayContext] = []
        contexts.reserveCapacity(days)

        for offset in stride(from: days - 1, through: 0, by: -1) {
            let candidate = calendar.date(byAdding: .day, value: -offset, to: currentNoon)
                ?? currentNoon.addingTimeInterval(TimeInterval(-offset * 86_400))
            let dayString = HistoricalLocalDayContext.dayString(
                for: candidate,
                timeZone: currentContext.timeZone
            )
            let context = try await resolveLocalDayContext(
                forDayString: dayString,
                userId: userId,
                preferredDate: candidate
            )
            contexts.append(context)
        }

        return contexts
    }

    private static func fetchFallbackTimeZone(userId: UUID, db: Database) throws -> TimeZone {
        let row = try Row.fetchOne(
            db,
            sql: "SELECT timezone FROM users WHERE id = ? OR id = ? LIMIT 1",
            arguments: [userId, userId.uuidString]
        )
        let identifier: String? = row?["timezone"]

        return HistoricalLocalDayContext.safeTimeZone(identifier: identifier ?? TimeZone.current.identifier)
    }

    private static func loadSnapshots(userId: UUID, db: Database) throws -> [TimeZoneHistoryEntry] {
        try TimeZoneHistoryEntry
            .filter(Column("user_id") == userId.uuidString)
            .order(Column("recorded_at").desc)
            .fetchAll(db)
    }

    private static func context(
        from state: PhysiologicalState,
        preferredDate: Date?
    ) -> HistoricalLocalDayContext? {
        let timeZone: TimeZone
        if let identifier = state.localTimezone {
            timeZone = HistoricalLocalDayContext.safeTimeZone(
                identifier: identifier,
                fallbackOffsetMinutes: state.localUtcOffsetMinutes
            )
        } else if let offsetMinutes = state.localUtcOffsetMinutes,
                  let fixedOffsetZone = TimeZone(secondsFromGMT: offsetMinutes * 60) {
            timeZone = fixedOffsetZone
        } else {
            return nil
        }
        return makeContext(dayString: state.date, timeZone: timeZone, preferredDate: preferredDate)
    }

    private static func bestSnapshot(
        forDayString dayString: String,
        snapshots: [TimeZoneHistoryEntry],
        fallbackTimeZone: TimeZone
    ) -> TimeZoneHistoryEntry? {
        let sameDaySnapshots = snapshots.filter { snapshot in
            HistoricalLocalDayContext.dayString(for: snapshot.recordedAt, timeZone: snapshot.timeZone) == dayString
        }

        if !sameDaySnapshots.isEmpty {
            return sameDaySnapshots.min { lhs, rhs in
                let lhsDistance = snapshotNoonDistance(lhs, dayString: dayString)
                let rhsDistance = snapshotNoonDistance(rhs, dayString: dayString)
                if lhsDistance != rhsDistance {
                    return lhsDistance < rhsDistance
                }
                return lhs.recordedAt > rhs.recordedAt
            }
        }

        let boundary = HistoricalLocalDayContext.referenceDate(
            for: dayString,
            timeZone: fallbackTimeZone,
            hour: 12
        )?.addingTimeInterval(18 * 3_600)

        guard let boundary else { return nil }
        return snapshots
            .filter { $0.recordedAt <= boundary }
            .max { lhs, rhs in lhs.recordedAt < rhs.recordedAt }
    }

    private static func bestSnapshot(
        forTimestamp timestamp: Date,
        snapshots: [TimeZoneHistoryEntry]
    ) -> TimeZoneHistoryEntry? {
        if let priorSnapshot = snapshots
            .filter({ $0.recordedAt <= timestamp })
            .max(by: { lhs, rhs in lhs.recordedAt < rhs.recordedAt }) {
            return priorSnapshot
        }

        let sameLocalDaySnapshots = snapshots.filter { snapshot in
            HistoricalLocalDayContext.dayString(for: timestamp, timeZone: snapshot.timeZone) ==
                HistoricalLocalDayContext.dayString(for: snapshot.recordedAt, timeZone: snapshot.timeZone)
        }
        if !sameLocalDaySnapshots.isEmpty {
            return sameLocalDaySnapshots.min { lhs, rhs in
                let lhsDistance = abs(lhs.recordedAt.timeIntervalSince(timestamp))
                let rhsDistance = abs(rhs.recordedAt.timeIntervalSince(timestamp))
                if lhsDistance != rhsDistance {
                    return lhsDistance < rhsDistance
                }
                return lhs.recordedAt < rhs.recordedAt
            }
        }

        return snapshots.min { lhs, rhs in lhs.recordedAt < rhs.recordedAt }
    }

    private static func snapshotNoonDistance(
        _ snapshot: TimeZoneHistoryEntry,
        dayString: String
    ) -> TimeInterval {
        guard let noon = HistoricalLocalDayContext.referenceDate(
            for: dayString,
            timeZone: snapshot.timeZone,
            hour: 12
        ) else {
            return .greatestFiniteMagnitude
        }
        return abs(snapshot.recordedAt.timeIntervalSince(noon))
    }

    private static func makeContext(
        dayString: String,
        timeZone: TimeZone,
        preferredDate: Date?
    ) -> HistoricalLocalDayContext {
        let referenceDate = HistoricalLocalDayContext.referenceDate(
            for: dayString,
            timeZone: timeZone
        ) ?? preferredDate ?? nowFallback(timeZone: timeZone)
        return HistoricalLocalDayContext(
            referenceDate: referenceDate,
            dayString: dayString,
            timeZone: timeZone
        )
    }

    private static func nowFallback(timeZone: TimeZone) -> Date {
        HistoricalLocalDayContext.referenceDate(
            for: HistoricalLocalDayContext.dayString(for: Date(), timeZone: timeZone),
            timeZone: timeZone
        ) ?? Date()
    }

    private static func calendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }
}
