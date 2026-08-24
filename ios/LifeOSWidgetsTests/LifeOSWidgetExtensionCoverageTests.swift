import SwiftUI
import WidgetKit
import XCTest
@testable import LifeOSWidgets

final class LifeOSWidgetExtensionCoverageTests: XCTestCase {
    private let snapshotDefaults = UserDefaults(suiteName: LifeOSWidgetConstants.appGroupSuiteName)

    override func setUp() {
        super.setUp()
        clearWidgetDefaults()
    }

    override func tearDown() {
        clearWidgetDefaults()
        super.tearDown()
    }

    @MainActor
    func testTimelineFactoryLoadsStoredSnapshotAndBuildsRefreshPolicies() {
        WidgetSnapshotStorage.storeSnapshot(.placeholder, defaults: snapshotDefaults)

        let placeholder = LifeOSWidgetsTestHooks.placeholderEntry()
        XCTAssertEqual(
            placeholder.snapshot.recovery?.recoveryZone,
            WidgetSnapshot.placeholder.recovery?.recoveryZone
        )

        let current = LifeOSWidgetsTestHooks.currentEntry()
        XCTAssertEqual(
            current.snapshot.nutrition?.targetCalories,
            WidgetSnapshot.placeholder.nutrition?.targetCalories
        )

        let timeline = LifeOSWidgetsTestHooks.timeline(refreshAfterMinutes: 15)
        XCTAssertEqual(timeline.entries.count, 1)
        XCTAssertEqual(
            timeline.entries.first?.snapshot.supplements?.nextSupplement?.name,
            WidgetSnapshot.placeholder.supplements?.nextSupplement?.name
        )
    }

    @MainActor
    func testWidgetHelpersCoverFormattingBranches() {
        XCTAssertEqual(LifeOSWidgetsTestHooks.scoreText(nil), "--")
        XCTAssertEqual(LifeOSWidgetsTestHooks.scoreText(84), "84")
        XCTAssertEqual(LifeOSWidgetsTestHooks.zoneBadge(nil), "?")
        XCTAssertEqual(LifeOSWidgetsTestHooks.zoneBadge("ready"), "R")
        XCTAssertEqual(LifeOSWidgetsTestHooks.progress(from: nil, target: 100), 0)
        XCTAssertEqual(LifeOSWidgetsTestHooks.progress(from: 75, target: 150), 0.5, accuracy: 0.0001)

        let nutritionWithTarget = WidgetSnapshot.NutritionPayload(
            calories: 1600,
            targetCalories: 2200,
            proteinG: 120,
            targetProteinG: 160,
            carbsG: 140,
            targetCarbsG: 220,
            fatG: 55,
            targetFatG: 70,
            fiberG: 25,
            targetFiberG: 30,
            waterMl: 1800,
            targetWaterMl: 2500
        )
        let nutritionWithoutTarget = WidgetSnapshot.NutritionPayload(
            calories: 900,
            targetCalories: nil,
            proteinG: 70,
            targetProteinG: nil,
            carbsG: 80,
            targetCarbsG: nil,
            fatG: 25,
            targetFatG: nil,
            fiberG: 12,
            targetFiberG: nil,
            waterMl: 900,
            targetWaterMl: nil
        )

        let supplementWithDay = WidgetSnapshot.SupplementEntry(
            name: "Magnesium",
            timeLabel: "21:30",
            dayLabel: "Tomorrow",
            scheduledDate: "2026-03-20"
        )
        let supplementWithoutDay = WidgetSnapshot.SupplementEntry(
            name: "Omega-3",
            timeLabel: "08:00",
            dayLabel: nil,
            scheduledDate: "2026-03-19"
        )

        let workoutWithDetails = WidgetSnapshot.WorkoutEntry(
            title: "Tempo Run",
            subtitle: "Threshold focus",
            dayLabel: "Tomorrow",
            plannedDate: "2026-03-20",
            durationMinutes: 50,
            deepLink: "lifeos://workout?date=2026-03-20"
        )
        let workoutWithoutDetails = WidgetSnapshot.WorkoutEntry(
            title: "Mobility",
            subtitle: nil,
            dayLabel: "Today",
            plannedDate: "2026-03-19",
            durationMinutes: nil,
            deepLink: nil
        )

        XCTAssertNotEqual(LifeOSWidgetsTestHooks.deltaText(6), LifeOSWidgetsTestHooks.deltaText(-4))
        XCTAssertNotEqual(LifeOSWidgetsTestHooks.deltaText(-4), LifeOSWidgetsTestHooks.deltaText(0))
        XCTAssertFalse(LifeOSWidgetsTestHooks.calorieSubtitle(nutritionWithTarget).isEmpty)
        XCTAssertFalse(LifeOSWidgetsTestHooks.calorieSubtitle(nutritionWithoutTarget).isEmpty)
        XCTAssertFalse(LifeOSWidgetsTestHooks.nextDoseSubtitle(supplementWithDay).isEmpty)
        XCTAssertEqual(LifeOSWidgetsTestHooks.nextDoseSubtitle(supplementWithoutDay), "08:00")
        XCTAssertFalse(LifeOSWidgetsTestHooks.workoutSubtitle(workoutWithDetails).isEmpty)
        XCTAssertEqual(LifeOSWidgetsTestHooks.zoneLabelText("  "), String(localized: "widget.no_data"))
        XCTAssertFalse(LifeOSWidgetsTestHooks.gramsText(42).isEmpty)
        XCTAssertFalse(LifeOSWidgetsTestHooks.millilitersText(800).isEmpty)
        XCTAssertFalse(String(describing: LifeOSWidgetsTestHooks.recoveryTint(for: "optimal")).isEmpty)
        XCTAssertFalse(String(describing: LifeOSWidgetsTestHooks.deltaColor(-1)).isEmpty)
        XCTAssertFalse(LifeOSWidgetsTestHooks.workoutSubtitle(workoutWithoutDetails).contains("Threshold"))
    }

