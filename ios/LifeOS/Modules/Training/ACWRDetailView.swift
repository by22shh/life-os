// MARK: - ACWR Detail View
// Weekly ACWR (Acute:Chronic Workload Ratio) metrics screen.
// Architecture mirrors RecoveryDetailView + RecoveryDetailViewModel.
// Scientific reference: Williams et al. (2017), Gabbett (2020).

import GRDB
import SwiftUI

struct ACWRDetailView: View {
    let dateString: String?
    @State private var viewModel: ACWRDetailViewModel

    init(dateString: String?) {
        self.dateString = dateString
        _viewModel = State(initialValue: ACWRDetailViewModel(dateString: dateString))
    }

#if DEBUG
    fileprivate init(dateString: String?, testViewModel: ACWRDetailViewModel) {
        self.dateString = dateString
        _viewModel = State(initialValue: testViewModel)
    }
#endif

    var body: some View {
        @Bindable var viewModel = viewModel

        ScrollView {
            VStack(spacing: Spacing.l) {
                // Header
                VStack(spacing: Spacing.xs) {
                    Label(String(localized: "training_load"), systemImage: "chart.bar")
                        .font(LifeOSTypography.title3)
                    Text(viewModel.displayDate)
                        .font(LifeOSTypography.subheadline)
                        .foregroundStyle(.secondary)
                }

                if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else if viewModel.hasSufficientData, let acwr = viewModel.acwrValue {
                    // ACWR Ratio Card
                    acwrRatioCard(acwr: acwr)

                    // Acute vs Chronic Load Bars
                    if let acute = viewModel.acuteLoad, let chronic = viewModel.chronicLoad {
                        loadBarsSection(acute: acute, chronic: chronic)
                    }

                    // Weekly Trend
                    if let trend = viewModel.weeklyTrend {
                        weeklyTrendRow(trend: trend)
                    }

                    // Advanced Metrics (collapsible)
                    advancedMetricsSection

                    // Disclaimer
                    disclaimerFooter
                } else {
                    // Cold-start: insufficient data
                    coldStartView
                }
            }
            .padding(LayoutConstants.contentPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LifeOSColors.Surface.background)
        .navigationTitle(String(localized: "training_load"))
        .accessibilityIdentifier("acwr.detail.screen")
        .task(viewModel.load)
    }

    // MARK: - ACWR Ratio Card

    private func acwrRatioCard(acwr: Double) -> some View {
        VStack(spacing: Spacing.s) {
            Text(String(format: "%.2f", acwr))
                .font(LifeOSTypography.metricMedium)
                .foregroundStyle(viewModel.trainingZone?.color ?? .primary)

            if let zone = viewModel.trainingZone {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: zone.iconName)
                        .foregroundStyle(zone.color)
                    Text(zone.label)
                        .font(LifeOSTypography.body)
                        .foregroundStyle(zone.color)
                }
            }

            Text(String(localized: "acwr_ratio"))
                .font(LifeOSTypography.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.l)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(acwrAccessibilityLabel)
    }

    private var acwrAccessibilityLabel: String {
        guard let acwr = viewModel.acwrValue else { return "" }
        let ratioText = String(format: "%.2f", acwr)
        let zoneText = viewModel.trainingZone?.label ?? ""
        return "\(String(localized: "acwr_ratio")): \(ratioText), \(zoneText)"
    }

    // MARK: - Load Bars

    private func loadBarsSection(acute: Double, chronic: Double) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(String(localized: "acute_load_7d"))
                .font(LifeOSTypography.caption)
                .foregroundStyle(.secondary)
            loadBar(
                value: acute,
                maxValue: max(acute, chronic) * 1.2,
                color: LifeOSColors.Recovery.ready,
                label: String(format: "%.0f", acute)
            )

