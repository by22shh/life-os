import SwiftUI
import Observation
import GRDB

struct SleepDayView: View {
    @State private var selectedDate: Date
    @State private var viewModel: SleepDayViewModel
    @State private var isShowingCalendar = false

    init(dateString: String?) {
        let initialDate = Self.initialSelectedDate(from: dateString)
        _selectedDate = State(initialValue: initialDate)
        _viewModel = State(initialValue: SleepDayViewModel(dateString: dateString))
    }

#if DEBUG
    fileprivate init(dateString: String?, testViewModel: SleepDayViewModel) {
        _selectedDate = State(initialValue: Self.initialSelectedDate(from: dateString))
        _viewModel = State(initialValue: testViewModel)
    }
#endif

    var body: some View {
        let snapshot = viewModel.snapshot ?? Self.placeholderSnapshot(for: selectedDate)

        ScrollView {
            VStack(spacing: Spacing.m) {
                dateNavigationHeader

                if viewModel.isLoading && viewModel.snapshot == nil && viewModel.summary == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, Spacing.s)
                }

                SleepDetailSections(
                    snapshot: snapshot,
                    permissionState: viewModel.permissionState,
                    isRequestingAccess: viewModel.isRequestingHealthAccess,
                    statusMessage: viewModel.statusMessage,
                    onRequestAccess: viewModel.permissionState.canRequestAccess ? {
                        Task { await viewModel.requestHealthKitAccess() }
                    } : nil
                )

                if viewModel.snapshot == nil, let summary = viewModel.summary {
                    legacySummaryCard(summary)
                }
            }
            .padding(LayoutConstants.contentPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LifeOSColors.Surface.background)
        .accessibilityIdentifier("sleep.day.screen")
        .navigationTitle(String(localized: "sleep_title"))
        .sheet(isPresented: $isShowingCalendar) {
            SleepCalendarView(selectedDate: $selectedDate)
        }
        .task(id: selectedDate) {
            await viewModel.load(for: selectedDate)
        }
    }

    private var dateNavigationHeader: some View {
        HStack {
            Button {
                selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: LayoutConstants.minTouchTarget, height: LayoutConstants.minTouchTarget)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                isShowingCalendar = true
            } label: {
                VStack(spacing: Spacing.xxs) {
                    Label(String(localized: "sleep_title"), systemImage: "bed.double")
                        .font(LifeOSTypography.title3)
                    Text(selectedDate.formatted(.dateTime.month().day().weekday(.wide)))
                        .font(LifeOSTypography.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: LayoutConstants.minTouchTarget, height: LayoutConstants.minTouchTarget)
            }
            .buttonStyle(.plain)
        }
    }

    private func legacySummaryCard(_ summary: SleepSummary) -> some View {
        VStack(spacing: Spacing.xs) {
            Text(summary.primaryText)
                .font(LifeOSTypography.body)
            if let secondaryText = summary.secondaryText {
                Text(secondaryText)
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary.accessibilitySummary)
    }

    private static func initialSelectedDate(from dateString: String?) -> Date {
        DiaryDateFormatter.parseDate(dateString) ?? Date()
    }

    private static func placeholderSnapshot(for date: Date) -> SleepDetailSnapshot {
        let day = DiaryDateFormatter.formatDate(date)
        return SleepDetailSnapshot(
            day: day,
            displayDate: date.formatted(.dateTime.weekday(.wide).month(.wide).day()),
            age: 30,
            baselineSleepHours: nil,
            sleepLog: nil,
            state: nil,
            score: nil,
            confidenceScore: nil,
            trendPoints: [],
            factors: [],
            tryTonightItems: [],
            stageFeedback: nil
        )
    }
}

@MainActor
@Observable
final class SleepDayViewModel {
    private(set) var snapshot: SleepDetailSnapshot?
    fileprivate var summary: SleepSummary?
    private(set) var permissionState: SleepPermissionState = .unavailable
    private(set) var isLoading = false
    private(set) var isRequestingHealthAccess = false
    var statusMessage: String?

    private var day: String
    private let dbQueue: DatabaseQueue

    init(
        dateString: String?,
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue
    ) {
        self.day = dateString ?? DiaryDateFormatter.formatDate(Date())
        self.dbQueue = dbQueue
    }

    func load() async {
        await load(forDay: day)
    }

    func load(for date: Date) async {
        await load(forDay: DiaryDateFormatter.formatDate(date))
    }

    func requestHealthKitAccess() async {
        isRequestingHealthAccess = true
        defer { isRequestingHealthAccess = false }

        do {
            try await SleepHealthKitAccessCoordinator.requestAccessAndBackfill(dbQueue: dbQueue)
            statusMessage = NSLocalizedString(
                "sleep.access_updated",
                value: "Sleep access updated. Recent data is syncing now.",
                comment: "Sleep detail success message after HealthKit access is updated"
            )
        } catch {
            statusMessage = error.localizedDescription
        }

        permissionState = SleepHealthKitAccessCoordinator.currentPermissionState()
        await load(forDay: day)
    }

    private func load(forDay day: String) async {
        self.day = day
        isLoading = true
        permissionState = SleepHealthKitAccessCoordinator.currentPermissionState()
        statusMessage = nil
        defer { isLoading = false }

        do {
            let snapshot = try await SleepDetailLoader.load(day: day, dbQueue: dbQueue)
            self.snapshot = snapshot
            summary = SleepSummary(snapshot: snapshot)
        } catch {
            snapshot = nil
            summary = nil
            statusMessage = error.localizedDescription
        }
    }

#if DEBUG
    fileprivate func _testOverrideState(summary: SleepSummary?, isLoading: Bool) {
        self.summary = summary
        self.snapshot = nil
        self.isLoading = isLoading
    }
#endif
}