    @MainActor
    func testWidgetRootsRenderContentHiddenAndEmptyStates() {
        let contentEntry = WidgetSnapshotEntry(date: Date(), snapshot: .placeholder)
        let hiddenEntry = WidgetSnapshotEntry(
            date: Date(),
            snapshot: WidgetSnapshot(
                generatedAt: Date(),
                privacy: WidgetPrivacySettings(
                    showRecoveryScore: false,
                    showNutrition: false,
                    showSupplements: false,
                    showTraining: false,
                    showMenstrualData: false,
                    showHealthDiagnoses: false
                ),
                recovery: WidgetSnapshot.placeholder.recovery,
                nutrition: WidgetSnapshot.placeholder.nutrition,
                supplements: WidgetSnapshot.placeholder.supplements,
                training: WidgetSnapshot.placeholder.training
            )
        )
        let emptyEntry = WidgetSnapshotEntry(
            date: Date(),
            snapshot: WidgetSnapshot(
                generatedAt: Date(),
                privacy: WidgetPrivacySettings(),
                recovery: nil,
                nutrition: nil,
                supplements: nil,
                training: WidgetSnapshot.TrainingPayload(nextWorkout: nil)
            )
        )

        render(LifeOSWidgetsTestHooks.recoveryRoot(entry: contentEntry, family: .systemSmall))
        render(LifeOSWidgetsTestHooks.recoveryRoot(entry: contentEntry, family: .systemMedium), size: CGSize(width: 329, height: 155))
        render(LifeOSWidgetsTestHooks.recoveryRoot(entry: contentEntry, family: .accessoryCircular), size: CGSize(width: 96, height: 96))
        render(LifeOSWidgetsTestHooks.recoveryRoot(entry: contentEntry, family: .accessoryRectangular), size: CGSize(width: 180, height: 80))
        render(LifeOSWidgetsTestHooks.recoveryRoot(entry: contentEntry, family: .accessoryInline), size: CGSize(width: 180, height: 40))
        render(LifeOSWidgetsTestHooks.recoveryRoot(entry: hiddenEntry, family: .systemSmall))
        render(LifeOSWidgetsTestHooks.recoveryRoot(entry: emptyEntry, family: .systemSmall))

        render(LifeOSWidgetsTestHooks.nutritionRoot(entry: contentEntry, family: .systemSmall))
        render(LifeOSWidgetsTestHooks.nutritionRoot(entry: contentEntry, family: .systemMedium), size: CGSize(width: 329, height: 155))
        render(LifeOSWidgetsTestHooks.nutritionRoot(entry: hiddenEntry, family: .systemSmall))
        render(LifeOSWidgetsTestHooks.nutritionRoot(entry: emptyEntry, family: .systemSmall))

        render(LifeOSWidgetsTestHooks.supplementsRoot(entry: contentEntry))
        render(LifeOSWidgetsTestHooks.supplementsRoot(entry: hiddenEntry))
        render(LifeOSWidgetsTestHooks.supplementsRoot(entry: emptyEntry))

        render(LifeOSWidgetsTestHooks.workoutRoot(entry: contentEntry, family: .systemSmall))
        render(LifeOSWidgetsTestHooks.workoutRoot(entry: contentEntry, family: .accessoryRectangular), size: CGSize(width: 180, height: 80))
        render(LifeOSWidgetsTestHooks.workoutRoot(entry: hiddenEntry, family: .systemSmall))
        render(LifeOSWidgetsTestHooks.workoutRoot(entry: emptyEntry, family: .systemSmall))

        render(LifeOSWidgetsTestHooks.hidden(title: "Recovery"))
        render(LifeOSWidgetsTestHooks.empty(title: "Recovery", message: "No data"))
        _ = RecoveryWidget().body
        _ = NutritionWidget().body
        _ = SupplementsWidget().body
        _ = WorkoutWidget().body
        _ = LifeOSWidgetsBundle().body
    }

