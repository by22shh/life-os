import SwiftUI
import Observation
import GRDB
import OSLog

private let supplementsDayLogger = Logger(subsystem: "LifeOS", category: "SupplementsDay")

enum SupplementsLaunchContext: Equatable {
    case day
    case log
}

struct SupplementsDayView: View {
    let dateString: String?
    let launchContext: SupplementsLaunchContext
    @State private var viewModel: SupplementsDayViewModel
    @State private var showsQuickLogSheet = false
    @State private var shouldReopenQuickLogAfterAdd = false
    @State private var hasPresentedInitialQuickLog = false
    @State private var pendingAddSupplementFromQuickLog = false
    @State private var editingSupplement: UserStackItem?

    init(dateString: String?, launchContext: SupplementsLaunchContext = .day) {
        self.dateString = dateString
        self.launchContext = launchContext
        _viewModel = State(initialValue: SupplementsDayViewModel(dateString: dateString))
    }

#if DEBUG
    fileprivate init(
        dateString: String?,
        launchContext: SupplementsLaunchContext = .day,
        testViewModel: SupplementsDayViewModel
    ) {
        self.dateString = dateString
        self.launchContext = launchContext
        _viewModel = State(initialValue: testViewModel)
    }
#endif

    var body: some View {
        @Bindable var viewModel = viewModel

        ScrollView {
            VStack(spacing: Spacing.m) {
                // Header
                Label(String(localized: "supplements"), systemImage: "pill")
                    .font(LifeOSTypography.title3)

                Text(viewModel.displayDate)
                    .font(LifeOSTypography.subheadline)
                    .foregroundStyle(.secondary)

                // Scheduled Supplements (One-Tap Taken)
                if !viewModel.scheduledSupplements.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(scheduledSectionTitle)
                            .font(LifeOSTypography.subheadline.weight(.semibold))
                            .padding(.horizontal, LayoutConstants.contentPadding)

                        ForEach(viewModel.scheduledSupplements) { scheduled in
                            scheduledRow(scheduled)
                        }
                    }
                }

                // Taken Today
                if viewModel.isLoading {
                    ProgressView()
                } else if viewModel.logs.isEmpty && viewModel.scheduledSupplements.isEmpty {
                    Text(String(localized: "no_supplements_taken"))
                        .font(LifeOSTypography.body)
                        .foregroundStyle(.secondary)
                } else if !viewModel.logs.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(takenSectionTitle)
                            .font(LifeOSTypography.subheadline.weight(.semibold))
                            .padding(.horizontal, LayoutConstants.contentPadding)

                        LazyVStack(spacing: Spacing.s) {
                            ForEach(viewModel.logs, content: logRow)
                        }
                    }
                }

                // Month Grid
                monthGridSection

                // Manage Stack
                manageStackSection
            }
            .padding(.top, Spacing.m)
        }
        .accessibilityIdentifier("supplements.day.screen")
        .background(LifeOSColors.Surface.background)
        .navigationTitle(String(localized: "supplements"))
        .task(runLoadTaskAction)
        .sheet(isPresented: $viewModel.showsAddSupplement) {
            AddSupplementView(
                onSave: {
                    Task {
                        await viewModel.load()
                        await MainActor.run {
                            guard shouldReopenQuickLogAfterAdd else { return }
                            shouldReopenQuickLogAfterAdd = false
                            showsQuickLogSheet = true
                        }
                    }
                },
                onCancel: {
                    shouldReopenQuickLogAfterAdd = false
                }
            )
        }
        .sheet(item: $editingSupplement) { supplement in
            AddSupplementView(
                editing: supplement,
                onSave: { Task { await viewModel.load() } }
            )
        }
        .sheet(isPresented: $showsQuickLogSheet) {
            SupplementQuickLogSheet(
                scheduledSectionTitle: scheduledSectionTitle,
                scheduledItems: viewModel.pendingScheduledSupplements,
                stackItems: viewModel.quickLogStackItems,
                onMarkScheduled: handleQuickLogScheduledSelection(_:),
                onLogFromStack: handleQuickLogStackSelection(_:),
                onAddSupplement: handleQuickLogAddSupplement
            )
        }
        .onChange(of: showsQuickLogSheet) { _, isPresented in
            handleQuickLogSheetPresentationChange(isPresented)
        }
    }

    private var scheduledSectionTitle: String {
        if viewModel.isViewingToday {
            return String(localized: "supplements_scheduled_today")
        }
        return String.localizedStringWithFormat(
            String(localized: "supplements_log_scheduled_for_date_format"),
            viewModel.displayDate
        )
    }

    private var takenSectionTitle: String {
        if viewModel.isViewingToday {
            return String(localized: "supplements_taken_today")
        }
        return String.localizedStringWithFormat(
            String(localized: "supplements_taken_for_date_format"),
            viewModel.displayDate
        )
    }

    private func scheduledRow(_ item: ScheduledSupplement) -> some View {
        HStack(spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(item.name)
                    .font(LifeOSTypography.body)
                HStack(spacing: Spacing.xxs) {
                    if let time = item.scheduledTime {
                        Text(time)
                            .font(LifeOSTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let dose = item.dose {
                        Text("• \(dose)")
                            .font(LifeOSTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if item.isTaken {
                HStack(spacing: Spacing.xxs) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(String(localized: "supplements_taken_label"))
                        .font(LifeOSTypography.caption.weight(.semibold))
                }
                .foregroundStyle(LifeOSColors.Recovery.ready)
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, Spacing.xxs)
                .background(LifeOSColors.Recovery.ready.opacity(0.12))
                .clipShape(Capsule())
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(localized: "supplements_taken_label"))
                .accessibilityIdentifier("supplements.taken.badge.\(item.name)")
            } else {
                Button {
                    Task { await viewModel.markTaken(item) }
                } label: {
                    Text(String(localized: "supplements_mark_taken"))
                        .font(LifeOSTypography.caption.weight(.semibold))
                        .padding(.horizontal, Spacing.s)
                        .padding(.vertical, Spacing.xxs)
                }
                .buttonStyle(.borderedProminent)
                .tint(LifeOSColors.Semantic.primary)
                .accessibilityLabel(String(format: String(localized: "supplements_mark_taken_format"), item.name))
                .accessibilityIdentifier("supplements.mark_taken.\(item.name)")
            }
        }
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
        .padding(.horizontal, LayoutConstants.contentPadding)
    }

    // MARK: - Month Grid

    private var monthGridSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(String(localized: "supplements_month_overview"))
                .font(LifeOSTypography.subheadline.weight(.semibold))
                .padding(.horizontal, LayoutConstants.contentPadding)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(viewModel.monthDays, id: \.date) { dayEntry in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(dayEntry.adherenceColor)
                        .frame(height: 28)
                        .overlay {
                            Text("\(dayEntry.dayNumber)")
                                .font(LifeOSTypography.caption2)
                                .foregroundStyle(dayEntry.isToday ? .white : .primary)
                        }
                        .accessibilityLabel("\(dayEntry.dayNumber), \(dayEntry.adherenceLabel)")
                }
            }
            .padding(.horizontal, LayoutConstants.contentPadding)
        }
    }

    // MARK: - Manage Stack

    private var manageStackSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(String(localized: "supplements_my_stack"))
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                Spacer()
                Button {
                    viewModel.showsAddSupplement = true
                } label: {
                    Label(String(localized: "supplements_add"), systemImage: "plus")
                        .font(LifeOSTypography.caption.weight(.semibold))
                }
            }
            .padding(.horizontal, LayoutConstants.contentPadding)

            ForEach(viewModel.userStack) { supplement in
                stackRow(supplement)
            }
        }
    }

    private func stackRow(_ supplement: UserStackItem) -> some View {
        HStack(spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(supplement.name)
                    .font(LifeOSTypography.body)
                    .foregroundStyle(supplement.isActive ? .primary : .secondary)
                Text(supplement.schedule)
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(supplement.isActive ? .secondary : .tertiary)
            }
            Spacer()
            if viewModel.isUpdatingSupplement(supplement.id) {
                ProgressView()
                    .controlSize(.small)
            }
            Toggle("", isOn: Binding(
                get: { supplement.isActive },
                set: { isActive in
                    guard isActive != supplement.isActive else { return }
                    Task { await viewModel.setSupplementActive(supplement.id, isActive: isActive) }
                }
            ))
                .labelsHidden()
                .tint(LifeOSColors.Semantic.primary)
                .disabled(viewModel.isUpdatingSupplement(supplement.id))
            Button {
                editingSupplement = supplement
            } label: {
                Image(systemName: "pencil")
                    .frame(width: LayoutConstants.minTouchTarget, height: LayoutConstants.minTouchTarget)
            }
            .accessibilityLabel(String(localized: "edit"))
            .accessibilityIdentifier("supplements.edit.\(supplement.id.uuidString)")
        }
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
        .opacity(supplement.isActive ? 1 : 0.72)
        .padding(.horizontal, LayoutConstants.contentPadding)
    }

    private func logRow(_ log: SupplementLogSummary) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "pill.fill")
                .foregroundStyle(LifeOSColors.Semantic.primary)
                .frame(width: LayoutConstants.minTouchTarget, height: LayoutConstants.minTouchTarget)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(log.name)
                    .font(LifeOSTypography.body)
                if let details = log.details {
                    Text(details)
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(role: .destructive) {
                Task { await viewModel.undoTakenLog(log) }
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: LayoutConstants.minTouchTarget, height: LayoutConstants.minTouchTarget)
            }
            .accessibilityLabel(String(localized: "undo"))
            .accessibilityIdentifier("supplements.undo_taken.\(log.id.uuidString)")
        }
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(log.accessibilitySummary)
        .accessibilityIdentifier("supplements.log.row.\(log.name)")
    }

    private func runLoadTask(_ viewModel: SupplementsDayViewModel) async {
        await viewModel.load()
    }

    private func runLoadTaskAction() async {
        await runLoadTask(viewModel)
        guard launchContext == .log, !hasPresentedInitialQuickLog else {
            return
        }
        await MainActor.run {
            hasPresentedInitialQuickLog = true
            showsQuickLogSheet = true
        }
    }

    private func handleQuickLogScheduledSelection(_ item: ScheduledSupplement) async {
        await viewModel.markTaken(item)
    }

    private func handleQuickLogStackSelection(_ item: UserStackItem) async {
        await viewModel.logSupplementNow(item)
    }

    private func handleQuickLogAddSupplement() {
        shouldReopenQuickLogAfterAdd = true
        pendingAddSupplementFromQuickLog = true
        showsQuickLogSheet = false
    }

    private func handleQuickLogSheetPresentationChange(_ isPresented: Bool) {
        guard !isPresented, pendingAddSupplementFromQuickLog else {
            return
        }
        pendingAddSupplementFromQuickLog = false
        viewModel.showsAddSupplement = true
    }
}

