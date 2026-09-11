import SwiftUI
import Observation
import GRDB
import UIKit

private func localizedTrainingIdentifier(_ value: String) -> String {
    switch value.lowercased() {
    case "strength":
        return String(localized: "training_identifier_strength")
    case "cardio":
        return String(localized: "training_identifier_cardio")
    case "mobility":
        return String(localized: "training_identifier_mobility")
    case "recovery":
        return String(localized: "training_identifier_recovery")
    case "mixed":
        return String(localized: "training_identifier_mixed")
    case "sport":
        return String(localized: "training_identifier_sport")
    case "other":
        return String(localized: "training_identifier_other")
    case "beginner":
        return String(localized: "training_identifier_beginner")
    case "intermediate":
        return String(localized: "training_identifier_intermediate")
    case "advanced":
        return String(localized: "training_identifier_advanced")
    case "bodyweight":
        return String(localized: "training_identifier_bodyweight")
    case "home_gym":
        return String(localized: "training_identifier_home_gym")
    case "gym":
        return String(localized: "training_identifier_gym")
    case "hypertrophy":
        return String(localized: "training_identifier_hypertrophy")
    case "endurance":
        return String(localized: "training_identifier_endurance")
    case "weight_loss":
        return String(localized: "training_identifier_weight_loss")
    case "sport_specific":
        return String(localized: "training_identifier_sport_specific")
    case "general_fitness":
        return String(localized: "training_identifier_general_fitness")
    case "active":
        return String(localized: "training_identifier_active")
    case "paused":
        return String(localized: "training_identifier_paused")
    case "completed":
        return String(localized: "training_identifier_completed")
    case "archived":
        return String(localized: "training_identifier_archived")
    case "planned":
        return String(localized: "training_identifier_planned")
    case "skipped":
        return String(localized: "training_identifier_skipped")
    case "rescheduled":
        return String(localized: "training_identifier_rescheduled")
    case "recovery_low":
        return String(localized: "training_identifier_recovery_low")
    case "recovery_critical":
        return String(localized: "training_identifier_recovery_critical")
    case "fatigue_accumulation":
        return String(localized: "training_identifier_fatigue_accumulation")
    case "injury_flag":
        return String(localized: "training_identifier_injury_flag")
    case "user_request":
        return String(localized: "training_identifier_user_request")
    case "schedule_conflict":
        return String(localized: "training_identifier_schedule_conflict")
    case "load_spike_acwr":
        return String(localized: "training_identifier_load_spike_acwr")
    case "reduce_volume_30":
        return String(localized: "training_identifier_reduce_volume_30")
    case "reduce_intensity_20":
        return String(localized: "training_identifier_reduce_intensity_20")
    case "skip_session":
        return String(localized: "training_identifier_skip_session")
    case "swap_to_mobility":
        return String(localized: "training_identifier_swap_to_mobility")
    case "extend_rest_day":
        return String(localized: "training_identifier_extend_rest_day")
    case "deload_week":
        return String(localized: "training_identifier_deload_week")
    default:
        let normalized = value.replacingOccurrences(of: "_", with: " ")
        guard let first = normalized.first else { return value }
        return first.uppercased() + normalized.dropFirst()
    }
}

func localizedTrainingMinutes(_ minutes: Int) -> String {
    String(format: String(localized: "training_duration_minutes_short_format"), minutes)
}

private func localizedTrainingRestLabel(_ value: String) -> String {
    String(format: String(localized: "training_rest_timer_format"), value)
}

struct TrainingDayView: View {
    let dateString: String?
    @State private var viewModel: TrainingDayViewModel
    @State private var isShowingCalendar = false

    init(dateString: String?) {
        self.dateString = dateString
        _viewModel = State(initialValue: TrainingDayViewModel(dateString: dateString))
    }

#if DEBUG
    fileprivate init(dateString: String?, testViewModel: TrainingDayViewModel) {
        self.dateString = dateString
        _viewModel = State(initialValue: testViewModel)
    }
#endif

    var body: some View {
        @Bindable var viewModel = viewModel

        ScrollView {
            VStack(spacing: Spacing.m) {
                Label(String(localized: "training"), systemImage: "figure.run")
                    .font(LifeOSTypography.title3)

                Text(viewModel.displayDate)
                    .font(LifeOSTypography.subheadline)
                    .foregroundStyle(LifeOSColors.Text.secondary)

                TrainingWeekOverviewCard(
                    selectedDay: viewModel.dayString,
                    selectedDate: viewModel.selectedDate,
                    onSelectDay: { day in
                        Task { await viewModel.selectDay(day) }
                    },
                    onOpenMonth: {
                        isShowingCalendar = true
                    }
                )

                if viewModel.isLoading &&
                    viewModel.sessions.isEmpty &&
                    viewModel.plannedSession == nil &&
                    viewModel.planOverview == nil {
                    ProgressView()
                        .padding(.top, Spacing.s)
                }

                trainingPlanSection(viewModel)

                if let plannedSession = viewModel.plannedSession {
                    plannedSessionCard(
                        plannedSession,
                        selectedDate: viewModel.selectedDate,
                        onWorkoutChanged: {
                            Task { await viewModel.load() }
                        }
                    )
                }

                if viewModel.sessions.isEmpty && viewModel.plannedSession == nil {
                    Text(String(localized: "no_workouts_today"))
                        .font(LifeOSTypography.body)
                        .foregroundStyle(LifeOSColors.Text.secondary)
                } else if !viewModel.sessions.isEmpty {
                    LazyVStack(spacing: Spacing.s) {
                        ForEach(viewModel.sessions) { session in
                            NavigationLink {
                                WorkoutLogView(
                                    existingSessionId: session.id,
                                    targetDate: viewModel.selectedDate,
                                    onWorkoutChanged: {
                                        Task { await viewModel.load() }
                                    }
                                )
                            } label: {
                                sessionRow(session)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.top, Spacing.m)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(LayoutConstants.contentPadding)
        .accessibilityIdentifier("training.day.screen")
        .background(LifeOSColors.Surface.background)
        .navigationTitle(String(localized: "training"))
        .task(runLoadTaskAction)
        .sheet(isPresented: $viewModel.isShowingPlanComposer) {
            TrainingPlanComposerSheet(
                isSaving: viewModel.isPerformingPlanAction,
                onCreate: { draft in
                    await viewModel.createPlan(draft)
                }
            )
        }
        .sheet(isPresented: $viewModel.isShowingPlanAdjustmentSheet) {
            if let plan = viewModel.planOverview {
                TrainingPlanAdjustmentSheet(
                    plan: plan,
                    isSaving: viewModel.isPerformingPlanAction,
                    onApply: { draft in
                        await viewModel.adjustPlan(draft)
                    }
                )
            }
        }
        .sheet(isPresented: $viewModel.isShowingPlanManager) {
            if let plan = viewModel.planOverview {
                TrainingPlanManageSheet(
                    plan: plan,
                    isSaving: viewModel.isPerformingPlanAction,
                    onSave: { draft in
                        await viewModel.updatePlan(draft)
                    }
                )
            }
        }
        .sheet(isPresented: $isShowingCalendar) {
            TrainingCalendarView(selectedDate: viewModel.selectedDate) { day in
                Task { await viewModel.selectDay(day) }
            }
        }
    }

    private func sessionRow(_ session: TrainingSessionSummary) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: session.iconName)
                .frame(width: LayoutConstants.minTouchTarget, height: LayoutConstants.minTouchTarget)
                .foregroundStyle(LifeOSColors.Semantic.primary)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(session.primaryText)
                    .font(LifeOSTypography.body)
                if let secondary = session.secondaryText {
                    Text(secondary)
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(LifeOSColors.Text.secondary)
                }
            }
            Spacer()
        }
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.accessibilitySummary)
        .accessibilityIdentifier("training.session.\(session.id.uuidString)")
    }

    private func trainingPlanSection(_ viewModel: TrainingDayViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Label(String(localized: "training_plan_title"), systemImage: "figure.strengthtraining.traditional")
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                Spacer()
                if viewModel.canCreatePlan {
                    Button(String(localized: "training_generate")) {
                        viewModel.presentPlanComposer()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LifeOSColors.Semantic.primary)
                    .disabled(viewModel.isPerformingPlanAction)
                }
            }

            if let planMessage = viewModel.planMessage {
                inlinePlanStatusBanner(
                    planMessage,
                    isError: viewModel.isPlanMessageError
                )
            }

            if let plan = viewModel.planOverview {
                trainingPlanOverviewCard(plan, viewModel: viewModel)
            } else {
                trainingPlanEmptyState(viewModel)
            }

            if !viewModel.upcomingPlanSessions.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(String(localized: "training_coming_up"))
                        .font(LifeOSTypography.caption.weight(.semibold))
                        .foregroundStyle(LifeOSColors.Text.secondary)

