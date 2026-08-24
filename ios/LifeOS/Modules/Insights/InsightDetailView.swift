import SwiftUI
import Observation
import GRDB

private struct ExperimentSchedule: Sendable {
    let startDate: String
    let endDate: String
    let baselineStartDate: String
    let baselineEndDate: String
    let baselineDurationDays: Int
    let interventionStartDate: String
    let interventionEndDate: String
    let interventionDurationDays: Int
    let washoutStartDate: String?
    let washoutEndDate: String?
    let washoutDurationDays: Int?

    var durationDays: Int {
        baselineDurationDays + interventionDurationDays + (washoutDurationDays ?? 0)
    }
}

private struct ExperimentCreateRequest: Encodable, Sendable {
    let id: UUID
    let title: String
    let hypothesis: String
    let variable: String
    let controlDescription: String?
    let interventionDescription: String?
    let baselineDurationDays: Int
    let interventionDurationDays: Int
    let washoutDurationDays: Int?
    let primaryMetric: String
    let secondaryMetrics: [String]?
    let measurementFrequency: MeasurementFrequency?
    let reminderTime: String?
    let userNotes: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case hypothesis
        case variable
        case controlDescription = "control_description"
        case interventionDescription = "intervention_description"
        case baselineDurationDays = "baseline_duration_days"
        case interventionDurationDays = "intervention_duration_days"
        case washoutDurationDays = "washout_duration_days"
        case primaryMetric = "primary_metric"
        case secondaryMetrics = "secondary_metrics"
        case measurementFrequency = "measurement_frequency"
        case reminderTime = "reminder_time"
        case userNotes = "user_notes"
    }
}

private struct ExperimentLogRequest: Encodable, Sendable {
    let id: UUID
    let date: String
    let measurements: [String: Double]
    let notes: String?
    let protocolFollowed: Bool
    let metricUnit: String?

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case measurements
        case notes
        case protocolFollowed = "protocol_followed"
        case metricUnit = "metric_unit"
    }
}

private enum ExperimentStartAvailability: Equatable {
    case available
    case needsMoreData
    case requiresCloudSession
    case activeExperiment(existingId: UUID)

    var message: String? {
        switch self {
        case .available:
            return nil
        case .needsMoreData:
            return String(localized: "experiments_start_unavailable_low_confidence")
        case .requiresCloudSession:
            return String(localized: "experiments_start_unavailable_offline")
        case .activeExperiment(let existingId):
            return ExperimentError.alreadyActive(existingId: existingId).errorDescription
        }
    }

    var isBlockingWarning: Bool {
        switch self {
        case .available:
            return false
        case .needsMoreData, .activeExperiment:
            return true
        case .requiresCloudSession:
            return false
        }
    }
}

struct InsightDetailView: View {
    let insightId: UUID
    @State private var viewModel: InsightDetailViewModel

    init(insightId: UUID) {
        self.insightId = insightId
        _viewModel = State(initialValue: InsightDetailViewModel(insightId: insightId))
    }

#if DEBUG
    fileprivate init(insightId: UUID, testViewModel: InsightDetailViewModel) {
        self.insightId = insightId
        _viewModel = State(initialValue: testViewModel)
    }
#endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if let insight = viewModel.insight {
                    Label(insight.title, systemImage: "lightbulb.max")
                        .font(LifeOSTypography.title3)
                        .foregroundStyle(LifeOSColors.Semantic.primary)

