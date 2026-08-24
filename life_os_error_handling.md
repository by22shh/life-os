# LIFE OS — ERROR HANDLING SPECIFICATION

**Version:** 2.1  
**Date:** February 16, 2026  
**Purpose:** Comprehensive error handling strategy for all app components

---

## ERROR CLASSIFICATION

### Severity Levels

| Level | Name | User Impact | Recovery | Example |
|-------|------|-------------|----------|---------|
| 0 | **Silent** | None | Auto | Cache miss, background sync delay |
| 1 | **Info** | Minimal | Auto | Using cached data instead of fresh |
| 2 | **Warning** | Degraded | Semi-auto | HRV data missing, using estimate |
| 3 | **Error** | Blocked action | User retry | Food photo analysis failed |
| 4 | **Critical** | App unusable | Manual | Database corruption, auth failure |

### Error Categories

```swift
enum ErrorCategory {
    case network       // Connectivity issues
    case auth          // Authentication/authorization
    case healthKit     // Apple HealthKit errors
    case vision        // AI Vision API errors
    case database      // Supabase/local DB errors
    case validation    // Input validation failures
    case permission    // Missing permissions
    case focusControl  // Screen Time / Focus Control errors
    case quota         // Rate limits, API quotas
    case hardware      // Camera, sensors errors
    case unknown       // Unexpected errors
}
```

---

## CORE TYPES (shared)

These types are referenced throughout this document to keep error handling consistent.

```swift
enum ErrorSeverity: Int, Codable {
    case silent = 0
    case info = 1
    case warning = 2
    case error = 3
    case critical = 4
}

enum RecoveryAction: String, Codable {
    case none
    case openSettings
    case openHealthApp
    case retryLater
}

enum FallbackBehavior: String, Codable {
    case none
    case offerManualEntry
    case retakePhoto
    case rescanBarcode
    case openFoodSearch
    case openFoodLabelScan
    case openVoiceLog
    case openBatchLibrary
    case showResultsWithWarning
    case showResultsWithManualFill
    case retakePhotoOrManual
    case showDuplicateWarning
    case useOfflineMode
    case useCachedCatalogOnly
}

enum LifeOSError: Error {
    case unknown
}

// Focus Control / Screen Time Errors (9xxx)
enum FocusControlError: Int, LocalizedError {
    case notSupported = 9001       // Device/OS does not support Focus Control
    case permissionDenied = 9002   // User denied Screen Time permission
    case permissionRestricted = 9003 // Parental controls or enterprise restriction
    case ruleApplyFailed = 9004    // Failed to apply a restriction rule
    case ruleRevertFailed = 9005   // Failed to remove a restriction rule

    var userFacingMessage: String {
        switch self {
        case .notSupported:
            return "Focus Control isn’t available on this device."
        case .permissionDenied:
            return "Focus Control permission is required for Guardian mode."
        case .permissionRestricted:
            return "Focus Control is restricted by device policy."
        case .ruleApplyFailed:
            return "We couldn’t apply Focus Control. Try again."
        case .ruleRevertFailed:
            return "We couldn’t remove Focus Control. Try again."
        }
    }
}
```

---

## ERROR CODES

### Network Errors (1xxx)

```swift
enum NetworkError: Int, LocalizedError {
    case noConnection = 1001        // No internet
    case timeout = 1002             // Request timeout
    case serverUnavailable = 1003   // 5xx errors
    case serverMaintenance = 1004   // Planned downtime
    case rateLimited = 1005         // Too many requests
    case sslError = 1006            // Certificate issues
    
    var errorDescription: String? {
        switch self {
        case .noConnection:
            return "No internet connection"
        case .timeout:
            return "Request timed out"
        case .serverUnavailable:
            return "Server is temporarily unavailable"
        case .serverMaintenance:
            return "Server is under maintenance"
        case .rateLimited:
            return "Too many requests. Please wait."
        case .sslError:
            return "Secure connection failed"
        }
    }
    
    var userFacingMessage: String {
        switch self {
        case .noConnection:
            return "You're offline. We'll sync when you're back online."
        case .timeout:
            return "Taking longer than usual. Try again?"
        case .serverUnavailable:
            return "Our servers are busy. Trying again in a moment..."
        case .serverMaintenance:
            return "We're updating! Back in a few minutes."
        case .rateLimited:
            return "Slow down! Let's try that again in a moment."
        case .sslError:
            return "Connection isn't secure. Please try a different network."
        }
    }
    
    var isRetryable: Bool {
        switch self {
        case .noConnection, .timeout, .serverUnavailable, .rateLimited:
            return true
        case .serverMaintenance, .sslError:
            return false
        }
    }
    
    // NOTE: These retry strategies apply to **in-flow** network requests (e.g., user-initiated actions).
    // The sync engine outbox uses a separate, more conservative backoff schedule:
    // 10s base delay, up to 10 retries — see `life_os_sync_engine_spec.md` §8.2.
    var retryStrategy: RetryStrategy {
        switch self {
        case .noConnection:
            return .waitForConnectivity
        case .timeout, .serverUnavailable:
            return .exponentialBackoff(maxAttempts: 3, baseDelay: 2.0)
        case .rateLimited:
            return .fixedDelay(seconds: 60)
        default:
            return .noRetry
        }
    }

    var severity: ErrorSeverity {
        switch self {
        case .noConnection, .timeout, .rateLimited, .serverMaintenance:
            return .warning
        case .serverUnavailable, .sslError:
            return .error
        }
    }
}
```

### Authentication Errors (2xxx)