private struct SupplementQuickLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var activeActionId: String?

    let scheduledSectionTitle: String
    let scheduledItems: [ScheduledSupplement]
    let stackItems: [UserStackItem]
    let onMarkScheduled: (ScheduledSupplement) async -> Void
    let onLogFromStack: (UserStackItem) async -> Void
    let onAddSupplement: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if !scheduledItems.isEmpty {
                    Section(scheduledSectionTitle) {
                        ForEach(scheduledItems) { item in
                            Button {
                                Task { await handleScheduledSelection(item) }
                            } label: {
                                quickLogRow(
                                    title: item.name,
                                    subtitle: [item.scheduledTime, item.dose].compactMap { $0 }.joined(separator: " • "),
                                    buttonTitle: String(localized: "supplements_mark_taken"),
                                    isLoading: activeActionId == scheduledActionIdentifier(for: item)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(activeActionId != nil)
                            .accessibilityIdentifier("supplements.quick_log.scheduled.\(item.id)")
                        }
                    }
                }

                if !stackItems.isEmpty {
                    Section(String(localized: "supplements_log_stack_section")) {
                        ForEach(stackItems) { item in
                            Button {
                                Task { await handleStackSelection(item) }
                            } label: {
                                quickLogRow(
                                    title: item.name,
                                    subtitle: item.schedule,
                                    buttonTitle: String(localized: "supplements_log_now"),
                                    isLoading: activeActionId == stackActionIdentifier(for: item)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(activeActionId != nil)
                            .accessibilityIdentifier("supplements.quick_log.stack.\(item.id.uuidString)")
                        }
                    }
                }

                if scheduledItems.isEmpty && stackItems.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: Spacing.s) {
                            Text(String(localized: "supplements_log_empty_title"))
                                .font(LifeOSTypography.body.weight(.semibold))

                            Text(String(localized: "supplements_log_empty_message"))
                                .font(LifeOSTypography.footnote)
                                .foregroundStyle(.secondary)

                            Button(String(localized: "supplements_add")) {
                                onAddSupplement()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Spacing.xxs)
                        .accessibilityIdentifier("supplements.quick_log.empty")
                    }
                }
            }
            .navigationTitle(String(localized: "supplements_log_title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) { dismiss() }
                        .disabled(activeActionId != nil)
                }
            }
        }
        .accessibilityIdentifier("supplements.quick_log.sheet")
    }

    private func quickLogRow(
        title: String,
        subtitle: String,
        buttonTitle: String,
        isLoading: Bool
    ) -> some View {
        HStack(spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(LifeOSTypography.body.weight(.semibold))
                    .foregroundStyle(.primary)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: Spacing.s)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(buttonTitle)
                    .font(LifeOSTypography.caption.weight(.semibold))
                    .foregroundStyle(LifeOSColors.Semantic.primary)
            }
        }
        .padding(.vertical, Spacing.xxs)
    }

    private func handleScheduledSelection(_ item: ScheduledSupplement) async {
        activeActionId = scheduledActionIdentifier(for: item)
        await onMarkScheduled(item)
        dismiss()
    }

    private func handleStackSelection(_ item: UserStackItem) async {
        activeActionId = stackActionIdentifier(for: item)
        await onLogFromStack(item)
        dismiss()
    }

    private func scheduledActionIdentifier(for item: ScheduledSupplement) -> String {
        "scheduled:\(item.id)"
    }

    private func stackActionIdentifier(for item: UserStackItem) -> String {
        "stack:\(item.id.uuidString)"
    }
}

@MainActor
@Observable
private final class SupplementsDayViewModel {
    private(set) var logs: [SupplementLogSummary] = []
    private(set) var isLoading = false
    var scheduledSupplements: [ScheduledSupplement] = []
    var monthDays: [SupplementMonthDay] = []
    var userStack: [UserStackItem] = []
    private(set) var updatingSupplementIds: Set<UUID> = []
    var showsAddSupplement = false

    let displayDate: String
    private let day: String
    private let dbQueue: DatabaseQueue
    private let timeZoneHistoryStore: TimeZoneHistoryStore