            Text(String(localized: "chronic_load_28d"))
                .font(LifeOSTypography.caption)
                .foregroundStyle(.secondary)
            loadBar(
                value: chronic,
                maxValue: max(acute, chronic) * 1.2,
                color: LifeOSColors.Recovery.optimal,
                label: String(format: "%.0f", chronic)
            )
        }
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(String(localized: "acute_load_7d")): \(String(format: "%.0f", acute)), \(String(localized: "chronic_load_28d")): \(String(format: "%.0f", chronic))"
        )
    }

    private func loadBar(value: Double, maxValue: Double, color: Color, label: String) -> some View {
        HStack(spacing: Spacing.s) {
            GeometryReader { geometry in
                let fraction = maxValue > 0 ? min(value / maxValue, 1.0) : 0
                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(width: geometry.size.width * fraction)
            }
            .frame(height: 12)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.15))
            )

            Text(label)
                .font(LifeOSTypography.headline)
                .frame(minWidth: 44, alignment: .trailing)
        }
    }

    // MARK: - Weekly Trend

    private func weeklyTrendRow(trend: WeeklyTrend) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: trend.iconName)
                .foregroundStyle(trend.color)
                .frame(width: LayoutConstants.minTouchTarget, height: LayoutConstants.minTouchTarget)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(String(localized: "weekly_trend"))
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
                Text(trend.label)
                    .font(LifeOSTypography.body)
            }
            Spacer()
        }
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(trend.accessibilityLabel)
    }

    // MARK: - Advanced Metrics

    @State private var showAdvanced = false

    private var advancedMetricsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Button {
                withAnimation(LifeOSAnimation.standard) {
                    showAdvanced.toggle()
                }
            } label: {
                HStack {
                    Text(String(localized: "advanced_metrics"))
                        .font(LifeOSTypography.headline)
                    Spacer()
                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .foregroundStyle(.primary)
            }

            if showAdvanced {
                VStack(spacing: Spacing.xs) {
                    if let monotony = viewModel.monotony {
                        metricRow(title: String(localized: "monotony"), value: String(format: "%.2f", monotony))
                    }
                    if let strain = viewModel.strain {
                        metricRow(title: String(localized: "strain"), value: String(format: "%.0f", strain))
                    }
                    Divider()
                    if let ctl = viewModel.fitnessCtl {
                        metricRow(title: String(localized: "fitness_ctl"), value: String(format: "%.0f", ctl))
                    }
                    if let atl = viewModel.fatigueAtl {
                        metricRow(title: String(localized: "fatigue_atl"), value: String(format: "%.0f", atl))
                    }
                    if let tsb = viewModel.formTsb {
                        metricRow(
                            title: String(localized: "form_tsb"),
                            value: String(format: "%+.0f", tsb),
                            valueColor: tsb >= 0 ? LifeOSColors.Semantic.success : LifeOSColors.Semantic.warning
                        )
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
    }

    private func metricRow(title: String, value: String, valueColor: Color = .primary) -> some View {
        HStack {
            Text(title)
                .font(LifeOSTypography.body)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(LifeOSTypography.headline)
                .foregroundStyle(valueColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }

    // MARK: - Cold Start

    private var coldStartView: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(String(localized: "acwr_collecting_data"))
                .font(LifeOSTypography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ProgressView(value: Double(viewModel.daysOfData), total: 21)
                .tint(LifeOSColors.Semantic.primary)
                .padding(.horizontal, Spacing.l)

            Text("\(viewModel.daysOfData) / 21 \(String(localized: "days"))")
                .font(LifeOSTypography.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.l)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(String(localized: "acwr_collecting_data")). \(viewModel.daysOfData) of 21 days."
        )
    }

    // MARK: - Disclaimer

    private var disclaimerFooter: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "info.circle")
                .font(.caption)
            Text(String(localized: "acwr_disclaimer"))
                .font(LifeOSTypography.caption2)
        }
        .foregroundStyle(.tertiary)
        .padding(.top, Spacing.s)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - ViewModel

@MainActor
@Observable
private final class ACWRDetailViewModel {
    private(set) var acwrValue: Double?
    private(set) var trainingZone: TrainingZoneState?
    private(set) var weeklyTrend: WeeklyTrend?
    private(set) var acuteLoad: Double?
    private(set) var chronicLoad: Double?
    private(set) var monotony: Double?
    private(set) var strain: Double?
    private(set) var fitnessCtl: Double?
    private(set) var fatigueAtl: Double?
    private(set) var formTsb: Double?
    private(set) var daysOfData: Int = 0
    private(set) var isLoading = false

    let displayDate: String
    private let day: String
    private let dbQueue: DatabaseQueue

    var hasSufficientData: Bool {
        acwrValue != nil
    }

    init(
        dateString: String?,
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue
    ) {
        self.day = Self.resolvedDay(dateString)
        self.displayDate = dateString ?? self.day
        self.dbQueue = dbQueue
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        let authId = AuthManager.activeAuthId?.uuidString
        do {
            let result = try await dbQueue.read { db in
                try Self.loadTrainingLoad(day: self.day, authId: authId, db: db)
            }
            acwrValue = result.acwr
            trainingZone = result.zone
            weeklyTrend = result.trend
            acuteLoad = result.acute
            chronicLoad = result.chronic
            monotony = result.monotony
            strain = result.strain
            fitnessCtl = result.fitnessCtl
            fatigueAtl = result.fatigueAtl
            formTsb = result.formTsb
            daysOfData = result.daysOfData
        } catch {
            acwrValue = nil
            daysOfData = 0
        }
    }

    // MARK: - Data Loading

    private struct LoadResult {
        var acwr: Double?
        var zone: TrainingZoneState?
        var trend: WeeklyTrend?
        var acute: Double?
        var chronic: Double?
        var monotony: Double?
        var strain: Double?
        var fitnessCtl: Double?
        var fatigueAtl: Double?
        var formTsb: Double?
        var daysOfData: Int
    }

    nonisolated private static func loadTrainingLoad(
        day: String,
        authId: String?,
        db: Database
    ) throws -> LoadResult {
        guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
            return LoadResult(daysOfData: 0)
        }

        // Count total days of training load data for cold-start gating
        let daysOfData = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(DISTINCT date)
                FROM training_loads
                WHERE (user_id = ? OR user_id = ?)
                  AND daily_trimp IS NOT NULL
                """,
            arguments: [userId, userId.uuidString]
        ) ?? 0

        // Fetch the training load record for the selected day
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT
                    acute_load_7d, chronic_load_28d, acwr,
                    training_zone, weekly_trend,
                    monotony_7d, strain_7d,
                    fitness_ctl, fatigue_atl, form_tsb
                FROM training_loads
                WHERE (user_id = ? OR user_id = ?)
                  AND date = ?
                LIMIT 1
                """,
            arguments: [userId, userId.uuidString, day]
        ) else {
            return LoadResult(daysOfData: daysOfData)
        }

        let acuteLoad: Double? = row["acute_load_7d"]
        let chronicLoad: Double? = row["chronic_load_28d"]

        // Use safe ACWR calculation with cold-start protection
        let safeAcwr = TrainingLoad.safeACWR(
            acuteLoad7d: acuteLoad,
            chronicLoad28d: chronicLoad,
            daysOfData: daysOfData
        )

        let zoneRaw: String? = row["training_zone"]
        let trendRaw: String? = row["weekly_trend"]

        return LoadResult(
            acwr: safeAcwr,
            zone: zoneRaw.flatMap(TrainingZoneState.init(rawValue:)),
            trend: trendRaw.flatMap(WeeklyTrend.init(rawValue:)),
            acute: acuteLoad,
            chronic: chronicLoad,
            monotony: row["monotony_7d"],
            strain: row["strain_7d"],
            fitnessCtl: row["fitness_ctl"],
            fatigueAtl: row["fatigue_atl"],
            formTsb: row["form_tsb"],
            daysOfData: daysOfData
        )
    }

    // MARK: - Helpers

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

#if DEBUG
    func _testOverrideState(
        acwrValue: Double? = nil,
        trainingZone: TrainingZoneState? = nil,
        weeklyTrend: WeeklyTrend? = nil,
        acuteLoad: Double? = nil,
        chronicLoad: Double? = nil,
        monotony: Double? = nil,
        strain: Double? = nil,
        fitnessCtl: Double? = nil,
        fatigueAtl: Double? = nil,
        formTsb: Double? = nil,
        daysOfData: Int = 21,
        isLoading: Bool = false
    ) {
        self.acwrValue = acwrValue
        self.trainingZone = trainingZone
        self.weeklyTrend = weeklyTrend
        self.acuteLoad = acuteLoad
        self.chronicLoad = chronicLoad
        self.monotony = monotony
        self.strain = strain
        self.fitnessCtl = fitnessCtl
        self.fatigueAtl = fatigueAtl
        self.formTsb = formTsb
        self.daysOfData = daysOfData
        self.isLoading = isLoading
    }
#endif
}

