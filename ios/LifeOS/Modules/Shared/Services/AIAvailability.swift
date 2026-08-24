import Foundation

/// Encapsulates the runtime/rollout checks that gate AI-powered surfaces.
@MainActor
struct AIAvailability {
    private let featureFlags: FeatureFlagManager?
    private let simulationAvailableOverride: Bool?

    init(
        featureFlags: FeatureFlagManager? = AppContainer.shared?.featureFlags,
        simulationAvailableOverride: Bool? = nil
    ) {
        self.featureFlags = featureFlags
        self.simulationAvailableOverride = simulationAvailableOverride
    }

    private var runtimeConfigured: Bool {
        SupabaseConfig.isRuntimeConfigured
    }

    private var hasCloudSession: Bool {
        AuthManager.activeHasCloudSession
    }

    private func isFlagEnabled(_ flag: AppFeatureFlag) -> Bool {
        featureFlags?.currentSnapshot().isEnabled(flag) ?? flag.defaultEnabled
    }

    var simulationAvailable: Bool {
        if let simulationAvailableOverride {
            return simulationAvailableOverride
        }
        return runtimeConfigured && hasCloudSession &&
            isFlagEnabled(.aiInsightsEnabled) &&
            isFlagEnabled(.openrouterAvailable)
    }

    var photoLoggingAvailable: Bool {
        true
    }

    var photoCloudAnalysisAvailable: Bool {
        runtimeConfigured && hasCloudSession &&
            isFlagEnabled(.aiFoodPhotoEnabled) &&
            isFlagEnabled(.openrouterAvailable)
    }

    var photoAnalysisAvailable: Bool {
        photoCloudAnalysisAvailable
    }

    var voiceLoggingAvailable: Bool {
        runtimeConfigured && hasCloudSession &&
            isFlagEnabled(.aiVoiceLoggingEnabled)
    }

    var labOcrAvailable: Bool {
        isFlagEnabled(.aiLabOcrEnabled)
    }
}
