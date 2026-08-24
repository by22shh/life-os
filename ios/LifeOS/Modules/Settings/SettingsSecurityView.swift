import SwiftUI

struct SettingsSecurityView: View {
    @State private var biometricAuthManager = BiometricAuthManager.shared
    @State private var isUpdating = false
    @State private var statusMessage: String?

    private var canEnableAppLock: Bool {
        biometricAuthManager.isBiometricAvailable || biometricAuthManager.isBiometricEnabled
    }

    private var appLockBinding: Binding<Bool> {
        Binding(
            get: { biometricAuthManager.isBiometricEnabled },
            set: { isEnabled in
                handleAppLockToggle(isEnabled)
            }
        )
    }

    var body: some View {
        List {
            Section {
                Toggle(String(localized: "settings_security_app_lock"), isOn: appLockBinding)
                    .disabled(isUpdating || !canEnableAppLock)
                    .accessibilityIdentifier("settings.security.toggle")

                LabeledContent(String(localized: "settings_security_status_label")) {
                    Text(
                        biometricAuthManager.isBiometricEnabled
                        ? String(localized: "settings_security_status_enabled")
                        : String(localized: "settings_security_status_disabled")
                    )
                    .foregroundStyle(.secondary)
                }

                if biometricAuthManager.isBiometricAvailable {
                    LabeledContent(String(localized: "settings_security_method_label")) {
                        Text(biometricAuthManager.biometricLabel)
                            .foregroundStyle(.secondary)
                    }
                }

                Label(String(localized: "settings_security_auto_lock"), systemImage: "lock.rotation")
                    .font(LifeOSTypography.footnote)
                    .foregroundStyle(.secondary)

                Label(String(localized: "settings_security_passcode_fallback"), systemImage: "key.fill")
                    .font(LifeOSTypography.footnote)
                    .foregroundStyle(.secondary)

                if isUpdating {
                    HStack(spacing: Spacing.s) {
                        ProgressView()
                        Text(String(localized: "settings_security_authenticating"))
                            .font(LifeOSTypography.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(LifeOSTypography.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(String(localized: "settings_security_footer"))
            }

            if !biometricAuthManager.isBiometricAvailable && !biometricAuthManager.isBiometricEnabled {
                Section {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Label(String(localized: "settings_security_unavailable_title"), systemImage: "faceid")
                            .font(LifeOSTypography.subheadline.weight(.semibold))

                        Text(String(localized: "settings_security_unavailable_body"))
                            .font(LifeOSTypography.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Spacing.xxs)
                }
            }
        }
        .navigationTitle(String(localized: "settings_security"))
        .background(LifeOSColors.Surface.background)
    }

    private func handleAppLockToggle(_ isEnabled: Bool) {
        if isEnabled {
            enableAppLock()
        } else {
            biometricAuthManager.disableBiometrics()
            statusMessage = String(localized: "settings_security_disable_success")
        }
    }

    private func enableAppLock() {
        guard !isUpdating else { return }
        isUpdating = true
        statusMessage = nil

        Task {
            let didEnable = await biometricAuthManager.enableBiometrics()
            await MainActor.run {
                isUpdating = false
                statusMessage = didEnable
                    ? String(localized: "settings_security_enable_success")
                    : String(localized: "settings_security_enable_failed")
            }
        }
    }
}

#if DEBUG
extension SettingsSecurityView {
    @MainActor
    func _testEvaluateBody() {
        _ = body
    }
}
#endif

#Preview {
    NavigationStack {
        SettingsSecurityView()
    }
}