                    Text("\(String(localized: "insights_category_prefix")) \(viewModel.localizedCategory(insight.category))")
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)

                    Text("\(String(localized: "insights_confidence_prefix")) \(Int((insight.confidence * 100).rounded()))%")
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(String(localized: "insights_confidence_prefix")) \(Int((insight.confidence * 100).rounded())) percent")

                    if insight.requiresReview {
                        Text(String(localized: "insights_review_required_message"))
                            .font(LifeOSTypography.footnote)
                            .foregroundStyle(LifeOSColors.Recovery.caution)
                    }

                    Text(insight.bodyWithClinicianCaveat)
                        .font(LifeOSTypography.body)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)

                    if let reasoning = insight.reasoning, !reasoning.isEmpty {
                        Text(reasoning)
                            .font(LifeOSTypography.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    // Privacy: AI cache expiry
                    PrivacyNoteView(.aiCacheExpiry)
                        .padding(.top, Spacing.xs)

                    if insight.category == .experiment {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            if viewModel.canStartExperiment {
                                Button {
                                    Task { await viewModel.startExperiment() }
                                } label: {
                                    Label(String(localized: "insights_start_experiment"), systemImage: "flask")
                                        .font(LifeOSTypography.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, Spacing.s)
                                }
                                .buttonStyle(.bordered)
                                .disabled(viewModel.isStartingExperiment)
                                .accessibilityIdentifier("insights.detail.start_experiment")
                            }

                            if let message = viewModel.startExperimentAvailabilityMessage {
                                Text(message)
                                    .font(LifeOSTypography.footnote)
                                    .foregroundStyle(
                                        viewModel.startExperimentAvailabilityIsWarning
                                        ? AnyShapeStyle(LifeOSColors.Recovery.caution)
                                        : AnyShapeStyle(.secondary)
                                    )
                            }

                            if let error = viewModel.startExperimentError {
                                Text(error)
                                    .font(LifeOSTypography.footnote)
                                    .foregroundStyle(LifeOSColors.Recovery.caution)
                            }
                        }
                        .padding(.horizontal, LayoutConstants.contentPadding)
                    }
                } else if let loadError = viewModel.loadError {
                    Text(loadError)
                        .font(LifeOSTypography.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(localized: "insights_detail_not_found"))
                        .font(LifeOSTypography.body)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(LayoutConstants.contentPadding)
        }
        .accessibilityIdentifier("insights.detail.screen")
        .background(LifeOSColors.Surface.background)
        .navigationTitle(String(localized: "tab_insights"))
        .task(loadInsightTask)
    }

    private func loadInsightTask() async {
        await viewModel.loadInsight()
#if os(iOS)
        await PushNotificationManager.shared.evaluateDelayedAuthorizationPromptIfEligible()
#endif
    }
}

#if DEBUG
extension InsightDetailView {
    @MainActor
    func _testRunLoadInsightTask() async {
        await loadInsightTask()
    }
}
#endif

@MainActor
@Observable
private final class InsightDetailViewModel {
    let insightId: UUID

    var insight: Insight?
    var loadError: String?
    var isStartingExperiment = false
    var startExperimentError: String?
    private var activeExperimentId: UUID?
    private let dbQueue: DatabaseQueue

    init(insightId: UUID, dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue) {
        self.insightId = insightId
        self.dbQueue = dbQueue
    }

    var canStartExperiment: Bool {
        startExperimentAvailability == .available
    }

    var startExperimentAvailabilityMessage: String? {
        startExperimentAvailability.message
    }

    var startExperimentAvailabilityIsWarning: Bool {
        startExperimentAvailability.isBlockingWarning
    }

