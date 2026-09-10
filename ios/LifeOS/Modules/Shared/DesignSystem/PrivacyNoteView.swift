// MARK: - Privacy Note View
// Subtle inline privacy messaging per life_os_privacy_architecture.md.
// Shows contextual privacy information at the point of data collection,
// not hidden in Settings. Builds trust through transparency.

import SwiftUI

/// A subtle inline label communicating a privacy policy to the user
/// at the moment of data collection or display.
///
/// Usage:
/// ```
/// PrivacyNoteView(.photoRetention)
/// PrivacyNoteView(.localOnly)
/// PrivacyNoteView(.aiCacheExpiry)
/// ```
struct PrivacyNoteView: View {
    let note: PrivacyNote

    init(_ note: PrivacyNote) {
        self.note = note
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Image(systemName: note.icon)
                .accessibilityHidden(true)
            Text(note.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(LifeOSTypography.footnote)
        .foregroundStyle(LifeOSColors.Text.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(note.accessibilityText)
    }
}

// MARK: - Privacy Note Types

enum PrivacyNote {
    /// Food photos: auto-deleted after 90 days
    case photoRetention
    /// Menstrual data: stored only on this device
    case menstrualLocalOnly
    /// Medical scans: stored only on this device (when enabled)
    case medicalScanLocalOnly
    /// Medical scan images: auto-deleted after 90 days
    case medicalScanRetention
    /// AI-generated insights: cached for 7 days only
    case aiCacheExpiry
    /// AI features: health context is processed by an external provider
    case aiProcessing
    /// HealthKit: read-only access, no writes
    case healthKitReadOnly
    /// General on-device note
    case onDeviceOnly
    /// Custom note
    case custom(icon: String, text: String)

    var icon: String {
        switch self {
        case .photoRetention, .medicalScanRetention:
            return "clock.arrow.circlepath"
        case .menstrualLocalOnly, .medicalScanLocalOnly, .onDeviceOnly:
            return "iphone"
        case .aiCacheExpiry:
            return "timer"
        case .aiProcessing:
            return "sparkles.shield"
        case .healthKitReadOnly:
            return "lock.shield"
        case .custom(let icon, _):
            return icon
        }
    }

    var text: String {
        switch self {
        case .photoRetention:
            return String(localized: "privacy_note_photo_retention")
        case .menstrualLocalOnly:
            return String(localized: "privacy_note_menstrual_local")
        case .medicalScanLocalOnly:
            return String(localized: "privacy_note_medical_local")
        case .medicalScanRetention:
            return String(localized: "privacy_note_medical_retention")
        case .aiCacheExpiry:
            return String(localized: "privacy_note_ai_cache")
        case .aiProcessing:
            return String(localized: "privacy_note_ai_processing")
        case .healthKitReadOnly:
            return String(localized: "privacy_note_healthkit_readonly")
        case .onDeviceOnly:
            return String(localized: "privacy_note_on_device")
        case .custom(_, let text):
            return text
        }
    }

    var accessibilityText: String {
        text
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        PrivacyNoteView(.photoRetention)
        PrivacyNoteView(.menstrualLocalOnly)
        PrivacyNoteView(.aiCacheExpiry)
        PrivacyNoteView(.medicalScanRetention)
        PrivacyNoteView(.healthKitReadOnly)
    }
    .padding()
}