```swift
enum AuthError: Int, LocalizedError {
    case tokenExpired = 2001        // JWT expired
    case tokenInvalid = 2002        // Malformed token
    case sessionRevoked = 2003      // Logged out remotely
    case accountDeleted = 2004      // User deleted account
    case accountSuspended = 2005    // Policy violation
    case biometricFailed = 2006     // Face ID / Touch ID failed
    case biometricNotEnrolled = 2007
    
    var userFacingMessage: String {
        switch self {
        case .tokenExpired, .tokenInvalid:
            return "Your session expired. Please sign in again."
        case .sessionRevoked:
            return "You were signed out. Please sign in again."
        case .accountDeleted:
            return "This account no longer exists."
        case .accountSuspended:
            return "Your account is suspended. Contact support."
        case .biometricFailed:
            return "Authentication failed. Try again or use passcode."
        case .biometricNotEnrolled:
            return "Set up Face ID or Touch ID in Settings to use this feature."
        }
    }
    
    var requiresReauth: Bool {
        switch self {
        case .tokenExpired, .tokenInvalid, .sessionRevoked:
            return true
        default:
            return false
        }
    }

    var severity: ErrorSeverity {
        switch self {
        case .tokenExpired, .tokenInvalid, .sessionRevoked, .biometricFailed:
            return .warning
        case .accountDeleted, .accountSuspended:
            return .error
        case .biometricNotEnrolled:
            return .info
        }
    }
}
```

### HealthKit Errors (3xxx)

```swift
enum HealthKitError: Int, LocalizedError {
    case notAvailable = 3001        // HealthKit not on device
    case notAuthorized = 3002       // Permission denied
    case partialAuthorization = 3003 // Some permissions denied
    case dataUnavailable = 3004     // Requested data not found
    case staleData = 3005           // Data older than expected
    case syncFailed = 3006          // Background sync failed
    case deviceNotPaired = 3007     // Apple Watch not connected
    
    var userFacingMessage: String {
        switch self {
        case .notAvailable:
            return "HealthKit isn't available on this device."
        case .notAuthorized:
            return "We need access to Health data to calculate your recovery score."
        case .partialAuthorization:
            return "Some health data is missing. Grant full access for accurate insights."
        case .dataUnavailable:
            return "No health data found. Make sure your Apple Watch is synced."
        case .staleData:
            return "Your health data is outdated. Sync your Apple Watch."
        case .syncFailed:
            return "Couldn't sync health data. We'll try again shortly."
        case .deviceNotPaired:
            return "Connect your Apple Watch to track recovery."
        }
    }
    
    var recoveryAction: RecoveryAction {
        switch self {
        case .notAuthorized, .partialAuthorization:
            return .openSettings
        case .dataUnavailable, .staleData, .deviceNotPaired:
            return .openHealthApp
        case .syncFailed:
            return .retryLater
        default:
            return .none
        }
    }
}
```

### Vision API Errors (4xxx)

```swift
enum VisionError: Int, LocalizedError {
    case apiUnavailable = 4001      // AI gateway/provider down (OpenRouter or routed model)
    case quotaExceeded = 4002       // API quota limit
    case imageInvalid = 4003        // Corrupted/unsupported image
    case imageTooLarge = 4004       // File size limit
    case imageBlurry = 4005         // Can't analyze
    case noFoodDetected = 4006      // No food in image
    case lowConfidence = 4007       // Uncertain analysis
    case timeout = 4008             // Analysis took too long
    case contentFiltered = 4009     // Inappropriate content
    
    var userFacingMessage: String {
        switch self {
        case .apiUnavailable:
            return "Food analysis is temporarily unavailable. Try manual entry?"
        case .quotaExceeded:
            return "Daily photo limit reached. Log this meal manually or try again tomorrow."
        case .imageInvalid:
            return "This image couldn't be processed. Try taking another photo."
        case .imageTooLarge:
            return "Image is too large. Try again with a smaller photo."
        case .imageBlurry:
            return "Image is too blurry. Hold steady and try again."
        case .noFoodDetected:
            return "I couldn't find food in this photo. Try a clearer shot."
        case .lowConfidence:
            return "I'm not sure about this one. Please review and adjust."
        case .timeout:
            return "Analysis is taking too long. Try again?"
        case .contentFiltered:
            return "This image can't be analyzed."
        }
    }
    
    var fallbackBehavior: FallbackBehavior {
        switch self {
        case .apiUnavailable, .timeout:
            return .offerManualEntry
        case .imageBlurry, .noFoodDetected:
            return .retakePhoto
        case .lowConfidence:
            return .showResultsWithWarning
        case .quotaExceeded:
            return .offerManualEntry
        default:
            return .offerManualEntry
        }
    }

    var severity: ErrorSeverity {
        switch self {
        case .contentFiltered:
            return .error
        case .apiUnavailable, .quotaExceeded, .timeout, .imageInvalid, .imageTooLarge, .imageBlurry:
            return .warning
        case .noFoodDetected, .lowConfidence:
            return .info
        }
    }
}
```

### Validation Errors (95xx)

```swift
enum ValidationError: Int, LocalizedError {
    case missingField = 9501        // Required field missing
    case invalidFormat = 9502       // Wrong type/format
    case outOfRange = 9503          // Value outside allowed range

    var userFacingMessage: String {
        switch self {
        case .missingField:
            return "Missing required information. Please review and try again."
        case .invalidFormat:
            return "Some fields are invalid. Please correct and try again."
        case .outOfRange:
            return "One or more values are out of range. Please adjust."
        }
    }

    var severity: ErrorSeverity {
        switch self {
        case .missingField:
            return .warning
        case .invalidFormat:
            return .warning
        case .outOfRange:
            return .warning
        }
    }

    var fallbackBehavior: FallbackBehavior {
        switch self {
        case .missingField, .invalidFormat, .outOfRange:
            return .showResultsWithManualFill
        }
    }
}
```

### AI Errors (91xx)

