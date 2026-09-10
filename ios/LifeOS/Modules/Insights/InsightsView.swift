// MARK: - Insights View

import SwiftUI
import GRDB

@MainActor
struct InsightsView: View {
    @State private var viewModel = InsightsViewModel()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(DeepLinkRouter.self) private var router: DeepLinkRouter?

    init(viewModel: InsightsViewModel = InsightsViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.s) {
                    if viewModel.lowConfidenceCount > 0 {
                        lowConfidenceBanner
                    }

                    simulationLauncherCard
                    experimentsLibraryCard

                    if let report = viewModel.latestWeeklyStrategyReport {
                        weeklyStrategyCard(report)
                    }

                    if shouldShowDomainFilters {
                        domainFilterBar
                    }

                    if viewModel.isLoading {
                        ProgressView(String(localized: "loading"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.l)
                    } else if let loadError = viewModel.loadError {
                        Text(loadError)
                            .font(LifeOSTypography.footnote)
                            .foregroundStyle(LifeOSColors.Text.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(Spacing.l)
                    } else if viewModel.insights.isEmpty {
                        currentEmptyState
                            .padding(.vertical, Spacing.l)
                    } else {
                        LazyVStack(spacing: Spacing.s) {
                            filterSummary
                            ForEach(viewModel.insights, content: insightNavigationLink)
                        }
                    }
                }
                .padding(.horizontal, LayoutConstants.contentPadding)
                .padding(.top, Spacing.s)
                .padding(.bottom, Spacing.l)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("insights.screen")
            .background(LifeOSColors.Surface.background)
            .navigationTitle(String(localized: "tab_insights"))
            .task(runRefreshTask)
            .refreshOnFeatureFlagChanges()
        }
    }

    private var routeHandler: (URL) -> Bool {
        Self.makeRouteHandler(router: router)
    }

    private var shouldShowDomainFilters: Bool {
        viewModel.hasAnyInsights || viewModel.hasActiveDomainFilters
    }

    private var currentEmptyState: some View {
        Group {
            if viewModel.hasAnyInsights && viewModel.hasActiveDomainFilters {
                filteredEmptyState
            } else {
                emptyState
            }
        }
    }

    private static func makeRouteHandler(router: DeepLinkRouter?) -> (URL) -> Bool {
        if let router {
            return router.handle
        }
        return alwaysFalseRoute
    }

    private static func alwaysFalseRoute(_: URL) -> Bool {
        false
    }

    private static var simulationRoute: URL? {
        URL(string: "lifeos://simulation")
    }

    private var aiAvailability: AIAvailability {
        AIAvailability()
    }

    private var isSimulationAvailable: Bool {
        aiAvailability.simulationAvailable
    }

    private var simulationEntryTitle: String {
        if isSimulationAvailable {
            return String(localized: "insights_simulate_entry_title")
        }
        return String(localized: "insights_simulate_unavailable_title")
    }

    private var simulationEntrySubtitle: String {
        if isSimulationAvailable {
            return String(localized: "insights_simulate_entry_subtitle")
        }
        return String(localized: "insights_simulate_unavailable_notice")
    }

    private var simulationEntryCTA: String {
        if isSimulationAvailable {
            return String(localized: "insights_simulate_new")
        }
        return String(localized: "insights_simulate_unavailable_cta")
    }

    private func detailDestination(for insight: Insight) -> some View {
        InsightDetailView(insightId: insight.id)
    }

    private func weeklyStrategyDestination(for report: WeeklyStrategyReport) -> some View {
        WeeklyStrategyReportDetailView(report: report)
    }

