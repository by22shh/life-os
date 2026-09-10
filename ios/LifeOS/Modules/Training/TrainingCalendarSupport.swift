import SwiftUI
import GRDB

struct TrainingCalendarDay: Identifiable, Equatable, Sendable {
    let id: String
    let day: String
    let loggedCount: Int
    let plannedCount: Int
    let completedPlannedCount: Int
    let totalDurationMinutes: Int
    let totalTrimpScore: Double
    let hasLoggedWorkout: Bool
    let hasPlannedWorkout: Bool

    init(
        day: String,
        loggedCount: Int,
        plannedCount: Int,
        completedPlannedCount: Int,
        totalDurationMinutes: Int,
        totalTrimpScore: Double
    ) {
        self.id = day
        self.day = day
        self.loggedCount = loggedCount
        self.plannedCount = plannedCount
        self.completedPlannedCount = completedPlannedCount
        self.totalDurationMinutes = totalDurationMinutes
        self.totalTrimpScore = totalTrimpScore
        self.hasLoggedWorkout = loggedCount > 0
        self.hasPlannedWorkout = plannedCount > 0
    }

    init(remote day: WorkoutCalendarRemoteDay) {
        self.init(
            day: day.date,
            loggedCount: day.loggedCount,
            plannedCount: day.plannedCount,
            completedPlannedCount: day.completedPlannedCount,
            totalDurationMinutes: day.totalDurationMinutes,
            totalTrimpScore: day.totalTrimpScore,
        )
    }

    var dayNumber: String {
        guard let date = DiaryDateFormatter.parseDate(day) else { return day }
        return date.formatted(.dateTime.day())
    }

    var shortWeekday: String {
        guard let date = DiaryDateFormatter.parseDate(day) else { return day }
        return date.formatted(.dateTime.weekday(.narrow))
    }

    var durationLabel: String? {
        guard totalDurationMinutes > 0 else { return nil }
        return localizedTrainingMinutes(totalDurationMinutes)
    }

    var compactMetricLabel: String? {
        if let durationLabel {
            return durationLabel
        }
        if plannedCount > 0 {
            return String(
                format: NSLocalizedString(
                    "training.calendar_planned_short_format",
                    value: "%d plan",
                    comment: "Short training calendar planned count"
                ),
                plannedCount
            )
        }
        return nil
    }

