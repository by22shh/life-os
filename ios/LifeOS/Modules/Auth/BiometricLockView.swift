import SwiftUI

struct BiometricLockView: View {
    @State private var biometricAuthManager = BiometricAuthManager.shared
    @State private var isAuthenticating = false
    @State private var statusMessage: String?
    private static let isRunningTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private var messageText: String {
        if biometricAuthManager.isBiometricAvailable {
            return String(
                format: String(localized: "biometric_lock_message_format"),
                biometricAuthManager.biometricLabel
            )
        }
        return String(localized: "biometric_lock_message_passcode_only")
    }

    private var primaryActionTitle: String {
        if biometricAuthManager.isBiometricAvailable {
            return String(
                format: String(localized: "biometric_lock_primary_action_format"),
                biometricAuthManager.biometricLabel
            )
        }
        return String(localized: "biometric_lock_primary_action_passcode")
    }

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Spacer(minLength: 0)

            VStack(spacing: Spacing.l) {
                Image(systemName: "lock.shield.fill")
                    .font(LifeOSTypography.metricMedium)
                    .foregroundStyle(LifeOSColors.Semantic.primary)

                VStack(spacing: Spacing.s) {
                    Text(String(localized: "biometric_lock_title"))
                        .font(LifeOSTypography.headline.weight(.semibold))
                        .multilineTextAlignment(.center)

                    Text(messageText)
                        .font(LifeOSTypography.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if isAuthenticating {
                    ProgressView(String(localized: "biometric_lock_authenticating"))
                        .font(LifeOSTypography.footnote)
                } else {
                    Button(primaryActionTitle, action: triggerUnlock)
                        .buttonStyle(.borderedProminent)
                        .frame(minWidth: LayoutConstants.minTouchTarget, minHeight: LayoutConstants.minTouchTarget)
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(LifeOSTypography.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(LayoutConstants.contentPadding)
            .frame(maxWidth: 360)
            .background(LifeOSColors.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
            .padding(.horizontal, LayoutConstants.contentPadding)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LifeOSColors.Surface.background)
        .onAppear(perform: attemptAutomaticUnlockIfNeeded)
        .accessibilityIdentifier("app.biometric.lock")
    }

    private func attemptAutomaticUnlockIfNeeded() {
        guard biometricAuthManager.isLocked, !Self.isRunningTests else { return }
        triggerUnlock()
    }

    private func triggerUnlock() {
        guard biometricAuthManager.isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        statusMessage = nil

        Task {
            let didUnlock = await biometricAuthManager.authenticate()
            await MainActor.run {
                isAuthenticating = false
                if !didUnlock {
                    statusMessage = String(localized: "biometric_lock_retry_note")
                }
            }
        }
    }
}

#if DEBUG
extension BiometricLockView {
    @MainActor
    func _testEvaluateBody() {
        _ = body
    }
}
#endif
