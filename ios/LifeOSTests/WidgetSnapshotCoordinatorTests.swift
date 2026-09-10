import Foundation
import GRDB
import OSLog
import XCTest
@testable import LifeOS

@MainActor
final class WidgetSnapshotCoordinatorTests: XCTestCase {
    func testEatingDisorderSafetyOverridesNutritionWidgetOptIn() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = makeUser(authId: UUID(), timezone: "UTC")
        try await manager.dbQueue.write { db in
            try user.insert(db)
            var flags = UserHealthFlags(userId: user.id)
            flags.hasEatingDisorderHistory = true
            try flags.insert(db)
            XCTAssertTrue(try NutritionSafetyPolicy.hidesCalories(in: db, userId: user.id))
            XCTAssertTrue(try NutritionSafetyPolicy.suppressesTargets(in: db, userId: user.id))
        }
        let snapshot = try await WidgetSnapshotCoordinator._testBuildSnapshot(dbQueue: manager.dbQueue, authId: user.authId.uuidString, now: Date(), privacy: WidgetPrivacySettings(showNutrition: true))
        XCTAssertNil(snapshot?.nutrition)
        XCTAssertEqual(snapshot?.privacy.showNutrition, false)
    }

    func testPregnancyDisablesGenericNutritionTargetsWithoutHidingFoodHistory() async throws {
        let manager = try DatabaseManager.inMemory()
        let user = makeUser(authId: UUID(), timezone: "UTC")
        try await manager.dbQueue.write { db in
            try user.insert(db)
            var flags = UserHealthFlags(userId: user.id)
            flags.isPregnant = true
            try flags.insert(db)
            XCTAssertFalse(try NutritionSafetyPolicy.hidesCalories(in: db, userId: user.id))
            XCTAssertTrue(try NutritionSafetyPolicy.suppressesTargets(in: db, userId: user.id))
        }
    }
    private enum SnapshotBuildFailure: Error {
        case simulated
    }

    override func tearDown() {
        AuthManager.setActiveAuthIdForTests(nil)
        super.tearDown()
    }

    func testWidgetPrivacyStorageRoundTripsCustomSettings() {
        let suiteName = "group.com.lifeos.tests.widgets.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.removePersistentDomain(forName: suiteName)

        let settings = WidgetPrivacySettings(
            showRecoveryScore: false,
            showNutrition: true,
            showSupplements: false,
            showTraining: true,
            showMenstrualData: false,
            showHealthDiagnoses: false
        )

        WidgetSnapshotStorage.storePrivacy(settings, defaults: defaults)
        XCTAssertEqual(WidgetSnapshotStorage.loadPrivacy(defaults: defaults), settings)

        defaults?.removePersistentDomain(forName: suiteName)
    }

    func testWidgetSnapshotFindsNextSupplementAcrossMidnight() async throws {
        let manager = try DatabaseManager.inMemory()
        let dbQueue = manager.dbQueue
        let authId = UUID()
        let user = makeUser(authId: authId, timezone: "Asia/Novosibirsk")
        let today = "2026-03-15"
        let tomorrow = "2026-03-16"

        try await dbQueue.write { db in
            try user.insert(db)

            var supplement = UserSupplement(userId: user.id, frequency: .daily, doseUnit: "mg")
            supplement.customName = "Magnesium"
            supplement.scheduledTimes = ["00:30"]
            supplement.startedAt = today
            try supplement.insert(db)
        }

        let now = makeDate(
            day: today,
            hour: 23,
            minute: 35,
            timeZone: TimeZone(identifier: "Asia/Novosibirsk")!
        )

        let snapshot = try await WidgetSnapshotCoordinator._testBuildSnapshot(
            dbQueue: dbQueue,
            authId: authId.uuidString,
            now: now
        )
        let tomorrowLabel = String(localized: "widget.relative_day_tomorrow")

        XCTAssertEqual(snapshot?.supplements?.supplementsTotal, 1)
        XCTAssertEqual(snapshot?.supplements?.supplementsTaken, 0)
        XCTAssertEqual(snapshot?.supplements?.nextSupplement?.name, "Magnesium")
        XCTAssertEqual(snapshot?.supplements?.nextSupplement?.timeLabel, "00:30")
        XCTAssertEqual(snapshot?.supplements?.nextSupplement?.dayLabel, tomorrowLabel)
        XCTAssertEqual(snapshot?.supplements?.nextSupplement?.scheduledDate, tomorrow)
    }

    func testWidgetSnapshotRespectsPrivacyMasking() async throws {
        let manager = try DatabaseManager.inMemory()
        let dbQueue = manager.dbQueue
        let authId = UUID()
        let user = makeUser(authId: authId, timezone: "UTC")

        try await dbQueue.write { db in
            try user.insert(db)

            let today = "2026-03-15"
            var state = PhysiologicalState(userId: user.id, date: today, recoveryScore: 81)
            state.recoveryZone = .ready
            try state.insert(db)
        }

        let snapshot = try await WidgetSnapshotCoordinator._testBuildSnapshot(
            dbQueue: dbQueue,
            authId: authId.uuidString,
            now: makeDate(day: "2026-03-15", hour: 9, minute: 0, timeZone: .current),
            privacy: WidgetPrivacySettings(
                showRecoveryScore: false,
                showNutrition: false,
                showSupplements: false,
                showTraining: false,
                showMenstrualData: false,
                showHealthDiagnoses: false
            )
        )

        XCTAssertNil(snapshot?.recovery)
        XCTAssertNil(snapshot?.nutrition)
        XCTAssertNil(snapshot?.supplements)
        XCTAssertNil(snapshot?.training)
    }

    func testWidgetSnapshotUsesEarliestUpcomingTrainingSession() async throws {
        let manager = try DatabaseManager.inMemory()
        let dbQueue = manager.dbQueue
        let authId = UUID()
        let user = makeUser(authId: authId, timezone: "UTC")
        let plan = TrainingPlan(
            userId: user.id,
            name: "Strength Block",
            goal: .strength,
            planJson: Data("{}".utf8)
        )

        try await dbQueue.write { db in
            try user.insert(db)
            try plan.insert(db)

            var laterSession = TrainingPlanSession(
                trainingPlanId: plan.id,
                userId: user.id,
                plannedDate: "2026-03-18",
                sessionType: .cardio
            )
            laterSession.title = "Tempo Run"
            laterSession.plannedDurationMinutes = 40
            try laterSession.insert(db)

            var earlierSession = TrainingPlanSession(
                trainingPlanId: plan.id,
                userId: user.id,
                plannedDate: "2026-03-16",
                sessionType: .strength
            )
            earlierSession.title = "Lower Body Strength"
            earlierSession.plannedDurationMinutes = 55
            earlierSession.status = .rescheduled
            try earlierSession.insert(db)
        }

        let snapshot = try await WidgetSnapshotCoordinator._testBuildSnapshot(
            dbQueue: dbQueue,
            authId: authId.uuidString,
            now: makeDate(day: "2026-03-15", hour: 8, minute: 0, timeZone: .current)
        )
        let tomorrowLabel = String(localized: "widget.relative_day_tomorrow")

        XCTAssertEqual(snapshot?.training?.nextWorkout?.title, "Lower Body Strength")
        XCTAssertEqual(snapshot?.training?.nextWorkout?.plannedDate, "2026-03-16")
        XCTAssertEqual(snapshot?.training?.nextWorkout?.dayLabel, tomorrowLabel)
        XCTAssertEqual(snapshot?.training?.nextWorkout?.durationMinutes, 55)
    }

    func testRefreshSnapshotPreservesStoredSnapshotWhenBuildFails() async throws {
        let manager = try DatabaseManager.inMemory()
        let suiteName = "group.com.lifeos.tests.widgets.\(UUID().uuidString)"
        let storageDefaults = UserDefaults(suiteName: suiteName)
        let actorDefaults = UserDefaults(suiteName: suiteName)
        storageDefaults?.removePersistentDomain(forName: suiteName)

        let existingSnapshot = makeStoredSnapshot()
        let now = makeDate(day: "2026-03-15", hour: 9, minute: 0, timeZone: .current)
        WidgetSnapshotStorage.storeSnapshot(existingSnapshot, defaults: storageDefaults)
        let user = makeUser(authId: UUID(), timezone: "UTC")
        try await manager.dbQueue.write { db in try user.insert(db) }
        AuthManager.setActiveAuthIdForTests(user.authId)

        let reloadCount = OSAllocatedUnfairLock(initialState: 0)
        let coordinator = WidgetSnapshotCoordinator(
            dbQueue: manager.dbQueue,
            defaults: actorDefaults,
            nowProvider: { now },
            snapshotBuilder: { _, _, _, _ in
                throw SnapshotBuildFailure.simulated
            },
            reloadTimelinesHandler: {
                reloadCount.withLock { $0 += 1 }
            }
        )

        await coordinator.refreshSnapshot()

        let storedSnapshot = WidgetSnapshotStorage.loadSnapshot(defaults: UserDefaults(suiteName: suiteName))
        XCTAssertEqual(storedSnapshot, existingSnapshot)
        XCTAssertEqual(reloadCount.withLock { $0 }, 1)

        storageDefaults?.removePersistentDomain(forName: suiteName)
    }

    func testRefreshSnapshotClearsStoredSnapshotWhenBuildReturnsNil() async throws {
        let manager = try DatabaseManager.inMemory()
        let suiteName = "group.com.lifeos.tests.widgets.\(UUID().uuidString)"
        let storageDefaults = UserDefaults(suiteName: suiteName)
        let actorDefaults = UserDefaults(suiteName: suiteName)
        storageDefaults?.removePersistentDomain(forName: suiteName)

        let now = makeDate(day: "2026-03-15", hour: 9, minute: 0, timeZone: .current)
        WidgetSnapshotStorage.storeSnapshot(makeStoredSnapshot(), defaults: storageDefaults)
        AuthManager.setActiveAuthIdForTests(UUID())

        let reloadCount = OSAllocatedUnfairLock(initialState: 0)
        let coordinator = WidgetSnapshotCoordinator(
            dbQueue: manager.dbQueue,
            defaults: actorDefaults,
            nowProvider: { now },
            snapshotBuilder: { _, _, _, _ in
                nil
            },
            reloadTimelinesHandler: {
                reloadCount.withLock { $0 += 1 }
            }
        )

        await coordinator.refreshSnapshot()

        let storedSnapshot = WidgetSnapshotStorage.loadSnapshot(defaults: UserDefaults(suiteName: suiteName))
        XCTAssertNil(storedSnapshot)
        XCTAssertEqual(reloadCount.withLock { $0 }, 1)

        storageDefaults?.removePersistentDomain(forName: suiteName)
    }

    private func makeUser(authId: UUID, timezone: String) -> User {
        var user = User(authId: authId, timezone: timezone)
        user.notificationEnabled = true
        user.onboardingCompleted = true
        return user
    }

    private func makeStoredSnapshot() -> WidgetSnapshot {
        var snapshot = WidgetSnapshot.placeholder
        snapshot.generatedAt = makeDate(day: "2026-03-15", hour: 9, minute: 0, timeZone: .current)
        return snapshot
    }

    private func makeDate(day: String, hour: Int, minute: Int, timeZone: TimeZone) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: "\(day) \(String(format: "%02d:%02d", hour, minute))") ?? Date()
    }
}