    func loadInsight() async {
        let authId = AuthManager.activeAuthId?.uuidString
        do {
            let loadedState = try await dbQueue.read { [insightId] db -> (insight: Insight?, activeExperimentId: UUID?) in
                let insight = try Insight
                    .filter(sql: "id = ? OR id = ?", arguments: [insightId, insightId.uuidString])
                    .fetchOne(db)
                let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db)
                let activeExperimentId = try Self.activeExperimentId(for: userId, in: db)
                return (insight, activeExperimentId)
            }
            insight = loadedState.insight
            activeExperimentId = loadedState.activeExperimentId
            loadError = nil
            startExperimentError = nil
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription
                ?? SyncError.serverError(code: 0, message: nil).errorDescription
        }
    }

    func startExperiment() async {
        guard let insight else { return }
        guard canStartExperiment else {
            startExperimentError = startExperimentAvailability.message
            return
        }

        isStartingExperiment = true
        defer { isStartingExperiment = false }

        let experimentId = UUID()
        let now = Date()
        let authId = AuthManager.activeAuthId?.uuidString
        let primaryMetric = Self.defaultPrimaryMetric(for: insight)
        let schedule = Self.makeSchedule(startingOn: now, baselineDays: 7, interventionDays: 14, washoutDays: 0)

        do {
            try await dbQueue.write { db in
                guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                    throw ExperimentError.invalidProtocol(reason: "Missing user identity")
                }
                if let existingId = try Self.activeExperimentId(for: userId, in: db) {
                    throw ExperimentError.alreadyActive(existingId: existingId)
                }

                var experiment = Experiment(
                    id: experimentId,
                    userId: userId,
                    title: insight.title,
                    variable: insight.title,
                    metric: primaryMetric,
                    durationDays: schedule.durationDays
                )
                experiment.hypothesis = insight.description ?? insight.body
                experiment.status = .baseline
                experiment.primaryMetric = primaryMetric
                experiment.measurementFrequency = .daily
                experiment.startDate = schedule.startDate
                experiment.endDate = schedule.endDate
                experiment.baselineStartDate = schedule.baselineStartDate
                experiment.baselineEndDate = schedule.baselineEndDate
                experiment.baselineDurationDays = schedule.baselineDurationDays
                experiment.interventionStartDate = schedule.interventionStartDate
                experiment.interventionEndDate = schedule.interventionEndDate
                experiment.interventionDurationDays = schedule.interventionDurationDays
                experiment.washoutStartDate = schedule.washoutStartDate
                experiment.washoutEndDate = schedule.washoutEndDate
                experiment.washoutDurationDays = schedule.washoutDurationDays
                experiment.notes = insight.body
                experiment.userNotes = insight.body
                try experiment.insert(db)

                let payload = ExperimentCreateRequest(
                    id: experiment.id,
                    title: experiment.title,
                    hypothesis: experiment.hypothesis ?? insight.body,
                    variable: experiment.variable,
                    controlDescription: experiment.controlDescription,
                    interventionDescription: experiment.interventionDescription,
                    baselineDurationDays: schedule.baselineDurationDays,
                    interventionDurationDays: schedule.interventionDurationDays,
                    washoutDurationDays: schedule.washoutDurationDays,
                    primaryMetric: primaryMetric,
                    secondaryMetrics: experiment.secondaryMetrics,
                    measurementFrequency: experiment.measurementFrequency,
                    reminderTime: experiment.reminderTime,
                    userNotes: experiment.userNotes
                )
                var event = OutboxEvent(
                    id: experiment.id,
                    httpMethod: .POST,
                    path: "api-experiments/create",
                    bodyJson: try JSONEncoder.supabase.encode(payload),
                    priority: 100
                )
                event.headersJson = try Self.outboxHeadersJson()
                try event.insert(db)
            }
            activeExperimentId = experimentId
            startExperimentError = nil
        } catch {
            startExperimentError = (error as? LocalizedError)?.errorDescription
                ?? SyncError.serverError(code: 0, message: nil).errorDescription
        }
    }

    private static func defaultPrimaryMetric(for insight: Insight) -> String {
        if let relatedMetrics = insight.relatedMetrics,
           let metrics = try? JSONDecoder().decode([String].self, from: relatedMetrics),
           let firstMetric = metrics.first,
           !firstMetric.isEmpty {
            return firstMetric
        }
        return String(localized: "experiment_metric")
    }

    nonisolated private static func outboxHeadersJson() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
    }

    private var startExperimentAvailability: ExperimentStartAvailability {
        guard let insight, insight.category == .experiment else {
            return .requiresCloudSession
        }
        if insight.confidence < LifeOSConstants.lowConfidenceThreshold {
            return .needsMoreData
        }
        if !AuthManager.activeHasCloudSession {
            return .requiresCloudSession
        }
        if let activeExperimentId {
            return .activeExperiment(existingId: activeExperimentId)
        }
        return .available
    }

    nonisolated private static func activeExperimentId(for userId: UUID?, in db: Database) throws -> UUID? {
        guard let userId else { return nil }
        let experiments = try Experiment
            .filter(sql: "deleted_at IS NULL AND (user_id = ? OR user_id = ?)", arguments: [userId, userId.uuidString])
            .order(Column("created_at").desc)
            .fetchAll(db)
        let today = DiaryDateFormatter.formatDate(Date())
        return experiments.first(where: { $0.isLifecycleActive(forLocalDate: today) })?.id
    }

    private static func makeSchedule(
        startingOn date: Date,
        baselineDays: Int,
        interventionDays: Int,
        washoutDays: Int
    ) -> ExperimentSchedule {
        let calendar = Calendar(identifier: .gregorian)
        let startOfDay = calendar.startOfDay(for: date)

        func dayOffset(_ value: Int) -> String {
            let shifted = calendar.date(byAdding: .day, value: value, to: startOfDay) ?? startOfDay
            return DiaryDateFormatter.formatDate(shifted)
        }

        let baselineEndOffset = max(0, baselineDays - 1)
        let interventionStartOffset = baselineEndOffset + 1
        let interventionEndOffset = interventionStartOffset + max(0, interventionDays - 1)
        let washoutStartOffset = washoutDays > 0 ? interventionEndOffset + 1 : nil
        let washoutEndOffset = washoutStartOffset.map { $0 + max(0, washoutDays - 1) }

        return ExperimentSchedule(
            startDate: dayOffset(0),
            endDate: dayOffset(washoutEndOffset ?? interventionEndOffset),
            baselineStartDate: dayOffset(0),
            baselineEndDate: dayOffset(baselineEndOffset),
            baselineDurationDays: baselineDays,
            interventionStartDate: dayOffset(interventionStartOffset),
            interventionEndDate: dayOffset(interventionEndOffset),
            interventionDurationDays: interventionDays,
            washoutStartDate: washoutStartOffset.map(dayOffset),
            washoutEndDate: washoutEndOffset.map(dayOffset),
            washoutDurationDays: washoutDays > 0 ? washoutDays : nil
        )
    }

    func localizedCategory(_ category: InsightCategory) -> String {
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

struct ExperimentDetailView: View {
    let experimentId: UUID
    @State private var viewModel: ExperimentDetailViewModel

    init(experimentId: UUID) {
        self.experimentId = experimentId
        _viewModel = State(initialValue: ExperimentDetailViewModel(experimentId: experimentId))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.m) {
                if let loadError = viewModel.loadError {
                    Text(loadError)
                        .font(LifeOSTypography.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: Spacing.xs) {
                        Label(viewModel.experimentName, systemImage: "flask")
                            .font(LifeOSTypography.title3)
                        Text(viewModel.statusText)
                            .font(LifeOSTypography.caption)
                            .foregroundStyle(.secondary)
                        if let hypothesis = viewModel.hypothesis {
                            Text(hypothesis)
                                .font(LifeOSTypography.body)
                                .foregroundStyle(.secondary)
                                .padding(.top, Spacing.xxs)
                        }
                    }

                    if viewModel.isActive {
                        dailyLoggingSection
                    }

                    if !viewModel.measurements.isEmpty {
                        measurementsSection
                    }

                    if viewModel.isCompleted {
                        resultsSection
                    }
                }
            }
            .padding(.top, Spacing.m)
            .padding(.horizontal, LayoutConstants.contentPadding)
        }
        .background(LifeOSColors.Surface.background)
        .navigationTitle(String(localized: "experiment_detail"))
        .task { await viewModel.load() }
    }

    // MARK: - Daily Logging

    private var dailyLoggingSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(String(localized: "experiment_daily_log"))
                .font(LifeOSTypography.headline)

            // Metric value input
            HStack(spacing: Spacing.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.metricLabel)
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)
                    TextField("0", text: $viewModel.dailyValue)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.decimalPad)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "experiment_notes"))
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)
                    TextField(String(localized: "experiment_notes_placeholder"), text: $viewModel.dailyNotes)
                        .textFieldStyle(.roundedBorder)
                }
            }

            // Adherence toggle
            Toggle(String(localized: "experiment_adhered_today"), isOn: $viewModel.adheredToday)
                .font(LifeOSTypography.body)

            Button {
                Task { await viewModel.logDailyMeasurement() }
            } label: {
                Text(viewModel.hasLoggedToday
                    ? String(localized: "experiment_update_log")
                    : String(localized: "experiment_log_today"))
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.s)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.dailyValue.isEmpty || !viewModel.canLogMeasurements)

            if let logStatusMessage = viewModel.logStatusMessage {
                Text(logStatusMessage)
                    .font(LifeOSTypography.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
    }

    // MARK: - Measurements History

    private var measurementsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(String(localized: "experiment_measurements"))
                .font(LifeOSTypography.headline)

            ForEach(viewModel.measurements) { measurement in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(measurement.date)
                            .font(LifeOSTypography.body)
                        if let notes = measurement.notes, !notes.isEmpty {
                            Text(notes)
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(measurement.value)
                        .font(LifeOSTypography.headline)
                    if measurement.adhered {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(LifeOSColors.Recovery.ready)
                    }
                }
                .padding(Spacing.s)
                .background(LifeOSColors.Surface.card)
                .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
            }
        }
    }

    // MARK: - Results

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(String(localized: "experiment_results"), systemImage: "chart.bar")
                .font(LifeOSTypography.headline)

            if let conclusion = viewModel.conclusion {
                Text(conclusion)
                    .font(LifeOSTypography.body)
            }

            HStack(spacing: Spacing.l) {
                VStack {
                    Text(viewModel.baselineValue)
                        .font(LifeOSTypography.headline)
                    Text(String(localized: "experiment_baseline"))
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)
                }
                VStack {
                    Text(viewModel.endValue)
                        .font(LifeOSTypography.headline)
                    Text(String(localized: "experiment_end_value"))
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)
                }
                VStack {
                    Text(viewModel.changeText)
                        .font(LifeOSTypography.headline)
                        .foregroundStyle(viewModel.changeIsPositive ? LifeOSColors.Recovery.ready : LifeOSColors.Recovery.caution)
                    Text(String(localized: "experiment_change"))
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
    }
}