    init(
        dateString: String?,
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue,
        timeZoneHistoryStore: TimeZoneHistoryStore? = nil
    ) {
        self.day = SupplementsDayViewModel.resolvedDay(dateString)
        self.displayDate = dateString ?? self.day
        self.dbQueue = dbQueue
        self.timeZoneHistoryStore = timeZoneHistoryStore ?? TimeZoneHistoryStore(dbQueue: dbQueue)
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let authId = AuthManager.activeAuthId?.uuidString
            let currentDay = day

            let result = try await dbQueue.read { db -> (
                logs: [SupplementLogSummary],
                scheduled: [ScheduledSupplement],
                stack: [UserStackItem],
                monthDays: [SupplementMonthDay]
            ) in
                guard let userId = try Self.resolveUserId(authId: authId, db: db) else {
                    return ([], [], [], [])
                }

                // Logs for today
                let logRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, supplement_name, dose_amount, dose_unit, taken_at
                        FROM supplement_logs
                        WHERE (user_id = ? OR user_id = ?)
                          AND taken_date = ?
                          AND deleted_at IS NULL
                        ORDER BY taken_at DESC
                        """,
                    arguments: [userId, userId.uuidString, currentDay]
                )
                let fetchedLogs = logRows.compactMap(SupplementLogSummary.init(row:))

                let scheduledTakenRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT user_supplement_id, scheduled_time
                        FROM supplement_logs
                        WHERE (user_id = ? OR user_id = ?)
                          AND taken_date = ?
                          AND was_scheduled = 1
                          AND deleted_at IS NULL
                        """,
                    arguments: [userId, userId.uuidString, currentDay]
                )

                var scheduledTakenLookup: Set<String> = []
                for row in scheduledTakenRows {
                    guard let supplementId = MixedUUIDStorage.decode(from: row, column: "user_supplement_id") else {
                        continue
                    }
                    let scheduledTime: String? = row["scheduled_time"]
                    scheduledTakenLookup.insert(
                        Self.scheduledLookupKey(
                            userSupplementId: supplementId,
                            scheduledTime: scheduledTime
                        )
                    )
                }

                // Active user supplements (stack)
                let stackRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT
                            user_supplements.id,
                            user_supplements.user_id,
                            user_supplements.catalog_id,
                            user_supplements.custom_name,
                            supplement_catalog.name AS catalog_name,
                            user_supplements.dose_amount,
                            user_supplements.dose_unit,
                            user_supplements.frequency,
                            user_supplements.scheduled_times,
                            user_supplements.days_of_week,
                            user_supplements.take_with_food,
                            user_supplements.notes,
                            user_supplements.started_at,
                            user_supplements.ended_at,
                            user_supplements.created_at,
                            user_supplements.updated_at,
                            user_supplements.active
                        FROM user_supplements
                        LEFT JOIN supplement_catalog
                          ON supplement_catalog.id = user_supplements.catalog_id
                        WHERE (user_id = ? OR user_id = ?)
                        ORDER BY user_supplements.active DESC,
                                 COALESCE(user_supplements.custom_name, supplement_catalog.name, 'Supplement') ASC
                        """,
                    arguments: [userId, userId.uuidString]
                )

                var fetchedStack: [UserStackItem] = []
                var fetchedScheduled: [ScheduledSupplement] = []
                var scheduleDefinitions: [SupplementScheduleDefinition] = []

                for row in stackRows {
                    guard let supId = MixedUUIDStorage.decode(from: row, column: "id") else { continue }
                    let name: String = row["custom_name"] ?? row["catalog_name"] ?? "Supplement"
                    let freq: String = row["frequency"] ?? "daily"
                    let isActive: Bool = row["active"] ?? true
                    let doseAmt: Double? = row["dose_amount"]
                    let doseUnitVal: String? = row["dose_unit"]
                    let timesJson: String? = row["scheduled_times"]
                    let daysJson: String? = row["days_of_week"]
                    let startedAt: String = row["started_at"] ?? currentDay
                    let endedAt: String? = row["ended_at"]

                    let scheduleLabel: String
                    switch freq {
                    case "daily": scheduleLabel = String(localized: "supplements_freq_daily")
                    case "twice_daily": scheduleLabel = String(localized: "supplements_freq_twice_daily")
                    case "weekly": scheduleLabel = String(localized: "supplements_freq_weekly")
                    default: scheduleLabel = String(localized: "supplements_freq_as_needed")
                    }

                    fetchedStack.append(UserStackItem(
                        id: supId,
                        name: name,
                        schedule: scheduleLabel,
                        isActive: isActive,
                        doseAmount: doseAmt,
                        doseUnit: doseUnitVal ?? "mg",
                        frequency: freq,
                        scheduledTimes: Self.decodeStringArray(timesJson),
                        daysOfWeek: Self.decodeIntArray(daysJson),
                        startedAt: startedAt,
                        endedAt: endedAt,
                        createdAt: Self.decodeDate(from: row, column: "created_at") ?? Date()
                    ))

                    guard isActive else {
                        continue
                    }

                    let times = Self.decodeStringArray(timesJson)
                    let definition = SupplementScheduleDefinition(
                        id: supId,
                        frequency: freq,
                        scheduledTimes: times,
                        daysOfWeek: Self.decodeIntArray(daysJson),
                        startedAt: startedAt,
                        endedAt: endedAt
                    )
                    scheduleDefinitions.append(definition)
                    guard Self.isScheduled(definition, on: currentDay) else {
                        continue
                    }

                    // Build scheduled items for today
                    let doseStr: String? = {
                        guard let amt = doseAmt, let unit = doseUnitVal, !unit.isEmpty else { return nil }
                        return "\(amt) \(unit)"
                    }()

                    if times.isEmpty {
                        // Single entry with no specific time
                        fetchedScheduled.append(ScheduledSupplement(
                            id: "\(supId.uuidString)|unscheduled",
                            userSupplementId: supId,
                            name: name,
                            scheduledTime: nil,
                            dose: doseStr,
                            isTaken: scheduledTakenLookup.contains(
                                Self.scheduledLookupKey(
                                    userSupplementId: supId,
                                    scheduledTime: nil
                                )
                            )
                        ))
                    } else {
                        for (index, time) in times.enumerated() {
                            fetchedScheduled.append(ScheduledSupplement(
                                id: "\(supId.uuidString)|\(index)|\(time)",
                                userSupplementId: supId,
                                name: name,
                                scheduledTime: time,
                                dose: doseStr,
                                isTaken: scheduledTakenLookup.contains(
                                    Self.scheduledLookupKey(
                                        userSupplementId: supId,
                                        scheduledTime: time
                                    )
                                )
                            ))
                        }
                    }
                }

                fetchedScheduled.sort { lhs, rhs in
                    switch (lhs.scheduledTime, rhs.scheduledTime) {
                    case let (left?, right?):
                        if left != right {
                            return left < right
                        }
                    case (.some, .none):
                        return true
                    case (.none, .some):
                        return false
                    case (.none, .none):
                        break
                    }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }

                // Month grid data
                let calendar = Calendar.current
                let dateFormatter = DateFormatter()
                dateFormatter.calendar = Calendar(identifier: .gregorian)
                dateFormatter.locale = Locale(identifier: "en_US_POSIX")
                dateFormatter.timeZone = TimeZone.current
                dateFormatter.dateFormat = "yyyy-MM-dd"

                guard let currentDate = dateFormatter.date(from: currentDay) else {
                    return (fetchedLogs, fetchedScheduled, fetchedStack, [])
                }

                let monthRange = calendar.range(of: .day, in: .month, for: currentDate) ?? 1..<2
                let comps = calendar.dateComponents([.year, .month], from: currentDate)

                var fetchedMonthDays: [SupplementMonthDay] = []
                for dayNum in monthRange {
                    var dayComps = comps
                    dayComps.day = dayNum
                    guard let dayDate = calendar.date(from: dayComps) else { continue }
                    let dayStr = dateFormatter.string(from: dayDate)
                    let isToday = dayStr == currentDay

                    let dueDefinitions = scheduleDefinitions.filter { Self.isScheduled($0, on: dayStr) }
                    let expectedLookupKeys = Set(dueDefinitions.flatMap { definition in
                        let times = definition.scheduledTimes.isEmpty ? [nil] : definition.scheduledTimes.map(Optional.some)
                        return times.map {
                            Self.scheduledLookupKey(userSupplementId: definition.id, scheduledTime: $0)
                        }
                    })
                    let scheduledTakenRows = try Row.fetchAll(
                        db,
                        sql: """
                            SELECT user_supplement_id, scheduled_time FROM supplement_logs
                            WHERE (user_id = ? OR user_id = ?)
                              AND taken_date = ?
                              AND was_scheduled = 1
                              AND deleted_at IS NULL
                            """,
                        arguments: [userId, userId.uuidString, dayStr]
                    )
                    let takenLookupKeys = Set(scheduledTakenRows.compactMap { row -> String? in
                        guard let supplementId = MixedUUIDStorage.decode(from: row, column: "user_supplement_id") else {
                            return nil
                        }
                        let scheduledTime: String? = row["scheduled_time"]
                        return Self.scheduledLookupKey(userSupplementId: supplementId, scheduledTime: scheduledTime)
                    })

                    fetchedMonthDays.append(SupplementMonthDay(
                        date: dayStr,
                        dayNumber: dayNum,
                        isToday: isToday,
                        takenCount: takenLookupKeys.intersection(expectedLookupKeys).count,
                        totalCount: expectedLookupKeys.count
                    ))
                }

                return (fetchedLogs, fetchedScheduled, fetchedStack, fetchedMonthDays)
            }

            logs = result.logs
            scheduledSupplements = result.scheduled
            userStack = result.stack
            monthDays = result.monthDays
        } catch {
            #if DEBUG
            supplementsDayLogger.debug("SupplementsDayViewModel.load failed: \(error.localizedDescription, privacy: .private)")
            #endif
        }
    }

    func isUpdatingSupplement(_ id: UUID) -> Bool {
        updatingSupplementIds.contains(id)
    }

    var isViewingToday: Bool {
        day == Self.localDayString(for: Date())
    }

    var pendingScheduledSupplements: [ScheduledSupplement] {
        scheduledSupplements.filter { !$0.isTaken }
    }

    var quickLogStackItems: [UserStackItem] {
        let pendingScheduledIds = Set(pendingScheduledSupplements.map(\.userSupplementId))
        return userStack.filter { $0.isActive && !pendingScheduledIds.contains($0.id) }
    }

    func setSupplementActive(_ id: UUID, isActive: Bool) async {
        guard let currentItem = userStack.first(where: { $0.id == id }),
              currentItem.isActive != isActive,
              !updatingSupplementIds.contains(id) else {
            return
        }

        updatingSupplementIds.insert(id)
        applySupplementActiveState(for: id, isActive: isActive)
        defer { updatingSupplementIds.remove(id) }

        do {
            let authId = AuthManager.activeAuthId?.uuidString

            try await dbQueue.write { db in
                guard let userId = try Self.resolveUserId(authId: authId, db: db) else {
                    throw SupplementsDayViewModelError.missingUser
                }

                guard let storedSupplement = try Self.fetchStoredSupplement(
                    id: id,
                    userId: userId,
                    in: db
                ) else {
                    throw SupplementsDayViewModelError.supplementNotFound
                }

                let updatedAt = Date()

                try db.execute(
                    sql: """
                        UPDATE user_supplements
                        SET active = ?, updated_at = ?
                        WHERE (id = ? OR id = ?)
                          AND (user_id = ? OR user_id = ?)
                        """,
                    arguments: [
                        isActive,
                        updatedAt.timeIntervalSince1970,
                        id,
                        id.uuidString,
                        userId,
                        userId.uuidString
                    ]
                )

                let payload = storedSupplement
                    .updating(active: isActive, updatedAt: updatedAt)
                    .outboxPayload

                var event = OutboxEvent(
                    id: UUID(),
                    httpMethod: .POST,
                    path: "rest/v1/user_supplements",
                    bodyJson: try JSONEncoder.supabase.encode(payload),
                    priority: 110
                )
                event.headersJson = try Self.outboxHeadersJson()
                event.dependsOn = Self.latestSupplementMutationDependency(for: id, in: db)
                try event.insert(db)
            }

            if let notificationScheduler = AppContainer.shared?.notificationScheduler {
                await notificationScheduler.refreshSchedules()
            }
            await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
            await load()
        } catch {
            #if DEBUG
            supplementsDayLogger.debug("SupplementsDayViewModel.setSupplementActive failed: \(error.localizedDescription, privacy: .private)")
            #endif
            await load()
        }
    }

    func markTaken(_ item: ScheduledSupplement) async {
        guard !item.isTaken else { return }

        do {
            let authId = AuthManager.activeAuthId?.uuidString
            let now = Date()
            let userId = try await dbQueue.read { db in
                guard let userId = try Self.resolveUserId(authId: authId, db: db) else {
                    throw SupplementsDayViewModelError.supplementNotFound
                }
                return userId
            }
            let dayContext = try await resolveManualLocalDayContext(
                referenceDate: now,
                userId: userId
            )
            let currentDay = dayContext.dayString

            _ = try await dbQueue.write { db -> UUID? in
                guard let resolvedUserId = try Self.resolveUserId(authId: authId, db: db),
                      resolvedUserId == userId else {
                    throw SupplementsDayViewModelError.supplementNotFound
                }

                // Look up supplement name from user_supplements
                let name = try String.fetchOne(
                    db,
                    sql: """
                        SELECT COALESCE(user_supplements.custom_name, supplement_catalog.name)
                        FROM user_supplements
                        LEFT JOIN supplement_catalog
                          ON supplement_catalog.id = user_supplements.catalog_id
                        WHERE user_supplements.id = ? OR user_supplements.id = ?
                        LIMIT 1
                        """,
                    arguments: [item.userSupplementId, item.userSupplementId.uuidString]
                ) ?? item.name

                let existingRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT scheduled_time
                        FROM supplement_logs
                        WHERE (user_id = ? OR user_id = ?)
                          AND (user_supplement_id = ? OR user_supplement_id = ?)
                          AND taken_date = ?
                          AND was_scheduled = 1
                          AND deleted_at IS NULL
                        """,
                    arguments: [userId, userId.uuidString, item.userSupplementId, item.userSupplementId.uuidString, currentDay]
                )

