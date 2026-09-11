import SwiftUI
import Observation
import GRDB

struct RecoveryDetailView: View {
    let dateString: String?
    @State private var viewModel: RecoveryDetailViewModel

    init(dateString: String?) {
        self.dateString = dateString
        _viewModel = State(initialValue: RecoveryDetailViewModel(dateString: dateString))
    }

#if DEBUG
    fileprivate init(dateString: String?, testViewModel: RecoveryDetailViewModel) {
        self.dateString = dateString
        _viewModel = State(initialValue: testViewModel)
    }
#endif

    var body: some View {
        let sleepSnapshot = viewModel.sleepSnapshot ?? Self.placeholderSnapshot(for: viewModel.currentDay)

        ScrollView {
            VStack(spacing: Spacing.m) {
                Label(String(localized: "recovery_score"), systemImage: "heart.text.square")
                    .font(LifeOSTypography.title3)

                Text(viewModel.displayDate)
                    .font(LifeOSTypography.subheadline)
                    .foregroundStyle(.secondary)

                if viewModel.isLoading && viewModel.score == nil && viewModel.sleepSnapshot == nil {
                    ProgressView()
                } else if let score = viewModel.score {
                    recoveryScoreCard(score)
                } else {
                    Text(String(localized: "recovery_connect_health"))
                        .font(LifeOSTypography.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(Spacing.m)
                        .background(LifeOSColors.Surface.card)
                        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
                }

                if let cycleNote = viewModel.cycleNoteText {
                    Label(cycleNote, systemImage: "calendar")
                        .font(LifeOSTypography.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.m)
                        .background(LifeOSColors.Surface.card)
                        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
                        .accessibilityIdentifier("recovery.cycle_note")
                }

                if let hrvCaveat = viewModel.hrvCaveatText {
                    Label(hrvCaveat, systemImage: "waveform.path.ecg.rectangle")
                        .font(LifeOSTypography.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.m)
                        .background(LifeOSColors.Surface.card)
                        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
                        .accessibilityIdentifier("recovery.hrv_caveat")
                }

                SleepDetailSections(
                    snapshot: sleepSnapshot,
                    permissionState: viewModel.sleepPermissionState,
                    isRequestingAccess: viewModel.isRequestingSleepAccess,
                    statusMessage: viewModel.sleepStatusMessage,
                    onRequestAccess: viewModel.sleepPermissionState.canRequestAccess ? {
                        Task { await viewModel.requestSleepAccess() }
                    } : nil
                )
            }
            .padding(LayoutConstants.contentPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LifeOSColors.Surface.background)
        .navigationTitle(String(localized: "recovery_score"))
        .task(viewModel.load)
    }

    private func recoveryScoreCard(_ score: RecoverySummary) -> some View {
        VStack(spacing: Spacing.xs) {
            Text("\(Int(score.value.rounded()))")
                .font(LifeOSTypography.metricMedium)
                .foregroundStyle(score.zone.color)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Text(score.zone.label)
                .font(LifeOSTypography.body)

            if let confidencePercent = score.confidencePercent {
                Text("\(confidencePercent)%")
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.m)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(score.accessibilitySummary)
    }

    private static func placeholderSnapshot(for day: String) -> SleepDetailSnapshot {
        let date = DiaryDateFormatter.parseDate(day) ?? Date()
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
final class RecoveryDetailViewModel {
    fileprivate var score: RecoverySummary?
    private(set) var sleepSnapshot: SleepDetailSnapshot?
    private(set) var sleepPermissionState: SleepPermissionState = .unavailable
    private(set) var isLoading = false
    private(set) var isRequestingSleepAccess = false
    private(set) var sleepStatusMessage: String?
    private(set) var cycleNoteText: String?
    private(set) var hrvCaveatText: String?

    let displayDate: String
    let currentDay: String
    private let dbQueue: DatabaseQueue

    init(
        dateString: String?,
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue
    ) {
        self.currentDay = RecoveryDetailViewModel.resolvedDay(dateString)
        self.displayDate = dateString ?? self.currentDay
        self.dbQueue = dbQueue
    }

    func load() async {
        isLoading = true
        sleepPermissionState = SleepHealthKitAccessCoordinator.currentPermissionState()
        sleepStatusMessage = nil
        defer { isLoading = false }

        do {
            let authId = AuthManager.activeAuthId?.uuidString
            let loaded = try await dbQueue.read { db -> (score: RecoverySummary?, phase: MenstrualPhase?) in
                guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                    return (nil, nil)
                }
                var derivedPhase: MenstrualPhase?
                let trackingEnabled = try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT menstrual_tracking_enabled
                        FROM user_health_flags
                        WHERE (user_id = ? OR user_id = ?)
                        ORDER BY updated_at DESC
                        LIMIT 1
                        """,
                    arguments: [userId, userId.uuidString]
                ) ?? false
                if trackingEnabled {
                    let flowDates = try String.fetchAll(
                        db,
                        sql: """
                            SELECT DISTINCT date
                            FROM menstrual_logs
                            WHERE (user_id = ? OR user_id = ?)
                              AND deleted_at IS NULL
                              AND flow IS NOT NULL
                              AND flow <> 'spotting'
                            """,
                        arguments: [userId, userId.uuidString]
                    )
                    derivedPhase = MenstrualCycleAdjustment
                        .derivePhase(flowDates: flowDates, on: currentDay)?
                        .phase
                }
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT recovery_score, recovery_zone, confidence_score
                        FROM physiological_states
                        WHERE (user_id = ? OR user_id = ?)
                          AND date = ?
                        LIMIT 1
                        """,
                    arguments: [userId, userId.uuidString, currentDay]
                ) else {
                    return (nil, derivedPhase)
                }
                return (RecoverySummary(row: row), derivedPhase)
            }
            score = loaded.score
            cycleNoteText = loaded.phase.map {
                String(localized: String.LocalizationValue($0.noteKey))
            }
            let onBetaBlockers = try await dbQueue.read { db -> Bool in
                guard let userId = try UserIdentityLookup.resolveUserId(authId: authId, db: db) else {
                    return false
                }
                return try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT on_beta_blockers
                        FROM user_health_flags
                        WHERE (user_id = ? OR user_id = ?)
                        ORDER BY updated_at DESC
                        LIMIT 1
                        """,
                    arguments: [userId, userId.uuidString]
                ) ?? false
            }
            hrvCaveatText = onBetaBlockers
                ? String(localized: "recovery_hrv_beta_blocker_note")
                : nil
        } catch {
            score = nil
            cycleNoteText = nil
            hrvCaveatText = nil
        }

        do {
            sleepSnapshot = try await SleepDetailLoader.load(day: currentDay, dbQueue: dbQueue)
        } catch {
            sleepSnapshot = nil
            sleepStatusMessage = error.localizedDescription
        }
    }

    func requestSleepAccess() async {
        isRequestingSleepAccess = true
        defer { isRequestingSleepAccess = false }

        do {
            try await SleepHealthKitAccessCoordinator.requestAccessAndBackfill(dbQueue: dbQueue)
            sleepStatusMessage = NSLocalizedString(
                "sleep.access_updated",
                value: "Sleep access updated. Recent data is syncing now.",
                comment: "Sleep detail success message after HealthKit access is updated"
            )
        } catch {
            sleepStatusMessage = error.localizedDescription
        }

        sleepPermissionState = SleepHealthKitAccessCoordinator.currentPermissionState()
        await load()
    }

    private static func resolvedDay(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return DiaryDateFormatter.formatDate(Date())
        }
        return value
    }

#if DEBUG
    fileprivate func _testOverrideState(score: RecoverySummary?, isLoading: Bool) {
        self.score = score
        self.sleepSnapshot = nil
        self.isLoading = isLoading
    }
#endif
}

struct RecoverySummary {
    let value: Double
    let zone: RecoveryZone
    let confidencePercent: Int?
    let accessibilitySummary: String

    init?(row: Row) {
        guard let value: Double = row["recovery_score"] else { return nil }
        self.value = value
        if let zoneRaw: String = row["recovery_zone"],
           let zone = RecoveryZone(rawValue: zoneRaw) {
            self.zone = zone
        } else {
            self.zone = RecoveryZone.from(score: value)
        }
        let confidence: Double? = row["confidence_score"]
        self.confidencePercent = confidence.map { Int(($0 * 100).rounded()) }

        if let confidencePercent {
            accessibilitySummary = "\(zone.label), \(Int(value.rounded())), \(confidencePercent)%"
        } else {
            accessibilitySummary = "\(zone.label), \(Int(value.rounded()))"
        }
    }
}

#if DEBUG
private extension RecoverySummary {
    init(testValue: Double, testZone: RecoveryZone, testConfidencePercent: Int?) {
        value = testValue
        zone = testZone
        confidencePercent = testConfidencePercent
        if let testConfidencePercent {
            accessibilitySummary = "\(testZone.label), \(Int(testValue.rounded())), \(testConfidencePercent)%"
        } else {
            accessibilitySummary = "\(testZone.label), \(Int(testValue.rounded()))"
        }
    }
}

@MainActor
enum RecoveryDetailViewTestHarness {
    static func exerciseBodyBranches() {
        let loadingVM = RecoveryDetailViewModel(dateString: "2026-02-24")
        loadingVM._testOverrideState(score: nil, isLoading: true)
        _ = RecoveryDetailView(dateString: "2026-02-24", testViewModel: loadingVM).body

        let emptyVM = RecoveryDetailViewModel(dateString: "2026-02-24")
        emptyVM._testOverrideState(score: nil, isLoading: false)
        _ = RecoveryDetailView(dateString: "2026-02-24", testViewModel: emptyVM).body

        let loadedVM = RecoveryDetailViewModel(dateString: "2026-02-24")
        loadedVM._testOverrideState(
            score: RecoverySummary(testValue: 74, testZone: .ready, testConfidencePercent: 82),
            isLoading: false
        )
        _ = RecoveryDetailView(dateString: "2026-02-24", testViewModel: loadedVM).body

        let loadedWithoutConfidenceVM = RecoveryDetailViewModel(dateString: "2026-02-24")
        loadedWithoutConfidenceVM._testOverrideState(
            score: RecoverySummary(testValue: 51, testZone: .caution, testConfidencePercent: nil),
            isLoading: false
        )
        _ = RecoveryDetailView(dateString: "2026-02-24", testViewModel: loadedWithoutConfidenceVM).body
    }

    static func loadSummary(
        dateString: String?,
        dbQueue: DatabaseQueue
    ) async -> String? {
        let viewModel = RecoveryDetailViewModel(dateString: dateString, dbQueue: dbQueue)
        await viewModel.load()
        return viewModel.score?.accessibilitySummary
    }
}
#endif