// MARK: - Experiment Detail ViewModel

@MainActor
@Observable
final class ExperimentDetailViewModel {
    let experimentId: UUID
    var experimentName = ""
    var statusText = ""
    var hypothesis: String?
    var isActive = false
    var isCompleted = false
    var metricLabel = ""
    var measurements: [ExperimentMeasurementRow] = []
    var dailyValue = ""
    var dailyNotes = ""
    var adheredToday = true
    var hasLoggedToday = false
    var loadError: String?
    var logStatusMessage: String?
    var conclusion: String?
    var baselineValue = "—"
    var endValue = "—"
    var changeText = "—"
    var changeIsPositive = true
    private let dbQueue: DatabaseQueue

    init(experimentId: UUID, dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue) {
        self.experimentId = experimentId
        self.dbQueue = dbQueue
    }

    var canLogMeasurements: Bool {
        AuthManager.activeHasCloudSession
    }

    func load() async {
        do {
            let loadedState = try await dbQueue.read { [experimentId] db -> (
                experiment: Experiment,
                measurements: [ExperimentMeasurementRow]
            )? in
                guard let experiment = try Experiment
                    .filter(sql: "id = ? OR id = ?", arguments: [experimentId, experimentId.uuidString])
                    .fetchOne(db) else {
                    return nil
                }

                let measurementRows = try ExperimentMeasurement
                    .filter(sql: "experiment_id = ? OR experiment_id = ?", arguments: [experimentId, experimentId.uuidString])
                    .order(Column("measurement_date").desc, Column("created_at").desc)
                    .fetchAll(db)

                let parsed = measurementRows.map { measurement in
                    let loggedDate = measurement.measurementDate ?? measurement.date
                    let metricValue = measurement.metricValue ?? measurement.value
                    return ExperimentMeasurementRow(
                        id: measurement.id,
                        date: loggedDate,
                        value: String(format: "%.1f", metricValue),
                        notes: measurement.notes,
                        adhered: measurement.protocolFollowed
                    )
                }
                return (
                    experiment: experiment,
                    measurements: parsed
                )
            }

            guard let loadedState else {
                resetLoadedState(error: ExperimentError.notFound.errorDescription)
                return
            }

            let today = DiaryDateFormatter.formatDate(Date())
            let resolvedStatus = loadedState.experiment.resolvedLifecycleStatus(forLocalDate: today)

            experimentName = loadedState.experiment.title
            statusText = resolvedStatus.rawValue.capitalized
            hypothesis = loadedState.experiment.hypothesis
            metricLabel = loadedState.experiment.primaryMetric ?? loadedState.experiment.metric
            isActive = Self.isLifecycleActiveStatus(resolvedStatus)
            isCompleted = resolvedStatus == .completed
            conclusion = loadedState.experiment.resultSummary
            measurements = loadedState.measurements

            hasLoggedToday = loadedState.measurements.contains { $0.date == today }

            if let first = loadedState.measurements.last, let last = loadedState.measurements.first {
                baselineValue = first.value
                endValue = last.value
                if let fv = Double(first.value), let lv = Double(last.value), fv != 0 {
                    let change = ((lv - fv) / fv) * 100
                    changeText = String(format: "%+.1f%%", change)
                    changeIsPositive = change >= 0
                }
            }
            loadError = nil
            logStatusMessage = nil
        } catch {
            resetLoadedState(
                error: (error as? LocalizedError)?.errorDescription
                    ?? SyncError.serverError(code: 0, message: nil).errorDescription
            )
        }
    }

