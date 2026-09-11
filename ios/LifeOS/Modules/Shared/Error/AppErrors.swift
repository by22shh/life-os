// MARK: - App Errors
// Source of truth: life_os_error_handling.md
// Per-module typed errors for structured error handling.
// All user-facing strings use NSLocalizedString for l10n support.

import Foundation

// MARK: - Nutrition Errors

enum NutritionError: LocalizedError {
    case invalidMacros(reason: String)
    case imageTooLarge(maxMB: Int)
    case barcodeNotFound(barcode: String)
    case catalogUnavailable
    case templateEmpty
    case templateNotFound
    case batchRecipeEmpty
    case batchRecipeNotFound
    case batchRecipeSaveFailed
    case duplicateLog(existingId: UUID)
    case mealNotFound
    case undoExpired
    case invalidMealItem(reason: String)
    case invalidBatchRecipe(reason: String)
    case batchPortionExceedsRemaining(maxGrams: Double)

    var errorDescription: String? {
        switch self {
        case .invalidMacros(let reason):
            return String(format: NSLocalizedString("error.nutrition.invalid_macros", value: "Invalid macronutrient data: %@", comment: "Nutrition error: invalid macros"), reason)
        case .imageTooLarge(let max):
            return String(format: NSLocalizedString("error.nutrition.image_too_large", value: "Photo exceeds %d MB", comment: "Nutrition error: image too large"), max)
        case .barcodeNotFound(let code):
            return String(format: NSLocalizedString("error.nutrition.barcode_not_found", value: "Product with barcode %@ not found", comment: "Nutrition error: barcode not found"), code)
        case .catalogUnavailable:
            return NSLocalizedString("error.nutrition.catalog_unavailable", value: "Food catalog temporarily unavailable", comment: "Nutrition error: catalog unavailable")
        case .templateEmpty:
            return NSLocalizedString("error.nutrition.template_empty", value: "Template contains no food items", comment: "Nutrition error: empty template")
        case .templateNotFound:
            return NSLocalizedString("error.nutrition.template_not_found", value: "Template not found", comment: "Nutrition error: template not found")
        case .batchRecipeEmpty:
            return NSLocalizedString("error.nutrition.batch_recipe_empty", value: "Batch recipe contains no ingredients", comment: "Nutrition error: empty batch recipe")
        case .batchRecipeNotFound:
            return NSLocalizedString("error.nutrition.batch_recipe_not_found", value: "Batch recipe not found", comment: "Nutrition error: batch recipe not found")
        case .batchRecipeSaveFailed:
            return NSLocalizedString("error.nutrition.batch_recipe_save_failed", value: "Batch recipe could not be saved. Please try again.", comment: "Nutrition error: batch recipe save failed")
        case .duplicateLog:
            return NSLocalizedString("error.nutrition.duplicate_log", value: "This meal has already been logged", comment: "Nutrition error: duplicate log")
        case .mealNotFound:
            return NSLocalizedString("error.nutrition.meal_not_found", value: "Meal not found", comment: "Nutrition error: meal not found")
        case .undoExpired:
            return NSLocalizedString("error.nutrition.undo_expired", value: "Undo is no longer available for this meal", comment: "Nutrition error: meal undo expired")
        case .invalidMealItem(let reason):
            return String(format: NSLocalizedString("error.nutrition.invalid_meal_item", value: "Invalid meal item: %@", comment: "Nutrition error: invalid meal item"), reason)
        case .invalidBatchRecipe(let reason):
            return String(format: NSLocalizedString("error.nutrition.invalid_batch_recipe", value: "Invalid batch recipe: %@", comment: "Nutrition error: invalid batch recipe"), reason)
        case .batchPortionExceedsRemaining(let maxGrams):
            return String(
                format: NSLocalizedString(
                    "error.nutrition.batch_portion_exceeds_remaining",
                    value: "Portion exceeds remaining batch weight. Max available: %.0f g",
                    comment: "Nutrition error: batch portion exceeds remaining"
                ),
                maxGrams
            )
        }
    }
}

// MARK: - Training Errors

enum TrainingError: LocalizedError {
    case invalidSet(reason: String)
    case workoutAlreadyActive
    case planLimitReached(max: Int)
    case planRequiresCloudSync
    case exerciseNotFound(id: UUID)
    case workoutNotFound
    case undoExpired
    case importedWorkoutEditRestricted

    var errorDescription: String? {
        switch self {
        case .invalidSet(let reason):
            return String(format: NSLocalizedString("error.training.invalid_set", value: "Invalid set data: %@", comment: "Training error: invalid set"), reason)
        case .workoutAlreadyActive:
            return NSLocalizedString("error.training.workout_active", value: "A workout is already in progress", comment: "Training error: workout already active")
        case .planLimitReached(let max):
            return String(format: NSLocalizedString("error.training.plan_limit", value: "Maximum %d plans reached", comment: "Training error: plan limit"), max)
        case .planRequiresCloudSync:
            return NSLocalizedString("error.training.plan_requires_cloud_sync", value: "Training plans require a synced cloud account", comment: "Training error: training plans require cloud sync")
        case .exerciseNotFound:
            return NSLocalizedString("error.training.exercise_not_found", value: "Exercise not found", comment: "Training error: exercise not found")
        case .workoutNotFound:
            return NSLocalizedString("error.training.workout_not_found", value: "Workout not found", comment: "Training error: workout not found")
        case .undoExpired:
            return NSLocalizedString("error.training.undo_expired", value: "Undo is no longer available for this workout", comment: "Training error: undo expired")
        case .importedWorkoutEditRestricted:
            return NSLocalizedString("error.training.imported_workout_edit_restricted", value: "Imported workouts can only update notes, timing, and effort", comment: "Training error: imported workout edit restricted")
        }
    }
}

