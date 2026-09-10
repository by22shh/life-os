import SwiftUI
import Observation
import GRDB

struct SleepDayView: View {
    @State private var selectedDate: Date
    @State private var viewModel: SleepDayViewModel
    @State private var isShowingCalendar = false
    @State private var isShowingManualEntry = false

    init(dateString: String?) {
        let initialDate = Self.initialSelectedDate(from: dateString)
        _selectedDate = State(initialValue: initialDate)
        _viewModel = State(initialValue: SleepDayViewModel(dateString: dateString, syncEngine: AppContainer.shared?.syncEngine))
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
        .toolbar {
            Button { isShowingManualEntry = true } label: { Image(systemName: "plus") }
                .accessibilityLabel(String(localized: "sleep_manual_entry", defaultValue: "Log sleep"))
                .accessibilityIdentifier("sleep.manual.add")
        }
        .sheet(isPresented: $isShowingManualEntry) {
            ManualSleepEntryView(day: selectedDate, model: viewModel)
        }
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
    private let syncEngine: SyncEngine?

    init(
        dateString: String?,
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue,
        syncEngine: SyncEngine? = nil
    ) {
        self.day = dateString ?? DiaryDateFormatter.formatDate(Date())
        self.dbQueue = dbQueue
        self.syncEngine = syncEngine
    }

    func load() async {
        await load(forDay: day)
    }

    func load(for date: Date) async {
        await load(forDay: DiaryDateFormatter.formatDate(date))
    }

    func saveManualSleep(bedTime: Date, wakeTime: Date) async throws {
        let minutes = Int(wakeTime.timeIntervalSince(bedTime) / 60)
        guard minutes > 0, minutes <= 24 * 60,
              DiaryDateFormatter.formatDate(wakeTime) == day else {
            throw NSError(domain: "SleepEntry", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "sleep_invalid_interval", defaultValue: "Choose a sleep interval up to 24 hours ending on the selected day.")])
        }
        let authId = AuthManager.activeAuthId?.uuidString
        let targetDay = day
        let engine = self.syncEngine
        let operation: @Sendable (Database) throws -> (value: Void, event: OutboxEvent) = { db in
            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                throw NSError(domain: "SleepEntry", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "auth_required")])
            }
            var log = try SleepRecordSelection.daily(userId: userId, day: targetDay, includeDeleted: true, db: db)
                ?? SleepLog(userId: userId, date: targetDay, source: .manual)
            log.source = .manual
            log.deletedAt = nil
            log.date = targetDay
            log.sleepDate = targetDay
            log.bedTime = bedTime
            log.wakeTime = wakeTime
            log.totalDurationMinutes = minutes
            log.deepSleepMinutes = nil
            log.remSleepMinutes = nil
            log.lightSleepMinutes = nil
            log.awakeMinutes = nil
            log.sleepEfficiency = nil
            log.sleepQualityScore = nil
            log.timeInBedMinutes = nil
            log.numberOfAwakenings = nil
            log.bedtimeActual = bedTime
            log.waketime = wakeTime
            log.deviceName = nil
            log.updatedAt = Date()
            log.sleepTimezone = TimeZone.current.identifier
            log.sleepUtcOffsetMinutes = TimeZone.current.secondsFromGMT(for: wakeTime) / 60
            try log.save(db)
            try SleepRecordSelection.supersedeOtherRecords(with: log, db: db)
            var state = try PhysiologicalState
                .filter((Column("user_id") == userId || Column("user_id") == userId.uuidString) && Column("date") == targetDay)
                .fetchOne(db) ?? PhysiologicalState(userId: userId, date: targetDay, recoveryScore: 50)
            SleepRecordSelection.applySleepFields(log, to: &state)
            state.updatedAt = Date()
            try state.save(db)
            let score = try RecoveryEngine.computeScore(userId: userId, date: targetDay, db: db)
            state.recoveryScore = score.score
            state.recoveryZone = RecoveryZone.from(score: score.score)
            state.confidenceScore = score.confidence
            state.sleepScore = score.components.sleepScore
            state.sleepQualityPercent = score.components.sleepScore
            state.hrvScore = score.components.hrvScore
            state.rhrScore = score.components.rhrScore
            state.tempScore = score.components.tempScore
            try state.update(db)
            var stateEvent = OutboxEvent(httpMethod: .POST, path: "rest/v1/physiological_states", bodyJson: try JSONEncoder.supabase.encode(state), priority: 90)
            stateEvent.headersJson = try JSONSerialization.data(withJSONObject: ["Prefer": "resolution=merge-duplicates"])
            if let engine { try engine.enqueueMutation(stateEvent, in: db) }
            else { try stateEvent.insert(db) }
            let event = try SleepRecordSelection.outboxEvent(for: log)
            return ((), event)
        }
        if let engine {
            try await engine.performOptimisticMutation(operation)
        } else {
            try await dbQueue.write { db in try operation(db).event.insert(db) }
        }
        await load()
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


private struct ManualSleepEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var bedTime: Date
    @State private var wakeTime: Date
    @State private var saving = false
    @State private var errorMessage: String?
    let model: SleepDayViewModel

    init(day: Date, model: SleepDayViewModel) {
        let morning = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: day) ?? day
        _wakeTime = State(initialValue: morning)
        _bedTime = State(initialValue: morning.addingTimeInterval(-8 * 3600))
        self.model = model
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(String(localized: "sleep_bed_time", defaultValue: "Fell asleep"), selection: $bedTime)
                DatePicker(String(localized: "sleep_wake_time", defaultValue: "Woke up"), selection: $wakeTime)
                Text(String(localized: "sleep_manual_duration_note", defaultValue: "Enter your estimated time asleep. Sleep stages are left unknown."))
                    .font(.caption).foregroundStyle(.secondary)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle(String(localized: "sleep_manual_entry", defaultValue: "Log sleep"))
            .accessibilityIdentifier("sleep.manual.form")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "save")) {
                        saving = true
                        Task {
                            defer { saving = false }
                            do {
                                try await model.saveManualSleep(bedTime: bedTime, wakeTime: wakeTime)
                                dismiss()
                            } catch { errorMessage = error.localizedDescription }
                        }
                    }.disabled(saving)
                        .accessibilityIdentifier("sleep.manual.save")
                }
            }
        }
    }
}