    private func insightNavigationLink(_ insight: Insight) -> some View {
        NavigationLink {
            detailDestination(for: insight)
        } label: {
            insightRowLabel(for: insight)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("insights.card.\(insight.title)")
    }

    private func insightRowLabel(for insight: Insight) -> some View {
        insightCard(insight)
    }

    private func runRefreshTask() async {
        await viewModel.refresh()
#if os(iOS)
        await PushNotificationManager.shared.evaluateDelayedAuthorizationPromptIfEligible()
#endif
    }

    private func weeklyStrategyCard(_ report: WeeklyStrategyReport) -> some View {
        NavigationLink {
            weeklyStrategyDestination(for: report)
        } label: {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Label(String(localized: "insights_weekly_strategy_title"), systemImage: "calendar.badge.clock")
                    .font(LifeOSTypography.headline)
                    .foregroundStyle(.primary)

                Text("\(report.weekStart) - \(report.weekEnd)")
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(LifeOSColors.Text.secondary)

                Text(weeklyReportPreview(report))
                    .font(LifeOSTypography.footnote)
                    .foregroundStyle(LifeOSColors.Text.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.m)
            .background(LifeOSColors.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("insights.weekly_strategy")
    }

    private var lowConfidenceBanner: some View {
        Label(
            "\(String(localized: "insights_confidence_low_badge")) (\(viewModel.lowConfidenceCount))",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(LifeOSTypography.footnote.weight(.semibold))
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xxs)
        .background(LifeOSColors.Recovery.caution.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(String(localized: "insights_confidence_low_badge"))
    }

    private func weeklyReportPreview(_ report: WeeklyStrategyReport) -> String {
        report.reportMarkdownWithClinicianCaveat
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .prefix(3)
            .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
            .joined(separator: "\n")
    }

    private var simulationLauncherCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Image(systemName: "waveform.path.ecg.rectangle")

                Text(simulationEntryTitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(LifeOSTypography.headline)
            .foregroundStyle(.primary)
            .accessibilityElement(children: .combine)

            Text(simulationEntrySubtitle)
                .font(LifeOSTypography.footnote)
                .foregroundStyle(LifeOSColors.Text.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if isSimulationAvailable {
                Button(action: simulationButtonAction(onRoute: routeHandler)) {
                    Text(simulationEntryCTA)
                        .font(LifeOSTypography.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: LayoutConstants.minTouchTarget)
                }
                .buttonStyle(.borderedProminent)
                .tint(LifeOSColors.Semantic.primary)
                .accessibilityIdentifier("insights.simulation.cta")
            } else {
                Text(simulationEntryCTA)
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                    .foregroundStyle(LifeOSColors.Text.secondary)
                    .frame(maxWidth: .infinity, minHeight: LayoutConstants.minTouchTarget)
                    .accessibilityIdentifier("insights.simulation.cta")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("insights.simulation.launcher")
    }

    private var experimentsLibraryCard: some View {
        NavigationLink {
            ExperimentListView()
        } label: {
            HStack(spacing: Spacing.s) {
                Image(systemName: "flask")
                    .font(LifeOSTypography.title3)
                    .foregroundStyle(LifeOSColors.Semantic.primary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "experiments_library_title"))
                        .font(LifeOSTypography.headline)
                        .foregroundStyle(.primary)
                    Text(String(localized: "experiments_library_subtitle"))
                        .font(LifeOSTypography.footnote)
                        .foregroundStyle(LifeOSColors.Text.secondary)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.right")
                    .foregroundStyle(LifeOSColors.Text.secondary)
                    .accessibilityHidden(true)
            }
            .padding(Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LifeOSColors.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "experiments_library_title"))
        .accessibilityHint(String(localized: "experiments_library_subtitle"))
        .accessibilityIdentifier("insights.experiments.library")
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: "lightbulb")
                .font(LifeOSTypography.title)
                .foregroundStyle(LifeOSColors.Text.tertiary)
                .accessibilityHidden(true)

            Text(String(localized: "insights_empty_title"))
                .font(LifeOSTypography.headline)
                .foregroundStyle(.primary)

            Text(String(localized: "insights_empty_subtitle"))
                .font(LifeOSTypography.body)
                .foregroundStyle(LifeOSColors.Text.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var filteredEmptyState: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(LifeOSTypography.title)
                .foregroundStyle(LifeOSColors.Text.tertiary)
                .accessibilityHidden(true)

            Text(String(localized: "insights_filter_empty_title"))
                .font(LifeOSTypography.headline)
                .foregroundStyle(.primary)

            Text(String(localized: "insights_filter_empty_subtitle"))
                .font(LifeOSTypography.body)
                .foregroundStyle(LifeOSColors.Text.secondary)
                .multilineTextAlignment(.center)

            Button(String(localized: "insights_filter_clear"), action: viewModel.selectAllDomains)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("insights.filters.clear")

        }
        .frame(maxWidth: .infinity)
    }

    private var domainFilterLayout: AnyLayout {
        if dynamicTypeSize >= .xxLarge {
            return AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xs))
        }
        return AnyLayout(HStackLayout(alignment: .center, spacing: Spacing.xs))
    }

    private var domainFilterBar: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(String(localized: "insights_filter_section_title"))
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                if viewModel.hasActiveDomainFilters {
                    Button(String(localized: "insights_filter_show_all"), action: viewModel.selectAllDomains)
                        .font(LifeOSTypography.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(LifeOSColors.Semantic.primary)
                        .accessibilityIdentifier("insights.filters.show_all")
                }
            }

            domainFilterLayout {
                    domainChip(
                        title: String(localized: "insights_filter_all"),
                        count: viewModel.totalInsightCount,
                        isSelected: !viewModel.hasActiveDomainFilters,
                        accessibilityIdentifier: "insights.filter.all",
                        action: viewModel.selectAllDomains
                    )

                    ForEach(viewModel.availableDomains, id: \.self) { domain in
                        domainChip(
                            title: localizedCategory(domain),
                            count: viewModel.domainCount(for: domain),
                            isSelected: viewModel.isDomainSelected(domain),
                            accessibilityIdentifier: "insights.filter.\(domain.rawValue)"
                        ) {
                            viewModel.toggleDomain(domain)
                        }
                    }
            }
            .padding(.vertical, Spacing.xxs)
        }
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("insights.filters")
    }