// MARK: - Test Helpers

#if DEBUG
extension ACWRDetailView {
    func _testEvaluateRatioCard() {
        _ = acwrRatioCard(acwr: 1.15)
    }

    func _testEvaluateLoadBars() {
        _ = loadBarsSection(acute: 85, chronic: 77)
    }

    func _testEvaluateTrendRow() {
        _ = weeklyTrendRow(trend: .increasing)
        _ = weeklyTrendRow(trend: .stable)
        _ = weeklyTrendRow(trend: .decreasing)
    }

    func _testEvaluateAdvancedMetrics() {
        _ = advancedMetricsSection
    }

    func _testEvaluateColdStart() {
        _ = coldStartView
    }

    func _testEvaluateDisclaimer() {
        _ = disclaimerFooter
    }

    static func _testCreateWithViewModel() -> ACWRDetailView {
        let vm = ACWRDetailViewModel(dateString: "2026-03-10")
        vm._testOverrideState(
            acwrValue: 1.15,
            trainingZone: .optimal,
            weeklyTrend: .increasing,
            acuteLoad: 85,
            chronicLoad: 77,
            monotony: 1.2,
            strain: 310,
            fitnessCtl: 72,
            fatigueAtl: 85,
            formTsb: -13,
            daysOfData: 28
        )
        return ACWRDetailView(dateString: "2026-03-10", testViewModel: vm)
    }
}

extension ACWRDetailViewModel {
    @MainActor
    static func _testResolvedDay(_ value: String?) -> String {
        resolvedDay(value)
    }

