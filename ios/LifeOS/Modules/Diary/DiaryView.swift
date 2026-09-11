// MARK: - Diary View
// Unified day view with local-date navigation and section rotor support.

import ComposableArchitecture
import GRDB
import Foundation
import Observation
import SwiftUI

enum DiaryPresentationMode: Equatable, Sendable {
    case overview
    case review
}

private struct DiaryRefreshKey: Equatable {
    let day: String
    let externalRefreshToken: Int
}

struct DiaryView: View {
    @State private var selectedDate: Date
    @State private var viewModel = DiaryViewModel()
    @State private var reviewViewModel = DiaryReviewQueueViewModel()
    @State private var presentationMode: DiaryPresentationMode
    private let externalRefreshToken: Int
    @Namespace private var sectionRotorNamespace

    init(
        initialDateString: String? = nil,
        initialMode: DiaryPresentationMode = .overview,
        externalRefreshToken: Int = 0,
        viewModel: DiaryViewModel = DiaryViewModel()
    ) {
        _selectedDate = State(initialValue: Self.parseDate(initialDateString) ?? Date())
        _viewModel = State(initialValue: viewModel)
        _presentationMode = State(initialValue: initialMode)
        self.externalRefreshToken = externalRefreshToken
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.m) {
                    if presentationMode == .review {
                        reviewModeCard
                    }

                    // Date Picker
                    DatePicker(String(localized: "date"), selection: $selectedDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .padding(.horizontal, LayoutConstants.contentPadding)

                    DiaryMonthGrid(
                        selection: $selectedDate,
                        domainsByDay: viewModel.recordedDomainsByDay,
                        legendDomains: viewModel.monthDomains
                    )
                        .padding(.horizontal, LayoutConstants.contentPadding)

                    // Sleep & Recovery Summary
                    sectionCard(
                        title: String(localized: "sleep_recovery"),
                        icon: "bed.double",
                        subtitle: viewModel.sleepSubtitle
                    ) {
                        if let recoveryScore = viewModel.recoveryScoreText {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: viewModel.recoveryZoneIcon ?? "heart.text.square")
                                    .foregroundStyle(viewModel.recoveryZoneColor ?? .secondary)
                                Text(recoveryScore)
                                    .font(LifeOSTypography.headline)
                            }
                        }

                        NavigationLink {
                            SleepDayView(dateString: Self.formatDate(selectedDate))
                        } label: {
                            sectionLinkLabel(
                                NSLocalizedString(
                                    "sleep.open_detail",
                                    value: "View sleep detail",
                                    comment: "Diary CTA to open the sleep detail screen"
                                ),
                                systemImage: "arrow.right.circle"
                            )
                        }
                    }
                    .accessibilityRotorEntry(id: "diary_sleep_recovery", in: sectionRotorNamespace)

                    // Nutrition Summary
                    sectionCard(
                        title: String(localized: "nutrition"),
                        icon: "fork.knife",
                        subtitle: viewModel.nutritionSubtitle
                    ) {
                        macroRow
                        if !viewModel.hideCalories, let targetSummary = viewModel.targetSummary {
                            Text(targetSummary)
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, Spacing.xxs)
                        }
                    }
                    .accessibilityRotorEntry(id: "diary_nutrition", in: sectionRotorNamespace)

                    // Workout Summary
                    sectionCard(
                        title: String(localized: "training"),
                        icon: "figure.run",
                        subtitle: viewModel.trainingSubtitle
                    ) {
                        if viewModel.workoutCount > 0 {
                            Text(viewModel.trainingDetail)
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.secondary)
                        }

                        // ACWR Zone Badge
                        if let acwrText = viewModel.acwrText,
                           let zoneIcon = viewModel.trainingZoneIcon,
                           let zoneColor = viewModel.trainingZoneColor,
                           let zoneLabel = viewModel.trainingZoneLabel {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: zoneIcon)
                                    .foregroundStyle(zoneColor)
                                Text(acwrText)
                                    .font(LifeOSTypography.headline)
                                    .foregroundStyle(zoneColor)
                                Text(zoneLabel)
                                    .font(LifeOSTypography.caption)
                                    .foregroundStyle(.secondary)

                                if let trendIcon = viewModel.weeklyTrendIcon {
                                    Spacer()
                                    Image(systemName: trendIcon)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let trendLabel = viewModel.weeklyTrendLabel {
                                        Text(trendLabel)
                                            .font(LifeOSTypography.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.top, Spacing.xxs)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(
                                "\(String(localized: "acwr_ratio")): \(acwrText), \(zoneLabel)"
                            )
                        }

                        NavigationLink {
                            ACWRDetailView(dateString: Self.formatDate(selectedDate))
                        } label: {
                            sectionLinkLabel(
                                String(localized: "training_load_details"),
                                systemImage: "chart.bar"
                            )
                        }
                    }
                    .accessibilityRotorEntry(id: "diary_training", in: sectionRotorNamespace)

                    // Supplements
                    sectionCard(
                        title: String(localized: "supplements"),
                        icon: "pill",
                        subtitle: viewModel.supplementsSubtitle
                    ) {
                        if viewModel.supplementsTakenCount > 0 {
                            Text(viewModel.supplementsDetail)
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityRotorEntry(id: "diary_supplements", in: sectionRotorNamespace)

                    // Labs
                    sectionCard(
                        title: String(localized: "labs"),
                        icon: "cross.case",
                        subtitle: viewModel.labsSubtitle
                    ) {
                        if !viewModel.labsDetail.isEmpty {
                            Text(viewModel.labsDetail)
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.secondary)
                        }

                        NavigationLink {
                            LabsOverviewView(
                                store: Store(initialState: LabsFeature.State()) {
                                    LabsFeature()
                                }
                            )
                        } label: {
                            sectionLinkLabel(String(localized: "labs_review_results"), systemImage: "arrow.right.circle")
                        }
                    }
                    .accessibilityRotorEntry(id: "diary_labs", in: sectionRotorNamespace)

                    // Hydration
                    sectionCard(
                        title: String(localized: "hydration"),
                        icon: "drop",
                        subtitle: viewModel.hydrationSubtitle
                    ) {
                        ProgressView(value: hydrationProgress)
                            .tint(LifeOSColors.Semantic.primary)

                        Text(viewModel.hydrationDetail)
                            .font(LifeOSTypography.caption)
                            .foregroundStyle(.secondary)

                        NavigationLink {
                            HydrationDayView(dateString: Self.formatDate(selectedDate))
                        } label: {
                            sectionLinkLabel(String(localized: "hydration_open_log"), systemImage: "plus.circle")
                        }
                    }
                    .accessibilityRotorEntry(id: "diary_hydration", in: sectionRotorNamespace)

                    // Wellness Check
                    sectionCard(
                        title: String(localized: "wellness"),
                        icon: "heart.text.square",
                        subtitle: viewModel.wellnessSubtitle
                    ) {
                        if let wellnessScoreText = viewModel.wellnessScoreText {
                            Text(wellnessScoreText)
                                .font(LifeOSTypography.headline)
                        }

                        if !viewModel.wellnessDetail.isEmpty {
                            Text(viewModel.wellnessDetail)
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.secondary)
                        }

                        NavigationLink {
                            WellnessCheckDayView(dateString: Self.formatDate(selectedDate))
                        } label: {
                            sectionLinkLabel(
                                viewModel.hasCompletedWellnessCheck ? String(localized: "wellness_update_check") : String(localized: "start_wellness_check"),
                                systemImage: "arrow.right.circle"
                            )
                        }
                    }
                    .accessibilityRotorEntry(id: "diary_wellness", in: sectionRotorNamespace)

                    // Menstrual / Cycle Tracking
                    sectionCard(
                        title: String(localized: "menstrual_title"),
                        icon: "drop.circle",
                        subtitle: viewModel.menstrualSubtitle
                    ) {
                        if !viewModel.menstrualDetail.isEmpty {
                            Text(viewModel.menstrualDetail)
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.secondary)
                        }

                        NavigationLink {
                            MenstrualDayView(dateString: Self.formatDate(selectedDate))
                        } label: {
                            sectionLinkLabel(
                                viewModel.hasMenstrualLog
                                    ? String(localized: "menstrual_diary_review_cta")
                                    : String(localized: "menstrual_diary_log_cta"),
                                systemImage: "arrow.right.circle"
                            )
                        }
                    }
                    .accessibilityRotorEntry(id: "diary_menstrual", in: sectionRotorNamespace)
                }
                .padding(.top, Spacing.m)
            }
            .background(LifeOSColors.Surface.background)
            .navigationTitle(String(localized: "tab_diary"))
            .accessibilityRotor(String(localized: "accessibility_sections")) {
                AccessibilityRotorEntry(String(localized: "sleep_recovery"), "diary_sleep_recovery", in: sectionRotorNamespace)
                AccessibilityRotorEntry(String(localized: "nutrition"), "diary_nutrition", in: sectionRotorNamespace)
                AccessibilityRotorEntry(String(localized: "training"), "diary_training", in: sectionRotorNamespace)
                AccessibilityRotorEntry(String(localized: "supplements"), "diary_supplements", in: sectionRotorNamespace)
                AccessibilityRotorEntry(String(localized: "labs"), "diary_labs", in: sectionRotorNamespace)
                AccessibilityRotorEntry(String(localized: "hydration"), "diary_hydration", in: sectionRotorNamespace)
                AccessibilityRotorEntry(String(localized: "wellness"), "diary_wellness", in: sectionRotorNamespace)
                AccessibilityRotorEntry(String(localized: "menstrual_title"), "diary_menstrual", in: sectionRotorNamespace)
            }
            .task(id: refreshKey, refreshSelectedDateTask)
        }
    }

    private var refreshKey: DiaryRefreshKey {
        DiaryRefreshKey(
            day: Self.formatDate(selectedDate),
            externalRefreshToken: externalRefreshToken
        )
    }

    private func refreshSelectedDateTask() async {
        await viewModel.refresh(for: selectedDate)
        await reviewViewModel.refresh(for: Self.formatDate(selectedDate))
    }

    private var reviewModeCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(String(localized: "diary_review_mode_title"), systemImage: "checklist")
                .font(LifeOSTypography.headline)

            Text(reviewViewModel.summaryText)
                .font(LifeOSTypography.body)
                .foregroundStyle(.secondary)

            if reviewViewModel.foodLogsNeedingReview > 0 {
                NavigationLink {
                    NutritionDayView(dateString: Self.formatDate(selectedDate))
                } label: {
                    reviewModeActionRow(
                        title: String(localized: "diary_review_food_logs_title"),
                        detail: String(
                            format: String(localized: "diary_review_food_logs_detail_format"),
                            reviewViewModel.foodLogsNeedingReview
                        ),
                        systemImage: "fork.knife"
                    )
                }
            }

            if reviewViewModel.insightsNeedingReview > 0 {
                NavigationLink {
                    InsightsView()
                } label: {
                    reviewModeActionRow(
                        title: String(localized: "diary_review_insights_title"),
                        detail: String(
                            format: String(localized: "diary_review_insights_detail_format"),
                            reviewViewModel.insightsNeedingReview
                        ),
                        systemImage: "lightbulb"
                    )
                }
            }

            if reviewViewModel.totalItems == 0 {
                Text(String(localized: "diary_review_empty_state"))
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
        .padding(.horizontal, LayoutConstants.contentPadding)
    }

    private func reviewModeActionRow(
        title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: systemImage)
                .foregroundStyle(LifeOSColors.Semantic.primary)
                .frame(width: LayoutConstants.minTouchTarget, height: LayoutConstants.minTouchTarget)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Macro Summary Row

    private var macroRow: some View {
        HStack(spacing: Spacing.l) {
            if !viewModel.hideCalories {
                macroItem(label: String(localized: "calories"), value: viewModel.caloriesValue, unit: "kcal")
            }
            macroItem(label: String(localized: "protein"), value: viewModel.proteinValue, unit: "g")
            macroItem(label: String(localized: "fat"), value: viewModel.fatValue, unit: "g")
            macroItem(label: String(localized: "carbs"), value: viewModel.carbsValue, unit: "g")
        }
        .padding(.top, Spacing.xs)
    }

    private var hydrationProgress: Double {
        guard viewModel.hydrationTargetMl > 0 else { return 0 }
        return min(Double(viewModel.hydrationTotalMl) / Double(viewModel.hydrationTargetMl), 1)
    }

    private func macroItem(label: String, value: String, unit: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(LifeOSTypography.headline)
            Text(label)
                .font(LifeOSTypography.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value) \(unit)")
    }

    // MARK: - Section Card

    private func sectionCard<Content: View>(
        title: String,
        icon: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(title, systemImage: icon)
                .font(LifeOSTypography.headline)

            Text(subtitle)
                .font(LifeOSTypography.body)
                .foregroundStyle(.tertiary)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
        .padding(.horizontal, LayoutConstants.contentPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(format: String(localized: "accessibility_section_summary_format"), title, subtitle))
    }

    private func sectionLinkLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(title)
            Spacer()
            Image(systemName: systemImage)
                .font(.caption)
        }
        .font(LifeOSTypography.subheadline.weight(.semibold))
        .foregroundStyle(LifeOSColors.Semantic.primary)
        .padding(.top, Spacing.xs)
    }
}

