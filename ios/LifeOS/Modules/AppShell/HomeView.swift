// MARK: - Home View
// Recovery summary, next best action, and quick log entry points.

import SwiftUI

@MainActor
struct HomeView: View {
    @State private var viewModel = HomeViewModel()

    @Environment(DeepLinkRouter.self) private var router: DeepLinkRouter?

    init(viewModel: HomeViewModel = HomeViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.m) {
                    // Recovery Score Card
                    recoveryCard

                    // Setup progress (new users) OR next best action (established users)
                    if viewModel.showsSetupCard {
                        setupProgressCard
                    } else {
                        nextBestActionCard
                    }

                    if !viewModel.showsSetupCard && !viewModel.recommendations.isEmpty {
                        recommendationsCard
                    }

                    // Quick Actions
                    quickActionsRow

                    Spacer()
                }
                .padding(.horizontal, LayoutConstants.contentPadding)
                .padding(.top, Spacing.m)
                .padding(.bottom, Spacing.xxxl + LayoutConstants.minTouchTarget * 2)
            }
            .background(LifeOSColors.Surface.background)
            .navigationTitle(String(localized: "app_name"))
            .task(refreshTaskAction)
            .refreshOnFeatureFlagChanges()
        }
    }

    private var routeHandler: (URL) -> Bool {
        Self.makeRouteHandler(router: router)
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
            return String(localized: "insights_simulate_recovery_cta")
        }
        return String(localized: "insights_simulate_unavailable_cta")
    }

    // MARK: - Recovery Card

    private var recoveryCard: some View {
        VStack(spacing: Spacing.xs) {
            Text(String(localized: "recovery_score"))
                .font(LifeOSTypography.subheadline)
                .foregroundStyle(LifeOSColors.Text.secondary)

            if let score = viewModel.recoveryScore,
               let zone = viewModel.recoveryZone {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: zone.iconName)
                        .foregroundStyle(zone.color)
                    Text(zone.label)
                        .font(LifeOSTypography.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, Spacing.xxs)
                .background(zone.color.opacity(0.16), in: Capsule())
                .accessibilityLabel(zone.accessibilityAnnouncement(score: score))

                Text("\(Int(score.rounded()))")
                    .font(LifeOSTypography.metricLarge)
                    .foregroundStyle(.primary)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .accessibilityLabel(zone.accessibilityAnnouncement(score: score))

                if let confidence = viewModel.recoveryConfidence,
                   confidence < LifeOSConstants.lowConfidenceThreshold {
                    Text(String(localized: "insights_confidence_low_badge"))
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(LifeOSColors.Recovery.caution)
                }

                if let action = viewModel.contextualRecoveryAction {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(action.title)
                            .font(LifeOSTypography.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(action.message)
                            .font(LifeOSTypography.caption)
                            .foregroundStyle(LifeOSColors.Text.secondary)
                            .multilineTextAlignment(.leading)
                        Button(action: contextualActionButtonAction(action, onRoute: routeHandler)) {
                            HStack(spacing: Spacing.xxs) {
                                Text(action.buttonTitle)
                                Image(systemName: "chevron.right")
                            }
                            .font(LifeOSTypography.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Spacing.s)
                }
            } else {
                Capsule()
                    .fill(LifeOSColors.Text.primary)
                    .frame(width: 48, height: 6)
                    .padding(.vertical, Spacing.s)
                    .accessibilityHidden(true)

                // Baseline progress instead of static "calibrating"
                let days = viewModel.setupChecklistStore.baselineDaysCollected
                let needed = 5
                if days > 0 {
                    VStack(spacing: Spacing.xxs) {
                        ProgressView(value: Double(min(days, needed)), total: Double(needed))
                            .tint(LifeOSColors.Semantic.primary)
                            .accessibilityHidden(true)

                        Text(String(
                            format: String(localized: "recovery_calibrating_progress_format"),
                            days, needed
                        ))
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(LifeOSColors.Text.secondary)
                    }
                    .padding(.horizontal, Spacing.m)
                } else {
                    Text(String(localized: "recovery_calibrating"))
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(LifeOSColors.Text.secondary)
                        .accessibilityLabel(String(localized: "recovery_calibrating_accessibility"))
                }
            }

            if !viewModel.showsSetupCard && viewModel.recoveryScore == nil {
                // Only show generic hint when setup is complete
                Text(String(localized: "recovery_connect_health"))
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(LifeOSColors.Text.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, Spacing.xxs)
            }

            if isSimulationAvailable {
                Divider()
                    .padding(.top, Spacing.s)

                HStack(alignment: .center, spacing: Spacing.s) {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(simulationEntryTitle)
                            .font(LifeOSTypography.caption.weight(.semibold))
                            .foregroundStyle(.primary)

                        Text(simulationEntrySubtitle)
                            .font(LifeOSTypography.caption)
                            .foregroundStyle(LifeOSColors.Text.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: Spacing.s)

                    Button(action: simulationButtonAction(onRoute: routeHandler)) {
                        Text(simulationEntryCTA)
                            .font(LifeOSTypography.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("home.recovery.simulation")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
        .accessibilityElement(children: .contain)
    }

    // MARK: - Setup Progress Card

    private var setupProgressCard: some View {
        return VStack(alignment: .leading, spacing: Spacing.s) {
            // Header with progress
            HStack {
                Label(String(localized: "setup_getting_ready"), systemImage: "checkmark.circle")
                    .font(LifeOSTypography.headline)

                Spacer()

                Text("\(viewModel.setupChecklistStore.completedCount)/\(viewModel.setupChecklistStore.totalCount)")
                    .font(LifeOSTypography.caption.weight(.semibold))
                    .foregroundStyle(LifeOSColors.Text.secondary)
            }

            ProgressView(value: viewModel.setupChecklistStore.progress)
                .tint(LifeOSColors.Semantic.primary)
                .accessibilityHidden(true)

            // Checklist items
            ForEach(viewModel.setupChecklistStore.items, content: setupChecklistRow)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(setupProgressAccessibilityLabel)
    }

    private var setupProgressAccessibilityLabel: String {
        "\(String(localized: "setup_getting_ready")), \(viewModel.setupChecklistStore.completedCount)/\(viewModel.setupChecklistStore.totalCount)"
    }

    @ViewBuilder
    private func setupChecklistRow(_ item: SetupChecklistFeature.Item) -> some View {
        if item.isActionable {
            Button(action: setupChecklistButtonAction(item, onRoute: routeHandler)) {
                setupChecklistRowContent(item)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.title), \(item.subtitle)")
            .accessibilityHint(String(localized: "setup_tap_to_complete"))
        } else {
            setupChecklistRowContent(item)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.title), \(item.isComplete ? String(localized: "setup_done") : item.subtitle)")
        }
    }

    private func setupChecklistRowContent(_ item: SetupChecklistFeature.Item) -> some View {
        HStack(spacing: Spacing.s) {
            // Completion indicator
            Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle")
                .font(LifeOSTypography.body)
                .foregroundStyle(
                    item.isComplete
                        ? LifeOSColors.Recovery.Hex.optimalLight
                        : LifeOSColors.Semantic.primary.opacity(0.4)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(LifeOSTypography.subheadline.weight(item.isComplete ? .regular : .semibold))
                    .foregroundStyle(item.isComplete ? LifeOSColors.Text.secondary : LifeOSColors.Text.primary)
                    .strikethrough(item.isComplete)

                Text(item.subtitle)
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(LifeOSColors.Text.secondary)
            }

            Spacer()

            if item.isActionable {
                Image(systemName: "chevron.right")
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(LifeOSColors.Text.tertiary)
            }
        }
        .padding(.vertical, Spacing.xxs)
    }

    // MARK: - Next Best Action

    private var nextBestActionCard: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let action = viewModel.nextBestAction {
                Label(action.title, systemImage: action.iconName)
                    .font(LifeOSTypography.headline)

                Text(action.message)
                    .font(LifeOSTypography.body)
                    .foregroundStyle(LifeOSColors.Text.secondary)

                Button(action: nextBestActionButtonAction(action.deepLink, onRoute: routeHandler)) {
                    Text(action.buttonTitle)
                        .font(LifeOSTypography.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.s)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, Spacing.xxs)
                .accessibilityLabel(action.buttonTitle)
                .accessibilityHint(action.message)
            } else {
                Label(String(localized: "next_best_action"), systemImage: "sparkles")
                    .font(LifeOSTypography.headline)

                Text(String(localized: "home_next_action_subtitle"))
                    .font(LifeOSTypography.body)
                    .foregroundStyle(LifeOSColors.Text.secondary)

                Button(action: wellnessButtonAction(onRoute: routeHandler)) {
                    Text(String(localized: "start_wellness_check"))
                        .font(LifeOSTypography.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.s)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, Spacing.xxs)
                .accessibilityLabel(String(localized: "home_start_wellness_check_accessibility"))
                .accessibilityHint(String(localized: "home_start_wellness_check_hint"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
        .accessibilityElement(children: .contain)
    }

    // MARK: - Quick Actions

    private var recommendationsCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "sparkles.rectangle.stack")
                    .accessibilityHidden(true)

                Text(String(localized: "home_recommendations_title"))
            }
            .font(LifeOSTypography.headline)
            .foregroundStyle(LifeOSColors.Text.primary)

            ForEach(viewModel.recommendations.prefix(3)) { recommendation in
                Button(action: recommendationButtonAction(recommendation, onRoute: routeHandler)) {
                    recommendationRow(recommendation)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
        .accessibilityElement(children: .contain)
    }

    private func recommendationRow(_ recommendation: Recommendation) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(alignment: .top, spacing: Spacing.s) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(recommendation.title)
                        .font(LifeOSTypography.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)

                    Text(localizedRecommendationCategory(recommendation.category))
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(LifeOSColors.Text.secondary)
                }

                Spacer(minLength: Spacing.s)

                Text(humanizedIdentifier(recommendation.priority))
                    .font(LifeOSTypography.caption.weight(.semibold))
                    .foregroundStyle(priorityColor(recommendation.priority))
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, 4)
                    .background(priorityColor(recommendation.priority).opacity(0.12), in: Capsule())
            }

            Text(recommendation.descriptionWithClinicianCaveat)
                .font(LifeOSTypography.footnote)
                .foregroundStyle(LifeOSColors.Text.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)

            if !recommendation.reasoning.isEmpty {
                Text(recommendation.reasoning)
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(LifeOSColors.Text.tertiary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.xxs)
    }

    private var quickActionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.s) {
                quickActionButton(icon: "fork.knife", label: String(localized: "log_food"), deepLink: "lifeos://nutrition/log")
                quickActionButton(icon: "figure.run", label: String(localized: "workout"), deepLink: "lifeos://workout/log")
                quickActionButton(icon: "pill", label: String(localized: "supplements"), deepLink: "lifeos://supplements/log")
                quickActionButton(icon: "drop", label: String(localized: "water"), deepLink: "lifeos://hydration")
            }
            .padding(.horizontal, 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func quickActionButton(icon: String, label: String, deepLink: String) -> some View {
        Button(action: quickActionButtonAction(deepLink, onRoute: routeHandler)) {
            VStack(spacing: Spacing.xxs) {
                Image(systemName: icon)
                    .imageScale(.large)
                    .frame(width: LayoutConstants.minTouchTarget, height: LayoutConstants.minTouchTarget)
                    .background(LifeOSColors.Surface.card)
                    .clipShape(Circle())

                Text(label)
                    .font(LifeOSTypography.body)
                    .foregroundStyle(LifeOSColors.Text.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 128)
        }
        .accessibilityLabel("\(String(localized: "home_log_prefix")) \(label)")
        .accessibilityHint(String(localized: "home_start_wellness_check_hint"))
    }

    private func runRefreshTask(_ refresh: () async -> Void) async {
        await Self.runRefreshTask(refresh)
    }

    private func refreshTaskAction() async {
        await runRefreshTask {
            await viewModel.refresh()
#if os(iOS)
            await PushNotificationManager.shared.evaluateDelayedAuthorizationPromptIfEligible()
#endif
        }
    }

    private func handleContextualActionTap(
        _ action: RecoveryContextualAction,
        onRoute: (URL) -> Bool
    ) {
        Self.performRoute(action.deepLink, onRoute: onRoute)
    }

    private func contextualActionButtonAction(
        _ action: RecoveryContextualAction,
        onRoute: @escaping (URL) -> Bool
    ) -> () -> Void {
        { handleContextualActionTap(action, onRoute: onRoute) }
    }

    private func handleSetupChecklistTap(
        _ item: SetupChecklistFeature.Item,
        onRoute: (URL) -> Bool
    ) {
        Self.performChecklistRoute(item, onRoute: onRoute)
    }

    private func setupChecklistButtonAction(
        _ item: SetupChecklistFeature.Item,
        onRoute: @escaping (URL) -> Bool
    ) -> () -> Void {
        { handleSetupChecklistTap(item, onRoute: onRoute) }
    }

    private func handleNextBestActionTap(_ deepLink: URL, onRoute: (URL) -> Bool) {
        Self.performRoute(deepLink, onRoute: onRoute)
    }

    private func nextBestActionButtonAction(
        _ deepLink: URL,
        onRoute: @escaping (URL) -> Bool
    ) -> () -> Void {
        { handleNextBestActionTap(deepLink, onRoute: onRoute) }
    }

    private func handleWellnessActionTap(onRoute: (URL) -> Bool) {
        Self.performRoute(URL(string: "lifeos://wellness"), onRoute: onRoute)
    }

    private func wellnessButtonAction(onRoute: @escaping (URL) -> Bool) -> () -> Void {
        { handleWellnessActionTap(onRoute: onRoute) }
    }

    private func handleQuickActionTap(_ deepLink: String, onRoute: (URL) -> Bool) {
        Self.performRoute(URL(string: deepLink), onRoute: onRoute)
    }

    private func handleSimulationTap(onRoute: (URL) -> Bool) {
        Self.performRoute(Self.simulationRoute, onRoute: onRoute)
    }

    private func handleRecommendationTap(
        _ recommendation: Recommendation,
        onRoute: (URL) -> Bool
    ) {
        Self.performRoute(recommendationDeepLink(for: recommendation), onRoute: onRoute)
    }

    private func quickActionButtonAction(
        _ deepLink: String,
        onRoute: @escaping (URL) -> Bool
    ) -> () -> Void {
        { handleQuickActionTap(deepLink, onRoute: onRoute) }
    }

    private func recommendationButtonAction(
        _ recommendation: Recommendation,
        onRoute: @escaping (URL) -> Bool
    ) -> () -> Void {
        { handleRecommendationTap(recommendation, onRoute: onRoute) }
    }

    private func simulationButtonAction(
        onRoute: @escaping (URL) -> Bool
    ) -> () -> Void {
        { handleSimulationTap(onRoute: onRoute) }
    }

    private static func runRefreshTask(_ refresh: () async -> Void) async {
        await refresh()
    }

    private static func performChecklistRoute(
        _ item: SetupChecklistFeature.Item,
        onRoute: (URL) -> Bool,
        haptic: () -> Void = { HapticManager.lightTap() }
    ) {
        guard !item.isComplete,
              let route = item.route,
              let url = URL(string: route) else {
            return
        }
        performRoute(url, onRoute: onRoute, haptic: haptic)
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

    private func recommendationDeepLink(for recommendation: Recommendation) -> URL? {
        switch recommendation.category.lowercased() {
        case "nutrition":
            return URL(string: "lifeos://nutrition")
        case "training":
            return URL(string: "lifeos://workout")
        case "supplement", "supplements":
            return URL(string: "lifeos://supplements")
        case "sleep":
            return URL(string: "lifeos://sleep")
        case "recovery":
            return URL(string: "lifeos://recovery")
        case "hydration":
            return URL(string: "lifeos://hydration")
        default:
            return URL(string: "lifeos://insights")
        }
    }

    private func localizedRecommendationCategory(_ category: String) -> String {
        switch category.lowercased() {
        case "recovery":
            return String(localized: "insights_category_recovery")
        case "nutrition":
            return String(localized: "insights_category_nutrition")
        case "training":
            return String(localized: "insights_category_training")
        case "sleep":
            return String(localized: "insights_category_sleep")
        case "supplement", "supplements":
            return String(localized: "insights_category_supplement")
        case "health":
            return String(localized: "insights_category_health")
        default:
            return humanizedIdentifier(category)
        }
    }

    private func priorityColor(_ priority: String) -> Color {
        switch priority.lowercased() {
        case "critical":
            return LifeOSColors.Semantic.destructive
        case "high":
            return LifeOSColors.Semantic.warning
        default:
            return LifeOSColors.Semantic.primary
        }
    }

    private func humanizedIdentifier(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "_", with: " ")
        guard let first = normalized.first else { return value }
        return first.uppercased() + normalized.dropFirst()
    }
}

#if DEBUG
extension HomeView {
    @MainActor
    func _testEvaluateSections() {
        _ = recoveryCard
        _ = setupProgressCard
        _ = nextBestActionCard
        _ = quickActionsRow
        _ = setupChecklistRow(
            SetupChecklistFeature.Item(
                id: "weight",
                icon: "scalemass",
                title: "Weight",
                subtitle: "Set your weight",
                isComplete: false,
                route: "lifeos://body-composition"
            )
        )
        _ = setupChecklistRow(
            SetupChecklistFeature.Item(
                id: "healthkit",
                icon: "heart.fill",
                title: "Health",
                subtitle: "Connected",
                isComplete: true,
                route: "lifeos://settings"
            )
        )
        _ = quickActionButton(
            icon: "fork.knife",
            label: "Test",
            deepLink: "lifeos://nutrition/log"
        )
    }

    func _testRunRefreshTask(_ refresh: @escaping () async -> Void) async {
        await Self.runRefreshTask(refresh)
    }

    @MainActor
    func _testRunInstanceRefreshTask(_ refresh: @escaping () async -> Void) async {
        await runRefreshTask(refresh)
    }

    @MainActor
    func _testRunRefreshTaskAction() async {
        await refreshTaskAction()
    }

    @MainActor
    func _testTriggerInstanceActions() -> [String] {
        var handled: [String] = []
        let onRoute: (URL) -> Bool = {
            handled.append($0.absoluteString)
            return true
        }

        let contextual = RecoveryContextualAction(
            title: "Hydrate",
            message: "Drink water",
            buttonTitle: "Open",
            deepLink: URL(string: "lifeos://hydration")!
        )
        contextualActionButtonAction(contextual, onRoute: onRoute)()
        handleContextualActionTap(contextual, onRoute: onRoute)

        let checklistItem = SetupChecklistFeature.Item(
            id: "sleep",
            icon: "bed.double",
            title: "Sleep",
            subtitle: "Open Sleep",
            isComplete: false,
            route: "lifeos://sleep"
        )
        setupChecklistButtonAction(checklistItem, onRoute: onRoute)()
        handleSetupChecklistTap(checklistItem, onRoute: onRoute)

        wellnessButtonAction(onRoute: onRoute)()
        quickActionButtonAction("lifeos://nutrition/log", onRoute: onRoute)()
        simulationButtonAction(onRoute: onRoute)()
        handleWellnessActionTap(onRoute: onRoute)
        handleQuickActionTap("lifeos://nutrition/log", onRoute: onRoute)
        handleSimulationTap(onRoute: onRoute)

        return handled
    }

    static func _testRouteExecutionSamples() -> [String] {
        var handled: [String] = []
        let onRoute: (URL) -> Bool = {
            handled.append($0.absoluteString)
            return true
        }
        let noHaptic = {}

        performChecklistRoute(
            SetupChecklistFeature.Item(
                id: "todo",
                icon: "circle",
                title: "Todo",
                subtitle: "Open",
                isComplete: false,
                route: "lifeos://nutrition/log"
            ),
            onRoute: onRoute,
            haptic: noHaptic
        )
        performChecklistRoute(
            SetupChecklistFeature.Item(
                id: "done",
                icon: "checkmark.circle",
                title: "Done",
                subtitle: "Skip",
                isComplete: true,
                route: "lifeos://supplements/log"
            ),
            onRoute: onRoute,
            haptic: noHaptic
        )
        performRoute(URL(string: "lifeos://wellness"), onRoute: onRoute, haptic: noHaptic)
        performRoute(URL(string: "lifeos://workout/log"), onRoute: onRoute, haptic: noHaptic)
        performRoute(simulationRoute, onRoute: onRoute, haptic: noHaptic)
        performRoute(nil, onRoute: onRoute, haptic: noHaptic)

        return handled
    }

    static func _testRouteHandler(router: DeepLinkRouter?, url: URL) -> Bool {
        makeRouteHandler(router: router)(url)
    }
}
#endif

#Preview {
    HomeView()
}
