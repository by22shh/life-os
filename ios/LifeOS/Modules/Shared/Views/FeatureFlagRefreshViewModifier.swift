import Combine
import SwiftUI

private struct FeatureFlagRefreshViewModifier: ViewModifier {
    @State private var refreshTick = 0

    func body(content: Content) -> some View {
        content
            .onReceive(
                NotificationCenter.default
                    .publisher(for: FeatureFlagManager.didUpdateNotification)
                    .receive(on: RunLoop.main)
            ) { _ in
                refreshTick += 1
            }
    }
}

extension View {
    func refreshOnFeatureFlagChanges() -> some View {
        modifier(FeatureFlagRefreshViewModifier())
    }
}