```swift
enum AIError: Int, LocalizedError {
    case gatewayUnavailable = 9101  // LLM gateway down
    case timeout = 9102             // AI processing timed out
    case unsafeOutput = 9103        // Output blocked by safety filters
    case lowConfidence = 9104       // Output too uncertain

    var userFacingMessage: String {
        switch self {
        case .gatewayUnavailable:
            return "AI features are temporarily unavailable."
        case .timeout:
            return "This took too long. Please try again."
        case .unsafeOutput:
            return "This request cannot be completed safely."
        case .lowConfidence:
            return "I'm not confident about this result. Please review."
        }
    }

    var severity: ErrorSeverity {
        switch self {
        case .gatewayUnavailable, .timeout:
            return .warning
        case .unsafeOutput:
            return .error
        case .lowConfidence:
            return .info
        }
    }
}
```

### Food Database + Barcode Errors (60xx–61xx)

These errors cover barcode lookup, food search, nutrition label OCR fallback, and text-to-structured meal parsing (voice transcript parsing).

```swift
enum FoodDBError: Int, LocalizedError {
    case barcodeNotFound = 6001           // No match in provider
    case providerUnavailable = 6002       // Provider down / timeout
    case providerRateLimited = 6003       // 429 or quota exceeded
    case invalidBarcode = 6004            // Non-digit or unsupported length
    case insufficientNutritionData = 6005 // Missing per-100g and serving weight
    case parseFailed = 6006               // parse-food-text could not produce items
    
    // Nutrition label OCR fallback (CIS-critical)
    case labelImageInvalid = 6010         // Corrupted/unsupported image
    case labelImageBlurry = 6011          // Too blurry / glare
    case labelNoNutritionTable = 6012     // Nutrition table not detected
    case labelServingMissing = 6013       // No serving size; per-100g cannot be trusted
    case labelMacroMismatch = 6014        // kcal vs macros mismatch beyond tolerance
    case labelUnsupportedLanguage = 6015  // Language not supported for extraction
    case labelExtractionFailed = 6016     // Generic extraction failure
    
    var userFacingMessage: String {
        switch self {
        case .barcodeNotFound:
            return "Barcode not found. You can still log it in seconds."
        case .providerUnavailable:
            return "Food database is temporarily unavailable. Try again or log manually."
        case .providerRateLimited:
            return "Food lookup limit reached. Try again later or log manually."
        case .invalidBarcode:
            return "That barcode doesn’t look valid. Try scanning again."
        case .insufficientNutritionData:
            return "We found the product, but nutrition details are incomplete. Please review."
        case .parseFailed:
            return "Couldn’t understand that meal. Please type it or add items manually."
        case .labelImageInvalid:
            return "This label photo couldn’t be processed. Try taking another photo."
        case .labelImageBlurry:
            return "The label is hard to read. Try better lighting and reduce glare."
        case .labelNoNutritionTable:
            return "I couldn’t find a nutrition table. Try photographing only the nutrition panel."
        case .labelServingMissing:
            return "Serving size is unclear. Please review and enter grams if you can."
        case .labelMacroMismatch:
            return "Some label values don’t add up. Please review before saving."
        case .labelUnsupportedLanguage:
            return "This label language isn’t supported yet. Please enter macros manually."
        case .labelExtractionFailed:
            return "Couldn’t read this nutrition label. Try again or enter manually."
        }
    }
    
    var fallbackBehavior: FallbackBehavior {
        switch self {
        case .barcodeNotFound:
            return .openFoodLabelScan
        case .providerUnavailable:
            return .useCachedCatalogOnly
        case .providerRateLimited:
            return .useCachedCatalogOnly
        case .invalidBarcode:
            return .rescanBarcode
        case .insufficientNutritionData:
            return .showResultsWithWarning
        case .parseFailed:
            return .offerManualEntry
        case .labelImageInvalid:
            return .retakePhoto
        case .labelImageBlurry:
            return .retakePhoto
        case .labelNoNutritionTable:
            return .retakePhoto
        case .labelServingMissing:
            return .showResultsWithManualFill
        case .labelMacroMismatch:
            return .showResultsWithWarning
        case .labelUnsupportedLanguage:
            return .offerManualEntry
        case .labelExtractionFailed:
            return .offerManualEntry
        }
    }
    
    var severity: ErrorSeverity {
        switch self {
        case .barcodeNotFound:
            return .info
        case .invalidBarcode:
            return .warning
        case .providerUnavailable, .providerRateLimited:
            return .warning
        case .insufficientNutritionData:
            return .warning
        case .parseFailed:
            return .error
        case .labelServingMissing, .labelMacroMismatch:
            return .warning
        case .labelUnsupportedLanguage:
            return .warning
        case .labelImageInvalid, .labelImageBlurry, .labelNoNutritionTable, .labelExtractionFailed:
            return .error
        }
    }
}
```

### Batch Recipes / Meal Prep Errors (61xx)

```swift
enum BatchRecipeError: Int, LocalizedError {
    case invalidTotalWeight = 6101       // total_weight_g missing/<=0
    case invalidPortions = 6102          // total_portions missing/<=0 (when required)
    case ingredientMissingMacros = 6103  // one or more ingredients has incomplete macros
    case portionExceedsRemaining = 6104  // user logs more than remaining weight
    case analysisUnavailable = 6105      // analyze-batch-recipe-image down / timeout
    case draftLowConfidence = 6106       // AI draft < threshold; review required
    
    var userFacingMessage: String {
        switch self {
        case .invalidTotalWeight:
            return "Total cooked weight is required. Please enter grams."
        case .invalidPortions:
            return "Portions look invalid. Set an approximate number of portions."
        case .ingredientMissingMacros:
            return "Some ingredients are missing nutrition details. Please review."
        case .portionExceedsRemaining:
            return "That portion is larger than what’s left in the batch. Please adjust."
        case .analysisUnavailable:
            return "Meal prep analysis is temporarily unavailable. Try precise mode?"
        case .draftLowConfidence:
            return "This draft needs a quick review before saving."
        }
    }
    
    var fallbackBehavior: FallbackBehavior {
        switch self {
        case .invalidTotalWeight, .invalidPortions:
            return .showResultsWithManualFill
        case .ingredientMissingMacros:
            return .showResultsWithManualFill
        case .portionExceedsRemaining:
            return .showResultsWithWarning
        case .analysisUnavailable:
            return .openBatchLibrary
        case .draftLowConfidence:
            return .showResultsWithWarning
        }
    }
    
    var severity: ErrorSeverity {
        switch self {
        case .draftLowConfidence:
            return .info
        case .ingredientMissingMacros, .portionExceedsRemaining:
            return .warning
        case .invalidTotalWeight, .invalidPortions, .analysisUnavailable:
            return .error
        }
    }
}
```

