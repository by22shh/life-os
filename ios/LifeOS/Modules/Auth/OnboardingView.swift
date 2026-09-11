// MARK: - Onboarding View
// Shipped 6-step onboarding:
// Value proposition → quick win → HealthKit → basic profile (+ optional supplements/labs entry points)
// → first insight → notifications.

import SwiftUI
import ComposableArchitecture

private enum OnboardingQuickWinModal: Identifiable, Equatable {
    case photoCapture
    case review(NutritionLogDraft)

    var id: String {
        switch self {
        case .photoCapture:
            return "photo_capture"
        case .review(let draft):
            return "review_\(draft.id.uuidString)"
        }
    }
}

private enum OnboardingProfileField: Hashable {
    case height
    case weight
}

struct OnboardingView: View {
    @State private var store: StoreOf<OnboardingFeature>
    @State private var optionalSetupSheet: OnboardingOptionalSetupSheet?
    @State private var quickWinModal: OnboardingQuickWinModal?
    @State private var quickWinLoggedAt = Date()
    @State private var selectedSupplementQuickPick: OnboardingSupplementQuickPick?
    @State private var selectedSupplementTiming: OnboardingSupplementTimingPreference = .morning
    @FocusState private var focusedProfileField: OnboardingProfileField?
    @Environment(AuthManager.self) private var authManager: AuthManager?

    init(store: StoreOf<OnboardingFeature> = Store(initialState: OnboardingFeature.State()) { OnboardingFeature() }) {
        _store = State(initialValue: store)
    }

    var body: some View {
        NavigationStack {
            @Bindable var store = store

            VStack(spacing: Spacing.l) {
                progressSection(store: store)

                Group {
                    if store.currentStep == .onboardingComplete {
                        completeStep(store: store)
                    } else {
                        switch store.currentDisplayStep {
                        case .valueProp:
                            valuePropStep(store: store)
                        case .quickWin:
                            quickWinStep(store: store)
                        case .healthKitPermission:
                            healthKitStep(store: store)
                        case .basicProfile:
                            profileStep(store: store)
                        case .firstInsight:
                            firstInsightStep(store: store)
                        case .notifications:
                            notificationsStep(store: store)
                        default:
                            valuePropStep(store: store)
                        }
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .animation(LifeOSAnimation.sheet, value: store.currentStep)

                Spacer()
            }
                .padding(.top, Spacing.l)
                .background(LifeOSColors.Surface.background)
                .navigationTitle(String(localized: "getting_started"))
                .navigationBarTitleDisplayMode(.large)
                .onAppear {
                    store.send(.loadProfileIfNeeded)
                    handleCurrentStepChange(store.currentStep, store: store)
                }
                .onChange(of: store.currentStep) { _, newStep in
                    handleCurrentStepChange(newStep, store: store)
                }
                .sheet(item: $optionalSetupSheet, onDismiss: {
                    self.store.send(.loadOptionalSetupSummary)
                }) { sheet in
                    switch sheet {
                    case .supplementQuickAdd:
                        AddSupplementView(
                            initialName: selectedSupplementQuickPick?.displayName ?? "",
                            initialScheduledTime: selectedSupplementTiming.defaultScheduledTime,
                            onSave: { self.store.send(.loadOptionalSetupSummary) }
                        )
                    case .supplementCustom:
                        AddSupplementView(onSave: { self.store.send(.loadOptionalSetupSummary) })
                    case .labsImport:
                        LabsScanCaptureView()
                    }
                }
                .fullScreenCover(item: $quickWinModal) { modal in
                    switch modal {
                    case .photoCapture:
                        NutritionPhotoCaptureView(
                            targetDay: DiaryDateFormatter.formatDate(quickWinLoggedAt),
                            loggedAt: quickWinLoggedAt
                        ) { draft in
                            presentQuickWinReview(draft)
                        }
                    case .review(let draft):
                        NavigationStack {
                            NutritionLogView(
                                method: draft.method,
                                aiConfidence: draft.confidence,
                                draft: draft,
                                onComplete: {
                                    quickWinModal = nil
                                    self.store.send(.completeQuickWin)
                                }
                            )
                        }
                    }
                }
        }
    }

    // MARK: - Step Views

    private func progressSection(store: StoreOf<OnboardingFeature>) -> some View {
        VStack(spacing: Spacing.s) {
            ProgressView(value: store.progress)
                .tint(LifeOSColors.Semantic.primary)
                .padding(.horizontal, Spacing.l)
                .animation(.easeInOut(duration: 0.3), value: store.progress)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) {
                    ForEach(OnboardingStep.flowSteps, id: \.self) { step in
                        flowChip(
                            title: flowTitle(for: step),
                            status: flowStatus(for: step, current: store.currentStep)
                        )
                    }
                }
                .padding(.horizontal, Spacing.l)
            }
        }
    }

    private func valuePropStep(store: StoreOf<OnboardingFeature>) -> some View {
        VStack(spacing: Spacing.l) {
            Spacer()

            Image(systemName: "sparkles.rectangle.stack")
                .font(LifeOSTypography.title)
                .foregroundStyle(LifeOSColors.Semantic.primary)

            Text(String(localized: "onboarding_value_prop_title"))
                .font(LifeOSTypography.headline)

            Text(String(localized: "onboarding_value_prop_description"))
                .font(LifeOSTypography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)

            VStack(alignment: .leading, spacing: Spacing.s) {
                benefitRow(icon: "heart.text.square.fill", text: String(localized: "onboarding_value_prop_benefit_recovery"))
                benefitRow(icon: "fork.knife.circle.fill", text: String(localized: "onboarding_value_prop_benefit_diary"))
                benefitRow(icon: "lightbulb.max.fill", text: String(localized: "onboarding_value_prop_benefit_insights"))
            }
            .padding(Spacing.m)
            .background(LifeOSColors.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
            .padding(.horizontal, Spacing.l)

            Spacer()

            if let errorMessage = store.errorMessage {
                stepErrorMessage(errorMessage)
            }

            Button(action: advanceFromValuePropAction(store: store)) {
                Text(String(localized: "continue"))
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: LayoutConstants.minTouchTarget)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, Spacing.l)
            .accessibilityIdentifier("onboarding.value_prop.continue")
        }
    }

