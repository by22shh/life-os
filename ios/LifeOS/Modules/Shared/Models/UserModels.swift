// MARK: - User Models
// Source of truth: life_os_api_specification.md — Tables: users, user_health_flags

import Foundation

// MARK: - User

struct User: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var createdAt: Date
    var updatedAt: Date

    // Auth
    var authId: UUID

    // Profile
    var email: String?
    var displayName: String?
    var dateOfBirth: Date?
    var ageRange: AgeRange?

    // Biometrics
    var sex: BiologicalSex?
    var heightCm: Double?
    var weightKg: Double?

    // Goals
    var primaryGoal: PrimaryGoal?
    var activityLevel: ActivityLevel?

    // Baselines (calculated after 3-7 days)
    var baselineHrvMs: Double?
    var baselineRhrBpm: Int?
    var baselineSleepHours: Double?

    // Preferences
    var timezone: String
    var units: UnitSystem
    var notificationEnabled: Bool

    // Metadata
    var onboardingCompleted: Bool
    var calibrationDaysRemaining: Int

    // Account deletion
    var deletionScheduledAt: Date?
    var deletionReason: String?
    var deletionInProgress: Bool

    init(
        id: UUID = UUID(),
        authId: UUID,
        timezone: String = "UTC",
        units: UnitSystem = .metric
    ) {
        self.id = id
        self.createdAt = Date()
        self.updatedAt = Date()
        self.authId = authId
        self.timezone = timezone
        self.units = units
        self.notificationEnabled = true
        self.onboardingCompleted = false
        self.calibrationDaysRemaining = 3
        self.deletionInProgress = false
    }
}

// MARK: - Supporting Enums

enum AgeRange: String, Codable, Sendable, CaseIterable {
    case under18 = "under_18"
    case age18_24 = "18_24"
    case age25_34 = "25_34"
    case age35_44 = "35_44"
    case age45_54 = "45_54"
    case age55_64 = "55_64"
    case age65Plus = "65_plus"

    init(age: Int) {
        switch age {
        case ..<18:
            self = .under18
        case 18...24:
            self = .age18_24
        case 25...34:
            self = .age25_34
        case 35...44:
            self = .age35_44
        case 45...54:
            self = .age45_54
        case 55...64:
            self = .age55_64
        default:
            self = .age65Plus
        }
    }

    var representativeAge: Int {
        switch self {
        case .under18:
            return 17
        case .age18_24:
            return 21
        case .age25_34:
            return 30
        case .age35_44:
            return 40
        case .age45_54:
            return 50
        case .age55_64:
            return 60
        case .age65Plus:
            return 70
        }
    }
}

enum BiologicalSex: String, Codable, Sendable, CaseIterable {
    case male
    case female
    case other
}

enum PrimaryGoal: String, Codable, Sendable, CaseIterable {
    case recovery
    case performance
    case weight
    case generalHealth = "general_health"
}

enum ActivityLevel: String, Codable, Sendable, CaseIterable {
    case sedentary
    case light
    case moderate
    case active
    case veryActive = "very_active"
}

enum UnitSystem: String, Codable, Sendable, CaseIterable {
    case metric
    case imperial
}

// MARK: - User Health Flags

/// Health screening flags from onboarding. Stored locally by default.
/// Only synced to server when cloud_backup_enabled = true.
struct UserHealthFlags: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var createdAt: Date
    var updatedAt: Date

    // Cardiac
    var hasCardiacCondition: Bool {
        didSet { refreshDerivedFlags() }
    }
    var hasPacemaker: Bool {
        didSet { refreshDerivedFlags() }
    }
    var onBetaBlockers: Bool

    // Reproductive
    var isPregnant: Bool {
        didSet { refreshDerivedFlags() }
    }
    var menstrualTrackingEnabled: Bool

    // Mental health
    var hasEatingDisorderHistory: Bool {
        didSet { refreshDerivedFlags() }
    }
    var hasChronicFatigue: Bool

    // Derived behavior overrides
    var disableHrv: Bool
    var hideCalories: Bool
    var pregnancyMode: Bool

    init(id: UUID = UUID(), userId: UUID) {
        self.id = id
        self.userId = userId
        self.createdAt = Date()
        self.updatedAt = Date()
        self.hasCardiacCondition = false
        self.hasPacemaker = false
        self.onBetaBlockers = false
        self.isPregnant = false
        self.menstrualTrackingEnabled = false
        self.hasEatingDisorderHistory = false
        self.hasChronicFatigue = false
        self.disableHrv = false
        self.hideCalories = false
        self.pregnancyMode = false
        refreshDerivedFlags()
    }

    mutating func refreshDerivedFlags() {
        disableHrv = hasCardiacCondition || hasPacemaker
        hideCalories = hasEatingDisorderHistory
        pregnancyMode = isPregnant
    }
}