    private var filterSummary: some View {
        Text(filterSummaryText)
            .font(LifeOSTypography.caption)
            .foregroundStyle(LifeOSColors.Text.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("insights.filters.summary")
    }

    private var filterSummaryText: String {
        guard viewModel.hasActiveDomainFilters else {
            return String.localizedStringWithFormat(
                String(localized: "insights_filter_summary_all_format"),
                Int64(viewModel.insights.count)
            )
        }
        return String.localizedStringWithFormat(
            String(localized: "insights_filter_summary_filtered_format"),
            Int64(viewModel.insights.count),
            Int64(viewModel.selectedDomains.count)
        )
    }

    private func domainChip(
        title: String,
        count: Int,
        isSelected: Bool,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                Text(title)
                    .font(LifeOSTypography.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(count)")
                    .font(LifeOSTypography.caption.weight(.bold))
                    .fixedSize()
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, 2)
                    .background(countBadgeBackground(isSelected: isSelected))
                    .clipShape(Capsule())
            }
            .foregroundStyle(isSelected ? (colorScheme == .dark ? Color.black : Color.white) : LifeOSColors.Text.primary)
            .frame(maxWidth: .infinity, minHeight: LayoutConstants.minTouchTarget)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .background(isSelected ? LifeOSColors.Semantic.primary : LifeOSColors.Surface.elevated)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityValue(
            isSelected
                ? String(localized: "insights_filter_accessibility_selected")
                : String(localized: "insights_filter_accessibility_not_selected")
        )
    }

    private func countBadgeBackground(isSelected: Bool) -> some ShapeStyle {
        if isSelected {
            return Color.clear
        }
        return LifeOSColors.Surface.card
    }