### Bioimpedance Scan Errors (7xxx)

```swift
enum BioimpedanceError: Int, LocalizedError {
    case imageBlurry = 7001          // Can't read scale display
    case notScaleImage = 7002        // Image isn't a scale/report
    case partialExtraction = 7003    // Some fields missing
    case inbodyOCRFailed = 7004      // InBody report OCR failed
    case noWeight = 7005             // Weight not readable (critical)
    case analysisUnavailable = 7006  // AI analysis service down
    case unsupportedDevice = 7007    // Unknown scale brand
    case lowLighting = 7008          // Photo too dark
    
    var userFacingMessage: String {
        switch self {
        case .imageBlurry:
            return "The image is too blurry. Try holding your phone steady with good lighting."
        case .notScaleImage:
            return "This doesn't look like a scale or body composition report. Try again?"
        case .partialExtraction:
            return "We found some values but others are unclear. Please review and fill in the missing ones."
        case .inbodyOCRFailed:
            return "Couldn't read this InBody report. Try taking a clearer photo."
        case .noWeight:
            return "Couldn't read the weight. This is required — please try again or enter manually."
        case .analysisUnavailable:
            return "Body composition analysis is temporarily unavailable. Try again later or enter manually."
        case .unsupportedDevice:
            return "We couldn't identify this scale. You can still enter values manually."
        case .lowLighting:
            return "The photo is too dark. Try again with better lighting."
        }
    }
    
    var fallbackBehavior: FallbackBehavior {
        switch self {
        case .imageBlurry, .lowLighting, .inbodyOCRFailed, .notScaleImage:
            return .retakePhoto
        case .partialExtraction:
            return .showResultsWithManualFill
        case .noWeight:
            return .retakePhotoOrManual
        case .analysisUnavailable, .unsupportedDevice:
            return .offerManualEntry
        }
    }
    
    var severity: ErrorSeverity {
        switch self {
        case .partialExtraction:
            return .info
        case .imageBlurry, .lowLighting, .analysisUnavailable, .unsupportedDevice:
            return .warning
        case .noWeight, .notScaleImage, .inbodyOCRFailed:
            return .error
        }
    }
}
```

### Database Errors (5xxx)

```swift
enum DatabaseError: Int, LocalizedError {
    case connectionFailed = 5001    // Can't connect to Supabase
    case queryFailed = 5002         // SQL error
    case constraintViolation = 5003 // Unique/FK violation
    case migrationFailed = 5004     // Schema migration error
    case localCorruption = 5005     // SQLite corruption
    case syncConflict = 5006        // Offline/online conflict
    case quotaExceeded = 5007       // Storage limit
    
    var userFacingMessage: String {
        switch self {
        case .connectionFailed:
            return "Can't connect to our servers. Using offline mode."
        case .queryFailed, .constraintViolation:
            return "Something went wrong. Please try again."
        case .migrationFailed:
            return "App update required. Please update from App Store."
        case .localCorruption:
            return "Local data is corrupted. Restoring from backup..."
        case .syncConflict:
            return "Sync conflict detected. Most recent data was kept."
        case .quotaExceeded:
            return "Storage limit reached. Delete old data or export and remove history."
        }
    }

    var fallbackBehavior: FallbackBehavior {
        switch self {
        case .connectionFailed:
            return .useOfflineMode
        default:
            return .none
        }
    }

    var severity: ErrorSeverity {
        switch self {
        case .connectionFailed, .syncConflict, .quotaExceeded:
            return .warning
        case .queryFailed, .constraintViolation:
            return .error
        case .migrationFailed, .localCorruption:
            return .critical
        }
    }
}
```

---

### Workout Errors (62xx)

```swift
enum WorkoutError: Int, LocalizedError {
    case invalidSession = 6201      // Missing start/end or invalid duration
    case missingExercises = 6202    // No exercises logged
    case invalidSetData = 6203      // Negative reps/weight, malformed set
    case wearableImportFailed = 6204// HealthKit/workout import failed
    case syncFailed = 6205          // Failed to sync workout log
    
    var userFacingMessage: String {
        switch self {
        case .invalidSession:
            return "This workout looks incomplete. Please check start/end time."
        case .missingExercises:
            return "No exercises found. Add at least one exercise to save."
        case .invalidSetData:
            return "Some set data looks wrong. Please review and try again."
        case .wearableImportFailed:
            return "Couldn't import this workout. You can log it manually."
        case .syncFailed:
            return "Workout saved locally. We'll sync when you're online."
        }
    }
    
    var fallbackBehavior: FallbackBehavior {
        switch self {
        case .wearableImportFailed:
            return .offerManualEntry
        case .syncFailed:
            return .useOfflineMode
        default:
            return .showResultsWithManualFill
        }
    }

    var severity: ErrorSeverity {
        switch self {
        case .invalidSession:
            return .error
        case .missingExercises:
            return .warning
        case .invalidSetData:
            return .warning
        case .wearableImportFailed:
            return .error
        case .syncFailed:
            return .warning
        }
    }
}
```

