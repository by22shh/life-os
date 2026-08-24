import Foundation
import Observation
import SwiftUI

struct MenstrualDayView: View {
    @State private var viewModel: MenstrualDayViewModel

    init(dateString: String?, store: MenstrualStore = MenstrualStore()) {
        _viewModel = State(initialValue: MenstrualDayViewModel(dateString: dateString, store: store))
    }

#if DEBUG
    init(testViewModel: MenstrualDayViewModel) {
        _viewModel = State(initialValue: testViewModel)
    }

    func _testEvaluateBody() {
        _ = body
    }
#endif

    var body: some View {
        @Bindable var viewModel = viewModel

        ScrollView {
            VStack(spacing: Spacing.m) {
                VStack(spacing: Spacing.xs) {
                    Label(String(localized: "menstrual_title"), systemImage: "drop.circle")
                        .font(LifeOSTypography.title3)

                    DatePicker(
                        String(localized: "date"),
                        selection: Binding(
                            get: { viewModel.selectedDate },
                            set: { viewModel.updateSelectedDate($0) }
                        ),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)
                }

                cardContainer {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text(String(localized: "menstrual_log_title"))
                            .font(LifeOSTypography.headline)

                        Text(viewModel.currentSummary)
                            .font(LifeOSTypography.body)
                            .foregroundStyle(.secondary)

                        if !viewModel.trackingEnabled {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text(String(localized: "menstrual_tracking_disabled_title"))
                                    .font(LifeOSTypography.subheadline.weight(.semibold))

                                Text(String(localized: "menstrual_tracking_disabled_body"))
                                    .font(LifeOSTypography.caption)
                                    .foregroundStyle(.secondary)

                                NavigationLink {
                                    SettingsHealthFlagsView()
                                } label: {
                                    Label(String(localized: "menstrual_open_health_flags"), systemImage: "slider.horizontal.3")
                                        .font(LifeOSTypography.caption.weight(.semibold))
                                }
                            }
                        }

                        if viewModel.syncEnabled {
                            PrivacyNoteView(
                                .custom(
                                    icon: "lock.icloud",
                                    text: String(localized: "menstrual_sync_enabled_note")
                                )
                            )
                        } else {
                            PrivacyNoteView(.menstrualLocalOnly)
                        }

                        if let statusMessage = viewModel.statusMessage {
                            Text(statusMessage)
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                cardContainer {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text(String(localized: "menstrual_flow_section"))
                            .font(LifeOSTypography.subheadline.weight(.semibold))

                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: Spacing.s),
                                GridItem(.flexible(), spacing: Spacing.s),
                            ],
                            spacing: Spacing.s
                        ) {
                            ForEach(MenstrualFlow.allCases, id: \.self) { flow in
                                selectionButton(
                                    title: flow.localizedTitle,
                                    isSelected: viewModel.draftFlow == flow
                                ) {
                                    viewModel.toggleFlow(flow)
                                }
                            }
                        }

                        Button(String(localized: "menstrual_flow_none")) {
                            viewModel.clearFlow()
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.draftFlow == nil || viewModel.isSaving)

                        Divider()

                        Text(String(localized: "menstrual_pain_section"))
                            .font(LifeOSTypography.subheadline.weight(.semibold))

                        LazyVGrid(
                            columns: [
                                GridItem(.adaptive(minimum: 92), spacing: Spacing.s),
                            ],
                            spacing: Spacing.s
                        ) {
                            painSelectionButton(
                                title: String(localized: "menstrual_pain_none"),
                                isSelected: viewModel.draftPainLevel == 0
                            ) {
                                viewModel.setPainLevel(0)
                            }

                            ForEach(1...5, id: \.self) { painLevel in
                                painSelectionButton(
                                    title: String(format: String(localized: "menstrual_pain_value_format"), painLevel),
                                    isSelected: viewModel.draftPainLevel == painLevel
                                ) {
                                    viewModel.setPainLevel(painLevel)
                                }
                            }
                        }

                        HStack(spacing: Spacing.s) {
                            Button(String(localized: "settings_save")) {
                                Task { await viewModel.save() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!viewModel.canSaveDraft)

                            if viewModel.currentLog != nil {
                                Button(String(localized: "menstrual_delete_entry")) {
                                    Task { await viewModel.deleteCurrentLog() }
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)
                                .disabled(viewModel.isSaving)
                            }
                        }
                    }
                }

                cardContainer {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text(String(localized: "menstrual_recent_history"))
                            .font(LifeOSTypography.subheadline.weight(.semibold))

                        if viewModel.isLoading && viewModel.historyEntries.isEmpty {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, Spacing.s)
                        } else if viewModel.historyEntries.isEmpty {
                            Text(String(localized: "menstrual_recent_empty"))
                                .font(LifeOSTypography.body)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: Spacing.s) {
                                ForEach(viewModel.historyEntries) { entry in
                                    Button {
                                        viewModel.jumpTo(dateString: entry.date)
                                    } label: {
                                        HStack(spacing: Spacing.s) {
                                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                                Text(viewModel.formattedHistoryDate(entry.date))
                                                    .font(LifeOSTypography.subheadline.weight(.semibold))
                                                    .foregroundStyle(.primary)

                                                Text(viewModel.summary(for: entry))
                                                    .font(LifeOSTypography.caption)
                                                    .foregroundStyle(.secondary)
                                            }

                                            Spacer()

                                            Image(systemName: "chevron.right")
                                                .font(LifeOSTypography.caption)
                                                .foregroundStyle(.tertiary)
                                        }
                                        .padding(Spacing.s)
                                        .background(LifeOSColors.Surface.background)
                                        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .padding(LayoutConstants.contentPadding)
        }
        .background(LifeOSColors.Surface.background)
        .navigationTitle(String(localized: "menstrual_title"))
        .task(id: viewModel.selectedDay) {
            await viewModel.loadForSelectedDayTask()
        }
    }

    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
    }