                let requestedLookupKey = Self.scheduledLookupKey(
                    userSupplementId: item.userSupplementId,
                    scheduledTime: item.scheduledTime
                )
                let alreadyLogged = existingRows.contains { row in
                    let scheduledTime: String? = row["scheduled_time"]
                    return Self.scheduledLookupKey(
                        userSupplementId: item.userSupplementId,
                        scheduledTime: scheduledTime
                    ) == requestedLookupKey
                }
                guard !alreadyLogged else {
                    return nil
                }

                let doseAmount: Double? = {
                    guard let dose = item.dose else { return nil }
                    let parts = dose.split(separator: " ")
                    guard let first = parts.first else { return nil }
                    return Double(first)
                }()

                let doseUnit: String = {
                    guard let dose = item.dose else { return "mg" }
                    let parts = dose.split(separator: " ")
                    return parts.count > 1 ? String(parts[1]) : "mg"
                }()

                let logId = UUID()
                try db.execute(
                    sql: """
                        INSERT INTO supplement_logs
                            (id, user_id, user_supplement_id, supplement_name,
                             dose_amount, dose_unit, taken_at, taken_date,
                             was_scheduled, scheduled_time, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        logId.uuidString,
                        userId.uuidString,
                        item.userSupplementId.uuidString,
                        name,
                        doseAmount,
                        doseUnit,
                        now.timeIntervalSince1970,
                        currentDay,
                        true,
                        item.scheduledTime,
                        now.timeIntervalSince1970,
                        now.timeIntervalSince1970
                    ]
                )

                let payload = SupplementLogOutboxPayload(
                    id: logId,
                    userId: userId,
                    userSupplementId: item.userSupplementId,
                    takenAt: now,
                    takenDate: currentDay,
                    takenTimezone: dayContext.timeZoneIdentifier,
                    takenUtcOffsetMinutes: dayContext.utcOffsetMinutes,
                    supplementName: name,
                    doseAmount: doseAmount,
                    doseUnit: doseUnit,
                    withFood: nil,
                    notes: nil,
                    wasScheduled: true,
                    scheduledTime: item.scheduledTime,
                    feltEffect: nil,
                    deletedAt: nil,
                    deletedReason: nil,
                    createdAt: now,
                    updatedAt: now
                )

                var event = OutboxEvent(
                    id: logId,
                    httpMethod: .POST,
                    path: "rest/v1/supplement_logs",
                    bodyJson: try JSONEncoder.supabase.encode(payload),
                    priority: 100
                )
                event.headersJson = try Self.outboxHeadersJson()
                try event.insert(db)

                return logId
            }
            if let notificationScheduler = AppContainer.shared?.notificationScheduler {
                await notificationScheduler.refreshSchedules()
            }
            await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
            await load()
        } catch {
            #if DEBUG
            supplementsDayLogger.debug("SupplementsDayViewModel.markTaken failed: \(error.localizedDescription, privacy: .private)")
            #endif
            await load()
        }
    }

    func undoTakenLog(_ log: SupplementLogSummary) async {
        do {
            let authId = AuthManager.activeAuthId?.uuidString
            let now = Date()
            try await dbQueue.write { db in
                guard let userId = try Self.resolveUserId(authId: authId, db: db) else {
                    throw SupplementsDayViewModelError.missingUser
                }
                try db.execute(
                    sql: """
                        UPDATE supplement_logs
                        SET deleted_at = ?, deleted_reason = ?, updated_at = ?
                        WHERE (id = ? OR id = ?)
                          AND (user_id = ? OR user_id = ?)
                          AND deleted_at IS NULL
                        """,
                    arguments: [
                        now.timeIntervalSince1970,
                        "user_undo",
                        now.timeIntervalSince1970,
                        log.id,
                        log.id.uuidString,
                        userId,
                        userId.uuidString
                    ]
                )
                guard db.changesCount > 0 else { return }
                let body = try JSONEncoder.supabase.encode([
                    "deleted_at": ISO8601DateFormatter().string(from: now),
                    "deleted_reason": "user_undo",
                    "updated_at": ISO8601DateFormatter().string(from: now)
                ])
                var event = OutboxEvent(
                    httpMethod: .PATCH,
                    path: "rest/v1/supplement_logs?id=eq.\(log.id.uuidString)",
                    bodyJson: body,
                    priority: 100
                )
                event.headersJson = try Self.outboxHeadersJson()
                try event.insert(db)
            }
            if let notificationScheduler = AppContainer.shared?.notificationScheduler {
                await notificationScheduler.refreshSchedules()
            }
            await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
            await load()
        } catch {
            #if DEBUG
            supplementsDayLogger.debug("SupplementsDayViewModel.undoTakenLog failed: \(error.localizedDescription, privacy: .private)")
            #endif
        }
    }

    func logSupplementNow(_ item: UserStackItem) async {
        do {
            let authId = AuthManager.activeAuthId?.uuidString
            let now = Date()
            let userId = try await dbQueue.read { db in
                guard let userId = try Self.resolveUserId(authId: authId, db: db) else {
                    throw SupplementsDayViewModelError.supplementNotFound
                }
                return userId
            }
            let dayContext = try await resolveManualLocalDayContext(
                referenceDate: now,
                userId: userId
            )
            let currentDay = dayContext.dayString

            _ = try await dbQueue.write { db -> UUID? in
                guard let resolvedUserId = try Self.resolveUserId(authId: authId, db: db),
                      resolvedUserId == userId else {
                    throw SupplementsDayViewModelError.supplementNotFound
                }

                guard let storedSupplement = try Self.fetchStoredSupplement(
                    id: item.id,
                    userId: userId,
                    in: db
                ) else {
                    throw SupplementsDayViewModelError.supplementNotFound
                }

                let logId = UUID()
                let doseUnit = storedSupplement.doseUnit.isEmpty ? "mg" : storedSupplement.doseUnit

                try db.execute(
                    sql: """
                        INSERT INTO supplement_logs
                            (id, user_id, user_supplement_id, supplement_name,
                             dose_amount, dose_unit, taken_at, taken_date,
                             was_scheduled, scheduled_time, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        logId.uuidString,
                        userId.uuidString,
                        storedSupplement.id.uuidString,
                        item.name,
                        storedSupplement.doseAmount,
                        doseUnit,
                        now.timeIntervalSince1970,
                        currentDay,
                        false,
                        nil,
                        now.timeIntervalSince1970,
                        now.timeIntervalSince1970
                    ]
                )