```swift
enum TrainingPlanError: Int, LocalizedError {
    case generationFailed = 6301    // AI plan generation failed
    case insufficientData = 6302    // Not enough profile data
    case conflictWithInjury = 6303  // Plan conflicts with injury constraints
    case planNotActive = 6304       // No active plan
    case adjustmentFailed = 6305    // Adaptive adjustment failed
    
    var userFacingMessage: String {
        switch self {
        case .generationFailed:
            return "We couldn't build a plan right now. Try again or choose a template."
        case .insufficientData:
            return "We need a few more details to build your plan."
        case .conflictWithInjury:
            return "This plan conflicts with your injury constraints. Please review."
        case .planNotActive:
            return "No active plan found. Create one to continue."
        case .adjustmentFailed:
            return "Couldn't adjust the plan. Your previous plan is still active."
        }
    }
    
    var fallbackBehavior: FallbackBehavior {
        switch self {
        case .generationFailed, .insufficientData, .conflictWithInjury:
            return .offerManualEntry
        case .planNotActive:
            return .offerManualEntry
        case .adjustmentFailed:
            return .showResultsWithWarning
        }
    }

    var severity: ErrorSeverity {
        switch self {
        case .generationFailed:
            return .error
        case .insufficientData:
            return .warning
        case .conflictWithInjury:
            return .error
        case .planNotActive:
            return .warning
        case .adjustmentFailed:
            return .warning
        }
    }
}
```

---

### Supplement Errors (64xx)

```swift
enum SupplementError: Int, LocalizedError {
    case supplementNotFound = 6401   // Supplement id not found
    case invalidSchedule = 6402      // Missing/invalid scheduled time
    case duplicateLog = 6403         // Already logged for the time window
    case invalidDose = 6404          // Dose outside allowed bounds
    case interactionConflict = 6405  // Known interaction flagged
    case logWindowClosed = 6406      // Logging outside allowed window (if enforced)

    var userFacingMessage: String {
        switch self {
        case .supplementNotFound:
            return "That supplement isn't available. Refresh your list and try again."
        case .invalidSchedule:
            return "Schedule looks incomplete. Please pick a time."
        case .duplicateLog:
            return "Already logged for this time window."
        case .invalidDose:
            return "Dose looks unusual. Please review before saving."
        case .interactionConflict:
            return "This combination may interact. Review timing before logging."
        case .logWindowClosed:
            return "That time window has passed. Log as a manual intake instead."
        }
    }

    var fallbackBehavior: FallbackBehavior {
        switch self {
        case .interactionConflict:
            return .showResultsWithWarning
        default:
            return .none
        }
    }

    var severity: ErrorSeverity {
        switch self {
        case .duplicateLog, .logWindowClosed:
            return .info
        case .invalidSchedule, .interactionConflict:
            return .warning
        case .supplementNotFound, .invalidDose:
            return .error
        }
    }
}
```

---

### Health Markers Errors (8xxx)

Errors for medical document extraction and health marker processing.

```swift
enum HealthMarkersError: Int, LocalizedError {
    case documentUnreadable = 8001      // Can't read document at all
    case notMedicalDocument = 8002      // Image isn't a medical document
    case partialExtraction = 8003       // Some values unclear
    case unknownLanguage = 8004         // Can't detect document language
    case duplicateScan = 8005           // Same date + lab already exists
    case noMarkersFound = 8006          // No health markers detected
    case extractionTimeout = 8007       // AI processing took too long
    case manualReviewRequired = 8008    // Low confidence, user must verify
    case unsupportedDocumentType = 8009 // Document type not supported
    case unitConversionFailed = 8010    // Couldn't convert units
    
    var userFacingMessage: String {
        switch self {
        case .documentUnreadable:
            return "Couldn't read this document. Try better lighting or a flatter angle."
        case .notMedicalDocument:
            return "This doesn't look like a medical document. Try a blood test or lab report."
        case .partialExtraction:
            return "Some values couldn't be read clearly. Please review and correct."
        case .unknownLanguage:
            return "Couldn't detect the language. You can add values manually."
        case .duplicateScan:
            return "This document has already been scanned (same date and lab)."
        case .noMarkersFound:
            return "No health markers found. Make sure the results section is visible."
        case .extractionTimeout:
            return "Analysis is taking too long. Try a clearer photo."
        case .manualReviewRequired:
            return "Please review the extracted data before saving."
        case .unsupportedDocumentType:
            return "This document type isn't supported yet. Try a blood test or lab report."
        case .unitConversionFailed:
            return "Couldn't convert units. You can edit the values manually."
        }
    }
    
    var fallbackBehavior: FallbackBehavior {
        switch self {
        case .documentUnreadable, .notMedicalDocument:
            return .retakePhoto
        case .partialExtraction, .manualReviewRequired:
            return .showResultsWithManualFill
        case .noMarkersFound:
            return .retakePhoto
        case .extractionTimeout, .unknownLanguage:
            return .offerManualEntry
        case .duplicateScan:
            return .showDuplicateWarning
        case .unsupportedDocumentType:
            return .offerManualEntry
        case .unitConversionFailed:
            return .showResultsWithWarning
        }
    }
    
    var severity: ErrorSeverity {
        switch self {
        case .documentUnreadable, .notMedicalDocument, .noMarkersFound:
            return .error
        case .partialExtraction, .manualReviewRequired, .unitConversionFailed:
            return .warning
        case .duplicateScan:
            return .info
        case .extractionTimeout, .unknownLanguage, .unsupportedDocumentType:
            return .warning
        }
    }
}
```

---

## RETRY STRATEGIES