                    ForEach(viewModel.upcomingPlanSessions) { session in
                        upcomingPlanSessionRow(session)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trainingPlanEmptyState(_ viewModel: TrainingDayViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(String(localized: "training_no_plan_yet"))
                .font(LifeOSTypography.body.weight(.semibold))

            Text(viewModel.planAvailabilityMessage)
                .font(LifeOSTypography.caption)
                .foregroundStyle(LifeOSColors.Text.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private func plannedSessionCard(
        _ plannedSession: PlannedTrainingSessionSummary,
        selectedDate: Date,
        onWorkoutChanged: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(String(localized: "training_plan_today_title"), systemImage: "calendar.badge.clock")
                .font(LifeOSTypography.subheadline.weight(.semibold))

            Text(plannedSession.sessionTitle)
                .font(LifeOSTypography.body.weight(.semibold))
                .foregroundStyle(.primary)

            Text(plannedSession.planName)
                .font(LifeOSTypography.caption)
                .foregroundStyle(LifeOSColors.Text.secondary)

            HStack(spacing: Spacing.s) {
                Text(humanizedIdentifier(plannedSession.sessionType))
                Text(String(format: String(localized: "training_plan_week_format"), plannedSession.currentWeek))
                Text(humanizedIdentifier(plannedSession.status))
            }
            .font(LifeOSTypography.caption)
            .foregroundStyle(LifeOSColors.Text.secondary)

            if let plannedDurationMinutes = plannedSession.plannedDurationMinutes {
                Text(localizedTrainingMinutes(plannedDurationMinutes))
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(LifeOSColors.Text.tertiary)
            }

            NavigationLink {
                WorkoutLogView(
                    targetDate: selectedDate,
                    initialWorkoutType: plannedSession.resolvedWorkoutType,
                    initialTrainingPlanId: plannedSession.planId,
                    onWorkoutChanged: onWorkoutChanged
                )
            } label: {
                Label(String(localized: "training_start_planned_workout"), systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(LifeOSColors.Semantic.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
        .accessibilityIdentifier("training.plan.session.\(plannedSession.id.uuidString)")
    }

    private func trainingPlanOverviewCard(
        _ plan: TrainingPlanOverview,
        viewModel: TrainingDayViewModel
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(
                plan.status == TrainingPlanStatus.active.rawValue
                    ? String(localized: "training_plan_active_title")
                    : String(localized: "training_plan_latest_title"),
                systemImage: "figure.strengthtraining.traditional"
            )
                .font(LifeOSTypography.subheadline.weight(.semibold))

            Text(plan.name)
                .font(LifeOSTypography.body.weight(.semibold))
                .foregroundStyle(.primary)

            HStack(spacing: Spacing.s) {
                Text(humanizedIdentifier(plan.goal))
                Text(String(format: String(localized: "training_plan_week_format"), plan.currentWeek))
                Text(humanizedIdentifier(plan.status))
            }
            .font(LifeOSTypography.caption)
            .foregroundStyle(LifeOSColors.Text.secondary)

            if let summaryLine = plan.summaryLine {
                Text(summaryLine)
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(LifeOSColors.Text.tertiary)
            }

            if !plan.adaptiveRules.isEmpty {
                Text(plan.adaptiveRuleSummary)
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(LifeOSColors.Semantic.primary)
            }

            HStack(spacing: Spacing.s) {
                if plan.canAdjust {
                    Button(String(localized: "training_adjust")) {
                        viewModel.presentPlanAdjustment()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LifeOSColors.Semantic.primary)
                    .disabled(!viewModel.canUseRemotePlanActions || viewModel.isPerformingPlanAction)

                    Button(String(localized: "training_manage")) {
                        viewModel.presentPlanManager()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.canUseRemotePlanActions || viewModel.isPerformingPlanAction)
                } else {
                    Button(String(localized: "training_manage")) {
                        viewModel.presentPlanManager()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LifeOSColors.Semantic.primary)
                    .disabled(!viewModel.canUseRemotePlanActions || viewModel.isPerformingPlanAction)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
        .accessibilityIdentifier("training.plan.active.\(plan.id.uuidString)")
    }

    private func inlinePlanStatusBanner(_ message: String, isError: Bool) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? LifeOSColors.Recovery.caution : LifeOSColors.Recovery.ready)
            Text(message)
                .font(LifeOSTypography.caption)
                .foregroundStyle(LifeOSColors.Text.secondary)
        }
        .padding(Spacing.s)
        .background((isError ? LifeOSColors.Recovery.caution : LifeOSColors.Recovery.ready).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private func upcomingPlanSessionRow(_ session: UpcomingTrainingPlanSessionSummary) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: session.iconName)
                .frame(width: LayoutConstants.minTouchTarget, height: LayoutConstants.minTouchTarget)
                .foregroundStyle(LifeOSColors.Semantic.primary)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xxs) {
                    Text(session.title)
                        .font(LifeOSTypography.body)
                    if session.isSelectedDate {
                        Text(String(localized: "training_selected_day"))
                            .font(LifeOSTypography.caption2.weight(.semibold))
                            .foregroundStyle(LifeOSColors.Semantic.primary)
                            .padding(.horizontal, Spacing.xxs)
                            .padding(.vertical, 2)
                            .background(LifeOSColors.Semantic.primary.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
                Text(session.subtitle)
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(LifeOSColors.Text.secondary)
            }
            Spacer()
        }
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
        .accessibilityIdentifier("training.plan.upcoming.\(session.id.uuidString)")
    }

    private func humanizedIdentifier(_ value: String) -> String {
        localizedTrainingIdentifier(value)
    }

    private func runLoadTask(_ viewModel: TrainingDayViewModel) async {
        await viewModel.load()
    }

    private func runLoadTaskAction() async {
        await runLoadTask(viewModel)
    }
}

struct WorkoutLogView: View {
    let existingSessionId: UUID?
    let targetDate: Date
    let initialWorkoutType: WorkoutType?
    let initialTrainingPlanId: UUID?
    let onWorkoutChanged: (() -> Void)?

    @State private var viewModel: WorkoutLogViewModel
    @Environment(\.dismiss) private var dismiss

    init(
        existingSessionId: UUID? = nil,
        targetDate: Date = Date(),
        initialWorkoutType: WorkoutType? = nil,
        initialTrainingPlanId: UUID? = nil,
        onWorkoutChanged: (() -> Void)? = nil,
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue,
        workoutManager: (any WorkoutSessionManaging)? = nil
    ) {
        self.existingSessionId = existingSessionId
        self.targetDate = targetDate
        self.initialWorkoutType = initialWorkoutType
        self.initialTrainingPlanId = initialTrainingPlanId
        self.onWorkoutChanged = onWorkoutChanged
        _viewModel = State(
            initialValue: WorkoutLogViewModel(
                existingSessionId: existingSessionId,
                workoutManager: workoutManager,
                dbQueue: dbQueue,
                targetDate: targetDate,
                initialWorkoutType: initialWorkoutType,
                initialTrainingPlanId: initialTrainingPlanId
            )
        )
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        ScrollView {
            VStack(spacing: Spacing.m) {
                if viewModel.isLoading && viewModel.hasExistingWorkout && viewModel.exercises.isEmpty {
                    ProgressView()
                        .padding(.top, Spacing.s)
                }

                if let errorMessage = viewModel.errorMessage {
                    statusBanner(
                        errorMessage,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: LifeOSColors.Recovery.caution
                    )
                }

                workoutOverviewCard

                if let restTimer = viewModel.activeRestTimer, !viewModel.isDeleted {
                    restTimerCard(restTimer)
                }

                if viewModel.isDeleted {
                    statusBanner(
                        viewModel.deletedStatusText ?? String(localized: "training_workout_deleted"),
                        systemImage: "trash.circle.fill",
                        tint: .red
                    )
                }

                workoutMetadataSection
                exercisePickerSection

                if viewModel.shouldShowHealthKitImportSection {
                    healthKitImportSection
                }

                if viewModel.canDelete || viewModel.canUndoDelete {
                    workoutLifecycleSection
                }
            }
            .padding(.top, Spacing.m)
        }
        .task { await viewModel.loadWorkoutDetailIfNeeded() }
        .accessibilityIdentifier("training.workout_log.screen")
        .background(LifeOSColors.Surface.background)
        .navigationTitle(viewModel.screenTitle)
        .toolbar {
            if !viewModel.hasExistingWorkout {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(viewModel.saveButtonTitle) {
                    Task { await handleSave() }
                }
                .disabled(!viewModel.canSave)
                .accessibilityIdentifier("training.workout.save")
            }
        }
    }

    private var workoutOverviewCard: some View {
        let summary = viewModel.summaryMetrics

        return VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .top, spacing: Spacing.s) {
                Label(viewModel.overviewTitle, systemImage: viewModel.overviewIconName)
                    .font(LifeOSTypography.title3.weight(.semibold))
                Spacer()
                Text(viewModel.sourceBadgeTitle)
                    .font(LifeOSTypography.caption.weight(.semibold))
                    .foregroundStyle(viewModel.workoutSource == .import ? LifeOSColors.Recovery.caution : LifeOSColors.Semantic.primary)
                    .padding(.horizontal, Spacing.s)
                    .padding(.vertical, Spacing.xxs)
                    .background((viewModel.workoutSource == .import ? LifeOSColors.Recovery.caution : LifeOSColors.Semantic.primary).opacity(0.12))
                    .clipShape(Capsule())
            }

            if let overviewSubtitle = viewModel.overviewSubtitle {
                Text(overviewSubtitle)
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: Spacing.s) {
                summaryPill(title: String(localized: "training_summary_duration"), value: summary.durationText)
                summaryPill(title: String(localized: "sets"), value: "\(summary.totalSets)")
                summaryPill(title: String(localized: "training_summary_volume"), value: summary.volumeText(units: viewModel.userUnits))
            }

            if viewModel.incompleteSetCount > 0 && !viewModel.isDeleted {
                Text(
                    String(
                        format: String(localized: "training_incomplete_sets_warning_format"),
                        viewModel.incompleteSetCount
                    )
                )
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(LifeOSColors.Recovery.caution)
            }

            if let importNotice = viewModel.importedWorkoutNotice {
                Text(importNotice)
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
        .padding(.horizontal, LayoutConstants.contentPadding)
    }

    private func summaryPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(LifeOSTypography.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(LifeOSTypography.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.background)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private func restTimerCard(_ timer: WorkoutRestTimerState) -> some View {
        HStack(spacing: Spacing.s) {
            Label(localizedTrainingRestLabel(timer.remainingText), systemImage: "timer")
                .font(LifeOSTypography.subheadline.weight(.semibold))
                .foregroundStyle(LifeOSColors.Semantic.primary)
            Spacer()
            Button(String(localized: "training_rest_add_15_seconds")) {
                viewModel.extendRestTimer(by: 15)
            }
            .buttonStyle(.bordered)

            Button(String(localized: "training_rest_dismiss")) {
                viewModel.dismissRestTimer()
            }
            .buttonStyle(.bordered)
        }
        .padding(Spacing.s)
        .background(LifeOSColors.Semantic.primary.opacity(0.08))
        .clipShape(Capsule())
        .padding(.horizontal, LayoutConstants.contentPadding)
    }

    private func statusBanner(_ message: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .padding(.top, 2)
            Text(message)
                .font(LifeOSTypography.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(Spacing.s)
        .background(tint.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
        .padding(.horizontal, LayoutConstants.contentPadding)
    }

    private var workoutMetadataSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(String(localized: "workout_type"))
                .font(LifeOSTypography.subheadline.weight(.semibold))

            Picker(String(localized: "workout_type"), selection: $viewModel.selectedWorkoutType) {
                Text(String(localized: "training_unspecified")).tag(Optional<WorkoutType>.none)
                ForEach(WorkoutType.allCases, id: \.self) { type in
                    Text(localizedTrainingIdentifier(type.rawValue)).tag(Optional(type))
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(String(localized: "notes"))
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                TextField(
                    String(localized: "workout_notes_placeholder"),
                    text: $viewModel.notes,
                    axis: .vertical
                )
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(viewModel.rpeLabelText)
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                Slider(
                    value: Binding(
                        get: { viewModel.rpe },
                        set: { viewModel.setRPE($0) }
                    ),
                    in: 1...10,
                    step: 1
                )
                .tint(LifeOSColors.Semantic.primary)
            }
        }
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
        .padding(.horizontal, LayoutConstants.contentPadding)
    }

    private var exercisePickerSection: some View {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(String(localized: "exercises"))
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                    .padding(.horizontal, LayoutConstants.contentPadding)

            if viewModel.canEditExercises {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(String(localized: "workout_search_exercise"), text: $viewModel.exerciseSearch)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("training.exercise.search")
                    if !viewModel.exerciseSearch.isEmpty {
                        Button { viewModel.exerciseSearch = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(Spacing.s)
                .background(LifeOSColors.Surface.card)
                .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
                .padding(.horizontal, LayoutConstants.contentPadding)

                if viewModel.shouldShowExerciseSuggestions {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.filteredCatalog.prefix(5), id: \.id) { entry in
                            Button {
                                viewModel.addExercise(entry)
                                viewModel.exerciseSearch = ""
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name)
                                            .font(LifeOSTypography.body)
                                            .foregroundStyle(.primary)
                                        Text(localizedTrainingIdentifier(entry.category.rawValue))
                                            .font(LifeOSTypography.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(LifeOSColors.Semantic.primary)
                                }
                                .padding(.vertical, Spacing.xs)
                                .padding(.horizontal, LayoutConstants.contentPadding)
                            }
                            .accessibilityIdentifier("training.exercise.result.\(entry.name)")
                            if entry.id != viewModel.filteredCatalog.prefix(5).last?.id || viewModel.canCreateCustomExercise {
                                Divider()
                            }
                        }

                        if viewModel.canCreateCustomExercise {
                            Button {
                                Task { await viewModel.addExerciseFromSearch() }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(viewModel.customExerciseButtonTitle)
                                            .font(LifeOSTypography.body)
                                            .foregroundStyle(.primary)
                                        Text(viewModel.customExerciseButtonSubtitle)
                                            .font(LifeOSTypography.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(LifeOSColors.Semantic.primary)
                                }
                                .padding(.vertical, Spacing.xs)
                                .padding(.horizontal, LayoutConstants.contentPadding)
                            }
                            .accessibilityIdentifier("training.exercise.create-custom")
                        }
                    }
                    .background(LifeOSColors.Surface.card)
                    .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
                    .padding(.horizontal, LayoutConstants.contentPadding)
                }
            }

            if viewModel.exercises.isEmpty {
                Text(
                    viewModel.canEditExercises
                        ? String(localized: "training_add_exercise_hint")
                        : String(localized: "training_no_exercises_for_workout")
                )
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, LayoutConstants.contentPadding)
            } else {
                ForEach(Array(viewModel.exercises.enumerated()), id: \.element.id) { index, exercise in
                    exerciseRow(exerciseIndex: index, exercise: exercise)
                }
            }
        }
    }

    private func exerciseRow(exerciseIndex: Int, exercise: WorkoutLogExercise) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .foregroundStyle(LifeOSColors.Semantic.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.name)
                        .font(LifeOSTypography.body)
                        .accessibilityIdentifier("training.exercise.name.\(exercise.name)")
                    Text(localizedTrainingIdentifier(exercise.category.rawValue))
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.canEditExercises {
                    Button {
                        viewModel.removeExercise(exercise.id)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                }
            }

            ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { setIndex, _ in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.s) {
                        if viewModel.canTrackSetCompletion {
                            Button {
                                viewModel.toggleSetCompletion(exerciseId: exercise.id, at: setIndex)
                            } label: {
                                Image(systemName: exercise.sets[setIndex].isCompleted ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(exercise.sets[setIndex].isCompleted ? LifeOSColors.Recovery.ready : .secondary)
                            }
                            .buttonStyle(.plain)
                        }

                        Text("\(setIndex + 1)")
                            .font(LifeOSTypography.caption.weight(.bold))
                            .frame(width: 24)

                        editorField(
                            title: "\(String(localized: "weight")) (\(UnitPreferences.weightUnitLabel(viewModel.userUnits)))",
                            text: weightTextBinding(exerciseIndex: exerciseIndex, setIndex: setIndex),
                            width: 72,
                            keyboardType: .decimalPad,
                            accessibilityIdentifier: "training.exercise.weight.\(exerciseIndex).\(setIndex)",
                            isEditable: viewModel.canEditExercises
                        )

                        editorField(
                            title: String(localized: "reps"),
                            text: repsTextBinding(exerciseIndex: exerciseIndex, setIndex: setIndex),
                            width: 60,
                            keyboardType: .numberPad,
                            accessibilityIdentifier: "training.exercise.reps.\(exerciseIndex).\(setIndex)",
                            isEditable: viewModel.canEditExercises
                        )

                        editorField(
                            title: String(localized: "training_rpe"),
                            text: rpeTextBinding(exerciseIndex: exerciseIndex, setIndex: setIndex),
                            width: 56,
                            keyboardType: .numberPad,
                            accessibilityIdentifier: "training.exercise.rpe.\(exerciseIndex).\(setIndex)",
                            isEditable: viewModel.canEditExercises
                        )

                        Spacer(minLength: 0)

                        if viewModel.canEditExercises {
                            Button {
                                viewModel.toggleWarmup(exerciseId: exercise.id, at: setIndex)
                            } label: {
                                Image(systemName: exercise.sets[setIndex].isWarmup ? "flame.fill" : "flame")
                                    .foregroundStyle(exercise.sets[setIndex].isWarmup ? .orange : .secondary)
                            }
                            .buttonStyle(.plain)

                            Menu {
                                Button(String(localized: "training_rest_off")) {
                                    viewModel.setRestDuration(exerciseId: exercise.id, at: setIndex, seconds: nil)
                                }
                                ForEach([45, 60, 90, 120, 180], id: \.self) { seconds in
                                    Button(Self.restDurationLabel(seconds: seconds)) {
                                        viewModel.setRestDuration(exerciseId: exercise.id, at: setIndex, seconds: seconds)
                                    }
                                }
                            } label: {
                                Text(Self.restDurationLabel(seconds: exercise.sets[setIndex].restAfterSeconds))
                                    .font(LifeOSTypography.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Button {
                                viewModel.removeSet(from: exercise.id, at: setIndex)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(Self.restDurationLabel(seconds: exercise.sets[setIndex].restAfterSeconds))
                                .font(LifeOSTypography.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if exercise.sets[setIndex].hasIncompleteMetrics && viewModel.canEditExercises {
                        Text(String(localized: "training_incomplete_set_warning"))
                            .font(LifeOSTypography.caption2)
                            .foregroundStyle(LifeOSColors.Recovery.caution)
                    }
                }
            }

            if viewModel.canEditExercises {
                Button {
                    viewModel.addSet(to: exercise.id)
                } label: {
                    Label(String(localized: "workout_add_set"), systemImage: "plus.circle")
                        .font(LifeOSTypography.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("training.exercise.add_set.\(exercise.name)")
            }
        }
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
        .padding(.horizontal, LayoutConstants.contentPadding)
    }

    private func editorField(
        title: String,
        text: Binding<String>,
        width: CGFloat,
        keyboardType: UIKeyboardType,
        accessibilityIdentifier: String,
        isEditable: Bool
    ) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(LifeOSTypography.caption2)
            TextField("0", text: text)
                .textFieldStyle(.roundedBorder)
                .keyboardType(keyboardType)
                .frame(width: width)
                .disabled(!isEditable)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    private func weightTextBinding(exerciseIndex: Int, setIndex: Int) -> Binding<String> {
        Binding(
            get: {
                let kilograms = viewModel.exercises[exerciseIndex].sets[setIndex].weight
                guard kilograms > 0 else { return "" }
                return UnitPreferences.formattedDecimal(
                    UnitPreferences.weightValue(fromKilograms: kilograms, units: viewModel.userUnits),
                    maxDecimals: 1
                )
            },
            set: { raw in
                let displayed = Self.parseWeight(raw)
                guard displayed > 0 else {
                    viewModel.exercises[exerciseIndex].sets[setIndex].weight = 0
                    return
                }
                viewModel.exercises[exerciseIndex].sets[setIndex].weight = UnitPreferences.kilograms(
                    fromDisplayedWeight: displayed,
                    units: viewModel.userUnits
                )
            }
        )
    }

    private func repsTextBinding(exerciseIndex: Int, setIndex: Int) -> Binding<String> {
        Binding(
            get: { Self.formattedReps(viewModel.exercises[exerciseIndex].sets[setIndex].reps) },
            set: { viewModel.exercises[exerciseIndex].sets[setIndex].reps = Self.parseReps($0) }
        )
    }

    private func rpeTextBinding(exerciseIndex: Int, setIndex: Int) -> Binding<String> {
        Binding(
            get: { Self.formattedRPE(viewModel.exercises[exerciseIndex].sets[setIndex].rpe) },
            set: { viewModel.exercises[exerciseIndex].sets[setIndex].rpe = Self.parseRPE($0) }
        )
    }

    fileprivate static func formattedWeight(_ value: Double) -> String {
        guard value != 0 else { return "" }
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }

    fileprivate static func parseWeight(_ raw: String) -> Double {
        let sanitized = raw
            .replacingOccurrences(of: ",", with: ".")
            .filter { $0.isNumber || $0 == "." }
        return Double(sanitized) ?? 0
    }

    fileprivate static func formattedReps(_ value: Int) -> String {
        value == 0 ? "" : String(value)
    }

    fileprivate static func parseReps(_ raw: String) -> Int {
        Int(raw.filter(\.isNumber)) ?? 0
    }

    fileprivate static func formattedRPE(_ value: Int) -> String {
        value == 0 ? "" : String(value)
    }

    fileprivate static func parseRPE(_ raw: String) -> Int {
        let parsed = Int(raw.filter(\.isNumber)) ?? 0
        return min(max(parsed, 0), 10)
    }

    fileprivate static func restDurationLabel(seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return String(localized: "training_rest_off") }
        if seconds % 60 == 0 {
            return String(format: String(localized: "training_rest_minutes_format"), seconds / 60)
        }
        return String(format: String(localized: "training_rest_seconds_format"), seconds)
    }

    private var healthKitImportSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Label(String(localized: "settings_apple_health"), systemImage: "heart.text.square")
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                Spacer()
                Button {
                    Task { await viewModel.importFromHealthKit() }
                } label: {
                    if viewModel.isImportingFromHealthKit {
                        ProgressView()
                    } else {
                        Label(
                            viewModel.importedSessions.isEmpty
                                ? String(localized: "training_apple_health_import")
                                : String(localized: "training_apple_health_refresh"),
                            systemImage: "arrow.down.circle"
                        )
                    }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isImportingFromHealthKit)
            }
            .padding(.horizontal, LayoutConstants.contentPadding)

            if let status = viewModel.healthKitStatusMessage {
                Text(status)
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, LayoutConstants.contentPadding)
            }

            if viewModel.importedSessions.isEmpty {
                Text(String(localized: "training_apple_health_empty"))
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, LayoutConstants.contentPadding)
            } else {
                ForEach(viewModel.importedSessions) { session in
                    HStack(alignment: .top, spacing: Spacing.s) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(LifeOSColors.Recovery.ready)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.primaryText)
                                .font(LifeOSTypography.body)
                            Text(session.secondaryText)
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(Spacing.s)
                    .background(LifeOSColors.Surface.card)
                    .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
                    .padding(.horizontal, LayoutConstants.contentPadding)
                }
            }

            if let conflict = viewModel.importConflict {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Label(String(localized: "workout_import_conflict"), systemImage: "exclamationmark.triangle")
                        .font(LifeOSTypography.subheadline.weight(.semibold))
                        .foregroundStyle(LifeOSColors.Recovery.caution)

                    Text(String(format: String(localized: "workout_conflict_desc_format"), conflict.existingType, conflict.importedType))
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: Spacing.s) {
                        Button(String(localized: "workout_conflict_merge")) {
                            Task { await viewModel.resolveConflict(.merge) }
                        }
                        .buttonStyle(.borderedProminent)

                        Button(String(localized: "workout_conflict_keep_existing")) {
                            Task { await viewModel.resolveConflict(.keepExisting) }
                        }
                        .buttonStyle(.bordered)

                        Button(String(localized: "workout_conflict_use_imported")) {
                            Task { await viewModel.resolveConflict(.useImported) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(Spacing.m)
                .background(LifeOSColors.Recovery.caution.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
                .padding(.horizontal, LayoutConstants.contentPadding)
            }

            if let trimp = viewModel.estimatedTrimp ?? viewModel.importedSessions.compactMap(\.trimpScore).max() {
                HStack {
                    Label(String(localized: "training_load"), systemImage: "flame")
                        .font(LifeOSTypography.subheadline)
                    Spacer()
                    Text(String(format: "%.0f", trimp))
                        .font(LifeOSTypography.headline)
                        .foregroundStyle(LifeOSColors.Semantic.primary)
                }
                .padding(Spacing.s)
                .background(LifeOSColors.Surface.card)
                .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
                .padding(.horizontal, LayoutConstants.contentPadding)
            }
        }
    }

    private var workoutLifecycleSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if viewModel.canUndoDelete {
                Button {
                    Task { await handleUndoDelete() }
                } label: {
                    if viewModel.isUndoing {
                        ProgressView()
                    } else {
                        Label(String(localized: "training_undo_delete"), systemImage: "arrow.uturn.backward.circle")
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            if viewModel.canDelete {
                Button(role: .destructive) {
                    Task { await handleDelete() }
                } label: {
                    if viewModel.isDeleting {
                        ProgressView()
                    } else {
                        Label(String(localized: "training_delete_workout"), systemImage: "trash")
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
        .padding(.horizontal, LayoutConstants.contentPadding)
    }

    private func handleSave() async {
        guard await viewModel.save() else { return }
        onWorkoutChanged?()
        if !viewModel.hasExistingWorkout {
            dismiss()
        }
    }

    private func handleDelete() async {
        guard await viewModel.deleteWorkout() else { return }
        onWorkoutChanged?()
    }

    private func handleUndoDelete() async {
        guard await viewModel.undoDeleteWorkout() else { return }
        onWorkoutChanged?()
    }
}

struct WorkoutRestTimerState: Equatable, Sendable {
    let setId: UUID
    let totalSeconds: Int
    var remainingSeconds: Int

    var remainingText: String {
        let minutes = remainingSeconds / 60
        let seconds = remainingSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

fileprivate struct WorkoutSummaryMetrics: Equatable {
    let totalSets: Int
    let totalVolume: Double
    let durationMinutes: Int?

    var durationText: String {
        guard let durationMinutes, durationMinutes > 0 else { return String(localized: "training_not_available") }
        if durationMinutes >= 60 {
            let hours = durationMinutes / 60
            let minutes = durationMinutes % 60
            if minutes == 0 {
                return String(format: String(localized: "training_duration_hours_only_format"), hours)
            }
            return String(format: String(localized: "training_duration_hours_minutes_format"), hours, minutes)
        }
        return String(format: String(localized: "training_duration_minutes_short_format"), durationMinutes)
    }

    func volumeText(units: UnitSystem = .metric) -> String {
        guard totalVolume > 0 else { return String(localized: "training_not_available") }
        let displayed = UnitPreferences.weightValue(fromKilograms: totalVolume, units: units)
        return "\(UnitPreferences.formattedDecimal(displayed, maxDecimals: 1)) \(UnitPreferences.weightUnitLabel(units))"
    }
}

@MainActor
@Observable
final class WorkoutLogViewModel {
    let existingSessionId: UUID?

    var selectedWorkoutType: WorkoutType? = .strength
    var exerciseSearch = ""
    var exercises: [WorkoutLogExercise] = []
    var notes = ""
    var rpe: Double = 5.0
    var isSaving = false
    var isLoading = false
    var isDeleting = false
    var isUndoing = false
    var errorMessage: String?
    var isDeleted = false
    var deletedAt: Date?
    var workoutSource: WorkoutSource = .manual
    var activeRestTimer: WorkoutRestTimerState?
    var importConflict: ImportConflict?
    var estimatedTrimp: Double?
    var importedSessions: [ImportedWorkoutSummary] = []
    var isImportingFromHealthKit = false
    var healthKitStatusMessage: String?
    var userUnits: UnitSystem = .metric

    private var didLoadExistingWorkout = false
    private var loadedPerceivedExertionRpe: Int?
    private var didModifyRpe = false
    private var catalog: [ExerciseCatalogEntry] = []
    private let workoutManager: any WorkoutSessionManaging
    private let dbQueue: DatabaseQueue
    private let targetDate: Date
    private let defaultRestAfterSeconds: Int
    private let restTimerTickNanoseconds: UInt64
    private var restTimerTask: Task<Void, Never>?
    private var sessionStartedAt: Date
    private var sessionStartedTimezone: String?
    private var sessionStartedUtcOffsetMinutes: Int?
    private var sessionEndedAt: Date?
    private var sessionDateString: String
    private var sessionDurationMinutes: Int?
    private var sessionLocation: WorkoutLocation?
    private var trainingPlanId: UUID?
    private var postFeeling: Int?
    private var estimatedCalories: Int?
    private var loadedTrimpScore: Double?

    init(
        existingSessionId: UUID? = nil,
        workoutManager: (any WorkoutSessionManaging)? = nil,
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue,
        targetDate: Date = Date(),
        initialWorkoutType: WorkoutType? = nil,
        initialTrainingPlanId: UUID? = nil,
        defaultRestAfterSeconds: Int = 90,
        restTimerTickNanoseconds: UInt64 = 1_000_000_000
    ) {
        let sessionStartedAt = Self.sessionStartDate(for: targetDate)
        self.existingSessionId = existingSessionId
        self.workoutManager = workoutManager ?? TrainingService(dbQueue: dbQueue)
        self.dbQueue = dbQueue
        self.targetDate = targetDate
        self.defaultRestAfterSeconds = defaultRestAfterSeconds
        self.restTimerTickNanoseconds = restTimerTickNanoseconds
        self.sessionStartedAt = sessionStartedAt
        self.sessionStartedTimezone = TimeZone.current.identifier
        self.sessionStartedUtcOffsetMinutes = TimeZone.current.secondsFromGMT(for: sessionStartedAt) / 60
        self.sessionDateString = DiaryDateFormatter.formatDate(targetDate)
        self.selectedWorkoutType = initialWorkoutType ?? .strength
        self.trainingPlanId = initialTrainingPlanId
        self.workoutSource = initialTrainingPlanId == nil ? .manual : .plan
        Task {
            await loadCatalog()
            if existingSessionId == nil {
                await refreshHealthKitImportState()
            }
        }
    }

    var hasExistingWorkout: Bool { existingSessionId != nil }
    var canEditExercises: Bool { !hasExistingWorkout || workoutSource != .import }
    var canTrackSetCompletion: Bool { !hasExistingWorkout && !isDeleted }
    var shouldShowHealthKitImportSection: Bool { !hasExistingWorkout && !isDeleted }
    var canDelete: Bool { hasExistingWorkout && !isBusy && !isDeleted }
    var canUndoDelete: Bool {
        hasExistingWorkout &&
            isDeleted &&
            !isBusy &&
            (deletedAt?.addingTimeInterval(24 * 60 * 60) ?? .distantPast) > Date()
    }
    var canSave: Bool {
        if isBusy || isDeleted { return false }
        if !canEditExercises { return true }
        return !exercises.isEmpty
    }
    var isBusy: Bool { isSaving || isLoading || isDeleting || isUndoing || isImportingFromHealthKit }
    var screenTitle: String {
        isDeleted
            ? String(localized: "training_workout_deleted")
            : (hasExistingWorkout ? String(localized: "training_workout_detail_title") : String(localized: "log_workout"))
    }
    var saveButtonTitle: String {
        hasExistingWorkout ? String(localized: "training_save_changes") : String(localized: "training_finish_workout")
    }
    var deletedStatusText: String? {
        deletedAt.map {
            String(
                format: String(localized: "training_deleted_at_format"),
                $0.formatted(date: .abbreviated, time: .shortened)
            )
        }
    }
    var overviewTitle: String {
        selectedWorkoutType.map { localizedTrainingIdentifier($0.rawValue) } ?? String(localized: "training_workout_default_title")
    }
    var overviewIconName: String {
        switch selectedWorkoutType {
        case .cardio: return "figure.run.circle"
        case .mobility: return "figure.cooldown"
        default: return "figure.strengthtraining.traditional"
        }
    }
    var overviewSubtitle: String? { "\(sessionDateString) • \(sessionStartedAt.formatted(date: .abbreviated, time: .shortened))" }
    var sourceBadgeTitle: String {
        switch workoutSource {
        case .manual: return String(localized: "training_source_manual")
        case .wearable: return String(localized: "training_source_wearable")
        case .plan: return String(localized: "training_source_plan")
        case .import: return String(localized: "training_source_imported")
        }
    }
    var importedWorkoutNotice: String? {
        guard hasExistingWorkout, workoutSource == .import else { return nil }
        return TrainingError.importedWorkoutEditRestricted.errorDescription
    }
    var incompleteSetCount: Int { exercises.flatMap(\.sets).filter(\.hasIncompleteMetrics).count }
    var rpeLabelText: String {
        if hasExistingWorkout && !didModifyRpe && loadedPerceivedExertionRpe == nil {
            return String(localized: "training_rpe_not_set")
        }
        return String(
            format: String(localized: "training_rpe_value_format"),
            resolvedPerceivedExertionRpe ?? Int(rpe.rounded())
        )
    }
    fileprivate var summaryMetrics: WorkoutSummaryMetrics {
        WorkoutSummaryMetrics(
            totalSets: exercises.reduce(0) { $0 + $1.sets.count },
            totalVolume: exercises.flatMap(\.sets).reduce(0.0) { $0 + ($1.weight * Double($1.reps)) },
            durationMinutes: currentDurationMinutes
        )
    }

    var exerciseSearchQuery: String? {
        ExerciseCatalogSupport.normalizedName(exerciseSearch)
    }
    var exactCatalogMatch: ExerciseCatalogEntry? {
        guard let query = exerciseSearchQuery else { return nil }
        return catalog.first { $0.name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }
    var canCreateCustomExercise: Bool {
        guard canEditExercises, exerciseSearchQuery != nil else { return false }
        return exactCatalogMatch == nil
    }
    var shouldShowExerciseSuggestions: Bool {
        guard exerciseSearchQuery != nil else { return false }
        return !filteredCatalog.isEmpty || canCreateCustomExercise
    }
    var customExerciseButtonTitle: String {
        String(
            format: String(localized: "training_add_custom_exercise_format"),
            exerciseSearchQuery ?? exerciseSearch
        )
    }
    var customExerciseButtonSubtitle: String {
        String(
            format: String(localized: "training_custom_exercise_category_format"),
            localizedTrainingIdentifier(defaultCustomExerciseCategory.rawValue)
        )
    }
    var filteredCatalog: [ExerciseCatalogEntry] {
        guard let query = exerciseSearchQuery else { return [] }
        let normalizedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return catalog
            .filter {
                $0.name
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .contains(normalizedQuery)
            }
            .sorted {
                let lhsPriority = Self.catalogMatchPriority(for: $0.name, query: normalizedQuery)
                let rhsPriority = Self.catalogMatchPriority(for: $1.name, query: normalizedQuery)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    func loadCatalog() async {
        let authId = AuthManager.activeAuthId?.uuidString
        do {
            let result = try await dbQueue.write { db -> ([ExerciseCatalogEntry], UnitSystem) in
                let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db)
                let loadedCatalog = try ExerciseCatalogSupport.loadVisibleCatalog(in: db, userId: userId)
                let userIdString = userId?.uuidString
                let unitsRaw = try String.fetchOne(
                    db,
                    sql: """
                        SELECT units
                        FROM users
                        WHERE (id = ? OR id = ?)
                        ORDER BY updated_at DESC
                        LIMIT 1
                        """,
                    arguments: [userId, userIdString]
                )
                let units = unitsRaw.flatMap(UnitSystem.init(rawValue:)) ?? .metric
                return (loadedCatalog, units)
            }
            catalog = result.0
            userUnits = result.1
        } catch {
            catalog = []
        }
    }

    func loadWorkoutDetailIfNeeded() async {
        guard let existingSessionId, !didLoadExistingWorkout else { return }
        isLoading = true
        defer {
            isLoading = false
            didLoadExistingWorkout = true
        }

        do {
            let shouldFetchRemote = SupabaseConfig.isRuntimeConfigured && AuthManager.activeHasCloudSession
            guard let detail = try await workoutManager.loadWorkoutDetail(id: existingSessionId, preferRemote: shouldFetchRemote) else {
                throw TrainingError.workoutNotFound
            }
            apply(detail: detail)
            errorMessage = nil
        } catch {
            errorMessage = Self.localizedErrorDescription(for: error)
        }
    }

    func addExercise(_ entry: ExerciseCatalogEntry) {
        exercises.append(
            WorkoutLogExercise(
                id: UUID(),
                catalogId: entry.id,
                name: entry.name,
                category: entry.category,
                sets: [WorkoutLogSet(id: UUID(), weight: 0, reps: 0, rpe: 0, restAfterSeconds: defaultRestAfterSeconds)]
            )
        )
    }

    func addExerciseFromSearch() async {
        guard let query = exerciseSearchQuery else { return }

        if let exactCatalogMatch {
            addExercise(exactCatalogMatch)
            exerciseSearch = ""
            errorMessage = nil
            return
        }

        let authId = AuthManager.activeAuthId?.uuidString
        let defaultCategory = defaultCustomExerciseCategory

        do {
            let result = try await dbQueue.write { db -> (ExerciseCatalogEntry, [ExerciseCatalogEntry]) in
                let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db)
                let entry = try ExerciseCatalogSupport.resolveEntry(
                    requestedId: nil,
                    name: query,
                    category: defaultCategory,
                    userId: userId,
                    in: db
                )
                guard let entry else {
                    throw TrainingError.invalidSet(reason: String(localized: "training_validation_add_exercise"))
                }
                let catalog = try ExerciseCatalogSupport.loadVisibleCatalog(in: db, userId: userId)
                return (entry, catalog)
            }

            catalog = result.1
            addExercise(result.0)
            exerciseSearch = ""
            errorMessage = nil
        } catch {
            errorMessage = Self.localizedErrorDescription(for: error)
        }
    }

    func removeExercise(_ id: UUID) {
        exercises.removeAll { $0.id == id }
    }

    func addSet(to exerciseId: UUID) {
        guard let exerciseIndex = exercises.firstIndex(where: { $0.id == exerciseId }) else { return }
        exercises[exerciseIndex].sets.append(
            WorkoutLogSet(id: UUID(), weight: 0, reps: 0, rpe: 0, restAfterSeconds: defaultRestAfterSeconds)
        )
    }

    func removeSet(from exerciseId: UUID, at index: Int) {
        guard let exerciseIndex = exercises.firstIndex(where: { $0.id == exerciseId }) else { return }
        guard exercises[exerciseIndex].sets.indices.contains(index) else { return }
        exercises[exerciseIndex].sets.remove(at: index)
    }

    func toggleWarmup(exerciseId: UUID, at index: Int) {
        guard let exerciseIndex = exercises.firstIndex(where: { $0.id == exerciseId }) else { return }
        guard exercises[exerciseIndex].sets.indices.contains(index) else { return }
        exercises[exerciseIndex].sets[index].isWarmup.toggle()
    }

    func setRestDuration(exerciseId: UUID, at index: Int, seconds: Int?) {
        guard let exerciseIndex = exercises.firstIndex(where: { $0.id == exerciseId }) else { return }
        guard exercises[exerciseIndex].sets.indices.contains(index) else { return }
        exercises[exerciseIndex].sets[index].restAfterSeconds = seconds
    }

    func toggleSetCompletion(exerciseId: UUID, at index: Int) {
        guard canTrackSetCompletion,
              let exerciseIndex = exercises.firstIndex(where: { $0.id == exerciseId }),
              exercises[exerciseIndex].sets.indices.contains(index) else {
            return
        }
        exercises[exerciseIndex].sets[index].isCompleted.toggle()
        let set = exercises[exerciseIndex].sets[index]
        if set.isCompleted {
            startRestTimer(for: set)
        } else if activeRestTimer?.setId == set.id {
            dismissRestTimer()
        }
    }

    func extendRestTimer(by seconds: Int) {
        guard var timer = activeRestTimer else { return }
        timer.remainingSeconds += seconds
        activeRestTimer = timer
    }

    func dismissRestTimer() {
        restTimerTask?.cancel()
        restTimerTask = nil
        activeRestTimer = nil
    }

    func setRPE(_ value: Double) {
        didModifyRpe = true
        rpe = value
    }

    func importFromHealthKit() async {
        guard !isImportingFromHealthKit else { return }
        isImportingFromHealthKit = true
        healthKitStatusMessage = nil
        defer { isImportingFromHealthKit = false }

        let authId = AuthManager.activeAuthId?.uuidString

        do {
            guard let userId = try await dbQueue.read({
                try UserIdentityLookup.resolveUserId(authId: authId, db: $0)
            }) else {
                healthKitStatusMessage = String(localized: "error.user.unavailable")
                return
            }

            try await HealthSyncManager.shared.syncImportedWorkouts(for: targetDate, userId: userId)
            await refreshHealthKitImportState()
            healthKitStatusMessage = importedSessions.isEmpty
                ? String(localized: "training_apple_health_no_workouts_today")
                : String(localized: "training_apple_health_imported_today")
        } catch {
            healthKitStatusMessage = String(localized: "training_apple_health_import_failed")
        }
    }

    func refreshHealthKitImportState() async {
        let authId = AuthManager.activeAuthId?.uuidString
        let currentSessionDateString = sessionDateString

        do {
            let snapshot = try await dbQueue.read { db -> ([ImportedWorkoutSummary], ImportConflict?) in
                guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                    return ([], nil)
                }

                let sessions = try WorkoutSession.fetchAll(
                    db,
                    sql: """
                        SELECT *
                        FROM workout_sessions
                        WHERE session_date = ?
                          AND (user_id = ? OR user_id = ?)
                        ORDER BY started_at ASC
                        """,
                    arguments: [currentSessionDateString, userId, userId.uuidString]
                )

                let activeImported = sessions
                    .filter { $0.source == .import && $0.deletedAt == nil }
                    .map(ImportedWorkoutSummary.init)
                    .sorted { $0.startedAt < $1.startedAt }

                return (activeImported, Self.firstImportConflict(in: sessions))
            }

            importedSessions = snapshot.0
            importConflict = snapshot.1
        } catch {
            importedSessions = []
            importConflict = nil
        }
    }

    func resolveConflict(_ resolution: ConflictResolution) async {
        guard let conflict = importConflict else { return }

        do {
            let sessions = try await dbQueue.read { db -> (WorkoutSession, WorkoutSession) in
                guard let existingSession = try WorkoutSession.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM workout_sessions
                        WHERE id = ? OR id = ?
                        LIMIT 1
                        """,
                    arguments: [conflict.existingSessionId, conflict.existingSessionId.uuidString]
                ), let importedSession = try WorkoutSession.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM workout_sessions
                        WHERE id = ? OR id = ?
                        LIMIT 1
                        """,
                    arguments: [conflict.importedSessionId, conflict.importedSessionId.uuidString]
                ) else {
                    throw TrainingError.workoutNotFound
                }
                return (existingSession, importedSession)
            }

            let existingSession = sessions.0
            let importedSession = sessions.1
            switch resolution {
            case .merge:
                var mergedSession = existingSession
                if let importedEndedAt = importedSession.endedAt {
                    mergedSession.endedAt = max(mergedSession.endedAt ?? importedEndedAt, importedEndedAt)
                }
                if let importedDuration = importedSession.durationMinutes {
                    mergedSession.durationMinutes = max(mergedSession.durationMinutes ?? 0, importedDuration)
                }
                mergedSession.estimatedCalories = mergedSession.estimatedCalories ?? importedSession.estimatedCalories
                if let importedTrimp = importedSession.trimpScore {
                    mergedSession.trimpScore = max(mergedSession.trimpScore ?? 0, importedTrimp)
                }
                if let importedRPE = importedSession.perceivedExertionRpe {
                    mergedSession.perceivedExertionRpe = max(mergedSession.perceivedExertionRpe ?? 0, importedRPE)
                }
                if mergedSession.startedTimezone == nil {
                    mergedSession.startedTimezone = importedSession.startedTimezone
                }
                if mergedSession.startedUtcOffsetMinutes == nil {
                    mergedSession.startedUtcOffsetMinutes = importedSession.startedUtcOffsetMinutes
                }
                try await workoutManager.updateWorkout(Self.makeUpdateDraft(from: mergedSession, exercises: nil))
                _ = try await workoutManager.deleteWorkout(id: importedSession.id)
            case .keepExisting:
                _ = try await workoutManager.deleteWorkout(id: importedSession.id)
            case .useImported:
                _ = try await workoutManager.deleteWorkout(id: existingSession.id)
            }

            await refreshHealthKitImportState()
            switch resolution {
            case .merge:
                healthKitStatusMessage = String(localized: "training_apple_health_merge_success")
            case .keepExisting:
                healthKitStatusMessage = String(localized: "training_apple_health_keep_manual_success")
            case .useImported:
                healthKitStatusMessage = String(localized: "training_apple_health_keep_imported_success")
            }
        } catch {
            healthKitStatusMessage = String(localized: "training_apple_health_conflict_failed")
        }
    }

    func save() async -> Bool {
        hasExistingWorkout ? await updateExistingWorkout() : await createNewWorkout()
    }

    func deleteWorkout() async -> Bool {
        guard let existingSessionId, canDelete else { return false }
        isDeleting = true
        defer { isDeleting = false }

        do {
            deletedAt = try await workoutManager.deleteWorkout(id: existingSessionId)
            isDeleted = true
            dismissRestTimer()
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.localizedErrorDescription(for: error)
            return false
        }
    }

    func undoDeleteWorkout() async -> Bool {
        guard let existingSessionId, canUndoDelete else { return false }
        isUndoing = true
        defer { isUndoing = false }

        do {
            try await workoutManager.undoDeleteWorkout(id: existingSessionId)
            isDeleted = false
            deletedAt = nil
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.localizedErrorDescription(for: error)
            return false
        }
    }

    private func createNewWorkout() async -> Bool {
        guard !exercises.isEmpty else {
            errorMessage = Self.localizedErrorDescription(
                for: TrainingError.invalidSet(reason: String(localized: "training_validation_add_exercise"))
            )
            return false
        }
        isSaving = true
        defer { isSaving = false }

        let durationMinutes = currentDurationMinutes
        let trimp = currentTrimpScore
        estimatedTrimp = trimp

        do {
            try await workoutManager.createManualWorkout(
                WorkoutSessionDraft(
                    id: UUID(),
                    startedAt: sessionStartedAt,
                    sessionDate: sessionDateString,
                    startedTimezone: sessionStartedTimezone,
                    startedUtcOffsetMinutes: sessionStartedUtcOffsetMinutes,
                    endedAt: durationMinutes.map { sessionStartedAt.addingTimeInterval(TimeInterval($0 * 60)) },
                    durationMinutes: durationMinutes,
                    workoutType: selectedWorkoutType,
                    location: sessionLocation,
                    notes: Self.normalizedText(notes),
                    trainingPlanId: trainingPlanId,
                    perceivedExertionRpe: resolvedPerceivedExertionRpe,
                    postFeeling: postFeeling,
                    estimatedCalories: estimatedCalories,
                    trimpScore: trimp,
                    exercises: buildDraftExercises()
                )
            )
            dismissRestTimer()
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.localizedErrorDescription(for: error)
            return false
        }
    }

    private func updateExistingWorkout() async -> Bool {
        guard let existingSessionId else { return false }
        if canEditExercises && exercises.isEmpty {
            errorMessage = Self.localizedErrorDescription(
                for: TrainingError.invalidSet(reason: String(localized: "training_validation_add_exercise"))
            )
            return false
        }

        isSaving = true
        defer { isSaving = false }

        let durationMinutes = currentDurationMinutes
        let trimp = currentTrimpScore
        estimatedTrimp = trimp

        do {
            try await workoutManager.updateWorkout(
                WorkoutSessionUpdateDraft(
                    id: existingSessionId,
                    startedAt: sessionStartedAt,
                    sessionDate: sessionDateString,
                    startedTimezone: sessionStartedTimezone,
                    startedUtcOffsetMinutes: sessionStartedUtcOffsetMinutes,
                    endedAt: durationMinutes.map { sessionStartedAt.addingTimeInterval(TimeInterval($0 * 60)) },
                    durationMinutes: durationMinutes,
                    workoutType: selectedWorkoutType,
                    location: sessionLocation,
                    notes: Self.normalizedText(notes),
                    trainingPlanId: trainingPlanId,
                    perceivedExertionRpe: resolvedPerceivedExertionRpe,
                    postFeeling: postFeeling,
                    estimatedCalories: estimatedCalories,
                    trimpScore: trimp,
                    exercises: canEditExercises ? buildDraftExercises() : nil
                )
            )
            sessionDurationMinutes = durationMinutes
            sessionEndedAt = durationMinutes.map { sessionStartedAt.addingTimeInterval(TimeInterval($0 * 60)) }
            loadedTrimpScore = trimp
            loadedPerceivedExertionRpe = resolvedPerceivedExertionRpe
            didModifyRpe = false
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.localizedErrorDescription(for: error)
            return false
        }
    }

    private func apply(detail: WorkoutSessionDetail) {
        selectedWorkoutType = detail.session.workoutType
        notes = detail.session.notes ?? ""
        loadedPerceivedExertionRpe = detail.session.perceivedExertionRpe
        didModifyRpe = false
        rpe = Double(detail.session.perceivedExertionRpe ?? 5)
        workoutSource = detail.session.source
        isDeleted = detail.session.deletedAt != nil
        deletedAt = detail.session.deletedAt
        sessionStartedAt = detail.session.startedAt
        sessionStartedTimezone = detail.session.startedTimezone
        sessionStartedUtcOffsetMinutes = detail.session.startedUtcOffsetMinutes
        sessionEndedAt = detail.session.endedAt
        sessionDateString = detail.session.sessionDate
        sessionDurationMinutes = detail.session.durationMinutes
        sessionLocation = detail.session.location
        trainingPlanId = detail.session.trainingPlanId
        postFeeling = detail.session.postFeeling
        estimatedCalories = detail.session.estimatedCalories
        loadedTrimpScore = detail.session.trimpScore
        estimatedTrimp = detail.session.trimpScore
        exercises = detail.exercises
            .sorted { ($0.exercise.orderInSession ?? 0) < ($1.exercise.orderInSession ?? 0) }
            .enumerated()
            .map { index, detailExercise in
                WorkoutLogExercise(
                    id: detailExercise.exercise.id,
                    catalogId: detailExercise.exercise.exerciseId,
                    name: detailExercise.name ?? "Exercise \(index + 1)",
                    category: detailExercise.category ?? .other,
                    notes: detailExercise.exercise.notes ?? "",
                    durationSeconds: detailExercise.exercise.durationSeconds,
                    sets: detailExercise.sets.sorted { $0.setNumber < $1.setNumber }.map {
                        WorkoutLogSet(
                            id: $0.id,
                            weight: $0.weight ?? 0,
                            reps: $0.reps ?? 0,
                            rpe: $0.rpe ?? 0,
                            restAfterSeconds: $0.restAfterSeconds,
                            isWarmup: $0.isWarmup,
                            isFailure: $0.isFailure,
                            isDropset: $0.isDropset,
                            isCompleted: false
                        )
                    }
                )
            }
    }

    private func buildDraftExercises() -> [WorkoutSessionDraftExercise] {
        exercises.enumerated().map { index, exercise in
            WorkoutSessionDraftExercise(
                id: exercise.id,
                exerciseId: exercise.catalogId,
                name: Self.normalizedText(exercise.name),
                category: exercise.category,
                orderInSession: index + 1,
                durationSeconds: exercise.durationSeconds,
                notes: Self.normalizedText(exercise.notes),
                sets: exercise.sets.enumerated().map { setIndex, set in
                    WorkoutSessionDraftSet(
                        id: set.id,
                        setNumber: setIndex + 1,
                        weight: set.weight > 0 ? set.weight : nil,
                        reps: set.reps > 0 ? set.reps : nil,
                        rpe: set.rpe > 0 ? set.rpe : nil,
                        restAfterSeconds: (set.restAfterSeconds ?? 0) > 0 ? set.restAfterSeconds : nil,
                        isWarmup: set.isWarmup,
                        isFailure: set.isFailure,
                        isDropset: set.isDropset
                    )
                }
            )
        }
    }

    private func startRestTimer(for set: WorkoutLogSet) {
        let duration = max(set.restAfterSeconds ?? defaultRestAfterSeconds, 1)
        dismissRestTimer()
        activeRestTimer = WorkoutRestTimerState(setId: set.id, totalSeconds: duration, remainingSeconds: duration)

        let tick = restTimerTickNanoseconds
        let setId = set.id
        restTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: tick)
                } catch {
                    return
                }
                guard let self else { return }
                let shouldContinue = await MainActor.run { () -> Bool in
                    guard let timer = self.activeRestTimer, timer.setId == setId else {
                        return false
                    }
                    if timer.remainingSeconds <= 1 {
                        self.activeRestTimer = nil
                        return false
                    }
                    var updated = timer
                    updated.remainingSeconds -= 1
                    self.activeRestTimer = updated
                    return true
                }
                if !shouldContinue {
                    return
                }
            }
        }
    }

    private var resolvedPerceivedExertionRpe: Int? {
        if hasExistingWorkout && !didModifyRpe {
            return loadedPerceivedExertionRpe
        }
        return Int(rpe.rounded())
    }

    private var currentDurationMinutes: Int? {
        if canEditExercises, !exercises.isEmpty {
            return max(Int((Double(exercises.flatMap(\.sets).count) * 2.5).rounded()), 15)
        }
        if let sessionDurationMinutes {
            return sessionDurationMinutes
        }
        if let sessionEndedAt {
            return max(0, Int(sessionEndedAt.timeIntervalSince(sessionStartedAt) / 60))
        }
        return nil
    }

    private var currentTrimpScore: Double? {
        guard let durationMinutes = currentDurationMinutes,
              let resolvedPerceivedExertionRpe else {
            return loadedTrimpScore
        }
        return Double(durationMinutes) * (Double(resolvedPerceivedExertionRpe) / 10.0) * 1.5
    }

    private var defaultCustomExerciseCategory: ExerciseCategory {
        ExerciseCatalogSupport.defaultCategory(for: selectedWorkoutType)
    }

    private nonisolated static func firstImportConflict(in sessions: [WorkoutSession]) -> ImportConflict? {
        let activeImported = sessions.filter { $0.source == .import && $0.deletedAt == nil }
        let activeManual = sessions.filter { $0.source != .import && $0.deletedAt == nil }

        for existing in activeManual {
            for imported in activeImported where sessionsConflict(existing, imported) {
                return ImportConflict(
                    existingSessionId: existing.id,
                    existingType: existing.workoutType.map { localizedTrainingIdentifier($0.rawValue) }
                        ?? String(localized: "training_manual_workout_fallback"),
                    importedType: imported.workoutType.map { localizedTrainingIdentifier($0.rawValue) }
                        ?? String(localized: "training_imported_workout_fallback"),
                    importedSessionId: imported.id
                )
            }
        }
        return nil
    }

    fileprivate nonisolated static func sessionsConflict(_ lhs: WorkoutSession, _ rhs: WorkoutSession) -> Bool {
        guard areCompatibleWorkoutTypes(lhs.workoutType, rhs.workoutType) else {
            return false
        }

        let lhsEnd = inferredEndDate(for: lhs)
        let rhsEnd = inferredEndDate(for: rhs)
        let overlapStart = max(lhs.startedAt, rhs.startedAt)
        let overlapEnd = min(lhsEnd, rhsEnd)
        let overlap = max(0, overlapEnd.timeIntervalSince(overlapStart))
        let shorterDuration = max(1, min(lhsEnd.timeIntervalSince(lhs.startedAt), rhsEnd.timeIntervalSince(rhs.startedAt)))
        let overlapRatio = overlap / shorterDuration
        let startDelta = abs(lhs.startedAt.timeIntervalSince(rhs.startedAt))
        let lhsDuration = max(1, lhsEnd.timeIntervalSince(lhs.startedAt))
        let rhsDuration = max(1, rhsEnd.timeIntervalSince(rhs.startedAt))
        let durationDeltaRatio = abs(lhsDuration - rhsDuration) / max(lhsDuration, rhsDuration)

        return overlapRatio >= 0.6 || (startDelta <= 30 * 60 && durationDeltaRatio <= 0.25)
    }

    fileprivate nonisolated static func inferredEndDate(for session: WorkoutSession) -> Date {
        if let endedAt = session.endedAt {
            return endedAt
        }
        if let durationMinutes = session.durationMinutes, durationMinutes > 0 {
            return session.startedAt.addingTimeInterval(TimeInterval(durationMinutes * 60))
        }
        return session.startedAt
    }

    fileprivate nonisolated static func areCompatibleWorkoutTypes(_ lhs: WorkoutType?, _ rhs: WorkoutType?) -> Bool {
        guard let lhs, let rhs else { return true }
        if lhs == rhs || lhs == .mixed || rhs == .mixed { return true }
        let cardioLike: Set<WorkoutType> = [.cardio, .sport]
        if cardioLike.contains(lhs) && cardioLike.contains(rhs) {
            return true
        }
        return lhs == .other || rhs == .other
    }

    private nonisolated static func makeUpdateDraft(
        from session: WorkoutSession,
        exercises: [WorkoutSessionDraftExercise]?
    ) -> WorkoutSessionUpdateDraft {
        WorkoutSessionUpdateDraft(
            id: session.id,
            startedAt: session.startedAt,
            sessionDate: session.sessionDate,
            startedTimezone: session.startedTimezone,
            startedUtcOffsetMinutes: session.startedUtcOffsetMinutes,
            endedAt: session.endedAt,
            durationMinutes: session.durationMinutes,
            workoutType: session.workoutType,
            location: session.location,
            notes: session.notes,
            trainingPlanId: session.trainingPlanId,
            perceivedExertionRpe: session.perceivedExertionRpe,
            postFeeling: session.postFeeling,
            estimatedCalories: session.estimatedCalories,
            trimpScore: session.trimpScore,
            exercises: exercises
        )
    }

    fileprivate static func sessionStartDate(for targetDate: Date, referenceNow: Date = Date()) -> Date {
        let calendar = Calendar.current
        guard !calendar.isDate(targetDate, inSameDayAs: referenceNow) else {
            return referenceNow
        }

        let currentTime = calendar.dateComponents([.hour, .minute, .second], from: referenceNow)
        var targetComponents = calendar.dateComponents([.year, .month, .day], from: targetDate)
        targetComponents.hour = currentTime.hour ?? 12
        targetComponents.minute = currentTime.minute ?? 0
        targetComponents.second = currentTime.second ?? 0
        return calendar.date(from: targetComponents) ?? targetDate
    }

    fileprivate nonisolated static func normalizedText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    fileprivate nonisolated static func catalogMatchPriority(for name: String, query: String) -> Int {
        let normalizedName = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if normalizedName == query { return 0 }
        if normalizedName.hasPrefix(query) { return 1 }
        return 2
    }

    fileprivate nonisolated static func localizedErrorDescription(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }
}

#if DEBUG
extension WorkoutLogViewModel {
    static func _testNormalizedText(_ value: String?) -> String? {
        normalizedText(value)
    }

    static func _testCatalogMatchPriority(for name: String, query: String) -> Int {
        catalogMatchPriority(for: name, query: query)
    }

    static func _testSessionStartDate(for targetDate: Date, referenceNow: Date) -> Date {
        sessionStartDate(for: targetDate, referenceNow: referenceNow)
    }

    static func _testInferredEndDate(for session: WorkoutSession) -> Date {
        inferredEndDate(for: session)
    }

    static func _testSessionsConflict(_ lhs: WorkoutSession, _ rhs: WorkoutSession) -> Bool {
        sessionsConflict(lhs, rhs)
    }

    static func _testAreCompatibleWorkoutTypes(_ lhs: WorkoutType?, _ rhs: WorkoutType?) -> Bool {
        areCompatibleWorkoutTypes(lhs, rhs)
    }
}
#endif

struct WorkoutLogExercise: Identifiable {
    let id: UUID
    var catalogId: UUID?
    var name: String
    var category: ExerciseCategory
    var notes: String = ""
    var durationSeconds: Int?
    var sets: [WorkoutLogSet] = []
}

struct WorkoutLogSet: Identifiable {
    let id: UUID
    var weight: Double
    var reps: Int
    var rpe: Int = 0
    var restAfterSeconds: Int?
    var isWarmup = false
    var isFailure = false
    var isDropset = false
    var isCompleted = false

    var hasIncompleteMetrics: Bool {
        weight <= 0 || reps <= 0
    }
}

struct ImportConflict: Equatable {
    let existingSessionId: UUID
    let existingType: String
    let importedType: String
    let importedSessionId: UUID
}

struct ImportedWorkoutSummary: Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    let primaryText: String
    let secondaryText: String
    let trimpScore: Double?

    init(_ session: WorkoutSession) {
        self.id = session.id
        self.startedAt = session.startedAt

        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let timeText = formatter.string(from: session.startedAt)
        let typeText = session.workoutType.map { localizedTrainingIdentifier($0.rawValue) }
            ?? String(localized: "training_workout_fallback")

        self.primaryText = "\(typeText) • \(timeText)"

        var parts: [String] = []
        if let durationMinutes = session.durationMinutes, durationMinutes > 0 {
            parts.append("\(durationMinutes) min")
        }
        if !NutritionSafetyPolicy.hidesCalories, let estimatedCalories = session.estimatedCalories, estimatedCalories > 0 {
            parts.append("\(estimatedCalories) kcal")
        }
        self.secondaryText = parts.isEmpty ? String(localized: "training_apple_health_imported_source") : parts.joined(separator: " • ")
        self.trimpScore = session.trimpScore
    }
}

enum ConflictResolution {
    case merge
    case keepExisting
    case useImported
}

@MainActor
@Observable
private final class TrainingDayViewModel {
    private(set) var sessions: [TrainingSessionSummary] = []
    private(set) var plannedSession: PlannedTrainingSessionSummary?
    private(set) var planOverview: TrainingPlanOverview?
    private(set) var upcomingPlanSessions: [UpcomingTrainingPlanSessionSummary] = []
    private(set) var isLoading = false
    private(set) var isPerformingPlanAction = false
    private(set) var planMessage: String?
    private(set) var isPlanMessageError = false

    var isShowingPlanComposer = false
    var isShowingPlanAdjustmentSheet = false
    var isShowingPlanManager = false

    private(set) var displayDate: String
    private(set) var selectedDate: Date
    private(set) var dayString: String
    private let dbQueue: DatabaseQueue
    private let planManager: any TrainingPlanManaging

    init(
        dateString: String?,
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue,
        planManager: (any TrainingPlanManaging)? = nil
    ) {
        let resolvedDay = TrainingDayViewModel.resolvedDay(dateString)
        self.dayString = resolvedDay
        self.displayDate = dateString ?? resolvedDay
        self.selectedDate = DiaryDateFormatter.parseDate(resolvedDay) ?? Date()
        self.dbQueue = dbQueue
        self.planManager = planManager ?? TrainingPlanService(dbQueue: dbQueue)
    }

    var canUseRemotePlanActions: Bool {
        SupabaseConfig.isRuntimeConfigured && AuthManager.activeHasCloudSession
    }

    var canCreatePlan: Bool {
        canUseRemotePlanActions &&
            planOverview?.status != TrainingPlanStatus.active.rawValue &&
            !isPerformingPlanAction
    }

    var planAvailabilityMessage: String {
        if canUseRemotePlanActions {
            return String(localized: "training_plan_availability_online")
        }
        return String(localized: "training_plan_availability_offline")
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        let authId = AuthManager.activeAuthId?.uuidString
        let selectedDay = dayString
        do {
            let trainingState = try await dbQueue.read { db in
                guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                    return (
                        sessions: [TrainingSessionSummary](),
                        plannedSession: Optional<PlannedTrainingSessionSummary>.none,
                        planOverview: Optional<TrainingPlanOverview>.none,
                        upcomingPlanSessions: [UpcomingTrainingPlanSessionSummary]()
                    )
                }
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, started_at, duration_minutes, workout_type, total_sets
                        FROM workout_sessions
                        WHERE session_date = ?
                          AND (user_id = ? OR user_id = ?)
                          AND deleted_at IS NULL
                        ORDER BY started_at DESC
                        """,
                    arguments: [selectedDay, userId, userId.uuidString]
                )
                let plannedSession = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT
                            tps.id,
                            tps.title,
                            tps.planned_exercises,
                            tps.session_type,
                            tps.planned_duration_minutes,
                            tps.status,
                            tp.id AS plan_id,
                            tp.name AS plan_name,
                            tp.goal AS plan_goal,
                            tp.current_week
                        FROM training_plan_sessions tps
                        JOIN training_plans tp
                          ON tp.id = tps.training_plan_id
                        WHERE tps.planned_date = ?
                          AND (tps.user_id = ? OR tps.user_id = ?)
                          AND tp.status = 'active'
                          AND tps.status IN ('planned', 'rescheduled', 'scheduled', 'modified')
                        ORDER BY
                          CASE tps.status
                            WHEN 'planned' THEN 0
                            WHEN 'scheduled' THEN 0
                            WHEN 'rescheduled' THEN 1
                            WHEN 'modified' THEN 1
                            ELSE 2
                          END,
                          tps.updated_at DESC
                        LIMIT 1
                        """,
                    arguments: [selectedDay, userId, userId.uuidString]
                ).flatMap(PlannedTrainingSessionSummary.init(row:))
                let planOverview = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT
                            id,
                            name,
                            goal,
                            status,
                            current_week,
                            days_per_week,
                            duration_weeks,
                            start_date,
                            end_date,
                            ai_generated,
                            adaptive_rules
                        FROM training_plans
                        WHERE (user_id = ? OR user_id = ?)
                        ORDER BY
                          CASE status
                            WHEN 'active' THEN 0
                            WHEN 'paused' THEN 1
                            WHEN 'completed' THEN 2
                            ELSE 3
                          END,
                          updated_at DESC
                        LIMIT 1
                        """,
                    arguments: [userId, userId.uuidString]
                ).flatMap(TrainingPlanOverview.init(row:))
                let upcomingPlanSessions: [UpcomingTrainingPlanSessionSummary]
                if let planOverview, planOverview.status == TrainingPlanStatus.active.rawValue {
                    let sessionRows = try Row.fetchAll(
                        db,
                        sql: """
                            SELECT
                                id,
                                title,
                                planned_exercises,
                                planned_date,
                                session_type,
                                planned_duration_minutes,
                                status
                            FROM training_plan_sessions
                            WHERE (training_plan_id = ? OR training_plan_id = ?)
                              AND planned_date >= ?
                              AND status IN ('planned', 'rescheduled', 'scheduled', 'modified')
                            ORDER BY
                              planned_date ASC,
                              CASE status
                                WHEN 'planned' THEN 0
                                WHEN 'scheduled' THEN 0
                                WHEN 'rescheduled' THEN 1
                                WHEN 'modified' THEN 1
                                ELSE 2
                              END,
                              updated_at DESC
                            LIMIT 6
                            """,
                        arguments: [planOverview.id, planOverview.id.uuidString, selectedDay]
                    )
                    upcomingPlanSessions = sessionRows.compactMap {
                        UpcomingTrainingPlanSessionSummary(row: $0, selectedDay: selectedDay)
                    }
                    .filter { !$0.isSelectedDate }
                } else {
                    upcomingPlanSessions = []
                }
                return (
                    sessions: rows.compactMap(TrainingSessionSummary.init(row:)),
                    plannedSession: plannedSession,
                    planOverview: planOverview,
                    upcomingPlanSessions: upcomingPlanSessions
                )
            }
            sessions = trainingState.sessions
            plannedSession = trainingState.plannedSession
            planOverview = trainingState.planOverview
            upcomingPlanSessions = trainingState.upcomingPlanSessions
        } catch {
            sessions = []
            plannedSession = nil
            planOverview = nil
            upcomingPlanSessions = []
        }
    }

    func presentPlanComposer() {
        guard canUseRemotePlanActions else {
            setPlanMessage(TrainingError.planRequiresCloudSync, isError: true)
            return
        }
        isShowingPlanComposer = true
    }

    func presentPlanAdjustment() {
        guard canUseRemotePlanActions else {
            setPlanMessage(TrainingError.planRequiresCloudSync, isError: true)
            return
        }
        guard planOverview?.canAdjust == true else { return }
        isShowingPlanAdjustmentSheet = true
    }

    func presentPlanManager() {
        guard canUseRemotePlanActions else {
            setPlanMessage(TrainingError.planRequiresCloudSync, isError: true)
            return
        }
        guard planOverview != nil else { return }
        isShowingPlanManager = true
    }

    func selectDay(_ newDay: String) async {
        let resolvedDay = Self.resolvedDay(newDay)
        dayString = resolvedDay
        displayDate = resolvedDay
        if let parsedDate = DiaryDateFormatter.parseDate(resolvedDay) {
            selectedDate = parsedDate
        }
        await load()
    }

    func createPlan(_ draft: TrainingPlanGenerationDraft) async -> Bool {
        let didSucceed = await performPlanMutation(
            successMessage: String(localized: "training_plan_generated")
        ) {
            try await self.planManager.generatePlan(draft)
        }
        if didSucceed {
            isShowingPlanComposer = false
        }
        return didSucceed
    }

    func updatePlan(_ draft: TrainingPlanUpdateDraft) async -> Bool {
        let didSucceed = await performPlanMutation(
            successMessage: String(localized: "training_plan_updated")
        ) {
            try await self.planManager.updatePlan(draft)
        }
        if didSucceed {
            isShowingPlanManager = false
        }
        return didSucceed
    }

    func adjustPlan(_ draft: TrainingPlanAdjustmentDraft) async -> Bool {
        let didSucceed = await performPlanMutation(
            successMessage: String(localized: "training_plan_adjustment_saved")
        ) {
            try await self.planManager.adjustPlan(draft)
        }
        if didSucceed {
            isShowingPlanAdjustmentSheet = false
        }
        return didSucceed
    }

    private static func resolvedDay(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return localDayString(for: Date())
        }
        return value
    }

    private static func localDayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func performPlanMutation(
        successMessage: String,
        action: @escaping () async throws -> Void
    ) async -> Bool {
        guard !isPerformingPlanAction else { return false }
        isPerformingPlanAction = true
        defer { isPerformingPlanAction = false }

        do {
            try await action()
            await load()
            planMessage = successMessage
            isPlanMessageError = false
            return true
        } catch {
            setPlanMessage(error, isError: true)
            return false
        }
    }

    private func setPlanMessage(_ value: Error, isError: Bool) {
        planMessage = Self.localizedErrorDescription(for: value)
        isPlanMessageError = isError
    }

    private nonisolated static func localizedErrorDescription(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }

#if DEBUG
    func _testOverrideState(sessions: [TrainingSessionSummary], isLoading: Bool) {
        self.sessions = sessions
        self.plannedSession = nil
        self.planOverview = nil
        self.upcomingPlanSessions = []
        self.isLoading = isLoading
    }
#endif
}

private struct PlannedTrainingSessionSummary: Identifiable {
    let id: UUID
    let planId: UUID
    let planName: String
    let goal: String
    let currentWeek: Int
    let sessionTitle: String
    let sessionType: String
    let plannedDurationMinutes: Int?
    let status: String

    var resolvedWorkoutType: WorkoutType? {
        switch sessionType.lowercased() {
        case "strength":
            return .strength
        case "cardio":
            return .cardio
        case "mobility", "recovery":
            return .mobility
        case "mixed":
            return .mixed
        case "sport":
            return .sport
        default:
            return .other
        }
    }

    init?(row: Row) {
        guard let id = MixedUUIDStorage.decode(from: row, column: "id"),
              let planId = MixedUUIDStorage.decode(from: row, column: "plan_id"),
              let planName: String = row["plan_name"],
              let goal: String = row["plan_goal"],
              let currentWeek: Int = row["current_week"],
              let sessionType: String = row["session_type"],
              let status: String = row["status"] else {
            return nil
        }
        self.id = id
        self.planId = planId
        self.planName = planName
        self.goal = goal
        self.currentWeek = currentWeek
        self.sessionTitle = trainingPlanSessionTitle(
            explicitTitle: row["title"],
            payload: row["planned_exercises"],
            fallbackType: sessionType
        )
        self.sessionType = sessionType
        self.plannedDurationMinutes = row["planned_duration_minutes"]
        self.status = status
    }
}

private struct TrainingPlanOverview: Identifiable {
    let id: UUID
    let name: String
    let goal: String
    let status: String
    let currentWeek: Int
    let daysPerWeek: Int?
    let durationWeeks: Int?
    let startDate: String?
    let endDate: String?
    let aiGenerated: Bool
    let adaptiveRules: [TrainingAdaptiveRuleSummary]

    var canAdjust: Bool {
        status == TrainingPlanStatus.active.rawValue
    }

    var summaryLine: String? {
        var parts: [String] = []
        if let daysPerWeek {
            parts.append(String(format: String(localized: "training_plan_days_per_week_format"), daysPerWeek))
        }
        if let durationWeeks {
            parts.append(String(format: String(localized: "training_plan_duration_weeks_format"), durationWeeks))
        }
        if let startDate, let endDate {
            parts.append(
                String(
                    format: String(localized: "training_plan_date_range_format"),
                    formattedPlanDate(startDate),
                    formattedPlanDate(endDate)
                )
            )
        }
        if aiGenerated {
            parts.append(String(localized: "training_plan_ai_adaptive"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    var adaptiveRuleSummary: String {
        if adaptiveRules.count == 1, let rule = adaptiveRules.first {
            return "\(rule.reasonTitle): \(rule.adjustmentTitle)"
        }
        return String(
            format: String(localized: "training_plan_adaptive_rules_saved_format"),
            adaptiveRules.count
        )
    }

    init?(row: Row) {
        guard let id = MixedUUIDStorage.decode(from: row, column: "id"),
              let name: String = row["name"],
              let goal: String = row["goal"],
              let status: String = row["status"],
              let currentWeek: Int = row["current_week"] else {
            return nil
        }
        self.id = id
        self.name = name
        self.goal = goal
        self.status = status
        self.currentWeek = currentWeek
        self.daysPerWeek = row["days_per_week"]
        self.durationWeeks = row["duration_weeks"]
        self.startDate = row["start_date"]
        self.endDate = row["end_date"]
        self.aiGenerated = row["ai_generated"] ?? false
        self.adaptiveRules = trainingAdaptiveRules(payload: row["adaptive_rules"])
    }
}

private struct TrainingAdaptiveRuleSummary: Identifiable, Equatable {
    let reason: String
    let adjustment: String

    var id: String { "\(reason):\(adjustment)" }
    var reasonTitle: String { humanized(reason) }
    var adjustmentTitle: String { humanized(adjustment) }
}

private struct UpcomingTrainingPlanSessionSummary: Identifiable {
    let id: UUID
    let title: String
    let subtitle: String
    let iconName: String
    let isSelectedDate: Bool

    init?(row: Row, selectedDay: String) {
        guard let id = MixedUUIDStorage.decode(from: row, column: "id"),
              let plannedDate: String = row["planned_date"],
              let sessionType: String = row["session_type"],
              let status: String = row["status"] else {
            return nil
        }

        self.id = id
        self.title = trainingPlanSessionTitle(
            explicitTitle: row["title"],
            payload: row["planned_exercises"],
            fallbackType: sessionType
        )
        self.iconName = TrainingSessionSummary.iconName(forPlannedSessionType: sessionType)
        self.isSelectedDate = plannedDate == selectedDay

        var subtitleParts = [formattedPlanDate(plannedDate), localizedTrainingIdentifier(sessionType)]
        if let plannedDurationMinutes: Int = row["planned_duration_minutes"], plannedDurationMinutes > 0 {
            subtitleParts.append(localizedTrainingMinutes(plannedDurationMinutes))
        }
        subtitleParts.append(humanized(status))
        self.subtitle = subtitleParts.joined(separator: " • ")
    }
}

private struct TrainingPlanComposerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let isSaving: Bool
    let onCreate: (TrainingPlanGenerationDraft) async -> Bool

    @State private var name = ""
    @State private var goal: TrainingGoal = .hypertrophy
    @State private var selectedWeekdays: Set<Int> = [1, 3, 5]
    @State private var durationWeeks = 4
    @State private var sessionDurationMinutes = 60
    @State private var experienceLevel: TrainingPlanExperienceLevel = .intermediate
    @State private var equipmentAccess: TrainingPlanEquipmentAccess = .gym
    @State private var injuriesText = ""

    private let weekdayOptions = orderedTrainingWeekdays()

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "training_form_overview")) {
                    TextField(String(localized: "training_plan_name_optional"), text: $name)

                    Picker(String(localized: "training_goal"), selection: $goal) {
                        ForEach(TrainingGoal.allCases, id: \.rawValue) { option in
                            Text(localizedTrainingIdentifier(option.rawValue)).tag(option)
                        }
                    }

                    Picker(String(localized: "training_experience"), selection: $experienceLevel) {
                        ForEach(TrainingPlanExperienceLevel.allCases) { option in
                            Text(humanized(option.rawValue)).tag(option)
                        }
                    }

                    Picker(String(localized: "training_equipment"), selection: $equipmentAccess) {
                        ForEach(TrainingPlanEquipmentAccess.allCases) { option in
                            Text(humanized(option.rawValue)).tag(option)
                        }
                    }
                }

                Section(String(localized: "training_form_schedule")) {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text(String(localized: "training_training_days"))
                            .font(LifeOSTypography.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.xs), count: 4), spacing: Spacing.xs) {
                            ForEach(weekdayOptions) { option in
                                Button {
                                    toggleWeekday(option.value)
                                } label: {
                                    Text(option.label)
                                        .font(LifeOSTypography.caption.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, Spacing.xs)
                                        .background(selectedWeekdays.contains(option.value) ? LifeOSColors.Semantic.primary.opacity(0.14) : LifeOSColors.Surface.card)
                                        .foregroundStyle(selectedWeekdays.contains(option.value) ? LifeOSColors.Semantic.primary : .secondary)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Stepper(
                        String(format: String(localized: "training_duration_weeks_stepper_format"), durationWeeks),
                        value: $durationWeeks,
                        in: 1...24
                    )
                    Stepper(
                        String(format: String(localized: "training_session_length_stepper_format"), sessionDurationMinutes),
                        value: $sessionDurationMinutes,
                        in: 10...240,
                        step: 5
                    )
                }

                Section(String(localized: "training_form_constraints")) {
                    TextField(String(localized: "training_injuries_limitations"), text: $injuriesText, axis: .vertical)
                        .lineLimit(2...4)
                    Text(String(localized: "training_injuries_hint"))
                        .font(LifeOSTypography.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(String(localized: "training_generate_plan"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "training_create")) {
                        Task {
                            let didCreate = await onCreate(
                                TrainingPlanGenerationDraft(
                                    name: name,
                                    goal: goal,
                                    availableDays: Array(selectedWeekdays).sorted(),
                                    durationWeeks: durationWeeks,
                                    sessionDurationMinutes: sessionDurationMinutes,
                                    experienceLevel: experienceLevel,
                                    equipmentAccess: equipmentAccess,
                                    injuries: parsedInjuries
                                )
                            )
                            if didCreate {
                                dismiss()
                            }
                        }
                    }
                    .disabled(selectedWeekdays.isEmpty || isSaving)
                }
            }
        }
    }

    private var parsedInjuries: [String] {
        injuriesText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func toggleWeekday(_ value: Int) {
        if selectedWeekdays.contains(value) {
            selectedWeekdays.remove(value)
        } else {
            selectedWeekdays.insert(value)
        }
    }
}

private struct TrainingPlanAdjustmentSheet: View {
    @Environment(\.dismiss) private var dismiss

    let plan: TrainingPlanOverview
    let isSaving: Bool
    let onApply: (TrainingPlanAdjustmentDraft) async -> Bool

    @State private var reason: TrainingPlanAdjustmentReason = .recoveryLow
    @State private var adjustment: TrainingPlanAdjustmentKind = .reduceVolume30

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "training_form_plan")) {
                    Text(plan.name)
                    Text(String(localized: "training_plan_adjustment_note"))
                        .font(LifeOSTypography.footnote)
                        .foregroundStyle(.secondary)
                }

                Section(String(localized: "training_form_trigger")) {
                    Picker(String(localized: "training_reason"), selection: $reason) {
                        ForEach(TrainingPlanAdjustmentReason.allCases) { option in
                            Text(humanized(option.rawValue)).tag(option)
                        }
                    }
                }

                Section(String(localized: "training_form_response")) {
                    Picker(String(localized: "training_adjustment"), selection: $adjustment) {
                        ForEach(TrainingPlanAdjustmentKind.allCases) { option in
                            Text(humanized(option.rawValue)).tag(option)
                        }
                    }
                    Text(
                        String(
                            format: String(localized: "training_recommended_adjustment_format"),
                            humanized(reason.recommendedAdjustment.rawValue)
                        )
                    )
                        .font(LifeOSTypography.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(String(localized: "training_adjust_plan"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "training_apply")) {
                        Task {
                            let didApply = await onApply(
                                TrainingPlanAdjustmentDraft(
                                    id: plan.id,
                                    reason: reason,
                                    adjustment: adjustment
                                )
                            )
                            if didApply {
                                dismiss()
                            }
                        }
                    }
                    .disabled(isSaving)
                }
            }
            .onChange(of: reason) { _, newValue in
                adjustment = newValue.recommendedAdjustment
            }
        }
    }
}

private struct TrainingPlanManageSheet: View {
    @Environment(\.dismiss) private var dismiss

    let plan: TrainingPlanOverview
    let isSaving: Bool
    let onSave: (TrainingPlanUpdateDraft) async -> Bool

    @State private var name: String
    @State private var status: TrainingPlanStatus

    init(
        plan: TrainingPlanOverview,
        isSaving: Bool,
        onSave: @escaping (TrainingPlanUpdateDraft) async -> Bool
    ) {
        self.plan = plan
        self.isSaving = isSaving
        self.onSave = onSave
        _name = State(initialValue: plan.name)
        _status = State(initialValue: TrainingPlanStatus(rawValue: plan.status) ?? .active)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "training_form_metadata")) {
                    TextField(String(localized: "training_plan_name"), text: $name)
                }

                Section(String(localized: "training_form_lifecycle")) {
                    Picker(String(localized: "training_status"), selection: $status) {
                        ForEach(TrainingPlanStatus.managementCases, id: \.rawValue) { option in
                            Text(localizedTrainingIdentifier(option.rawValue)).tag(option)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "training_manage_plan"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "save")) {
                        Task {
                            let didSave = await onSave(
                                TrainingPlanUpdateDraft(
                                    id: plan.id,
                                    name: name,
                                    status: status
                                )
                            )
                            if didSave {
                                dismiss()
                            }
                        }
                    }
                    .disabled(isSaving || !hasChanges)
                }
            }
        }
    }

    private var hasChanges: Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedName != plan.name || status.rawValue != plan.status
    }
}

private struct TrainingWeekdayOption: Identifiable {
    let value: Int
    let label: String

    var id: Int { value }
}

private func orderedTrainingWeekdays() -> [TrainingWeekdayOption] {
    let calendar = Calendar.current
    let labels = calendar.veryShortWeekdaySymbols
    let firstIndex = max(0, min(labels.count - 1, calendar.firstWeekday - 1))
    let weekdayValues = Array(0..<labels.count)
    let orderedValues = Array(weekdayValues[firstIndex...]) + Array(weekdayValues[..<firstIndex])
    return orderedValues.map { TrainingWeekdayOption(value: $0, label: labels[$0]) }
}

private func humanized(_ value: String) -> String {
    localizedTrainingIdentifier(value)
}

private func trainingPlanSessionTitle(
    explicitTitle: String?,
    payload: Any?,
    fallbackType: String
) -> String {
    let normalizedExplicitTitle = explicitTitle?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfEmpty
    if let normalizedExplicitTitle {
        return normalizedExplicitTitle
    }
    if let payloadTitle = trainingPlanTitle(from: payload) {
        return payloadTitle
    }
    return humanized(fallbackType)
}

private func trainingPlanTitle(from payload: Any?) -> String? {
    guard let object = trainingPlanJSONObject(from: payload) else { return nil }
    let title = object["title"] as? String
    return title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
}

private func trainingAdaptiveRules(payload: Any?) -> [TrainingAdaptiveRuleSummary] {
    guard let object = trainingPlanJSONObject(from: payload) else { return [] }
    return object.compactMap { key, value in
        guard let adjustment = value as? String else { return nil }
        return TrainingAdaptiveRuleSummary(reason: key, adjustment: adjustment)
    }
    .sorted { $0.reason < $1.reason }
}

private func trainingPlanJSONObject(from payload: Any?) -> [String: Any]? {
    if let data = payload as? Data {
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    if let string = payload as? String {
        return (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? [String: Any]
    }
    return payload as? [String: Any]
}

private func formattedPlanDate(_ value: String) -> String {
    guard let date = DiaryDateFormatter.parseDate(value) else { return value }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: date)
}

private extension TrainingPlanStatus {
    static let managementCases: [TrainingPlanStatus] = [
        .active,
        .paused,
        .completed,
        .archived
    ]
}

private struct TrainingSessionSummary: Identifiable {
    let id: UUID
    let iconName: String
    let primaryText: String
    let secondaryText: String?
    let accessibilitySummary: String

    init?(row: Row) {
        guard let uuid = MixedUUIDStorage.decode(from: row, column: "id") else {
            return nil
        }
        id = uuid

        let workoutType: String? = row["workout_type"]
        let startedAt: Date? = row["started_at"]
        let durationMinutes: Int? = row["duration_minutes"]
        let totalSets: Int? = row["total_sets"]

        iconName = Self.icon(for: workoutType)
        primaryText = Self.primaryLine(startedAt: startedAt, workoutType: workoutType)
        secondaryText = Self.secondaryLine(durationMinutes: durationMinutes, totalSets: totalSets)
        accessibilitySummary = [primaryText, secondaryText].compactMap { $0 }.joined(separator: ", ")
    }

    static func iconName(forPlannedSessionType workoutType: String?) -> String {
        icon(for: workoutType)
    }

    private static func icon(for workoutType: String?) -> String {
        switch workoutType?.lowercased() {
        case "cardio":
            return "figure.run.circle"
        case "mobility":
            return "figure.cooldown"
        case "recovery":
            return "figure.cooldown"
        default:
            return "figure.strengthtraining.traditional"
        }
    }

    private static func primaryLine(startedAt: Date?, workoutType: String?) -> String {
        if let startedAt {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return formatter.string(from: startedAt)
        }
        if let workoutType {
            return localizedTrainingIdentifier(workoutType)
        }
        return String(localized: "training_workout_fallback")
    }

    private static func secondaryLine(durationMinutes: Int?, totalSets: Int?) -> String? {
        var parts: [String] = []
        if let durationMinutes, durationMinutes > 0 {
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .abbreviated
            formatter.allowedUnits = durationMinutes >= 60 ? [.hour, .minute] : [.minute]
            if let duration = formatter.string(from: TimeInterval(durationMinutes * 60)) {
                parts.append(duration)
            }
        }
        if let totalSets, totalSets > 0 {
            parts.append("\(totalSets)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
}

#if DEBUG
private extension TrainingSessionSummary {
    init(
        testId: UUID,
        testIconName: String,
        testPrimaryText: String,
        testSecondaryText: String?
    ) {
        id = testId
        iconName = testIconName
        primaryText = testPrimaryText
        secondaryText = testSecondaryText
        accessibilitySummary = [testPrimaryText, testSecondaryText].compactMap { $0 }.joined(separator: ", ")
    }
}

private extension TrainingSessionSummary {
    static func _testIcon(for workoutType: String?) -> String {
        icon(for: workoutType)
    }

    static func _testPrimaryLine(startedAt: Date?, workoutType: String?) -> String {
        primaryLine(startedAt: startedAt, workoutType: workoutType)
    }

    static func _testSecondaryLine(durationMinutes: Int?, totalSets: Int?) -> String? {
        secondaryLine(durationMinutes: durationMinutes, totalSets: totalSets)
    }
}

struct WorkoutLogCoverageSnapshot {
    let durationTexts: [String]
    let volumeTexts: [String]
    let restLabels: [String]
    let formattedRPEValues: [String]
    let parsedRPEValues: [Int]
    let normalizedTexts: [String?]
    let catalogPriorities: [Int]
    let localizedErrors: [String]
    let sameDayStartMatchesReference: Bool
    let shiftedSessionStart: Date
    let inferredEndDates: [Date]
    let conflictFlags: [Bool]
    let compatibilityFlags: [Bool]
}

struct TrainingPlanCoverageSnapshot {
    let resolvedWorkoutTypes: [WorkoutType?]
    let activeSummaryLine: String?
    let emptySummaryLine: String?
    let singleAdaptiveRuleSummary: String
    let multiAdaptiveRuleSummary: String
    let sessionTitles: [String]
    let adaptiveRuleIds: [String]
    let formattedValidDate: String
    let formattedInvalidDate: String
    let weekdayLabels: [String]
    let upcomingSubtitle: String
    let upcomingIconName: String
    let upcomingSelected: Bool
}

@MainActor
enum TrainingDayViewTestHarness {
    static func exerciseBodyBranches() {
        let loadingVM = TrainingDayViewModel(dateString: "2026-02-24")
        loadingVM._testOverrideState(sessions: [], isLoading: true)
        _ = TrainingDayView(dateString: "2026-02-24", testViewModel: loadingVM).body

        let emptyVM = TrainingDayViewModel(dateString: "2026-02-24")
        emptyVM._testOverrideState(sessions: [], isLoading: false)
        _ = TrainingDayView(dateString: "2026-02-24", testViewModel: emptyVM).body

        let loadedVM = TrainingDayViewModel(dateString: "2026-02-24")
        loadedVM._testOverrideState(sessions: [
            TrainingSessionSummary(
                testId: UUID(),
                testIconName: "figure.run.circle",
                testPrimaryText: "07:30",
                testSecondaryText: "45m • 12"
            )
        ], isLoading: false)
        let loadedView = TrainingDayView(dateString: "2026-02-24", testViewModel: loadedVM)
        _ = loadedView.body
        loadedView._testRenderSessionRows()

        _ = WorkoutLogView().body
    }

    static func loadSessions(
        dateString: String?,
        dbQueue: DatabaseQueue
    ) async -> [String] {
        let viewModel = TrainingDayViewModel(dateString: dateString, dbQueue: dbQueue)
        await viewModel.load()
        return viewModel.sessions.map(\.accessibilitySummary)
    }

    static func runLoadTask(
        dateString: String?,
        dbQueue: DatabaseQueue
    ) async -> Bool {
        let viewModel = TrainingDayViewModel(dateString: dateString, dbQueue: dbQueue)
        let view = TrainingDayView(dateString: dateString, testViewModel: viewModel)
        await view._testRunLoadTask()
        return !viewModel.isLoading
    }

    static func runLoadTaskAction(
        dateString: String?,
        dbQueue: DatabaseQueue
    ) async -> Bool {
        let viewModel = TrainingDayViewModel(dateString: dateString, dbQueue: dbQueue)
        let view = TrainingDayView(dateString: dateString, testViewModel: viewModel)
        await view._testRunLoadTaskAction()
        return !viewModel.isLoading
    }

    static func summaryFormattingCoverageSamples() -> [String] {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let secondaryLineWithSets = TrainingSessionSummary._testSecondaryLine(durationMinutes: 45, totalSets: 12)
        let secondaryLineWithoutSets = TrainingSessionSummary._testSecondaryLine(durationMinutes: 75, totalSets: 0)
        let secondaryLineEmpty = TrainingSessionSummary._testSecondaryLine(durationMinutes: nil, totalSets: nil)

        func resolveOptionalLine(_ value: String?) -> String {
            if let value {
                return value
            }
            return ""
        }

        let secondaryWithSets = resolveOptionalLine(secondaryLineWithSets)
        let secondaryWithoutSets = resolveOptionalLine(secondaryLineWithoutSets)
        let secondaryEmpty = resolveOptionalLine(secondaryLineEmpty)

        return [
            TrainingSessionSummary._testIcon(for: "cardio"),
            TrainingSessionSummary._testIcon(for: "mobility"),
            TrainingSessionSummary._testIcon(for: "strength"),
            TrainingSessionSummary._testPrimaryLine(startedAt: startedAt, workoutType: "cardio"),
            TrainingSessionSummary._testPrimaryLine(startedAt: nil, workoutType: "mobility"),
            TrainingSessionSummary._testPrimaryLine(startedAt: nil, workoutType: nil),
            secondaryWithSets,
            secondaryWithoutSets,
            secondaryEmpty
        ]
    }

    static func editorInputNormalizationSamples() -> (weights: [String], parsedWeights: [Double], reps: [String], parsedReps: [Int]) {
        let weightInputs = [
            WorkoutLogView.formattedWeight(0),
            WorkoutLogView.formattedWeight(80),
            WorkoutLogView.formattedWeight(82.5)
        ]
        let parsedWeights = [
            WorkoutLogView.parseWeight("80"),
            WorkoutLogView.parseWeight("82,5"),
            WorkoutLogView.parseWeight("82.5kg")
        ]
        let repsInputs = [
            WorkoutLogView.formattedReps(0),
            WorkoutLogView.formattedReps(5)
        ]
        let parsedReps = [
            WorkoutLogView.parseReps("5"),
            WorkoutLogView.parseReps("5 reps"),
            WorkoutLogView.parseReps("")
        ]
        return (weightInputs, parsedWeights, repsInputs, parsedReps)
    }

    static func workoutLogHelperCoverageSamples(referenceNow: Date) -> WorkoutLogCoverageSnapshot {
        let durationTexts = [
            WorkoutSummaryMetrics(totalSets: 0, totalVolume: 0, durationMinutes: nil).durationText,
            WorkoutSummaryMetrics(totalSets: 4, totalVolume: 320, durationMinutes: 45).durationText,
            WorkoutSummaryMetrics(totalSets: 6, totalVolume: 500, durationMinutes: 120).durationText,
            WorkoutSummaryMetrics(totalSets: 8, totalVolume: 612.5, durationMinutes: 75).durationText
        ]
        let volumeTexts = [
            WorkoutSummaryMetrics(totalSets: 0, totalVolume: 0, durationMinutes: nil).volumeText(),
            WorkoutSummaryMetrics(totalSets: 4, totalVolume: 320, durationMinutes: 45).volumeText(),
            WorkoutSummaryMetrics(totalSets: 8, totalVolume: 612.5, durationMinutes: 75).volumeText()
        ]
        let restLabels = [
            WorkoutLogView.restDurationLabel(seconds: nil),
            WorkoutLogView.restDurationLabel(seconds: 90),
            WorkoutLogView.restDurationLabel(seconds: 120)
        ]
        let formattedRPEValues = [
            WorkoutLogView.formattedRPE(0),
            WorkoutLogView.formattedRPE(8)
        ]
        let parsedRPEValues = [
            WorkoutLogView.parseRPE(""),
            WorkoutLogView.parseRPE("8"),
            WorkoutLogView.parseRPE("11"),
            WorkoutLogView.parseRPE("RPE 6/10")
        ]
        let normalizedTexts = [
            WorkoutLogViewModel.normalizedText(nil),
            WorkoutLogViewModel.normalizedText("   "),
            WorkoutLogViewModel.normalizedText("  Deadlift  ")
        ]
        let catalogPriorities = [
            WorkoutLogViewModel.catalogMatchPriority(for: "Squat", query: "squat"),
            WorkoutLogViewModel.catalogMatchPriority(for: "Squat Press", query: "squat"),
            WorkoutLogViewModel.catalogMatchPriority(for: "Front Squat", query: "squat")
        ]
        let localizedErrors = [
            WorkoutLogViewModel.localizedErrorDescription(
                for: TrainingError.invalidSet(reason: "Coverage invalid set")
            ),
            WorkoutLogViewModel.localizedErrorDescription(
                for: NSError(domain: "CoverageTraining", code: 7)
            )
        ]

        let targetSameDay = referenceNow
        let targetPastDay = Calendar.current.date(byAdding: .day, value: -2, to: referenceNow) ?? referenceNow
        let sameDayStart = WorkoutLogViewModel.sessionStartDate(
            for: targetSameDay,
            referenceNow: referenceNow
        )
        let shiftedSessionStart = WorkoutLogViewModel.sessionStartDate(
            for: targetPastDay,
            referenceNow: referenceNow
        )

        let explicitEndStart = Date(timeIntervalSince1970: 1_773_331_200)
        var explicitEndSession = WorkoutSession(
            id: UUID(),
            userId: UUID(),
            startedAt: explicitEndStart,
            sessionDate: "2026-03-12",
            source: .manual
        )
        explicitEndSession.endedAt = explicitEndStart.addingTimeInterval(35 * 60)

        let durationOnlyStart = explicitEndStart.addingTimeInterval(2 * 60 * 60)
        var durationOnlySession = WorkoutSession(
            id: UUID(),
            userId: UUID(),
            startedAt: durationOnlyStart,
            sessionDate: "2026-03-12",
            source: .manual
        )
        durationOnlySession.durationMinutes = 50

        let pointInTimeStart = explicitEndStart.addingTimeInterval(4 * 60 * 60)
        let pointInTimeSession = WorkoutSession(
            id: UUID(),
            userId: UUID(),
            startedAt: pointInTimeStart,
            sessionDate: "2026-03-12",
            source: .manual
        )

        var incompatibleExisting = explicitEndSession
        incompatibleExisting.workoutType = .strength

        var incompatibleImported = WorkoutSession(
            id: UUID(),
            userId: explicitEndSession.userId,
            startedAt: explicitEndSession.startedAt,
            sessionDate: explicitEndSession.sessionDate,
            source: .import
        )
        incompatibleImported.endedAt = explicitEndSession.endedAt
        incompatibleImported.durationMinutes = explicitEndSession.durationMinutes
        incompatibleImported.workoutType = .mobility

        var overlapManual = explicitEndSession
        overlapManual.workoutType = .cardio
        overlapManual.durationMinutes = 60
        overlapManual.endedAt = nil

        var overlapImported = WorkoutSession(
            id: UUID(),
            userId: overlapManual.userId,
            startedAt: overlapManual.startedAt.addingTimeInterval(10 * 60),
            sessionDate: overlapManual.sessionDate,
            source: .import
        )
        overlapImported.workoutType = overlapManual.workoutType
        overlapImported.durationMinutes = 40

        var nearbyCardio = explicitEndSession
        nearbyCardio.workoutType = .cardio
        nearbyCardio.durationMinutes = 60
        nearbyCardio.endedAt = nil

        var nearbySport = WorkoutSession(
            id: UUID(),
            userId: nearbyCardio.userId,
            startedAt: nearbyCardio.startedAt.addingTimeInterval(20 * 60),
            sessionDate: nearbyCardio.sessionDate,
            source: .import
        )
        nearbySport.workoutType = .sport
        nearbySport.durationMinutes = 55

        var farOther = explicitEndSession
        farOther.workoutType = .other
        farOther.durationMinutes = 30
        farOther.endedAt = nil

        var farStrength = WorkoutSession(
            id: UUID(),
            userId: farOther.userId,
            startedAt: farOther.startedAt.addingTimeInterval(3 * 60 * 60),
            sessionDate: farOther.sessionDate,
            source: .import
        )
        farStrength.workoutType = .strength
        farStrength.durationMinutes = 90

        return WorkoutLogCoverageSnapshot(
            durationTexts: durationTexts,
            volumeTexts: volumeTexts,
            restLabels: restLabels,
            formattedRPEValues: formattedRPEValues,
            parsedRPEValues: parsedRPEValues,
            normalizedTexts: normalizedTexts,
            catalogPriorities: catalogPriorities,
            localizedErrors: localizedErrors,
            sameDayStartMatchesReference: sameDayStart == referenceNow,
            shiftedSessionStart: shiftedSessionStart,
            inferredEndDates: [
                WorkoutLogViewModel.inferredEndDate(for: explicitEndSession),
                WorkoutLogViewModel.inferredEndDate(for: durationOnlySession),
                WorkoutLogViewModel.inferredEndDate(for: pointInTimeSession)
            ],
            conflictFlags: [
                WorkoutLogViewModel.sessionsConflict(incompatibleExisting, incompatibleImported),
                WorkoutLogViewModel.sessionsConflict(overlapManual, overlapImported),
                WorkoutLogViewModel.sessionsConflict(nearbyCardio, nearbySport),
                WorkoutLogViewModel.sessionsConflict(farOther, farStrength)
            ],
            compatibilityFlags: [
                WorkoutLogViewModel.areCompatibleWorkoutTypes(nil, .strength),
                WorkoutLogViewModel.areCompatibleWorkoutTypes(.cardio, .cardio),
                WorkoutLogViewModel.areCompatibleWorkoutTypes(.mixed, .mobility),
                WorkoutLogViewModel.areCompatibleWorkoutTypes(.cardio, .sport),
                WorkoutLogViewModel.areCompatibleWorkoutTypes(.other, .strength),
                WorkoutLogViewModel.areCompatibleWorkoutTypes(.strength, .mobility)
            ]
        )
    }

    static func trainingPlanCoverageSamples() throws -> TrainingPlanCoverageSnapshot {
        let dbQueue = try DatabaseQueue(path: ":memory:")
        let activePlan = try makePlanOverview(
            dbQueue: dbQueue,
            name: "Coverage Build",
            goal: "hypertrophy",
            status: TrainingPlanStatus.active.rawValue,
            currentWeek: 3,
            daysPerWeek: 4,
            durationWeeks: 8,
            startDate: "2026-03-01",
            endDate: "2026-04-26",
            aiGenerated: true,
            adaptiveRulesPayload: #"{"recovery_low":"reduce_volume_30"}"#
        )
        let archivedPlan = try makePlanOverview(
            dbQueue: dbQueue,
            name: "Archived Coverage",
            goal: "general_fitness",
            status: TrainingPlanStatus.archived.rawValue,
            currentWeek: 1,
            daysPerWeek: nil,
            durationWeeks: nil,
            startDate: nil,
            endDate: nil,
            aiGenerated: false,
            adaptiveRulesPayload: #"{"recovery_low":"reduce_volume_30","user_request":"swap_to_mobility"}"#
        )
        let upcoming = try makeUpcomingSession(dbQueue: dbQueue)

        return TrainingPlanCoverageSnapshot(
            resolvedWorkoutTypes: [
                try makePlannedSession(dbQueue: dbQueue, type: "strength")?.resolvedWorkoutType,
                try makePlannedSession(dbQueue: dbQueue, type: "cardio")?.resolvedWorkoutType,
                try makePlannedSession(dbQueue: dbQueue, type: "mobility")?.resolvedWorkoutType,
                try makePlannedSession(dbQueue: dbQueue, type: "recovery")?.resolvedWorkoutType,
                try makePlannedSession(dbQueue: dbQueue, type: "mixed")?.resolvedWorkoutType,
                try makePlannedSession(dbQueue: dbQueue, type: "sport")?.resolvedWorkoutType,
                try makePlannedSession(dbQueue: dbQueue, type: "dance")?.resolvedWorkoutType
            ],
            activeSummaryLine: activePlan?.summaryLine,
            emptySummaryLine: archivedPlan?.summaryLine,
            singleAdaptiveRuleSummary: activePlan?.adaptiveRuleSummary ?? "",
            multiAdaptiveRuleSummary: archivedPlan?.adaptiveRuleSummary ?? "",
            sessionTitles: [
                trainingPlanSessionTitle(
                    explicitTitle: "  Tempo Intervals  ",
                    payload: nil,
                    fallbackType: "cardio"
                ),
                trainingPlanSessionTitle(
                    explicitTitle: nil,
                    payload: Data(#"{"title":"Posterior Chain Focus"}"#.utf8),
                    fallbackType: "strength"
                ),
                trainingPlanSessionTitle(
                    explicitTitle: nil,
                    payload: #"{"title":"Mobility Restore"}"#,
                    fallbackType: "mobility"
                ),
                trainingPlanSessionTitle(
                    explicitTitle: nil,
                    payload: ["title": "Engine Builder"],
                    fallbackType: "cardio"
                ),
                trainingPlanSessionTitle(
                    explicitTitle: nil,
                    payload: #"{"unexpected":"value"}"#,
                    fallbackType: "sport"
                )
            ],
            adaptiveRuleIds: trainingAdaptiveRules(
                payload: #"{"user_request":"swap_to_mobility","recovery_low":"reduce_volume_30"}"#
            )
            .map(\.id),
            formattedValidDate: formattedPlanDate("2026-03-12"),
            formattedInvalidDate: formattedPlanDate("not-a-date"),
            weekdayLabels: orderedTrainingWeekdays().map(\.label),
            upcomingSubtitle: upcoming?.subtitle ?? "",
            upcomingIconName: upcoming?.iconName ?? "",
            upcomingSelected: upcoming?.isSelectedDate ?? false
        )
    }

    private static func makePlannedSession(
        dbQueue: DatabaseQueue,
        type: String
    ) throws -> PlannedTrainingSessionSummary? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        ? AS id,
                        ? AS plan_id,
                        ? AS plan_name,
                        ? AS plan_goal,
                        ? AS current_week,
                        ? AS session_type,
                        ? AS status,
                        NULL AS title,
                        NULL AS planned_exercises,
                        ? AS planned_duration_minutes
                    """,
                arguments: [
                    UUID().uuidString,
                    UUID().uuidString,
                    "Coverage Plan",
                    "hypertrophy",
                    2,
                    type,
                    "planned",
                    45
                ]
            )
            .flatMap(PlannedTrainingSessionSummary.init(row:))
        }
    }

    private static func makePlanOverview(
        dbQueue: DatabaseQueue,
        name: String,
        goal: String,
        status: String,
        currentWeek: Int,
        daysPerWeek: Int?,
        durationWeeks: Int?,
        startDate: String?,
        endDate: String?,
        aiGenerated: Bool,
        adaptiveRulesPayload: String
    ) throws -> TrainingPlanOverview? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        ? AS id,
                        ? AS name,
                        ? AS goal,
                        ? AS status,
                        ? AS current_week,
                        ? AS days_per_week,
                        ? AS duration_weeks,
                        ? AS start_date,
                        ? AS end_date,
                        ? AS ai_generated,
                        ? AS adaptive_rules
                    """,
                arguments: [
                    UUID().uuidString,
                    name,
                    goal,
                    status,
                    currentWeek,
                    daysPerWeek,
                    durationWeeks,
                    startDate,
                    endDate,
                    aiGenerated,
                    adaptiveRulesPayload
                ]
            )
            .flatMap(TrainingPlanOverview.init(row:))
        }
    }

    private static func makeUpcomingSession(
        dbQueue: DatabaseQueue
    ) throws -> UpcomingTrainingPlanSessionSummary? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        ? AS id,
                        ? AS planned_date,
                        ? AS session_type,
                        ? AS status,
                        ? AS title,
                        ? AS planned_exercises,
                        ? AS planned_duration_minutes
                    """,
                arguments: [
                    UUID().uuidString,
                    "2026-03-12",
                    "recovery",
                    "planned",
                    "  Recovery Flow  ",
                    #"{"title":"Mobility Restore"}"#,
                    35
                ]
            )
            .flatMap { UpcomingTrainingPlanSessionSummary(row: $0, selectedDay: "2026-03-12") }
        }
    }

    static func decodeSummaryCountWithInvalidRows() throws -> Int {
        let dbQueue = try DatabaseQueue(path: ":memory:")
        return try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE tmp_training_rows (
                    id TEXT,
                    started_at DATETIME,
                    duration_minutes INTEGER,
                    workout_type TEXT,
                    total_sets INTEGER
                )
                """)
            try db.execute(
                sql: """
                    INSERT INTO tmp_training_rows (id, started_at, duration_minutes, workout_type, total_sets)
                    VALUES (?, ?, ?, ?, ?), (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString, Date(), 40, "cardio", 8,
                    "not-a-uuid", Date(), 30, "mobility", 5
                ]
            )
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, started_at, duration_minutes, workout_type, total_sets FROM tmp_training_rows"
            )
            return rows.compactMap(TrainingSessionSummary.init(row:)).count
        }
    }
}

private extension TrainingDayView {
    func _testRenderSessionRows() {
        _ = sessionRow(
            TrainingSessionSummary(
                testId: UUID(),
                testIconName: "figure.run.circle",
                testPrimaryText: "07:30",
                testSecondaryText: "45m • 12"
            )
        )
        _ = sessionRow(
            TrainingSessionSummary(
                testId: UUID(),
                testIconName: "figure.cooldown",
                testPrimaryText: "Mobility",
                testSecondaryText: nil
            )
        )
    }

    func _testRunLoadTask() async {
        await runLoadTask(viewModel)
    }

    func _testRunLoadTaskAction() async {
        await runLoadTaskAction()
    }
}
#endif