    private func insightCard(_ insight: Insight) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .top, spacing: Spacing.xs) {
                Image(systemName: icon(for: insight.category))
                    .foregroundStyle(LifeOSColors.Semantic.primary)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(insight.title)
                        .font(LifeOSTypography.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)

                    Text(localizedCategory(insight.category))
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(LifeOSColors.Text.secondary)

                    Text(insight.bodyWithClinicianCaveat)
                        .font(LifeOSTypography.footnote)
                        .foregroundStyle(LifeOSColors.Text.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }

                Spacer()
            }

            HStack(spacing: Spacing.s) {
                if insight.requiresReview {
                    Label(String(localized: "insights_confidence_low_badge"), systemImage: "exclamationmark.triangle.fill")
                        .font(LifeOSTypography.caption.weight(.semibold))
                        .foregroundStyle(LifeOSColors.Recovery.caution)
                }

                Text("\(String(localized: "insights_confidence_prefix")) \(Int((insight.confidence * 100).rounded()))%")
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(LifeOSColors.Text.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(localizedCategory(insight.category)): \(insight.title). \(String(localized: "insights_confidence_prefix")) \(Int((insight.confidence * 100).rounded()))%\(insight.requiresReview ? ". \(String(localized: "insights_confidence_low_badge"))" : "")")
    }

    private func handleSimulationTap(onRoute: (URL) -> Bool) {
        Self.performRoute(Self.simulationRoute, onRoute: onRoute)
    }

    private func simulationButtonAction(
        onRoute: @escaping (URL) -> Bool
    ) -> () -> Void {
        { handleSimulationTap(onRoute: onRoute) }
    }

    private static func performRoute(
        _ url: URL?,
        onRoute: (URL) -> Bool,
        haptic: () -> Void = { HapticManager.lightTap() }
    ) {
        guard let url else { return }
        haptic()
        _ = onRoute(url)
    }

    private func icon(for category: InsightCategory) -> String {
        switch category {
        case .recovery: return "heart.text.square"
        case .nutrition: return "fork.knife"
        case .training: return "figure.run"
        case .sleep: return "bed.double"
        case .supplement: return "pill"
        case .health: return "cross.case"
        case .experiment: return "flask"
        case .general: return "lightbulb"
        }
    }

    private func localizedCategory(_ category: InsightCategory) -> String {
        switch category {
        case .recovery: return String(localized: "insights_category_recovery")
        case .nutrition: return String(localized: "insights_category_nutrition")
        case .training: return String(localized: "insights_category_training")
        case .sleep: return String(localized: "insights_category_sleep")
        case .supplement: return String(localized: "insights_category_supplement")
        case .health: return String(localized: "insights_category_health")
        case .experiment: return String(localized: "insights_category_experiment")
        case .general: return String(localized: "insights_category_general")
        }
    }
}

private struct WeeklyStrategyReportDetailView: View {
    let report: WeeklyStrategyReport

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("\(report.weekStart) - \(report.weekEnd)")
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(LifeOSColors.Text.secondary)

                Text(report.reportMarkdownWithClinicianCaveat)
                    .font(LifeOSTypography.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(LayoutConstants.contentPadding)
        }
        .background(LifeOSColors.Surface.background)
        .navigationTitle(String(localized: "insights_weekly_strategy_title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
extension InsightsView {
    @MainActor
    func _testEvaluateSections(sampleInsight: Insight) {
        _ = lowConfidenceBanner
        _ = simulationLauncherCard
        _ = emptyState
        _ = filteredEmptyState
        _ = currentEmptyState
        _ = domainFilterBar
        _ = filterSummary
        _ = filterSummaryText
        _ = domainChip(
            title: String(localized: "insights_filter_all"),
            count: 1,
            isSelected: true,
            accessibilityIdentifier: "insights.filter.all",
            action: {}
        )
        _ = countBadgeBackground(isSelected: true)
        _ = countBadgeBackground(isSelected: false)
        _ = insightCard(sampleInsight)

        _ = icon(for: .recovery)
        _ = icon(for: .nutrition)
        _ = icon(for: .training)
        _ = icon(for: .sleep)
        _ = icon(for: .supplement)
        _ = icon(for: .health)
        _ = icon(for: .experiment)
        _ = icon(for: .general)

        _ = localizedCategory(.recovery)
        _ = localizedCategory(.nutrition)
        _ = localizedCategory(.training)
        _ = localizedCategory(.sleep)
        _ = localizedCategory(.supplement)
        _ = localizedCategory(.health)
        _ = localizedCategory(.experiment)
        _ = localizedCategory(.general)
    }

    @MainActor
    func _testExerciseNavigationAndTaskWrappers(sampleInsight: Insight) async {
        _ = detailDestination(for: sampleInsight)
        _ = insightNavigationLink(sampleInsight)
        _ = insightRowLabel(for: sampleInsight)
        await runRefreshTask()
    }

    @MainActor
    func _testExerciseFilterActions() {
        viewModel.selectAllDomains()
        viewModel.toggleDomain(.recovery)
        viewModel.toggleDomain(.nutrition)
        viewModel.toggleDomain(.recovery)
        viewModel.selectAllDomains()
    }

    @MainActor
    func _testTriggerRouteActions() -> [String] {
        var handled: [String] = []
        let onRoute: (URL) -> Bool = {
            handled.append($0.absoluteString)
            return true
        }
        simulationButtonAction(onRoute: onRoute)()
        handleSimulationTap(onRoute: onRoute)
        return handled
    }
}
#endif

private enum ExperimentListFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return String(localized: "experiments_filter_all")
        case .active:
            return String(localized: "experiments_filter_active")
        case .completed:
            return String(localized: "experiments_filter_completed")
        }
    }