    func logDailyMeasurement() async {
        guard canLogMeasurements else {
            logStatusMessage = String(localized: "experiments_start_unavailable_offline")
            return
        }

        let today = DiaryDateFormatter.formatDate(Date())
        let value = Double(dailyValue) ?? 0
        let now = Date()

        do {
            try await dbQueue.write { [experimentId, adheredToday, dailyNotes] db in
                guard let experiment = try Experiment
                    .filter(sql: "id = ? OR id = ?", arguments: [experimentId, experimentId.uuidString])
                    .fetchOne(db) else {
                    throw ExperimentError.notFound
                }

                let metricName = experiment.primaryMetric ?? experiment.metric
                let resolvedStatus = experiment.resolvedLifecycleStatus(forLocalDate: today)
                guard Self.isLifecycleActiveStatus(resolvedStatus) else {
                    throw ExperimentError.invalidProtocol(reason: "Experiment is no longer active")
                }
                let measurementPhase = experiment.scheduledPhase(forLocalDate: today)
                    ?? Self.measurementPhase(for: resolvedStatus)
                let notes = dailyNotes.isEmpty ? nil : dailyNotes
                let payload: ExperimentMeasurement

                if var existingMeasurement = try ExperimentMeasurement
                    .filter(sql: "experiment_id = ? OR experiment_id = ?", arguments: [experimentId, experimentId.uuidString])
                    .filter(Column("measurement_date") == today)
                    .filter(Column("metric_name") == metricName)
                    .fetchOne(db) {
                    existingMeasurement.metricValue = value
                    existingMeasurement.value = value
                    existingMeasurement.notes = notes
                    existingMeasurement.protocolFollowed = adheredToday
                    existingMeasurement.measurementPhase = measurementPhase
                    existingMeasurement.updatedAt = now
                    try existingMeasurement.update(db)
                    payload = existingMeasurement
                } else {
                    var measurement = ExperimentMeasurement(
                        experimentId: experimentId,
                        userId: experiment.userId,
                        date: today,
                        value: value,
                        unit: nil,
                        measurementPhase: measurementPhase,
                        metricName: metricName
                    )
                    measurement.measurementDate = today
                    measurement.metricValue = value
                    measurement.notes = notes
                    measurement.protocolFollowed = adheredToday
                    measurement.createdAt = now
                    measurement.updatedAt = now
                    try measurement.insert(db)
                    payload = measurement
                }

                let request = ExperimentLogRequest(
                    id: payload.id,
                    date: today,
                    measurements: [metricName: value],
                    notes: notes,
                    protocolFollowed: adheredToday,
                    metricUnit: payload.metricUnit ?? payload.unit
                )
                try Self.upsertLogOutboxEvent(
                    experimentId: experimentId,
                    measurementId: payload.id,
                    path: "api-experiments/\(experimentId.uuidString)/log",
                    bodyJson: try JSONEncoder.supabase.encode(request),
                    headersJson: try Self.outboxHeadersJson(),
                    in: db
                )
            }
            hasLoggedToday = true
            logStatusMessage = nil
            await load()
        } catch {
            if let experimentError = error as? ExperimentError, case .notFound = experimentError {
                await load()
            }
            logStatusMessage = (error as? LocalizedError)?.errorDescription
                ?? SyncError.serverError(code: 0, message: nil).errorDescription
        }
    }