    private func selectionButton(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(LifeOSTypography.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.s)
                .background(isSelected ? LifeOSColors.Semantic.primary.opacity(0.14) : LifeOSColors.Surface.background)
                .foregroundStyle(isSelected ? LifeOSColors.Semantic.primary : .primary)
                .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .disabled(viewModel.isSaving)
    }

    private func painSelectionButton(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(LifeOSTypography.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.s)
                .background(isSelected ? LifeOSColors.Semantic.primary.opacity(0.14) : LifeOSColors.Surface.background)
                .foregroundStyle(isSelected ? LifeOSColors.Semantic.primary : .primary)
                .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .disabled(viewModel.isSaving)
    }
}

@MainActor
@Observable
final class MenstrualDayViewModel {
    var selectedDate: Date
    var currentLog: MenstrualLog?
    var recentLogs: [MenstrualLog] = []
    var trackingEnabled = false
    var syncEnabled = false
    var isLoading = false
    var isSaving = false
    var statusMessage: String?
    var draftFlow: MenstrualFlow?
    var draftPainLevel = 0

    private let store: MenstrualStore
    private var activeUserId: UUID?

    init(dateString: String?, store: MenstrualStore = MenstrualStore()) {
        self.selectedDate = DiaryDateFormatter.parseDate(dateString) ?? Date()
        self.store = store
    }

    var selectedDay: String {
        DiaryDateFormatter.formatDate(selectedDate)
    }

    var historyEntries: [MenstrualLog] {
        recentLogs.filter { $0.date != selectedDay }
    }

    var canSaveDraft: Bool {
        activeUserId != nil && !isSaving && (draftFlow != nil || draftPainLevel > 0)
    }

    var currentSummary: String {
        if let currentLog {
            return summary(for: currentLog)
        }
        if activeUserId == nil {
            return String(localized: "menstrual_unavailable")
        }
        return String(localized: "menstrual_status_empty")
    }

    func loadForSelectedDayTask() async {
        await load(preserveStatus: false)
    }

    func updateSelectedDate(_ newValue: Date) {
        let normalized = Calendar.current.startOfDay(for: newValue)
        if selectedDay != DiaryDateFormatter.formatDate(normalized) {
            statusMessage = nil
            currentLog = nil
            draftFlow = nil
            draftPainLevel = 0
        }
        selectedDate = normalized
    }

    func jumpTo(dateString: String) {
        guard let parsedDate = DiaryDateFormatter.parseDate(dateString) else { return }
        updateSelectedDate(parsedDate)
    }

    func toggleFlow(_ flow: MenstrualFlow) {
        draftFlow = draftFlow == flow ? nil : flow
    }

    func clearFlow() {
        draftFlow = nil
    }

