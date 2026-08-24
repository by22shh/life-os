// MARK: - GRDB Record Conformances
// Maps Swift models to GRDB FetchableRecord + PersistableRecord.

import Foundation
import GRDB

/// Shared GRDB mapping policy:
/// app models use lowerCamelCase while SQL schema uses snake_case.
protocol SnakeCaseGRDBRecord: FetchableRecord, PersistableRecord {}

extension SnakeCaseGRDBRecord {
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy {
        .convertFromSnakeCase
    }

    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy {
        .convertToSnakeCase
    }

    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }
}

private enum GRDBRecordDecoder {
    static func required<T: DatabaseValueConvertible>(
        _ row: Row,
        column: String,
        default defaultValue: @autoclosure () -> T
    ) -> T {
        if let value: T = row[column] {
            return value
        }
        assertionFailure("Failed to decode required column \(column)")
        return defaultValue()
    }

    static func optional<T: DatabaseValueConvertible>(_ row: Row, column: String) -> T? {
        row[column]
    }

    static func requiredUUID(
        _ row: Row,
        column: String,
        default defaultValue: @autoclosure () -> UUID = UUID()
    ) -> UUID {
        if let uuid = MixedUUIDStorage.decode(from: row, column: column) {
            return uuid
        }
        assertionFailure("Failed to decode UUID column \(column)")
        return defaultValue()
    }

    static func optionalUUID(_ row: Row, column: String) -> UUID? {
        MixedUUIDStorage.decode(from: row, column: column)
    }

    static func requiredEnum<T: RawRepresentable>(
        _ row: Row,
        column: String,
        default defaultValue: @autoclosure () -> T
    ) -> T where T.RawValue == String {
        if let rawValue: String = row[column],
           let value = T(rawValue: rawValue) {
            return value
        }
        assertionFailure("Failed to decode enum column \(column)")
        return defaultValue()
    }

    static func optionalEnum<T: RawRepresentable>(_ row: Row, column: String) -> T? where T.RawValue == String {
        guard let rawValue: String = row[column] else { return nil }
        return T(rawValue: rawValue)
    }

    static func encryptedString(_ row: Row, column: String) -> String? {
        let value: String? = row[column]
        return FieldEncryption.decryptStoredString(value)
    }

    static func encryptedDouble(_ row: Row, column: String) -> Double? {
        let value: DatabaseValue = row[column]
        if value.isNull {
            return nil
        }
        if let numeric = Double.fromDatabaseValue(value) {
            return numeric
        }
        if let integer = Int.fromDatabaseValue(value) {
            return Double(integer)
        }
        if let storedValue = String.fromDatabaseValue(value) {
            return FieldEncryption.decryptStoredDouble(storedValue)
        }
        assertionFailure("Failed to decode encrypted numeric column \(column)")
        return nil
    }

    static func requiredEncryptedDouble(
        _ row: Row,
        column: String,
        default defaultValue: @autoclosure () -> Double = 0
    ) -> Double {
        if let value = encryptedDouble(row, column: column) {
            return value
        }
        assertionFailure("Failed to decode required encrypted numeric column \(column)")
        return defaultValue()
    }
}

private enum GRDBSensitiveEncoder {
    static func storageString(_ value: String?, column: String) -> String? {
        FieldEncryption.storageStringForPersistence(value, column: column)
    }

    static func storageDouble(_ value: Double?, column: String) -> String? {
        FieldEncryption.storageDoubleForPersistence(value, column: column)
    }
}

// MARK: - Outbox Event

extension OutboxEvent: SnakeCaseGRDBRecord {
    static let databaseTableName = "outbox_events"
    // OutboxEvent already declares explicit snake_case CodingKeys in SyncModels.swift.
    // Applying convertFromSnakeCase here would remap DB columns twice and break decoding.
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy {
        .useDefaultKeys
    }

    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy {
        .useDefaultKeys
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let status = Column(CodingKeys.status)
        static let priority = Column(CodingKeys.priority)
        static let createdAtLocal = Column(CodingKeys.createdAtLocal)
    }
}

// MARK: - Sync State

