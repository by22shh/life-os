import Foundation
import ComposableArchitecture
import GRDB
import OSLog

@Reducer
struct OnboardingFeature {
#if DEBUG
    private static let testDatabaseQueueOverride = LockedTestOverride<DatabaseQueue>()
#endif
    private static let logger = Logger(subsystem: "com.lifeos.app", category: "Onboarding")

    @ObservableState
    struct State: Equatable {
        static let minimumSupportedAge = 13
        static let maximumSupportedAge = 100
        static let minimumHeightCm = 100.0
        static let maximumHeightCm = 250.0
        static let defaultDateOfBirth: Date = {
            Calendar(identifier: .gregorian).date(byAdding: .year, value: -30, to: Date()) ?? Date()
        }()

        var currentStep: OnboardingStep = .notStarted

        // Profile
        var hasLoadedProfile = false
        var dateOfBirth: Date = State.defaultDateOfBirth
        var hasConfirmedDateOfBirth = false
        var sex: BiologicalSex?
        var heightCm: Double = 170
        var heightInputText = "170"
        var primaryGoal: PrimaryGoal?
        var activityLevel: ActivityLevel?

        // Health flags
        var hasCardiacCondition = false
        var hasPacemaker = false
        var onBetaBlockers = false
        var isPregnant = false
        var menstrualTrackingEnabled = false
        var hasEatingDisorderHistory = false
        var hasChronicFatigue = false

        // Weight input
        var weightKg: Double = 70
        var weightInputText: String = "70"

        // Step persistence
        var isSavingProfile = false
        var isSavingHealthFlags = false
        var isSavingWeight = false
        var isCompletingQuickWin = false
        var quickWinCompleted = false
        var quickWinResult: QuickWinResult?
        var isLoadingFirstInsight = false
        var firstInsight: FirstInsightCard?
        var optionalSetupSummary = OptionalSetupSummary()
        var errorMessage: String?

        // HealthKit
        var isRequestingHealthKit = false
        var healthKitGranted = false

        // Backfill
        var isBackfilling = false
        var isCompleting = false

        var parsedHeightCm: Double? {
            OnboardingFeature.parseMetricValue(
                heightInputText,
                allowedRange: State.minimumHeightCm...State.maximumHeightCm
            )
        }

        var profileAge: Int? {
            guard hasConfirmedDateOfBirth else { return nil }
            return OnboardingFeature.supportedAge(from: dateOfBirth)
        }

        var parsedWeightKg: Double? {
            OnboardingFeature.parseMetricValue(weightInputText, allowedRange: 20...300)
        }

        var canAdvanceFromProfile: Bool {
            hasConfirmedDateOfBirth &&
            profileAge != nil &&
            sex != nil &&
            parsedHeightCm != nil &&
            primaryGoal != nil &&
            activityLevel != nil &&
            parsedWeightKg != nil
        }

        var canAdvanceFromWeight: Bool {
            parsedWeightKg != nil
        }

        var currentDisplayStep: OnboardingStep {
            currentStep.displayStep
        }

        var progress: Double {
            if currentStep == .onboardingComplete {
                return 1
            }
            guard let index = currentDisplayStep.flowIndex else { return 0 }
            return Double(index + 1) / Double(max(OnboardingStep.flowSteps.count, 1))
        }
    }

    struct ProfileSnapshot: Equatable {
        var persistedStep: OnboardingStep? = nil
        var onboardingCompleted = false
        var dateOfBirth: Date?
        var sex: BiologicalSex?
        var heightCm: Double?
        var primaryGoal: PrimaryGoal?
        var activityLevel: ActivityLevel?
        var weightKg: Double?
        var hasCardiacCondition = false
        var hasPacemaker = false
        var onBetaBlockers = false
        var isPregnant = false
        var menstrualTrackingEnabled = false
        var hasEatingDisorderHistory = false
        var hasChronicFatigue = false
    }

    struct OptionalSetupSummary: Equatable {
        var supplementCount = 0
        var labScanCount = 0
        var labReviewCount = 0
    }

    struct QuickWinResult: Equatable, Sendable {
        var title: String
        var calories: Double
        var proteinG: Double
        var fatG: Double
        var carbsG: Double
        var fiberG: Double?
        var note: String?
        var needsReview: Bool

        var hasMacroSummary: Bool {
            calories > 0 || proteinG > 0 || fatG > 0 || carbsG > 0 || (fiberG ?? 0) > 0
        }
    }

    struct FirstInsightCard: Equatable, Sendable {
        var insightId: UUID
        var title: String
        var body: String
        var score: Int
        var zone: RecoveryZone
        var detail: String
        var footer: String
        var isPreview: Bool
    }

    enum StepTransitionResult: Equatable {
        case succeeded
        case failed(String)
    }