    var accessibilitySummary: String {
        var parts = [
            formattedTrainingCalendarLongDate(day)
        ]

        if loggedCount > 0 {
            parts.append(
                String(
                    format: NSLocalizedString(
                        "training.calendar_logged_format",
                        value: "%d logged workouts",
                        comment: "Training calendar logged workouts label"
                    ),
                    loggedCount
                )
            )
        }

        if plannedCount > 0 {
            parts.append(
                String(
                    format: NSLocalizedString(
                        "training.calendar_planned_format",
                        value: "%d planned sessions",
                        comment: "Training calendar planned sessions label"
                    ),
                    plannedCount
                )
            )
        }

        if totalDurationMinutes > 0 {
            parts.append(durationLabel ?? "")
        }

        if totalTrimpScore > 0 {
            parts.append(
                String(
                    format: NSLocalizedString(
                        "training.calendar_trimp_format",
                        value: "TRIMP %.0f",
                        comment: "Training calendar TRIMP label"
                    ),
                    totalTrimpScore
                )
            )
        }

        if !hasLoggedWorkout && !hasPlannedWorkout {
            parts.append(
                NSLocalizedString(
                    "training.calendar_rest_day",
                    value: "Recovery day",
                    comment: "Training calendar empty day label"
                )
            )
        }

        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

struct TrainingCalendarWeekSummary: Equatable {
    let loggedSessions: Int
    let plannedSessions: Int
    let completedPlannedSessions: Int
    let totalDurationMinutes: Int
    let totalTrimpScore: Double

    init(days: [TrainingCalendarDay]) {
        loggedSessions = days.reduce(0) { $0 + $1.loggedCount }
        plannedSessions = days.reduce(0) { $0 + $1.plannedCount }
        completedPlannedSessions = days.reduce(0) { $0 + $1.completedPlannedCount }
        totalDurationMinutes = days.reduce(0) { $0 + $1.totalDurationMinutes }
        totalTrimpScore = days.reduce(0) { $0 + $1.totalTrimpScore }
    }

    var completionLabel: String {
        if plannedSessions > 0 {
            return String(
                format: NSLocalizedString(
                    "training.calendar_completion_format",
                    value: "%d of %d planned",
                    comment: "Training calendar weekly completion label"
                ),
                min(max(loggedSessions, completedPlannedSessions), plannedSessions),
                plannedSessions
            )
        }

        if loggedSessions > 0 {
            return String(
                format: NSLocalizedString(
                    "training.calendar_logged_only_format",
                    value: "%d workouts logged",
                    comment: "Training calendar weekly logged-only label"
                ),
                loggedSessions
            )
        }

        return NSLocalizedString(
            "training.calendar_recovery_week",
            value: "Recovery-focused week",
            comment: "Training calendar weekly empty label"
        )
    }

    var durationLabel: String {
        if totalDurationMinutes > 0 {
            return localizedTrainingMinutes(totalDurationMinutes)
        }
        return NSLocalizedString(
            "training.calendar_no_duration",
            value: "No duration yet",
            comment: "Training calendar weekly duration placeholder"
        )
    }

    var loadLabel: String {
        if totalTrimpScore > 0 {
            return String(
                format: NSLocalizedString(
                    "training.calendar_weekly_load_format",
                    value: "%.0f TRIMP",
                    comment: "Training calendar weekly load label"
                ),
                totalTrimpScore
            )
        }
        return NSLocalizedString(
            "training.calendar_load_pending",
            value: "Load building",
            comment: "Training calendar weekly load placeholder"
        )
    }
}

private enum TrainingCalendarLoaderError: Error {
    case remoteUnavailable
}

enum TrainingCalendarLoader {
    static func loadWeek(
        containing date: Date,
        dbQueue: DatabaseQueue,
        apiClient: any TrainingCalendarRouteAPIClient = APIClient(),
        runtimeConfigured: @escaping @Sendable () -> Bool = { SupabaseConfig.isRuntimeConfigured },
        hasCloudSessionProvider: @escaping @Sendable () async -> Bool = {
            await MainActor.run { AuthManager.activeHasCloudSession }
        }
    ) async throws -> [TrainingCalendarDay] {
        let range = weekRange(containing: date)
        return try await loadRange(
            from: range.from,
            to: range.to,
            dbQueue: dbQueue,
            apiClient: apiClient,
            runtimeConfigured: runtimeConfigured,
            hasCloudSessionProvider: hasCloudSessionProvider
        )
    }

    static func loadMonth(
        month: Date,
        dbQueue: DatabaseQueue,
        apiClient: any TrainingCalendarRouteAPIClient = APIClient(),
        runtimeConfigured: @escaping @Sendable () -> Bool = { SupabaseConfig.isRuntimeConfigured },
        hasCloudSessionProvider: @escaping @Sendable () async -> Bool = {
            await MainActor.run { AuthManager.activeHasCloudSession }
        }
    ) async throws -> [TrainingCalendarDay] {
        let range = monthRange(for: month)
        return try await loadRange(
            from: range.from,
            to: range.to,
            dbQueue: dbQueue,
            apiClient: apiClient,
            runtimeConfigured: runtimeConfigured,
            hasCloudSessionProvider: hasCloudSessionProvider
        )
    }

    static func loadRange(
        from fromDay: String,
        to toDay: String,
        dbQueue: DatabaseQueue,
        apiClient: any TrainingCalendarRouteAPIClient = APIClient(),
        runtimeConfigured: @escaping @Sendable () -> Bool = { SupabaseConfig.isRuntimeConfigured },
        hasCloudSessionProvider: @escaping @Sendable () async -> Bool = {
            await MainActor.run { AuthManager.activeHasCloudSession }
        }
    ) async throws -> [TrainingCalendarDay] {
        do {
            return try await loadRemoteRange(
                from: fromDay,
                to: toDay,
                apiClient: apiClient,
                runtimeConfigured: runtimeConfigured,
                hasCloudSessionProvider: hasCloudSessionProvider
            )
        } catch {
            return try await loadLocalRange(from: fromDay, to: toDay, dbQueue: dbQueue)
        }
    }

    static func weekRange(containing date: Date) -> (from: String, to: String) {
        let calendar = Calendar.current
        guard
            let weekInterval = calendar.dateInterval(of: .weekOfYear, for: date),
            let endDate = calendar.date(byAdding: .day, value: 6, to: weekInterval.start)
        else {
            let day = DiaryDateFormatter.formatDate(date)
            return (day, day)
        }

        return (
            DiaryDateFormatter.formatDate(weekInterval.start),
            DiaryDateFormatter.formatDate(endDate)
        )
    }

    static func monthRange(for month: Date) -> (from: String, to: String) {
        let calendar = Calendar.current
        guard
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
            let dayRange = calendar.range(of: .day, in: .month, for: monthStart),
            let monthEnd = calendar.date(byAdding: .day, value: dayRange.count - 1, to: monthStart)
        else {
            let day = DiaryDateFormatter.formatDate(month)
            return (day, day)
        }

        return (
            DiaryDateFormatter.formatDate(monthStart),
            DiaryDateFormatter.formatDate(monthEnd)
        )
    }

    private static func loadRemoteRange(
        from fromDay: String,
        to toDay: String,
        apiClient: any TrainingCalendarRouteAPIClient,
        runtimeConfigured: @escaping @Sendable () -> Bool,
        hasCloudSessionProvider: @escaping @Sendable () async -> Bool
    ) async throws -> [TrainingCalendarDay] {
        let hasCloudSession = await hasCloudSessionProvider()
        guard runtimeConfigured(), hasCloudSession else {
            throw TrainingCalendarLoaderError.remoteUnavailable
        }

        let response = try await apiClient.fetchWorkoutCalendar(from: fromDay, to: toDay)
        return response.days.map(TrainingCalendarDay.init(remote:))
    }

    private static func loadLocalRange(
        from fromDay: String,
        to toDay: String,
        dbQueue: DatabaseQueue
    ) async throws -> [TrainingCalendarDay] {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }

        return try await dbQueue.read { db in
            guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                return enumerateDays(from: fromDay, to: toDay).map {
                    TrainingCalendarDay(
                        day: $0,
                        loggedCount: 0,
                        plannedCount: 0,
                        completedPlannedCount: 0,
                        totalDurationMinutes: 0,
                        totalTrimpScore: 0
                    )
                }
            }

            let sessionRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT session_date, duration_minutes, trimp_score
                    FROM workout_sessions
                    WHERE (user_id = ? OR user_id = ?)
                      AND session_date BETWEEN ? AND ?
                      AND deleted_at IS NULL
                    """,
                arguments: [userId, userId.uuidString, fromDay, toDay]
            )

            let plannedRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT planned_date, status
                    FROM training_plan_sessions
                    WHERE (user_id = ? OR user_id = ?)
                      AND planned_date BETWEEN ? AND ?
                    """,
                arguments: [userId, userId.uuidString, fromDay, toDay]
            )

            var summaries: [String: TrainingCalendarDayAccumulator] = [:]
            for row in sessionRows {
                guard let day: String = row["session_date"] else { continue }
                var value = summaries[day] ?? TrainingCalendarDayAccumulator()
                value.loggedCount += 1
                value.totalDurationMinutes += row["duration_minutes"] ?? 0
                value.totalTrimpScore += row["trimp_score"] ?? 0
                summaries[day] = value
            }

            for row in plannedRows {
                guard let day: String = row["planned_date"] else { continue }
                var value = summaries[day] ?? TrainingCalendarDayAccumulator()
                value.plannedCount += 1
                if let status: String = row["status"], status == "completed" {
                    value.completedPlannedCount += 1
                }
                summaries[day] = value
            }

            return enumerateDays(from: fromDay, to: toDay).map { day in
                let summary = summaries[day] ?? TrainingCalendarDayAccumulator()
                return TrainingCalendarDay(
                    day: day,
                    loggedCount: summary.loggedCount,
                    plannedCount: summary.plannedCount,
                    completedPlannedCount: summary.completedPlannedCount,
                    totalDurationMinutes: summary.totalDurationMinutes,
                    totalTrimpScore: summary.totalTrimpScore
                )
            }
        }
    }

    private static func enumerateDays(from fromDay: String, to toDay: String) -> [String] {
        guard
            let startDate = DiaryDateFormatter.parseDate(fromDay),
            let endDate = DiaryDateFormatter.parseDate(toDay)
        else {
            return [fromDay]
        }

        let calendar = Calendar.current
        var result: [String] = []
        var cursor = startDate
        while cursor <= endDate {
            result.append(DiaryDateFormatter.formatDate(cursor))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? endDate.addingTimeInterval(1)
        }
        return result
    }
}