    func includes(_ experiment: Experiment) -> Bool {
        switch self {
        case .all:
            return true
        case .active:
            return ExperimentStatus.lifecycleActiveStatuses.contains(experiment.status)
                || [.design, .planned, .paused].contains(experiment.status)
        case .completed:
            return ExperimentStatus.lifecycleTerminalStatuses.contains(experiment.status)
        }
    }
}

struct ExperimentListView: View {
    @State private var experiments: [Experiment] = []
    @State private var selectedFilter: ExperimentListFilter = .all
    @State private var isLoading = true
    @State private var loadError: String?

    private var filteredExperiments: [Experiment] {
        experiments.filter(selectedFilter.includes)
    }

    var body: some View {
        VStack(spacing: Spacing.s) {
            Picker(String(localized: "experiments_filter_label"), selection: $selectedFilter) {
                ForEach(ExperimentListFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, LayoutConstants.contentPadding)
            .accessibilityIdentifier("experiments.filter")

            if isLoading {
                Spacer()
                ProgressView(String(localized: "loading"))
                Spacer()
            } else if let loadError {
                ContentUnavailableView(
                    String(localized: "experiments_load_failed"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else if filteredExperiments.isEmpty {
                ContentUnavailableView(
                    String(localized: "experiments_empty_title"),
                    systemImage: "flask",
                    description: Text(String(localized: "experiments_empty_subtitle"))
                )
            } else {
                List(filteredExperiments) { experiment in
                    NavigationLink {
                        ExperimentDetailView(experimentId: experiment.id)
                    } label: {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            HStack {
                                Text(experiment.title)
                                    .font(LifeOSTypography.headline)
                                Spacer()
                                Text(localizedStatus(experiment.status))
                                    .font(LifeOSTypography.caption)
                                    .foregroundStyle(LifeOSColors.Text.secondary)
                            }
                            Text(experiment.primaryMetric ?? experiment.metric)
                                .font(LifeOSTypography.footnote)
                                .foregroundStyle(LifeOSColors.Text.secondary)
                            if let startDate = experiment.startDate {
                                Text(startDate)
                                    .font(LifeOSTypography.caption)
                                    .foregroundStyle(LifeOSColors.Text.tertiary)
                            }
                        }
                        .padding(.vertical, Spacing.xxs)
                    }
                    .accessibilityIdentifier("experiments.row.\(experiment.id.uuidString)")
                }
                .listStyle(.plain)
                .refreshable { await loadExperiments(refreshRemote: true) }
            }
        }
        .background(LifeOSColors.Surface.background)
        .navigationTitle(String(localized: "experiments_library_title"))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("experiments.list.screen")
        .task { await loadExperiments(refreshRemote: true) }
    }

    @MainActor
    private func loadExperiments(refreshRemote: Bool) async {
        isLoading = experiments.isEmpty
        loadError = nil
        if refreshRemote, AuthManager.activeHasCloudSession,
           let syncEngine = AppContainer.shared?.syncEngine {
            try? await syncEngine.pullAll()
        }
        do {
            experiments = try await DatabaseManager.shared.dbQueue.read { db in
                try Experiment
                    .filter(Column("deleted_at") == nil)
                    .filter(Column("sync_quarantine_reason") == nil)
                    .order(Column("updated_at").desc)
                    .fetchAll(db)
            }
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func localizedStatus(_ status: ExperimentStatus) -> String {
        switch status {
        case .design, .planned:
            return String(localized: "experiments_status_design")
        case .baseline:
            return String(localized: "experiments_status_baseline")
        case .intervention, .active:
            return String(localized: "experiments_status_active")
        case .washout:
            return String(localized: "experiments_status_washout")
        case .paused:
            return String(localized: "experiments_status_paused")
        case .completed:
            return String(localized: "experiments_status_completed")
        case .abandoned, .cancelled:
            return String(localized: "experiments_status_cancelled")
        }
    }
}

#Preview {
    InsightsView()
}
