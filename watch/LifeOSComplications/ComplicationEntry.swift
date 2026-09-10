import WidgetKit
import SwiftUI

// MARK: - Recovery Complication
// Source of truth: life_os_watchos_spec.md §1.1, §4

struct RecoveryComplicationEntry: TimelineEntry {
    let date: Date
    let score: Int?
    let zone: String?
    let zoneLabel: String
    let zoneIcon: String

    static var placeholder: RecoveryComplicationEntry {
        RecoveryComplicationEntry(
            date: Date(),
            score: 72,
            zone: "ready",
            zoneLabel: String(localized: "recovery_zone_ready"),
            zoneIcon: "arrow.up.right.circle.fill"
        )
    }

    static var empty: RecoveryComplicationEntry {
        RecoveryComplicationEntry(
            date: Date(),
            score: nil,
            zone: nil,
            zoneLabel: "--",
            zoneIcon: "questionmark.circle"
        )
    }
}

// MARK: - Timeline Provider

struct RecoveryTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecoveryComplicationEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (RecoveryComplicationEntry) -> Void) {
        completion(context.isPreview ? .placeholder : timelineEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecoveryComplicationEntry>) -> Void) {
        let entry = timelineEntry()

        // Refresh after 30 minutes or when snapshot is pushed (§4)
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        let timeline = Timeline(entries: [entry], policy: .after(nextRefresh))
        completion(timeline)
    }

    private func snapshotEntry(
        defaults: UserDefaults? = UserDefaults(suiteName: "group.com.lifeos.watchkit")
    ) -> RecoveryComplicationEntry {
        loadCurrentEntry(defaults: defaults) ?? .empty
    }

    private func timelineEntry(
        defaults: UserDefaults? = UserDefaults(suiteName: "group.com.lifeos.watchkit")
    ) -> RecoveryComplicationEntry {
        loadCurrentEntry(defaults: defaults) ?? .empty
    }

    private func loadCurrentEntry(
        defaults: UserDefaults? = UserDefaults(suiteName: "group.com.lifeos.watchkit")
    ) -> RecoveryComplicationEntry? {
        guard let data = defaults?.data(forKey: "latestSnapshot"),
              let snapshot = try? JSONDecoder.iso8601.decode(SnapshotPayload.self, from: data) else {
            return nil
        }

        guard let updatedAt = snapshot.lastUpdatedAt.flatMap(Self.parseTimestamp),
              Calendar.current.isDateInToday(updatedAt),
              updatedAt.timeIntervalSinceNow <= 300,
              Date().timeIntervalSince(updatedAt) < 24 * 3600 else { return nil }
        if let day = snapshot.date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            guard day == formatter.string(from: Date()) else { return nil }
        }
        guard let score = snapshot.recoveryScore, score.isFinite, (0...100).contains(score) else { return nil }
        let zone = snapshot.recoveryZone?.lowercased() ?? "critical"
        return RecoveryComplicationEntry(
            date: Date(),
            score: Int(score.rounded()),
            zone: snapshot.recoveryZone,
            zoneLabel: zoneLabel(for: zone),
            zoneIcon: zoneIcon(for: zone)
        )
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func zoneLabel(for zone: String) -> String {
        switch zone {
        case "optimal": return String(localized: "recovery_zone_optimal")
        case "ready": return String(localized: "recovery_zone_ready")
        case "caution": return String(localized: "recovery_zone_caution")
        default: return String(localized: "recovery_zone_critical")
        }
    }

    private func zoneIcon(for zone: String) -> String {
        switch zone {
        case "optimal": return "checkmark.circle.fill"
        case "ready": return "arrow.up.right.circle.fill"
        case "caution": return "exclamationmark.triangle.fill"
        default: return "xmark.circle.fill"
        }
    }
}

/// Minimal Codable struct for reading snapshot from shared UserDefaults.
private struct SnapshotPayload: Codable {
    var date: String?
    var lastUpdatedAt: String?
    var recoveryScore: Double?
    var recoveryZone: String?