                let payload = SupplementLogOutboxPayload(
                    id: logId,
                    userId: userId,
                    userSupplementId: storedSupplement.id,
                    takenAt: now,
                    takenDate: currentDay,
                    takenTimezone: dayContext.timeZoneIdentifier,
                    takenUtcOffsetMinutes: dayContext.utcOffsetMinutes,
                    supplementName: item.name,
                    doseAmount: storedSupplement.doseAmount,
                    doseUnit: doseUnit,
                    withFood: storedSupplement.takeWithFood,
                    notes: nil,
                    wasScheduled: false,
                    scheduledTime: nil,
                    feltEffect: nil,
                    deletedAt: nil,
                    deletedReason: nil,
                    createdAt: now,
                    updatedAt: now
                )

                var event = OutboxEvent(
                    id: logId,
                    httpMethod: .POST,
                    path: "rest/v1/supplement_logs",
                    bodyJson: try JSONEncoder.supabase.encode(payload),
                    priority: 100
                )
                event.headersJson = try Self.outboxHeadersJson()
                try event.insert(db)

                return logId
            }

            await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
            await load()
        } catch {
#if DEBUG
            supplementsDayLogger.debug("SupplementsDayViewModel.logSupplementNow failed: \(error.localizedDescription, privacy: .private)")
#endif
            await load()
        }
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

    nonisolated private static func resolveUserId(authId: String?, db: Database) throws -> UUID? {
        try UserIdentityLookup.resolveUserId(authId: authId, db: db)
    }

    nonisolated private static func outboxHeadersJson() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
    }

    private func applySupplementActiveState(for id: UUID, isActive: Bool) {
        userStack = userStack.map { item in
            guard item.id == id else { return item }
            return UserStackItem(
                id: item.id,
                name: item.name,
                schedule: item.schedule,
                isActive: isActive,
                doseAmount: item.doseAmount,
                doseUnit: item.doseUnit,
                frequency: item.frequency,
                scheduledTimes: item.scheduledTimes,
                daysOfWeek: item.daysOfWeek,
                startedAt: item.startedAt,
                endedAt: item.endedAt,
                createdAt: item.createdAt
            )
        }
        .sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive {
                return lhs.isActive && !rhs.isActive
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        if !isActive {
            scheduledSupplements.removeAll { $0.userSupplementId == id }
        }

        let totalActive = userStack.filter(\.isActive).count
        monthDays = monthDays.map { dayEntry in
            SupplementMonthDay(
                date: dayEntry.date,
                dayNumber: dayEntry.dayNumber,
                isToday: dayEntry.isToday,
                takenCount: dayEntry.takenCount,
                totalCount: totalActive
            )
        }
    }

    nonisolated fileprivate static func formattedDoseDetails(
        doseAmount: Double?,
        doseUnit: String
    ) -> String? {
        guard let doseAmount else { return nil }
        return "\(doseAmount) \(doseUnit)"
    }

    nonisolated fileprivate static func isScheduled(
        _ definition: SupplementScheduleDefinition,
        on dayString: String
    ) -> Bool {
        guard definition.startedAt <= dayString,
              definition.endedAt.map({ $0 >= dayString }) ?? true,
              definition.frequency != "as_needed" else {
            return false
        }
        guard definition.frequency == "weekly" else { return true }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dayString) else { return false }
        let weekday = Calendar.current.component(.weekday, from: date) - 1
        if let daysOfWeek = definition.daysOfWeek, !daysOfWeek.isEmpty {
            return daysOfWeek.contains(weekday)
        }
        guard let started = formatter.date(from: definition.startedAt) else { return false }
        return weekday == Calendar.current.component(.weekday, from: started) - 1
    }

    nonisolated private static func scheduledLookupKey(
        userSupplementId: UUID,
        scheduledTime: String?
    ) -> String {
        let normalizedScheduledTime: String
        if let normalized = normalizedWallClockTime(from: scheduledTime) {
            normalizedScheduledTime = normalized
        } else if let trimmed = scheduledTime?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty {
            normalizedScheduledTime = trimmed
        } else {
            normalizedScheduledTime = ""
        }
        return "\(userSupplementId.uuidString)|\(normalizedScheduledTime)"
    }

    nonisolated private static func normalizedWallClockTime(from rawValue: String?) -> String? {
        guard let rawValue else { return nil }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let components = trimmed.split(separator: ":")
        guard components.count == 2 || components.count == 3,
              let hour = Int(components[0]),
              let minute = Int(components[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }

        if components.count == 3 {
            guard let second = Int(components[2]), (0...59).contains(second) else {
                return nil
            }
        }

        return String(format: "%02d:%02d", hour, minute)
    }

    private nonisolated static func fetchStoredSupplement(
        id: UUID,
        userId: UUID,
        in db: Database
    ) throws -> StoredUserSupplement? {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT
                    id,
                    user_id,
                    catalog_id,
                    custom_name,
                    dose_amount,
                    dose_unit,
                    frequency,
                    scheduled_times,
                    days_of_week,
                    take_with_food,
                    notes,
                    active,
                    started_at,
                    ended_at,
                    created_at,
                    updated_at
                FROM user_supplements
                WHERE (id = ? OR id = ?)
                  AND (user_id = ? OR user_id = ?)
                LIMIT 1
                """,
            arguments: [id, id.uuidString, userId, userId.uuidString]
        )

        guard let row else { return nil }
        return StoredUserSupplement(row: row)
    }

    private nonisolated static func latestSupplementMutationDependency(for supplementId: UUID, in db: Database) -> UUID? {
        try? UUID.fetchOne(
            db,
            sql: """
                SELECT id
                FROM outbox_events
                WHERE (
                        id = ? OR id = ?
                     OR (
                            path = 'rest/v1/user_supplements'
                        AND CAST(body_json AS TEXT) LIKE ?
                     )
                  )
                  AND status IN (?, ?, ?)
                ORDER BY created_at_local DESC
                LIMIT 1
                """,
            arguments: [
                supplementId,
                supplementId.uuidString,
                "%\(supplementId.uuidString)%",
                OutboxStatus.pending.rawValue,
                OutboxStatus.failedRetryable.rawValue,
                OutboxStatus.inFlight.rawValue
            ]
        )
    }

    fileprivate nonisolated static func decodeDate(from row: Row, column: String) -> Date? {
        if let date: Date = row[column] {
            return date
        }
        if let seconds: Double = row[column] {
            return Date(timeIntervalSince1970: seconds)
        }
        if let seconds: Int64 = row[column] {
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        if let text: String = row[column], let seconds = Double(text) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    fileprivate nonisolated static func decodeStringArray(_ rawValue: String?) -> [String] {
        guard let rawValue,
              let data = rawValue.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return values
    }

    fileprivate nonisolated static func decodeIntArray(_ rawValue: String?) -> [Int]? {
        guard let rawValue,
              let data = rawValue.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [Int] else {
            return nil
        }
        return values
    }

#if DEBUG
    func _testOverrideState(logs: [SupplementLogSummary], isLoading: Bool) {
        self.logs = logs
        self.isLoading = isLoading
    }
#endif
}

// MARK: - Scheduled Supplement

struct ScheduledSupplement: Identifiable {
    let id: String
    let userSupplementId: UUID
    let name: String
    let scheduledTime: String?
    let dose: String?
    var isTaken: Bool
}

struct SupplementScheduleDefinition: Equatable, Sendable {
    let id: UUID
    let frequency: String
    let scheduledTimes: [String]
    let daysOfWeek: [Int]?
    let startedAt: String
    let endedAt: String?
}

// MARK: - Month Day Entry

struct SupplementMonthDay {
    let date: String
    let dayNumber: Int
    let isToday: Bool
    let takenCount: Int
    let totalCount: Int

    var adherenceColor: Color {
        if isToday { return LifeOSColors.Semantic.primary }
        if totalCount == 0 { return LifeOSColors.Surface.card }
        let ratio = Double(takenCount) / Double(totalCount)
        if ratio >= 0.8 { return LifeOSColors.Recovery.ready.opacity(0.6) }
        if ratio >= 0.5 { return LifeOSColors.Recovery.caution.opacity(0.5) }
        if takenCount > 0 { return LifeOSColors.Recovery.critical.opacity(0.3) }
        return LifeOSColors.Surface.card
    }

    var adherenceLabel: String {
        if totalCount == 0 { return String(localized: "supplements_no_schedule") }
        return "\(takenCount)/\(totalCount)"
    }
}

// MARK: - User Stack Item

struct UserStackItem: Identifiable {
    let id: UUID
    let name: String
    let schedule: String
    let isActive: Bool
    let doseAmount: Double?
    let doseUnit: String
    let frequency: String
    let scheduledTimes: [String]
    let daysOfWeek: [Int]?
    let startedAt: String
    let endedAt: String?
    let createdAt: Date
}

private struct StoredUserSupplement {
    let id: UUID
    let userId: UUID
    let catalogId: UUID?
    let customName: String?
    let doseAmount: Double?
    let doseUnit: String
    let frequency: String
    let scheduledTimes: [String]
    let daysOfWeek: [Int]?
    let takeWithFood: Bool
    let notes: String?
    let active: Bool
    let startedAt: String
    let endedAt: String?
    let createdAt: Date
    let updatedAt: Date

    init?(row: Row) {
        guard let id = MixedUUIDStorage.decode(from: row, column: "id"),
              let userId = MixedUUIDStorage.decode(from: row, column: "user_id"),
              let startedAt: String = row["started_at"],
              let createdAt = SupplementsDayViewModel.decodeDate(from: row, column: "created_at"),
              let updatedAt = SupplementsDayViewModel.decodeDate(from: row, column: "updated_at") else {
            return nil
        }

        self.id = id
        self.userId = userId
        self.catalogId = MixedUUIDStorage.decode(from: row, column: "catalog_id")
        self.customName = row["custom_name"]
        self.doseAmount = row["dose_amount"]
        self.doseUnit = row["dose_unit"] ?? "mg"
        self.frequency = row["frequency"] ?? "daily"
        self.scheduledTimes = SupplementsDayViewModel.decodeStringArray(row["scheduled_times"])
        self.daysOfWeek = SupplementsDayViewModel.decodeIntArray(row["days_of_week"])
        self.takeWithFood = row["take_with_food"] ?? false
        self.notes = row["notes"]
        self.active = row["active"] ?? true
        self.startedAt = startedAt
        self.endedAt = row["ended_at"]
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func updating(active: Bool, updatedAt: Date) -> StoredUserSupplement {
        StoredUserSupplement(
            id: id,
            userId: userId,
            catalogId: catalogId,
            customName: customName,
            doseAmount: doseAmount,
            doseUnit: doseUnit,
            frequency: frequency,
            scheduledTimes: scheduledTimes,
            daysOfWeek: daysOfWeek,
            takeWithFood: takeWithFood,
            notes: notes,
            active: active,
            startedAt: startedAt,
            endedAt: endedAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    var outboxPayload: UserSupplementOutboxPayload {
        UserSupplementOutboxPayload(
            id: id,
            userId: userId,
            catalogId: catalogId,
            customName: customName,
            doseAmount: doseAmount,
            doseUnit: doseUnit,
            frequency: frequency,
            scheduledTimes: scheduledTimes,
            daysOfWeek: daysOfWeek,
            takeWithFood: takeWithFood,
            notes: notes,
            active: active,
            startedAt: startedAt,
            endedAt: endedAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private init(
        id: UUID,
        userId: UUID,
        catalogId: UUID?,
        customName: String?,
        doseAmount: Double?,
        doseUnit: String,
        frequency: String,
        scheduledTimes: [String],
        daysOfWeek: [Int]?,
        takeWithFood: Bool,
        notes: String?,
        active: Bool,
        startedAt: String,
        endedAt: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.userId = userId
        self.catalogId = catalogId
        self.customName = customName
        self.doseAmount = doseAmount
        self.doseUnit = doseUnit
        self.frequency = frequency
        self.scheduledTimes = scheduledTimes
        self.daysOfWeek = daysOfWeek
        self.takeWithFood = takeWithFood
        self.notes = notes
        self.active = active
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

private enum SupplementsDayViewModelError: Error {
    case missingUser
    case supplementNotFound
}

// MARK: - Add Supplement View

struct AddSupplementView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var doseAmount = ""
    @State private var doseUnit = "mg"
    @State private var frequency = "daily"
    @State private var scheduledTime = Date()
    @State private var selectedWeeklyDays: Set<Int> = []
    @State private var didSave = false
    private let editing: UserStackItem?
    let onSave: () -> Void
    let onCancel: () -> Void

    init(
        initialName: String = "",
        initialDoseAmount: String = "",
        initialDoseUnit: String = "mg",
        initialFrequency: String = "daily",
        initialScheduledTime: Date = Date(),
        editing: UserStackItem? = nil,
        onSave: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.editing = editing
        _name = State(initialValue: editing?.name ?? initialName)
        _doseAmount = State(initialValue: editing?.doseAmount.map { String($0) } ?? initialDoseAmount)
        _doseUnit = State(initialValue: editing?.doseUnit ?? initialDoseUnit)
        _frequency = State(initialValue: editing?.frequency ?? initialFrequency)
        _scheduledTime = State(initialValue: Self.date(fromWallClock: editing?.scheduledTimes.first) ?? initialScheduledTime)
        _selectedWeeklyDays = State(initialValue: Set(editing?.daysOfWeek ?? []))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "supplements_info")) {
                    TextField(String(localized: "supplements_name"), text: $name)
                    HStack {
                        TextField(String(localized: "supplements_dose"), text: $doseAmount)
                            .keyboardType(.decimalPad)
                        Picker(String(localized: "supplements_unit"), selection: $doseUnit) {
                            Text("mg").tag("mg")
                            Text("mcg").tag("mcg")
                            Text("g").tag("g")
                            Text("IU").tag("IU")
                            Text("mL").tag("mL")
                        }
                        .pickerStyle(.menu)
                    }
                }

                Section(String(localized: "supplements_schedule")) {
                    Picker(String(localized: "supplements_frequency"), selection: $frequency) {
                        Text(String(localized: "supplements_freq_daily")).tag("daily")
                        Text(String(localized: "supplements_freq_twice_daily")).tag("twice_daily")
                        Text(String(localized: "supplements_freq_weekly")).tag("weekly")
                        Text(String(localized: "supplements_freq_as_needed")).tag("as_needed")
                    }
                    if frequency != "as_needed" {
                        DatePicker(String(localized: "supplements_time"), selection: $scheduledTime, displayedComponents: .hourAndMinute)
                    }
                    if frequency == "weekly" {
                        weeklyDaysPicker
                    }
                }
            }
            .navigationTitle(editing == nil ? String(localized: "supplements_add") : String(localized: "edit"))
            .onDisappear {
                guard !didSave else { return }
                onCancel()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "save")) {
                        Task {
                            let saved = await saveSupplement()
                            guard saved else { return }
                            didSave = true
                            dismiss()
                            onSave()
                        }
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }

    private var weeklyDaysPicker: some View {
        let symbols = Calendar.current.shortWeekdaySymbols
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(String(localized: "supplements_schedule"))
                .font(LifeOSTypography.caption.weight(.semibold))
            HStack(spacing: Spacing.xxs) {
                ForEach(0..<7, id: \.self) { weekday in
                    let title = symbols[(weekday + 1) % 7]
                    Button(title) {
                        if selectedWeeklyDays.contains(weekday) {
                            selectedWeeklyDays.remove(weekday)
                        } else {
                            selectedWeeklyDays.insert(weekday)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedWeeklyDays.contains(weekday) ? LifeOSColors.Semantic.primary : .secondary)
                    .accessibilityIdentifier("supplements.weekday.\(weekday)")
                }
            }
        }
    }

    private func saveSupplement() async -> Bool {
        let id = editing?.id ?? UUID()
        let userId = AuthManager.activeAuthId ?? UUID()
        let supplementName = name
        let parsedDoseAmount = Double(doseAmount)
        let selectedDoseUnit = doseUnit
        let selectedFrequency = frequency
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let timeString = timeFormatter.string(from: scheduledTime)

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone.current
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let todayStr = dayFormatter.string(from: Date())

        let daysOfWeek: [Int]? = {
            guard selectedFrequency == "weekly" else { return nil }
            if !selectedWeeklyDays.isEmpty { return selectedWeeklyDays.sorted() }
            return [Calendar.current.component(.weekday, from: Date()) - 1]
        }()

        let timesJson: String
        let scheduledTimes = selectedFrequency == "as_needed" ? [] : [timeString]
        if let data = try? JSONSerialization.data(withJSONObject: scheduledTimes),
           let str = String(data: data, encoding: .utf8) {
            timesJson = str
        } else {
            timesJson = "[\"\(timeString)\"]"
        }

        do {
            let didPersist = try await DatabaseManager.shared.dbQueue.write { db -> Bool in
                guard let dbUserId = try UserIdentityLookup.resolveUserId(
                    authId: userId.uuidString,
                    db: db
                ) else {
                    return false
                }
                let now = Date()

                let serializedDays = daysOfWeek.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }
                let startedAt = editing?.startedAt ?? todayStr
                let createdAt = editing?.createdAt ?? now
                if let editing {
                    try db.execute(
                        sql: """
                            UPDATE user_supplements
                            SET custom_name = ?, dose_amount = ?, dose_unit = ?,
                                frequency = ?, scheduled_times = ?, days_of_week = ?,
                                updated_at = ?
                            WHERE (id = ? OR id = ?) AND (user_id = ? OR user_id = ?)
                            """,
                        arguments: [
                            supplementName, parsedDoseAmount, selectedDoseUnit,
                            selectedFrequency, timesJson, serializedDays,
                            now.timeIntervalSince1970,
                            editing.id, editing.id.uuidString, dbUserId, dbUserId.uuidString
                        ]
                    )
                } else {
                    try db.execute(
                        sql: """
                            INSERT INTO user_supplements
                                (id, user_id, custom_name, dose_amount, dose_unit,
                                 frequency, scheduled_times, active, started_at,
                                 days_of_week, created_at, updated_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            id.uuidString, dbUserId.uuidString, supplementName,
                            parsedDoseAmount, selectedDoseUnit, selectedFrequency,
                            timesJson, true, startedAt, serializedDays,
                            createdAt.timeIntervalSince1970, now.timeIntervalSince1970
                        ]
                    )
                }

                let payload = UserSupplementOutboxPayload(
                    id: id,
                    userId: dbUserId,
                    catalogId: nil,
                    customName: supplementName,
                    doseAmount: parsedDoseAmount,
                    doseUnit: selectedDoseUnit,
                    frequency: selectedFrequency,
                    scheduledTimes: scheduledTimes,
                    daysOfWeek: daysOfWeek,
                    takeWithFood: false,
                    notes: nil,
                    active: editing?.isActive ?? true,
                    startedAt: startedAt,
                    endedAt: editing?.endedAt,
                    createdAt: createdAt,
                    updatedAt: now
                )

                var event = OutboxEvent(
                    id: id,
                    httpMethod: .POST,
                    path: "rest/v1/user_supplements",
                    bodyJson: try JSONEncoder.supabase.encode(payload),
                    priority: 100
                )
                event.headersJson = try Self.outboxHeadersJson()
                try event.insert(db)
                return true
            }
            guard didPersist else { return false }
            if let notificationScheduler = AppContainer.shared?.notificationScheduler {
                await notificationScheduler.refreshSchedules()
            }
            await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
            return true
        } catch {
            return false
        }
    }

    nonisolated private static func outboxHeadersJson() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
    }

    private static func date(fromWallClock rawValue: String?) -> Date? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.date(from: rawValue)
    }
}

