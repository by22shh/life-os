// MARK: - Main Tab View
// App shell with 4-tab navigation: Home, Diary, Insights, Settings.

import SwiftUI
import Foundation
import GRDB
import ComposableArchitecture
#if canImport(UIKit)
import UIKit
#endif

struct MainTabView: View {
    @Environment(DeepLinkRouter.self) private var deepLinkRouter
    private let injectedRouter: DeepLinkRouter?
    @State private var presentedDestination: DeepLinkDestination?
    @State private var contentRefreshToken = 0
    @State private var insightsNeedsReviewCount: Int = 0
    @State private var needsReviewObservationAuthId: String?
    @State private var needsReviewObservationVersion = 0

    init(injectedRouter: DeepLinkRouter? = nil) {
        self.injectedRouter = injectedRouter
        Self.configureTabBarAppearance()
    }

    private var router: DeepLinkRouter { if let injectedRouter { return injectedRouter }; return deepLinkRouter }

    private static func resolveRouter(
        injectedRouter: DeepLinkRouter?,
        environmentRouter: DeepLinkRouter
    ) -> DeepLinkRouter {
        if let injectedRouter {
            return injectedRouter
        }
        return environmentRouter
    }

    private static func configureTabBarAppearance() {
        #if canImport(UIKit)
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        let backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: 0x221C17)
                : UIColor(hex: 0xFFFBF7)
        }
        appearance.backgroundColor = backgroundColor
        appearance.shadowColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: 0x3A3128)
                : UIColor(hex: 0xE6D8CB)
        }
        let selectedColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: 0x0A84FF)
                : UIColor(hex: 0x005DBA)
        }
        appearance.stackedLayoutAppearance.selected.iconColor = selectedColor
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [
            .foregroundColor: selectedColor
        ]
        appearance.stackedLayoutAppearance.normal.iconColor = .label
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [
            .foregroundColor: UIColor.label
        ]

        let tabBar = UITabBar.appearance()
        tabBar.isTranslucent = false
        tabBar.backgroundColor = backgroundColor
        tabBar.barTintColor = backgroundColor
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        #endif
    }

    private var tabSelectionBinding: Binding<AppTab> {
        Binding(
            get: { router.selectedTab },
            set: { router.selectedTab = $0 }
        )
    }

    var body: some View {
        TabView(selection: tabSelectionBinding) {
            HomeView()
                .tabItem {
                    Label(AppTab.home.title, systemImage: AppTab.home.icon)
                }
                .tag(AppTab.home)

            DiaryView(externalRefreshToken: contentRefreshToken)
                .tabItem {
                    Label(AppTab.diary.title, systemImage: AppTab.diary.icon)
                }
                .tag(AppTab.diary)

            InsightsView()
                .tabItem {
                    Label(AppTab.insights.title, systemImage: AppTab.insights.icon)
                }
                .tag(AppTab.insights)
                .badge(insightsNeedsReviewCount)

            SettingsView()
                .tabItem {
                    Label(AppTab.settings.title, systemImage: AppTab.settings.icon)
                }
                .tag(AppTab.settings)
        }
        .tint(LifeOSColors.Semantic.primary)
        .toolbarBackground(LifeOSColors.Surface.elevated, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .environment(\.defaultMinListRowHeight, LayoutConstants.listRowMinHeight)
        .onChange(of: router.pendingNavigation) { _, newValue in
            pendingNavigationChanged(newValue)
        }
        .sheet(item: $presentedDestination, onDismiss: destinationSheetDismissed, content: destinationSheetContent)
        .task(runRefreshTask)
        .task(id: needsReviewObservationVersion, observeNeedsReviewBadgeTask)
        .onChange(of: router.selectedTab) { _, newValue in
            selectedTabChanged(newValue)
        }
    }

    private func pendingNavigationChanged(_: DeepLinkDestination?) {
        handlePendingNavigationChange()
    }

    private func selectedTabChanged(_: AppTab) {
        handleSelectedTabChange()
    }

    private func destinationSheetDismissed() {
        handleDestinationSheetDismissed()
    }

    private func runRefreshTask() async {
        handlePendingNavigationChange()
        await refreshNeedsReviewBadgeForCurrentAuth()
    }

    private func handlePendingNavigationChange() {
        guard let destination = router.consumePendingNavigation() else {
            return
        }
        presentedDestination = Self.consumePresentableDestination {
            destination
        }
    }

    private func handleSelectedTabChange() {
        Self.scheduleRefreshTask {
            await refreshNeedsReviewBadgeForCurrentAuth()
        }
    }

    private func handleDestinationSheetDismissed() {
        contentRefreshToken = Self.nextContentRefreshToken(contentRefreshToken)
        Self.scheduleRefreshTask {
            await refreshNeedsReviewBadgeForCurrentAuth()
        }
    }

    private static func nextContentRefreshToken(_ token: Int) -> Int {
        token &+ 1
    }

    private func observeNeedsReviewBadgeTask() async {
        let (version, authId) = await MainActor.run {
            (needsReviewObservationVersion, needsReviewObservationAuthId)
        }
        guard version > 0 else { return }

        do {
            for try await count in Self.makeNeedsReviewCountObservation(
                authId: authId,
                reader: DatabaseManager.shared.dbQueue
            ) {
                await MainActor.run {
                    insightsNeedsReviewCount = count
                }
            }
        } catch {
            await MainActor.run {
                insightsNeedsReviewCount = 0
            }
        }
    }

    private func destinationSheetContent(_ destination: DeepLinkDestination) -> some View {
        DeepLinkDestinationView(destination: destination)
    }

    /// Query count of insights and food_logs needing review (confidence < 0.65).
    private func refreshNeedsReviewBadge() async {
        let authId = await currentAuthId()
        await refreshNeedsReviewBadge(for: authId)
    }

    private func refreshNeedsReviewBadgeForCurrentAuth() async {
        let authId = await currentAuthId()
        await syncNeedsReviewObservationAuthId(authId)
        await refreshNeedsReviewBadge(for: authId)
    }

    private func refreshNeedsReviewBadge(for authId: String?) async {
        await refreshNeedsReviewBadge {
            try await DatabaseManager.shared.dbQueue.read { db -> Int in
                try Self.computeNeedsReviewCount(db: db, authId: authId)
            }
        }
    }

    private func refreshNeedsReviewBadge(
        loadCount: @escaping @Sendable () async throws -> Int
    ) async {
        do {
            let count = try await loadCount()
            await MainActor.run {
                insightsNeedsReviewCount = count
            }
        } catch {
            await MainActor.run {
                insightsNeedsReviewCount = 0
            }
        }
    }

    private func currentAuthId() async -> String? {
        await MainActor.run {
            AuthManager.activeAuthId?.uuidString
        }
    }

    private func syncNeedsReviewObservationAuthId(_ authId: String?) async {
        await MainActor.run {
            guard needsReviewObservationVersion == 0 || needsReviewObservationAuthId != authId else {
                return
            }
            needsReviewObservationAuthId = authId
            needsReviewObservationVersion += 1
        }
    }

    nonisolated private static func makeNeedsReviewCountObservation(
        authId: String?,
        reader: any DatabaseReader
    ) -> AsyncValueObservation<Int> {
        ValueObservation
            .tracking { db in
                try computeNeedsReviewCount(db: db, authId: authId)
            }
            .values(in: reader, bufferingPolicy: .bufferingNewest(1))
    }

    nonisolated private static func computeNeedsReviewCount(db: Database, authId: String?) throws -> Int {
        guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
            return 0
        }
        let insightsCount = try Int.fetchOne(db, sql: """
            SELECT COUNT(*)
            FROM insights
            WHERE (user_id = ? OR user_id = ?)
              AND needs_review = 1
              AND dismissed = 0
        """, arguments: [userId, userId.uuidString])!
        let foodCount = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM food_logs
            WHERE (user_id = ? OR user_id = ?)
              AND needs_review = 1
              AND deleted_at IS NULL
        """, arguments: [userId, userId.uuidString])!
        return insightsCount + foodCount
    }

    private static func consumePresentableDestination(
        consume: () -> DeepLinkDestination?
    ) -> DeepLinkDestination? {
        guard let destination = consume() else { return nil }
        switch destination {
        case .home, .insights, .settings:
            return nil
        default:
            return destination
        }
    }

    private static func scheduleRefreshTask(
        _ refresh: @escaping @Sendable () async -> Void,
        scheduler: (@escaping @Sendable () async -> Void) -> Void = { refresh in
            Task { await refresh() }
        }
    ) {
        scheduler(refresh)
    }
}

// MARK: - Tab Definition

enum AppTab: String, CaseIterable, Sendable {
    case home
    case diary
    case insights
    case settings

    var title: String {
        switch self {
        case .home: return String(localized: "tab_home")
        case .diary: return String(localized: "tab_diary")
        case .insights: return String(localized: "tab_insights")
        case .settings: return String(localized: "tab_settings")
        }
    }

    var icon: String {
        switch self {
        case .home: return "heart.text.square"
        case .diary: return "book"
        case .insights: return "lightbulb"
        case .settings: return "gearshape"
        }
    }
}

struct DeepLinkDestinationView: View {
    let destination: DeepLinkDestination

    var body: some View {
        NavigationStack {
            switch destination {
            case .home:
                HomeView()
            case .diary(let date):
                DiaryView(initialDateString: date)
            case .diaryReview(let date):
                DiaryView(initialDateString: date, initialMode: .review)
            case .insights:
                InsightsView()
            case .simulation:
                SimulationView()
            case .insightDetail(let id):
                InsightDetailView(insightId: id)
            case .settings:
                SettingsView()
            case .settingsSync:
                SettingsSyncView()
            case .settingsNotifications:
                SettingsNotificationsView()
            case .settingsPrivacy:
                SettingsPrivacyView()
            case .recoveryDetail(let date):
                RecoveryDetailView(dateString: date)
            case .nutrition(let date):
                NutritionDayView(dateString: date)
            case .nutritionLog(let method, let aiConfidence):
                NutritionLogView(method: method, aiConfidence: aiConfidence)
            case .supplements(let date):
                SupplementsDayView(dateString: date)
            case .supplementsLog(let date):
                SupplementsDayView(dateString: date, launchContext: .log)
            case .workout(let date):
                TrainingDayView(dateString: date)
            case .workoutLog:
                WorkoutLogView()
            case .authCallback:
                AuthCallbackView()
            case .experiment(let id):
                ExperimentDetailView(experimentId: id)
            case .labs:
                LabsOverviewView(
                    store: Store(initialState: LabsFeature.State()) {
                        LabsFeature()
                    }
                )
            case .labScan(let id):
                LabScanDetailView(scanId: id)
            case .hydration(let date):
                HydrationDayView(dateString: date)
            case .wellness(let date):
                WellnessCheckDayView(dateString: date)
            case .menstrual(let date):
                MenstrualDayView(dateString: date)
            case .bodyComposition:
                BodyCompositionView()
            case .sleep(let date):
                SleepDayView(dateString: date)
            }
        }
    }
}

extension DeepLinkDestination: Identifiable {
    var id: String {
        switch self {
        case .home: return "home"
        case .diary(let date): return "diary:\(date ?? "today")"
        case .diaryReview(let date): return "diary_review:\(date ?? "today")"
        case .insights: return "insights"
        case .simulation: return "simulation"
        case .insightDetail(let id): return "insight:\(id.uuidString)"
        case .settings: return "settings"
        case .settingsSync: return "settings:sync"
        case .settingsNotifications: return "settings:notifications"
        case .settingsPrivacy: return "settings:privacy"
        case .recoveryDetail(let date): return "recovery:\(date ?? "today")"
        case .nutrition(let date): return "nutrition:\(date ?? "today")"
        case .nutritionLog(let method, let aiConfidence):
            let confidencePart = aiConfidence.map { String(format: "%.2f", $0) } ?? "none"
            return "nutrition_log:\(method?.rawValue ?? "none"):\(confidencePart)"
        case .supplements(let date): return "supplements:\(date ?? "today")"
        case .supplementsLog(let date): return "supplements_log:\(date ?? "today")"
        case .workout(let date): return "workout:\(date ?? "today")"
        case .workoutLog: return "workout_log"
        case .authCallback: return "auth_callback"
        case .experiment(let id): return "experiment:\(id.uuidString)"
        case .labs: return "labs"
        case .labScan(let id): return "labs:\(id.uuidString)"
        case .hydration(let date): return "hydration:\(date ?? "today")"
        case .wellness(let date): return "wellness:\(date ?? "today")"
        case .menstrual(let date): return "menstrual:\(date ?? "today")"
        case .bodyComposition: return "body_composition"
        case .sleep(let date): return "sleep:\(date ?? "today")"
        }
    }
}

#if DEBUG
extension MainTabView {
    @MainActor
    func _testEvaluateBody() {
        _ = body
    }

    @MainActor
    func _testRefreshNeedsReviewBadge() async {
        await refreshNeedsReviewBadge()
    }

    @MainActor
    func _testRefreshNeedsReviewBadgeFailurePath() async {
        await refreshNeedsReviewBadge {
            struct CoverageFailure: Error {}
            throw CoverageFailure()
        }
    }

    @MainActor
    func _testRunRefreshTask() async {
        await runRefreshTask()
    }

    @MainActor
    func _testObserveNeedsReviewBadgeTask() async {
        await observeNeedsReviewBadgeTask()
    }

    @MainActor
    func _testHandleSelectedTabChange() {
        handleSelectedTabChange()
    }

    @MainActor
    func _testHandleDestinationSheetDismissed() {
        handleDestinationSheetDismissed()
    }

    @MainActor
    func _testHandlePendingNavigationChange() {
        handlePendingNavigationChange()
    }

    @MainActor
    func _testInvokeOnChangeWrappers() {
        pendingNavigationChanged(nil)
        selectedTabChanged(.home)
    }

    @MainActor
    func _testDestinationSheetView(_ destination: DeepLinkDestination) -> some View {
        destinationSheetContent(destination)
    }

    nonisolated static func _testComputeNeedsReviewCount(db: Database, authId: String?) throws -> Int {
        try computeNeedsReviewCount(db: db, authId: authId)
    }

    nonisolated static func _testMakeNeedsReviewCountObservation(
        authId: String?,
        reader: any DatabaseReader
    ) -> AsyncValueObservation<Int> {
        makeNeedsReviewCountObservation(authId: authId, reader: reader)
    }

    static func _testConsumePresentableDestination(_ destination: DeepLinkDestination?) -> DeepLinkDestination? {
        consumePresentableDestination { destination }
    }

    static func _testResolveRouter(
        injectedRouter: DeepLinkRouter?,
        environmentRouter: DeepLinkRouter
    ) -> DeepLinkRouter {
        resolveRouter(
            injectedRouter: injectedRouter,
            environmentRouter: environmentRouter
        )
    }

    static func _testNextContentRefreshToken(_ token: Int) -> Int {
        nextContentRefreshToken(token)
    }

    @MainActor
    func _testRouterGetterIsInjected() -> Bool {
        guard let injectedRouter else { return false }
        return router === injectedRouter
    }

    @MainActor
    func _testResolveRouterFromGetter() -> DeepLinkRouter {
        router
    }

    @MainActor
    func _testInsightsNeedsReviewCount() -> Int {
        insightsNeedsReviewCount
    }

    @MainActor
    func _testNeedsReviewObservationVersion() -> Int {
        needsReviewObservationVersion
    }

    @MainActor
    func _testNeedsReviewObservationAuthId() -> String? {
        needsReviewObservationAuthId
    }

    @MainActor
    func _testPresentedDestinationId() -> String? {
        presentedDestination?.id
    }

    @MainActor
    func _testContentRefreshToken() -> Int {
        contentRefreshToken
    }

    @MainActor
    func _testTabSelectionBindingRoundTrip(
        initial: AppTab,
        updated: AppTab
    ) -> (read: AppTab, stored: AppTab) {
        router.selectedTab = initial
        let binding = tabSelectionBinding
        let readValue = binding.wrappedValue
        binding.wrappedValue = updated
        return (readValue, router.selectedTab)
    }
}
#endif

// MARK: - Preview

#Preview {
    MainTabView()
        .environment(DeepLinkRouter())
}
