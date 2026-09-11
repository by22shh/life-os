import SwiftUI
import WidgetKit

private enum WidgetL10n {
    static func text(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }
}

struct WidgetSnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

private enum WidgetTimelineFactory {
    static func placeholderEntry() -> WidgetSnapshotEntry {
        WidgetSnapshotEntry(date: Date(), snapshot: .placeholder)
    }

    static func currentEntry() -> WidgetSnapshotEntry {
        WidgetSnapshotEntry(
            date: Date(),
            snapshot: WidgetSnapshotStorage.loadSnapshot() ?? .empty
        )
    }

    static func timeline(refreshAfterMinutes: Int) -> Timeline<WidgetSnapshotEntry> {
        let entry = currentEntry()
        let nextRefresh = Calendar.current.date(
            byAdding: .minute,
            value: refreshAfterMinutes,
            to: Date()
        ) ?? Date().addingTimeInterval(Double(refreshAfterMinutes) * 60)
        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }
}

struct RecoveryTimelineProvider: TimelineProvider {
    func placeholder(in _: Context) -> WidgetSnapshotEntry {
        WidgetTimelineFactory.placeholderEntry()
    }

    func getSnapshot(in _: Context, completion: @escaping (WidgetSnapshotEntry) -> Void) {
        completion(WidgetTimelineFactory.currentEntry())
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<WidgetSnapshotEntry>) -> Void) {
        completion(WidgetTimelineFactory.timeline(refreshAfterMinutes: 30))
    }
}

struct NutritionTimelineProvider: TimelineProvider {
    func placeholder(in _: Context) -> WidgetSnapshotEntry {
        WidgetTimelineFactory.placeholderEntry()
    }

    func getSnapshot(in _: Context, completion: @escaping (WidgetSnapshotEntry) -> Void) {
        completion(WidgetTimelineFactory.currentEntry())
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<WidgetSnapshotEntry>) -> Void) {
        completion(WidgetTimelineFactory.timeline(refreshAfterMinutes: 15))
    }
}

struct SupplementsTimelineProvider: TimelineProvider {
    func placeholder(in _: Context) -> WidgetSnapshotEntry {
        WidgetTimelineFactory.placeholderEntry()
    }

    func getSnapshot(in _: Context, completion: @escaping (WidgetSnapshotEntry) -> Void) {
        completion(WidgetTimelineFactory.currentEntry())
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<WidgetSnapshotEntry>) -> Void) {
        completion(WidgetTimelineFactory.timeline(refreshAfterMinutes: 15))
    }
}

struct WorkoutTimelineProvider: TimelineProvider {
    func placeholder(in _: Context) -> WidgetSnapshotEntry {
        WidgetTimelineFactory.placeholderEntry()
    }

    func getSnapshot(in _: Context, completion: @escaping (WidgetSnapshotEntry) -> Void) {
        completion(WidgetTimelineFactory.currentEntry())
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<WidgetSnapshotEntry>) -> Void) {
        completion(WidgetTimelineFactory.timeline(refreshAfterMinutes: 60))
    }
}

struct RecoveryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: LifeOSWidgetConstants.recoveryKind,
            provider: RecoveryTimelineProvider()
        ) { entry in
            RecoveryWidgetRoot(entry: entry)
        }
        .configurationDisplayName(String(localized: "widget.recovery.configuration_title"))
        .description(String(localized: "widget.recovery.configuration_description"))
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

struct NutritionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: LifeOSWidgetConstants.nutritionKind,
            provider: NutritionTimelineProvider()
        ) { entry in
            NutritionWidgetRoot(entry: entry)
        }
        .configurationDisplayName(String(localized: "widget.nutrition.configuration_title"))
        .description(String(localized: "widget.nutrition.configuration_description"))
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
        ])
    }
}

struct SupplementsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: LifeOSWidgetConstants.supplementsKind,
            provider: SupplementsTimelineProvider()
        ) { entry in
            SupplementsWidgetRoot(entry: entry)
        }
        .configurationDisplayName(String(localized: "widget.supplements.configuration_title"))
        .description(String(localized: "widget.supplements.configuration_description"))
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
        ])
    }
}

