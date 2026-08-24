import SwiftUI

// MARK: - Life OS Watch App Entry Point
// Source of truth: life_os_watchos_spec.md

@main
struct LifeOSWatchApp: App {
    @StateObject private var snapshotStore = WatchSnapshotStore()

    var body: some Scene {
        WindowGroup {
            WatchHomeView(
                snapshot: snapshotStore.snapshot,
                isReachable: snapshotStore.isReachable,
                lightweightActionAvailability: snapshotStore.lightweightActionAvailability,
                openOnIPhoneAvailability: snapshotStore.openOnIPhoneAvailability,
                isCurrentNextBestActionPending: snapshotStore.isCurrentNextBestActionPending,
                actionFeedback: snapshotStore.lastActionFeedback,
                onAction: { action in
                    snapshotStore.sendAction(action)
                }
            )
        }
    }
}

#if DEBUG
extension LifeOSWatchApp {
    init(testSnapshotStore: WatchSnapshotStore) {
        _snapshotStore = StateObject(wrappedValue: testSnapshotStore)
    }
}
#endif