```swift
enum RetryStrategy {
    case noRetry
    case immediate(maxAttempts: Int)
    case fixedDelay(seconds: TimeInterval)
    case exponentialBackoff(maxAttempts: Int, baseDelay: TimeInterval)
    case waitForConnectivity
}

struct RetryPolicy {
    let strategy: RetryStrategy
    let maxAttempts: Int
    let jitter: Bool  // Add randomness to prevent thundering herd
    
    func execute<T>(
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var attempt = 0
        var lastError: Error?
        
        while attempt < maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                attempt += 1
                
                guard attempt < maxAttempts else { break }
                
                let delay = calculateDelay(attempt: attempt)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        
        throw lastError ?? LifeOSError.unknown
    }
    
    private func calculateDelay(attempt: Int) -> TimeInterval {
        switch strategy {
        case .noRetry, .immediate:
            return 0
        case .fixedDelay(let seconds):
            return seconds
        case .exponentialBackoff(_, let baseDelay):
            var delay = baseDelay * pow(2.0, Double(attempt - 1))
            if jitter {
                delay *= Double.random(in: 0.5...1.5)
            }
            return min(delay, 60) // Max 60 seconds
        case .waitForConnectivity:
            return 0 // Handled by NWPathMonitor
        }
    }
}
```

### Default Retry Policies

```swift
struct DefaultRetryPolicies {
    static let networkRequest = RetryPolicy(
        strategy: .exponentialBackoff(maxAttempts: 3, baseDelay: 1.0),
        maxAttempts: 3,
        jitter: true
    )
    
    static let visionAPI = RetryPolicy(
        strategy: .exponentialBackoff(maxAttempts: 2, baseDelay: 2.0),
        maxAttempts: 2,
        jitter: false
    )
    
    static let healthKitSync = RetryPolicy(
        strategy: .exponentialBackoff(maxAttempts: 5, baseDelay: 5.0),
        maxAttempts: 5,
        jitter: true
    )
    
    static let databaseWrite = RetryPolicy(
        strategy: .immediate(maxAttempts: 2),
        maxAttempts: 2,
        jitter: false
    )
}
```

---

## USER-FACING ERROR UI

### Error Alert Types

```swift
enum ErrorPresentation {
    case inline          // Small message near the action
    case banner          // Top banner, auto-dismiss
    case modal           // Full modal (critical errors)
    case bottomSheet     // Sheet with options
    case fullScreen      // Takes over screen (auth required)
}

struct ErrorAlert {
    let title: String
    let message: String
    let titleCopyId: String?
    let messageCopyId: String?
    let presentation: ErrorPresentation
    let primaryAction: ErrorAction?
    let secondaryAction: ErrorAction?
    let autoDismiss: TimeInterval?
    let icon: String
    let hapticFeedback: UINotificationFeedbackGenerator.FeedbackType
}

struct ErrorAction {
    let title: String
    let style: ActionStyle
    let handler: () -> Void
    
    enum ActionStyle {
        case primary      // Blue filled
        case secondary    // Outlined
        case destructive  // Red
        case cancel       // Gray text
    }
}
```

> [!NOTE]
> Error UI copy must reference `life_os_copy_catalog.md` where a matching `copy_id` exists.

### Error UI Examples

#### Inline Error (Severity 2)
```
┌────────────────────────────────────────┐
│ 🍽️ Food Log                            │
│                                        │
│ ┌────────────────────────────────────┐ │
│ │ ⚠️ Some data uses yesterday's      │ │
│ │    estimates. Sync for accuracy.   │ │
│ │              [SYNC NOW]            │ │
│ └────────────────────────────────────┘ │
│                                        │
│ 1420 / 1850 kcal                       │
└────────────────────────────────────────┘
```

#### Banner Error (Severity 2-3)
```
┌────────────────────────────────────────┐
│ 📶 Working offline                     │
│ Changes will sync when connected       │
└────────────────────────────────────────┘
│                                        │
│           (Rest of screen)             │
```

#### Modal Error (Severity 3)
```
┌────────────────────────────────────────┐
│                                        │
│              📷                        │
│                                        │
│     Photo Analysis Failed              │
│                                        │
│   The image was too blurry to         │
│   identify foods accurately.           │
│                                        │
│   ┌─────────────────────────────────┐  │
│   │       RETAKE PHOTO              │  │
│   └─────────────────────────────────┘  │
│                                        │
│   ┌─────────────────────────────────┐  │
│   │       ENTER MANUALLY            │  │
│   └─────────────────────────────────┘  │
│                                        │
│          [CANCEL]                      │
└────────────────────────────────────────┘
```

#### Module-Specific Examples

Workout log validation (inline):
```
┌────────────────────────────────────────┐
│ 🏋️ Workout                             │
│                                        │
│ ⚠️ Set data is incomplete. Please      │
│    review.                             │
│ [Fix Set] [Save as is]                 │
└────────────────────────────────────────┘
```

Copy source:
- Use `training.error_missing_sets` from `life_os_copy_catalog.md`

Training plan generation failure (bottom sheet):
```
┌────────────────────────────────────────┐
│ Could not build plan                    │
│ We need your available days and         │
│ equipment access.                       │
│                                        │
│ [Add details] [Choose template]         │
└────────────────────────────────────────┘
```

Lab OCR low confidence (modal):
```
┌────────────────────────────────────────┐
│ Scan Needs Review                       │
│ We found values but confidence is low.  │
│ Please review before saving.            │
│                                        │
│ [Review Values] [Retake Photo]          │
│ [Upload PDF]                            │
└────────────────────────────────────────┘
```

Copy source:
- Use `labs.ocr_low_title`, `labs.ocr_low_helper`, and CTAs from `life_os_copy_catalog.md`

Barcode not found (sheet):
```
┌────────────────────────────────────────┐
│ Barcode not found                       │
│ You can still log it in seconds.        │
│                                        │
│ [Search] [Photo]                        │
│ [Scan again]                            │
└────────────────────────────────────────┘
```

Copy source:
- Use `nutrition.barcode_not_found_title`, `nutrition.barcode_not_found_helper`, `nutrition.method_search`, `nutrition.method_photo`, `nutrition.barcode_scan_again`

Food database unavailable (banner):
```
┌────────────────────────────────────────┐
│ Food database unavailable               │
│ Showing cached results only             │
└────────────────────────────────────────┘
```