// MARK: - Supplements Errors

enum SupplementsError: LocalizedError {
    case scheduleConflict
    case invalidDose
    case reminderWindowInvalid

    var errorDescription: String? {
        switch self {
        case .scheduleConflict:
            return NSLocalizedString("error.supplements.schedule_conflict", value: "Schedule conflicts with an existing supplement reminder", comment: "Supplements error: schedule conflict")
        case .invalidDose:
            return NSLocalizedString("error.supplements.invalid_dose", value: "Dose is outside a safe range", comment: "Supplements error: invalid dose")
        case .reminderWindowInvalid:
            return NSLocalizedString("error.supplements.reminder_window", value: "Reminder time falls inside quiet hours", comment: "Supplements error: reminder window invalid")
        }
    }
}

// MARK: - Labs Errors

enum LabsError: LocalizedError {
    case unsupportedDocument
    case extractionFailed
    case lowConfidenceExtraction

    var errorDescription: String? {
        switch self {
        case .unsupportedDocument:
            return NSLocalizedString("error.labs.unsupported_document", value: "This lab document format is not supported yet", comment: "Labs error: unsupported document")
        case .extractionFailed:
            return NSLocalizedString("error.labs.extraction_failed", value: "Unable to extract markers from this scan", comment: "Labs error: extraction failed")
        case .lowConfidenceExtraction:
            return NSLocalizedString("error.labs.low_confidence", value: "Low confidence extraction. Please review values before saving.", comment: "Labs error: low confidence extraction")
        }
    }
}

// MARK: - Settings Errors

enum SettingsError: LocalizedError {
    case saveFailed
    case exportFailed
    case importFailed
    case deletionFailed
    case consentVersionMismatch

    var errorDescription: String? {
        switch self {
        case .saveFailed:
            return NSLocalizedString("error.settings.save_failed", value: "Unable to save settings right now", comment: "Settings error: save failed")
        case .exportFailed:
            return NSLocalizedString("error.settings.export_failed", value: "Unable to prepare your export right now", comment: "Settings error: export failed")
        case .importFailed:
            return NSLocalizedString("error.settings.import_failed", value: "Unable to import this archive", comment: "Settings error: archive import failed")
        case .deletionFailed:
            return NSLocalizedString("error.settings.deletion_failed", value: "Account deletion request failed", comment: "Settings error: deletion failed")
        case .consentVersionMismatch:
            return NSLocalizedString("error.settings.consent_version", value: "Please re-confirm consent for the latest policy version", comment: "Settings error: consent version mismatch")
        }
    }
}

// MARK: - Sync Errors

enum SyncError: LocalizedError {
    case networkUnavailable
    case authRequired
    case serverError(code: Int, message: String?)
    case conflictResolutionFailed(table: String)
    case watermarkCorrupted(table: String)
    case maxRetriesExceeded(eventId: UUID)

    var errorDescription: String? {
        switch self {
        case .networkUnavailable:
            return NSLocalizedString("error.sync.network_unavailable", value: "No internet connection", comment: "Sync error: no network")
        case .authRequired:
            return NSLocalizedString("error.sync.auth_required", value: "Re-authentication required", comment: "Sync error: auth required")
        case .serverError(let code, let msg):
            return String(format: NSLocalizedString("error.sync.server_error", value: "Server error %d: %@", comment: "Sync error: server error"), code, msg ?? "")
        case .conflictResolutionFailed(let table):
            return String(format: NSLocalizedString("error.sync.conflict", value: "Data conflict in %@", comment: "Sync error: conflict"), table)
        case .watermarkCorrupted(let table):
            return String(format: NSLocalizedString("error.sync.watermark_corrupted", value: "Sync watermark corrupted for %@", comment: "Sync error: watermark corrupted"), table)
        case .maxRetriesExceeded:
            return NSLocalizedString("error.sync.max_retries", value: "Maximum send attempts exceeded", comment: "Sync error: max retries")
        }
    }
}

// MARK: - HealthKit Errors