    private func resetLoadedState(error: String?) {
        experimentName = ""
        statusText = ""
        hypothesis = nil
        isActive = false
        isCompleted = false
        metricLabel = ""
        measurements = []
        dailyValue = ""
        dailyNotes = ""
        adheredToday = true
        hasLoggedToday = false
        loadError = error
        logStatusMessage = nil
        conclusion = nil
        baselineValue = "—"
        endValue = "—"
        changeText = "—"
        changeIsPositive = true
    }

    nonisolated private static func isLifecycleActiveStatus(_ status: ExperimentStatus) -> Bool {
        ExperimentStatus.lifecycleActiveStatuses.contains(status)
    }

    nonisolated private static func measurementPhase(for status: ExperimentStatus) -> ExperimentPhase {
        switch status {
        case .intervention:
            return .intervention
        case .washout:
            return .washout
        default:
            return .baseline
        }
    }

    nonisolated private static func outboxHeadersJson() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
    }

    nonisolated private static func upsertLogOutboxEvent(
        experimentId: UUID,
        measurementId: UUID,
        path: String,
        bodyJson: Data,
        headersJson: Data,
        in db: Database
    ) throws {
        let dependency = try createDependencyIfNeeded(for: experimentId, in: db)

        if let existingStatusRaw = try String.fetchOne(
            db,
            sql: "SELECT status FROM outbox_events WHERE id = ? OR id = ? LIMIT 1",
            arguments: [measurementId, measurementId.uuidString]
        ), let existingStatus = OutboxStatus(rawValue: existingStatusRaw) {
            if existingStatus == .inFlight {
                var event = OutboxEvent(
                    httpMethod: .POST,
                    path: path,
                    bodyJson: bodyJson,
                    priority: 101
                )
                event.headersJson = headersJson
                try event.insert(db)
                return
            }

            try db.execute(
                sql: """
                    UPDATE outbox_events
                    SET status = ?,
                        priority = ?,
                        depends_on = ?,
                        http_method = ?,
                        path = ?,
                        headers_json = ?,
                        body_json = ?,
                        idempotency_key = ?,
                        attempt_count = 0,
                        next_attempt_at = NULL,
                        last_attempt_at = NULL,
                        last_error_category = NULL,
                        last_error_code = NULL,
                        last_error_message = NULL,
                        user_visible_blocker = 0,
                        updated_at_local = ?
                    WHERE id = ? OR id = ?
                    """,
                arguments: [
                    OutboxStatus.pending.rawValue,
                    101,
                    dependency,
                    HTTPMethod.POST.rawValue,
                    path,
                    headersJson,
                    bodyJson,
                    UUID().uuidString,
                    Date(),
                    measurementId,
                    measurementId.uuidString,
                ]
            )
            return
        }

        var event = OutboxEvent(
            id: measurementId,
            httpMethod: .POST,
            path: path,
            bodyJson: bodyJson,
            priority: 101
        )
        event.dependsOn = dependency
        event.headersJson = headersJson
        try event.insert(db)
    }

    nonisolated private static func createDependencyIfNeeded(for experimentId: UUID, in db: Database) throws -> UUID? {
        let createEventStatus = try String.fetchOne(
            db,
            sql: """
                SELECT status
                FROM outbox_events
                WHERE (id = ? OR id = ?)
                  AND path = ?
                LIMIT 1
                """,
            arguments: [experimentId, experimentId.uuidString, "api-experiments/create"]
        )
        guard let createEventStatus,
              createEventStatus != OutboxStatus.cancelled.rawValue,
              createEventStatus != OutboxStatus.failedPermanent.rawValue,
              createEventStatus != OutboxStatus.succeeded.rawValue else {
            return nil
        }
        return experimentId
    }
}

