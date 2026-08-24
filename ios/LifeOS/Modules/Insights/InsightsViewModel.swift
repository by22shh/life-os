import Foundation
import Observation
import GRDB

@Observable
@MainActor
final class InsightsViewModel {
    private let dbQueue: DatabaseQueue
    private let dailyInsightsService: any DailyInsightsManaging
    private let weeklyStrategyService: any WeeklyStrategyManaging

    private(set) var lowConfidenceCount: Int = 0
    private(set) var insights: [Insight] = []
    private(set) var allInsights: [Insight] = []
    private(set) var selectedDomains: Set<InsightCategory> = []
    private(set) var domainCounts: [InsightCategory: Int] = [:]
    private(set) var latestWeeklyStrategyReport: WeeklyStrategyReport?
    private(set) var isLoading = false
    private(set) var loadError: String?

    var hasAnyInsights: Bool {
        !allInsights.isEmpty
    }

    var hasActiveDomainFilters: Bool {
        !selectedDomains.isEmpty
    }

    var totalInsightCount: Int {
        allInsights.count
    }

    init(
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue,
        dailyInsightsService: any DailyInsightsManaging = DailyInsightsService(),
        weeklyStrategyService: any WeeklyStrategyManaging = WeeklyStrategyService()
    ) {
        self.dbQueue = dbQueue
        self.dailyInsightsService = dailyInsightsService
        self.weeklyStrategyService = weeklyStrategyService
    }

    var availableDomains: [InsightCategory] {
        let presentDomains = Set(allInsights.map(\.category)).union(selectedDomains)
        return InsightCategory.allCases.filter(presentDomains.contains)
    }

    func isDomainSelected(_ domain: InsightCategory) -> Bool {
        selectedDomains.contains(domain)
    }

    func domainCount(for domain: InsightCategory) -> Int {
        domainCounts[domain, default: 0]
    }

    func toggleDomain(_ domain: InsightCategory) {
        if selectedDomains.contains(domain) {
            selectedDomains.remove(domain)
        } else {
            selectedDomains.insert(domain)
        }
        applyDomainFilters()
    }

    func selectAllDomains() {
        guard !selectedDomains.isEmpty else { return }
        selectedDomains.removeAll()
        applyDomainFilters()
    }

    func refresh() async {
        isLoading = true
        loadError = nil
        do {
            let currentDailySnapshot: DailyInsightsSnapshot?
            do {
                currentDailySnapshot = try await dailyInsightsService.refreshCurrentDaySnapshot()
            } catch {
                currentDailySnapshot = nil
            }

            let currentWeeklyReport: WeeklyStrategyReport?
            do {
                currentWeeklyReport = try await weeklyStrategyService.refreshCurrentWeekReport()
            } catch {
                currentWeeklyReport = nil
            }

            let authId = AuthManager.activeAuthId?.uuidString
            let result = try await dbQueue.read { db -> (Int, [Insight], WeeklyStrategyReport?) in
                guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                    return (0, [], nil)
                }

                let lowConfidence = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*)
                        FROM insights
                        WHERE (user_id = ? OR user_id = ?)
                          AND needs_review = 1
                          AND dismissed = 0
                        """,
                    arguments: [userId, userId.uuidString]
                )!

                let items = try Insight.fetchAll(
                    db,
                    sql: """
                        SELECT *
                        FROM insights
                        WHERE (user_id = ? OR user_id = ?)
                          AND dismissed = 0
                        ORDER BY priority ASC, created_at DESC
                        LIMIT 100
                        """,
                    arguments: [userId, userId.uuidString]
                )

                let latestWeeklyStrategyReport = try WeeklyStrategyReport.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM weekly_strategy_reports
                        WHERE (user_id = ? OR user_id = ?)
                        ORDER BY week_end DESC, updated_at DESC
                        LIMIT 1
                        """,
                    arguments: [userId, userId.uuidString]
                )

                return (lowConfidence, items, latestWeeklyStrategyReport)
            }

            let resolvedInsights = result.1.isEmpty
                ? (currentDailySnapshot?.insights ?? [])
                : result.1
            allInsights = resolvedInsights
            domainCounts = Dictionary(grouping: resolvedInsights, by: \.category).mapValues(\.count)
            let resolvedLowConfidenceCount = resolvedInsights == result.1
                ? result.0
                : resolvedInsights.reduce(into: 0) { count, insight in
                    if insight.requiresReview {
                        count += 1
                    }
                }
            applyDomainFilters(defaultLowConfidenceCount: resolvedLowConfidenceCount)
            latestWeeklyStrategyReport = currentWeeklyReport ?? result.2
        } catch {
            lowConfidenceCount = 0
            allInsights = []
            insights = []
            domainCounts = [:]
            latestWeeklyStrategyReport = nil
            loadError = (error as? LocalizedError)?.errorDescription
                ?? SyncError.serverError(code: 0, message: nil).errorDescription
        }
        isLoading = false
    }

    private func applyDomainFilters(defaultLowConfidenceCount: Int? = nil) {
        if selectedDomains.isEmpty {
            insights = allInsights
            lowConfidenceCount = defaultLowConfidenceCount ?? allInsights.reduce(into: 0) { count, insight in
                if insight.requiresReview {
                    count += 1
                }
            }
            return
        }

        let filteredInsights = allInsights.filter { selectedDomains.contains($0.category) }
        insights = filteredInsights
        lowConfidenceCount = filteredInsights.reduce(into: 0) { count, insight in
            if insight.requiresReview {
                count += 1
            }
        }
    }
}

#if DEBUG
extension InsightsViewModel {
    func _testOverrideState(
        lowConfidenceCount: Int,
        insights: [Insight],
        latestWeeklyStrategyReport: WeeklyStrategyReport?,
        isLoading: Bool,
        loadError: String?,
        allInsights: [Insight]? = nil,
        selectedDomains: Set<InsightCategory> = [],
        domainCounts: [InsightCategory: Int]? = nil
    ) {
        self.lowConfidenceCount = lowConfidenceCount
        self.insights = insights
        self.allInsights = allInsights ?? insights
        self.selectedDomains = selectedDomains
        self.domainCounts = domainCounts ?? Dictionary(grouping: self.allInsights, by: \.category).mapValues(\.count)
        self.latestWeeklyStrategyReport = latestWeeklyStrategyReport
        self.isLoading = isLoading
        self.loadError = loadError
    }
}
#endif