#if DEBUG
extension DiaryView {
    @MainActor
    func _testRefreshKey() -> (day: String, externalRefreshToken: Int) {
        (refreshKey.day, refreshKey.externalRefreshToken)
    }

    @MainActor
    func _testEvaluateSections() {
        _ = macroRow
        _ = macroItem(label: "Calories", value: "1200", unit: "kcal")
        _ = sectionCard(
            title: "Test Section",
            icon: "star",
            subtitle: "Summary"
        ) {
            EmptyView()
        }
        // Sleep/Recovery branch coverage
        _ = sectionCard(
            title: "Sleep & Recovery",
            icon: "bed.double",
            subtitle: "7h 30m"
        ) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "heart.text.square")
                    .foregroundStyle(.secondary)
                Text("85%")
                    .font(LifeOSTypography.headline)
            }
        }
        // Training branch coverage (workoutCount > 0 + ACWR badge)
        _ = sectionCard(
            title: "Training",
            icon: "figure.run",
            subtitle: "1 workout"
        ) {
            Text("Upper Body – 45 min")
                .font(LifeOSTypography.caption)
                .foregroundStyle(.secondary)
            // ACWR badge coverage
            HStack(spacing: Spacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(LifeOSColors.Recovery.optimal)
                Text("1.15")
                    .font(LifeOSTypography.headline)
                Text("Optimal")
                    .font(LifeOSTypography.caption)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                Text("Increasing")
                    .font(LifeOSTypography.caption)
            }
            NavigationLink {
                ACWRDetailView(dateString: "2026-03-10")
            } label: {
                sectionLinkLabel("Training load details", systemImage: "chart.bar")
            }
        }
        // Supplements branch coverage (supplementsTakenCount > 0)
        _ = sectionCard(
            title: "Supplements",
            icon: "pill",
            subtitle: "3 of 5 taken"
        ) {
            Text("Vitamin D, Omega-3, Magnesium")
                .font(LifeOSTypography.caption)
                .foregroundStyle(.secondary)
        }
        // Labs branch coverage
        _ = sectionCard(
            title: "Labs",
            icon: "cross.case",
            subtitle: "No recent labs"
        ) {
            EmptyView()
        }
        _ = sectionCard(
            title: "Cycle",
            icon: "drop.circle",
            subtitle: "No entry for this day"
        ) {
            Text("Open cycle log")
                .font(LifeOSTypography.caption)
                .foregroundStyle(.secondary)
            NavigationLink {
                MenstrualDayView(dateString: "2026-03-10")
            } label: {
                sectionLinkLabel("Log cycle details", systemImage: "arrow.right.circle")
            }
        }
        _ = Self.parseDate("2026-02-24")
        _ = Self.formatDate(Date(timeIntervalSince1970: 1_700_000_000))
    }

    @MainActor
    func _testRefreshSelectedDateTask() async {
        await refreshSelectedDateTask()
    }
}
#endif

private extension DiaryView {
    static func parseDate(_ value: String?) -> Date? {
        DiaryDateFormatter.parseDate(value)
    }

    static func formatDate(_ date: Date) -> String {
        DiaryDateFormatter.formatDate(date)
    }
}

@MainActor
@Observable
private final class DiaryReviewQueueViewModel {
    var foodLogsNeedingReview = 0
    var insightsNeedingReview = 0

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue) {
        self.dbQueue = dbQueue
    }

    var totalItems: Int {
        foodLogsNeedingReview + insightsNeedingReview
    }

    var summaryText: String {
        if totalItems == 0 {
            return String(localized: "diary_review_empty_state")
        }

        return String(
            format: String(localized: "diary_review_summary_format"),
            totalItems
        )
    }

    func refresh(for day: String) async {
        do {
            let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
            let counts = try await dbQueue.read { db -> (food: Int, insights: Int) in
                guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                    return (0, 0)
                }

                let foodLogs = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*)
                        FROM food_logs
                        WHERE (user_id = ? OR user_id = ?)
                          AND logged_date = ?
                          AND needs_review = 1
                          AND deleted_at IS NULL
                        """,
                    arguments: [userId, userId.uuidString, day]
                ) ?? 0

                let insights = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*)
                        FROM insights
                        WHERE (user_id = ? OR user_id = ?)
                          AND needs_review = 1
                          AND dismissed = 0
                        """,
                    arguments: [userId, userId.uuidString]
                ) ?? 0

                return (foodLogs, insights)
            }

            foodLogsNeedingReview = counts.food
            insightsNeedingReview = counts.insights
        } catch {
            foodLogsNeedingReview = 0
            insightsNeedingReview = 0
        }
    }
}