extension SyncState: SnakeCaseGRDBRecord {
    static let databaseTableName = "sync_state"
    // SyncState declares explicit snake_case CodingKeys in SyncModels.swift.
    // Use default keys to avoid applying snake_case conversion twice.
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy {
        .useDefaultKeys
    }

    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy {
        .useDefaultKeys
    }
}

extension SyncRowCursor: SnakeCaseGRDBRecord {
    static let databaseTableName = "sync_row_state"
    // SyncRowCursor also provides explicit snake_case CodingKeys.
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy {
        .useDefaultKeys
    }

    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy {
        .useDefaultKeys
    }
}

// MARK: - User

extension User: SnakeCaseGRDBRecord {
    static let databaseTableName = "users"
}

// MARK: - User Health Flags

extension UserHealthFlags: SnakeCaseGRDBRecord {
    static let databaseTableName = "user_health_flags"
}

// MARK: - Notification Settings

extension NotificationSettings: SnakeCaseGRDBRecord {
    static let databaseTableName = "notification_settings"
}

// MARK: - Physiological State

extension PhysiologicalState: SnakeCaseGRDBRecord {
    static let databaseTableName = "physiological_states"
}

extension TimeZoneHistoryEntry: SnakeCaseGRDBRecord {
    static let databaseTableName = "timezone_history"
}

// MARK: - Nutrition

extension FoodLog: SnakeCaseGRDBRecord {
    static let databaseTableName = "food_logs"

