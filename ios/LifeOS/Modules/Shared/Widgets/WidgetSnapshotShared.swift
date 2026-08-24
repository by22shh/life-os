import Foundation

enum LifeOSWidgetConstants {
    static let appGroupSuiteName = "group.com.lifeos.widgets"
    static let snapshotKey = "widget_snapshot_v1"
    static let privacyKey = "widget_privacy_v1"

    static let recoveryKind = "LifeOSRecoveryWidget"
    static let nutritionKind = "LifeOSNutritionWidget"
    static let supplementsKind = "LifeOSSupplementsWidget"
    static let workoutKind = "LifeOSWorkoutWidget"

    static let allKinds = [
        recoveryKind,
        nutritionKind,
        supplementsKind,
        workoutKind,
    ]
}

struct WidgetPrivacySettings: Codable, Equatable, Sendable {
    var showRecoveryScore: Bool
    var showNutrition: Bool
    var showSupplements: Bool
    var showTraining: Bool
    var showMenstrualData: Bool
    var showHealthDiagnoses: Bool

    init(
        showRecoveryScore: Bool = true,
        showNutrition: Bool = true,
        showSupplements: Bool = true,
        showTraining: Bool = true,
        showMenstrualData: Bool = false,
        showHealthDiagnoses: Bool = false
    ) {
        self.showRecoveryScore = showRecoveryScore
        self.showNutrition = showNutrition
        self.showSupplements = showSupplements
        self.showTraining = showTraining
        self.showMenstrualData = showMenstrualData
        self.showHealthDiagnoses = showHealthDiagnoses
    }
}

struct WidgetSnapshot: Codable, Equatable, Sendable {
    struct RecoveryPayload: Codable, Equatable, Sendable {
        var recoveryScore: Int?
        var recoveryZone: String?
        var recoveryZoneLabel: String?
        var recoveryDelta: Int?
    }

    struct NutritionPayload: Codable, Equatable, Sendable {
        var calories: Int
        var targetCalories: Int?
        var proteinG: Int
        var targetProteinG: Int?
        var carbsG: Int
        var targetCarbsG: Int?
        var fatG: Int
        var targetFatG: Int?
        var fiberG: Int
        var targetFiberG: Int?
        var waterMl: Int
        var targetWaterMl: Int?
    }

    struct SupplementEntry: Codable, Equatable, Sendable {
        var name: String
        var timeLabel: String
        var dayLabel: String?
        var scheduledDate: String
    }

    struct SupplementsPayload: Codable, Equatable, Sendable {
        var supplementsTotal: Int
        var supplementsTaken: Int
        var nextSupplement: SupplementEntry?
    }

    struct WorkoutEntry: Codable, Equatable, Sendable {
        var title: String
        var subtitle: String?
        var dayLabel: String
        var plannedDate: String
        var durationMinutes: Int?
        var deepLink: String?
    }

    struct TrainingPayload: Codable, Equatable, Sendable {
        var nextWorkout: WorkoutEntry?
    }

    var generatedAt: Date
    var privacy: WidgetPrivacySettings
    var recovery: RecoveryPayload?
    var nutrition: NutritionPayload?
    var supplements: SupplementsPayload?
    var training: TrainingPayload?
}

extension WidgetSnapshot {
    static var empty: WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: Date(),
            privacy: WidgetPrivacySettings(),
            recovery: nil,
            nutrition: WidgetSnapshot.NutritionPayload(
                calories: 0,
                targetCalories: nil,
                proteinG: 0,
                targetProteinG: nil,
                carbsG: 0,
                targetCarbsG: nil,
                fatG: 0,
                targetFatG: nil,
                fiberG: 0,
                targetFiberG: nil,
                waterMl: 0,
                targetWaterMl: nil
            ),
            supplements: WidgetSnapshot.SupplementsPayload(
                supplementsTotal: 0,
                supplementsTaken: 0,
                nextSupplement: nil
            ),
            training: WidgetSnapshot.TrainingPayload(nextWorkout: nil)
        )
    }

    static var placeholder: WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: Date(),
            privacy: WidgetPrivacySettings(),
            recovery: WidgetSnapshot.RecoveryPayload(
                recoveryScore: 82,
                recoveryZone: "ready",
                recoveryZoneLabel: String(localized: "recovery_zone_ready"),
                recoveryDelta: 6
            ),
            nutrition: WidgetSnapshot.NutritionPayload(
                calories: 1540,
                targetCalories: 2200,
                proteinG: 112,
                targetProteinG: 150,
                carbsG: 138,
                targetCarbsG: 220,
                fatG: 54,
                targetFatG: 75,
                fiberG: 19,
                targetFiberG: 30,
                waterMl: 1450,
                targetWaterMl: 2450
            ),
            supplements: WidgetSnapshot.SupplementsPayload(
                supplementsTotal: 4,
                supplementsTaken: 2,
                nextSupplement: WidgetSnapshot.SupplementEntry(
                    name: String(localized: "widget.placeholder.supplement_name"),
                    timeLabel: "21:30",
                    dayLabel: String(localized: "widget.relative_day_today"),
                    scheduledDate: "2026-03-15"
                )
            ),
            training: WidgetSnapshot.TrainingPayload(
                nextWorkout: WidgetSnapshot.WorkoutEntry(
                    title: String(localized: "widget.placeholder.workout_title"),
                    subtitle: String(localized: "widget.placeholder.workout_subtitle"),
                    dayLabel: String(localized: "widget.relative_day_tomorrow"),
                    plannedDate: "2026-03-16",
                    durationMinutes: 55,
                    deepLink: "lifeos://workout?date=2026-03-16"
                )
            )
        )
    }
}

enum WidgetSnapshotCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

enum WidgetSnapshotStorage {
    static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: LifeOSWidgetConstants.appGroupSuiteName)
    }

    static func loadSnapshot(defaults: UserDefaults? = sharedDefaults()) -> WidgetSnapshot? {
        guard let defaults,
              let data = defaults.data(forKey: LifeOSWidgetConstants.snapshotKey) else {
            return nil
        }
        return try? WidgetSnapshotCoding.decoder.decode(WidgetSnapshot.self, from: data)
    }

    static func storeSnapshot(_ snapshot: WidgetSnapshot?, defaults: UserDefaults? = sharedDefaults()) {
        guard let defaults else { return }
        guard let snapshot else {
            defaults.removeObject(forKey: LifeOSWidgetConstants.snapshotKey)
            return
        }
        guard let data = try? WidgetSnapshotCoding.encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: LifeOSWidgetConstants.snapshotKey)
    }

    static func loadPrivacy(defaults: UserDefaults? = sharedDefaults()) -> WidgetPrivacySettings {
        guard let defaults,
              let data = defaults.data(forKey: LifeOSWidgetConstants.privacyKey),
              let settings = try? WidgetSnapshotCoding.decoder.decode(WidgetPrivacySettings.self, from: data) else {
            return WidgetPrivacySettings()
        }
        return settings
    }

    static func storePrivacy(_ settings: WidgetPrivacySettings, defaults: UserDefaults? = sharedDefaults()) {
        guard let defaults,
              let data = try? WidgetSnapshotCoding.encoder.encode(settings) else {
            return
        }
        defaults.set(data, forKey: LifeOSWidgetConstants.privacyKey)
    }
}