    enum Action: Equatable {
        case loadProfileIfNeeded
        case loadOptionalSetupSummary
        case profileLoaded(ProfileSnapshot?)
        case optionalSetupSummaryLoaded(OptionalSetupSummary)
        case loadQuickWinResult
        case quickWinResultLoaded(QuickWinResult?)
        case advanceFromValueProp
        case progressAdvanceFinished(step: OnboardingStep, result: StepTransitionResult)
        case completeQuickWin
        case quickWinCompletionSucceeded(QuickWinResult?)
        case quickWinCompletionFailed(String)
        case advanceFromQuickWin
        case profileAdvanceFinished(StepTransitionResult)
        case dateOfBirthChanged(Date)
        case confirmDateOfBirth
        case setSex(BiologicalSex)
        case heightChanged(String)
        case setPrimaryGoal(PrimaryGoal)
        case setActivityLevel(ActivityLevel)
        case advanceFromProfile
        case advanceFromHealthFlags
        case healthFlagsAdvanceFinished(StepTransitionResult)
        case setHasCardiacCondition(Bool)
        case setHasPacemaker(Bool)
        case setOnBetaBlockers(Bool)
        case setIsPregnant(Bool)
        case setMenstrualTrackingEnabled(Bool)
        case setHasEatingDisorderHistory(Bool)
        case setHasChronicFatigue(Bool)
        case weightChanged(String)
        case advanceFromWeight
        case weightAdvanceFinished(StepTransitionResult)
        case requestHealthKit
        case healthKitResult(Bool)
        case healthKitAdvanceFinished(granted: Bool, result: StepTransitionResult)
        case skipHealthKit
        case startBackfill
        case backfillFinished(StepTransitionResult)
        case prepareFirstInsight
        case firstInsightLoaded(FirstInsightCard)
        case firstInsightFailed(String)
        case advanceFromFirstInsight
        case enableNotifications
        case complete
        case completeFinished(StepTransitionResult)
    }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {

            case .loadProfileIfNeeded:
                let summaryEffect: Effect<Action> = .send(.loadOptionalSetupSummary)
                guard !state.hasLoadedProfile else { return summaryEffect }
                state.hasLoadedProfile = true
                return .merge(
                    .run { send in
                        let snapshot = try? await Self.loadProfileSnapshot()
                        await send(.profileLoaded(snapshot))
                    },
                    summaryEffect
                )

            case .loadOptionalSetupSummary:
                return .run { send in
                    let summary = (try? await Self.loadOptionalSetupSummary()) ?? OptionalSetupSummary()
                    await send(.optionalSetupSummaryLoaded(summary))
                }

            case let .profileLoaded(snapshot):
                guard let snapshot else {
                    state.currentStep = .valueProp
                    return .none
                }
                if let dateOfBirth = snapshot.dateOfBirth {
                    state.dateOfBirth = Self.clampedDateOfBirth(dateOfBirth)
                    state.hasConfirmedDateOfBirth = true
                }
                state.sex = snapshot.sex
                if let heightCm = snapshot.heightCm {
                    state.heightCm = heightCm
                    state.heightInputText = Self.formattedMetricValue(heightCm)
                }
                state.primaryGoal = snapshot.primaryGoal
                state.activityLevel = snapshot.activityLevel
                if let weightKg = snapshot.weightKg {
                    state.weightKg = weightKg
                    state.weightInputText = Self.formattedMetricValue(weightKg)
                }
                state.hasCardiacCondition = snapshot.hasCardiacCondition
                state.hasPacemaker = snapshot.hasPacemaker
                state.onBetaBlockers = snapshot.onBetaBlockers
                state.isPregnant = snapshot.isPregnant
                state.menstrualTrackingEnabled = snapshot.menstrualTrackingEnabled
                state.hasEatingDisorderHistory = snapshot.hasEatingDisorderHistory
                state.hasChronicFatigue = snapshot.hasChronicFatigue
                state.healthKitGranted = Self.didGrantHealthKit(snapshot.persistedStep)
                state.quickWinCompleted = snapshot.persistedStep?.hasPassedQuickWin ?? false
                if !state.quickWinCompleted {
                    state.quickWinResult = nil
                }
                state.currentStep = Self.resolveCurrentStep(from: snapshot)
                var followUpEffects: [Effect<Action>] = []
                if state.quickWinCompleted {
                    followUpEffects.append(.send(.loadQuickWinResult))
                }
                if state.currentStep == .firstInsight || state.currentStep == .notifications {
                    followUpEffects.append(.send(.prepareFirstInsight))
                }
                return followUpEffects.isEmpty ? .none : .merge(followUpEffects)

            case let .optionalSetupSummaryLoaded(summary):
                state.optionalSetupSummary = summary
                return .none

            case .loadQuickWinResult:
                guard state.quickWinCompleted, state.quickWinResult == nil else { return .none }
                return .run { send in
                    let result = try? await Self.loadLatestQuickWinResult()
                    await send(.quickWinResultLoaded(result))
                }

            case let .quickWinResultLoaded(result):
                state.quickWinResult = result
                return .none

            case .advanceFromValueProp:
                state.errorMessage = nil
                return Self.runMilestoneTransition(
                    milestone: .valuePropComplete,
                    nextStep: .quickWin
                )

            case let .progressAdvanceFinished(step, result):
                switch result {
                case .succeeded:
                    state.errorMessage = nil
                    state.currentStep = step
                    if step == .notifications {
                        return .send(.prepareFirstInsight)
                    }
                case let .failed(message):
                    state.errorMessage = message
                }
                return .none

            case .completeQuickWin:
                guard !state.isCompletingQuickWin else { return .none }
                state.isCompletingQuickWin = true
                state.errorMessage = nil
                return .run { send in
                    do {
                        let authId = try await Self.requiredActiveAuthId()
                        let result = try await Self.loadLatestQuickWinResult()
                        try await Self.persistOnboardingMilestone(
                            authId: authId,
                            step: .quickWinComplete,
                            completedAt: Date()
                        )
                        await send(.quickWinCompletionSucceeded(result))
                    } catch {
                        await send(.quickWinCompletionFailed(Self.userFacingFailureMessage(for: .progress, error: error)))
                    }
                }

            case let .quickWinCompletionSucceeded(result):
                state.isCompletingQuickWin = false
                state.quickWinCompleted = true
                state.quickWinResult = result
                if result == nil {
                    return .send(.loadQuickWinResult)
                }
                return .none

            case let .quickWinCompletionFailed(message):
                state.isCompletingQuickWin = false
                state.errorMessage = message
                return .none

            case .advanceFromQuickWin:
                guard state.quickWinCompleted else { return .none }
                state.errorMessage = nil
                state.currentStep = .healthKitPermission
                return .none

            case let .profileAdvanceFinished(result):
                state.isSavingProfile = false
                state.isSavingHealthFlags = false
                state.isSavingWeight = false
                switch result {
                case .succeeded:
                    state.errorMessage = nil
                    state.currentStep = .firstInsight
                    return .send(.prepareFirstInsight)
                case let .failed(message):
                    state.errorMessage = message
                }
                return .none

            case let .dateOfBirthChanged(date):
                state.dateOfBirth = Self.clampedDateOfBirth(date)
                state.hasConfirmedDateOfBirth = true
                state.errorMessage = nil
                return .none

            case .confirmDateOfBirth:
                state.dateOfBirth = Self.clampedDateOfBirth(state.dateOfBirth)
                state.hasConfirmedDateOfBirth = true
                state.errorMessage = nil
                return .none

            case let .setSex(value):
                state.sex = value
                state.errorMessage = nil
                return .none

            case let .heightChanged(text):
                state.heightInputText = text
                if let value = Self.parseMetricValue(
                    text,
                    allowedRange: State.minimumHeightCm...State.maximumHeightCm
                ) {
                    state.heightCm = value
                }
                state.errorMessage = nil
                return .none

            case let .setPrimaryGoal(value):
                state.primaryGoal = value
                state.errorMessage = nil
                return .none

            case let .setActivityLevel(value):
                state.activityLevel = value
                state.errorMessage = nil
                return .none

            case .advanceFromProfile:
                guard !state.isSavingProfile,
                      state.canAdvanceFromProfile,
                      let age = state.profileAge,
                      let sex = state.sex,
                      let heightCm = state.parsedHeightCm,
                      let weightKg = state.parsedWeightKg,
                      let primaryGoal = state.primaryGoal,
                      let activityLevel = state.activityLevel else {
                    return .none
                }
                state.isSavingProfile = true
                state.isSavingHealthFlags = true
                state.isSavingWeight = true
                state.errorMessage = nil
                let dateOfBirth = Self.clampedDateOfBirth(state.dateOfBirth)
                let ageRange = AgeRange(age: age)
                let hasCardiacCondition = state.hasCardiacCondition
                let hasPacemaker = state.hasPacemaker
                let onBetaBlockers = state.onBetaBlockers
                let isPregnant = state.isPregnant
                let menstrualTrackingEnabled = state.menstrualTrackingEnabled
                let hasEatingDisorderHistory = state.hasEatingDisorderHistory
                let hasChronicFatigue = state.hasChronicFatigue
                return Self.runTransition(
                    context: .profile,
                    operation: {
                        let authId = try await Self.requiredActiveAuthId()
                        try await Self.persistUserProfile(
                            authId: authId,
                            dateOfBirth: dateOfBirth,
                            ageRange: ageRange,
                            sex: sex,
                            heightCm: heightCm,
                            primaryGoal: primaryGoal,
                            activityLevel: activityLevel
                        )
                        try await Self.persistUserWeight(authId: authId, weight: weightKg)
                        try await Self.persistUserHealthFlags(
                            authId: authId,
                            hasCardiacCondition: hasCardiacCondition,
                            hasPacemaker: hasPacemaker,
                            onBetaBlockers: onBetaBlockers,
                            isPregnant: isPregnant,
                            menstrualTrackingEnabled: menstrualTrackingEnabled,
                            hasEatingDisorderHistory: hasEatingDisorderHistory,
                            hasChronicFatigue: hasChronicFatigue
                        )
                    },
                    responseAction: Action.profileAdvanceFinished
                )

            case .advanceFromHealthFlags:
                return .none

            case let .healthFlagsAdvanceFinished(result):
                state.isSavingHealthFlags = false
                switch result {
                case .succeeded:
                    state.errorMessage = nil
                case let .failed(message):
                    state.errorMessage = message
                }
                return .none

            case .setHasCardiacCondition(let value):
                state.hasCardiacCondition = value
                state.errorMessage = nil
                return .none

            case .setHasPacemaker(let value):
                state.hasPacemaker = value
                state.errorMessage = nil
                return .none

            case .setOnBetaBlockers(let value):
                state.onBetaBlockers = value
                state.errorMessage = nil
                return .none

            case .setIsPregnant(let value):
                state.isPregnant = value
                state.errorMessage = nil
                return .none

            case .setMenstrualTrackingEnabled(let value):
                state.menstrualTrackingEnabled = value
                state.errorMessage = nil
                return .none

            case .setHasEatingDisorderHistory(let value):
                state.hasEatingDisorderHistory = value
                state.errorMessage = nil
                return .none

            case .setHasChronicFatigue(let value):
                state.hasChronicFatigue = value
                state.errorMessage = nil
                return .none

            case let .weightChanged(text):
                state.weightInputText = text
                if let value = Self.parseMetricValue(text, allowedRange: 20...300) {
                    state.weightKg = value
                }
                state.errorMessage = nil
                return .none

            case .advanceFromWeight:
                return .none

            case let .weightAdvanceFinished(result):
                state.isSavingWeight = false
                switch result {
                case .succeeded:
                    state.errorMessage = nil
                case let .failed(message):
                    state.errorMessage = message
                }
                return .none

            case .requestHealthKit:
                guard !state.isRequestingHealthKit, !state.isBackfilling else { return .none }
                state.isRequestingHealthKit = true
                state.errorMessage = nil
                return .run { send in
                    let granted: Bool
                    do {
                        granted = try await HealthKitManager.shared.requestAuthorization()
                    } catch {
                        granted = false
                    }
                    await send(.healthKitResult(granted))
                }

            case let .healthKitResult(granted):
                state.isRequestingHealthKit = false
                state.healthKitGranted = granted
                guard granted else {
                    state.errorMessage =
                        AppCapabilityAvailability.healthKitCapabilityWarning
                        ?? String(localized: "onboarding_healthkit_denied_notice")
                    return .none
                }
                state.errorMessage = nil
                state.isBackfilling = true
                return Self.runTransition(
                    context: .healthKit,
                    operation: {
                        let userId = try await Self.requiredUserId()
                        do {
                            try await HealthSyncManager.shared.backfillRecentData(days: 14, userId: userId)
                        } catch {
                            Self.logger.error(
                                "Onboarding backfill failed but will not block the flow: \(error.localizedDescription, privacy: .public)"
                            )
                        }
                        let authId = try await Self.requiredActiveAuthId()
                        try await Self.persistOnboardingMilestone(
                            authId: authId,
                            step: .healthkitGranted,
                            completedAt: Date()
                        )
                    },
                    responseAction: { .healthKitAdvanceFinished(granted: true, result: $0) }
                )

            case let .healthKitAdvanceFinished(granted, result):
                state.isBackfilling = false
                switch result {
                case .succeeded:
                    state.errorMessage = nil
                    state.healthKitGranted = granted
                    state.currentStep = .basicProfile
                case let .failed(message):
                    state.errorMessage = message
                }
                return .none

            case .skipHealthKit:
                state.errorMessage = nil
                state.healthKitGranted = false
                return Self.runTransition(
                    context: .healthKit,
                    operation: {
                        let authId = try await Self.requiredActiveAuthId()
                        try await Self.persistOnboardingMilestone(
                            authId: authId,
                            step: .healthkitSkipped,
                            completedAt: Date()
                        )
                    },
                    responseAction: { .healthKitAdvanceFinished(granted: false, result: $0) }
                )

            case .startBackfill:
                return .none

            case let .backfillFinished(result):
                state.isBackfilling = false
                switch result {
                case .succeeded:
                    state.errorMessage = nil
                case let .failed(message):
                    state.errorMessage = message
                }
                return .none

            case .prepareFirstInsight:
                guard !state.isLoadingFirstInsight, state.firstInsight == nil else { return .none }
                state.isLoadingFirstInsight = true
                state.errorMessage = nil
                return .run { send in
                    do {
                        let card = try await Self.loadOrCreateFirstInsight()
                        await send(.firstInsightLoaded(card))
                    } catch {
                        await send(.firstInsightFailed(Self.userFacingFailureMessage(for: .firstInsight, error: error)))
                    }
                }

            case let .firstInsightLoaded(card):
                state.isLoadingFirstInsight = false
                state.errorMessage = nil
                state.firstInsight = card
                return .none

            case let .firstInsightFailed(message):
                state.isLoadingFirstInsight = false
                state.errorMessage = message
                return .none

            case .advanceFromFirstInsight:
                guard state.firstInsight != nil else { return .none }
                state.errorMessage = nil
                return Self.runMilestoneTransition(
                    milestone: .firstInsightDelivered,
                    nextStep: .notifications
                )

            case .enableNotifications:
                guard !state.isCompleting else { return .none }
                state.isCompleting = true
                state.errorMessage = nil
                return Self.runTransition(
                    context: .complete,
                    operation: {
                        let authId = try await Self.requiredActiveAuthId()
                        try await Self.persistOnboardingMilestone(
                            authId: authId,
                            step: .notificationsPrompted,
                            completedAt: Date()
                        )
#if os(iOS)
                        await PushNotificationManager.shared.evaluateDelayedAuthorizationPromptIfEligible()
#endif
                        try await Self.completeOnboarding(authId: authId)
                    },
                    responseAction: Action.completeFinished
                )

            case .complete:
                guard !state.isCompleting else { return .none }
                state.isCompleting = true
                state.errorMessage = nil
                return Self.runTransition(
                    context: .complete,
                    operation: {
                        let authId = try await Self.requiredActiveAuthId()
                        try await Self.completeOnboarding(authId: authId)
                    },
                    responseAction: Action.completeFinished
                )

            case let .completeFinished(result):
                state.isCompleting = false
                switch result {
                case .succeeded:
                    state.errorMessage = nil
                    state.currentStep = .onboardingComplete
                case let .failed(message):
                    state.errorMessage = message
                }
                return .none
            }
        }
    }

    private static func latestUserId() async throws -> UUID? {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        guard let authId else { return nil }

        return try await resolvedDBQueue.read { db in
            try UserIdentityLookup.resolveUserId(authId: authId, db: db)
        }
    }

    private static func loadProfileSnapshot() async throws -> ProfileSnapshot? {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        guard let authId else { return nil }

        return try await resolvedDBQueue.read { db in
            guard let user = try UserIdentityLookup.fetchUser(authId: authId, db: db) else {
                return nil
            }
            let persistedStep = try OnboardingState.fetchOne(
                db,
                sql: """
                    SELECT *
                    FROM onboarding_state
                    WHERE user_id = ? OR user_id = ?
                    ORDER BY updated_at DESC
                    LIMIT 1
                    """,
                arguments: [user.id, user.id.uuidString]
            )?.step

            let healthFlagsRow = try UserHealthFlags.fetchOne(
                db,
                sql: """
                    SELECT *
                    FROM user_health_flags
                    WHERE user_id = ? OR user_id = ?
                    ORDER BY updated_at DESC
                    LIMIT 1
                    """,
                arguments: [user.id, user.id.uuidString]
            )

            return ProfileSnapshot(
                persistedStep: persistedStep,
                onboardingCompleted: user.onboardingCompleted,
                dateOfBirth: user.dateOfBirth,
                sex: user.sex,
                heightCm: user.heightCm,
                primaryGoal: user.primaryGoal,
                activityLevel: user.activityLevel,
                weightKg: user.weightKg,
                hasCardiacCondition: healthFlagsRow?.hasCardiacCondition ?? false,
                hasPacemaker: healthFlagsRow?.hasPacemaker ?? false,
                onBetaBlockers: healthFlagsRow?.onBetaBlockers ?? false,
                isPregnant: healthFlagsRow?.isPregnant ?? false,
                menstrualTrackingEnabled: healthFlagsRow?.menstrualTrackingEnabled ?? false,
                hasEatingDisorderHistory: healthFlagsRow?.hasEatingDisorderHistory ?? false,
                hasChronicFatigue: healthFlagsRow?.hasChronicFatigue ?? false
            )
        }
    }

    private static func loadOptionalSetupSummary() async throws -> OptionalSetupSummary {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        guard let authId else { return OptionalSetupSummary() }

        return try await resolvedDBQueue.read { db in
            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                return OptionalSetupSummary()
            }

            let supplementCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM user_supplements
                    WHERE user_id = ? OR user_id = ?
                    """,
                arguments: [userId, userId.uuidString]
            ) ?? 0

            let labScanCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM medical_scans
                    WHERE (user_id = ? OR user_id = ?)
                      AND deleted_at IS NULL
                    """,
                arguments: [userId, userId.uuidString]
            ) ?? 0

            let labReviewCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM medical_scans
                    WHERE (user_id = ? OR user_id = ?)
                      AND deleted_at IS NULL
                      AND needs_review = 1
                    """,
                arguments: [userId, userId.uuidString]
            ) ?? 0

            return OptionalSetupSummary(
                supplementCount: supplementCount,
                labScanCount: labScanCount,
                labReviewCount: labReviewCount
            )
        }
    }

    private static func loadLatestQuickWinResult() async throws -> QuickWinResult? {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        guard let authId else { return nil }

        return try await resolvedDBQueue.read { db in
            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                return nil
            }

            guard let log = try FoodLog.fetchOne(
                db,
                sql: """
                    SELECT *
                    FROM food_logs
                    WHERE (user_id = ? OR user_id = ?)
                      AND input_method = ?
                      AND deleted_at IS NULL
                    ORDER BY updated_at DESC
                    LIMIT 1
                    """,
                arguments: [userId, userId.uuidString, NutritionInputMethod.vision.rawValue]
            ) else {
                return nil
            }

            let firstItemName = try String.fetchOne(
                db,
                sql: """
                    SELECT name
                    FROM food_items
                    WHERE food_log_id = ? OR food_log_id = ?
                    ORDER BY created_at ASC
                    LIMIT 1
                    """,
                arguments: [log.id, log.id.uuidString]
            )

            let title = resolveQuickWinTitle(log: log, firstItemName: firstItemName)
            let note = resolveQuickWinNote(log: log, title: title)

            return QuickWinResult(
                title: title,
                calories: log.calories,
                proteinG: log.proteinG,
                fatG: log.fatG,
                carbsG: log.carbsG,
                fiberG: log.fiberG,
                note: note,
                needsReview: log.needsReview
            )
        }
    }

    private static func resolveQuickWinTitle(log: FoodLog, firstItemName: String?) -> String {
        if let mealType = log.mealType {
            return localizedNutritionMealType(mealType)
        }
        if let firstItemName = normalizedQuickWinText(firstItemName) {
            return firstItemName
        }
        return String(localized: "nutrition_meal")
    }

    private static func resolveQuickWinNote(log: FoodLog, title: String) -> String? {
        if log.needsReview {
            return String(localized: "nutrition_review_gate_message")
        }
        if let summary = normalizedQuickWinText(log.aiContextAnalysis),
           summary.caseInsensitiveCompare(title) != .orderedSame {
            return String(summary.prefix(140))
        }
        return String(localized: "onboarding_quick_win_result_note")
    }

    private static func normalizedQuickWinText(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func resolveCurrentStep(from snapshot: ProfileSnapshot) -> OnboardingStep {
        if snapshot.onboardingCompleted || snapshot.persistedStep == .onboardingComplete {
            return .onboardingComplete
        }

        let persistedStep = snapshot.persistedStep ?? .notStarted
        let hasBasicProfile = isBasicProfileComplete(snapshot)

        if persistedStep == .firstInsightDelivered || persistedStep == .notificationsPrompted {
            return .notifications
        }
        if hasBasicProfile && persistedStep.hasHandledHealthKit {
            return .firstInsight
        }
        if persistedStep.hasHandledHealthKit {
            return .basicProfile
        }
        if persistedStep.hasPassedQuickWin {
            return .healthKitPermission
        }
        if persistedStep.hasPassedValueProp {
            return .quickWin
        }
        return .valueProp
    }

    private static func isBasicProfileComplete(_ snapshot: ProfileSnapshot) -> Bool {
        snapshot.dateOfBirth != nil &&
        snapshot.sex != nil &&
        snapshot.heightCm != nil &&
        snapshot.primaryGoal != nil &&
        snapshot.activityLevel != nil &&
        snapshot.weightKg != nil
    }

    private static func didGrantHealthKit(_ step: OnboardingStep?) -> Bool {
        switch step {
        case .healthkitGranted?, .backfillInProgress?, .backfillComplete?:
            return true
        default:
            return false
        }
    }

    private static func runMilestoneTransition(
        milestone: OnboardingStep,
        nextStep: OnboardingStep
    ) -> Effect<Action> {
        runTransition(
            context: .progress,
            operation: {
                let authId = try await requiredActiveAuthId()
                try await persistOnboardingMilestone(authId: authId, step: milestone, completedAt: Date())
            },
            responseAction: { .progressAdvanceFinished(step: nextStep, result: $0) }
        )
    }

    private static func persistUserProfile(
        authId: String,
        dateOfBirth: Date,
        ageRange: AgeRange,
        sex: BiologicalSex,
        heightCm: Double,
        primaryGoal: PrimaryGoal,
        activityLevel: ActivityLevel
    ) async throws {
        let now = Date()
        let stableDateOfBirth = normalizedDateOnly(dateOfBirth)
        let roundedHeightCm = roundedMetricValue(heightCm)
        try await resolvedSyncEngine.performOptimisticMutation { db in
            let userId = try resolveRequiredUserId(authId: authId, db: db)
            let fields: [String: Any] = [
                "date_of_birth": localDateOnlyString(from: stableDateOfBirth),
                "age_range": ageRange.rawValue,
                "sex": sex.rawValue,
                "height_cm": roundedHeightCm,
                "primary_goal": primaryGoal.rawValue,
                "activity_level": activityLevel.rawValue,
                "updated_at": ISO8601DateFormatter.supabaseString(from: now)
            ]
            try db.execute(
                sql: """
                    UPDATE users
                    SET date_of_birth = ?,
                        age_range = ?,
                        sex = ?,
                        height_cm = ?,
                        primary_goal = ?,
                        activity_level = ?,
                        updated_at = ?
                    WHERE id = ? OR id = ?
                """,
                arguments: [
                    stableDateOfBirth,
                    ageRange.rawValue,
                    sex.rawValue,
                    roundedHeightCm,
                    primaryGoal.rawValue,
                    activityLevel.rawValue,
                    now,
                    userId,
                    MixedUUIDStorage.encode(userId)
                ]
            )
            guard let authUUID = UUID(uuidString: authId) else {
                throw OnboardingPersistenceError.activeUserUnavailable
            }
            let event = try makeUserUpsertEvent(userId: userId, authId: authUUID, fields: fields)
            return (value: (), event: event)
        }
    }

    private static func makeUserUpsertEvent(
        userId: UUID,
        authId: UUID,
        fields: [String: Any]
    ) throws -> OutboxEvent {
        var payload = fields
        payload["id"] = userId.uuidString
        payload["auth_id"] = authId.uuidString

        let body = try JSONSerialization.data(withJSONObject: payload)
        return OutboxEvent(
            httpMethod: .POST,
            path: "rest/v1/users",
            bodyJson: body,
            priority: 80
        )
    }

    private static func persistUserHealthFlags(
        authId: String,
        hasCardiacCondition: Bool,
        hasPacemaker: Bool,
        onBetaBlockers: Bool,
        isPregnant: Bool,
        menstrualTrackingEnabled: Bool,
        hasEatingDisorderHistory: Bool,
        hasChronicFatigue: Bool
    ) async throws {
        let now = Date()

        try await resolvedDBQueue.write { db in
            let userId = try resolveRequiredUserId(authId: authId, db: db)
            let existingRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, created_at
                    FROM user_health_flags
                    WHERE user_id = ? OR user_id = ?
                    ORDER BY updated_at DESC
                    """,
                arguments: [userId, userId.uuidString]
            )
            let recordId = existingRows.first.flatMap { MixedUUIDStorage.decode(from: $0, column: "id") } ?? UUID()
            let existingCreatedAt: Date? = existingRows.first?["created_at"]

            var flags = UserHealthFlags(id: recordId, userId: userId)
            flags.hasCardiacCondition = hasCardiacCondition
            flags.hasPacemaker = hasPacemaker
            flags.onBetaBlockers = onBetaBlockers
            flags.isPregnant = isPregnant
            flags.menstrualTrackingEnabled = menstrualTrackingEnabled
            flags.hasEatingDisorderHistory = hasEatingDisorderHistory
            flags.hasChronicFatigue = hasChronicFatigue
            flags.createdAt = existingCreatedAt ?? now
            flags.updatedAt = now
            flags.refreshDerivedFlags()

            let encodedRecordId = MixedUUIDStorage.encode(flags.id)
            let encodedUserId = MixedUUIDStorage.encode(flags.userId)

            if let primaryId = existingRows.first.flatMap({ MixedUUIDStorage.decode(from: $0, column: "id") }) {
                for duplicateId in existingRows.dropFirst().compactMap({ MixedUUIDStorage.decode(from: $0, column: "id") }) {
                    try db.execute(
                        sql: "DELETE FROM user_health_flags WHERE id = ? OR id = ?",
                        arguments: [duplicateId, MixedUUIDStorage.encode(duplicateId)]
                    )
                }

                try db.execute(
                    sql: """
                        UPDATE user_health_flags
                        SET user_id = ?,
                            has_cardiac_condition = ?,
                            has_pacemaker = ?,
                            on_beta_blockers = ?,
                            is_pregnant = ?,
                            menstrual_tracking_enabled = ?,
                            has_eating_disorder_history = ?,
                            has_chronic_fatigue = ?,
                            disable_hrv = ?,
                            hide_calories = ?,
                            pregnancy_mode = ?,
                            created_at = ?,
                            updated_at = ?
                        WHERE id = ? OR id = ?
                        """,
                    arguments: [
                        encodedUserId,
                        flags.hasCardiacCondition,
                        flags.hasPacemaker,
                        flags.onBetaBlockers,
                        flags.isPregnant,
                        flags.menstrualTrackingEnabled,
                        flags.hasEatingDisorderHistory,
                        flags.hasChronicFatigue,
                        flags.disableHrv,
                        flags.hideCalories,
                        flags.pregnancyMode,
                        flags.createdAt,
                        flags.updatedAt,
                        primaryId,
                        MixedUUIDStorage.encode(primaryId)
                    ]
                )
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO user_health_flags (
                            id, user_id, has_cardiac_condition, has_pacemaker, on_beta_blockers,
                            is_pregnant, menstrual_tracking_enabled, has_eating_disorder_history,
                            has_chronic_fatigue, disable_hrv, hide_calories, pregnancy_mode,
                            created_at, updated_at
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        encodedRecordId,
                        encodedUserId,
                        flags.hasCardiacCondition,
                        flags.hasPacemaker,
                        flags.onBetaBlockers,
                        flags.isPregnant,
                        flags.menstrualTrackingEnabled,
                        flags.hasEatingDisorderHistory,
                        flags.hasChronicFatigue,
                        flags.disableHrv,
                        flags.hideCalories,
                        flags.pregnancyMode,
                        flags.createdAt,
                        flags.updatedAt
                    ]
                )
            }

            let cloudBackupEnabled = try Bool.fetchOne(
                db,
                sql: """
                    SELECT cloud_backup_enabled
                    FROM privacy_settings
                    WHERE user_id = ? OR user_id = ?
                    ORDER BY updated_at DESC
                    LIMIT 1
                    """,
                arguments: [userId, userId.uuidString]
            ) ?? false
            guard cloudBackupEnabled else { return }

            let payload: [String: Any] = [
                "id": flags.id.uuidString,
                "user_id": flags.userId.uuidString,
                "has_cardiac_condition": flags.hasCardiacCondition,
                "has_pacemaker": flags.hasPacemaker,
                "on_beta_blockers": flags.onBetaBlockers,
                "is_pregnant": flags.isPregnant,
                "menstrual_tracking_enabled": flags.menstrualTrackingEnabled,
                "has_eating_disorder_history": flags.hasEatingDisorderHistory,
                "has_chronic_fatigue": flags.hasChronicFatigue,
                "disable_hrv": flags.disableHrv,
                "hide_calories": flags.hideCalories,
                "pregnancy_mode": flags.pregnancyMode,
                "created_at": ISO8601DateFormatter.supabaseString(from: flags.createdAt),
                "updated_at": ISO8601DateFormatter.supabaseString(from: flags.updatedAt)
            ]
            let body = try JSONSerialization.data(withJSONObject: payload)
            var event = OutboxEvent(
                httpMethod: .POST,
                path: "rest/v1/user_health_flags",
                bodyJson: body,
                priority: 80
            )
            event.idempotencyKey = "user-health-flags-\(flags.id.uuidString.lowercased())-\(Int(now.timeIntervalSince1970))"
            try event.insert(db)
        }
    }

    private static func persistUserWeight(
        authId: String,
        weight: Double
    ) async throws {
        let roundedWeight = roundedMetricValue(weight)
        let now = Date()
        try await resolvedSyncEngine.performOptimisticMutation { db in
            let userId = try resolveRequiredUserId(authId: authId, db: db)
            let fields: [String: Any] = [
                "weight_kg": roundedWeight,
                "updated_at": ISO8601DateFormatter.supabaseString(from: now)
            ]
            try db.execute(
                sql: """
                    UPDATE users
                    SET weight_kg = ?, updated_at = ?
                    WHERE id = ? OR id = ?
                    """,
                arguments: [roundedWeight, now, userId, MixedUUIDStorage.encode(userId)]
            )
            guard let authUUID = UUID(uuidString: authId) else {
                throw OnboardingPersistenceError.activeUserUnavailable
            }
            let event = try makeUserUpsertEvent(userId: userId, authId: authUUID, fields: fields)
            return (value: (), event: event)
        }
    }

    private static func persistOnboardingMilestone(
        authId: String,
        step: OnboardingStep,
        completedAt: Date? = nil
    ) async throws {
        try await resolvedDBQueue.write { db in
            let userId = try resolveRequiredUserId(authId: authId, db: db)
            let record = try upsertOnboardingMilestone(
                db: db,
                userId: userId,
                step: step,
                completedAt: completedAt
            )
            let event = try makeOnboardingStateUpsertEvent(record: record)
            try event.insert(db)
        }
    }

    private static func completeOnboarding(authId: String) async throws {
        let now = Date()
        try await resolvedDBQueue.write { db in
            let userId = try resolveRequiredUserId(authId: authId, db: db)
            let fields: [String: Any] = [
                "onboarding_completed": true,
                "updated_at": ISO8601DateFormatter.supabaseString(from: now)
            ]
            try db.execute(
                sql: """
                    UPDATE users
                    SET onboarding_completed = 1, updated_at = ?
                    WHERE id = ? OR id = ?
                    """,
                arguments: [now, userId, MixedUUIDStorage.encode(userId)]
            )

            guard let authUUID = UUID(uuidString: authId) else {
                throw OnboardingPersistenceError.activeUserUnavailable
            }
            let userEvent = try makeUserUpsertEvent(userId: userId, authId: authUUID, fields: fields)
            try userEvent.insert(db)

            let onboardingRecord = try upsertOnboardingMilestone(
                db: db,
                userId: userId,
                step: .onboardingComplete,
                completedAt: now
            )
            let onboardingEvent = try makeOnboardingStateUpsertEvent(record: onboardingRecord)
            try onboardingEvent.insert(db)
        }
    }

    private static func upsertOnboardingMilestone(
        db: Database,
        userId: UUID,
        step: OnboardingStep,
        completedAt: Date?
    ) throws -> OnboardingState {
        let now = Date()
        let existing = try OnboardingState.fetchOne(
            db,
            sql: """
                SELECT *
                FROM onboarding_state
                WHERE user_id = ? OR user_id = ?
                ORDER BY updated_at DESC
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString]
        )

        let effectiveStep: OnboardingStep
        if let existing, existing.step.progressionRank > step.progressionRank {
            effectiveStep = existing.step
        } else {
            effectiveStep = step
        }

        var record = existing ?? OnboardingState(userId: userId)
        record.userId = userId
        record.step = effectiveStep
        record.updatedAt = now
        if existing == nil {
            record.createdAt = now
        }
        if let completedAt {
            record.completedAt = completedAt
        }

        if existing != nil {
            try db.execute(
                sql: """
                    UPDATE onboarding_state
                    SET user_id = ?, step = ?, completed_at = ?, updated_at = ?
                    WHERE id = ? OR id = ?
                    """,
                arguments: [
                    record.userId.uuidString,
                    record.step.rawValue,
                    record.completedAt,
                    record.updatedAt,
                    record.id.uuidString,
                    MixedUUIDStorage.encode(record.id)
                ]
            )
        } else {
            try db.execute(
                sql: """
                    INSERT INTO onboarding_state (
                        id, user_id, step, completed_at, created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    record.id.uuidString,
                    record.userId.uuidString,
                    record.step.rawValue,
                    record.completedAt,
                    record.createdAt,
                    record.updatedAt
                ]
            )
        }

        return record
    }

    private static func makeOnboardingStateUpsertEvent(record: OnboardingState) throws -> OutboxEvent {
        var payload: [String: Any] = [
            "id": record.id.uuidString,
            "user_id": record.userId.uuidString,
            "step": record.step.rawValue,
            "created_at": ISO8601DateFormatter.supabaseString(from: record.createdAt),
            "updated_at": ISO8601DateFormatter.supabaseString(from: record.updatedAt)
        ]
        if let completedAt = record.completedAt {
            payload["completed_at"] = ISO8601DateFormatter.supabaseString(from: completedAt)
        }

        let body = try JSONSerialization.data(withJSONObject: payload)
        var event = OutboxEvent(
            httpMethod: .POST,
            path: "rest/v1/onboarding_state",
            bodyJson: body,
            priority: 70
        )
        event.idempotencyKey = "onboarding-state-\(record.userId.uuidString.lowercased())-\(record.step.rawValue)"
        return event
    }

    private struct RecoveryInsightSeed {
        var title: String
        var body: String
        var score: Int
        var zone: RecoveryZone
        var detail: String
        var footer: String
        var isPreview: Bool
    }

    private static func loadOrCreateFirstInsight() async throws -> FirstInsightCard {
        let authId = try await requiredActiveAuthId()

        return try await resolvedDBQueue.write { db in
            let userId = try resolveRequiredUserId(authId: authId, db: db)
            let existing = try Insight.fetchOne(
                db,
                sql: """
                    SELECT *
                    FROM insights
                    WHERE (user_id = ? OR user_id = ?)
                      AND type = ?
                    ORDER BY updated_at DESC
                    LIMIT 1
                    """,
                arguments: [userId, userId.uuidString, "onboarding_first_insight"]
            )

            let seed = try buildRecoveryInsightSeed(db: db, userId: userId)
            let now = Date()

            let insight: Insight
            if var existing {
                existing.category = .recovery
                existing.type = "onboarding_first_insight"
                existing.title = seed.title
                existing.description = seed.detail
                existing.body = withClinicianDisclaimerIfNeeded(seed.body, category: .recovery)
                existing.confidence = seed.isPreview ? 0.82 : 0.93
                existing.inputsUsed = seed.isPreview ? "profile" : "sleep,recovery"
                existing.priority = 1
                existing.actionable = true
                existing.actionType = "open_home"
                existing.shownToUser = true
                existing.shownAt = now
                existing.read = true
                existing.readAt = now
                existing.acknowledged = true
                existing.acknowledgedAt = now
                existing.dismissed = false
                existing.dismissedAt = nil
                existing.needsReview = false
                existing.expiresAt = Calendar.current.date(byAdding: .day, value: 14, to: now)
                existing.updatedAt = now
                try existing.update(db)
                insight = existing
            } else {
                var created = Insight(
                    userId: userId,
                    category: .recovery,
                    title: seed.title,
                    body: withClinicianDisclaimerIfNeeded(seed.body, category: .recovery),
                    confidence: seed.isPreview ? 0.82 : 0.93
                )
                created.type = "onboarding_first_insight"
                created.description = seed.detail
                created.inputsUsed = seed.isPreview ? "profile" : "sleep,recovery"
                created.priority = 1
                created.actionable = true
                created.actionType = "open_home"
                created.shownToUser = true
                created.shownAt = now
                created.read = true
                created.readAt = now
                created.acknowledged = true
                created.acknowledgedAt = now
                created.dismissed = false
                created.needsReview = false
                created.expiresAt = Calendar.current.date(byAdding: .day, value: 14, to: now)
                try created.insert(db)
                insight = created
            }

            return FirstInsightCard(
                insightId: insight.id,
                title: insight.title,
                body: insight.body,
                score: seed.score,
                zone: seed.zone,
                detail: seed.detail,
                footer: seed.footer,
                isPreview: seed.isPreview
            )
        }
    }

    private static func buildRecoveryInsightSeed(
        db: Database,
        userId: UUID
    ) throws -> RecoveryInsightSeed {
        if let latestState = try PhysiologicalState.fetchOne(
            db,
            sql: """
                SELECT *
                FROM physiological_states
                WHERE user_id = ? OR user_id = ?
                ORDER BY date DESC
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString]
        ) {
            let score = Int(latestState.recoveryScore.rounded())
            let detail: String
            if let sleepDurationHours = latestState.sleepDurationHours {
                detail = String(
                    format: String(localized: "onboarding_first_insight_live_detail_sleep_format"),
                    formattedDuration(hours: sleepDurationHours)
                )
            } else {
                detail = String(localized: "onboarding_first_insight_live_detail_generic")
            }
            let body = String(
                format: String(localized: "onboarding_first_insight_live_body_format"),
                score,
                latestState.recoveryZone.label,
                detail
            )
            return RecoveryInsightSeed(
                title: String(localized: "onboarding_first_insight_title"),
                body: body,
                score: score,
                zone: latestState.recoveryZone,
                detail: detail,
                footer: String(localized: "onboarding_first_insight_live_footer"),
                isPreview: false
            )
        }

        let user = try User.fetchOne(
            db,
            sql: """
                SELECT *
                FROM users
                WHERE id = ? OR id = ?
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString]
        )
        let flags = try UserHealthFlags.fetchOne(
            db,
            sql: """
                SELECT *
                FROM user_health_flags
                WHERE user_id = ? OR user_id = ?
                ORDER BY updated_at DESC
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString]
        )

        let score = starterRecoveryScore(
            primaryGoal: user?.primaryGoal,
            activityLevel: user?.activityLevel,
            hasCardiacCondition: flags?.hasCardiacCondition ?? false,
            hasPacemaker: flags?.hasPacemaker ?? false,
            isPregnant: flags?.isPregnant ?? false,
            hasChronicFatigue: flags?.hasChronicFatigue ?? false
        )
        let zone = RecoveryZone.from(score: Double(score))
        let detail = String(localized: "onboarding_first_insight_preview_detail")
        let body = String(
            format: String(localized: "onboarding_first_insight_preview_body_format"),
            score,
            zone.label,
            detail
        )

        return RecoveryInsightSeed(
            title: String(localized: "onboarding_first_insight_title"),
            body: body,
            score: score,
            zone: zone,
            detail: detail,
            footer: String(localized: "onboarding_first_insight_preview_footer"),
            isPreview: true
        )
    }

    private static func starterRecoveryScore(
        primaryGoal: PrimaryGoal?,
        activityLevel: ActivityLevel?,
        hasCardiacCondition: Bool,
        hasPacemaker: Bool,
        isPregnant: Bool,
        hasChronicFatigue: Bool
    ) -> Int {
        var score = 68

        switch activityLevel {
        case .sedentary?:
            score += 3
        case .light?:
            score += 1
        case .active?:
            score -= 2
        case .veryActive?:
            score -= 4
        case .moderate?, nil:
            break
        }

        switch primaryGoal {
        case .recovery?:
            score += 2
        case .performance?:
            score -= 1
        default:
            break
        }

        if hasCardiacCondition || hasPacemaker {
            score -= 6
        }
        if isPregnant {
            score -= 4
        }
        if hasChronicFatigue {
            score -= 8
        }

        return min(max(score, 45), 82)
    }

    private static func formattedDuration(hours: Double) -> String {
        let totalMinutes = max(Int((hours * 60).rounded()), 0)
        let hourComponent = totalMinutes / 60
        let minuteComponent = totalMinutes % 60
        return String(
            format: String(localized: "onboarding_first_insight_duration_format"),
            hourComponent,
            minuteComponent
        )
    }

    private static func withClinicianDisclaimerIfNeeded(
        _ body: String,
        category: InsightCategory
    ) -> String {
        let disclaimer = String(localized: "clinician_disclaimer")
        guard category == .health || category == .recovery || category == .sleep else {
            return body
        }
        if body.localizedCaseInsensitiveContains(disclaimer) {
            return body
        }
        return "\(body) \(disclaimer)"
    }

    private static var resolvedDBQueue: DatabaseQueue {
#if DEBUG
        if let override = testDatabaseQueueOverride.value {
            return override
        }
#endif
        return DatabaseManager.shared.dbQueue
    }

    private static var resolvedSyncEngine: SyncEngine {
        if let syncEngine = AppContainer.shared?.syncEngine {
            return syncEngine
        }
#if DEBUG
        if let override = testDatabaseQueueOverride.value {
            return SyncEngine(dbQueue: override)
        }
#endif
        return SyncEngine(dbQueue: DatabaseManager.shared.dbQueue)
    }

    private static func requiredActiveAuthId() async throws -> String {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        guard let authId else {
            throw OnboardingPersistenceError.activeUserUnavailable
        }
        return authId
    }

    private static func requiredUserId() async throws -> UUID {
        let authId = try await requiredActiveAuthId()
        guard let userId = try await resolvedDBQueue.read(
            { db in try UserIdentityLookup.resolveUserId(authId: authId, db: db) }
        ) else {
            throw OnboardingPersistenceError.activeUserUnavailable
        }
        return userId
    }

    private static func resolveRequiredUserId(authId: String, db: Database) throws -> UUID {
        guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
            throw OnboardingPersistenceError.activeUserUnavailable
        }
        return userId
    }

    private enum TransitionContext: Equatable {
        case progress
        case profile
        case healthKit
        case firstInsight
        case healthFlags
        case weight
        case backfill
        case complete

        var fallbackMessage: String {
            switch self {
            case .backfill:
                return String(localized: "onboarding_backfill_failed")
            case .progress, .profile, .healthKit, .firstInsight, .healthFlags, .weight, .complete:
                return String(localized: "onboarding_step_save_failed")
            }
        }

        var logName: String {
            switch self {
            case .progress:
                return "progress"
            case .profile:
                return "profile"
            case .healthKit:
                return "health_kit"
            case .firstInsight:
                return "first_insight"
            case .healthFlags:
                return "health_flags"
            case .weight:
                return "weight"
            case .backfill:
                return "backfill"
            case .complete:
                return "complete"
            }
        }
    }

    private enum OnboardingPersistenceError: LocalizedError {
        case activeUserUnavailable

        var errorDescription: String? {
            String(localized: "error.user.unavailable")
        }
    }

    private static func runTransition(
        context: TransitionContext,
        operation: @escaping @Sendable () async throws -> Void,
        responseAction: @escaping @Sendable (StepTransitionResult) -> Action
    ) -> Effect<Action> {
        .run { send in
            do {
                try await operation()
                await send(responseAction(.succeeded))
            } catch {
                logger.error(
                    "Onboarding \(context.logName, privacy: .public) transition failed: \(error.localizedDescription, privacy: .public)"
                )
                await send(responseAction(.failed(userFacingFailureMessage(for: context, error: error))))
            }
        }
    }

    private static func userFacingFailureMessage(
        for context: TransitionContext,
        error: Error
    ) -> String {
        if let onboardingError = error as? OnboardingPersistenceError,
           let description = onboardingError.errorDescription,
           !description.isEmpty {
            return description
        }
        if context == .backfill,
           let healthKitError = error as? HealthKitError,
           let description = healthKitError.errorDescription,
           !description.isEmpty {
            return description
        }
        return context.fallbackMessage
    }

    private static func supportedAge(from dateOfBirth: Date) -> Int? {
        let years = Calendar.current.dateComponents([.year], from: dateOfBirth, to: Date()).year ?? 0
        guard (State.minimumSupportedAge...State.maximumSupportedAge).contains(years) else {
            return nil
        }
        return years
    }

    private static func clampedDateOfBirth(_ date: Date) -> Date {
        let bounds = supportedDateOfBirthRange
        if date < bounds.lowerBound { return bounds.lowerBound }
        if date > bounds.upperBound { return bounds.upperBound }
        return date
    }

    private static var supportedDateOfBirthRange: ClosedRange<Date> {
        let calendar = Calendar(identifier: .gregorian)
        let today = Date()
        let youngest = calendar.date(byAdding: .year, value: -State.minimumSupportedAge, to: today) ?? today
        let oldest = calendar.date(byAdding: .year, value: -State.maximumSupportedAge, to: today) ?? youngest
        return oldest...youngest
    }

    private static func parseMetricValue(
        _ text: String,
        allowedRange: ClosedRange<Double>
    ) -> Double? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), allowedRange.contains(value) else {
            return nil
        }
        return roundedMetricValue(value)
    }

    private static func roundedMetricValue(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private static func formattedMetricValue(_ value: Double) -> String {
        let rounded = roundedMetricValue(value)
        if rounded.rounded(.towardZero) == rounded {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }

    private static func normalizedDateOnly(_ date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: components.year,
            month: components.month,
            day: components.day,
            hour: 12
        )) ?? date
    }

    private static func localDateOnlyString(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return DateFormatting.dateOnlyString(from: date)
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

#if DEBUG
extension OnboardingFeature {
    static func _testLatestUserId() async throws -> UUID? {
        try await latestUserId()
    }

    static func _testResolveSyncEngineFallbackPath() {
        let previousContainer = AppContainer.shared
        AppContainer.shared = nil
        _ = resolvedSyncEngine
        AppContainer.shared = previousContainer
    }

    nonisolated static func _testSetDatabaseQueueOverride(_ dbQueue: DatabaseQueue?) {
        testDatabaseQueueOverride.value = dbQueue
    }
}
#endif