    init(row: Row) {
        id = GRDBRecordDecoder.requiredUUID(row, column: "id")
        userId = GRDBRecordDecoder.requiredUUID(row, column: "user_id")
        createdAt = GRDBRecordDecoder.required(row, column: "created_at", default: Date())
        updatedAt = GRDBRecordDecoder.required(row, column: "updated_at", default: Date())
        loggedAt = GRDBRecordDecoder.required(row, column: "logged_at", default: Date())
        loggedDate = GRDBRecordDecoder.required(row, column: "logged_date", default: "")
        loggedTimezone = GRDBRecordDecoder.optional(row, column: "logged_timezone")
        loggedUtcOffsetMinutes = GRDBRecordDecoder.optional(row, column: "logged_utc_offset_minutes")
        locationLat = GRDBRecordDecoder.encryptedDouble(row, column: "location_lat")
        locationLng = GRDBRecordDecoder.encryptedDouble(row, column: "location_lng")
        inputMethod = GRDBRecordDecoder.requiredEnum(row, column: "input_method", default: .manual)
        mealType = GRDBRecordDecoder.optionalEnum(row, column: "meal_type")
        context = GRDBRecordDecoder.optionalEnum(row, column: "context")
        preWorkout = GRDBRecordDecoder.required(row, column: "pre_workout", default: false)
        postWorkout = GRDBRecordDecoder.required(row, column: "post_workout", default: false)
        minutesSinceWorkout = GRDBRecordDecoder.optional(row, column: "minutes_since_workout")
        calories = GRDBRecordDecoder.required(row, column: "calories", default: 0)
        proteinG = GRDBRecordDecoder.required(row, column: "protein_g", default: 0)
        fatG = GRDBRecordDecoder.required(row, column: "fat_g", default: 0)
        carbsG = GRDBRecordDecoder.required(row, column: "carbs_g", default: 0)
        fiberG = GRDBRecordDecoder.optional(row, column: "fiber_g")
        sugarG = GRDBRecordDecoder.optional(row, column: "sugar_g")
        alcoholUnits = GRDBRecordDecoder.optional(row, column: "alcohol_units")
        caffeineMg = GRDBRecordDecoder.optional(row, column: "caffeine_mg")
        sodiumMg = GRDBRecordDecoder.optional(row, column: "sodium_mg")
        potassiumMg = GRDBRecordDecoder.optional(row, column: "potassium_mg")
        calciumMg = GRDBRecordDecoder.optional(row, column: "calcium_mg")
        ironMg = GRDBRecordDecoder.optional(row, column: "iron_mg")
        vitaminDMcg = GRDBRecordDecoder.optional(row, column: "vitamin_d_mcg")
        vitaminB12Mcg = GRDBRecordDecoder.optional(row, column: "vitamin_b12_mcg")
        imageUrl = GRDBRecordDecoder.optional(row, column: "image_url")
        imageUploadedAt = GRDBRecordDecoder.optional(row, column: "image_uploaded_at")
        aiDetectedItems = GRDBRecordDecoder.optional(row, column: "ai_detected_items")
        aiConfidence = GRDBRecordDecoder.optional(row, column: "ai_confidence")
        aiContextAnalysis = GRDBRecordDecoder.optional(row, column: "ai_context_analysis")
        needsReview = GRDBRecordDecoder.required(row, column: "needs_review", default: false)
        userCorrected = GRDBRecordDecoder.required(row, column: "user_corrected", default: false)
        userNotes = GRDBRecordDecoder.optional(row, column: "user_notes")
        aiFeedback = GRDBRecordDecoder.optionalEnum(row, column: "ai_feedback")
        aiFeedbackDetails = GRDBRecordDecoder.optional(row, column: "ai_feedback_details")
        aiFeedbackAt = GRDBRecordDecoder.optional(row, column: "ai_feedback_at")
        deletedAt = GRDBRecordDecoder.optional(row, column: "deleted_at")
        deletedReason = GRDBRecordDecoder.optionalEnum(row, column: "deleted_reason")
        syncedToVectorDb = GRDBRecordDecoder.required(row, column: "synced_to_vector_db", default: false)
        vectorId = GRDBRecordDecoder.optional(row, column: "vector_id")
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = MixedUUIDStorage.encode(id)
        container["user_id"] = MixedUUIDStorage.encode(userId)
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
        container["logged_at"] = loggedAt
        container["logged_date"] = loggedDate
        container["logged_timezone"] = loggedTimezone
        container["logged_utc_offset_minutes"] = loggedUtcOffsetMinutes
        container["location_lat"] = GRDBSensitiveEncoder.storageDouble(locationLat, column: "location_lat")
        container["location_lng"] = GRDBSensitiveEncoder.storageDouble(locationLng, column: "location_lng")
        container["input_method"] = inputMethod.rawValue
        container["meal_type"] = mealType?.rawValue
        container["context"] = context?.rawValue
        container["pre_workout"] = preWorkout
        container["post_workout"] = postWorkout
        container["minutes_since_workout"] = minutesSinceWorkout
        container["calories"] = calories
        container["protein_g"] = proteinG
        container["fat_g"] = fatG
        container["carbs_g"] = carbsG
        container["fiber_g"] = fiberG
        container["sugar_g"] = sugarG
        container["alcohol_units"] = alcoholUnits
        container["caffeine_mg"] = caffeineMg
        container["sodium_mg"] = sodiumMg
        container["potassium_mg"] = potassiumMg
        container["calcium_mg"] = calciumMg
        container["iron_mg"] = ironMg
        container["vitamin_d_mcg"] = vitaminDMcg
        container["vitamin_b12_mcg"] = vitaminB12Mcg
        container["image_url"] = imageUrl
        container["image_uploaded_at"] = imageUploadedAt
        container["ai_detected_items"] = aiDetectedItems
        container["ai_confidence"] = aiConfidence
        container["ai_context_analysis"] = aiContextAnalysis
        container["needs_review"] = needsReview
        container["user_corrected"] = userCorrected
        container["user_notes"] = userNotes
        container["ai_feedback"] = aiFeedback?.rawValue
        container["ai_feedback_details"] = aiFeedbackDetails
        container["ai_feedback_at"] = aiFeedbackAt
        container["deleted_at"] = deletedAt
        container["deleted_reason"] = deletedReason?.rawValue
        container["synced_to_vector_db"] = syncedToVectorDb
        container["vector_id"] = vectorId
    }

    func aroundSave(_ db: Database, save: () throws -> PersistenceSuccess) throws {
        guard locationLat != nil || locationLng != nil else {
            _ = try save()
            return
        }
        _ = try FieldEncryption.withPreparedPersistenceContext(save)
    }
}

