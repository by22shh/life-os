import SwiftUI

struct AuthCallbackView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(\.dismiss) private var dismiss

    private var iconName: String {
        Self.iconName(for: authManager.authCallbackStatus)
    }

    private var iconColor: Color {
        Self.iconColor(for: authManager.authCallbackStatus)
    }

    private var titleKey: LocalizedStringResource {
        Self.titleKey(for: authManager.authCallbackStatus)
    }

    private var message: String {
        Self.message(for: authManager.authCallbackStatus)
    }

    private var actionButtonTitleKey: LocalizedStringResource {
        Self.actionButtonTitleKey(for: authManager.authCallbackStatus)
    }

    var body: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: iconName)
                .font(LifeOSTypography.title)
                .foregroundStyle(iconColor)
            Text(titleKey)
                .font(LifeOSTypography.headline)
            Text(message)
                .font(LifeOSTypography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if authManager.authCallbackStatus.isProcessing {
                ProgressView()
                    .padding(.top, Spacing.s)
            } else {
                Button(action: close) {
                    Text(actionButtonTitleKey)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, Spacing.s)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(LayoutConstants.contentPadding)
        .background(LifeOSColors.Surface.background)
        .navigationTitle(String(localized: "sign_in"))
        .interactiveDismissDisabled(authManager.authCallbackStatus.isProcessing)
        .task(id: authManager.authCallbackStatus) {
            await handleAuthCallbackStatusChange()
        }
    }

    @MainActor
    private func close() {
        authManager.resetAuthCallbackStatus()
        dismiss()
    }

    private func handleAuthCallbackStatusChange() async {
        await Self.handleAuthCallbackStatusChange(
            status: authManager.authCallbackStatus,
            onSuccess: close
        )
    }

    private static func iconName(for status: AuthCallbackStatus) -> String {
        switch status {
        case .idle, .processing:
            return "ellipsis.circle"
        case .succeeded:
            return "checkmark.seal"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private static func iconColor(for status: AuthCallbackStatus) -> Color {
        switch status {
        case .idle, .processing:
            return LifeOSColors.Semantic.primary
        case .succeeded:
            return LifeOSColors.Semantic.success
        case .failed:
            return LifeOSColors.Recovery.caution
        }
    }

    private static func titleKey(for status: AuthCallbackStatus) -> LocalizedStringResource {
        switch status {
        case .idle, .processing:
            return "auth_callback_processing_title"
        case .succeeded:
            return "auth_callback_success_title"
        case .failed:
            return "auth_callback_failure_title"
        }
    }

    private static func message(for status: AuthCallbackStatus) -> String {
        switch status {
        case .idle, .processing:
            return String(localized: "auth_callback_processing_message")
        case .succeeded:
            return String(localized: "auth_callback_success_message")
        case .failed(let errorMessage):
            return errorMessage
        }
    }

    private static func actionButtonTitleKey(
        for status: AuthCallbackStatus
    ) -> LocalizedStringResource {
        switch status {
        case .succeeded:
            return "continue"
        case .failed:
            return "cancel"
        case .idle, .processing:
            return "continue"
        }
    }

    private static func handleAuthCallbackStatusChange(
        status: AuthCallbackStatus,
        onSuccess: @escaping @MainActor () -> Void,
        sleepNanoseconds: UInt64 = 1_200_000_000
    ) async {
        guard case .succeeded = status else {
            return
        }
        try? await Task.sleep(nanoseconds: sleepNanoseconds)
        await MainActor.run {
            onSuccess()
        }
    }
}

#if DEBUG
extension AuthCallbackView {
    static func _testPresentation(
        for status: AuthCallbackStatus
    ) -> (
        iconName: String,
        iconColor: String,
        title: String,
        message: String,
        actionTitle: String,
        isProcessing: Bool
    ) {
        (
            iconName: iconName(for: status),
            iconColor: String(describing: iconColor(for: status)),
            title: String(localized: titleKey(for: status)),
            message: message(for: status),
            actionTitle: String(localized: actionButtonTitleKey(for: status)),
            isProcessing: status.isProcessing
        )
    }

    static func _testHandleAuthCallbackStatusChange(
        status: AuthCallbackStatus,
        sleepNanoseconds: UInt64 = 0,
        onSuccess: @escaping @MainActor () -> Void
    ) async {
        await handleAuthCallbackStatusChange(
            status: status,
            onSuccess: onSuccess,
            sleepNanoseconds: sleepNanoseconds
        )
    }
}
#endif