    func setPainLevel(_ value: Int) {
        draftPainLevel = min(max(value, 0), 5)
    }

    func save() async {
        guard draftFlow != nil || draftPainLevel > 0 else {
            return
        }

        isSaving = true
        defer { isSaving = false }

        do {
            let context = try await store.fetchContext(date: selectedDay)
            guard let activeUserId = context.userId else {
                statusMessage = String(localized: "menstrual_unavailable")
                return
            }

            let now = Date()
            var log = context.currentLog ?? MenstrualLog(userId: activeUserId, date: selectedDay)
            log.userId = activeUserId
            log.date = selectedDay
            log.flow = draftFlow
            log.painLevel = draftPainLevel == 0 ? nil : draftPainLevel
            log.deletedAt = nil
            log.updatedAt = now

            let wasExistingLog = context.currentLog != nil
            try await store.saveLog(log)
            statusMessage = wasExistingLog
                ? String(localized: "menstrual_status_updated")
                : String(localized: "menstrual_status_saved")
            await load(preserveStatus: true)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteCurrentLog() async {
        guard let currentLog else { return }

        isSaving = true
        defer { isSaving = false }

        do {
            try await store.deleteLog(id: currentLog.id)
            statusMessage = String(localized: "menstrual_status_deleted")
            await load(preserveStatus: true)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func formattedHistoryDate(_ rawDate: String) -> String {
        if let parsedDate = DiaryDateFormatter.parseDate(rawDate) {
            return Self.historyDateFormatter.string(from: parsedDate)
        }
        return rawDate
    }

    func summary(for log: MenstrualLog) -> String {
        Self.sharedSummary(flow: log.flow, painLevel: log.painLevel)
    }

    private func load(preserveStatus: Bool) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let context = try await store.fetchContext(date: selectedDay)
            activeUserId = context.userId
            trackingEnabled = context.trackingEnabled
            syncEnabled = context.syncEnabled
            currentLog = context.currentLog
            recentLogs = context.recentLogs
            draftFlow = context.currentLog?.flow
            draftPainLevel = context.currentLog?.painLevel ?? 0
            if !preserveStatus {
                statusMessage = nil
            }
        } catch {
            activeUserId = nil
            currentLog = nil
            recentLogs = []
            draftFlow = nil
            draftPainLevel = 0
            syncEnabled = false
            trackingEnabled = false
            if !preserveStatus {
                statusMessage = error.localizedDescription
            }
        }
    }

    private static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    nonisolated static func sharedSummary(flow: MenstrualFlow?, painLevel: Int?) -> String {
        var components: [String] = []
        if let flow {
            components.append(flow.localizedTitle)
        }
        if let painLevel, painLevel > 0 {
            components.append(String(format: String(localized: "menstrual_pain_value_format"), painLevel))
        }
        if components.isEmpty {
            return String(localized: "menstrual_status_empty")
        }
        return components.joined(separator: " • ")
    }
}

private extension MenstrualFlow {
    static let allCases: [MenstrualFlow] = [.spotting, .light, .medium, .heavy]

    var localizedTitle: String {
        switch self {
        case .spotting:
            return String(localized: "menstrual_flow_spotting")
        case .light:
            return String(localized: "menstrual_flow_light")
        case .medium:
            return String(localized: "menstrual_flow_medium")
        case .heavy:
            return String(localized: "menstrual_flow_heavy")
        }
    }
}

#if DEBUG
extension MenstrualDayViewModel {
    static func _testSummary(flow: MenstrualFlow?, painLevel: Int?) -> String {
        sharedSummary(flow: flow, painLevel: painLevel)
    }

    func _testOverrideState(
        userId: UUID?,
        currentLog: MenstrualLog?,
        recentLogs: [MenstrualLog],
        trackingEnabled: Bool,
        syncEnabled: Bool,
        statusMessage: String?,
        isLoading: Bool,
        isSaving: Bool
    ) {
        activeUserId = userId
        self.currentLog = currentLog
        self.recentLogs = recentLogs
        self.trackingEnabled = trackingEnabled
        self.syncEnabled = syncEnabled
        self.statusMessage = statusMessage
        self.isLoading = isLoading
        self.isSaving = isSaving
        draftFlow = currentLog?.flow
        draftPainLevel = currentLog?.painLevel ?? 0
    }
}
#endif