extension FoodItem: SnakeCaseGRDBRecord {
    static let databaseTableName = "food_items"
}

extension DailyNutritionTarget: SnakeCaseGRDBRecord {
    static let databaseTableName = "daily_nutrition_targets"
}

extension FoodCatalogItem: SnakeCaseGRDBRecord {
    static let databaseTableName = "food_catalog_items"
}

extension UserFood: SnakeCaseGRDBRecord {
    static let databaseTableName = "user_foods"
}

extension UserFoodFavorite: SnakeCaseGRDBRecord {
    static let databaseTableName = "user_food_favorites"
}

extension BatchRecipe: SnakeCaseGRDBRecord {
    static let databaseTableName = "batch_recipes"

    // BatchRecipe declares explicit snake_case CodingKeys in NutritionModels.swift.
    // Using default keys avoids applying snake_case conversion twice.
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy {
        .useDefaultKeys
    }

    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy {
        .useDefaultKeys
    }
}

extension BatchRecipeIngredient: SnakeCaseGRDBRecord {
    static let databaseTableName = "batch_recipe_ingredients"
}

extension MealTemplate: SnakeCaseGRDBRecord {
    static let databaseTableName = "meal_templates"
}

// MARK: - Training

extension WorkoutSession: SnakeCaseGRDBRecord {
    static let databaseTableName = "workout_sessions"
}

extension WorkoutExercise: SnakeCaseGRDBRecord {
    static let databaseTableName = "workout_exercises"
}

extension WorkoutSet: SnakeCaseGRDBRecord {
    static let databaseTableName = "workout_sets"
}

extension ExerciseCatalogEntry: SnakeCaseGRDBRecord {
    static let databaseTableName = "exercise_catalog"
}

extension TrainingPlan: SnakeCaseGRDBRecord {
    static let databaseTableName = "training_plans"
}

extension TrainingPlanSession: SnakeCaseGRDBRecord {
    static let databaseTableName = "training_plan_sessions"
}

extension TrainingLoad: SnakeCaseGRDBRecord {
    static let databaseTableName = "training_loads"
}

// MARK: - Supplements

extension SupplementCatalogEntry: SnakeCaseGRDBRecord {
    static let databaseTableName = "supplement_catalog"
}

extension UserSupplement: SnakeCaseGRDBRecord {
    static let databaseTableName = "user_supplements"
}

extension SupplementLog: SnakeCaseGRDBRecord {
    static let databaseTableName = "supplement_logs"
}

// MARK: - Health

extension WellnessCheck: SnakeCaseGRDBRecord {
    static let databaseTableName = "wellness_checks"
}

extension BodyComposition: SnakeCaseGRDBRecord {
    static let databaseTableName = "body_composition"
}

extension HydrationLog: SnakeCaseGRDBRecord {
    static let databaseTableName = "hydration_logs"
}

// MARK: - Labs

extension MedicalScan: SnakeCaseGRDBRecord {
    static let databaseTableName = "medical_scans"