private struct SupplementLogSummary: Identifiable {
    let id: UUID
    let name: String
    let details: String?
    let accessibilitySummary: String

    init(id: UUID, name: String, details: String?) {
        self.id = id
        self.name = name
        self.details = details
        self.accessibilitySummary = [name, details].compactMap { $0 }.joined(separator: ", ")
    }

    init?(row: Row) {
        guard let uuid = MixedUUIDStorage.decode(from: row, column: "id"),
              let supplementName: String = row["supplement_name"] else {
            return nil
        }
        id = uuid
        name = supplementName

        let doseAmount: Double? = row["dose_amount"]
        let doseUnit: String? = row["dose_unit"]
        details = if let doseUnit, !doseUnit.isEmpty {
            SupplementsDayViewModel.formattedDoseDetails(doseAmount: doseAmount, doseUnit: doseUnit)
        } else {
            nil
        }
        accessibilitySummary = [name, details].compactMap { $0 }.joined(separator: ", ")
    }
}

private struct SupplementLogOutboxPayload: Codable {
    let id: UUID
    let userId: UUID
    let userSupplementId: UUID?
    let takenAt: Date
    let takenDate: String
    let takenTimezone: String?
    let takenUtcOffsetMinutes: Int?
    let supplementName: String
    let doseAmount: Double?
    let doseUnit: String
    let withFood: Bool?
    let notes: String?
    let wasScheduled: Bool
    let scheduledTime: String?
    let feltEffect: String?
    let deletedAt: Date?
    let deletedReason: String?
    let createdAt: Date
    let updatedAt: Date
}