UX rule:
- Do not block logging; route user to manual search + custom foods.

Supplement interaction warning (inline):
```
┌────────────────────────────────────────┐
│ 💊 Supplements                          │
│ ⚠️ Calcium may reduce iron absorption.  │
│ [Adjust Timing] [Keep Schedule]         │
└────────────────────────────────────────┘
```

#### Full Screen Error (Severity 4)
```
┌────────────────────────────────────────┐
│                                        │
│                                        │
│              🔐                        │
│                                        │
│      Session Expired                   │
│                                        │
│  Your session has ended for security   │
│  reasons. Please sign in again.        │
│                                        │
│  ┌─────────────────────────────────┐   │
│  │         SIGN IN                 │   │
│  └─────────────────────────────────┘   │
│                                        │
│                                        │
└────────────────────────────────────────┘
```

---

## OFFLINE ERROR HANDLING

### Offline Queue

```swift
struct OfflineOperation: Codable {
    let id: UUID
    let createdAt: Date
    let type: OperationType
    let payload: Data
    let retryCount: Int
    let maxRetries: Int
    let priority: Priority
    
    enum OperationType: String, Codable {
        case foodLog
        case supplementLog
        case workoutLog
        case trainingPlanUpdate
        case medicalScanUpload
        case experimentMeasurement
        case userPreferenceUpdate
    }
    
    enum Priority: Int, Codable {
        case low = 0
        case normal = 1
        case high = 2
    }
}

class OfflineQueueManager {
    private var queue: [OfflineOperation] = []
    private let storage: LocalStorage
    private let networkMonitor: NWPathMonitor
    
    func enqueue(_ operation: OfflineOperation) {
        queue.append(operation)
        queue.sort { $0.priority.rawValue > $1.priority.rawValue }
        persistQueue()
    }
    
    func processQueue() async {
        guard networkMonitor.currentPath.status == .satisfied else { return }
        
        for operation in queue {
            do {
                try await execute(operation)
                removeFromQueue(operation.id)
            } catch {
                incrementRetryCount(operation.id)
                if operation.retryCount >= operation.maxRetries {
                    moveToDeadLetter(operation)
                }
            }
        }
    }
}
```

### Conflict Resolution

```swift
enum ConflictResolution {
    case serverWins           // Server data overwrites local
    case clientWins           // Local data overwrites server
    case lastWriteWins        // Most recent timestamp wins
    case merge                // Attempt to merge both
    case askUser              // Present choice to user
}

struct SyncConflict {
    let localData: Codable
    let serverData: Codable
    let localTimestamp: Date
    let serverTimestamp: Date
    let resolution: ConflictResolution
}
```

---

## LOGGING & MONITORING

### Error Logging Structure

```swift
struct ErrorLog: Codable {
    let id: UUID
    let timestamp: Date
    let errorCode: Int
    let category: String
    let message: String
    let stackTrace: String?
    let userContext: UserContext
    let deviceContext: DeviceContext
    let appContext: AppContext
}

struct UserContext: Codable {
    let userId: UUID?
    let sessionId: UUID
    let screenName: String
    let actionAttempted: String
}

struct DeviceContext: Codable {
    let deviceModel: String
    let osVersion: String
    let appVersion: String
    let locale: String
    let timezone: String
    let networkType: String
    let batteryLevel: Float
    let storageAvailable: Int64
}

struct AppContext: Codable {
    let launchTime: Date
    let foregroundTime: TimeInterval
    let memoryUsage: Int64
    let lastSuccessfulSync: Date?
}
```

### Log Levels

```swift
enum LogLevel: Int {
    case debug = 0    // Development only
    case info = 1     // Normal operations
    case warning = 2  // Potential issues
    case error = 3    // Recoverable errors
    case fatal = 4    // App-breaking errors
}

class Logger {
    static let shared = Logger()
    
    func log(
        _ level: LogLevel,
        _ message: String,
        error: Error? = nil,
        context: [String: Any]? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let entry = LogEntry(
            level: level,
            message: message,
            error: error,
            context: context,
            file: file,
            function: function,
            line: line,
            timestamp: Date()
        )
        
        // Local logging
        storeLocally(entry)
        
        // Remote logging (error+ only in production)
        if level >= .error {
            sendToRemote(entry)
        }
        
        // Console in debug
        #if DEBUG
        print("[\(level)] \(message)")
        #endif
    }
}
```

### Crash Reporting

```swift
struct CrashReport {
    let timestamp: Date
    let exception: String
    let stackTrace: String
    let threadInfo: [ThreadInfo]
    let recentLogs: [LogEntry]  // Last 50 entries
    let userContext: UserContext
    let deviceContext: DeviceContext
    
    // Anonymized data for privacy
    var anonymized: AnonymizedCrashReport {
        AnonymizedCrashReport(
            timestamp: timestamp,
            exception: exception,
            stackTrace: sanitizedStackTrace,
            deviceModel: deviceContext.deviceModel,
            osVersion: deviceContext.osVersion,
            appVersion: deviceContext.appVersion
        )
    }
}
```

---

## GRACEFUL DEGRADATION

### Feature Flags for Degraded Mode

```swift
struct DegradedModeFlags {
    var visionAPIAvailable: Bool = true
    var ragQueryAvailable: Bool = true
    var realtimeSyncAvailable: Bool = true
    var experimentAnalysisAvailable: Bool = true
    
    func canPerform(_ feature: Feature) -> Bool {
        switch feature {
        case .foodPhotoAnalysis:
            return visionAPIAvailable
        case .askQuestion:
            return ragQueryAvailable
        case .liveSync:
            return realtimeSyncAvailable
        case .experimentStatistics:
            return experimentAnalysisAvailable
        }
    }
}
```

### Fallback Behavior Matrix