struct SleepSummary {
    let primaryText: String
    let secondaryText: String?
    let accessibilitySummary: String
#if DEBUG
    private static let testDurationFormatterOverride = LockedTestOverride<(Int) -> String?>()
#endif

    init?(snapshot: SleepDetailSnapshot) {
        guard snapshot.hasAnySleepData else { return nil }
        let durationPrimaryText: String
        if let durationMinutes = snapshot.durationMinutes, durationMinutes > 0 {
            durationPrimaryText = Self.resolvedPrimaryText(durationMinutes: durationMinutes)
        } else {
            durationPrimaryText = String(localized: "sleep_title")
        }

        primaryText = durationPrimaryText
        secondaryText = snapshot.sleepEfficiency.map { "\(Int($0.rounded()))%" }
        accessibilitySummary = [primaryText, secondaryText].compactMap { $0 }.joined(separator: ", ")
    }

    init(row: Row) {
        let durationMinutes: Int? = row["total_duration_minutes"]
        let efficiency: Double? = row["sleep_efficiency"]

        if let durationMinutes, durationMinutes > 0 {
            primaryText = Self.resolvedPrimaryText(durationMinutes: durationMinutes)
        } else {
            primaryText = String(localized: "sleep_title")
        }

        if let efficiency {
            secondaryText = "\(Int(efficiency.rounded()))%"
        } else {
            secondaryText = nil
        }

        accessibilitySummary = [primaryText, secondaryText].compactMap { $0 }.joined(separator: ", ")
    }

    private static func resolvedPrimaryText(durationMinutes: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = durationMinutes >= 60 ? [.hour, .minute] : [.minute]
#if DEBUG
        let formatted: String?
        if let override = testDurationFormatterOverride.value {
            formatted = override(durationMinutes)
        } else {
            formatted = formatter.string(from: TimeInterval(durationMinutes * 60))
        }
#else
        let formatted = formatter.string(from: TimeInterval(durationMinutes * 60))
#endif
        if let formatted {
            return formatted
        }
        return String(localized: "sleep_title")
    }
}

#if DEBUG
private extension SleepSummary {
    init(testPrimaryText: String, testSecondaryText: String?) {
        primaryText = testPrimaryText
        secondaryText = testSecondaryText
        accessibilitySummary = [testPrimaryText, testSecondaryText].compactMap { $0 }.joined(separator: ", ")
    }

    static func _testSetDurationFormatterOverride(_ override: ((Int) -> String?)?) {
        testDurationFormatterOverride.value = override
    }

    static func _testResolvedPrimaryText(durationMinutes: Int) -> String {
        resolvedPrimaryText(durationMinutes: durationMinutes)
    }
}

@MainActor
enum SleepDayViewTestHarness {
    static func exerciseBodyBranches() {
        let loadingVM = SleepDayViewModel(dateString: "2026-02-24")
        loadingVM._testOverrideState(summary: nil, isLoading: true)
        _ = SleepDayView(dateString: "2026-02-24", testViewModel: loadingVM).body

        let emptyVM = SleepDayViewModel(dateString: "2026-02-24")
        emptyVM._testOverrideState(summary: nil, isLoading: false)
        _ = SleepDayView(dateString: "2026-02-24", testViewModel: emptyVM).body

        let loadedVM = SleepDayViewModel(dateString: "2026-02-24")
        loadedVM._testOverrideState(
            summary: SleepSummary(testPrimaryText: "8 hours", testSecondaryText: "92%"),
            isLoading: false
        )
        _ = SleepDayView(dateString: "2026-02-24", testViewModel: loadedVM).body
    }

    static func loadSummary(
        dateString: String?,
        dbQueue: DatabaseQueue
    ) async -> String? {
        let viewModel = SleepDayViewModel(dateString: dateString, dbQueue: dbQueue)
        await viewModel.load()
        return viewModel.summary?.accessibilitySummary
    }

    static func runLoadTask(
        dateString: String?,
        dbQueue: DatabaseQueue
    ) async -> Bool {
        let viewModel = SleepDayViewModel(dateString: dateString, dbQueue: dbQueue)
        let view = SleepDayView(dateString: dateString, testViewModel: viewModel)
        await view._testRunLoadTask()
        return !viewModel.isLoading
    }

    static func runLoadTaskAction(
        dateString: String?,
        dbQueue: DatabaseQueue
    ) async -> Bool {
        let viewModel = SleepDayViewModel(dateString: dateString, dbQueue: dbQueue)
        let view = SleepDayView(dateString: dateString, testViewModel: viewModel)
        await view._testRunLoadTaskAction()
        return !viewModel.isLoading
    }

    static func setDurationFormatterOverride(_ override: ((Int) -> String?)?) {
        SleepSummary._testSetDurationFormatterOverride(override)
    }

    static func resolvedPrimaryText(durationMinutes: Int) -> String {
        SleepSummary._testResolvedPrimaryText(durationMinutes: durationMinutes)
    }
}

private extension SleepDayView {
    func _testRunLoadTask() async {
        await viewModel.load()
    }

    func _testRunLoadTaskAction() async {
        await viewModel.load(for: selectedDate)
    }
}
#endif