enum HealthKitError: LocalizedError {
    case notAvailable
    case authorizationDenied
    case noDataForDate(Date)
    case invalidSample(reason: String)
    case sdnnTooLow(value: Double)

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return NSLocalizedString("error.healthkit.not_available", value: "HealthKit is not available on this device", comment: "HealthKit error: not available")
        case .authorizationDenied:
            return NSLocalizedString("error.healthkit.auth_denied", value: "Health data access denied", comment: "HealthKit error: auth denied")
        case .noDataForDate:
            return NSLocalizedString("error.healthkit.no_data", value: "No data available for this date", comment: "HealthKit error: no data")
        case .invalidSample(let reason):
            return String(format: NSLocalizedString("error.healthkit.invalid_sample", value: "Invalid measurement: %@", comment: "HealthKit error: invalid sample"), reason)
        case .sdnnTooLow(let v):
            return String(format: NSLocalizedString("error.healthkit.sdnn_too_low", value: "SDNN too low (%.1fms) — rejected as noise", comment: "HealthKit error: SDNN too low"), v)
        }
    }
}

// MARK: - Recovery Errors

enum RecoveryError: LocalizedError {
    case insufficientBaseline(daysAvailable: Int, daysRequired: Int)
    case noPhysiologicalState(date: String)
    case computationFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .insufficientBaseline(let available, let required):
            return String(format: NSLocalizedString("error.recovery.insufficient_baseline", value: "Not enough data days (%d/%d) for baseline calculation", comment: "Recovery error: insufficient baseline"), available, required)
        case .noPhysiologicalState(let date):
            return String(format: NSLocalizedString("error.recovery.no_state", value: "No physiological data for %@", comment: "Recovery error: no state"), date)
        case .computationFailed(let reason):
            return String(format: NSLocalizedString("error.recovery.computation_failed", value: "Computation error: %@", comment: "Recovery error: computation failed"), reason)
        }
    }
}

// MARK: - Hydration Errors

enum HydrationError: LocalizedError {
    case invalidAmount(reason: String)
    case targetNotSet
    case dailyLimitExceeded(maxMl: Int)

    var errorDescription: String? {
        switch self {
        case .invalidAmount(let reason):
            return String(format: NSLocalizedString("error.hydration.invalid_amount", value: "Invalid hydration amount: %@", comment: "Hydration error: invalid amount"), reason)
        case .targetNotSet:
            return NSLocalizedString("error.hydration.target_not_set", value: "Daily hydration target not configured", comment: "Hydration error: target not set")
        case .dailyLimitExceeded(let max):
            return String(format: NSLocalizedString("error.hydration.daily_limit", value: "Daily hydration exceeds reasonable limit (%d ml)", comment: "Hydration error: daily limit exceeded"), max)
        }
    }
}

// MARK: - Wellness Errors

enum WellnessError: LocalizedError {
    case checkAlreadyCompleted(date: String)
    case invalidResponse(field: String)
    case pss4OutOfRange

    var errorDescription: String? {
        switch self {
        case .checkAlreadyCompleted(let date):
            return String(format: NSLocalizedString("error.wellness.already_completed", value: "Wellness check already completed for %@", comment: "Wellness error: already completed"), date)
        case .invalidResponse(let field):
            return String(format: NSLocalizedString("error.wellness.invalid_response", value: "Invalid response for field: %@", comment: "Wellness error: invalid response"), field)
        case .pss4OutOfRange:
            return NSLocalizedString("error.wellness.pss4_out_of_range", value: "PSS-4 score must be between 0 and 16", comment: "Wellness error: PSS-4 out of range")
        }
    }
}

// MARK: - Experiment Errors

enum ExperimentError: LocalizedError {
    case notFound
    case alreadyActive(existingId: UUID)
    case invalidProtocol(reason: String)
    case durationExceeded(maxDays: Int)
    case insufficientBaselineDays(required: Int)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return NSLocalizedString(
                "error.experiment.not_found",
                value: "Experiment not found",
                comment: "Experiment error: not found"
            )
        case .alreadyActive:
            return NSLocalizedString("error.experiment.already_active", value: "An experiment is already active", comment: "Experiment error: already active")
        case .invalidProtocol(let reason):
            return String(format: NSLocalizedString("error.experiment.invalid_protocol", value: "Invalid experiment protocol: %@", comment: "Experiment error: invalid protocol"), reason)
        case .durationExceeded(let max):
            return String(format: NSLocalizedString("error.experiment.duration_exceeded", value: "Experiment duration exceeds maximum (%d days)", comment: "Experiment error: duration exceeded"), max)
        case .insufficientBaselineDays(let required):
            return String(format: NSLocalizedString("error.experiment.insufficient_baseline", value: "Need at least %d baseline days before starting", comment: "Experiment error: insufficient baseline"), required)
        }
    }
}

// MARK: - Privacy Errors

enum PrivacyError: LocalizedError {
    case exportAlreadyInProgress
    case exportNotReady
    case deletionScheduled(at: Date)

    var errorDescription: String? {
        switch self {
        case .exportAlreadyInProgress:
            return NSLocalizedString("error.privacy.export_in_progress", value: "Data export is already in progress", comment: "Privacy error: export in progress")
        case .exportNotReady:
            return NSLocalizedString("error.privacy.export_not_ready", value: "Data export is not ready yet", comment: "Privacy error: export not ready")
        case .deletionScheduled(let date):
            return String(format: NSLocalizedString("error.privacy.deletion_scheduled", value: "Account deletion scheduled for %@", comment: "Privacy error: deletion scheduled"), "\(date)")
        }
    }
}