    init(row: Row) {
        id = GRDBRecordDecoder.requiredUUID(row, column: "id")
        userId = GRDBRecordDecoder.requiredUUID(row, column: "user_id")
        createdAt = GRDBRecordDecoder.required(row, column: "created_at", default: Date())
        updatedAt = GRDBRecordDecoder.required(row, column: "updated_at", default: Date())
        scanType = GRDBRecordDecoder.requiredEnum(row, column: "scan_type", default: .other)
        status = GRDBRecordDecoder.requiredEnum(row, column: "status", default: .pending)
        imageUrl = GRDBRecordDecoder.encryptedString(row, column: "image_url")
        imageUploadedAt = GRDBRecordDecoder.optional(row, column: "image_uploaded_at")
        originalImageUrl = GRDBRecordDecoder.encryptedString(row, column: "original_image_url")
        aiExtractionRaw = GRDBRecordDecoder.optional(row, column: "ai_extraction_raw")
        aiConfidence = GRDBRecordDecoder.optional(row, column: "ai_confidence")
        ocrConfidence = GRDBRecordDecoder.optional(row, column: "ocr_confidence")
        extractionStatus = GRDBRecordDecoder.optional(row, column: "extraction_status")
        extractionError = GRDBRecordDecoder.optional(row, column: "extraction_error")
        markersExtracted = GRDBRecordDecoder.optional(row, column: "markers_extracted")
        diagnosesExtracted = GRDBRecordDecoder.optional(row, column: "diagnoses_extracted")
        processedData = GRDBRecordDecoder.optional(row, column: "processed_data")
        needsReview = GRDBRecordDecoder.required(row, column: "needs_review", default: false)
        userReviewed = GRDBRecordDecoder.required(row, column: "user_reviewed", default: false)
        userReviewedAt = GRDBRecordDecoder.optional(row, column: "user_reviewed_at")
        manuallyVerified = GRDBRecordDecoder.required(row, column: "manually_verified", default: false)
        pinnedByUser = GRDBRecordDecoder.required(row, column: "pinned_by_user", default: false)
        scanDate = GRDBRecordDecoder.optional(row, column: "scan_date")
        labName = GRDBRecordDecoder.optional(row, column: "lab_name")
        documentLanguage = GRDBRecordDecoder.optional(row, column: "document_language")
        sourceFileSha256 = GRDBRecordDecoder.optional(row, column: "source_file_sha256")
        storageMode = GRDBRecordDecoder.optional(row, column: "storage_mode")
        storeOriginalInCloud = GRDBRecordDecoder.optional(row, column: "store_original_in_cloud")
        scheduledDeletionAt = GRDBRecordDecoder.optional(row, column: "scheduled_deletion_at")
        notes = GRDBRecordDecoder.optional(row, column: "notes")
        deletedAt = GRDBRecordDecoder.optional(row, column: "deleted_at")
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = MixedUUIDStorage.encode(id)
        container["user_id"] = MixedUUIDStorage.encode(userId)
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
        container["scan_type"] = scanType.rawValue
        container["status"] = status.rawValue
        container["image_url"] = GRDBSensitiveEncoder.storageString(imageUrl, column: "image_url")
        container["image_uploaded_at"] = imageUploadedAt
        container["original_image_url"] = GRDBSensitiveEncoder.storageString(originalImageUrl, column: "original_image_url")
        container["ai_extraction_raw"] = aiExtractionRaw
        container["ai_confidence"] = aiConfidence
        container["ocr_confidence"] = ocrConfidence
        container["extraction_status"] = extractionStatus
        container["extraction_error"] = extractionError
        container["markers_extracted"] = markersExtracted
        container["diagnoses_extracted"] = diagnosesExtracted
        container["processed_data"] = processedData
        container["needs_review"] = needsReview
        container["user_reviewed"] = userReviewed
        container["user_reviewed_at"] = userReviewedAt
        container["manually_verified"] = manuallyVerified
        container["pinned_by_user"] = pinnedByUser
        container["scan_date"] = scanDate
        container["lab_name"] = labName
        container["document_language"] = documentLanguage
        container["source_file_sha256"] = sourceFileSha256
        container["storage_mode"] = storageMode
        container["store_original_in_cloud"] = storeOriginalInCloud
        container["scheduled_deletion_at"] = scheduledDeletionAt
        container["notes"] = notes
        container["deleted_at"] = deletedAt
    }

    func aroundSave(_ db: Database, save: () throws -> PersistenceSuccess) throws {
        guard imageUrl != nil || originalImageUrl != nil else {
            _ = try save()
            return
        }
        _ = try FieldEncryption.withPreparedPersistenceContext(save)
    }
}

extension HealthMeasurement: SnakeCaseGRDBRecord {
    static let databaseTableName = "health_measurements"