struct WorkoutWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: LifeOSWidgetConstants.workoutKind,
            provider: WorkoutTimelineProvider()
        ) { entry in
            WorkoutWidgetRoot(entry: entry)
        }
        .configurationDisplayName(String(localized: "widget.workout.title"))
        .description(String(localized: "widget.workout.configuration_description"))
        .supportedFamilies([
            .systemSmall,
            .accessoryRectangular,
        ])
    }
}

private struct RecoveryWidgetRoot: View {
    let entry: WidgetSnapshotEntry
    @Environment(\.widgetFamily) private var family
    let familyOverride: WidgetFamily?

    init(entry: WidgetSnapshotEntry, familyOverride: WidgetFamily? = nil) {
        self.entry = entry
        self.familyOverride = familyOverride
    }

    private var resolvedFamily: WidgetFamily {
        familyOverride ?? family
    }

    var body: some View {
        Group {
            if !entry.snapshot.privacy.showRecoveryScore {
                hiddenWidget(title: WidgetL10n.text("widget.recovery.title"))
            } else if let recovery = entry.snapshot.recovery {
                content(recovery: recovery)
            } else {
                emptyWidget(
                    title: WidgetL10n.text("widget.recovery.title"),
                    message: WidgetL10n.text("widget.recovery.empty_message")
                )
            }
        }
        .widgetURL(URL(string: "lifeos://recovery"))
    }

