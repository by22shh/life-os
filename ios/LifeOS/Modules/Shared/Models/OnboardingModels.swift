// MARK: - Onboarding & Settings Models
// Source of truth: life_os_api_specification.md §onboarding_state, §user_baselines, §privacy_settings

import Foundation
import GRDB

// MARK: - Onboarding Step

/// Shipped onboarding flow:
/// Value proposition → quick win → HealthKit → basic profile (+ optional supplements/labs entry points)
/// → first insight → notifications.
///
/// The enum also retains legacy persisted states so older local/cloud rows can still be decoded and
/// normalized into the current 6-step flow without dropping users back to the start unexpectedly.
enum OnboardingStep: String, Codable, Sendable, CaseIterable {
    case notStarted = "not_started"

    // Current 6-step UI flow
    case valueProp = "value_prop"
    case quickWin = "quick_win"
    case healthKitPermission = "healthkit_permission"
    case basicProfile = "basic_profile"
    case firstInsight = "first_insight"
    case notifications = "notifications"
    case onboardingComplete = "onboarding_complete"

    // Persisted milestones for the shipped flow
    case valuePropComplete = "value_prop_complete"
    case quickWinComplete = "quick_win_complete"
    case firstInsightDelivered = "first_insight_delivered"
    case notificationsPrompted = "notifications_prompted"

    // Legacy persisted states kept for backward compatibility
    case authComplete = "auth_complete"
    case profileComplete = "profile_complete"
    case healthkitPrompted = "healthkit_prompted"
    case healthkitGranted = "healthkit_granted"
    case healthkitSkipped = "healthkit_skipped"
    case backfillInProgress = "backfill_in_progress"
    case backfillComplete = "backfill_complete"
    case tutorialShown = "tutorial_shown"

    static let allCases: [OnboardingStep] = [
        .notStarted,
        .valueProp,
        .quickWin,
        .healthKitPermission,
        .basicProfile,
        .firstInsight,
        .notifications,
        .onboardingComplete,
        .valuePropComplete,
        .quickWinComplete,
        .firstInsightDelivered,
        .notificationsPrompted,
        .authComplete,
        .profileComplete,
        .healthkitPrompted,
        .healthkitGranted,
        .healthkitSkipped,
        .backfillInProgress,
        .backfillComplete,
        .tutorialShown
    ]

    static let flowSteps: [OnboardingStep] = [
        .valueProp,
        .quickWin,
        .healthKitPermission,
        .basicProfile,
        .firstInsight,
        .notifications
    ]

    var displayStep: OnboardingStep {
        switch self {
        case .notStarted, .authComplete, .valueProp:
            return .valueProp
        case .valuePropComplete, .quickWin:
            return .quickWin
        case .quickWinComplete, .healthKitPermission:
            return .healthKitPermission
        case .basicProfile,
             .profileComplete,
             .healthkitPrompted,
             .healthkitGranted,
             .healthkitSkipped,
             .backfillInProgress,
             .backfillComplete:
            return .basicProfile
        case .firstInsight, .firstInsightDelivered:
            return .firstInsight
        case .notifications, .notificationsPrompted, .tutorialShown, .onboardingComplete:
            return .notifications
        }
    }

    var flowIndex: Int? {
        Self.flowSteps.firstIndex(of: displayStep)
    }

    var hasPassedValueProp: Bool {
        progressionRank >= 1
    }

    var hasPassedQuickWin: Bool {
        progressionRank >= 2
    }

    var hasHandledHealthKit: Bool {
        progressionRank >= 3
    }

    var hasDeliveredFirstInsight: Bool {
        progressionRank >= 5
    }

    var progressionRank: Int {
        switch self {
        case .notStarted, .valueProp, .authComplete:
            return 0
        case .valuePropComplete, .quickWin:
            return 1
        case .quickWinComplete, .healthKitPermission:
            return 2
        case .healthkitGranted, .healthkitSkipped, .backfillInProgress, .backfillComplete, .basicProfile:
            return 3
        case .profileComplete, .healthkitPrompted:
            return 4
        case .firstInsightDelivered, .firstInsight:
            return 5
        case .notificationsPrompted, .notifications, .tutorialShown:
            return 6
        case .onboardingComplete:
            return 7
        }
    }
}

// MARK: - Onboarding State

struct OnboardingState: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var userId: UUID
    var step: OnboardingStep
    var completedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        userId: UUID,
        step: OnboardingStep = .notStarted
    ) {
        self.id = id
        self.userId = userId
        self.step = step
        self.completedAt = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case step
        case completedAt = "completed_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Whether onboarding is fully complete.
    var isComplete: Bool {
        step == .onboardingComplete
    }

    /// Whether we've passed the HealthKit prompt step.
    var hasPassedHealthKit: Bool {
        let passedSteps: Set<OnboardingStep> = [
            .healthkitGranted,
            .healthkitSkipped,
            .backfillInProgress,
            .backfillComplete,
            .basicProfile,
            .profileComplete,
            .firstInsight,
            .firstInsightDelivered,
            .notifications,
            .notificationsPrompted,
            .tutorialShown,
            .onboardingComplete
        ]
        return passedSteps.contains(step)
    }
}

// MARK: - User Baseline

/// Computed HRV/RHR/Sleep baselines per life_os_recovery_algorithms.md §3.
struct UserBaseline: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var userId: UUID
    var hrvLnRmssdBaseline: Double?
    var rhrBaseline: Double?
    var sleepBaselineHours: Double?
    var dataDaysAvailable: Int
    var baselineConfidence: Double
    var lastComputedAt: Date
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        userId: UUID,
        dataDaysAvailable: Int = 0,
        baselineConfidence: Double = 0
    ) {
        self.id = id
        self.userId = userId
        self.dataDaysAvailable = dataDaysAvailable
        self.baselineConfidence = baselineConfidence
        self.lastComputedAt = Date()
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case hrvLnRmssdBaseline = "hrv_ln_rmssd_baseline"
        case rhrBaseline = "rhr_baseline"
        case sleepBaselineHours = "sleep_baseline_hours"
        case dataDaysAvailable = "data_days_available"
        case baselineConfidence = "baseline_confidence"
        case lastComputedAt = "last_computed_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Whether baselines have sufficient data for scoring.
    /// Requires ≥5 days per recovery algorithm baseline validity rule.
    var hasSufficientData: Bool {
        dataDaysAvailable >= 5 && baselineConfidence >= 0.5
    }
}

// MARK: - Privacy Settings

/// User privacy preferences per life_os_privacy_architecture.md.
struct PrivacySettings: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var userId: UUID
    var menstrualLocalOnly: Bool
    var medicalScanLocalOnly: Bool
    var cloudBackupEnabled: Bool
    var vectorOptIn: Bool
    var analyticsConsent: Bool
    var cloudOcrEnabled: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        userId: UUID
    ) {
        self.id = id
        self.userId = userId
        // Privacy-first defaults
        self.menstrualLocalOnly = true
        self.medicalScanLocalOnly = true
        self.cloudBackupEnabled = false
        self.vectorOptIn = false
        self.analyticsConsent = false
        self.cloudOcrEnabled = true
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case menstrualLocalOnly = "menstrual_local_only"
        case medicalScanLocalOnly = "medical_scan_local_only"
        case cloudBackupEnabled = "cloud_backup_enabled"
        case vectorOptIn = "vector_opt_in"
        case analyticsConsent = "analytics_consent"
        case cloudOcrEnabled = "cloud_ocr_enabled"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