// MARK: - Notification Settings

struct NotificationSettings: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var createdAt: Date
    var updatedAt: Date

    // Toggles
    var morningBriefEnabled: Bool
    var positiveEnabled: Bool
    var nudgesEnabled: Bool
    var celebrationEnabled: Bool
    var criticalOnly: Bool

    // Scheduling (wall-clock time, user's local timezone)
    var morningBriefTimeLocal: String  // "HH:mm"
    var quietHoursStart: String        // "HH:mm"
    var quietHoursEnd: String          // "HH:mm"

    // Limits (mirrors PRD defaults)
    var maxPositivePerDay: Int
    var maxNudgesPerDay: Int
    var maxCelebrationPerDay: Int
    /// INVARIANT: Hard cap ≤ 6 per day. Never exceeded.
    var maxTotalPerDay: Int

    // Control level
    var controlLevel: ControlLevel
    var focusControlEnabled: Bool
    var focusControlLastGrantedAt: Date?

    init(id: UUID = UUID(), userId: UUID) {
        self.id = id
        self.userId = userId
        self.createdAt = Date()
        self.updatedAt = Date()
        self.morningBriefEnabled = true
        self.positiveEnabled = true
        self.nudgesEnabled = true
        self.celebrationEnabled = true
        self.criticalOnly = false
        self.morningBriefTimeLocal = "07:00"
        self.quietHoursStart = "22:00"
        self.quietHoursEnd = "07:00"
        self.maxPositivePerDay = 3
        self.maxNudgesPerDay = 2
        self.maxCelebrationPerDay = 2
        self.maxTotalPerDay = 6
        self.controlLevel = .advisory
        self.focusControlEnabled = false
    }

    /// Returns a normalized copy that enforces cross-document invariants.
    func normalizedForInvariants(guardianModeEnabled: Bool = true) -> NotificationSettings {
        var normalized = self
        normalized.maxTotalPerDay = min(6, max(1, maxTotalPerDay))
        normalized.maxPositivePerDay = min(3, max(0, maxPositivePerDay))
        normalized.maxNudgesPerDay = min(2, max(0, maxNudgesPerDay))
        normalized.maxCelebrationPerDay = min(2, max(0, maxCelebrationPerDay))

        if normalized.criticalOnly {
            normalized.controlLevel = .advisory
            normalized.focusControlEnabled = false
        } else if !guardianModeEnabled &&
            (normalized.controlLevel == .guardian || normalized.focusControlEnabled) {
            normalized.controlLevel = .protective
            normalized.focusControlEnabled = false
        } else if normalized.controlLevel == .guardian && !normalized.focusControlEnabled {
            // Invariant: guardian mode requires Focus Control authorization.
            normalized.controlLevel = .protective
        }
        return normalized
    }

    /// Canonical payload used by settings outbox writes.
    /// Always enforces invariants before serializing field values.
    func apiPayload(guardianModeEnabled: Bool = true) -> [String: Any] {
        let normalized = normalizedForInvariants(guardianModeEnabled: guardianModeEnabled)
        return [
            "id": normalized.id.uuidString,
            "user_id": normalized.userId.uuidString,
            "morning_brief_enabled": normalized.morningBriefEnabled,
            "positive_enabled": normalized.positiveEnabled,
            "nudges_enabled": normalized.nudgesEnabled,
            "celebration_enabled": normalized.celebrationEnabled,
            "critical_only": normalized.criticalOnly,
            "morning_brief_time_local": normalized.morningBriefTimeLocal,
            "quiet_hours_start": normalized.quietHoursStart,
            "quiet_hours_end": normalized.quietHoursEnd,
            "max_positive_per_day": normalized.maxPositivePerDay,
            "max_nudges_per_day": normalized.maxNudgesPerDay,
            "max_celebration_per_day": normalized.maxCelebrationPerDay,
            "max_total_per_day": normalized.maxTotalPerDay,
            "control_level": normalized.controlLevel.rawValue,
            "focus_control_enabled": normalized.focusControlEnabled
        ]
    }
}

/// Control model levels.
/// advisory = suggestions only (default)
/// protective = active nudges + friction on risky behaviors (user opt-in)
/// guardian = can restrict access via Focus Control (requires FamilyControls)
enum ControlLevel: String, Codable, Sendable {
    case advisory
    case protective
    case guardian
}
