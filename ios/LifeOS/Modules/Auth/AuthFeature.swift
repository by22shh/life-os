import Foundation
import ComposableArchitecture

@Reducer
struct AuthFeature {
    @ObservableState
    struct State: Equatable {
        var showEmailOTP = false
        var email = ""
        var otpCode = ""
        var otpSent = false
        var isLoading = false
        var errorMessage: String?

        // MARK: - Email Validation

        /// Whether the current email string is a structurally valid email address.
        /// Uses a conservative regex: local@domain.tld (≥2-char TLD).
        var isEmailValid: Bool {
            AuthFeature.isValidEmail(email)
        }

        /// Whether the Send OTP button should be enabled.
        var canSendOTP: Bool {
            isEmailValid && !isLoading
        }

        // MARK: - OTP Validation

        /// Whether the current OTP code is a valid 6-digit numeric string.
        var isOTPValid: Bool {
            otpCode.count == 6 && otpCode.allSatisfy(\.isWholeNumber)
        }

        /// Whether the Verify OTP button should be enabled.
        var canVerifyOTP: Bool {
            isOTPValid && !isLoading
        }
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        case openEmailOTP(Bool)
        case emailChanged(String)
        case otpCodeChanged(String)
        case sendOTPTapped
        case sendOTPSucceeded
        case sendOTPFailed(String)
        case verifyOTPTapped
        case verifyOTPSucceeded
        case verifyOTPFailed(String)
        case appleSignInFailed(String)
    }

    var body: some ReducerOf<Self> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .openEmailOTP(let presented):
                state.showEmailOTP = presented
                if !presented {
                    state.otpCode = ""
                    state.errorMessage = nil
                }
                return .none

            case .emailChanged(let newEmail):
                state.email = newEmail
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                // Clear any previous validation error when user edits the email.
                if state.errorMessage != nil {
                    state.errorMessage = nil
                }
                return .none

            case .otpCodeChanged(let rawCode):
                // Strip non-digit characters and cap at 6 digits.
                let digitsOnly = String(rawCode.unicodeScalars.filter(CharacterSet.decimalDigits.contains).prefix(6))
                state.otpCode = digitsOnly
                return .none

            case .sendOTPTapped:
                // Guard: reject structurally invalid emails before hitting the network.
                guard state.isEmailValid else {
                    state.errorMessage = String(localized: "auth_error_invalid_email")
                    return .none
                }
                state.isLoading = true
                state.errorMessage = nil
                return .none

            case .sendOTPSucceeded:
                state.isLoading = false
                state.otpSent = true
                return .none

            case .sendOTPFailed(let error):
                state.isLoading = false
                state.errorMessage = error
                return .none

            case .verifyOTPTapped:
                // Guard: reject non-numeric or incomplete OTP before sending.
                guard state.isOTPValid else {
                    state.errorMessage = String(localized: "auth_error_invalid_otp")
                    return .none
                }
                state.isLoading = true
                state.errorMessage = nil
                return .none

            case .verifyOTPSucceeded:
                state.isLoading = false
                state.showEmailOTP = false
                state.otpCode = ""
                return .none

            case .verifyOTPFailed(let error):
                state.isLoading = false
                state.errorMessage = error
                return .none

            case .appleSignInFailed(let error):
                state.errorMessage = error
                return .none
            }
        }
    }

    // MARK: - Email Validation Helper

    /// RFC 5322 simplified: local-part @ domain . tld (≥2 chars).
    /// Rejects obviously invalid inputs while remaining permissive enough for
    /// real-world addresses (subdomains, +tags, dots in local part).
    static func isValidEmail(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Single-pass structural check:
        // 1. Exactly one '@'
        // 2. Non-empty local part (≥1 char)
        // 3. Domain contains at least one '.' with ≥2-char TLD
        // 4. No spaces anywhere
        guard !trimmed.contains(" ") else { return false }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = parts[0]
        let domain = parts[1]
        guard !local.isEmpty, local.count <= 64 else { return false }
        guard !domain.isEmpty, domain.count <= 253 else { return false }
        let domainParts = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard domainParts.count >= 2 else { return false }
        guard let tld = domainParts.last, tld.count >= 2 else { return false }
        // All domain labels must be non-empty.
        guard domainParts.allSatisfy({ !$0.isEmpty }) else { return false }
        return true
    }
}