| Feature | Primary | Fallback 1 | Fallback 2 | Final Fallback |
|---------|---------|------------|------------|----------------|
| Food Analysis | openai/gpt-4o (Vision) | openai/gpt-4-turbo | Core ML (local) | Manual entry |
| Recovery Score | Full calculation | Cached baseline | Simple estimate | "Data pending" |
| Insights | RAG query | Pre-computed | Generic tips | None |
| Experiments | Full statistics | Simple mean comparison | Visual only | None |
| Sync | Realtime | Batch (hourly) | Manual only | Offline mode |

---

## ERROR RECOVERY FLOWS

### HealthKit Permission Recovery

```
User denies HealthKit → 
  Show explanation modal →
  Offer "Open Settings" →
  Monitor for permission grant →
  Resume normal flow
```

### Focus Control Permission Recovery

```
User selects Guardian →
  Check Focus Control permission:
    - Granted → Apply rules
    - Denied → Show inline banner + fallback to Protective
    - Restricted → Explain restriction + fallback to Protective
```

### Notification Permission Revoked

```
System permission revoked →
  Disable all non‑critical notifications →
  Show banner on next app open →
  Offer “Open Settings” CTA
```

### Vision API Failure Recovery

```
Photo analysis fails →
  Check error type:
    - Blurry? → Offer retake with tips
    - No food? → Offer retake or manual
    - API down? → Queue for retry, offer manual
    - Quota? → Show upgrade or wait
```

### Session Expiry Recovery

```
Any API returns 401 →
  Check token refresh possible:
    - Yes → Silently refresh, retry original
    - No → Clear session, show login
  Preserve pending offline operations
```

---

## TESTING ERROR HANDLING

### Error Simulation

```swift
#if DEBUG
class ErrorSimulator {
    static var simulatedErrors: [ErrorCategory: Error] = [:]
    
    static func simulateNetworkError(_ error: NetworkError) {
        simulatedErrors[.network] = error
    }
    
    static func clearSimulations() {
        simulatedErrors.removeAll()
    }
}

// Usage in API client:
func request<T>(_ endpoint: Endpoint) async throws -> T {
    #if DEBUG
    if let simulated = ErrorSimulator.simulatedErrors[.network] {
        throw simulated
    }
    #endif
    
    // Normal implementation...
}
#endif
```

### Test Cases

```swift
class ErrorHandlingTests: XCTestCase {
    func testNetworkRetryExponentialBackoff() async {
        // Verify retry timing follows exponential pattern
    }
    
    func testOfflineQueuePersistence() async {
        // Verify operations survive app restart
    }
    
    func testConflictResolutionLastWriteWins() async {
        // Verify correct data is kept
    }
    
    func testGracefulDegradationVisionUnavailable() async {
        // Verify fallback to manual entry works
    }
    
    func testErrorLoggingAnonymization() async {
        // Verify PII is stripped from crash reports
    }
}
```

---

This error handling specification ensures robust, user-friendly error recovery across all app components while maintaining privacy and providing actionable debugging information.

---

## CRASH RECOVERY & DATABASE CORRUPTION

### Automatic SQLite Backup Strategy

**Implementation:**
- GRDB creates an automatic backup of the local SQLite database **daily** at the first app launch of the day.
- Backup is stored in the App Group shared container at `AppGroup/Backups/lifeos_backup_{YYYYMMDD}.sqlite`.
- **Retention:** Keep the 3 most recent backups. Delete older ones automatically.
- Backup is performed using SQLite's `VACUUM INTO` command (safe, atomic, no locking issues during normal operation).
- Backup does **not** include media files (photos, PDFs). These are stored separately and can be re-downloaded from Supabase Storage.

### Corruption Detection

Corruption is detected in the following scenarios:
1. **GRDB migration failure** (`DatabaseError.migrationFailed` / code 5004): migration script encounters unexpected schema state.
2. **SQLite integrity check failure** (`DatabaseError.localCorruption` / code 5005): detected via `PRAGMA integrity_check` run during app launch.
3. **Read/write exception** at runtime: unexpected SQLITE_CORRUPT, SQLITE_NOTADB, or SQLITE_IOERR errors.

### Restoration Flow

**Step 1: Attempt local backup restoration**
```
User sees: Full-screen overlay with spinner
Copy: "Restoring your data..."
Subtext: "This should take less than a minute."
```
- App copies the most recent valid backup over the corrupted database.
- Runs `PRAGMA integrity_check` on the restored file.
- If valid: resume normal operation. Show toast: "Data restored successfully. Some recent entries may need re-syncing."
- If all 3 backups are invalid: proceed to Step 2.

**Step 2: Server re-pull (if local recovery fails)**
```
User sees: Full-screen overlay
Copy: "Restoring from server..."
Subtext: "We're downloading your data. This may take a few minutes."
```
- App deletes the corrupted local database.
- Creates a fresh GRDB database with current migrations.
- Resets all `sync_state` watermarks to `NULL`.
- Triggers a full pull sync (all tables, no watermark filter).
- **Limitation:** Any data that was **never synced** (stuck in Outbox) is lost. The user is warned: "Some offline entries that hadn't synced may be lost."

**Step 3: Anonymous user with no server data (worst case)**
```
User sees: Full-screen overlay
Copy: "We couldn't restore your data."
Subtext: "Please link your account to prevent future data loss."
CTA: [Start Fresh] [Contact Support]
```
- "Start Fresh" resets the local database and restarts onboarding.
- "Contact Support" opens a pre-filled support email with device info and corruption details (no PII).

### Corruption Analytics

| Event | Properties |
|-------|------------|
| `app.database_corruption_detected` | `corruption_type`, `db_size_bytes`, `days_since_last_backup` |
| `app.database_restore_attempted` | `restore_source` (`local_backup` \| `server_pull` \| `fresh_start`), `success` |
| `app.database_restore_completed` | `restore_source`, `duration_seconds`, `rows_recovered` |