private struct TrainingCalendarDayAccumulator {
    var loggedCount = 0
    var plannedCount = 0
    var completedPlannedCount = 0
    var totalDurationMinutes = 0
    var totalTrimpScore = 0.0
}

struct TrainingWeekOverviewCard: View {
    let selectedDay: String
    let selectedDate: Date
    let onSelectDay: (String) -> Void
    let onOpenMonth: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var weekDays: [TrainingCalendarDay] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let dbQueue: DatabaseQueue

    init(
        selectedDay: String,
        selectedDate: Date,
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue,
        onSelectDay: @escaping (String) -> Void,
        onOpenMonth: @escaping () -> Void
    ) {
        self.selectedDay = selectedDay
        self.selectedDate = selectedDate
        self.dbQueue = dbQueue
        self.onSelectDay = onSelectDay
        self.onOpenMonth = onOpenMonth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Label(
                    NSLocalizedString(
                        "training.calendar_week_title",
                        value: "Week view",
                        comment: "Training calendar week section title"
                    ),
                    systemImage: "calendar"
                )
                .font(LifeOSTypography.subheadline.weight(.semibold))

                Spacer()

                Button(
                    NSLocalizedString(
                        "training.calendar_month_cta",
                        value: "Month",
                        comment: "Training calendar open month view button"
                    ),
                    action: onOpenMonth
                )
                .buttonStyle(.bordered)
                .tint(LifeOSColors.Semantic.primary)
                .foregroundStyle(LifeOSColors.Text.primary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(LifeOSColors.Text.secondary)
            } else if !weekDays.isEmpty {
                let summary = TrainingCalendarWeekSummary(days: weekDays)
                summaryLayout {
                    weeklySummaryPills(summary)
                }

                weekLayout {
                    ForEach(weekDays) { day in
                        Button {
                            onSelectDay(day.day)
                        } label: {
                            TrainingWeekDayChip(
                                day: day,
                                isSelected: day.day == selectedDay
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(day.accessibilitySummary)
                        .accessibilityAddTraits(day.day == selectedDay ? .isSelected : [])
                    }
                }
            }

            if isLoading && weekDays.isEmpty {
                ProgressView()
                    .padding(.vertical, Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
        .task(id: selectedDay) {
            await loadWeek()
        }
    }

    private var weekLayout: AnyLayout {
        if dynamicTypeSize > .large {
            return AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xs))
        }
        return AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.xs))
    }