    enum CodingKeys: String, CodingKey {
        case date
        case lastUpdatedAt = "last_updated_at"
        case recoveryScore = "recovery_score"
        case recoveryZone = "recovery_zone"
    }
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - Complication Views

/// Circular complication: score number + zone icon (§1.1)
struct CircularComplicationView: View {
    let entry: RecoveryComplicationEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                if let score = entry.score {
                    Text("\(score)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.5)
                } else {
                    Text("--")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                }
                Image(systemName: entry.zoneIcon)
                    .font(.caption2)
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if let score = entry.score {
            return "\(String(localized: "recovery_announcement_prefix")) \(entry.zoneLabel), \(score) \(String(localized: "recovery_percent_label"))"
        }
        return String(localized: "loading")
    }
}

/// Rectangular complication: score + zone label (§1.1)
struct RectangularComplicationView: View {
    let entry: RecoveryComplicationEntry

    var body: some View {
        HStack(spacing: 4) {
            if let score = entry.score {
                Text("\(score)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
            } else {
                Text("--")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
            }

            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: entry.zoneIcon)
                    .font(.caption2)
                Text(entry.zoneLabel)
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Corner complication: score with zone icon (§1.1)
struct CornerComplicationView: View {
    let entry: RecoveryComplicationEntry

    var body: some View {
        VStack(spacing: 0) {
            if let score = entry.score {
                Text("\(score)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
            } else {
                Text("--")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
        }
        .widgetLabel {
            Label(entry.zoneLabel, systemImage: entry.zoneIcon)
        }
    }
}

// MARK: - Widget Configuration

struct RecoveryComplicationWidget: Widget {
    let kind = "RecoveryComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: RecoveryTimelineProvider()
        ) { entry in
            ComplicationRootView(entry: entry)
        }
        .configurationDisplayName(String(localized: "complication_recovery_title"))
        .description(String(localized: "complication_recovery_description"))
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryCorner
        ])
    }
}

private struct ComplicationRootView: View {
    let entry: RecoveryComplicationEntry
    @Environment(\.widgetFamily) private var family
    let familyOverride: WidgetFamily?

    init(entry: RecoveryComplicationEntry, familyOverride: WidgetFamily? = nil) {
        self.entry = entry
        self.familyOverride = familyOverride
    }

    private var resolvedFamily: WidgetFamily {
        familyOverride ?? family
    }

    @ViewBuilder
    var body: some View {
        switch resolvedFamily {
        case .accessoryCircular:
            CircularComplicationView(entry: entry)
        case .accessoryRectangular:
            RectangularComplicationView(entry: entry)
        case .accessoryCorner:
            CornerComplicationView(entry: entry)
        default:
            CircularComplicationView(entry: entry)
        }
    }
}

// MARK: - Widget Bundle

@main
struct LifeOSComplicationsBundle: WidgetBundle {
    var body: some Widget {
        RecoveryComplicationWidget()
    }
}

#if DEBUG
extension RecoveryTimelineProvider {
    func _testLoadCurrentEntry(defaults: UserDefaults?) -> RecoveryComplicationEntry? {
        loadCurrentEntry(defaults: defaults)
    }

    func _testSnapshotEntry(defaults: UserDefaults?) -> RecoveryComplicationEntry {
        snapshotEntry(defaults: defaults)
    }

    func _testTimelineEntry(defaults: UserDefaults?) -> RecoveryComplicationEntry {
        timelineEntry(defaults: defaults)
    }

    func _testZoneLabel(for zone: String) -> String {
        zoneLabel(for: zone)
    }

    func _testZoneIcon(for zone: String) -> String {
        zoneIcon(for: zone)
    }
}

enum RecoveryComplicationTestHooks {
    @MainActor
    static func rootView(
        entry: RecoveryComplicationEntry,
        family: WidgetFamily
    ) -> AnyView {
        AnyView(ComplicationRootView(entry: entry, familyOverride: family))
    }
}
#endif