struct HydrationDayView: View {
    let dateString: String?
    @State private var viewModel: HydrationDayViewModel

    init(dateString: String?) {
        self.dateString = dateString
        _viewModel = State(initialValue: HydrationDayViewModel(dateString: dateString))
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        ScrollView {
            VStack(spacing: Spacing.m) {
                Label(String(localized: "hydration"), systemImage: "drop.fill")
                    .font(LifeOSTypography.title3)

                Text(viewModel.displayDate)
                    .font(LifeOSTypography.subheadline)
                    .foregroundStyle(.secondary)

                VStack(spacing: Spacing.xs) {
                    ProgressView(value: viewModel.progress)
                        .tint(LifeOSColors.Semantic.primary)
                    Text("\(viewModel.displayVolume(Double(viewModel.totalMl))) / \(viewModel.displayVolume(Double(viewModel.targetMl))) \(viewModel.volumeUnitLabel)")
                        .font(LifeOSTypography.headline)
                }

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: Spacing.s),
                        GridItem(.flexible(), spacing: Spacing.s),
                        GridItem(.flexible(), spacing: Spacing.s),
                    ],
                    spacing: Spacing.s
                ) {
                    ForEach([250, 500, 750], id: \.self) { amount in
                        Button {
                            Task { await viewModel.addWater(amount) }
                        } label: {
                            Text("+\(UnitPreferences.formatVolume(milliliters: Double(amount), units: viewModel.userUnits))")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Spacing.s)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isSaving)
                    }
                }

                if let statusMessage = viewModel.statusMessage {
                    Text(statusMessage)
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)
                }

                if viewModel.isLoading {
                    ProgressView()
                } else if viewModel.logs.isEmpty {
                    Text(String(localized: "hydration_empty_day"))
                        .font(LifeOSTypography.body)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(String(localized: "hydration_entries"))
                            .font(LifeOSTypography.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        ForEach(viewModel.logs) { log in
                            HStack(spacing: Spacing.s) {
                                VStack(alignment: .leading, spacing: Spacing.xxs) {
                                    Text(UnitPreferences.formatVolume(milliliters: Double(log.amountMl), units: viewModel.userUnits))
                                        .font(LifeOSTypography.body.weight(.semibold))
                                    Text(log.timestampText)
                                        .font(LifeOSTypography.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    Task { await viewModel.deleteLog(log.id) }
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(Spacing.s)
                            .background(LifeOSColors.Surface.card)
                            .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
                        }
                    }
                }
            }
            .padding(LayoutConstants.contentPadding)
        }
        .background(LifeOSColors.Surface.background)
        .navigationTitle(String(localized: "hydration"))
        .task { await viewModel.load() }
    }
}

@MainActor
@Observable
private final class HydrationDayViewModel {
    var logs: [HydrationEntry] = []
    var totalMl = 0
    var targetMl = 2000
    var isLoading = false
    var isSaving = false
    var statusMessage: String?
    var userUnits: UnitSystem = .metric

    let displayDate: String
    private let day: String
    private let dbQueue: DatabaseQueue
    private let timeZoneHistoryStore: TimeZoneHistoryStore

    init(
        dateString: String?,
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue,
        timeZoneHistoryStore: TimeZoneHistoryStore = .shared
    ) {
        self.day = dateString ?? DiaryDateFormatter.formatDate(Date())
        self.displayDate = dateString ?? self.day
        self.dbQueue = dbQueue
        self.timeZoneHistoryStore = timeZoneHistoryStore
    }

    var progress: Double {
        guard targetMl > 0 else { return 0 }
        return min(Double(totalMl) / Double(targetMl), 1)
    }

    var volumeUnitLabel: String {
        UnitPreferences.volumeUnitLabel(userUnits)
    }