    private var summaryLayout: AnyLayout {
        if dynamicTypeSize > .large {
            return AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xs))
        }
        return AnyLayout(HStackLayout(spacing: Spacing.s))
    }

    private func loadWeek() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let loadedDays = try await TrainingCalendarLoader.loadWeek(
                containing: selectedDate,
                dbQueue: dbQueue
            )
            weekDays = loadedDays
            errorMessage = nil
        } catch {
            weekDays = []
            errorMessage = NSLocalizedString(
                "training.calendar_load_failed",
                value: "Calendar is unavailable right now.",
                comment: "Training calendar load error"
            )
        }
    }

    @ViewBuilder
    private func weeklySummaryPills(_ summary: TrainingCalendarWeekSummary) -> some View {
        trainingCalendarPill(
            title: NSLocalizedString(
                "training.calendar_summary_completion",
                value: "Plan",
                comment: "Training calendar weekly completion pill title"
            ),
            value: summary.completionLabel
        )
        trainingCalendarPill(
            title: NSLocalizedString(
                "training.calendar_summary_duration",
                value: "Volume",
                comment: "Training calendar weekly duration pill title"
            ),
            value: summary.durationLabel
        )
        trainingCalendarPill(
            title: NSLocalizedString(
                "training.calendar_summary_load",
                value: "Load",
                comment: "Training calendar weekly load pill title"
            ),
            value: summary.loadLabel
        )
    }

    private func trainingCalendarPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(LifeOSTypography.caption.weight(.semibold))
                .foregroundStyle(LifeOSColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(LifeOSTypography.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .background(LifeOSColors.Semantic.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
        .accessibilityElement(children: .combine)
    }
}

private struct TrainingWeekDayChip: View {
    let day: TrainingCalendarDay
    let isSelected: Bool

    var body: some View {
        VStack(spacing: Spacing.xxs) {
            Text(day.shortWeekday)
                .font(LifeOSTypography.subheadline.weight(.semibold))
                .foregroundStyle(LifeOSColors.Text.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(day.dayNumber)
                .font(LifeOSTypography.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 4) {
                Circle()
                    .fill(day.primaryIndicatorTint)
                    .frame(width: 7, height: 7)
                if day.hasLoggedWorkout && day.hasPlannedWorkout {
                    Circle()
                        .fill(LifeOSColors.Semantic.primary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityHidden(true)

            if let metric = day.compactMetricLabel {
                Text(metric)
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(LifeOSColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .padding(.vertical, Spacing.xs)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius)
                .strokeBorder(border, lineWidth: isSelected ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private var background: Color {
        if isSelected {
            return day.primaryIndicatorTint.opacity(0.18)
        }
        return day.primaryIndicatorTint.opacity(day.hasLoggedWorkout || day.hasPlannedWorkout ? 0.08 : 0.03)
    }

    private var border: Color {
        isSelected ? day.primaryIndicatorTint : day.primaryIndicatorTint.opacity(0.35)
    }
}

struct TrainingCalendarView: View {
    let selectedDate: Date
    let onSelectDay: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayedMonth: Date
    @State private var daysByKey: [String: TrainingCalendarDay] = [:]
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let calendar = Calendar.current
    private let dbQueue: DatabaseQueue

    init(
        selectedDate: Date,
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue,
        onSelectDay: @escaping (String) -> Void
    ) {
        self.selectedDate = selectedDate
        self.dbQueue = dbQueue
        self.onSelectDay = onSelectDay
        self._displayedMonth = State(initialValue: selectedDate)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.m) {
                monthHeader
                weekdayHeader
                calendarGrid

                if let errorMessage {
                    Text(errorMessage)
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(LifeOSColors.Text.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(
                        NSLocalizedString(
                            "training.calendar_month_hint",
                            value: "Tap a day to jump into the workout log and plan for that date.",
                            comment: "Training calendar month view hint"
                        )
                    )
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(LifeOSColors.Text.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(LayoutConstants.contentPadding)
            .navigationTitle(
                NSLocalizedString(
                    "training.calendar_month_title",
                    value: "Training calendar",
                    comment: "Training calendar month sheet title"
                )
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(
                        NSLocalizedString(
                            "common_close",
                            value: "Close",
                            comment: "Close button"
                        )
                    ) {
                        dismiss()
                    }
                }
            }
        }
        .task(id: displayedMonth) {
            await loadMonth()
        }
    }

    private var monthHeader: some View {
        HStack {
            Button {
                displayedMonth = calendar.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: LayoutConstants.minTouchTarget, height: LayoutConstants.minTouchTarget)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(displayedMonth, format: .dateTime.month(.wide).year())
                .font(LifeOSTypography.title3.weight(.semibold))

            Spacer()

            Button {
                displayedMonth = calendar.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: LayoutConstants.minTouchTarget, height: LayoutConstants.minTouchTarget)
            }
            .buttonStyle(.plain)
        }
    }

    private var weekdayHeader: some View {
        let symbols = orderedWeekdaySymbols()
        return HStack(spacing: Spacing.xs) {
            ForEach(symbols, id: \.self) { symbol in
                Text(symbol)
                    .font(LifeOSTypography.caption.weight(.semibold))
                    .foregroundStyle(LifeOSColors.Text.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var calendarGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.xs), count: 7), spacing: Spacing.xs) {
            ForEach(Array(daysInMonth().enumerated()), id: \.offset) { _, date in
                if let date {
                    let dayKey = DiaryDateFormatter.formatDate(date)
                    let summary = daysByKey[dayKey]
                    Button {
                        onSelectDay(dayKey)
                        dismiss()
                    } label: {
                        TrainingMonthDayCell(
                            day: summary ?? TrainingCalendarDay(
                                day: dayKey,
                                loggedCount: 0,
                                plannedCount: 0,
                                completedPlannedCount: 0,
                                totalDurationMinutes: 0,
                                totalTrimpScore: 0
                            ),
                            isSelected: calendar.isDate(date, inSameDayAs: selectedDate)
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                        .frame(height: 76)
                }
            }
        }
        .overlay {
            if isLoading {
                ProgressView()
            }
        }
    }

    private func loadMonth() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let loadedDays = try await TrainingCalendarLoader.loadMonth(
                month: displayedMonth,
                dbQueue: dbQueue
            )
            daysByKey = Dictionary(uniqueKeysWithValues: loadedDays.map { ($0.day, $0) })
            errorMessage = nil
        } catch {
            daysByKey = [:]
            errorMessage = NSLocalizedString(
                "training.calendar_load_failed",
                value: "Calendar is unavailable right now.",
                comment: "Training calendar load error"
            )
        }
    }

    private func orderedWeekdaySymbols() -> [String] {
        let firstIndex = max(0, min(calendar.shortWeekdaySymbols.count - 1, calendar.firstWeekday - 1))
        let values = Array(0..<calendar.shortWeekdaySymbols.count)
        let ordered = Array(values[firstIndex...]) + Array(values[..<firstIndex])
        return ordered.map { calendar.shortWeekdaySymbols[$0] }
    }

    private func daysInMonth() -> [Date?] {
        guard
            let firstDay = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)),
            let dayRange = calendar.range(of: .day, in: .month, for: firstDay)
        else {
            return []
        }

        let firstWeekday = calendar.component(.weekday, from: firstDay)
        let leadingSpaces = (firstWeekday - calendar.firstWeekday + 7) % 7
        var values = Array(repeating: Optional<Date>.none, count: leadingSpaces)
        values += dayRange.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: firstDay)
        }
        return values
    }
}

private struct TrainingMonthDayCell: View {
    let day: TrainingCalendarDay
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(alignment: .top) {
                Text(day.dayNumber)
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Circle()
                    .fill(day.primaryIndicatorTint)
                    .frame(width: 8, height: 8)
            }

            Spacer(minLength: 0)

            if let compactMetricLabel = day.compactMetricLabel {
                Text(compactMetricLabel)
                    .font(LifeOSTypography.caption2)
                    .foregroundStyle(LifeOSColors.Text.secondary)
                    .lineLimit(2)
            } else {
                Text(
                    NSLocalizedString(
                        "training.calendar_rest_day_short",
                        value: "Rest",
                        comment: "Training calendar short rest day label"
                    )
                )
                .font(LifeOSTypography.caption2)
                .foregroundStyle(LifeOSColors.Text.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .padding(Spacing.xs)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius)
                .strokeBorder(border, lineWidth: isSelected ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.accessibilitySummary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isSelected {
            return day.primaryIndicatorTint.opacity(0.16)
        }
        return day.primaryIndicatorTint.opacity(day.hasLoggedWorkout || day.hasPlannedWorkout ? 0.08 : 0.03)
    }

    private var border: Color {
        isSelected ? day.primaryIndicatorTint : day.primaryIndicatorTint.opacity(0.28)
    }
}

private extension TrainingCalendarDay {
    var primaryIndicatorTint: Color {
        if hasLoggedWorkout {
            if totalTrimpScore >= 90 {
                return LifeOSColors.Recovery.optimal
            }
            return LifeOSColors.Recovery.ready
        }
        if hasPlannedWorkout {
            return LifeOSColors.Semantic.primary
        }
        return .secondary
    }
}

private func formattedTrainingCalendarLongDate(_ day: String) -> String {
    guard let date = DiaryDateFormatter.parseDate(day) else { return day }
    return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
}