private struct UserSupplementOutboxPayload: Codable {
    let id: UUID
    let userId: UUID
    let catalogId: UUID?
    let customName: String?
    let doseAmount: Double?
    let doseUnit: String
    let frequency: String
    let scheduledTimes: [String]
    let daysOfWeek: [Int]?
    let takeWithFood: Bool
    let notes: String?
    let active: Bool
    let startedAt: String
    let endedAt: String?
    let createdAt: Date
    let updatedAt: Date
}

#if DEBUG
private extension SupplementLogSummary {
    init(testId: UUID, testName: String, testDetails: String?) {
        id = testId
        name = testName
        details = testDetails
        accessibilitySummary = [testName, testDetails].compactMap { $0 }.joined(separator: ", ")
    }
}

@MainActor
enum SupplementsDayViewTestHarness {
    static func scheduleIsDue(
        frequency: String,
        scheduledTimes: [String] = [],
        daysOfWeek: [Int]? = nil,
        startedAt: String,
        endedAt: String? = nil,
        on day: String
    ) -> Bool {
        SupplementsDayViewModel.isScheduled(
            SupplementScheduleDefinition(
                id: UUID(),
                frequency: frequency,
                scheduledTimes: scheduledTimes,
                daysOfWeek: daysOfWeek,
                startedAt: startedAt,
                endedAt: endedAt
            ),
            on: day
        )
    }