    @MainActor
    static func _testLocalDayString(for date: Date) -> String {
        localDayString(for: date)
    }

    nonisolated static func _testLoadTrainingLoadSnapshot(
        day: String,
        authId: String?,
        db: Database
    ) throws -> (
        acwr: Double?,
        zone: TrainingZoneState?,
        trend: WeeklyTrend?,
        acute: Double?,
        chronic: Double?,
        monotony: Double?,
        strain: Double?,
        fitnessCtl: Double?,
        fatigueAtl: Double?,
        formTsb: Double?,
        daysOfData: Int
    ) {
        let result = try loadTrainingLoad(day: day, authId: authId, db: db)
        return (
            acwr: result.acwr,
            zone: result.zone,
            trend: result.trend,
            acute: result.acute,
            chronic: result.chronic,
            monotony: result.monotony,
            strain: result.strain,
            fitnessCtl: result.fitnessCtl,
            fatigueAtl: result.fatigueAtl,
            formTsb: result.formTsb,
            daysOfData: result.daysOfData
        )
    }
}

enum ACWRDetailViewTestHarness {
    @MainActor
    static func loadingView() -> ACWRDetailView {
        let vm = ACWRDetailViewModel(dateString: "2026-03-10")
        vm._testOverrideState(daysOfData: 0, isLoading: true)
        return ACWRDetailView(dateString: "2026-03-10", testViewModel: vm)
    }

    @MainActor
    static func coldStartView(daysOfData: Int = 7) -> ACWRDetailView {
        let vm = ACWRDetailViewModel(dateString: "2026-03-10")
        vm._testOverrideState(daysOfData: daysOfData)
        return ACWRDetailView(dateString: "2026-03-10", testViewModel: vm)
    }

    @MainActor
    static func populatedView(
        acwrValue: Double = 1.15,
        trainingZone: TrainingZoneState = .optimal,
        weeklyTrend: WeeklyTrend = .increasing,
        acuteLoad: Double = 85,
        chronicLoad: Double = 77,
        monotony: Double = 1.2,
        strain: Double = 310,
        fitnessCtl: Double = 72,
        fatigueAtl: Double = 85,
        formTsb: Double = -13,
        daysOfData: Int = 28
    ) -> ACWRDetailView {
        let vm = ACWRDetailViewModel(dateString: "2026-03-10")
        vm._testOverrideState(
            acwrValue: acwrValue,
            trainingZone: trainingZone,
            weeklyTrend: weeklyTrend,
            acuteLoad: acuteLoad,
            chronicLoad: chronicLoad,
            monotony: monotony,
            strain: strain,
            fitnessCtl: fitnessCtl,
            fatigueAtl: fatigueAtl,
            formTsb: formTsb,
            daysOfData: daysOfData
        )
        return ACWRDetailView(dateString: "2026-03-10", testViewModel: vm)
    }

    @MainActor
    static func resolvedDay(_ value: String?) -> String {
        ACWRDetailViewModel._testResolvedDay(value)
    }

    @MainActor
    static func localDayString(for date: Date) -> String {
        ACWRDetailViewModel._testLocalDayString(for: date)
    }

    static func loadTrainingLoadSnapshot(
        day: String,
        authId: String?,
        db: Database
    ) throws -> (
        acwr: Double?,
        zone: TrainingZoneState?,
        trend: WeeklyTrend?,
        acute: Double?,
        chronic: Double?,
        monotony: Double?,
        strain: Double?,
        fitnessCtl: Double?,
        fatigueAtl: Double?,
        formTsb: Double?,
        daysOfData: Int
    ) {
        try ACWRDetailViewModel._testLoadTrainingLoadSnapshot(day: day, authId: authId, db: db)
    }

    @MainActor
    static func loadState(
        dateString: String?,
        dbQueue: DatabaseQueue
    ) async -> (
        acwr: Double?,
        zone: TrainingZoneState?,
        trend: WeeklyTrend?,
        acute: Double?,
        chronic: Double?,
        monotony: Double?,
        strain: Double?,
        fitnessCtl: Double?,
        fatigueAtl: Double?,
        formTsb: Double?,
        daysOfData: Int,
        isLoading: Bool
    ) {
        let vm = ACWRDetailViewModel(dateString: dateString, dbQueue: dbQueue)
        await vm.load()
        return (
            acwr: vm.acwrValue,
            zone: vm.trainingZone,
            trend: vm.weeklyTrend,
            acute: vm.acuteLoad,
            chronic: vm.chronicLoad,
            monotony: vm.monotony,
            strain: vm.strain,
            fitnessCtl: vm.fitnessCtl,
            fatigueAtl: vm.fatigueAtl,
            formTsb: vm.formTsb,
            daysOfData: vm.daysOfData,
            isLoading: vm.isLoading
        )
    }
}
#endif