    private func quickWinStep(store: StoreOf<OnboardingFeature>) -> some View {
        VStack(spacing: Spacing.l) {
            Spacer()

            Image(systemName: "camera.macro.circle.fill")
                .font(LifeOSTypography.title)
                .foregroundStyle(LifeOSColors.Semantic.primary)

            Text(String(localized: "onboarding_quick_win_title"))
                .font(LifeOSTypography.headline)

            Text(String(localized: "onboarding_quick_win_description"))
                .font(LifeOSTypography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)

            Group {
                if store.quickWinCompleted {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Label(String(localized: "onboarding_quick_win_result_title"), systemImage: "checkmark.circle.fill")
                            .font(LifeOSTypography.subheadline.weight(.semibold))
                            .foregroundStyle(LifeOSColors.Semantic.primary)

                        Text(store.quickWinResult?.title ?? String(localized: "nutrition_meal"))
                            .font(LifeOSTypography.body.weight(.semibold))

                        if let result = store.quickWinResult,
                           let macros = quickWinMacroSummaryText(result) {
                            Text(macros)
                                .font(LifeOSTypography.subheadline)
                        }

                        Text(quickWinResultNote(store.quickWinResult))
                            .font(LifeOSTypography.caption)
                            .foregroundStyle(
                                (store.quickWinResult?.needsReview ?? false)
                                    ? LifeOSColors.Recovery.caution
                                    : Color.secondary
                            )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.m)
                    .background(LifeOSColors.Surface.card)
                    .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
                    .padding(.horizontal, Spacing.l)
                } else {
                    VStack(spacing: Spacing.s) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 42, weight: .medium))
                            .foregroundStyle(.secondary)

                        Text(String(localized: "onboarding_quick_win_demo_caption"))
                            .font(LifeOSTypography.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Text(String(localized: "nutrition_photo_review_save_notice"))
                            .font(LifeOSTypography.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .background(LifeOSColors.Surface.card)
                    .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
                    .padding(.horizontal, Spacing.l)
                }
            }

            Spacer()

            if let errorMessage = store.errorMessage {
                stepErrorMessage(errorMessage)
            }

            Button(
                action: store.quickWinCompleted
                    ? advanceFromQuickWinAction(store: store)
                    : runQuickWinAction(store: store)
            ) {
                Group {
                    if store.isCompletingQuickWin {
                        ProgressView()
                    } else {
                        Text(
                            store.quickWinCompleted
                                ? String(localized: "continue")
                                : String(localized: "onboarding_quick_win_cta")
                        )
                            .font(LifeOSTypography.subheadline.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: LayoutConstants.minTouchTarget)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, Spacing.l)
            .disabled(store.isCompletingQuickWin)
            .accessibilityIdentifier("onboarding.quick_win.primary")
        }
    }

    private func profileStep(store: StoreOf<OnboardingFeature>) -> some View {
        VStack(spacing: Spacing.m) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(LifeOSTypography.title)
                            .foregroundStyle(LifeOSColors.Semantic.primary)

                        Text(String(localized: "your_profile"))
                            .font(LifeOSTypography.headline)

                        Text(String(localized: "onboarding_profile_description"))
                            .font(LifeOSTypography.body)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, Spacing.l)

                    profileSection(
                        title: String(localized: "onboarding_profile_dob_title"),
                        description: String(localized: "onboarding_profile_dob_description")
                    ) {
                        DatePicker(
                            String(localized: "onboarding_profile_dob_title"),
                            selection: Binding(
                                get: { store.dateOfBirth },
                                set: { store.send(.dateOfBirthChanged($0)) }
                            ),
                            in: supportedDateOfBirthRange,
                            displayedComponents: .date
                        )
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("onboarding.profile.date_of_birth")

                        if !store.hasConfirmedDateOfBirth {
                            Button(action: { store.send(.confirmDateOfBirth) }) {
                                Text(String(localized: "onboarding_profile_confirm_dob"))
                                    .font(LifeOSTypography.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("onboarding.profile.confirm_date_of_birth")
                        }

                        if let age = store.profileAge {
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text(String(format: String(localized: "onboarding_profile_age_value_format"), age))
                                    .font(LifeOSTypography.caption)
                                    .foregroundStyle(.secondary)

                                Text(String(localized: "onboarding_profile_confirmed_dob"))
                                    .font(LifeOSTypography.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        } else {
                            Text(String(localized: "onboarding_profile_dob_hint"))
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    profileSection(
                        title: String(localized: "onboarding_profile_sex_title"),
                        description: String(localized: "onboarding_profile_sex_description")
                    ) {
                        LazyVGrid(columns: profileOptionColumns, spacing: Spacing.s) {
                            ForEach(BiologicalSex.allCases, id: \.self) { option in
                                profileOptionButton(
                                    title: title(for: option),
                                    isSelected: store.sex == option,
                                    accessibilityIdentifier: "onboarding.profile.sex.\(option.rawValue)",
                                    action: { store.send(.setSex(option)) }
                                )
                            }
                        }
                    }

                    profileSection(
                        title: String(localized: "onboarding_profile_height_title"),
                        description: String(localized: "onboarding_profile_height_description")
                    ) {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                            TextField(
                                String(localized: "onboarding_profile_height_placeholder"),
                                text: Binding(
                                    get: { store.heightInputText },
                                    set: { store.send(.heightChanged($0)) }
                                )
                            )
                            .font(LifeOSTypography.metricMedium)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.leading)
                            .focused($focusedProfileField, equals: .height)
                            .accessibilityIdentifier("onboarding.profile.height")

                            Spacer(minLength: Spacing.s)

                            Text(String(localized: "unit_cm"))
                                .font(LifeOSTypography.body)
                                .foregroundStyle(.secondary)
                        }
                    }

                    profileSection(
                        title: String(localized: "onboarding_profile_goal_title"),
                        description: String(localized: "onboarding_profile_goal_description")
                    ) {
                        LazyVGrid(columns: profileOptionColumns, spacing: Spacing.s) {
                            ForEach(PrimaryGoal.allCases, id: \.self) { option in
                                profileOptionButton(
                                    title: title(for: option),
                                    isSelected: store.primaryGoal == option,
                                    accessibilityIdentifier: "onboarding.profile.goal.\(option.rawValue)",
                                    action: { store.send(.setPrimaryGoal(option)) }
                                )
                            }
                        }
                    }

                    profileSection(
                        title: String(localized: "onboarding_profile_activity_title"),
                        description: String(localized: "onboarding_profile_activity_description")
                    ) {
                        LazyVGrid(columns: profileOptionColumns, spacing: Spacing.s) {
                            ForEach(ActivityLevel.allCases, id: \.self) { option in
                                profileOptionButton(
                                    title: title(for: option),
                                    isSelected: store.activityLevel == option,
                                    accessibilityIdentifier: "onboarding.profile.activity.\(option.rawValue)",
                                    action: { store.send(.setActivityLevel(option)) }
                                )
                            }
                        }
                    }

                    profileSection(
                        title: String(localized: "onboarding_weight_title"),
                        description: String(localized: "onboarding_weight_description")
                    ) {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                            TextField(
                                String(localized: "onboarding_profile_weight_placeholder"),
                                text: Binding(
                                    get: { store.weightInputText },
                                    set: { store.send(.weightChanged($0)) }
                                )
                            )
                            .font(LifeOSTypography.metricMedium)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.leading)
                            .focused($focusedProfileField, equals: .weight)
                            .accessibilityIdentifier("onboarding.profile.weight")

                            Spacer(minLength: Spacing.s)

                            Text(String(localized: "unit_kg"))
                                .font(LifeOSTypography.body)
                                .foregroundStyle(.secondary)
                        }

                        Text(String(localized: "onboarding_weight_why"))
                            .font(LifeOSTypography.caption)
                            .foregroundStyle(.secondary)
                    }

                    profileSection(
                        title: String(localized: "health_screening"),
                        description: String(localized: "onboarding_health_screening_description")
                    ) {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Toggle(
                                String(localized: "settings_health_flag_cardiac_condition"),
                                isOn: Binding(
                                    get: { store.hasCardiacCondition },
                                    set: { store.send(.setHasCardiacCondition($0)) }
                                )
                            )
                            Toggle(
                                String(localized: "settings_health_flag_pacemaker"),
                                isOn: Binding(
                                    get: { store.hasPacemaker },
                                    set: { store.send(.setHasPacemaker($0)) }
                                )
                            )
                            Toggle(
                                String(localized: "settings_health_flag_beta_blockers"),
                                isOn: Binding(
                                    get: { store.onBetaBlockers },
                                    set: { store.send(.setOnBetaBlockers($0)) }
                                )
                            )
                            Toggle(
                                String(localized: "settings_health_flag_pregnant"),
                                isOn: Binding(
                                    get: { store.isPregnant },
                                    set: { store.send(.setIsPregnant($0)) }
                                )
                            )
                            Toggle(
                                String(localized: "settings_health_flag_menstrual_tracking"),
                                isOn: Binding(
                                    get: { store.menstrualTrackingEnabled },
                                    set: { store.send(.setMenstrualTrackingEnabled($0)) }
                                )
                            )
                            Toggle(
                                String(localized: "settings_health_flag_eating_disorder_history"),
                                isOn: Binding(
                                    get: { store.hasEatingDisorderHistory },
                                    set: { store.send(.setHasEatingDisorderHistory($0)) }
                                )
                            )
                            Toggle(
                                String(localized: "settings_health_flag_chronic_fatigue"),
                                isOn: Binding(
                                    get: { store.hasChronicFatigue },
                                    set: { store.send(.setHasChronicFatigue($0)) }
                                )
                            )
                        }
                        .font(LifeOSTypography.subheadline)
                    }

                    profileSection(
                        title: String(localized: "onboarding_optional_setup_title"),
                        description: String(localized: "onboarding_optional_setup_description")
                    ) {
                        VStack(alignment: .leading, spacing: Spacing.m) {
                            optionalSetupCard(
                                icon: "pill",
                                title: String(localized: "supplements"),
                                statusText: supplementsStatusText(store: store)
                            ) {
                                VStack(alignment: .leading, spacing: Spacing.s) {
                                    Text(String(localized: "onboarding_optional_supplements_quick_pick_hint"))
                                        .font(LifeOSTypography.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)

                                    LazyVGrid(columns: profileOptionColumns, spacing: Spacing.s) {
                                        ForEach(OnboardingSupplementQuickPick.allCases, id: \.self) { option in
                                            profileOptionButton(
                                                title: option.displayName,
                                                isSelected: selectedSupplementQuickPick == option,
                                                action: { selectedSupplementQuickPick = option }
                                            )
                                        }
                                    }

                                    Text(String(localized: "onboarding_optional_supplements_timing_title"))
                                        .font(LifeOSTypography.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)

                                    LazyVGrid(columns: profileOptionColumns, spacing: Spacing.s) {
                                        ForEach(OnboardingSupplementTimingPreference.allCases, id: \.self) { option in
                                            profileOptionButton(
                                                title: option.title,
                                                isSelected: selectedSupplementTiming == option,
                                                action: { selectedSupplementTiming = option }
                                            )
                                        }
                                    }

                                    Label(String(localized: "onboarding_optional_supplements_timing_tip"), systemImage: "info.circle")
                                        .font(LifeOSTypography.caption)
                                        .foregroundStyle(.secondary)

                                    HStack(spacing: Spacing.s) {
                                        Button(
                                            String(localized: "onboarding_optional_supplements_primary"),
                                            action: openQuickAddSupplement
                                        )
                                        .buttonStyle(.borderedProminent)
                                        .disabled(selectedSupplementQuickPick == nil)
                                        .accessibilityIdentifier("onboarding.optional_setup.supplements.quick_add")

                                        Button(
                                            String(localized: "onboarding_optional_supplements_secondary"),
                                            action: openCustomSupplement
                                        )
                                        .buttonStyle(.bordered)
                                        .accessibilityIdentifier("onboarding.optional_setup.supplements.custom")
                                    }
                                }
                            }

                            optionalSetupCard(
                                icon: "waveform.path.ecg",
                                title: String(localized: "labs_scan_title"),
                                statusText: labsStatusText(store: store)
                            ) {
                                VStack(alignment: .leading, spacing: Spacing.s) {
                                    Text(String(localized: "onboarding_optional_labs_description"))
                                        .font(LifeOSTypography.caption)
                                        .foregroundStyle(.secondary)

                                    Label(String(localized: "labs_privacy_local_only"), systemImage: "lock.shield")
                                        .font(LifeOSTypography.caption)
                                        .foregroundStyle(LifeOSColors.Semantic.primary)

                                    Button(String(localized: "labs_scan_button"), action: openLabsImport)
                                        .buttonStyle(.borderedProminent)
                                        .accessibilityIdentifier("onboarding.optional_setup.labs.import")
                                }
                            }

                            Text(String(localized: "onboarding_optional_setup_later"))
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Label(String(localized: "onboarding_profile_privacy"), systemImage: "lock.shield")
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Spacing.l)
                }
                .padding(.bottom, Spacing.xs)
            }
            .scrollDismissesKeyboard(.immediately)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(String(localized: "common_done")) {
                        focusedProfileField = nil
                    }
                }
            }

            Text(String(localized: "onboarding_profile_required_note"))
                .font(LifeOSTypography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)

            if let errorMessage = store.errorMessage {
                stepErrorMessage(errorMessage)
            }

            Button(action: advanceFromProfileAction(store: store)) {
                Group {
                    if store.isSavingProfile {
                        ProgressView()
                    } else {
                        Text(String(localized: "continue"))
                            .font(LifeOSTypography.subheadline.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: LayoutConstants.minTouchTarget)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, Spacing.l)
            .disabled(!store.canAdvanceFromProfile || store.isSavingProfile)
            .accessibilityIdentifier("onboarding.profile.continue")
        }
    }

    private func profileSection<Content: View>(
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(title)
                .font(LifeOSTypography.subheadline.weight(.semibold))

            Text(description)
                .font(LifeOSTypography.caption)
                .foregroundStyle(.secondary)

            content()
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
        .padding(.horizontal, Spacing.l)
    }

    private func optionalSetupCard<Content: View>(
        icon: String,
        title: String,
        statusText: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Label(title, systemImage: icon)
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                    .foregroundStyle(LifeOSColors.Semantic.primary)

                Spacer()

                Text(statusText)
                    .font(LifeOSTypography.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.s)
                    .padding(.vertical, Spacing.xxs)
                    .background(LifeOSColors.Surface.elevated)
                    .clipShape(Capsule())
            }

            content()
        }
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.elevated)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private func profileOptionButton(
        title: String,
        isSelected: Bool,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(LifeOSTypography.subheadline.weight(.medium))
                .foregroundStyle(isSelected ? LifeOSColors.Semantic.primary : Color.primary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: LayoutConstants.minTouchTarget)
                .padding(.horizontal, Spacing.s)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius)
                        .fill(isSelected ? LifeOSColors.Semantic.primary.opacity(0.12) : LifeOSColors.Surface.elevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius)
                        .stroke(isSelected ? LifeOSColors.Semantic.primary : Color.secondary.opacity(0.18), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? String(localized: "selected") : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }

    private func supplementsStatusText(store: StoreOf<OnboardingFeature>) -> String {
        let count = store.optionalSetupSummary.supplementCount
        guard count > 0 else {
            return String(localized: "onboarding_optional_supplements_empty")
        }
        return String(format: String(localized: "onboarding_optional_supplements_status_format"), count)
    }

    private func labsStatusText(store: StoreOf<OnboardingFeature>) -> String {
        let summary = store.optionalSetupSummary
        if summary.labReviewCount > 0 {
            return String(format: String(localized: "onboarding_optional_labs_review_format"), summary.labReviewCount)
        }
        guard summary.labScanCount > 0 else {
            return String(localized: "onboarding_optional_labs_empty")
        }
        return String(format: String(localized: "onboarding_optional_labs_status_format"), summary.labScanCount)
    }

    private var profileOptionColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 132), spacing: Spacing.s)]
    }

    private var supportedDateOfBirthRange: ClosedRange<Date> {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let youngest = calendar.date(byAdding: .year, value: -OnboardingFeature.State.minimumSupportedAge, to: now) ?? now
        let oldest = calendar.date(byAdding: .year, value: -OnboardingFeature.State.maximumSupportedAge, to: now) ?? youngest
        return oldest...youngest
    }

    private func title(for option: BiologicalSex) -> String {
        switch option {
        case .male:
            return String(localized: "onboarding_profile_sex_male")
        case .female:
            return String(localized: "onboarding_profile_sex_female")
        case .other:
            return String(localized: "onboarding_profile_sex_other")
        }
    }

    private func title(for option: PrimaryGoal) -> String {
        switch option {
        case .recovery:
            return String(localized: "onboarding_profile_goal_recovery")
        case .performance:
            return String(localized: "onboarding_profile_goal_performance")
        case .weight:
            return String(localized: "onboarding_profile_goal_weight")
        case .generalHealth:
            return String(localized: "onboarding_profile_goal_general_health")
        }
    }

    private func title(for option: ActivityLevel) -> String {
        switch option {
        case .sedentary:
            return String(localized: "onboarding_profile_activity_sedentary")
        case .light:
            return String(localized: "onboarding_profile_activity_light")
        case .moderate:
            return String(localized: "onboarding_profile_activity_moderate")
        case .active:
            return String(localized: "onboarding_profile_activity_active")
        case .veryActive:
            return String(localized: "onboarding_profile_activity_very_active")
        }
    }

    private func healthFlagsStep(store: StoreOf<OnboardingFeature>) -> some View {
        VStack(spacing: Spacing.l) {
            Spacer()

            Image(systemName: "heart.text.square")
                .font(LifeOSTypography.title)
                .foregroundStyle(LifeOSColors.Semantic.primary)

            Text(String(localized: "health_screening"))
                .font(LifeOSTypography.headline)

            Text(String(localized: "onboarding_health_screening_description"))
                .font(LifeOSTypography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)

            VStack(alignment: .leading, spacing: Spacing.s) {
                Toggle(
                    String(localized: "settings_health_flag_cardiac_condition"),
                    isOn: Binding(
                        get: { store.hasCardiacCondition },
                        set: { store.send(.setHasCardiacCondition($0)) }
                    )
                )
                Toggle(
                    String(localized: "settings_health_flag_pacemaker"),
                    isOn: Binding(
                        get: { store.hasPacemaker },
                        set: { store.send(.setHasPacemaker($0)) }
                    )
                )
                Toggle(
                    String(localized: "settings_health_flag_beta_blockers"),
                    isOn: Binding(
                        get: { store.onBetaBlockers },
                        set: { store.send(.setOnBetaBlockers($0)) }
                    )
                )
                Toggle(
                    String(localized: "settings_health_flag_pregnant"),
                    isOn: Binding(
                        get: { store.isPregnant },
                        set: { store.send(.setIsPregnant($0)) }
                    )
                )
                Toggle(
                    String(localized: "settings_health_flag_menstrual_tracking"),
                    isOn: Binding(
                        get: { store.menstrualTrackingEnabled },
                        set: { store.send(.setMenstrualTrackingEnabled($0)) }
                    )
                )
                Toggle(
                    String(localized: "settings_health_flag_eating_disorder_history"),
                    isOn: Binding(
                        get: { store.hasEatingDisorderHistory },
                        set: { store.send(.setHasEatingDisorderHistory($0)) }
                    )
                )
                Toggle(
                    String(localized: "settings_health_flag_chronic_fatigue"),
                    isOn: Binding(
                        get: { store.hasChronicFatigue },
                        set: { store.send(.setHasChronicFatigue($0)) }
                    )
                )
            }
            .font(LifeOSTypography.subheadline)
            .padding(Spacing.m)
            .background(LifeOSColors.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
            .padding(.horizontal, Spacing.l)

            Label(String(localized: "onboarding_profile_privacy"), systemImage: "lock.shield")
                .font(LifeOSTypography.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, Spacing.xl)

            Spacer()

            if let errorMessage = store.errorMessage {
                stepErrorMessage(errorMessage)
            }

            Button(action: advanceFromHealthFlagsAction(store: store)) {
                Group {
                    if store.isSavingHealthFlags {
                        ProgressView()
                    } else {
                        Text(String(localized: "continue"))
                            .font(LifeOSTypography.subheadline.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: LayoutConstants.minTouchTarget)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, Spacing.l)
            .disabled(store.isSavingHealthFlags)
            .accessibilityIdentifier("onboarding.health_flags.continue")
        }
    }

    // MARK: - Weight Step (NEW)

    private func weightStep(store: StoreOf<OnboardingFeature>) -> some View {
        @Bindable var store = store

        return VStack(spacing: Spacing.l) {
            Spacer()

            Image(systemName: "scalemass")
                .font(LifeOSTypography.title)
                .foregroundStyle(LifeOSColors.Semantic.primary)

            Text(String(localized: "onboarding_weight_title"))
                .font(LifeOSTypography.headline)

            Text(String(localized: "onboarding_weight_description"))
                .font(LifeOSTypography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)

            // Weight input
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                TextField("70", text: $store.weightInputText.sending(\.weightChanged))
                    .font(LifeOSTypography.metricMedium)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .frame(width: 120)
                    .padding(.vertical, Spacing.s)
                    .background(LifeOSColors.Surface.card)
                    .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
                    .accessibilityLabel(String(localized: "onboarding_weight_input_label"))
                    .accessibilityIdentifier("onboarding.weight.input")

                Text(String(localized: "unit_kg"))
                    .font(LifeOSTypography.body)
                    .foregroundStyle(.secondary)
            }

            // Why we need this
            Label(String(localized: "onboarding_weight_why"), systemImage: "info.circle")
                .font(LifeOSTypography.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, Spacing.xl)

            Spacer()

            if let errorMessage = store.errorMessage {
                stepErrorMessage(errorMessage)
            }

            Button(action: advanceFromWeightAction(store: store)) {
                Group {
                    if store.isSavingWeight {
                        ProgressView()
                    } else {
                        Text(String(localized: "continue"))
                            .font(LifeOSTypography.subheadline.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: LayoutConstants.minTouchTarget)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, Spacing.l)
            .disabled(!store.canAdvanceFromWeight || store.isSavingWeight)
            .accessibilityIdentifier("onboarding.weight.continue")
        }
    }

    // MARK: - HealthKit Step (improved)

    private func healthKitStep(store: StoreOf<OnboardingFeature>) -> some View {
        VStack(spacing: Spacing.l) {
            Spacer()

            Image(systemName: "heart.fill")
                .font(LifeOSTypography.title)
                .foregroundStyle(.red)

            Text(String(localized: "onboarding_apple_health_title"))
                .font(LifeOSTypography.headline)

            Text(String(localized: "onboarding_apple_health_description"))
                .font(LifeOSTypography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)

            VStack(alignment: .leading, spacing: Spacing.s) {
                Label(String(localized: "onboarding_hk_privacy_card_title"), systemImage: "lock.shield.fill")
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                    .foregroundStyle(LifeOSColors.Semantic.primary)

                Text(String(localized: "onboarding_hk_privacy_card_body"))
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.m)
            .background(LifeOSColors.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
            .padding(.horizontal, Spacing.l)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                dataPointRow(icon: "waveform.path.ecg", text: String(localized: "onboarding_hk_hrv"), weight: "40%")
                dataPointRow(icon: "bed.double", text: String(localized: "onboarding_hk_sleep"), weight: "30%")
                dataPointRow(icon: "heart", text: String(localized: "onboarding_hk_rhr"), weight: "15%")
                dataPointRow(icon: "thermometer", text: String(localized: "onboarding_hk_temp"), weight: "15%")
            }
            .padding(Spacing.m)
            .background(LifeOSColors.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
            .padding(.horizontal, Spacing.l)

            VStack(alignment: .leading, spacing: Spacing.s) {
                Label(String(localized: "onboarding_hk_preview_title"), systemImage: "chart.line.uptrend.xyaxis")
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                    .foregroundStyle(LifeOSColors.Semantic.primary)

                Text(String(localized: "onboarding_hk_preview_body"))
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.m)
            .background(LifeOSColors.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
            .padding(.horizontal, Spacing.l)

            Spacer()

            if let errorMessage = store.errorMessage {
                stepErrorMessage(errorMessage)
            }

            VStack(spacing: Spacing.s) {
                Button(action: requestHealthKitAction(store: store)) {
                    if store.isRequestingHealthKit || store.isBackfilling {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .frame(height: LayoutConstants.minTouchTarget)
                    } else {
                        Text(String(localized: "connect_apple_health"))
                            .font(LifeOSTypography.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: LayoutConstants.minTouchTarget)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isRequestingHealthKit || store.isBackfilling)

                Button(String(localized: "onboarding_skip_for_now"), action: skipHealthKitAction(store: store))
                    .font(LifeOSTypography.footnote)
                    .foregroundStyle(.secondary)
                    .disabled(store.isRequestingHealthKit || store.isBackfilling)
                .accessibilityIdentifier("onboarding.healthkit.skip")
            }
            .padding(.horizontal, Spacing.l)
        }
    }

    private func dataPointRow(icon: String, text: String, weight: String) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: icon)
                .foregroundStyle(LifeOSColors.Semantic.primary)
                .frame(width: 24)

            Text(text)
                .font(LifeOSTypography.subheadline)

            Spacer()

            Text(weight)
                .font(LifeOSTypography.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func firstInsightStep(store: StoreOf<OnboardingFeature>) -> some View {
        VStack(spacing: Spacing.l) {
            Spacer()

            if store.isLoadingFirstInsight {
                ProgressView()
                    .scaleEffect(1.5)
                    .padding(.bottom, Spacing.s)

                Text(String(localized: "onboarding_first_insight_loading_title"))
                    .font(LifeOSTypography.headline)

                Text(String(localized: "onboarding_first_insight_loading_body"))
                    .font(LifeOSTypography.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
            } else {
                Image(systemName: "sparkles")
                    .font(LifeOSTypography.title)
                    .foregroundStyle(LifeOSColors.Semantic.primary)

                Text(String(localized: "onboarding_first_insight_title"))
                    .font(LifeOSTypography.headline)

                if let insight = store.firstInsight {
                    firstInsightCard(insight)
                }
            }

            Spacer()

            if let errorMessage = store.errorMessage {
                stepErrorMessage(errorMessage)
            }

            VStack(spacing: Spacing.s) {
                if store.firstInsight == nil && !store.isLoadingFirstInsight {
                    Button(action: retryFirstInsightAction(store: store)) {
                        Text(String(localized: "onboarding_retry_cta"))
                            .font(LifeOSTypography.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: LayoutConstants.minTouchTarget)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("onboarding.first_insight.retry")
                }

                Button(action: advanceFromFirstInsightAction(store: store)) {
                    Text(String(localized: "continue"))
                        .font(LifeOSTypography.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: LayoutConstants.minTouchTarget)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.firstInsight == nil || store.isLoadingFirstInsight)
                .accessibilityIdentifier("onboarding.first_insight.continue")
            }
            .padding(.horizontal, Spacing.l)
        }
    }

    private func notificationsStep(store: StoreOf<OnboardingFeature>) -> some View {
        VStack(spacing: Spacing.l) {
            Spacer()

            Text(String(localized: "onboarding_notifications_title"))
                .font(LifeOSTypography.headline)

            if let insight = store.firstInsight {
                firstInsightCard(insight)
            }

            Text(String(localized: "onboarding_notifications_body"))
                .font(LifeOSTypography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)

            Spacer()

            if let errorMessage = store.errorMessage {
                stepErrorMessage(errorMessage)
            }

            VStack(spacing: Spacing.s) {
                Button(action: enableNotificationsAction(store: store)) {
                    Group {
                        if store.isCompleting {
                            ProgressView()
                        } else {
                            Text(String(localized: "onboarding_notifications_cta"))
                                .font(LifeOSTypography.subheadline.weight(.semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: LayoutConstants.minTouchTarget)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isCompleting)
                .accessibilityIdentifier("onboarding.notifications.enable")

                Button(String(localized: "onboarding_notifications_skip"), action: completeOnboardingAction(store: store))
                    .font(LifeOSTypography.footnote)
                    .foregroundStyle(.secondary)
                    .disabled(store.isCompleting)
                    .accessibilityIdentifier("onboarding.notifications.skip")
            }
            .padding(.horizontal, Spacing.l)
        }
    }

    // MARK: - Complete Step

    private func completeStep(store: StoreOf<OnboardingFeature>) -> some View {
        VStack(spacing: Spacing.l) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(LifeOSTypography.metricMedium)
                .foregroundStyle(LifeOSColors.Recovery.Hex.optimalLight)

            Text(String(localized: "youre_all_set"))
                .font(LifeOSTypography.headline)

            Text(String(localized: "onboarding_complete_subtitle"))
                .font(LifeOSTypography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)

            // What happens next
            VStack(alignment: .leading, spacing: Spacing.xs) {
                nextStepRow(
                    icon: "chart.line.uptrend.xyaxis",
                    text: String(localized: "onboarding_next_baseline")
                )
                nextStepRow(
                    icon: "bell",
                    text: String(localized: "onboarding_next_insights")
                )
                nextStepRow(
                    icon: "fork.knife",
                    text: String(localized: "onboarding_next_nutrition")
                )
            }
            .padding(Spacing.m)
            .background(LifeOSColors.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
            .padding(.horizontal, Spacing.l)

            Spacer()

            if let errorMessage = store.errorMessage {
                stepErrorMessage(errorMessage)
            }

            Button(action: refreshAuthenticatedShellAction()) {
                Group {
                    Text(String(localized: "get_started"))
                        .font(LifeOSTypography.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: LayoutConstants.minTouchTarget)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, Spacing.l)
            .accessibilityIdentifier("onboarding.complete")
        }
    }

    private func stepErrorMessage(_ message: String) -> some View {
        Text(message)
            .font(LifeOSTypography.caption)
            .foregroundStyle(LifeOSColors.Semantic.destructive)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Spacing.xl)
    }

    private func benefitRow(icon: String, text: String) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: icon)
                .foregroundStyle(LifeOSColors.Semantic.primary)
                .frame(width: 24)

            Text(text)
                .font(LifeOSTypography.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func firstInsightCard(_ insight: OnboardingFeature.FirstInsightCard) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text("\(insight.score)%")
                    .font(LifeOSTypography.metricMedium)
                    .foregroundStyle(insight.zone.color)

                Label(insight.zone.label, systemImage: insight.zone.iconName)
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                    .foregroundStyle(insight.zone.color)
            }

            Text(insight.body)
                .font(LifeOSTypography.body)

            Text(insight.detail)
                .font(LifeOSTypography.caption)
                .foregroundStyle(.secondary)

            Text(insight.footer)
                .font(LifeOSTypography.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
        .padding(.horizontal, Spacing.l)
    }

    private func nextStepRow(icon: String, text: String) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: icon)
                .foregroundStyle(LifeOSColors.Semantic.primary)
                .frame(width: 24)
            Text(text)
                .font(LifeOSTypography.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private enum FlowChipStatus {
        case completed
        case current
        case upcoming
    }

    private func flowChip(title: String, status: FlowChipStatus) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: flowSymbol(for: status))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(flowColor(for: status))

            Text(title)
                .font(LifeOSTypography.caption)
                .foregroundStyle(flowColor(for: status))
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .background(
            Capsule()
                .fill(flowBackground(for: status))
        )
    }

    private func flowTitle(for step: OnboardingStep) -> String {
        switch step {
        case .valueProp:
            return String(localized: "onboarding_flow_welcome")
        case .quickWin:
            return String(localized: "onboarding_flow_demo")
        case .healthKitPermission:
            return String(localized: "onboarding_flow_health")
        case .basicProfile:
            return String(localized: "onboarding_flow_profile")
        case .firstInsight:
            return String(localized: "onboarding_flow_insight")
        case .notifications:
            return String(localized: "onboarding_flow_notify")
        default:
            return ""
        }
    }

    private func flowStatus(for step: OnboardingStep, current: OnboardingStep) -> FlowChipStatus {
        if current == .onboardingComplete {
            return .completed
        }
        guard let currentIndex = current.displayStep.flowIndex,
              let stepIndex = step.flowIndex else {
            return .upcoming
        }
        if stepIndex < currentIndex {
            return .completed
        }
        if stepIndex == currentIndex {
            return .current
        }
        return .upcoming
    }

    private func flowSymbol(for status: FlowChipStatus) -> String {
        switch status {
        case .completed:
            return "checkmark"
        case .current:
            return "circle.fill"
        case .upcoming:
            return "circle"
        }
    }

    private func flowColor(for status: FlowChipStatus) -> Color {
        switch status {
        case .completed, .current:
            return LifeOSColors.Semantic.primary
        case .upcoming:
            return .secondary
        }
    }

    private func flowBackground(for status: FlowChipStatus) -> Color {
        switch status {
        case .completed:
            return LifeOSColors.Semantic.primary.opacity(0.12)
        case .current:
            return LifeOSColors.Semantic.primary.opacity(0.16)
        case .upcoming:
            return LifeOSColors.Surface.card
        }
    }

    private func handleCurrentStepChange(_ newStep: OnboardingStep, store: StoreOf<OnboardingFeature>) {
        let displayStep = newStep.displayStep
        if newStep != .onboardingComplete && (displayStep == .firstInsight || displayStep == .notifications) {
            store.send(.prepareFirstInsight)
        }
    }

    private func openQuickAddSupplement() {
        guard selectedSupplementQuickPick != nil else { return }
        optionalSetupSheet = .supplementQuickAdd
    }

    private func openCustomSupplement() {
        optionalSetupSheet = .supplementCustom
    }

    private func openLabsImport() {
        optionalSetupSheet = .labsImport
    }

    private func quickWinMacroSummaryText(_ result: OnboardingFeature.QuickWinResult) -> String? {
        guard result.hasMacroSummary else { return nil }
        if NutritionSafetyPolicy.hidesCalories {
            return localizedNutritionMacroTotals(protein: result.proteinG, fat: result.fatG, carbs: result.carbsG, fiber: result.fiberG)
        }
        let calories = Int(result.calories.rounded())
        let protein = Int(result.proteinG.rounded())
        let fat = Int(result.fatG.rounded())
        let carbs = Int(result.carbsG.rounded())
        if let fiber = result.fiberG, fiber > 0 {
            return String(
                format: String(localized: "nutrition_photo_macros_with_fiber_format"),
                calories,
                protein,
                fat,
                carbs,
                Int(fiber.rounded())
            )
        }
        return String(
            format: String(localized: "nutrition_photo_macros_without_fiber_format"),
            calories,
            protein,
            fat,
            carbs
        )
    }

    private func quickWinResultNote(_ result: OnboardingFeature.QuickWinResult?) -> String {
        let fallback = String(localized: "onboarding_quick_win_result_note")
        guard let result else { return fallback }
        return result.note ?? fallback
    }

    private func openQuickWinCapture() {
        quickWinLoggedAt = Date()
        quickWinModal = .photoCapture
    }

    private func presentQuickWinReview(_ draft: NutritionLogDraft) {
        quickWinModal = nil
        Task { @MainActor in
            await Task.yield()
            quickWinModal = .review(draft)
        }
    }

    private func advanceFromProfileAction(store: StoreOf<OnboardingFeature>) -> () -> Void {
        { store.send(.advanceFromProfile) }
    }

    private func advanceFromValuePropAction(store: StoreOf<OnboardingFeature>) -> () -> Void {
        { store.send(.advanceFromValueProp) }
    }

    private func runQuickWinAction(store: StoreOf<OnboardingFeature>) -> () -> Void {
        {
            if UITestBootstrap.isEnabled {
                store.send(.completeQuickWin)
            } else {
                openQuickWinCapture()
            }
        }
    }

    private func advanceFromQuickWinAction(store: StoreOf<OnboardingFeature>) -> () -> Void {
        { store.send(.advanceFromQuickWin) }
    }

    private func advanceFromHealthFlagsAction(store: StoreOf<OnboardingFeature>) -> () -> Void {
        { store.send(.advanceFromHealthFlags) }
    }

    private func advanceFromWeightAction(store: StoreOf<OnboardingFeature>) -> () -> Void {
        { store.send(.advanceFromWeight) }
    }

    private func requestHealthKitAction(store: StoreOf<OnboardingFeature>) -> () -> Void {
        { store.send(.requestHealthKit) }
    }

    private func skipHealthKitAction(store: StoreOf<OnboardingFeature>) -> () -> Void {
        { store.send(.skipHealthKit) }
    }

    private func advanceFromFirstInsightAction(store: StoreOf<OnboardingFeature>) -> () -> Void {
        { store.send(.advanceFromFirstInsight) }
    }

    private func retryFirstInsightAction(store: StoreOf<OnboardingFeature>) -> () -> Void {
        { store.send(.prepareFirstInsight) }
    }

    private func enableNotificationsAction(store: StoreOf<OnboardingFeature>) -> () -> Void {
        { store.send(.enableNotifications) }
    }

    private func completeOnboardingAction(store: StoreOf<OnboardingFeature>) -> () -> Void {
        { store.send(.complete) }
    }

    private func refreshAuthenticatedShellAction() -> () -> Void {
        {
            Task {
                await authManager?.refreshPostAuthState()
            }
        }
    }
}

private enum OnboardingOptionalSetupSheet: String, Identifiable {
    case supplementQuickAdd
    case supplementCustom
    case labsImport

    var id: String { rawValue }
}

private enum OnboardingSupplementQuickPick: String, CaseIterable {
    case magnesium
    case vitaminD3
    case omega3
    case creatine
    case zinc
    case lTheanine

    var displayName: String {
        switch self {
        case .magnesium:
            return String(localized: "supplement_quick.magnesium")
        case .vitaminD3:
            return String(localized: "supplement_quick.vitamin_d3")
        case .omega3:
            return String(localized: "supplement_quick.omega3")
        case .creatine:
            return String(localized: "supplement_quick.creatine")
        case .zinc:
            return String(localized: "supplement_quick.zinc")
        case .lTheanine:
            return String(localized: "supplement_quick.l_theanine")
        }
    }
}

private enum OnboardingSupplementTimingPreference: CaseIterable {
    case morning
    case withFood
    case beforeBed
    case anytime

    var title: String {
        switch self {
        case .morning:
            return String(localized: "onboarding_optional_timing_morning")
        case .withFood:
            return String(localized: "onboarding_optional_timing_with_food")
        case .beforeBed:
            return String(localized: "onboarding_optional_timing_before_bed")
        case .anytime:
            return String(localized: "onboarding_optional_timing_anytime")
        }
    }

    var defaultScheduledTime: Date {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let components: DateComponents

        switch self {
        case .morning:
            components = DateComponents(hour: 8, minute: 0)
        case .withFood:
            components = DateComponents(hour: 12, minute: 30)
        case .beforeBed:
            components = DateComponents(hour: 21, minute: 0)
        case .anytime:
            components = DateComponents(hour: 9, minute: 0)
        }

        return calendar.date(
            bySettingHour: components.hour ?? 9,
            minute: components.minute ?? 0,
            second: 0,
            of: now
        ) ?? now
    }
}

// MARK: - Reusable Step View

struct OnboardingStepView: View {
    let icon: String
    let title: String
    let description: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: Spacing.l) {
            Spacer()

            Image(systemName: icon)
                .font(LifeOSTypography.title)
                .foregroundStyle(LifeOSColors.Semantic.primary)

            Text(title)
                .font(LifeOSTypography.headline)

            Text(description)
                .font(LifeOSTypography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)

            Spacer()

            Button(action: action) {
                Text(buttonTitle)
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: LayoutConstants.minTouchTarget)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, Spacing.l)
            .accessibilityIdentifier("onboarding.continue")
        }
    }
}

#if DEBUG
extension OnboardingView {
    @MainActor
    func _testEvaluateBody() {
        _ = body
    }

    @MainActor
    func _testEvaluateStepBuilders() {
        _ = valuePropStep(store: store)
        _ = quickWinStep(store: store)
        _ = profileStep(store: store)
        _ = healthFlagsStep(store: store)
        _ = weightStep(store: store)
        _ = healthKitStep(store: store)
        _ = firstInsightStep(store: store)
        _ = notificationsStep(store: store)
        _ = completeStep(store: store)
        _ = progressSection(store: store)
        _ = benefitRow(icon: "sparkles", text: "Benefit")
        _ = firstInsightCard(.init(
            insightId: UUID(),
            title: "Insight",
            body: "Body",
            score: 72,
            zone: .ready,
            detail: "Detail",
            footer: "Footer",
            isPreview: false
        ))
        _ = dataPointRow(icon: "heart", text: "Heart Rate Variability", weight: "40%")
        _ = nextStepRow(icon: "bell", text: "Enable notifications")
    }

    @MainActor
    func _testTriggerActions() {
        advanceFromValuePropAction(store: store)()
        runQuickWinAction(store: store)()
        advanceFromQuickWinAction(store: store)()
        advanceFromProfileAction(store: store)()
        advanceFromHealthFlagsAction(store: store)()
        advanceFromWeightAction(store: store)()
        requestHealthKitAction(store: store)()
        skipHealthKitAction(store: store)()
        advanceFromFirstInsightAction(store: store)()
        enableNotificationsAction(store: store)()
        completeOnboardingAction(store: store)()
    }

    @MainActor
    func _testTriggerInstanceStepChangeHandlers() {
        handleCurrentStepChange(.authComplete, store: store)
        handleCurrentStepChange(.onboardingComplete, store: store)
    }
}

extension OnboardingStepView {
    @MainActor
    func _testEvaluateBody() {
        _ = body
    }
}
#endif

#Preview {
    OnboardingView()
        .environment(AuthManager())
}