    static func exerciseBodyBranches() {
        let loadingVM = SupplementsDayViewModel(dateString: "2026-02-24")
        loadingVM._testOverrideState(logs: [], isLoading: true)
        _ = SupplementsDayView(dateString: "2026-02-24", testViewModel: loadingVM).body

        let emptyVM = SupplementsDayViewModel(dateString: "2026-02-24")
        emptyVM._testOverrideState(logs: [], isLoading: false)
        _ = SupplementsDayView(dateString: "2026-02-24", testViewModel: emptyVM).body

        let loadedVM = SupplementsDayViewModel(dateString: "2026-02-24")
        loadedVM._testOverrideState(logs: [
            SupplementLogSummary(
                testId: UUID(),
                testName: "Magnesium",
                testDetails: "200 mg"
            )
        ], isLoading: false)
        let loadedView = SupplementsDayView(dateString: "2026-02-24", testViewModel: loadedVM)
        _ = loadedView.body
        loadedView._testRenderLogRows()
    }

    static func loadLogs(
        dateString: String?,
        dbQueue: DatabaseQueue
    ) async -> [String] {
        let viewModel = SupplementsDayViewModel(dateString: dateString, dbQueue: dbQueue)
        await viewModel.load()
        return viewModel.logs.map(\.accessibilitySummary)
    }

    static func runLoadTask(
        dateString: String?,
        dbQueue: DatabaseQueue
    ) async -> Bool {
        let viewModel = SupplementsDayViewModel(dateString: dateString, dbQueue: dbQueue)
        let view = SupplementsDayView(dateString: dateString, testViewModel: viewModel)
        await view._testRunLoadTask()
        return !viewModel.isLoading
    }

    static func runLoadTaskAction(
        dateString: String?,
        dbQueue: DatabaseQueue
    ) async -> Bool {
        let viewModel = SupplementsDayViewModel(dateString: dateString, dbQueue: dbQueue)
        let view = SupplementsDayView(dateString: dateString, testViewModel: viewModel)
        await view._testRunLoadTaskAction()
        return !viewModel.isLoading
    }

    static func loadScheduledAndStackNames(
        dateString: String?,
        dbQueue: DatabaseQueue
    ) async -> (scheduled: [String], stack: [String]) {
        let viewModel = SupplementsDayViewModel(dateString: dateString, dbQueue: dbQueue)
        await viewModel.load()
        return (
            viewModel.scheduledSupplements.map(\.name),
            viewModel.userStack.map(\.name)
        )
    }

    static func markFirstScheduledSupplement(
        dateString: String?,
        dbQueue: DatabaseQueue
    ) async -> (takenFlags: [Bool], logNames: [String]) {
        let viewModel = SupplementsDayViewModel(dateString: dateString, dbQueue: dbQueue)
        await viewModel.load()
        guard let scheduled = viewModel.scheduledSupplements.first else {
            return ([], [])
        }

        await viewModel.markTaken(scheduled)
        return (
            viewModel.scheduledSupplements.map(\.isTaken),
            viewModel.logs.map(\.name)
        )
    }

    static func setSupplementActive(
        dateString: String?,
        dbQueue: DatabaseQueue,
        supplementName: String,
        isActive: Bool
    ) async -> (
        stackNames: [String],
        activeFlags: [Bool],
        scheduledNames: [String],
        quickLogNames: [String],
        dayTotalCount: Int?
    ) {
        let viewModel = SupplementsDayViewModel(dateString: dateString, dbQueue: dbQueue)
        await viewModel.load()
        guard let item = viewModel.userStack.first(where: { $0.name == supplementName }) else {
            return ([], [], [], [], nil)
        }

        await viewModel.setSupplementActive(item.id, isActive: isActive)
        return (
            viewModel.userStack.map(\.name),
            viewModel.userStack.map(\.isActive),
            viewModel.scheduledSupplements.map(\.name),
            viewModel.quickLogStackItems.map(\.name),
            viewModel.monthDays.first(where: { $0.date == viewModel.displayDate })?.totalCount
        )
    }

    static func logFirstQuickSupplement(
        dateString: String?,
        dbQueue: DatabaseQueue
    ) async -> (quickLogNames: [String], logNames: [String]) {
        let viewModel = SupplementsDayViewModel(dateString: dateString, dbQueue: dbQueue)
        await viewModel.load()
        let quickLogNames = viewModel.quickLogStackItems.map(\.name)
        guard let item = viewModel.quickLogStackItems.first else {
            return (quickLogNames, [])
        }

        await viewModel.logSupplementNow(item)
        return (quickLogNames, viewModel.logs.map(\.name))
    }

    static func decodeSummaryCountWithInvalidRows() throws -> Int {
        let dbQueue = try DatabaseQueue(path: ":memory:")
        return try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE tmp_supplement_rows (
                    id TEXT,
                    supplement_name TEXT,
                    dose_amount DOUBLE,
                    dose_unit TEXT
                )
                """)
            try db.execute(
                sql: """
                    INSERT INTO tmp_supplement_rows (id, supplement_name, dose_amount, dose_unit)
                    VALUES (?, ?, ?, ?), (?, ?, ?, ?), (?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString, "Magnesium", 200.0, "mg",
                    UUID().uuidString, "Vitamin D", 1_000.0, "",
                    "not-a-uuid", "Broken", 100.0, "mg"
                ]
            )
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, supplement_name, dose_amount, dose_unit FROM tmp_supplement_rows"
            )
            return rows.compactMap(SupplementLogSummary.init(row:)).count
        }
    }
}

private extension SupplementsDayView {
    func _testRenderLogRows() {
        _ = logRow(
            SupplementLogSummary(
                testId: UUID(),
                testName: "Magnesium",
                testDetails: "200 mg"
            )
        )
        _ = logRow(
            SupplementLogSummary(
                testId: UUID(),
                testName: "Vitamin D",
                testDetails: nil
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