    func testWidgetSnapshotStorageCoversEmptySnapshotAndPrivacyRoundTrip() {
        let defaults = UserDefaults(suiteName: "LifeOSWidgetExtensionCoverageTests.storage")!
        defaults.removeObject(forKey: LifeOSWidgetConstants.snapshotKey)
        defaults.removeObject(forKey: LifeOSWidgetConstants.privacyKey)

        let empty = WidgetSnapshot.empty
        XCTAssertNil(empty.recovery)
        XCTAssertEqual(empty.nutrition?.calories, 0)
        XCTAssertEqual(empty.supplements?.supplementsTotal, 0)
        XCTAssertNil(empty.training?.nextWorkout)

        XCTAssertNil(WidgetSnapshotStorage.loadSnapshot(defaults: defaults))
        WidgetSnapshotStorage.storeSnapshot(.placeholder, defaults: nil)
        WidgetSnapshotStorage.storeSnapshot(.placeholder, defaults: defaults)
        XCTAssertEqual(
            WidgetSnapshotStorage.loadSnapshot(defaults: defaults)?.recovery?.recoveryScore,
            WidgetSnapshot.placeholder.recovery?.recoveryScore
        )

        WidgetSnapshotStorage.storeSnapshot(nil, defaults: defaults)
        XCTAssertNil(WidgetSnapshotStorage.loadSnapshot(defaults: defaults))

        XCTAssertEqual(WidgetSnapshotStorage.loadPrivacy(defaults: defaults), WidgetPrivacySettings())
        let settings = WidgetPrivacySettings(
            showRecoveryScore: false,
            showNutrition: true,
            showSupplements: false,
            showTraining: true,
            showMenstrualData: true,
            showHealthDiagnoses: true
        )
        WidgetSnapshotStorage.storePrivacy(settings, defaults: nil)
        WidgetSnapshotStorage.storePrivacy(settings, defaults: defaults)
        XCTAssertEqual(WidgetSnapshotStorage.loadPrivacy(defaults: defaults), settings)
    }

    private func clearWidgetDefaults() {
        snapshotDefaults?.removeObject(forKey: LifeOSWidgetConstants.snapshotKey)
        snapshotDefaults?.removeObject(forKey: LifeOSWidgetConstants.privacyKey)
    }

    @MainActor
    private func render(
        _ view: some View,
        size: CGSize = CGSize(width: 169, height: 169),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let renderer = ImageRenderer(
            content: view
                .frame(width: size.width, height: size.height)
        )
        renderer.scale = 1
        XCTAssertNotNil(renderer.cgImage, file: file, line: line)
    }
}
