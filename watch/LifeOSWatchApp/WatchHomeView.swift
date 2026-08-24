import SwiftUI

// MARK: - Watch Home View (Glance)
// Source of truth: life_os_watchos_spec.md §1.2, §1.3, §3.2

struct WatchHomeView: View {
    let snapshot: WatchSnapshot?
    let isReachable: Bool
    let lightweightActionAvailability: WatchOpenOnIPhoneAvailability
    let openOnIPhoneAvailability: WatchOpenOnIPhoneAvailability
    let isCurrentNextBestActionPending: Bool
    let actionFeedback: WatchActionFeedback?
    let onAction: (WatchAction) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                recoveryBlock
                nextBestActionBlock
                supplementsDueSoonPill
                truncationNotice
                lastUpdatedFooter
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Recovery Score + Zone (§1.2 Block 1)

    @ViewBuilder
    private var recoveryBlock: some View {
        if let snapshot,
           let score = snapshot.recoveryScore {
            let zone = WatchRecoveryZone(rawValue: snapshot.recoveryZone?.lowercased() ?? "") ?? .critical

            Text("\(Int(score.rounded()))")
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .accessibilityHidden(true)

            HStack(spacing: 4) {
                Image(systemName: zone.iconName)
                Text(zone.label)
            }
            .font(.caption)
            .foregroundStyle(zone.color)
            .accessibilityLabel(zone.accessibilityAnnouncement(score: score))

            // Low confidence badge
            if let confidence = snapshot.confidenceScore,
               confidence < 0.65 {
                Text(String(localized: "insights_confidence_low_badge"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("--")
                .font(.system(size: 36, weight: .semibold, design: .rounded))
            Text(String(localized: "loading"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Next Best Action CTA (§1.2 Block 2)

    @ViewBuilder
    private var nextBestActionBlock: some View {
        if let snapshot,
           let nba = snapshot.nextBestAction {
            let actionType = WatchActionType(rawValue: nba.type) ?? .openOnIphone

            switch actionType {
            case .supplementTaken:
                lightweightActionBlock(
                    labelCopyId: nba.labelCopyId,
                    systemImage: "pills.fill",
                    tint: .green,
                    action: .supplementTaken(
                        name: nba.payload?.supplementName,
                        scheduledTime: nba.payload?.scheduledTime
                    )
                )

            case .insightAcknowledge:
                lightweightActionBlock(
                    labelCopyId: nba.labelCopyId,
                    systemImage: "hand.thumbsup.fill",
                    tint: .accentColor,
                    action: .insightAcknowledge(insightId: nba.payload?.insightId)
                )

            default:
                // All other actions route to iPhone (§1.3 routing rule)
                openOnIPhoneActionBlock(
                    deepLink: nba.payload?.deepLink,
                    compact: false
                )
            }
        }
    }

    // MARK: - Supplements Due Soon Pill (§1.2 Block 3)

    @ViewBuilder
    private var supplementsDueSoonPill: some View {
        if let supplements = snapshot?.supplementsDueSoon {
            HStack(spacing: 4) {
                Image(systemName: "pills.fill")
                    .font(.caption2)
                Text(String(format: String(localized: "watch.due_soon"), supplements.count, supplements.time))
                    .font(.caption2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.12))
            .clipShape(Capsule())
        }
    }

    // MARK: - Truncation Notice (§2)

    @ViewBuilder
    private var truncationNotice: some View {
        if snapshot?.wasTruncated == true {
            openOnIPhoneActionBlock(deepLink: nil, compact: true)
        }
    }

    // MARK: - Last Updated (§3.2)

    @ViewBuilder
    private var lastUpdatedFooter: some View {
        if let snapshot {
            let age = Date().timeIntervalSince(snapshot.lastUpdatedAt)
            let isStale = age > 3600 // > 1 hour considered stale

            HStack(spacing: 2) {
                if !isReachable || isStale {
                    Image(systemName: "exclamationmark.icloud")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text(String(format: String(localized: "watch.last_updated"), formattedAge(age)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let connectivityHintCopyKey {
                Text(String(localized: String.LocalizationValue(connectivityHintCopyKey)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func localizedCopyId(_ copyId: String) -> String {
        String(localized: String.LocalizationValue(copyId))
    }

    @ViewBuilder
    private func lightweightActionBlock(
        labelCopyId: String,
        systemImage: String,
        tint: Color,
        action: WatchAction
    ) -> some View {
        VStack(spacing: 4) {
            Button {
                onAction(action)
            } label: {
                Label(
                    localizedCopyId(labelCopyId),
                    systemImage: systemImage
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .disabled(!canSendLightweightAction)

            if let lightweightActionStatusCopyKey {
                Text(String(localized: String.LocalizationValue(lightweightActionStatusCopyKey)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private func openOnIPhoneActionBlock(deepLink: String?, compact: Bool) -> some View {
        VStack(spacing: 4) {
            if compact {
                Button {
                    onAction(.openOnIphone(deepLink: deepLink))
                } label: {
                    Text(String(localized: "global.open_on_iphone"))
                        .font(.caption2)
                        .foregroundStyle(canRouteToIPhone ? Color.blue : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canRouteToIPhone)
            } else {
                Button {
                    onAction(.openOnIphone(deepLink: deepLink))
                } label: {
                    Label(
                        String(localized: "global.open_on_iphone"),
                        systemImage: "iphone"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(!canRouteToIPhone)
            }

            if let openOnIPhoneStatusCopyKey {
                Text(String(localized: String.LocalizationValue(openOnIPhoneStatusCopyKey)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var canRouteToIPhone: Bool {
        openOnIPhoneAvailability != .unavailable
    }

    private var canSendLightweightAction: Bool {
        lightweightActionAvailability != .unavailable && !isCurrentNextBestActionPending
    }

    private var lightweightActionStatusCopyKey: String? {
        if isCurrentNextBestActionPending {
            return "watch.lightweight_action_queue_hint"
        }

        if let actionFeedback {
            switch actionFeedback {
            case .lightweightActionQueued:
                return "watch.lightweight_action_feedback_queued"
            case .lightweightActionUnavailable:
                return "watch.open_on_iphone_unavailable"
            default:
                break
            }
        }

        switch lightweightActionAvailability {
        case .immediate:
            return nil
        case .queued:
            return "watch.lightweight_action_queue_hint"
        case .unavailable:
            return "watch.open_on_iphone_unavailable"
        }
    }

    private var openOnIPhoneStatusCopyKey: String? {
        if let actionFeedback {
            switch actionFeedback {
            case .openOnIPhoneQueued:
                return "watch.open_on_iphone_feedback_queued"
            case .openOnIPhoneUnavailable:
                return "watch.open_on_iphone_unavailable"
            default:
                break
            }
        }

        return connectivityHintCopyKey
    }

    private var connectivityHintCopyKey: String? {
        switch openOnIPhoneAvailability {
        case .immediate:
            return nil
        case .queued:
            return "watch.open_on_iphone_queue_hint"
        case .unavailable:
            return "watch.open_on_iphone_unavailable"
        }
    }

    private func formattedAge(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return String(localized: "watch.just_now") }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return "\(hours)h"
    }
}

// MARK: - Watch Actions

enum WatchAction {
    case supplementTaken(name: String?, scheduledTime: String?)
    case insightAcknowledge(insightId: String?)
    case openOnIphone(deepLink: String?)
}

private enum WatchActionType: String {
    case openDiary = "open_diary"
    case openSleep = "open_sleep"
    case logMeal = "log_meal"
    case supplementTaken = "supplement_taken"
    case insightAcknowledge = "insight_acknowledge"
    case openOnIphone = "open_on_iphone"
}

// MARK: - Watch Recovery Zone

/// Recovery zone metadata for watchOS.
/// Source of truth: `life_os_invariants.md` §1 + `DesignTokens.swift` (Okabe-Ito palette).
/// Kept in sync with `RecoveryZone` on iOS. If you change values here, update the iOS
/// counterpart and vice versa.
enum WatchRecoveryZone: String, CaseIterable {
    case critical
    case caution
    case ready
    case optimal

    // MARK: - Shared metadata (must match iOS RecoveryZone)

    var label: String {
        switch self {
        case .critical: return String(localized: "recovery_zone_critical")
        case .caution: return String(localized: "recovery_zone_caution")
        case .ready: return String(localized: "recovery_zone_ready")
        case .optimal: return String(localized: "recovery_zone_optimal")
        }
    }

    /// SF Symbol icons — identical to iOS `RecoveryZone.iconName`.
    var iconName: String {
        switch self {
        case .critical: return "xmark.circle.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .ready: return "arrow.up.right.circle.fill"
        case .optimal: return "checkmark.circle.fill"
        }
    }

    /// Okabe-Ito dark-mode colors (watchOS always dark).
    /// Hex source: DesignTokens.LifeOSColors.Recovery.Hex.*Dark
    ///   critical: #D55E00, caution: #F0E442, ready: #009E73, optimal: #56B4E9
    var color: Color {
        switch self {
        case .critical: return Color(red: 0xD5 / 255.0, green: 0x5E / 255.0, blue: 0x00 / 255.0) // #D55E00
        case .caution:  return Color(red: 0xF0 / 255.0, green: 0xE4 / 255.0, blue: 0x42 / 255.0) // #F0E442
        case .ready:    return Color(red: 0x00 / 255.0, green: 0x9E / 255.0, blue: 0x73 / 255.0) // #009E73
        case .optimal:  return Color(red: 0x56 / 255.0, green: 0xB4 / 255.0, blue: 0xE9 / 255.0) // #56B4E9
        }
    }

    func accessibilityAnnouncement(score: Double) -> String {
        let percent = Int(min(max(score, 0), 100).rounded())
        return "\(String(localized: "recovery_announcement_prefix")) \(label), \(percent) \(String(localized: "recovery_percent_label"))"
    }
}