    init(row: Row) {
        func normalized(_ rawValue: String?) -> String? {
            guard let rawValue else { return nil }
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        id = GRDBRecordDecoder.requiredUUID(row, column: "id")
        userId = GRDBRecordDecoder.requiredUUID(row, column: "user_id")
        createdAt = GRDBRecordDecoder.required(row, column: "created_at", default: Date())
        updatedAt = GRDBRecordDecoder.required(row, column: "updated_at", default: Date())

        let decodedMedicalScanId = GRDBRecordDecoder.optionalUUID(row, column: "medical_scan_id")
        let decodedSourceScanId = GRDBRecordDecoder.optionalUUID(row, column: "source_scan_id")
        medicalScanId = decodedMedicalScanId ?? decodedSourceScanId
        sourceScanId = decodedSourceScanId ?? decodedMedicalScanId

        let decodedOriginalLabel = normalized(GRDBRecordDecoder.optional(row, column: "original_label"))
        originalLabel = decodedOriginalLabel

        let decodedBiomarkerName = normalized(GRDBRecordDecoder.optional(row, column: "biomarker_name"))
        let decodedMarkerId = HealthMeasurement.canonicalMarkerId(
            markerId: GRDBRecordDecoder.optional(row, column: "marker_id"),
            biomarkerName: decodedBiomarkerName,
            originalLabel: decodedOriginalLabel
        )
        markerId = decodedMarkerId
        biomarkerName = HealthMeasurement.resolvedBiomarkerName(
            biomarkerName: decodedBiomarkerName,
            originalLabel: decodedOriginalLabel,
            markerId: decodedMarkerId
        )

        value = GRDBRecordDecoder.requiredEncryptedDouble(row, column: "value")
        unit = normalized(GRDBRecordDecoder.optional(row, column: "unit")) ?? ""
        originalValue = GRDBRecordDecoder.encryptedDouble(row, column: "original_value")
        originalUnit = normalized(GRDBRecordDecoder.optional(row, column: "original_unit"))
        notes = normalized(GRDBRecordDecoder.optional(row, column: "notes"))

        referenceRangeLow = GRDBRecordDecoder.optional(row, column: "reference_range_low")
        referenceRangeHigh = GRDBRecordDecoder.optional(row, column: "reference_range_high")

        let decodedMeasuredAt: Date? = GRDBRecordDecoder.optional(row, column: "measured_at")
        let decodedMeasuredDate = normalized(GRDBRecordDecoder.optional(row, column: "measured_date"))
        measuredAt = decodedMeasuredAt ?? decodedMeasuredDate.flatMap(HealthMeasurement.dateOnlyDate(from:))
        measuredDate = decodedMeasuredDate ?? decodedMeasuredAt.map(HealthMeasurement.dateOnlyString(from:))

        sourceType = HealthMeasurement.normalizedSourceType(
            GRDBRecordDecoder.optional(row, column: "source_type")
        )

        confidence = GRDBRecordDecoder.optional(row, column: "confidence")
            ?? GRDBRecordDecoder.optional(row, column: "ai_confidence")

        let rawStatus: String? = GRDBRecordDecoder.optional(row, column: "status")
        status = HealthMeasurementStatus.canonicalRawValue(
            for: rawStatus,
            value: value,
            referenceRangeLow: referenceRangeLow,
            referenceRangeHigh: referenceRangeHigh
        )

        userCorrected = GRDBRecordDecoder.required(row, column: "user_corrected", default: false)
        manuallyVerified = GRDBRecordDecoder.required(row, column: "manually_verified", default: false)
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = MixedUUIDStorage.encode(id)
        container["user_id"] = MixedUUIDStorage.encode(userId)
        container["medical_scan_id"] = medicalScanId.map(MixedUUIDStorage.encode)
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
        container["biomarker_name"] = biomarkerName
        container["marker_id"] = markerId
        container["value"] = GRDBSensitiveEncoder.storageDouble(value, column: "value")
        container["unit"] = unit
        container["original_value"] = GRDBSensitiveEncoder.storageDouble(originalValue, column: "original_value")
        container["original_unit"] = originalUnit
        container["original_label"] = originalLabel
        container["status"] = status
        container["reference_range_low"] = referenceRangeLow
        container["reference_range_high"] = referenceRangeHigh
        container["measured_at"] = measuredAt
        container["measured_date"] = measuredDate
        container["source_scan_id"] = (sourceScanId ?? medicalScanId).map(MixedUUIDStorage.encode)
        container["source_type"] = sourceType
        container["confidence"] = confidence
        container["ai_confidence"] = confidence
        container["user_corrected"] = userCorrected
        container["manually_verified"] = manuallyVerified
        container["notes"] = notes
    }

    func aroundSave(_ db: Database, save: () throws -> PersistenceSuccess) throws {
        _ = try FieldEncryption.withPreparedPersistenceContext(save)
    }
}

// MARK: - AI

extension Insight: SnakeCaseGRDBRecord {
    static let databaseTableName = "insights"