struct ExperimentMeasurementRow: Identifiable {
    let id: UUID
    let date: String
    let value: String
    let notes: String?
    let adhered: Bool
}

#if DEBUG
@MainActor
enum InsightDetailViewTestHarness {
    static func localizedCategories() -> [String] {
        let viewModel = InsightDetailViewModel(insightId: UUID())
        return [
            viewModel.localizedCategory(.recovery),
            viewModel.localizedCategory(.nutrition),
            viewModel.localizedCategory(.training),
            viewModel.localizedCategory(.sleep),
            viewModel.localizedCategory(.supplement),
            viewModel.localizedCategory(.health),
            viewModel.localizedCategory(.experiment),
            viewModel.localizedCategory(.general),
        ]
    }

    static func exerciseBodyBranches() {
        let loaded = Insight(
            userId: UUID(),
            category: .recovery,
            title: "Test",
            body: "Body",
            confidence: 0.42
        )
        var loadedWithReasoning = loaded
        loadedWithReasoning.reasoning = "Because"

        let loadedVM = InsightDetailViewModel(insightId: loaded.id)
        loadedVM.insight = loadedWithReasoning
        _ = InsightDetailView(insightId: loaded.id, testViewModel: loadedVM).body

        let errorVM = InsightDetailViewModel(insightId: UUID())
        errorVM.loadError = "Load error"
        _ = InsightDetailView(insightId: UUID(), testViewModel: errorVM).body

        let emptyVM = InsightDetailViewModel(insightId: UUID())
        _ = InsightDetailView(insightId: UUID(), testViewModel: emptyVM).body
    }

    static func loadInsightResult(insightId: UUID) async -> (insight: Insight?, loadError: String?) {
        let viewModel = InsightDetailViewModel(insightId: insightId)
        await viewModel.loadInsight()
        return (viewModel.insight, viewModel.loadError)
    }

    static func startExperiment(
        insight: Insight,
        authId: UUID?,
        hasCloudSession: Bool = true,
        dbQueue: DatabaseQueue
    ) async {
        AuthManager.setActiveAuthIdForTests(authId)
        AuthManager._testSetActiveHasCloudSession(hasCloudSession)
        defer {
            AuthManager.setActiveAuthIdForTests(nil)
            AuthManager._testSetActiveHasCloudSession(false)
        }

        let viewModel = InsightDetailViewModel(insightId: insight.id, dbQueue: dbQueue)
        viewModel.insight = insight
        await viewModel.startExperiment()
    }

    static func exerciseExperimentDetailBody() {
        _ = ExperimentDetailView(experimentId: UUID()).body
    }
}
#endif