    @ViewBuilder
    private func content(recovery: WidgetSnapshot.RecoveryPayload) -> some View {
        switch resolvedFamily {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Text(widgetScoreText(recovery.recoveryScore))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(widgetZoneBadge(recovery.recoveryZoneLabel))
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                }
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(WidgetL10n.text("widget.recovery.title"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(widgetScoreText(recovery.recoveryScore))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(widgetZoneLabelText(recovery.recoveryZoneLabel))
                            .font(.caption)
                            .lineLimit(1)
                        if let delta = recovery.recoveryDelta {
                            Text(widgetDeltaText(delta))
                                .font(.caption2)
                                .foregroundStyle(widgetDeltaColor(delta))
                        }
                    }
                }
            }
        case .accessoryInline:
            Text(WidgetL10n.format(
                "widget.recovery.inline_format",
                widgetScoreText(recovery.recoveryScore),
                widgetZoneLabelText(recovery.recoveryZoneLabel)
            ))
        case .systemMedium:
            SystemCard {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(WidgetL10n.text("widget.recovery.title"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(widgetScoreText(recovery.recoveryScore))
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                        Text(widgetZoneLabelText(recovery.recoveryZoneLabel))
                            .font(.headline)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ProgressRing(
                            progress: widgetProgress(from: recovery.recoveryScore, target: 100),
                            tint: widgetRecoveryTint(for: recovery.recoveryZone)
                        )
                        if let delta = recovery.recoveryDelta {
                            Label(widgetDeltaText(delta), systemImage: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.caption)
                                .foregroundStyle(widgetDeltaColor(delta))
                        } else {
                            Text(WidgetL10n.text("widget.recovery.trend_waiting"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        default:
            SystemCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text(WidgetL10n.text("widget.recovery.title"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(widgetScoreText(recovery.recoveryScore))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(widgetZoneLabelText(recovery.recoveryZoneLabel))
                        .font(.headline)
                        .lineLimit(1)
                    if let delta = recovery.recoveryDelta {
                        Text(widgetDeltaText(delta))
                            .font(.caption)
                            .foregroundStyle(widgetDeltaColor(delta))
                    }
                }
            }
        }
    }
}

private struct NutritionWidgetRoot: View {
    let entry: WidgetSnapshotEntry
    @Environment(\.widgetFamily) private var family
    let familyOverride: WidgetFamily?

    init(entry: WidgetSnapshotEntry, familyOverride: WidgetFamily? = nil) {
        self.entry = entry
        self.familyOverride = familyOverride
    }

    private var resolvedFamily: WidgetFamily {
        familyOverride ?? family
    }

    var body: some View {
        Group {
            if !entry.snapshot.privacy.showNutrition {
                hiddenWidget(title: WidgetL10n.text("widget.nutrition.title"))
            } else if let nutrition = entry.snapshot.nutrition {
                content(nutrition: nutrition, units: entry.snapshot.units)
            } else {
                emptyWidget(
                    title: WidgetL10n.text("widget.nutrition.title"),
                    message: WidgetL10n.text("widget.nutrition.empty_message")
                )
            }
        }
        .widgetURL(URL(string: "lifeos://nutrition"))
    }

    @ViewBuilder
    private func content(nutrition: WidgetSnapshot.NutritionPayload, units: String?) -> some View {
        switch resolvedFamily {
        case .systemMedium:
            SystemCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(WidgetL10n.text("widget.nutrition.title"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(nutrition.calories)")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                            Text(widgetCalorieSubtitle(nutrition))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            MetricBar(label: String(localized: "protein"), valueText: widgetGramsText(nutrition.proteinG), progress: widgetProgress(from: nutrition.proteinG, target: nutrition.targetProteinG))
                            MetricBar(label: String(localized: "carbs"), valueText: widgetGramsText(nutrition.carbsG), progress: widgetProgress(from: nutrition.carbsG, target: nutrition.targetCarbsG))
                            MetricBar(label: String(localized: "water"), valueText: widgetWaterText(nutrition.waterMl, units: units), progress: widgetProgress(from: nutrition.waterMl, target: nutrition.targetWaterMl))
                        }
                    }
                }
            }
        default:
            SystemCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text(WidgetL10n.text("widget.nutrition.title"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(nutrition.calories)")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(widgetCalorieSubtitle(nutrition))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    MetricBar(label: String(localized: "protein"), valueText: widgetGramsText(nutrition.proteinG), progress: widgetProgress(from: nutrition.proteinG, target: nutrition.targetProteinG))
                    MetricBar(label: String(localized: "water"), valueText: widgetWaterText(nutrition.waterMl, units: units), progress: widgetProgress(from: nutrition.waterMl, target: nutrition.targetWaterMl))
                }
            }
        }
    }
}

private struct SupplementsWidgetRoot: View {
    let entry: WidgetSnapshotEntry

    var body: some View {
        Group {
            if !entry.snapshot.privacy.showSupplements {
                hiddenWidget(title: WidgetL10n.text("widget.supplements.title"))
            } else if let supplements = entry.snapshot.supplements {
                content(supplements: supplements)
            } else {
                emptyWidget(
                    title: WidgetL10n.text("widget.supplements.title"),
                    message: WidgetL10n.text("widget.supplements.empty_message")
                )
            }
        }
        .widgetURL(URL(string: "lifeos://supplements"))
    }

    @ViewBuilder
    private func content(supplements: WidgetSnapshot.SupplementsPayload) -> some View {
        let progress = widgetProgress(from: supplements.supplementsTaken, target: max(supplements.supplementsTotal, 1))

        SystemCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(WidgetL10n.text("widget.supplements.title"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(supplements.supplementsTaken)/\(supplements.supplementsTotal)")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(WidgetL10n.text("widget.supplements.taken"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: progress)
                    .tint(.mint)
                if let nextSupplement = supplements.nextSupplement {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nextSupplement.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(widgetNextDoseSubtitle(nextSupplement))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(
                        supplements.supplementsTotal == 0
                            ? WidgetL10n.text("widget.supplements.none_scheduled")
                            : WidgetL10n.text("widget.supplements.all_complete")
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct WorkoutWidgetRoot: View {
    let entry: WidgetSnapshotEntry
    @Environment(\.widgetFamily) private var family
    let familyOverride: WidgetFamily?

    init(entry: WidgetSnapshotEntry, familyOverride: WidgetFamily? = nil) {
        self.entry = entry
        self.familyOverride = familyOverride
    }

    private var resolvedFamily: WidgetFamily {
        familyOverride ?? family
    }

    var body: some View {
        Group {
            if !entry.snapshot.privacy.showTraining {
                hiddenWidget(title: WidgetL10n.text("widget.workout.title"))
            } else if let workout = entry.snapshot.training?.nextWorkout {
                content(workout: workout)
            } else {
                emptyWidget(
                    title: WidgetL10n.text("widget.workout.title"),
                    message: WidgetL10n.text("widget.workout.empty_message")
                )
            }
        }
        .widgetURL(URL(string: entry.snapshot.training?.nextWorkout?.deepLink ?? "lifeos://workout"))
    }

    @ViewBuilder
    private func content(workout: WidgetSnapshot.WorkoutEntry) -> some View {
        switch resolvedFamily {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(WidgetL10n.text("widget.workout.title"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(workout.title)
                    .font(.caption)
                    .lineLimit(1)
                Text(widgetWorkoutSubtitle(workout))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        default:
            SystemCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text(WidgetL10n.text("widget.workout.title"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(workout.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(workout.dayLabel)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(widgetWorkoutSubtitle(workout))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

private struct SystemCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.08, green: 0.10, blue: 0.16),
                            Color(red: 0.15, green: 0.18, blue: 0.24),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            content
                .foregroundStyle(.white)
                .padding(16)
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }
}

private struct MetricBar: View {
    let label: String
    let valueText: String
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.caption2)
                Spacer()
                Text(valueText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(progress, 0), 1))
                .tint(.cyan)
        }
    }
}

private struct ProgressRing: View {
    let progress: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: 10)
            Circle()
                .trim(from: 0, to: min(max(progress, 0.02), 1))
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text("\(Int((min(max(progress, 0), 1) * 100).rounded()))%")
                .font(.caption2)
                .bold()
        }
        .frame(width: 74, height: 74)
    }
}

@MainActor
@ViewBuilder
private func hiddenWidget(title: String) -> some View {
    SystemCard {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "lock.fill")
                .font(.headline)
            Text(WidgetL10n.text("widget.hidden_by_privacy"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
@ViewBuilder
private func emptyWidget(title: String, message: String) -> some View {
    SystemCard {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private func widgetScoreText(_ score: Int?) -> String {
    if let score {
        return "\(score)"
    }
    return "--"
}

private func widgetDeltaText(_ delta: Int) -> String {
    if delta > 0 {
        return WidgetL10n.format("widget.delta_positive_format", delta)
    }
    if delta < 0 {
        return WidgetL10n.format("widget.delta_negative_format", delta)
    }
    return WidgetL10n.text("widget.delta_zero")
}

private func widgetZoneBadge(_ label: String?) -> String {
    guard let label, let first = label.first else { return "?" }
    return String(first).uppercased()
}

private func widgetRecoveryTint(for zone: String?) -> Color {
    switch zone?.lowercased() {
    case "optimal":
        return .green
    case "ready":
        return .mint
    case "caution":
        return .orange
    case "critical":
        return .red
    default:
        return .blue
    }
}

private func widgetDeltaColor(_ delta: Int) -> Color {
    if delta > 0 { return .green }
    if delta < 0 { return .orange }
    return .secondary
}

private func widgetProgress(from value: Int?, target: Int?) -> Double {
    guard let value, let target, target > 0 else { return 0 }
    return Double(value) / Double(target)
}

private func widgetCalorieSubtitle(_ nutrition: WidgetSnapshot.NutritionPayload) -> String {
    if let target = nutrition.targetCalories, target > 0 {
        return WidgetL10n.format("widget.nutrition.calories_progress_format", nutrition.calories, target)
    }
    return WidgetL10n.format("widget.nutrition.calories_logged_format", nutrition.calories)
}

private func widgetNextDoseSubtitle(_ supplement: WidgetSnapshot.SupplementEntry) -> String {
    if let dayLabel = supplement.dayLabel, !dayLabel.isEmpty {
        return WidgetL10n.format("widget.supplements.next_dose_with_day_format", dayLabel, supplement.timeLabel)
    }
    return supplement.timeLabel
}

private func widgetWorkoutSubtitle(_ workout: WidgetSnapshot.WorkoutEntry) -> String {
    var components: [String] = [workout.dayLabel]
    if let durationMinutes = workout.durationMinutes, durationMinutes > 0 {
        components.append(WidgetL10n.format("widget.duration_minutes_format", durationMinutes))
    }
    if let subtitle = workout.subtitle, !subtitle.isEmpty {
        components.append(subtitle)
    }
    return components.joined(separator: " • ")
}

private func widgetZoneLabelText(_ label: String?) -> String {
    guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines),
          !label.isEmpty else {
        return WidgetL10n.text("widget.no_data")
    }
    return label
}

private func widgetGramsText(_ value: Int) -> String {
    WidgetL10n.format("widget.value_grams_format", value)
}

private func widgetWaterText(_ milliliters: Int, units: String?) -> String {
    guard units == "imperial" else {
        return WidgetL10n.format("widget.value_milliliters_format", milliliters)
    }
    let ounces = Double(milliliters) / 29.5735295625
    return WidgetL10n.format("widget.value_fluid_ounces_format", ounces)
}

#if DEBUG
enum LifeOSWidgetsTestHooks {
    static func placeholderEntry() -> WidgetSnapshotEntry {
        WidgetTimelineFactory.placeholderEntry()
    }

    static func currentEntry() -> WidgetSnapshotEntry {
        WidgetTimelineFactory.currentEntry()
    }

    static func timeline(refreshAfterMinutes: Int) -> Timeline<WidgetSnapshotEntry> {
        WidgetTimelineFactory.timeline(refreshAfterMinutes: refreshAfterMinutes)
    }

    @MainActor
    static func recoveryRoot(entry: WidgetSnapshotEntry, family: WidgetFamily) -> AnyView {
        AnyView(RecoveryWidgetRoot(entry: entry, familyOverride: family))
    }

    @MainActor
    static func nutritionRoot(entry: WidgetSnapshotEntry, family: WidgetFamily) -> AnyView {
        AnyView(NutritionWidgetRoot(entry: entry, familyOverride: family))
    }

    @MainActor
    static func supplementsRoot(entry: WidgetSnapshotEntry) -> AnyView {
        AnyView(SupplementsWidgetRoot(entry: entry))
    }

    @MainActor
    static func workoutRoot(entry: WidgetSnapshotEntry, family: WidgetFamily) -> AnyView {
        AnyView(WorkoutWidgetRoot(entry: entry, familyOverride: family))
    }

    @MainActor
    static func hidden(title: String) -> AnyView {
        AnyView(hiddenWidget(title: title))
    }

    @MainActor
    static func empty(title: String, message: String) -> AnyView {
        AnyView(emptyWidget(title: title, message: message))
    }

    static func scoreText(_ score: Int?) -> String {
        widgetScoreText(score)
    }

    static func deltaText(_ delta: Int) -> String {
        widgetDeltaText(delta)
    }

    static func zoneBadge(_ label: String?) -> String {
        widgetZoneBadge(label)
    }

    static func recoveryTint(for zone: String?) -> Color {
        widgetRecoveryTint(for: zone)
    }

    static func deltaColor(_ delta: Int) -> Color {
        widgetDeltaColor(delta)
    }

    static func progress(from value: Int?, target: Int?) -> Double {
        widgetProgress(from: value, target: target)
    }

    static func calorieSubtitle(_ nutrition: WidgetSnapshot.NutritionPayload) -> String {
        widgetCalorieSubtitle(nutrition)
    }

    static func nextDoseSubtitle(_ supplement: WidgetSnapshot.SupplementEntry) -> String {
        widgetNextDoseSubtitle(supplement)
    }

    static func workoutSubtitle(_ workout: WidgetSnapshot.WorkoutEntry) -> String {
        widgetWorkoutSubtitle(workout)
    }

    static func zoneLabelText(_ label: String?) -> String {
        widgetZoneLabelText(label)
    }

    static func gramsText(_ value: Int) -> String {
        widgetGramsText(value)
    }

    static func millilitersText(_ value: Int) -> String {
        widgetWaterText(value, units: nil)
    }
}
#endif

@main
struct LifeOSWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RecoveryWidget()
        NutritionWidget()
        SupplementsWidget()
        WorkoutWidget()
    }
}