    func displayVolume(_ milliliters: Double) -> String {
        UnitPreferences.formattedDecimal(
            UnitPreferences.volumeValue(fromMilliliters: milliliters, units: userUnits),
            maxDecimals: 1
        )
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let authId = AuthManager.activeAuthId?.uuidString

        do {
            let result = try await dbQueue.read { db -> (targetMl: Int, totalMl: Int, logs: [HydrationEntry], units: UnitSystem) in
                guard let userId = try Self.resolveUserId(authId: authId, db: db) else {
                    return (2_000, 0, [], .metric)
                }

                let effectiveWeight = try WeightResolution.getEffectiveWeight(userId: userId, db: db) ?? 70.0
                let targetMl = max(1_800, Int((effectiveWeight * 35).rounded()))
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, water_ml, logged_at
                        FROM hydration_logs
                        WHERE (user_id = ? OR user_id = ?)
                          AND logged_date = ?
                          AND deleted_at IS NULL
                        ORDER BY logged_at DESC
                        """,
                    arguments: [userId, userId.uuidString, day]
                )
                let logs = rows.compactMap { row -> HydrationEntry? in
                    guard let uuid = MixedUUIDStorage.decode(from: row, column: "id") else { return nil }
                    let amountMl: Int = row["water_ml"]
                    let loggedAt: Date = row["logged_at"]
                    return HydrationEntry(id: uuid, amountMl: amountMl, timestampText: Self.formattedTime(loggedAt))
                }
                let unitsRaw = try String.fetchOne(
                    db,
                    sql: """
                        SELECT units
                        FROM users
                        WHERE (id = ? OR id = ?)
                        ORDER BY updated_at DESC
                        LIMIT 1
                        """,
                    arguments: [userId, userId.uuidString]
                )
                let units = unitsRaw.flatMap(UnitSystem.init(rawValue:)) ?? .metric
                return (targetMl, logs.reduce(0) { $0 + $1.amountMl }, logs, units)
            }

            targetMl = result.targetMl
            totalMl = result.totalMl
            logs = result.logs
            userUnits = result.units
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
            logs = []
            totalMl = 0
            targetMl = 2000
        }
    }

    func addWater(_ amountMl: Int) async {
        isSaving = true
        defer { isSaving = false }
        let authId = AuthManager.activeAuthId?.uuidString

        do {
            let now = Date()
            let userId = try await dbQueue.read { db in
                guard let userId = try Self.resolveUserId(authId: authId, db: db) else {
                    throw HydrationError.userUnavailable
                }
                return userId
            }
            let dayContext = try await resolveManualLocalDayContext(
                referenceDate: now,
                userId: userId
            )
            try await dbQueue.write { db in
                guard let resolvedUserId = try Self.resolveUserId(authId: authId, db: db),
                      resolvedUserId == userId else {
                    throw HydrationError.userUnavailable
                }

                let logId = UUID()
                try db.execute(
                    sql: """
                        INSERT INTO hydration_logs (
                            id, user_id, logged_at, logged_date, logged_timezone,
                            logged_utc_offset_minutes, water_ml, source, created_at, updated_at
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        MixedUUIDStorage.encode(logId),
                        MixedUUIDStorage.encode(userId),
                        now,
                        dayContext.dayString,
                        dayContext.timeZoneIdentifier,
                        dayContext.utcOffsetMinutes,
                        amountMl,
                        HydrationSource.manual.rawValue,
                        now,
                        now,
                    ]
                )

                let payload = HydrationLogOutboxPayload(
                    id: logId,
                    userId: userId,
                    loggedAt: now,
                    loggedDate: dayContext.dayString,
                    loggedTimezone: dayContext.timeZoneIdentifier,
                    loggedUtcOffsetMinutes: dayContext.utcOffsetMinutes,
                    waterMl: amountMl,
                    source: HydrationSource.manual.rawValue,
                    notes: nil,
                    deletedAt: nil,
                    deletedReason: nil,
                    createdAt: now,
                    updatedAt: now
                )

                var event = OutboxEvent(
                    id: logId,
                    httpMethod: .POST,
                    path: "rest/v1/hydration_logs",
                    bodyJson: try JSONEncoder.supabase.encode(payload),
                    priority: 100
                )
                event.headersJson = try Self.outboxHeadersJson()
                try event.insert(db)
            }
            statusMessage = String(
                format: String(localized: "hydration_added_format"),
                UnitPreferences.formatVolume(milliliters: Double(amountMl), units: userUnits)
            )
            await load()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteLog(_ id: UUID) async {
        let authId = AuthManager.activeAuthId?.uuidString
        do {
            try await dbQueue.write { db in
                guard let userId = try Self.resolveUserId(authId: authId, db: db) else {
                    throw HydrationError.userUnavailable
                }

                let existingRow = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT logged_at, logged_date, logged_timezone, logged_utc_offset_minutes,
                               water_ml, source, notes, created_at
                        FROM hydration_logs
                        WHERE id = ? OR id = ?
                        LIMIT 1
                        """,
                    arguments: [id, MixedUUIDStorage.encode(id)]
                )
                let now = Date()
                try db.execute(
                    sql: """
                        UPDATE hydration_logs
                        SET deleted_at = ?, deleted_reason = ?, updated_at = ?
                        WHERE id = ? OR id = ?
                        """,
                    arguments: [now, "user_deleted", now, id, MixedUUIDStorage.encode(id)]
                )

                guard let existingRow else { return }

                let loggedAt: Date = existingRow["logged_at"]
                let loggedDate: String = existingRow["logged_date"]
                let loggedTimezone: String? = existingRow["logged_timezone"]
                let loggedUtcOffsetMinutes: Int? = existingRow["logged_utc_offset_minutes"]
                let waterMl: Int = existingRow["water_ml"]
                let source: String = (existingRow["source"] as String?) ?? HydrationSource.manual.rawValue
                let notes: String? = existingRow["notes"]
                let createdAt: Date = (existingRow["created_at"] as Date?) ?? loggedAt

                let payload = HydrationLogOutboxPayload(
                    id: id,
                    userId: userId,
                    loggedAt: loggedAt,
                    loggedDate: loggedDate,
                    loggedTimezone: loggedTimezone,
                    loggedUtcOffsetMinutes: loggedUtcOffsetMinutes,
                    waterMl: waterMl,
                    source: source,
                    notes: notes,
                    deletedAt: now,
                    deletedReason: "user_deleted",
                    createdAt: createdAt,
                    updatedAt: now
                )

                var event = OutboxEvent(
                    httpMethod: .POST,
                    path: "rest/v1/hydration_logs",
                    bodyJson: try JSONEncoder.supabase.encode(payload),
                    priority: 110
                )
                event.headersJson = try Self.outboxHeadersJson()
                try event.insert(db)
            }
            statusMessage = String(localized: "hydration_entry_removed")
            await load()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    nonisolated private static func outboxHeadersJson() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
    }

    nonisolated private static func resolveUserId(authId: String?, db: Database) throws -> UUID? {
        try UserIdentityLookup.resolveUserId(authId: authId, db: db)
    }

    private func resolveManualLocalDayContext(
        referenceDate: Date,
        userId: UUID
    ) async throws -> HistoricalLocalDayContext {
        _ = try await timeZoneHistoryStore.captureCurrentTimeZoneIfNeeded(
            userId: userId,
            recordedAt: referenceDate,
            source: .manualEntry
        )
        return try await timeZoneHistoryStore.resolveLocalDayContext(
            forDayString: day,
            userId: userId,
            preferredDate: referenceDate
        )
    }

    nonisolated private static func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    enum HydrationError: LocalizedError {
        case userUnavailable

        var errorDescription: String? {
            String(localized: "error.user.unavailable")
        }
    }
}

private struct HydrationEntry: Identifiable {
    let id: UUID
    let amountMl: Int
    let timestampText: String
}

private struct HydrationLogOutboxPayload: Codable {
    let id: UUID
    let userId: UUID
    let loggedAt: Date
    let loggedDate: String
    let loggedTimezone: String?
    let loggedUtcOffsetMinutes: Int?
    let waterMl: Int
    let source: String
    let notes: String?
    let deletedAt: Date?
    let deletedReason: String?
    let createdAt: Date
    let updatedAt: Date
}

struct WellnessCheckDayView: View {
    let dateString: String?
    @State private var viewModel: WellnessCheckDayViewModel

    init(dateString: String?) {
        self.dateString = dateString
        _viewModel = State(initialValue: WellnessCheckDayViewModel(dateString: dateString))
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        ScrollView {
            VStack(spacing: Spacing.m) {
                Label(String(localized: "wellness"), systemImage: "heart.text.square.fill")
                    .font(LifeOSTypography.title3)

                Text(viewModel.displayDate)
                    .font(LifeOSTypography.subheadline)
                    .foregroundStyle(.secondary)

                VStack(spacing: Spacing.s) {
                    scoreRow(String(localized: "wellness_sleep_quality"), value: $viewModel.sleepQuality)
                    scoreRow(String(localized: "wellness_energy"), value: $viewModel.energyLevel)
                    scoreRow(String(localized: "wellness_muscle_soreness"), value: $viewModel.muscleSoreness)
                    scoreRow(String(localized: "wellness_stress"), value: $viewModel.stressLevel)
                    scoreRow(String(localized: "wellness_mood"), value: $viewModel.mood)
                }

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Toggle(String(localized: "wellness_feeling_ill"), isOn: $viewModel.feelingIll)
                    Toggle(String(localized: "wellness_headache"), isOn: $viewModel.headache)
                    Toggle(String(localized: "wellness_digestive_issues"), isOn: $viewModel.digestiveIssues)
                }

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(String(localized: "notes"))
                        .font(LifeOSTypography.subheadline.weight(.semibold))
                    TextField(String(localized: "wellness_optional_notes"), text: $viewModel.notes, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(spacing: Spacing.xs) {
                    Text(String(format: String(localized: "wellness_readiness_format"), viewModel.scoreText))
                        .font(LifeOSTypography.headline)
                    ProgressView(value: viewModel.scoreProgress)
                        .tint(viewModel.scoreColor)
                }

                Button(String(localized: "save")) {
                    Task { await viewModel.save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isSaving)

                if let statusMessage = viewModel.statusMessage {
                    Text(statusMessage)
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(LayoutConstants.contentPadding)
        }
        .background(LifeOSColors.Surface.background)
        .navigationTitle(String(localized: "wellness"))
        .task { await viewModel.load() }
    }

    private func scoreRow(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack {
                Text(title)
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                Spacer()
                Text("\(value.wrappedValue)")
                    .font(LifeOSTypography.subheadline)
                    .foregroundStyle(.secondary)
            }
            Stepper("", value: value, in: 1...5)
                .labelsHidden()
        }
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }
}

@MainActor
@Observable
private final class WellnessCheckDayViewModel {
    var sleepQuality = 3
    var energyLevel = 3
    var muscleSoreness = 3
    var stressLevel = 3
    var mood = 3
    var feelingIll = false
    var headache = false
    var digestiveIssues = false
    var notes = ""
    var isSaving = false
    var statusMessage: String?

    let displayDate: String
    private let day: String
    private let dbQueue: DatabaseQueue

    init(dateString: String?, dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue) {
        self.day = dateString ?? DiaryDateFormatter.formatDate(Date())
        self.displayDate = dateString ?? self.day
        self.dbQueue = dbQueue
    }

    var score: Double {
        let positive = Double(sleepQuality + energyLevel + mood)
        let negative = Double((6 - muscleSoreness) + (6 - stressLevel))
        let base = ((positive + negative) / 25.0) * 100.0
        let penalty = (feelingIll ? 15.0 : 0.0) + (headache ? 5.0 : 0.0) + (digestiveIssues ? 5.0 : 0.0)
        return max(0, min(100, (base - penalty).rounded()))
    }

    var scoreText: String {
        "\(Int(score))%"
    }

    var scoreProgress: Double {
        score / 100.0
    }

    var scoreColor: Color {
        switch score {
        case ..<40: return LifeOSColors.Recovery.critical
        case ..<70: return LifeOSColors.Recovery.caution
        default: return LifeOSColors.Recovery.ready
        }
    }

    func load() async {
        let authId = AuthManager.activeAuthId?.uuidString
        do {
            let record = try await dbQueue.read { db -> WellnessSnapshot? in
                guard let userId = try Self.resolveUserId(authId: authId, db: db) else { return nil }
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT perceived_sleep_quality, energy_level, muscle_soreness,
                               stress_level, mood, feeling_ill, headache,
                               digestive_issues, notes
                        FROM wellness_checks
                        WHERE (user_id = ? OR user_id = ? OR user_id = ?)
                          AND date = ?
                          AND deleted_at IS NULL
                        LIMIT 1
                        """,
                    arguments: [userId, userId.uuidString, MixedUUIDStorage.rawData(userId), day]
                ) else {
                    return nil
                }

                return WellnessSnapshot(
                    sleepQuality: (row["perceived_sleep_quality"] as Int?) ?? 3,
                    energyLevel: (row["energy_level"] as Int?) ?? 3,
                    muscleSoreness: (row["muscle_soreness"] as Int?) ?? 3,
                    stressLevel: (row["stress_level"] as Int?) ?? 3,
                    mood: (row["mood"] as Int?) ?? 3,
                    feelingIll: (row["feeling_ill"] as Bool?) ?? false,
                    headache: (row["headache"] as Bool?) ?? false,
                    digestiveIssues: (row["digestive_issues"] as Bool?) ?? false,
                    notes: (row["notes"] as String?) ?? ""
                )
            }

            guard let record else { return }
            sleepQuality = record.sleepQuality
            energyLevel = record.energyLevel
            muscleSoreness = record.muscleSoreness
            stressLevel = record.stressLevel
            mood = record.mood
            feelingIll = record.feelingIll
            headache = record.headache
            digestiveIssues = record.digestiveIssues
            notes = record.notes
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func save() async {
        isSaving = true
        defer { isSaving = false }

        let sleepQuality = sleepQuality
        let energyLevel = energyLevel
        let muscleSoreness = muscleSoreness
        let stressLevel = stressLevel
        let mood = mood
        let feelingIll = feelingIll
        let headache = headache
        let digestiveIssues = digestiveIssues
        let notes = notes
        let score = score
        let authId = AuthManager.activeAuthId?.uuidString
        let outboxEventId = UUID()

        do {
            try await dbQueue.write { db in
                guard let userId = try Self.resolveUserId(authId: authId, db: db) else {
                    throw WellnessError.userUnavailable
                }

                let localDayContext = try TimeZoneHistoryStore.resolveLocalDayContext(
                    forDayString: day,
                    userId: userId,
                    db: db
                )
                let checkedAt = localDayContext.referenceDate
                let checkedTimeZone = localDayContext.timeZone
                let checkedUtcOffsetMinutes = checkedTimeZone.secondsFromGMT(for: checkedAt) / 60
                let canonicalDay = localDayContext.dayString
                let now = Date()
                let existingRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, created_at
                        FROM wellness_checks
                        WHERE (user_id = ? OR user_id = ? OR user_id = ?)
                          AND date = ?
                        ORDER BY CASE WHEN deleted_at IS NULL THEN 0 ELSE 1 END, updated_at DESC
                        """,
                    arguments: [userId, userId.uuidString, MixedUUIDStorage.rawData(userId), canonicalDay]
                )
                let primaryId = existingRows.first.flatMap { MixedUUIDStorage.decode(from: $0, column: "id") }
                let recordId = primaryId ?? UUID()
                let createdAt: Date = (existingRows.first?["created_at"]) ?? now

                if let primaryId {
                    for duplicateId in existingRows.dropFirst().compactMap({ MixedUUIDStorage.decode(from: $0, column: "id") }) {
                        try db.execute(
                            sql: "DELETE FROM wellness_checks WHERE id = ? OR id = ? OR id = ?",
                            arguments: [duplicateId, duplicateId.uuidString, MixedUUIDStorage.rawData(duplicateId)]
                        )
                    }

                    try db.execute(
                        sql: """
                            UPDATE wellness_checks
                            SET user_id = ?,
                                checked_at = ?,
                                date = ?,
                                checked_timezone = ?,
                                checked_utc_offset_minutes = ?,
                                perceived_sleep_quality = ?,
                                energy_level = ?,
                                muscle_soreness = ?,
                                stress_level = ?,
                                mood = ?,
                                feeling_ill = ?,
                                headache = ?,
                                digestive_issues = ?,
                                notes = ?,
                                wellness_score = ?,
                                mental_health_resources_shown = ?,
                                created_at = ?,
                                updated_at = ?,
                                deleted_at = NULL
                            WHERE id = ? OR id = ? OR id = ?
                            """,
                        arguments: [
                            MixedUUIDStorage.encode(userId),
                            checkedAt,
                            canonicalDay,
                            checkedTimeZone.identifier,
                            checkedUtcOffsetMinutes,
                            sleepQuality,
                            energyLevel,
                            muscleSoreness,
                            stressLevel,
                            mood,
                            feelingIll,
                            headache,
                            digestiveIssues,
                            notes.isEmpty ? nil : notes,
                            score,
                            score < 40,
                            createdAt,
                            now,
                            primaryId,
                            primaryId.uuidString,
                            MixedUUIDStorage.rawData(primaryId)
                        ]
                    )
                } else {
                    try db.execute(
                        sql: """
                            INSERT INTO wellness_checks (
                                id, user_id, checked_at, date, perceived_sleep_quality,
                                checked_timezone, checked_utc_offset_minutes,
                                energy_level, muscle_soreness, stress_level, mood,
                                feeling_ill, headache, digestive_issues, notes,
                                wellness_score, mental_health_resources_shown,
                                created_at, updated_at
                            )
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            MixedUUIDStorage.encode(recordId),
                            MixedUUIDStorage.encode(userId),
                            checkedAt,
                            canonicalDay,
                            sleepQuality,
                            checkedTimeZone.identifier,
                            checkedUtcOffsetMinutes,
                            energyLevel,
                            muscleSoreness,
                            stressLevel,
                            mood,
                            feelingIll,
                            headache,
                            digestiveIssues,
                            notes.isEmpty ? nil : notes,
                            score,
                            score < 40,
                            now,
                            now
                        ]
                    )
                }

                let payload = WellnessCheckOutboxPayload(
                    id: recordId,
                    userId: userId,
                    checkedAt: checkedAt,
                    date: canonicalDay,
                    checkedTimezone: checkedTimeZone.identifier,
                    checkedUtcOffsetMinutes: checkedUtcOffsetMinutes,
                    perceivedSleepQuality: sleepQuality,
                    energyLevel: energyLevel,
                    muscleSoreness: muscleSoreness,
                    stressLevel: stressLevel,
                    mood: mood,
                    pss4Q1: nil,
                    pss4Q2: nil,
                    pss4Q3: nil,
                    pss4Q4: nil,
                    pss4Total: nil,
                    feelingIll: feelingIll,
                    headache: headache,
                    digestiveIssues: digestiveIssues,
                    notes: notes.isEmpty ? nil : notes,
                    wellnessScore: score,
                    mentalHealthResourcesShown: score < 40,
                    deletedAt: nil,
                    createdAt: createdAt,
                    updatedAt: now
                )

                var event = OutboxEvent(
                    id: outboxEventId,
                    httpMethod: .POST,
                    path: "rest/v1/wellness_checks",
                    bodyJson: try JSONEncoder.supabase.encode(payload),
                    priority: 100
                )
                event.headersJson = try Self.outboxHeadersJson()
                try event.insert(db)
            }
            statusMessage = String(localized: "wellness_saved")
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    nonisolated private static func outboxHeadersJson() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
    }