    // Insight declares explicit snake_case CodingKeys in HealthModels.swift.
    // Using default keys avoids applying snake_case conversion twice.
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy {
        .useDefaultKeys
    }

    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy {
        .useDefaultKeys
    }
}

extension Recommendation: SnakeCaseGRDBRecord {
    static let databaseTableName = "recommendations"

    // Recommendation declares explicit snake_case CodingKeys in AdditionalModels.swift.
    // Using default keys avoids applying snake_case conversion twice.
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy {
        .useDefaultKeys
    }

    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy {
        .useDefaultKeys
    }
}

extension WeeklyStrategyReport: SnakeCaseGRDBRecord {
    static let databaseTableName = "weekly_strategy_reports"

    // WeeklyStrategyReport declares explicit snake_case CodingKeys.
    // Using default keys avoids applying snake_case conversion twice.
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy {
        .useDefaultKeys
    }

    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy {
        .useDefaultKeys
    }
}

extension HealthMarkerCatalogEntry: SnakeCaseGRDBRecord {
    static let databaseTableName = "health_marker_catalog"
}

extension HealthDiagnosis: SnakeCaseGRDBRecord {
    static let databaseTableName = "health_diagnoses"
}

extension VectorMemoryEntry: SnakeCaseGRDBRecord {
    static let databaseTableName = "vector_memory"
}

extension AnalyticsEvent: SnakeCaseGRDBRecord {
    static let databaseTableName = "analytics_events"
}

extension TrainingTemplate: SnakeCaseGRDBRecord {
    static let databaseTableName = "training_templates"
}

extension DeletionAuditLog: SnakeCaseGRDBRecord {
    static let databaseTableName = "deletion_audit_log"

    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy {
        .useDefaultKeys
    }

    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy {
        .useDefaultKeys
    }
}

extension DeletionFailure: SnakeCaseGRDBRecord {
    static let databaseTableName = "deletion_failures"

    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy {
        .useDefaultKeys
    }

    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy {
        .useDefaultKeys
    }
}

extension ConsentRecord: SnakeCaseGRDBRecord {
    static let databaseTableName = "consent_records"
}

extension AICacheEntry: SnakeCaseGRDBRecord {
    static let databaseTableName = "ai_cache"
}

extension Experiment: SnakeCaseGRDBRecord {
    static let databaseTableName = "experiments"
}

extension ExperimentMeasurement: SnakeCaseGRDBRecord {
    static let databaseTableName = "experiment_measurements"
}

// MARK: - Menstrual

extension MenstrualLog: SnakeCaseGRDBRecord {
    static let databaseTableName = "menstrual_logs"
    // MenstrualLog defines explicit snake_case CodingKeys.
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy {
        .useDefaultKeys
    }

    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy {
        .useDefaultKeys
    }
}

// MARK: - Onboarding & Privacy

extension OnboardingState: SnakeCaseGRDBRecord {
    static let databaseTableName = "onboarding_state"
    // OnboardingState defines explicit snake_case CodingKeys.
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy {
        .useDefaultKeys
    }

    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy {
        .useDefaultKeys
    }
}

extension UserBaseline: SnakeCaseGRDBRecord {
    static let databaseTableName = "user_baselines"
    // UserBaseline defines explicit snake_case CodingKeys.
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy {
        .useDefaultKeys
    }

    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy {
        .useDefaultKeys
    }
}

extension PrivacySettings: SnakeCaseGRDBRecord {
    static let databaseTableName = "privacy_settings"
    // PrivacySettings defines explicit snake_case CodingKeys.
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy {
        .useDefaultKeys
    }

    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy {
        .useDefaultKeys
    }
}