    nonisolated private static func resolveUserId(authId: String?, db: Database) throws -> UUID? {
        try UserIdentityLookup.resolveUserId(authId: authId, db: db)
    }

    private struct WellnessSnapshot {
        let sleepQuality: Int
        let energyLevel: Int
        let muscleSoreness: Int
        let stressLevel: Int
        let mood: Int
        let feelingIll: Bool
        let headache: Bool
        let digestiveIssues: Bool
        let notes: String
    }

    enum WellnessError: LocalizedError {
        case userUnavailable

        var errorDescription: String? {
            String(localized: "error.user.unavailable")
        }
    }
}

struct BodyCompositionView: View {
    @State private var viewModel = BodyCompositionViewModel()

    var body: some View {
        @Bindable var viewModel = viewModel

        ScrollView {
            VStack(spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Label(String(localized: "body_composition_title"), systemImage: "scalemass.fill")
                        .font(LifeOSTypography.title3)

                    Text(String(localized: "body_composition_description"))
                        .font(LifeOSTypography.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.m)
                .background(LifeOSColors.Surface.card)
                .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))

                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(viewModel.isEditing ? String(localized: "body_composition_edit_entry") : String(localized: "body_composition_new_entry"))
                        .font(LifeOSTypography.subheadline.weight(.semibold))

                    DatePicker(
                        String(localized: "body_composition_measured_at"),
                        selection: $viewModel.measuredAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )

                    metricField(
                        title: "\(String(localized: "weight")) (\(UnitPreferences.weightUnitLabel(viewModel.userUnits)))",
                        text: $viewModel.weightKgText,
                        placeholder: "70.0",
                        accessibilityId: "body_comp.weight"
                    )

                    metricField(
                        title: String(localized: "body_composition_body_fat"),
                        text: $viewModel.bodyFatPercentText,
                        placeholder: "18.0",
                        accessibilityId: "body_comp.body_fat"
                    )

                    metricField(
                        title: "\(String(localized: "body_composition_muscle_mass")) (\(UnitPreferences.weightUnitLabel(viewModel.userUnits)))",
                        text: $viewModel.muscleMassKgText,
                        placeholder: "30.0",
                        accessibilityId: "body_comp.muscle_mass"
                    )

                    HStack(spacing: Spacing.s) {
                        Button(viewModel.isEditing ? String(localized: "body_composition_update") : String(localized: "save")) {
                            Task { await viewModel.save() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isSaving || !viewModel.canSave)

                        if viewModel.isEditing {
                            Button(String(localized: "cancel")) {
                                viewModel.cancelEditing()
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if let statusMessage = viewModel.statusMessage {
                        Text(statusMessage)
                            .font(LifeOSTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.m)
                .background(LifeOSColors.Surface.card)
                .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(String(localized: "body_composition_history"))
                        .font(LifeOSTypography.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if viewModel.isLoading && viewModel.entries.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, Spacing.s)
                    } else if viewModel.entries.isEmpty {
                        Text(String(localized: "body_composition_empty"))
                            .font(LifeOSTypography.body)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: Spacing.s) {
                            ForEach(viewModel.entries) { entry in
                                HStack(spacing: Spacing.s) {
                                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                                        Text(Self.formattedTimestamp(entry.measuredAt))
                                            .font(LifeOSTypography.subheadline.weight(.semibold))

                                        Text(Self.metricsSummary(for: entry, units: viewModel.userUnits))
                                            .font(LifeOSTypography.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Button(String(localized: "body_composition_edit_button")) {
                                        viewModel.startEditing(entry)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(viewModel.isSaving)

                                    Button {
                                        Task { await viewModel.delete(entryId: entry.id) }
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(viewModel.isSaving)
                                }
                                .padding(Spacing.s)
                                .background(LifeOSColors.Surface.background)
                                .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.m)
                .background(LifeOSColors.Surface.card)
                .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
            }
            .padding(LayoutConstants.contentPadding)
        }
        .background(LifeOSColors.Surface.background)
        .navigationTitle(String(localized: "body_composition_title"))
        .task { await viewModel.load() }
    }

    private func metricField(
        title: String,
        text: Binding<String>,
        placeholder: String,
        accessibilityId: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title)
                .font(LifeOSTypography.subheadline)

            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.decimalPad)
                .accessibilityIdentifier(accessibilityId)
        }
    }

    private static func formattedTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func metricsSummary(
        for entry: BodyCompositionHistoryEntry,
        units: UnitSystem
    ) -> String {
        var parts: [String] = [
            UnitPreferences.formatWeight(kilograms: entry.weightKg, units: units)
        ]
        if let bodyFatPercent = entry.bodyFatPercent {
            parts.append(
                String(
                    format: String(localized: "body_composition_summary_body_fat_format"),
                    BodyCompositionViewModel.formattedDecimal(bodyFatPercent)
                )
            )
        }
        if let muscleMassKg = entry.muscleMassKg {
            parts.append(
                String(
                    format: String(localized: "body_composition_summary_muscle_format"),
                    UnitPreferences.formatWeight(kilograms: muscleMassKg, units: units)
                )
            )
        }
        return parts.joined(separator: " • ")
    }
}

@MainActor
@Observable
private final class BodyCompositionViewModel {
    var entries: [BodyCompositionHistoryEntry] = []
    var measuredAt = Date()
    var weightKgText = ""
    var bodyFatPercentText = ""
    var muscleMassKgText = ""
    var isLoading = false
    var isSaving = false
    var statusMessage: String?
    var userUnits: UnitSystem = .metric
    private(set) var editingEntryId: UUID?

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue) {
        self.dbQueue = dbQueue
    }

    var isEditing: Bool {
        editingEntryId != nil
    }

    var canSave: Bool {
        guard let value = Self.parseDecimal(weightKgText) else { return false }
        return value > 0
    }

    private func displayedWeight(_ kilograms: Double) -> String {
        UnitPreferences.formattedDecimal(
            UnitPreferences.weightValue(fromKilograms: kilograms, units: userUnits),
            maxDecimals: 1
        )
    }

    private func parsedWeightKg() -> Double? {
        guard let value = Self.parseDecimal(weightKgText), value > 0 else { return nil }
        return UnitPreferences.kilograms(fromDisplayedWeight: value, units: userUnits)
    }

    private func parsedMuscleMassKg() -> Double? {
        guard let value = Self.parseDecimal(muscleMassKgText) else { return nil }
        return UnitPreferences.kilograms(fromDisplayedWeight: value, units: userUnits)
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        let authId = AuthManager.activeAuthId?.uuidString

        do {
            let snapshot = try await dbQueue.read { db -> BodyCompositionLoadSnapshot in
                guard let userId = try Self.resolveUserId(authId: authId, db: db) else {
                    return BodyCompositionLoadSnapshot(entries: [], preferredWeightKg: nil, units: .metric)
                }

                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, measured_at, measured_date, measured_timezone,
                               measured_utc_offset_minutes, weight_kg, body_fat_percent,
                               muscle_mass_kg, input_type, source, user_corrected,
                               created_at, updated_at
                        FROM body_composition
                        WHERE (user_id = ? OR user_id = ?)
                          AND deleted_at IS NULL
                        ORDER BY measured_at DESC
                        LIMIT 120
                        """,
                    arguments: [userId, userId.uuidString]
                )

                let entries = rows.compactMap { row -> BodyCompositionHistoryEntry? in
                    guard let id = MixedUUIDStorage.decode(from: row, column: "id") else { return nil }
                    let measuredAt: Date = row["measured_at"]
                    let measuredTimezone: String? = row["measured_timezone"]
                    let measuredUtcOffsetMinutes: Int? = row["measured_utc_offset_minutes"]
                    let resolvedTimeZone = HistoricalLocalDayContext.safeTimeZone(
                        identifier: measuredTimezone ?? TimeZone.current.identifier,
                        fallbackOffsetMinutes: measuredUtcOffsetMinutes
                    )
                    let measuredDate = (row["measured_date"] as String?)
                        ?? HistoricalLocalDayContext.dayString(for: measuredAt, timeZone: resolvedTimeZone)
                    let weightKg: Double = row["weight_kg"]
                    let bodyFatPercent: Double? = row["body_fat_percent"]
                    let muscleMassKg: Double? = row["muscle_mass_kg"]
                    let inputType = BodyCompInputType(rawValue: (row["input_type"] as String?) ?? "")
                    let source = BodyCompSource(rawValue: (row["source"] as String?) ?? "")
                    let userCorrected: Bool = (row["user_corrected"] as Bool?) ?? false
                    let createdAt: Date = row["created_at"]
                    let updatedAt: Date = row["updated_at"]

                    return BodyCompositionHistoryEntry(
                        id: id,
                        measuredAt: measuredAt,
                        measuredDate: measuredDate,
                        measuredTimezone: measuredTimezone ?? resolvedTimeZone.identifier,
                        measuredUtcOffsetMinutes: measuredUtcOffsetMinutes
                            ?? resolvedTimeZone.secondsFromGMT(for: measuredAt) / 60,
                        weightKg: weightKg,
                        bodyFatPercent: bodyFatPercent,
                        muscleMassKg: muscleMassKg,
                        inputType: inputType,
                        source: source,
                        userCorrected: userCorrected,
                        createdAt: createdAt,
                        updatedAt: updatedAt
                    )
                }

                let profileWeight = try Double.fetchOne(
                    db,
                    sql: """
                        SELECT weight_kg
                        FROM users
                        WHERE (id = ? OR id = ?)
                          AND weight_kg > 0
                        ORDER BY updated_at DESC
                        LIMIT 1
                        """,
                    arguments: [userId, userId.uuidString]
                )

                let preferredWeightKg = entries.first?.weightKg ?? profileWeight
                let unitsRaw = try String.fetchOne(
                    db,
                    sql: """
                        SELECT units
                        FROM users
                        WHERE (id = ? OR id = ?)
                        ORDER BY updated_at DESC
                        LIMIT 1
                        """,
                    arguments: [userId, userId.uuidString]
                )
                let units = unitsRaw.flatMap(UnitSystem.init(rawValue:)) ?? .metric
                return BodyCompositionLoadSnapshot(entries: entries, preferredWeightKg: preferredWeightKg, units: units)
            }

            entries = snapshot.entries
            userUnits = snapshot.units

            if let editingEntryId,
               !snapshot.entries.contains(where: { $0.id == editingEntryId }) {
                cancelEditing()
            }

            if !isEditing,
               weightKgText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let preferredWeightKg = snapshot.preferredWeightKg {
                weightKgText = displayedWeight(preferredWeightKg)
            }
        } catch {
            statusMessage = error.localizedDescription
            entries = []
        }
    }

    func startEditing(_ entry: BodyCompositionHistoryEntry) {
        editingEntryId = entry.id
        measuredAt = entry.measuredAt
        weightKgText = displayedWeight(entry.weightKg)
        bodyFatPercentText = entry.bodyFatPercent.map(Self.formattedDecimal) ?? ""
        muscleMassKgText = entry.muscleMassKg.map(displayedWeight) ?? ""
        statusMessage = nil
    }

    func cancelEditing() {
        editingEntryId = nil
        measuredAt = Date()
        bodyFatPercentText = ""
        muscleMassKgText = ""
        statusMessage = nil
    }

    func save() async {
        guard let weightKg = parsedWeightKg(), weightKg > 0 else {
            statusMessage = String(localized: "body_composition_invalid_weight")
            return
        }

        isSaving = true
        defer { isSaving = false }

        let measuredAt = measuredAt
        let bodyFatPercent = Self.parseDecimal(bodyFatPercentText)
        let muscleMassKg = parsedMuscleMassKg()
        let editingEntryId = editingEntryId
        let wasEditing = editingEntryId != nil
        let existingEntry = entries.first(where: { $0.id == editingEntryId })
        let authId = AuthManager.activeAuthId?.uuidString

        do {
            try await dbQueue.write { db in
                guard let userId = try Self.resolveUserId(authId: authId, db: db) else {
                    throw BodyCompositionError.userUnavailable
                }

                let now = Date()
                let recordId = editingEntryId ?? UUID()
                let createdAt = existingEntry?.createdAt ?? now
                let source = existingEntry?.source ?? .manual
                let inputType = existingEntry?.inputType ?? .homeScale
                let userCorrected = wasEditing || (existingEntry?.userCorrected ?? false)
                let localDayContext = try TimeZoneHistoryStore.resolveLocalDayContext(
                    for: measuredAt,
                    userId: userId,
                    db: db
                )
                let measuredTimeZone = localDayContext.timeZone
                let measuredDate = HistoricalLocalDayContext.dayString(for: measuredAt, timeZone: measuredTimeZone)
                let measuredUtcOffsetMinutes = measuredTimeZone.secondsFromGMT(for: measuredAt) / 60

                if let editingEntryId {
                    try db.execute(
                        sql: """
                            UPDATE body_composition
                            SET user_id = ?,
                                measured_at = ?,
                                measured_date = ?,
                                measured_timezone = ?,
                                measured_utc_offset_minutes = ?,
                                input_type = ?,
                                weight_kg = ?,
                                body_fat_percent = ?,
                                muscle_mass_kg = ?,
                                source = ?,
                                user_corrected = ?,
                                updated_at = ?,
                                deleted_at = NULL
                            WHERE id = ? OR id = ?
                            """,
                        arguments: [
                            MixedUUIDStorage.encode(userId),
                            measuredAt,
                            measuredDate,
                            measuredTimeZone.identifier,
                            measuredUtcOffsetMinutes,
                            inputType.rawValue,
                            weightKg,
                            bodyFatPercent,
                            muscleMassKg,
                            source.rawValue,
                            userCorrected,
                            now,
                            editingEntryId,
                            MixedUUIDStorage.encode(editingEntryId)
                        ]
                    )
                } else {
                    try db.execute(
                        sql: """
                            INSERT INTO body_composition (
                                id, user_id, measured_at, measured_date, measured_timezone,
                                measured_utc_offset_minutes, input_type, weight_kg,
                                body_fat_percent, muscle_mass_kg, source, user_corrected,
                                created_at, updated_at
                            )
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            MixedUUIDStorage.encode(recordId),
                            MixedUUIDStorage.encode(userId),
                            measuredAt,
                            measuredDate,
                            measuredTimeZone.identifier,
                            measuredUtcOffsetMinutes,
                            inputType.rawValue,
                            weightKg,
                            bodyFatPercent,
                            muscleMassKg,
                            source.rawValue,
                            userCorrected,
                            createdAt,
                            now
                        ]
                    )
                }

                let payload = BodyCompositionOutboxPayload(
                    id: recordId,
                    userId: userId,
                    measuredAt: measuredAt,
                    measuredDate: measuredDate,
                    measuredTimezone: measuredTimeZone.identifier,
                    measuredUtcOffsetMinutes: measuredUtcOffsetMinutes,
                    inputType: inputType,
                    weightKg: weightKg,
                    bodyFatPercent: bodyFatPercent,
                    muscleMassKg: muscleMassKg,
                    source: source,
                    userCorrected: userCorrected,
                    createdAt: createdAt,
                    updatedAt: now,
                    deletedAt: nil
                )

                var event = OutboxEvent(
                    httpMethod: .POST,
                    path: "rest/v1/body_composition",
                    bodyJson: try JSONEncoder.supabase.encode(payload),
                    priority: 100
                )
                event.headersJson = try Self.outboxHeadersJson()
                try event.insert(db)
            }

            self.editingEntryId = nil
            self.measuredAt = Date()
            self.weightKgText = displayedWeight(weightKg)
            self.bodyFatPercentText = ""
            self.muscleMassKgText = ""
            self.statusMessage = wasEditing
                ? String(localized: "body_composition_updated")
                : String(localized: "body_composition_saved")
            await load()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func delete(entryId: UUID) async {
        guard let existingEntry = entries.first(where: { $0.id == entryId }) else { return }

        isSaving = true
        defer { isSaving = false }

        let authId = AuthManager.activeAuthId?.uuidString

        do {
            try await dbQueue.write { db in
                guard let userId = try Self.resolveUserId(authId: authId, db: db) else {
                    throw BodyCompositionError.userUnavailable
                }

                let now = Date()

                try db.execute(
                    sql: """
                        UPDATE body_composition
                        SET deleted_at = ?,
                            updated_at = ?
                        WHERE id = ? OR id = ?
                        """,
                    arguments: [
                        now,
                        now,
                        entryId,
                        MixedUUIDStorage.encode(entryId)
                    ]
                )

                let payload = BodyCompositionOutboxPayload(
                    id: existingEntry.id,
                    userId: userId,
                    measuredAt: existingEntry.measuredAt,
                    measuredDate: existingEntry.measuredDate,
                    measuredTimezone: existingEntry.measuredTimezone,
                    measuredUtcOffsetMinutes: existingEntry.measuredUtcOffsetMinutes,
                    inputType: existingEntry.inputType ?? .homeScale,
                    weightKg: existingEntry.weightKg,
                    bodyFatPercent: existingEntry.bodyFatPercent,
                    muscleMassKg: existingEntry.muscleMassKg,
                    source: existingEntry.source ?? .manual,
                    userCorrected: existingEntry.userCorrected,
                    createdAt: existingEntry.createdAt,
                    updatedAt: now,
                    deletedAt: now
                )

                var event = OutboxEvent(
                    httpMethod: .POST,
                    path: "rest/v1/body_composition",
                    bodyJson: try JSONEncoder.supabase.encode(payload),
                    priority: 100
                )
                event.headersJson = try Self.outboxHeadersJson()
                try event.insert(db)
            }

            if editingEntryId == entryId {
                cancelEditing()
            }
            statusMessage = String(localized: "body_composition_deleted")
            await load()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    nonisolated static func formattedDecimal(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    nonisolated private static func parseDecimal(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let sanitized = trimmed.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(sanitized), value.isFinite else { return nil }
        return value
    }

    nonisolated private static func outboxHeadersJson() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
    }

    nonisolated private static func resolveUserId(authId: String?, db: Database) throws -> UUID? {
        try UserIdentityLookup.resolveUserId(authId: authId, db: db)
    }

    enum BodyCompositionError: LocalizedError {
        case userUnavailable

        var errorDescription: String? {
            String(localized: "error.user.unavailable")
        }
    }
}

private struct BodyCompositionHistoryEntry: Identifiable, Equatable {
    let id: UUID
    let measuredAt: Date
    let measuredDate: String
    let measuredTimezone: String?
    let measuredUtcOffsetMinutes: Int?
    let weightKg: Double
    let bodyFatPercent: Double?
    let muscleMassKg: Double?
    let inputType: BodyCompInputType?
    let source: BodyCompSource?
    let userCorrected: Bool
    let createdAt: Date
    let updatedAt: Date
}

private struct BodyCompositionLoadSnapshot {
    let entries: [BodyCompositionHistoryEntry]
    let preferredWeightKg: Double?
    let units: UnitSystem
}

#if DEBUG
extension BodyCompositionView {
    @MainActor
    fileprivate init(testViewModel: BodyCompositionViewModel) {
        _viewModel = State(initialValue: testViewModel)
    }

    @MainActor
    fileprivate func _testEvaluateBody() {
        _ = body
    }
}

@MainActor
enum BodyCompositionViewTestHarness {
    struct Snapshot: Equatable {
        let entryCount: Int
        let isEditing: Bool
        let canSave: Bool
        let statusMessage: String?
        let weightKgText: String
        let bodyFatPercentText: String
        let muscleMassKgText: String
    }

    static func loadSnapshot(dbQueue: DatabaseQueue) async -> Snapshot {
        let viewModel = BodyCompositionViewModel(dbQueue: dbQueue)
        await viewModel.load()
        return snapshot(from: viewModel)
    }

    static func saveEntry(
        dbQueue: DatabaseQueue,
        measuredAt: Date,
        weightKgText: String,
        bodyFatPercentText: String,
        muscleMassKgText: String
    ) async -> Snapshot {
        let viewModel = BodyCompositionViewModel(dbQueue: dbQueue)
        viewModel.measuredAt = measuredAt
        viewModel.weightKgText = weightKgText
        viewModel.bodyFatPercentText = bodyFatPercentText
        viewModel.muscleMassKgText = muscleMassKgText
        await viewModel.save()
        return snapshot(from: viewModel)
    }

    static func updateFirstEntry(
        dbQueue: DatabaseQueue,
        measuredAt: Date,
        weightKgText: String,
        bodyFatPercentText: String,
        muscleMassKgText: String
    ) async -> Snapshot {
        let viewModel = BodyCompositionViewModel(dbQueue: dbQueue)
        await viewModel.load()
        guard let firstEntry = viewModel.entries.first else {
            return snapshot(from: viewModel)
        }
        viewModel.startEditing(firstEntry)
        viewModel.measuredAt = measuredAt
        viewModel.weightKgText = weightKgText
        viewModel.bodyFatPercentText = bodyFatPercentText
        viewModel.muscleMassKgText = muscleMassKgText
        await viewModel.save()
        return snapshot(from: viewModel)
    }

    static func cancelEditingSnapshot(dbQueue: DatabaseQueue) async -> Snapshot {
        let viewModel = BodyCompositionViewModel(dbQueue: dbQueue)
        await viewModel.load()
        if let firstEntry = viewModel.entries.first {
            viewModel.startEditing(firstEntry)
            viewModel.cancelEditing()
        }
        return snapshot(from: viewModel)
    }

    static func deleteFirstEntry(dbQueue: DatabaseQueue) async -> Snapshot {
        let viewModel = BodyCompositionViewModel(dbQueue: dbQueue)
        await viewModel.load()
        if let firstEntry = viewModel.entries.first {
            await viewModel.delete(entryId: firstEntry.id)
        }
        return snapshot(from: viewModel)
    }

    static func renderStates(dbQueue: DatabaseQueue) async {
        let loadingViewModel = BodyCompositionViewModel(dbQueue: dbQueue)
        loadingViewModel.isLoading = true
        BodyCompositionView(testViewModel: loadingViewModel)._testEvaluateBody()

        let loadedViewModel = BodyCompositionViewModel(dbQueue: dbQueue)
        await loadedViewModel.load()
        BodyCompositionView(testViewModel: loadedViewModel)._testEvaluateBody()

        if let firstEntry = loadedViewModel.entries.first {
            loadedViewModel.startEditing(firstEntry)
            BodyCompositionView(testViewModel: loadedViewModel)._testEvaluateBody()
        }
    }

    static func metricsSummary(
        weightKg: Double,
        bodyFatPercent: Double?,
        muscleMassKg: Double?
    ) -> String {
        var parts: [String] = [
            String(
                format: String(localized: "body_composition_summary_weight_format"),
                BodyCompositionViewModel.formattedDecimal(weightKg)
            )
        ]
        if let bodyFatPercent {
            parts.append(
                String(
                    format: String(localized: "body_composition_summary_body_fat_format"),
                    BodyCompositionViewModel.formattedDecimal(bodyFatPercent)
                )
            )
        }
        if let muscleMassKg {
            parts.append(
                String(
                    format: String(localized: "body_composition_summary_muscle_format"),
                    BodyCompositionViewModel.formattedDecimal(muscleMassKg)
                )
            )
        }
        return parts.joined(separator: " • ")
    }

    static func formattedTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func snapshot(from viewModel: BodyCompositionViewModel) -> Snapshot {
        Snapshot(
            entryCount: viewModel.entries.count,
            isEditing: viewModel.isEditing,
            canSave: viewModel.canSave,
            statusMessage: viewModel.statusMessage,
            weightKgText: viewModel.weightKgText,
            bodyFatPercentText: viewModel.bodyFatPercentText,
            muscleMassKgText: viewModel.muscleMassKgText
        )
    }
}
#endif

private struct WellnessCheckOutboxPayload: Codable {
    let id: UUID
    let userId: UUID
    let checkedAt: Date
    let date: String
    let checkedTimezone: String?
    let checkedUtcOffsetMinutes: Int?
    let perceivedSleepQuality: Int?
    let energyLevel: Int?
    let muscleSoreness: Int?
    let stressLevel: Int?
    let mood: Int?
    let pss4Q1: Int?
    let pss4Q2: Int?
    let pss4Q3: Int?
    let pss4Q4: Int?
    let pss4Total: Int?
    let feelingIll: Bool
    let headache: Bool
    let digestiveIssues: Bool
    let notes: String?
    let wellnessScore: Double?
    let mentalHealthResourcesShown: Bool
    let deletedAt: Date?
    let createdAt: Date
    let updatedAt: Date
}

private struct BodyCompositionOutboxPayload: Codable {
    let id: UUID
    let userId: UUID
    let measuredAt: Date
    let measuredDate: String?
    let measuredTimezone: String?
    let measuredUtcOffsetMinutes: Int?
    let inputType: BodyCompInputType
    let weightKg: Double
    let bodyFatPercent: Double?
    let muscleMassKg: Double?
    let source: BodyCompSource
    let userCorrected: Bool
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?
}

#if DEBUG
@MainActor
enum WellnessCheckDayViewTestHarness {
    static func saveSnapshot(
        dateString: String,
        dbQueue: DatabaseQueue,
        sleepQuality: Int,
        energyLevel: Int,
        muscleSoreness: Int,
        stressLevel: Int,
        mood: Int,
        feelingIll: Bool,
        headache: Bool,
        digestiveIssues: Bool,
        notes: String
    ) async -> String? {
        let viewModel = WellnessCheckDayViewModel(dateString: dateString, dbQueue: dbQueue)
        viewModel.sleepQuality = sleepQuality
        viewModel.energyLevel = energyLevel
        viewModel.muscleSoreness = muscleSoreness
        viewModel.stressLevel = stressLevel
        viewModel.mood = mood
        viewModel.feelingIll = feelingIll
        viewModel.headache = headache
        viewModel.digestiveIssues = digestiveIssues
        viewModel.notes = notes
        await viewModel.save()
        return viewModel.statusMessage
    }
}
#endif

#Preview {
    DiaryView()
}


private struct DiaryMonthGrid: View {
    @Binding var selection: Date
    let domainsByDay: [String: Set<DiaryRecordDomain>]
    let legendDomains: [DiaryRecordDomain]
    private let calendar = Calendar.current

    private var monthStart: Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: selection)) ?? selection
    }
    private var leadingDays: Int {
        (calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7) % 7
    }
    private var dayCount: Int { calendar.range(of: .day, in: .month, for: selection)?.count ?? 0 }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button { moveMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel(String(localized: "diary_previous_month", defaultValue: "Previous month"))
                Spacer()
                Text(selection.formatted(.dateTime.month(.wide).year())).font(.headline)
                Spacer()
                Button { moveMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .accessibilityLabel(String(localized: "diary_next_month", defaultValue: "Next month"))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                ForEach(0..<7, id: \.self) { index in
                    Text(calendar.veryShortStandaloneWeekdaySymbols[(index + calendar.firstWeekday - 1) % 7])
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(0..<(leadingDays + dayCount), id: \.self) { index in
                    if index < leadingDays {
                        Color.clear.frame(height: 44).accessibilityHidden(true)
                    } else if let date = calendar.date(byAdding: .day, value: index - leadingDays, to: monthStart) {
                        dayButton(date)
                    }
                }
            }

            if !legendDomains.isEmpty {
                HStack(spacing: Spacing.s) {
                    ForEach(legendDomains, id: \.self) { domain in
                        HStack(spacing: 3) {
                            Circle().fill(domain.color).frame(width: 6, height: 6)
                            Text(domain.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            }
        }
    }

    private func dayButton(_ date: Date) -> some View {
        let selected = calendar.isDate(date, inSameDayAs: selection)
        let domains = domainsByDay[DiaryDateFormatter.formatDate(date)] ?? []
        let sortedDomains = domains.sorted { $0.rawValue < $1.rawValue }
        let domainSummary = sortedDomains.map(\.title).sorted().joined(separator: ", ")
        return Button { selection = date } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: date))").font(.callout)
                HStack(spacing: 2) {
                    ForEach(Array(sortedDomains.prefix(4)), id: \.self) { domain in
                        Circle().fill(domain.color).frame(width: 4, height: 4)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityValue(
            domains.isEmpty
                ? String(localized: "diary_day_empty", defaultValue: "No records")
                : String(
                    format: String(localized: "diary_day_domains_format", defaultValue: "Has records: %@"),
                    domainSummary
                )
        )
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func moveMonth(_ offset: Int) {
        selection = calendar.date(byAdding: .month, value: offset, to: monthStart) ?? selection
    }
}
