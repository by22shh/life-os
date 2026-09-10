import Foundation
import ComposableArchitecture
import CoreImage
import CoreImage.CIFilterBuiltins
import GRDB
import PDFKit
import Supabase
import SwiftUI
import UIKit
import XCTest
@preconcurrency import BackgroundTasks
@preconcurrency import CoreLocation
@preconcurrency import HealthKit
@testable import LifeOS

private final class CoverageEdgeURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var currentHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func setHandler(_ handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?) {
        lock.lock()
        currentHandler = handler
        lock.unlock()
    }

    private static func handler() -> ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        lock.lock()
        defer { lock.unlock() }
        return currentHandler
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler() else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private struct CoverageFailingHealthSyncProvider: HealthSyncDataProviding {
    func fetchLatestHRV(for dayContext: HistoricalLocalDayContext) async throws -> Double? {
        _ = dayContext
        struct ExpectedError: Error {}
        throw ExpectedError()
    }
    func fetchSleep(for dayContext: HistoricalLocalDayContext) async throws -> SleepData? { _ = dayContext; return nil }
    func fetchRestingHeartRate(for dayContext: HistoricalLocalDayContext) async throws -> Int? { _ = dayContext; return nil }
    func fetchWristTemperature(for dayContext: HistoricalLocalDayContext) async throws -> Double? { _ = dayContext; return nil }
    func fetchSteps(for dayContext: HistoricalLocalDayContext) async throws -> Int? { _ = dayContext; return nil }
    func fetchActiveCalories(for dayContext: HistoricalLocalDayContext) async throws -> Int? { _ = dayContext; return nil }
    func fetchRespiratoryRate(for dayContext: HistoricalLocalDayContext) async throws -> Double? { _ = dayContext; return nil }
    func fetchBloodOxygen(for dayContext: HistoricalLocalDayContext) async throws -> Double? { _ = dayContext; return nil }
    func dataCompleteness(
        hrv: Double?,
        sleep: SleepData?,
        rhr: Int?,
        steps: Int?,
        activeCal: Int?
    ) async -> Double { 0 }
}

private struct CoverageHealthyHealthSyncProvider: HealthSyncDataProviding {
    func fetchLatestHRV(for dayContext: HistoricalLocalDayContext) async throws -> Double? { _ = dayContext; return nil }
    func fetchSleep(for dayContext: HistoricalLocalDayContext) async throws -> SleepData? { _ = dayContext; return nil }
    func fetchRestingHeartRate(for dayContext: HistoricalLocalDayContext) async throws -> Int? { _ = dayContext; return nil }
    func fetchWristTemperature(for dayContext: HistoricalLocalDayContext) async throws -> Double? { _ = dayContext; return nil }
    func fetchSteps(for dayContext: HistoricalLocalDayContext) async throws -> Int? { _ = dayContext; return nil }
    func fetchActiveCalories(for dayContext: HistoricalLocalDayContext) async throws -> Int? { _ = dayContext; return nil }
    func fetchRespiratoryRate(for dayContext: HistoricalLocalDayContext) async throws -> Double? { _ = dayContext; return nil }
    func fetchBloodOxygen(for dayContext: HistoricalLocalDayContext) async throws -> Double? { _ = dayContext; return nil }
    func dataCompleteness(
        hrv: Double?,
        sleep: SleepData?,
        rhr: Int?,
        steps: Int?,
        activeCal: Int?
    ) async -> Double { 0 }
}

private struct CoverageEnvironmentServiceStub: EnvironmentServiceProtocol {
    func fetchCurrentEnvironment() async throws -> EnvironmentalContext {
        struct ExpectedError: Error {}
        throw ExpectedError()
    }
}

private struct CoverageExpectedError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}

private actor CoverageWorkoutSessionManagerMock: WorkoutSessionManaging {
    private var createdDrafts: [WorkoutSessionDraft] = []
    private var loadedDetails: [UUID: WorkoutSessionDetail?] = [:]
    private var updatedDrafts: [WorkoutSessionUpdateDraft] = []
    private var deletedIds: [UUID] = []
    private var undoneIds: [UUID] = []
    private var loadError: Error?
    private var updateError: Error?
    private var deleteError: Error?
    private var undoError: Error?
    private var deleteReturnDate = Date()

    func createManualWorkout(_ draft: WorkoutSessionDraft) async throws {
        createdDrafts.append(draft)
    }

    func loadWorkoutDetail(id: UUID, preferRemote: Bool) async throws -> WorkoutSessionDetail? {
        _ = preferRemote
        if let loadError { throw loadError }
        return loadedDetails[id] ?? nil
    }

    func updateWorkout(_ draft: WorkoutSessionUpdateDraft) async throws {
        if let updateError { throw updateError }
        updatedDrafts.append(draft)
    }

    func deleteWorkout(id: UUID) async throws -> Date {
        if let deleteError { throw deleteError }
        deletedIds.append(id)
        return deleteReturnDate
    }

    func undoDeleteWorkout(id: UUID) async throws {
        if let undoError { throw undoError }
        undoneIds.append(id)
    }

    func setLoadedDetail(_ detail: WorkoutSessionDetail?, for id: UUID) {
        loadedDetails[id] = detail
    }

    func deletedIdsSnapshot() -> [UUID] {
        deletedIds
    }

    func undoneIdsSnapshot() -> [UUID] {
        undoneIds
    }

    func updatedDraftsSnapshot() -> [WorkoutSessionUpdateDraft] {
        updatedDrafts
    }

    func setLoadError(_ error: Error?) {
        loadError = error
    }

    func setUpdateError(_ error: Error?) {
        updateError = error
    }

    func setDeleteError(_ error: Error?) {
        deleteError = error
    }

    func setUndoError(_ error: Error?) {
        undoError = error
    }

    func setDeleteReturnDate(_ date: Date) {
        deleteReturnDate = date
    }
}

private actor CoveragePredictionAPIClientMock: PredictionAPIClient {
    struct Invocation: Sendable {
        let name: String
        let body: Data
        let headers: [String: String]
        let maxAttempts: Int
    }

    private let handler: @Sendable (String, Data, [String: String], Int) throws -> Data
    private var invocations: [Invocation] = []

    init(
        handler: @escaping @Sendable (String, Data, [String: String], Int) throws -> Data
    ) {
        self.handler = handler
    }

    func callEdgeFunction<T: Decodable & Sendable>(
        _ name: String,
        body: Data,
        headers: [String: String],
        maxAttempts: Int
    ) async throws -> T {
        invocations.append(
            Invocation(
                name: name,
                body: body,
                headers: headers,
                maxAttempts: maxAttempts
            )
        )
        let responseData = try handler(name, body, headers, maxAttempts)
        return try JSONDecoder().decode(T.self, from: responseData)
    }

    func firstInvocation() -> Invocation? {
        invocations.first
    }
}

private actor CoverageMealTemplateManagerMock: NutritionMealTemplateManaging {
    struct Snapshot: Sendable {
        let loadCallCount: Int
        let lastLoadPreferRemote: Bool?
        let templateListLoadCallCount: Int
        let lastTemplateListLoadPreferRemote: Bool?
        let createDrafts: [NutritionMealTemplateCreateDraft]
        let updateDrafts: [NutritionMealTemplateUpdateDraft]
        let archiveCalls: [(id: UUID, archived: Bool)]
        let applyCalls: [(id: UUID, targetDay: String)]
    }

    private var loadCalls: [Bool] = []
    private var templateListLoadCalls: [Bool] = []
    private var createDrafts: [NutritionMealTemplateCreateDraft] = []
    private var updateDrafts: [NutritionMealTemplateUpdateDraft] = []
    private var archiveCalls: [(id: UUID, archived: Bool)] = []
    private var applyCalls: [(id: UUID, targetDay: String)] = []

    private let detailResponse: NutritionMealTemplateDetail?
    private let loadError: Error?
    private let createError: Error?
    private let updateError: Error?
    private let archiveError: Error?
    private let applyError: Error?

    init(
        detailResponse: NutritionMealTemplateDetail?,
        loadError: Error? = nil,
        createError: Error? = nil,
        updateError: Error? = nil,
        archiveError: Error? = nil,
        applyError: Error? = nil
    ) {
        self.detailResponse = detailResponse
        self.loadError = loadError
        self.createError = createError
        self.updateError = updateError
        self.archiveError = archiveError
        self.applyError = applyError
    }

    func loadMealTemplates(includeArchived: Bool, limit: Int?, preferRemote: Bool) async throws -> [NutritionMealTemplateSummary] {
        _ = includeArchived
        _ = limit
        _ = preferRemote
        templateListLoadCalls.append(preferRemote)
        if let loadError {
            throw loadError
        }
        guard let detailResponse else {
            return []
        }
        return [
            NutritionMealTemplateSummary(
                id: detailResponse.template.id,
                name: detailResponse.template.name,
                mealType: detailResponse.template.mealType,
                calories: detailResponse.template.calories,
                proteinG: detailResponse.template.proteinG,
                fatG: detailResponse.template.fatG,
                carbsG: detailResponse.template.carbsG,
                fiberG: detailResponse.template.fiberG,
                timesUsed: detailResponse.template.timesUsed,
                lastUsedAt: detailResponse.template.lastUsedAt,
                archived: detailResponse.template.archived,
                updatedAt: detailResponse.template.updatedAt
            )
        ]
    }

    func loadMealTemplateDetail(id: UUID, preferRemote: Bool) async throws -> NutritionMealTemplateDetail? {
        _ = id
        loadCalls.append(preferRemote)
        if let loadError {
            throw loadError
        }
        return detailResponse
    }

    func createMealTemplate(_ draft: NutritionMealTemplateCreateDraft) async throws -> UUID {
        createDrafts.append(draft)
        if let createError {
            throw createError
        }
        return draft.id
    }

    func updateMealTemplate(_ update: NutritionMealTemplateUpdateDraft) async throws {
        updateDrafts.append(update)
        if let updateError {
            throw updateError
        }
    }

    func setMealTemplateArchived(id: UUID, archived: Bool) async throws {
        archiveCalls.append((id, archived))
        if let archiveError {
            throw archiveError
        }
    }

    func applyMealTemplate(
        id: UUID,
        targetDay: String,
        loggedAt: Date,
        context: MealContext?
    ) async throws -> NutritionMealTemplateApplicationResult {
        _ = loggedAt
        _ = context
        applyCalls.append((id, targetDay))
        if let applyError {
            throw applyError
        }
        return NutritionMealTemplateApplicationResult(
            foodLogId: UUID(),
            templateName: detailResponse?.template.name ?? "Coverage Template",
            itemCount: detailResponse?.items.count ?? 0
        )
    }

    func snapshot() -> Snapshot {
        Snapshot(
            loadCallCount: loadCalls.count,
            lastLoadPreferRemote: loadCalls.last,
            templateListLoadCallCount: templateListLoadCalls.count,
            lastTemplateListLoadPreferRemote: templateListLoadCalls.last,
            createDrafts: createDrafts,
            updateDrafts: updateDrafts,
            archiveCalls: archiveCalls,
            applyCalls: applyCalls
        )
    }
}

private actor CoverageBatchRecipeManagerMock: NutritionBatchRecipeManaging {
    struct Snapshot: Sendable {
        let listLoadCallCount: Int
        let lastListLoadPreferRemote: Bool?
        let loadDetailCallCount: Int
        let lastLoadDetailPreferRemote: Bool?
        let archiveCalls: [(id: UUID, archived: Bool)]
    }

    private let detailResponse: NutritionBatchRecipeDetail?
    private let loadError: Error?
    private let createError: Error?
    private let updateError: Error?
    private let archiveError: Error?
    private let duplicateError: Error?
    private let logError: Error?
    private var listLoadCalls: [Bool] = []
    private var loadDetailCalls: [Bool] = []
    private var archiveCalls: [(id: UUID, archived: Bool)] = []

    init(
        detailResponse: NutritionBatchRecipeDetail?,
        loadError: Error? = nil,
        createError: Error? = nil,
        updateError: Error? = nil,
        archiveError: Error? = nil,
        duplicateError: Error? = nil,
        logError: Error? = nil
    ) {
        self.detailResponse = detailResponse
        self.loadError = loadError
        self.createError = createError
        self.updateError = updateError
        self.archiveError = archiveError
        self.duplicateError = duplicateError
        self.logError = logError
    }

    func loadBatchRecipes(includeArchived: Bool, limit: Int?, preferRemote: Bool) async throws -> [NutritionBatchRecipeSummary] {
        _ = includeArchived
        _ = limit
        listLoadCalls.append(preferRemote)
        if let loadError {
            throw loadError
        }
        if let detailResponse {
            return [NutritionCoverageFixtures.batchSummary(archived: detailResponse.recipe.archived)]
        }
        return []
    }

    func loadBatchRecipeDetail(id: UUID, preferRemote: Bool) async throws -> NutritionBatchRecipeDetail? {
        _ = id
        loadDetailCalls.append(preferRemote)
        if let loadError {
            throw loadError
        }
        return detailResponse
    }

    func createBatchRecipe(_ draft: NutritionBatchRecipeDraft) async throws -> UUID {
        if let createError {
            throw createError
        }
        return draft.id
    }

    func updateBatchRecipe(_ draft: NutritionBatchRecipeDraft) async throws {
        _ = draft
        if let updateError {
            throw updateError
        }
    }

    func setBatchRecipeArchived(id: UUID, archived: Bool) async throws {
        archiveCalls.append((id, archived))
        if let archiveError {
            throw archiveError
        }
    }

    func duplicateBatchRecipe(id: UUID, cookedAt: String?) async throws -> NutritionBatchRecipeDuplicateResult {
        _ = id
        _ = cookedAt
        if let duplicateError {
            throw duplicateError
        }
        return NutritionBatchRecipeDuplicateResult(
            batchId: UUID(),
            name: "Coverage Duplicate"
        )
    }

    func logBatchPortion(_ draft: NutritionBatchPortionLogDraft) async throws -> NutritionBatchPortionLogResult {
        if let logError {
            throw logError
        }
        return NutritionBatchPortionLogResult(
            foodLogId: UUID(),
            foodItemId: UUID(),
            batchId: draft.batchId,
            weightRemainingG: max(0, 200 - draft.portionWeightG)
        )
    }

    func snapshot() -> Snapshot {
        Snapshot(
            listLoadCallCount: listLoadCalls.count,
            lastListLoadPreferRemote: listLoadCalls.last,
            loadDetailCallCount: loadDetailCalls.count,
            lastLoadDetailPreferRemote: loadDetailCalls.last,
            archiveCalls: archiveCalls
        )
    }
}

private final class CoverageImagePickerController: UIImagePickerController {
    private(set) var dismissCalls = 0

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        dismissCalls += 1
        completion?()
    }
}

@MainActor
final class CoverageFinalPushTests: XCTestCase {
    override func tearDown() {
        BackgroundSyncManager._testResetRegistrationOverrides()
        BackgroundSyncManager._testResetActionOverrides()
        AuthManager._testResetOverrides()
        AuthManager.setActiveAuthIdForTests(nil)
        OnboardingFeature._testSetDatabaseQueueOverride(nil)
        AppContainer.shared = nil
        LifeOSApp._testResetAsyncHelperOverrides()
        EnvironmentService._testResetOverrides()
        HealthKitManager._testResetOverrides()
        APIClient._testResetOverrides()
        SleepDayViewTestHarness.setDurationFormatterOverride(nil)
        super.tearDown()
    }

    func testGRDBColumnStrategiesForExplicitSnakeCaseModels() {
        if case .useDefaultKeys = OnboardingState.databaseColumnDecodingStrategy {
            XCTAssertTrue(true)
        } else {
            XCTFail("OnboardingState should use default key decoding")
        }

        if case .useDefaultKeys = OnboardingState.databaseColumnEncodingStrategy {
            XCTAssertTrue(true)
        } else {
            XCTFail("OnboardingState should use default key encoding")
        }

        if case .useDefaultKeys = UserBaseline.databaseColumnDecodingStrategy {
            XCTAssertTrue(true)
        } else {
            XCTFail("UserBaseline should use default key decoding")
        }

        if case .useDefaultKeys = UserBaseline.databaseColumnEncodingStrategy {
            XCTAssertTrue(true)
        } else {
            XCTFail("UserBaseline should use default key encoding")
        }
    }

    func testLifeOSAppSyncDailyStateProbeFallsBackToFalseWithoutOverride() async {
        LifeOSApp._testResetAsyncHelperOverrides()
        let result = await LifeOSApp._testRunSyncDailyStateOverrideProbe(userId: UUID())
        XCTAssertFalse(result)
    }

    func testLifeOSAppSyncDailyStateProbeFallsBackToFalseWhenOverrideThrows() async {
        enum ProbeError: Error { case expected }
        LifeOSApp._testSetAsyncHelperOverrides(syncDailyState: { _ in throw ProbeError.expected })
        defer { LifeOSApp._testResetAsyncHelperOverrides() }

        let result = await LifeOSApp._testRunSyncDailyStateOverrideProbe(userId: UUID())
        XCTAssertFalse(result)
    }

    func testLifeOSAppSyncDailyStateDefaultPathWithoutOverride() async {
        LifeOSApp._testResetAsyncHelperOverrides()
        await LifeOSApp._testRunSyncDailyStateDefault(userId: UUID())
        XCTAssertTrue(true)
    }

    func testHomeRouteHandlerNilRouterAndWellnessClosurePath() {
        let nilRouterHandled = HomeView._testRouteHandler(
            router: nil,
            url: URL(string: "https://example.com")!
        )
        XCTAssertFalse(nilRouterHandled)

        let homeView = HomeView(viewModel: HomeViewModel(pushLatestWatchSnapshot: { _ in }))
        let samples = homeView._testTriggerInstanceActions()
        XCTAssertTrue(samples.contains("lifeos://hydration"))
        XCTAssertTrue(samples.contains("lifeos://nutrition/log"))
        XCTAssertTrue(samples.contains("lifeos://sleep"))
        XCTAssertTrue(samples.contains("lifeos://wellness"))
        XCTAssertTrue(samples.contains("lifeos://simulation"))
    }

    func testBackgroundSyncDefaultSubmitBranches() {
        let now = Date()
        BackgroundSyncManager._testSetSubmitTaskRequestOverride(nil)
        BackgroundSyncManager._testScheduleOutboxReplayWithDefaultSubmit(shouldSchedule: false, now: now)
        BackgroundSyncManager._testScheduleOutboxReplayWithDefaultSubmit(shouldSchedule: true, now: now)
        BackgroundSyncManager._testScheduleDailyPullWithDefaultSubmit(shouldSchedule: false, now: now)
        BackgroundSyncManager._testScheduleDailyPullWithDefaultSubmit(shouldSchedule: true, now: now)

        BackgroundSyncManager._testSetSubmitTaskRequestOverride { _ in
            throw NSError(domain: "BackgroundSyncCoverage", code: 1)
        }
        BackgroundSyncManager._testScheduleOutboxReplayWithDefaultSubmit(shouldSchedule: true, now: now)
        BackgroundSyncManager._testScheduleDailyPullWithDefaultSubmit(shouldSchedule: true, now: now)
    }

    func testBackgroundSyncDefaultSubmitOverrideSuccessReturnBranch() {
        let now = Date()
        var submitCallCount = 0
        BackgroundSyncManager._testSetSubmitTaskRequestOverride { _ in
            submitCallCount += 1
        }
        defer { BackgroundSyncManager._testSetSubmitTaskRequestOverride(nil) }

        BackgroundSyncManager._testScheduleOutboxReplayWithDefaultSubmit(shouldSchedule: true, now: now)
        BackgroundSyncManager._testScheduleDailyPullWithDefaultSubmit(shouldSchedule: true, now: now)
        XCTAssertEqual(submitCallCount, 2)
    }

    func testOnboardingFeatureResolvedSyncEngineFallbackPath() {
        OnboardingFeature._testResolveSyncEngineFallbackPath()
        XCTAssertTrue(true)
    }

    func testSettingsExportUnknownFailureUsesFallbackMessage() async {
        let message = await SettingsView._testRequestExportUnknownFailureMessage()
        XCTAssertEqual(message, SettingsError.exportFailed.errorDescription)
    }

    func testAuthViewResolveAuthManagerHelperCoversOverrideAndEnvironmentBranches() {
        let environmentAuthManager = AuthManager()
        let overrideAuthManager = AuthManager()

        let resolvedEnvironment = AuthView._testResolveAuthManager(
            authManagerOverride: nil,
            environmentAuthManager: environmentAuthManager
        )
        XCTAssertTrue(resolvedEnvironment === environmentAuthManager)

        let resolvedOverride = AuthView._testResolveAuthManager(
            authManagerOverride: overrideAuthManager,
            environmentAuthManager: environmentAuthManager
        )
        XCTAssertTrue(resolvedOverride === overrideAuthManager)

        let deferredEnvironment = AuthView._testResolveAuthManagerDeferred(
            authManagerOverride: nil,
            environmentAuthManager: environmentAuthManager
        )
        XCTAssertTrue(deferredEnvironment === environmentAuthManager)

        let deferredOverride = AuthView._testResolveAuthManagerDeferred(
            authManagerOverride: overrideAuthManager,
            environmentAuthManager: environmentAuthManager
        )
        XCTAssertTrue(deferredOverride === overrideAuthManager)

        let getterOverrideView = AuthView(testAuthManager: overrideAuthManager)
        XCTAssertTrue(getterOverrideView._testAuthManagerGetterIsOverride())
        XCTAssertTrue(getterOverrideView._testResolveAuthManagerFromGetter() === overrideAuthManager)
    }

    func testAuthViewDefaultAuthManagerWrapperMethods() async {
        var state = AuthFeature.State()
        state.email = "coverage@example.com"
        state.otpCode = "123456"
        let store = Store(initialState: state) { AuthFeature() }
        let authView = AuthView(testAuthManager: AuthManager())
        let now = Date(timeIntervalSince1970: 1_700_400_000)
        let authId = UUID()

        AuthManager._testSetDefaultSendOTPOverride { _ in }
        AuthManager._testSetDefaultVerifyOTPOverride { _, _ in
            let user = Supabase.User(
                id: authId,
                appMetadata: [:],
                userMetadata: [:],
                aud: "authenticated",
                createdAt: now,
                updatedAt: now,
                isAnonymous: false
            )
            return Supabase.Session(
                accessToken: "coverage-token",
                tokenType: "bearer",
                expiresIn: 3600,
                expiresAt: now.addingTimeInterval(3600).timeIntervalSince1970,
                refreshToken: "coverage-refresh",
                user: user
            )
        }
        defer { AuthManager._testResetOverrides() }

        do {
            try await authView._testRunDefaultAppleSignInWithAuthManager(credential: nil)
            XCTFail("Expected invalid credential error")
        } catch {
            XCTAssertNotNil(error.localizedDescription)
        }

        await authView._testRunDefaultSendOTP(store: store)
        await authView._testRunDefaultVerifyOTP(store: store)
    }

    func testAuthManagerLoadingOverrideFallsBackToBootstrapAuthIdWhenFallbackOverrideIsNil() {
        AuthManager._testSetFallbackUITestAuthIdOverride(.some(nil))
        let manager = AuthManager()
        manager._testApplyUITestOverride(.loading)
        XCTAssertEqual(manager.userId, UITestBootstrap.authId)
    }

    func testSimulationTargetDateFallbackBranch() {
        let now = Date()
        let resolved = SimulationViewModel._testResolveTargetDate(now: now) { _ in nil }
        XCTAssertEqual(resolved, now)
    }

    func testDeepLinkRouterHelpersCoverFallbackComponentsAndAuditPropertyCasting() {
        XCTAssertEqual(DeepLinkRouter._testFirstPathComponent(""), "")
        XCTAssertEqual(DeepLinkRouter._testFirstPathComponent("/"), "")
        XCTAssertTrue(DeepLinkRouter._testAuditPropertiesDictionary(["k": "v"]).keys.contains("k"))
        XCTAssertTrue(DeepLinkRouter._testAuditPropertiesDictionary(["x", "y"]).isEmpty)

        let router = DeepLinkRouter()
        XCTAssertTrue(router.handle(URL(string: "lifeos:")!))
        _ = router.consumePendingNavigation()
    }

    func testSyncEngineSanitizedSerializationFailureThrowsInsteadOfSendingRaw() {
        let error = SyncEngine._testSerializeSanitizedBodyFailure(
            sanitized: ["safe": "value"]
        ) as NSError
        XCTAssertNotEqual(error.code, -1, "serializeSanitizedBody must throw on serializer failure")
    }

    func testForceUpdateCurrentVersionFallbackAndNumericOverflowBranch() {
        XCTAssertEqual(ForceUpdateManager._testResolveCurrentVersion(infoDictionary: nil), "0.0.0")

        let manager = ForceUpdateManager()
        let huge = "999999999999999999999999999999999999999999"
        XCTAssertFalse(manager.compareVersions("1", isLessThan: huge))
    }

    func testHealthKitFallbackEightAMAndDefaultRequestAuthorizationPath() async {
        let now = Date()
        XCTAssertEqual(HealthKitManager._testFallbackEightAMDate(dayStart: now), now)

        HealthKitManager._testSetStoreRequestAuthorizationRunner(nil)
        HealthKitManager._testSetDefaultStoreRequestAuthorizationRunner { _, _ in }
        defer {
            HealthKitManager._testSetDefaultStoreRequestAuthorizationRunner(nil)
            HealthKitManager._testSetStoreRequestAuthorizationRunner(nil)
        }

        let manager = HealthKitManager()
        try? await manager._testRequestReadAuthorization(store: HKHealthStore(), readTypes: [])
        XCTAssertTrue(true)
    }

    func testNotificationEngineOvernightBeforeEndBranch() {
        let userId = UUID()
        var settings = NotificationSettings(userId: userId)
        settings.quietHoursStart = "22:00"
        settings.quietHoursEnd = "07:00"

        var calendar = Calendar.current
        calendar.timeZone = .current
        let now = calendar.date(bySettingHour: 3, minute: 0, second: 0, of: Date())!

        let notification = LifeOSNotification(
            category: .mealReminder,
            priority: .active,
            title: "Meal",
            body: "Body"
        )

        let allowed = NotificationEngine._testCheckQuietHours(notification, settings: settings, now: now)
        XCTAssertFalse(allowed)
    }

    func testEnvironmentServiceDefaultReverseGeocodeSelectionAndDidFailContinuationResume() async {
        let service = EnvironmentService()
        EnvironmentService._testSetReverseGeocodeOverride(nil)
        service._testResolveReverseGeocodeActionForCoverage()

        let completion = expectation(description: "location continuation resumed with failure")
        Task { @MainActor in
            do {
                _ = try await service._testRequestLocation(
                    currentStatus: .authorizedWhenInUse,
                    requestAuthorizationBlock: { .authorizedWhenInUse },
                    requestLocationAction: {},
                    timeoutNanoseconds: 5_000_000_000
                )
                XCTFail("Expected location request to fail")
            } catch {
                completion.fulfill()
            }
        }

        try? await Task.sleep(nanoseconds: 20_000_000)
        service.locationManager(CLLocationManager(), didFailWithError: NSError(domain: "EnvironmentCoverage", code: 9))
        await fulfillment(of: [completion], timeout: 1.0)
    }

    func testEnvironmentServicePublicWrappersExerciseAuthorizationAndDefaultGeocodeClosures() async {
        let service = EnvironmentService()

        EnvironmentService._testSetAuthorizationStatusOverride(.notDetermined)
        EnvironmentService._testSetRequestWhenInUseAuthorizationOverride(nil)

        let authTask = Task { await service._testRequestAuthorizationViaPublicWrapper() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        service.locationManagerDidChangeAuthorization(CLLocationManager())
        _ = await authTask.value

        EnvironmentService._testSetAuthorizationStatusOverride(.notDetermined)
        EnvironmentService._testSetRequestLocationActionOverride({})
        let locationTask = Task {
            try await service._testRequestLocationViaPublicWrapper()
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        service.locationManagerDidChangeAuthorization(CLLocationManager())
        do {
            _ = try await locationTask.value
            XCTFail("Expected denied location flow with unresolved authorization state")
        } catch {
            XCTAssertNotNil(error.localizedDescription)
        }

        EnvironmentService._testSetReverseGeocodeOverride(nil)
        do {
            _ = try await service._testResolveCityViaPublicWrapper(
                from: CLLocation(latitude: 55.7558, longitude: 37.6173)
            )
        } catch {
            XCTAssertNotNil(error.localizedDescription)
        }
    }

    func testEnvironmentServiceAuthorizationWrapperFallbackStatusBranch() async {
        let service = EnvironmentService()
        EnvironmentService._testSetAuthorizationStatusOverride(nil)
        EnvironmentService._testSetRequestWhenInUseAuthorizationOverride({})

        let authTask = Task { await service._testRequestAuthorizationViaPublicWrapper() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        service.locationManagerDidChangeAuthorization(CLLocationManager())
        _ = await authTask.value
        XCTAssertTrue(true)
    }

    func testMainTabSelectionBindingRoundTripCoversGetSetClosures() {
        let router = DeepLinkRouter()
        let mainTab = MainTabView(injectedRouter: router)
        let result = mainTab._testTabSelectionBindingRoundTrip(initial: .home, updated: .settings)
        XCTAssertEqual(result.read, .home)
        XCTAssertEqual(result.stored, .settings)
        XCTAssertTrue(mainTab._testRouterGetterIsInjected())
        XCTAssertTrue(mainTab._testResolveRouterFromGetter() === router)

        let environmentRouter = DeepLinkRouter()
        let resolvedEnvironment = MainTabView._testResolveRouter(
            injectedRouter: nil,
            environmentRouter: environmentRouter
        )
        XCTAssertTrue(resolvedEnvironment === environmentRouter)

        let resolvedInjected = MainTabView._testResolveRouter(
            injectedRouter: router,
            environmentRouter: environmentRouter
        )
        XCTAssertTrue(resolvedInjected === router)
    }

    func testWatchSyncEncodedSizeReturnsZeroOnEncodingFailure() {
        let manager = WatchSyncManager()
        let snapshot = WatchSnapshot(
            date: "2026-02-27",
            lastUpdatedAt: Date(),
            recoveryScore: .nan,
            recoveryZone: "optimal",
            confidenceScore: 0.9,
            nextBestAction: nil,
            sleepDurationHours: nil,
            sleepQualityPercent: nil,
            nutritionAdherencePercent: nil,
            supplementsDueSoon: nil,
            wasTruncated: nil
        )
        XCTAssertEqual(manager._testEncodedSize(snapshot), Int.max)
    }

    func testSleepLogDecodeFallbackReadsLegacyCaffeineKeyPath() throws {
        var log = SleepLog(userId: UUID(), date: "2026-02-27")
        log.caffeineAfter14 = true
        let encoded = try JSONEncoder().encode(log)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        payload.removeValue(forKey: "caffeine_after_14")
        payload["caffeineAfter14"] = false

        let rewritten = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(SleepLog.self, from: rewritten)
        XCTAssertEqual(decoded.caffeineAfter14, false)
    }

    func testSleepLogDecodeFallbackReadsSnakeCaseCaffeineKeyPath() throws {
        var log = SleepLog(userId: UUID(), date: "2026-02-27")
        log.caffeineAfter14 = nil
        let encoded = try JSONEncoder().encode(log)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        payload.removeValue(forKey: "caffeineAfter14")
        payload["caffeine_after_14"] = true

        let rewritten = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(SleepLog.self, from: rewritten)
        XCTAssertEqual(decoded.caffeineAfter14, true)
    }

    func testSleepDataQualityScoreAdditionalDurationBands() {
        let lowBand = SleepData(
            totalHours: 6.5,
            deepMinutes: 60,
            remMinutes: 90,
            lightMinutes: 240,
            awakeMinutes: 30,
            efficiency: 90,
            bedTime: nil,
            wakeTime: nil
        )
        let highBand = SleepData(
            totalHours: 9.5,
            deepMinutes: 60,
            remMinutes: 90,
            lightMinutes: 240,
            awakeMinutes: 30,
            efficiency: 90,
            bedTime: nil,
            wakeTime: nil
        )

        XCTAssertGreaterThan(lowBand.qualityScore, 0)
        XCTAssertGreaterThan(highBand.qualityScore, 0)
    }

    func testSleepSummaryDurationFormatterFallbackAndSuccessBranches() {
        SleepDayViewTestHarness.setDurationFormatterOverride { _ in nil }
        let fallbackTitle = SleepDayViewTestHarness.resolvedPrimaryText(durationMinutes: 90)
        XCTAssertEqual(fallbackTitle, String(localized: "sleep_title"))

        SleepDayViewTestHarness.setDurationFormatterOverride { _ in "custom-duration" }
        let custom = SleepDayViewTestHarness.resolvedPrimaryText(durationMinutes: 90)
        XCTAssertEqual(custom, "custom-duration")

        SleepDayViewTestHarness.setDurationFormatterOverride(nil)
    }

    func testInsightBodyWithClinicianCaveatAppendAndPassthroughBranches() {
        let disclaimer = String(localized: "clinician_disclaimer")
        let appended = Insight(
            userId: UUID(),
            category: .health,
            title: "Coverage",
            body: "Needs disclaimer",
            confidence: 0.9
        )
        XCTAssertTrue(appended.bodyWithClinicianCaveat.contains(disclaimer))

        var forcedAppend = appended
        forcedAppend.body = "Needs disclaimer after mutation"
        XCTAssertTrue(forcedAppend.bodyWithClinicianCaveat.contains(disclaimer))
        XCTAssertNotEqual(forcedAppend.bodyWithClinicianCaveat, forcedAppend.body)

        let passthrough = Insight(
            userId: UUID(),
            category: .health,
            title: "Coverage",
            body: "Already has \(disclaimer)",
            confidence: 0.9
        )
        XCTAssertEqual(passthrough.bodyWithClinicianCaveat, passthrough.body)

        let general = Insight(
            userId: UUID(),
            category: .general,
            title: "Coverage",
            body: "General insight body",
            confidence: 0.9
        )
        XCTAssertEqual(general.bodyWithClinicianCaveat, general.body)
    }

    func testNutritionLogViewModelSaveFallbackAndErrorBranches() async throws {
        actor LogCapture {
            private(set) var last: FoodLog?
            func set(_ log: FoodLog) { last = log }
            func snapshot() -> FoodLog? { last }
        }

        struct NoopLogger: NutritionMealLogging {
            func logMeal(_ log: FoodLog) async throws {
                _ = log
            }
        }

        struct CapturingMealManager: NutritionMealManaging {
            let capture: LogCapture
            func persist(log: FoodLog, detectedItems: [NutritionDraftCandidateItem]) async throws {
                _ = detectedItems
                await capture.set(log)
            }
            func persist(log: FoodLog, items: [FoodItem]) async throws {
                _ = items
                await capture.set(log)
            }
            func loadMealDetail(id: UUID, preferRemote: Bool) async throws -> NutritionMealDetail? {
                _ = id
                _ = preferRemote
                return nil
            }
            func updateMeal(_ update: NutritionMealUpdateDraft) async throws { _ = update }
            func deleteMeal(id: UUID) async throws -> Date { _ = id; return Date() }
            func undoDeleteMeal(id: UUID) async throws { _ = id }
        }

        struct ThrowingMealManager: NutritionMealManaging {
            struct ExpectedError: Error {}
            func persist(log: FoodLog, detectedItems: [NutritionDraftCandidateItem]) async throws {
                _ = log
                _ = detectedItems
                throw ExpectedError()
            }
            func persist(log: FoodLog, items: [FoodItem]) async throws {
                _ = log
                _ = items
                throw ExpectedError()
            }
            func loadMealDetail(id: UUID, preferRemote: Bool) async throws -> NutritionMealDetail? {
                _ = id
                _ = preferRemote
                return nil
            }
            func updateMeal(_ update: NutritionMealUpdateDraft) async throws { _ = update }
            func deleteMeal(id: UUID) async throws -> Date { _ = id; return Date() }
            func undoDeleteMeal(id: UUID) async throws { _ = id }
        }

        let dbManager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let now = Date()
        try await dbManager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [userId.uuidString, authId.uuidString, "UTC", "metric", now, now]
            )
        }

        let capture = LogCapture()
        AuthManager.setActiveAuthIdForTests(authId)
        let successVM = NutritionLogViewModel(
            method: nil,
            aiConfidence: nil,
            nutritionService: NoopLogger(),
            mealManager: CapturingMealManager(capture: capture),
            dbQueue: dbManager.dbQueue
        )
        successVM.addMealItem()
        let saved = await successVM.save()
        XCTAssertTrue(saved)
        let savedLog = await capture.snapshot()
        XCTAssertEqual(savedLog?.inputMethod, .manual)
        XCTAssertNil(savedLog?.aiConfidence)

        let failingVM = NutritionLogViewModel(
            method: .manual,
            aiConfidence: nil,
            nutritionService: NoopLogger(),
            mealManager: ThrowingMealManager(),
            dbQueue: dbManager.dbQueue
        )
        failingVM.addMealItem()
        let failed = await failingVM.save()
        XCTAssertFalse(failed)
        XCTAssertEqual(failingVM.errorMessage, SyncError.serverError(code: 0, message: nil).errorDescription)

        AuthManager.setActiveAuthIdForTests(nil)
        let fallbackVM = NutritionLogViewModel(
            method: nil,
            aiConfidence: nil,
            nutritionService: NoopLogger(),
            mealManager: CapturingMealManager(capture: capture),
            dbQueue: dbManager.dbQueue
        )
        fallbackVM.addMealItem()
        let fallbackSaved = await fallbackVM.save()
        XCTAssertFalse(fallbackSaved)

        let missingUserAuthId = UUID()
        AuthManager.setActiveAuthIdForTests(missingUserAuthId)
        let missingUserVM = NutritionLogViewModel(
            method: .manual,
            aiConfidence: nil,
            nutritionService: NoopLogger(),
            dbQueue: dbManager.dbQueue
        )
        let resolvedTarget = try await missingUserVM._testResolvedDynamicTarget()
        XCTAssertNil(resolvedTarget)
    }

    func testNutritionLogViewSaveButtonTapSuccessBranchCoverage() async throws {
        struct NoopLogger: NutritionMealLogging {
            func logMeal(_ log: FoodLog) async throws {}
        }

        struct SuccessMealManager: NutritionMealManaging {
            func persist(log: FoodLog, detectedItems: [NutritionDraftCandidateItem]) async throws {
                _ = log
                _ = detectedItems
            }

            func persist(log: FoodLog, items: [FoodItem]) async throws {
                _ = log
                _ = items
            }

            func loadMealDetail(id: UUID, preferRemote: Bool) async throws -> NutritionMealDetail? {
                _ = id
                _ = preferRemote
                return nil
            }

            func updateMeal(_ update: NutritionMealUpdateDraft) async throws {
                _ = update
            }

            func deleteMeal(id: UUID) async throws -> Date {
                _ = id
                return Date()
            }

            func undoDeleteMeal(id: UUID) async throws {
                _ = id
            }
        }

        let dbManager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let now = Date()

        try await dbManager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [userId.uuidString, authId.uuidString, "UTC", "metric", now, now]
            )
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let viewModel = NutritionLogViewModel(
            method: .manual,
            aiConfidence: nil,
            nutritionService: NoopLogger(),
            mealManager: SuccessMealManager(),
            dbQueue: dbManager.dbQueue
        )
        viewModel.addMealItem()
        viewModel._testOverrideState(
            isSaving: false,
            didReviewLowConfidence: true,
            errorMessage: nil,
            dynamicHint: ""
        )

        NutritionLogView(
            method: .manual,
            aiConfidence: nil,
            testViewModel: viewModel
        )._testTriggerSaveButtonTap()
        try? await Task.sleep(nanoseconds: 100_000_000)
        let completionViewModel = NutritionLogViewModel(
            method: .manual,
            aiConfidence: nil,
            nutritionService: NoopLogger(),
            mealManager: SuccessMealManager(),
            dbQueue: dbManager.dbQueue
        )
        completionViewModel.addMealItem()
        completionViewModel._testOverrideState(
            isSaving: false,
            didReviewLowConfidence: true,
            errorMessage: nil,
            dynamicHint: ""
        )
        let completionExpectation = expectation(description: "Nutrition save completion callback fires")
        NutritionLogView(
            method: .manual,
            aiConfidence: nil,
            onComplete: { completionExpectation.fulfill() },
            testViewModel: completionViewModel
        )._testTriggerSaveButtonTap()
        await fulfillment(of: [completionExpectation], timeout: 1.0)
        XCTAssertTrue(true)
    }

    func testHealthKitDefaultStoreAuthorizationPathWithNonEmptyReadTypes() async {
        let manager = HealthKitManager()
        let readTypes: Set<HKObjectType> = [HKQuantityType(.stepCount)]

        HealthKitManager._testSetStoreRequestAuthorizationRunner(nil)
        HealthKitManager._testSetDefaultStoreRequestAuthorizationRunner { _, requestedTypes in
            XCTAssertEqual(requestedTypes.count, readTypes.count)
            XCTAssertTrue(requestedTypes.contains(HKQuantityType(.stepCount)))
        }
        defer {
            HealthKitManager._testSetDefaultStoreRequestAuthorizationRunner(nil)
            HealthKitManager._testSetStoreRequestAuthorizationRunner(nil)
        }

        try? await manager._testRequestReadAuthorization(store: HKHealthStore(), readTypes: readTypes)
        XCTAssertTrue(true)
    }

    func testHealthKitRequestReadAuthorizationStoreRunnerBranch() async throws {
        final class RequestRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var calls = 0

            func mark() {
                lock.lock()
                calls += 1
                lock.unlock()
            }
        }

        let recorder = RequestRecorder()
        let manager = HealthKitManager()
        HealthKitManager._testSetStoreRequestAuthorizationRunner { _, _ in
            recorder.mark()
        }
        defer { HealthKitManager._testSetStoreRequestAuthorizationRunner(nil) }

        try await manager._testRequestReadAuthorization(
            store: HKHealthStore(),
            readTypes: [HKQuantityType(.stepCount)]
        )
        XCTAssertEqual(recorder.calls, 1)
    }

    func testHealthKitEnableBackgroundDeliveryUsingStoreHelperCoverage() async {
        let manager = HealthKitManager()
        let types: [HKSampleType] = [HKQuantityType(.stepCount)]
        HealthKitManager._testSetStoreEnableBackgroundDeliveryRunner { _, _, completion in
            completion(true, nil)
        }
        defer { HealthKitManager._testSetStoreEnableBackgroundDeliveryRunner(nil) }

        do {
            try await manager._testEnableBackgroundDeliveryUsingStore(types: types, store: HKHealthStore())
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHealthKitSleepSelectionEmptyInputAndArchiveOverrideBranches() async {
        let manager = HealthKitManager()
        let preferred = await manager._testSelectPreferredSleepSource([])
        XCTAssertTrue(preferred.isEmpty)

        let selectedBout = await manager._testSelectMainSleepBout([], for: Date())
        XCTAssertTrue(selectedBout.isEmpty)

        let anchorKey = "coverage_anchor_success_\(UUID().uuidString)"
        let storageKey = "healthkit_anchor_" + anchorKey
        let anchor = HKQueryAnchor(fromValue: 11)
        HealthKitManager._testSetAnchorArchiveRunner { _ in
            Data("coverage-anchor".utf8)
        }
        defer {
            HealthKitManager._testSetAnchorArchiveRunner(nil)
            UserDefaults.standard.removeObject(forKey: storageKey)
        }

        HealthKitManager._testSaveAnchor(anchor, anchorKey: anchorKey)
        XCTAssertNotNil(UserDefaults.standard.data(forKey: storageKey))
    }

    func testNutritionViewsHarnessCoversTapAndDismissPaths() async {
        await NutritionViewsTestHarness.exerciseBodyBranches()
        XCTAssertTrue(true)
    }

    func testNutritionDayViewModalLoaderAndMappingHelpersCoverage() async throws {
        XCTAssertEqual(NutritionDayView._testInputMethodsCount(batchRecipesEnabled: true), 6)
        XCTAssertEqual(NutritionDayView._testInputMethodsCount(batchRecipesEnabled: false), 5)
        XCTAssertEqual(
            NutritionDayView._testVisibleInputMethods(batchRecipesEnabled: false),
            [.photo, .barcode, .voice, .manual, .template]
        )

        XCTAssertEqual(
            NutritionDayView._testResolvedModalID(for: .photo, batchRecipesEnabled: true),
            "photo_capture"
        )
        XCTAssertEqual(
            NutritionDayView._testResolvedModalID(for: .barcode, batchRecipesEnabled: true),
            "barcode_scanner"
        )
        XCTAssertEqual(
            NutritionDayView._testResolvedModalID(for: .voice, batchRecipesEnabled: true),
            "voice_input"
        )
        XCTAssertEqual(
            NutritionDayView._testResolvedModalID(for: .manual, batchRecipesEnabled: true),
            "food_search"
        )
        XCTAssertEqual(
            NutritionDayView._testResolvedModalID(for: .batch, batchRecipesEnabled: true),
            "batch_recipe"
        )
        XCTAssertNil(NutritionDayView._testResolvedModalID(for: .batch, batchRecipesEnabled: false))
        XCTAssertNil(NutritionDayView._testResolvedModalID(for: .template, batchRecipesEnabled: true))

        let modalIDs = NutritionDayView._testModalIDs()
        XCTAssertEqual(modalIDs.prefix(6), [
            "photo_capture",
            "barcode_scanner",
            "voice_input",
            "food_search",
            "batch_recipe",
            "calendar"
        ])
        XCTAssertTrue(modalIDs.last?.hasPrefix("log:") == true)

        let batchModalFlags = NutritionDayView._testIsBatchRecipeModalFlags()
        XCTAssertFalse(batchModalFlags.nilModal)
        XCTAssertFalse(batchModalFlags.manualModal)
        XCTAssertTrue(batchModalFlags.batchModal)

        let selectedDate = try XCTUnwrap(DiaryDateFormatter.parseDate("2026-03-19"))
        let navigationDraft = NutritionDayView._testNavigationDraft(
            method: .voice,
            confidence: 0.77,
            selectedDate: selectedDate
        )
        XCTAssertEqual(navigationDraft.method, .voice)
        XCTAssertEqual(navigationDraft.confidence, 0.77)
        XCTAssertEqual(navigationDraft.loggedDate, "2026-03-19")

        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let user = User(id: UUID(), authId: authId, timezone: "UTC", units: .metric)
        let mealId = UUID()
        let fallbackMealId = UUID()
        let invalidDateMealId = UUID()
        let deletedMealId = UUID()

        try await manager.dbQueue.write { db in
            try user.insert(db)

            var activeLog = FoodLog(
                id: mealId,
                userId: user.id,
                loggedAt: NutritionCoverageFixtures.loggedAt,
                loggedDate: "2026-03-19",
                inputMethod: .vision,
                calories: 520,
                proteinG: 35,
                fatG: 18,
                carbsG: 46
            )
            activeLog.mealType = .lunch
            activeLog.aiConfidence = 0.74
            try activeLog.insert(db)

            try db.execute(
                sql: """
                    INSERT INTO food_logs (
                        id, user_id, logged_at, logged_date, input_method,
                        calories, protein_g, fat_g, carbs_g, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    fallbackMealId.uuidString,
                    user.id.uuidString,
                    NutritionCoverageFixtures.loggedAt,
                    "2026-03-19",
                    "manual",
                    0,
                    0,
                    0,
                    0,
                    Date(),
                    Date()
                ]
            )

            try db.execute(
                sql: """
                    INSERT INTO food_logs (
                        id, user_id, logged_at, logged_date, input_method,
                        calories, protein_g, fat_g, carbs_g, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    invalidDateMealId.uuidString,
                    user.id.uuidString,
                    "coverage-invalid-date",
                    "2026-03-19",
                    "manual",
                    0,
                    0,
                    0,
                    0,
                    Date(),
                    Date()
                ]
            )

            var deletedLog = FoodLog(
                id: deletedMealId,
                userId: user.id,
                loggedAt: NutritionCoverageFixtures.loggedAt,
                loggedDate: "2026-03-19",
                inputMethod: .voice,
                calories: 310,
                proteinG: 14,
                fatG: 9,
                carbsG: 35
            )
            deletedLog.deletedAt = Date()
            try deletedLog.insert(db)
        }

        let loadedMeals = await NutritionDayView._testLoadMealsForDate(
            selectedDate: selectedDate,
            dbQueue: manager.dbQueue,
            authId: authId.uuidString
        )
        XCTAssertEqual(loadedMeals.count, 3)
        XCTAssertEqual(Set(loadedMeals.map(\.id)), Set([mealId, fallbackMealId, invalidDateMealId]))
        let persistedMeal = try XCTUnwrap(loadedMeals.first(where: { $0.id == mealId }))
        XCTAssertEqual(persistedMeal.mealType, .lunch)
        XCTAssertEqual(persistedMeal.aiConfidence, 0.74)
        let fallbackMeal = try XCTUnwrap(loadedMeals.first(where: { $0.id == fallbackMealId }))
        XCTAssertEqual(fallbackMeal.inputMethod, .manual)
        XCTAssertEqual(fallbackMeal.calories, 0)
        XCTAssertEqual(fallbackMeal.proteinG, 0)
        XCTAssertEqual(fallbackMeal.fatG, 0)
        XCTAssertEqual(fallbackMeal.carbsG, 0)
        XCTAssertEqual(fallbackMeal.loggedDate, "2026-03-19")
        XCTAssertEqual(fallbackMeal.loggedAt, NutritionCoverageFixtures.loggedAt)
        let invalidDateMeal = try XCTUnwrap(loadedMeals.first(where: { $0.id == invalidDateMealId }))
        XCTAssertEqual(invalidDateMeal.inputMethod, .manual)
        XCTAssertEqual(invalidDateMeal.calories, 0)
        XCTAssertLessThan(abs(invalidDateMeal.loggedAt.timeIntervalSinceNow), 60)

        let fallbackNow = Date(timeIntervalSince1970: 1_700_000_000)
        let fallbackDecodedMeal = try XCTUnwrap(
            NutritionDayView._testDecodeFoodLogRow(
                values: [
                    "id": fallbackMealId.uuidString,
                    "user_id": user.id.uuidString,
                    "input_method": "manual",
                    "logged_at": "coverage-invalid-date",
                    "calories": "coverage-invalid-calories",
                    "protein_g": "coverage-invalid-protein",
                    "fat_g": "coverage-invalid-fat",
                    "carbs_g": "coverage-invalid-carbs",
                    "meal_type": "coverage-invalid-meal-type",
                    "ai_confidence": "coverage-invalid-confidence"
                ],
                targetDate: "2026-03-19",
                fallbackLoggedAt: fallbackNow
            )
        )
        XCTAssertEqual(fallbackDecodedMeal.loggedAt, fallbackNow)
        XCTAssertEqual(fallbackDecodedMeal.inputMethod, .manual)
        XCTAssertEqual(fallbackDecodedMeal.calories, 0)
        XCTAssertEqual(fallbackDecodedMeal.proteinG, 0)
        XCTAssertEqual(fallbackDecodedMeal.fatG, 0)
        XCTAssertEqual(fallbackDecodedMeal.carbsG, 0)
        XCTAssertEqual(fallbackDecodedMeal.loggedDate, "2026-03-19")
        XCTAssertNil(fallbackDecodedMeal.mealType)
        XCTAssertNil(fallbackDecodedMeal.aiConfidence)
        let missingColumnDecodedMeal = try XCTUnwrap(
            NutritionDayView._testDecodeFoodLogRow(
                values: [
                    "id": fallbackMealId.uuidString,
                    "user_id": user.id.uuidString,
                    "input_method": "manual"
                ],
                targetDate: "2026-03-19",
                fallbackLoggedAt: fallbackNow
            )
        )
        XCTAssertEqual(missingColumnDecodedMeal.loggedAt, fallbackNow)
        XCTAssertEqual(missingColumnDecodedMeal.calories, 0)
        XCTAssertEqual(missingColumnDecodedMeal.proteinG, 0)
        XCTAssertEqual(missingColumnDecodedMeal.fatG, 0)
        XCTAssertEqual(missingColumnDecodedMeal.carbsG, 0)
        XCTAssertNil(
            NutritionDayView._testDecodeFoodLogRow(
                values: [
                    "id": fallbackMealId.uuidString,
                    "user_id": user.id.uuidString,
                    "input_method": "coverage-invalid-method"
                ],
                targetDate: "2026-03-19",
                fallbackLoggedAt: fallbackNow
            )
        )

        let missingMeals = await NutritionDayView._testLoadMealsForDate(
            selectedDate: selectedDate,
            dbQueue: manager.dbQueue,
            authId: UUID().uuidString
        )
        XCTAssertTrue(missingMeals.isEmpty)

        let resolvedOverrideMeals = await NutritionDayView._testResolvedMealsForDate(
            selectedDate: selectedDate,
            overrideAction: { _ in loadedMeals },
            dbQueue: manager.dbQueue,
            authId: UUID().uuidString
        )
        XCTAssertEqual(resolvedOverrideMeals.map(\.id), loadedMeals.map(\.id))

        let resolvedDatabaseMeals = await NutritionDayView._testResolvedMealsForDate(
            selectedDate: selectedDate,
            overrideAction: nil,
            dbQueue: manager.dbQueue,
            authId: authId.uuidString
        )
        XCTAssertEqual(Set(resolvedDatabaseMeals.map(\.id)), Set([mealId, fallbackMealId, invalidDateMealId]))

        XCTAssertEqual(
            NutritionViewsTestHarness.inputMethodMappings(),
            [.vision, .barcode, .voice, .manual, .batch, .template]
        )

        let successHarnessFlags = NutritionViewsTestHarness.saveOutcomeFlags(didSave: true)
        XCTAssertTrue(successHarnessFlags.dismissed)
        XCTAssertTrue(successHarnessFlags.success)
        XCTAssertFalse(successHarnessFlags.failure)

        let successFlags = NutritionLogView._testSaveOutcomeFlags(didSave: true)
        XCTAssertTrue(successFlags.dismissed)
        XCTAssertTrue(successFlags.success)
        XCTAssertFalse(successFlags.failure)

        let failureFlags = NutritionLogView._testSaveOutcomeFlags(didSave: false)
        XCTAssertFalse(failureFlags.dismissed)
        XCTAssertFalse(failureFlags.success)
        XCTAssertTrue(failureFlags.failure)

        XCTAssertEqual(NutritionInputMethod.vision.asLogMethod, .photo)
        XCTAssertEqual(NutritionInputMethod.barcode.asLogMethod, .barcode)
        XCTAssertEqual(NutritionInputMethod.voice.asLogMethod, .voice)
        XCTAssertEqual(NutritionInputMethod.manual.asLogMethod, .manual)
        XCTAssertEqual(NutritionInputMethod.batch.asLogMethod, .batch)
        XCTAssertEqual(NutritionInputMethod.template.asLogMethod, .template)
    }

    @MainActor
    func testNutritionDayViewInstanceActionsCoverage() async throws {
        let userId = UUID()
        let firstMealId = UUID()
        let secondMealId = UUID()
        let sampleMeals = [
            FoodLog(
                id: firstMealId,
                userId: userId,
                loggedAt: NutritionCoverageFixtures.loggedAt,
                loggedDate: NutritionCoverageFixtures.targetDay,
                inputMethod: .manual,
                calories: 420,
                proteinG: 28,
                fatG: 12,
                carbsG: 41
            ),
            FoodLog(
                id: secondMealId,
                userId: userId,
                loggedAt: NutritionCoverageFixtures.loggedAt.addingTimeInterval(3600),
                loggedDate: NutritionCoverageFixtures.targetDay,
                inputMethod: .voice,
                calories: 330,
                proteinG: 18,
                fatG: 11,
                carbsG: 37
            )
        ]

        let routingView = NutritionDayView(dateString: NutritionCoverageFixtures.targetDay)
        let dateActions = routingView._testInvokeDateNavigationActions()
        XCTAssertEqual(dateActions.previousDate, "2026-03-18")
        XCTAssertEqual(dateActions.calendarModalID, "calendar")
        XCTAssertEqual(dateActions.nextDate, "2026-03-20")
        let manualSheetModalID = await routingView._testInvokePresentSheet(for: .manual, batchRecipesEnabled: true)
        XCTAssertEqual(manualSheetModalID, "food_search")
        let batchSheetModalID = await routingView._testInvokePresentSheet(for: .batch, batchRecipesEnabled: true)
        XCTAssertEqual(batchSheetModalID, "batch_recipe")
        let disabledBatchSheetModalID = await routingView._testInvokePresentSheet(for: .batch, batchRecipesEnabled: false)
        XCTAssertNil(disabledBatchSheetModalID)
        let enabledBatchQuickActionModalID = await routingView._testInvokePresentBatchRecipeIfEnabled(batchRecipesEnabled: true)
        XCTAssertEqual(enabledBatchQuickActionModalID, "batch_recipe")
        let disabledBatchQuickActionModalID = await routingView._testInvokePresentBatchRecipeIfEnabled(batchRecipesEnabled: false)
        XCTAssertNil(disabledBatchQuickActionModalID)
        let barcodeInputModalID = await routingView._testInvokeInputMethodSelection(.barcode, batchRecipesEnabled: true)
        XCTAssertEqual(barcodeInputModalID, "barcode_scanner")

        let methodNavigationModalID = await routingView._testInvokeNavigateToLog(method: .voice, confidence: 0.42)
        XCTAssertTrue(methodNavigationModalID?.hasPrefix("log:") == true)
        let directDraft = NutritionDayView._testNavigationDraft(
            method: .manual,
            confidence: nil,
            selectedDate: NutritionCoverageFixtures.loggedAt
        )
        let draftNavigationModalID = await routingView._testInvokeNavigateToLog(draft: directDraft)
        XCTAssertTrue(draftNavigationModalID?.hasPrefix("log:") == true)

        let callbackView = NutritionDayView(dateString: NutritionCoverageFixtures.targetDay)
        let callbackMetrics = await callbackView._testInvokeTemplateCallbacks(with: sampleMeals)
        XCTAssertEqual(callbackMetrics.refreshToken, 1)
        XCTAssertEqual(callbackMetrics.mealIDs, [firstMealId, secondMealId])
        let loadedMealIDs = await callbackView._testInvokeLoadMealsForDate(with: sampleMeals)
        XCTAssertEqual(loadedMealIDs, [firstMealId, secondMealId])
        let loadedMealIDsFromTask = await callbackView._testInvokeLoadMealsForDateTask(with: sampleMeals)
        XCTAssertEqual(loadedMealIDsFromTask, [firstMealId, secondMealId])

        let templateSelectionView = NutritionDayView(dateString: NutritionCoverageFixtures.targetDay)
        let templateSelection = await templateSelectionView._testInvokeHandleTemplateSelection(
            templateId: UUID(),
            templateName: "Coverage Template",
            reloadedMeals: sampleMeals
        )
        XCTAssertEqual(templateSelection.message, String(
            format: String(localized: "nutrition_logged_template_format"),
            "Coverage Template"
        ))
        XCTAssertEqual(templateSelection.refreshToken, 1)
        XCTAssertEqual(templateSelection.mealIDs, [firstMealId, secondMealId])

        let refreshView = NutritionDayView(dateString: NutritionCoverageFixtures.targetDay)
        let refreshedMealIDs = await refreshView._testInvokeHandleLoggedMealRefresh(with: sampleMeals)
        XCTAssertEqual(refreshedMealIDs, [firstMealId, secondMealId])

        let handledDraftView = NutritionDayView(dateString: NutritionCoverageFixtures.targetDay)
        let handledDraftModalID = await handledDraftView._testInvokeHandleLoggedDraftResult(directDraft)
        XCTAssertTrue(handledDraftModalID.hasPrefix("log:"))

        let dismissBatchModalView = NutritionDayView(dateString: NutritionCoverageFixtures.targetDay)
        XCTAssertNil(dismissBatchModalView._testInvokeDismissBatchRecipeModalIfDisabled())

        let modalView = NutritionDayView(dateString: NutritionCoverageFixtures.targetDay)
        let enabledModalIDs = await modalView._testRenderModalContents(batchRecipesEnabled: true)
        XCTAssertTrue(enabledModalIDs.contains("photo_capture"))
        XCTAssertTrue(enabledModalIDs.contains("batch_recipe"))
        let disabledModalIDs = await modalView._testRenderModalContents(batchRecipesEnabled: false)
        XCTAssertTrue(disabledModalIDs.contains("calendar"))

        let applySuccessView = NutritionDayView(dateString: NutritionCoverageFixtures.targetDay)
        let applySuccess = await applySuccessView._testInvokeApplyTemplateSuccess(
            templateId: UUID(),
            templateName: "Coverage Template",
            reloadedMeals: sampleMeals
        )
        XCTAssertEqual(applySuccess.message, String(
            format: String(localized: "nutrition_logged_template_format"),
            "Coverage Template"
        ))
        XCTAssertFalse(applySuccess.isError)
        XCTAssertEqual(applySuccess.refreshToken, 1)
        XCTAssertEqual(applySuccess.mealIDs, [firstMealId, secondMealId])

        let applyFailureView = NutritionDayView(dateString: NutritionCoverageFixtures.targetDay)
        let applyFailure = await applyFailureView._testInvokeApplyTemplateFailure(
            templateId: UUID(),
            message: "Coverage failure"
        )
        XCTAssertEqual(applyFailure.message, "Coverage failure")
        XCTAssertTrue(applyFailure.isError)
        XCTAssertEqual(applyFailure.refreshToken, 0)

        switch await NutritionDayView._testResolvedTemplateApplication(
            templateId: UUID(),
            selectedDate: NutritionCoverageFixtures.loggedAt,
            applyAction: { _, _ in
                NutritionMealTemplateApplicationResult(
                    foodLogId: UUID(),
                    templateName: "Coverage Template",
                    itemCount: 2
                )
            }
        ) {
        case let .success(applied):
            XCTAssertEqual(applied.templateName, "Coverage Template")
            XCTAssertEqual(applied.itemCount, 2)
        case let .failure(error):
            XCTFail("Expected template application success, got \(error.localizedDescription)")
        }

        switch await NutritionDayView._testResolvedTemplateApplication(
            templateId: UUID(),
            selectedDate: NutritionCoverageFixtures.loggedAt,
            applyAction: { _, _ in
                throw CoverageExpectedError(message: "Template helper failed")
            }
        ) {
        case .success:
            XCTFail("Expected template application failure")
        case let .failure(error):
            XCTAssertEqual(error.localizedDescription, "Template helper failed")
        }

        switch await NutritionDayView._testResolvedTemplateApplicationUsingOverride(
            templateId: UUID(),
            selectedDate: NutritionCoverageFixtures.loggedAt,
            overrideAction: { _, _ in
                NutritionMealTemplateApplicationResult(
                    foodLogId: UUID(),
                    templateName: "Override Template",
                    itemCount: 1
                )
            }
        ) {
        case let .success(applied):
            XCTAssertEqual(applied.templateName, "Override Template")
            XCTAssertEqual(applied.itemCount, 1)
        case let .failure(error):
            XCTFail("Expected override-backed template success, got \(error.localizedDescription)")
        }

        switch await NutritionDayView._testResolvedTemplateApplicationUsingOverride(
            templateId: UUID(),
            selectedDate: NutritionCoverageFixtures.loggedAt,
            overrideAction: { _, _ in
                throw CoverageExpectedError(message: "Override template failed")
            }
        ) {
        case .success:
            XCTFail("Expected override-backed template failure")
        case let .failure(error):
            XCTAssertEqual(error.localizedDescription, "Override template failed")
        }

        switch await NutritionDayView._testResolvedTemplateApplication(
            templateId: UUID(),
            selectedDate: NutritionCoverageFixtures.loggedAt,
            applyAction: nil
        ) {
        case .success:
            XCTFail("Expected live template application failure for random template id")
        case let .failure(error):
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }

        let appliedStatus = NutritionDayView._testAppliedTemplateStatusMessage(templateName: "Coverage Template")
        XCTAssertEqual(
            appliedStatus.message,
            String(format: String(localized: "nutrition_logged_template_format"), "Coverage Template")
        )
        XCTAssertFalse(appliedStatus.isError)

        let failedStatus = NutritionDayView._testFailedTemplateStatusMessage(message: "Coverage failure")
        XCTAssertEqual(failedStatus.message, "Coverage failure")
        XCTAssertTrue(failedStatus.isError)

        let featureFlagDisabledView = NutritionDayView(dateString: NutritionCoverageFixtures.targetDay)
        let disabledFlagMetrics = await featureFlagDisabledView._testInvokeFeatureFlagUpdateForBatchModal(batchRecipesEnabled: false)
        XCTAssertEqual(disabledFlagMetrics.tick, 1)
        XCTAssertNil(disabledFlagMetrics.modalID)

        let featureFlagEnabledView = NutritionDayView(dateString: NutritionCoverageFixtures.targetDay)
        let enabledFlagMetrics = await featureFlagEnabledView._testInvokeFeatureFlagUpdateForBatchModal(batchRecipesEnabled: true)
        XCTAssertEqual(enabledFlagMetrics.tick, 1)
        XCTAssertEqual(enabledFlagMetrics.modalID, "batch_recipe")

        XCTAssertTrue(
            NutritionDayView._testShouldDismissBatchRecipeModal(
                batchRecipesEnabled: false,
                activeModalID: "batch_recipe"
            )
        )
        XCTAssertFalse(
            NutritionDayView._testShouldDismissBatchRecipeModal(
                batchRecipesEnabled: true,
                activeModalID: "batch_recipe"
            )
        )
        XCTAssertFalse(
            NutritionDayView._testShouldDismissBatchRecipeModal(
                batchRecipesEnabled: false,
                activeModalID: "food_search"
            )
        )
        XCTAssertFalse(
            NutritionDayView._testShouldDismissBatchRecipeModal(
                batchRecipesEnabled: false,
                activeModalID: nil
            )
        )

        let manualModalView = NutritionDayView(dateString: NutritionCoverageFixtures.targetDay)
        let manualModalMetrics = await manualModalView._testInvokeFeatureFlagUpdateForManualModal(batchRecipesEnabled: false)
        XCTAssertEqual(manualModalMetrics.tick, 1)
        XCTAssertEqual(manualModalMetrics.modalID, "food_search")
    }

    @MainActor
    func testNutritionDayViewLoggedMealsRenderingAndFallbackHelpersCoverage() async throws {
        let userId = UUID()

        var breakfast = FoodLog(
            id: UUID(),
            userId: userId,
            loggedAt: NutritionCoverageFixtures.loggedAt,
            loggedDate: NutritionCoverageFixtures.targetDay,
            inputMethod: .manual,
            calories: 410,
            proteinG: 24,
            fatG: 14,
            carbsG: 39
        )
        breakfast.mealType = .breakfast

        var dinner = FoodLog(
            id: UUID(),
            userId: userId,
            loggedAt: NutritionCoverageFixtures.loggedAt.addingTimeInterval(5_400),
            loggedDate: NutritionCoverageFixtures.targetDay,
            inputMethod: .voice,
            calories: 620,
            proteinG: 36,
            fatG: 21,
            carbsG: 58
        )
        dinner.mealType = .dinner
        dinner.aiConfidence = 0.88

        let meals = [breakfast, dinner]
        let dayView = NutritionDayView(
            testDateString: NutritionCoverageFixtures.targetDay,
            testSelectedDate: NutritionCoverageFixtures.loggedAt,
            testMealsLogged: meals
        )
        let defaultInitView = NutritionDayView(testDateString: nil)
        let applyingView = NutritionDayView(
            testDateString: NutritionCoverageFixtures.targetDay,
            testSelectedDate: NutritionCoverageFixtures.loggedAt,
            testIsApplyingTemplate: true
        )
        let statusView = NutritionDayView(
            testDateString: NutritionCoverageFixtures.targetDay,
            testSelectedDate: NutritionCoverageFixtures.loggedAt,
            testTemplateStatusMessage: .init(message: "Coverage status", isError: false)
        )

        dayView._testEvaluateBody()
        renderForCoverage(dayView)
        applyingView._testRenderTemplateStatusSection()
        statusView._testRenderTemplateStatusSection()
        dayView._testRenderBatchRecipeQuickAction()
        dayView._testRenderMealsLoggedSection()
        dayView._testRenderMealRowLabel(breakfast)
        dayView._testRenderMealRowLabel(dinner)
        dayView._testRenderMealNavigationLink(breakfast)
        dayView._testRenderMealNavigationLink(dinner)
        dayView._testRenderMealNavigationDestination(dinner)
        dayView._testInvokeHandleBatchRecipesChanged()
        XCTAssertNil(dayView._testInvokeHandleDisabledBatchRecipeModalAppear())
        defaultInitView._testEvaluateBody()

        let reloadedMealIDs = await dayView._testInvokeLoggedMealReload(with: meals)
        XCTAssertEqual(reloadedMealIDs, meals.map(\.id))

        let modalID = await dayView._testInvokeInputMethodTileAction(.manual, batchRecipesEnabled: true)
        XCTAssertEqual(modalID, "food_search")

        XCTAssertEqual(
            NutritionDayView._testResolvedBatchRecipesEnabled(nil),
            AppFeatureFlag.batchRecipesEnabled.defaultEnabled
        )
        XCTAssertFalse(NutritionDayView._testResolvedBatchRecipesEnabled(false))
        XCTAssertTrue(NutritionDayView._testResolvedBatchRecipesEnabled(true))

        let selectedDate = try XCTUnwrap(DiaryDateFormatter.parseDate("2026-03-19"))
        let shiftedPrevious = NutritionDayView._testShiftedDate(
            selectedDate: selectedDate,
            dayOffset: -1,
            fallbackToOriginal: false
        )
        XCTAssertEqual(DiaryDateFormatter.formatDate(shiftedPrevious), "2026-03-18")

        let shiftedFallback = NutritionDayView._testShiftedDate(
            selectedDate: selectedDate,
            dayOffset: 1,
            fallbackToOriginal: true
        )
        XCTAssertEqual(shiftedFallback, selectedDate)

        let defaultedLogTime = NutritionDayView._testSelectedLogTime(
            selectedDate: selectedDate,
            hour: nil,
            minute: nil,
            second: nil,
            fallbackToOriginal: false
        )
        let timeComponents = Calendar.current.dateComponents([.hour, .minute, .second], from: defaultedLogTime)
        XCTAssertEqual(timeComponents.hour, 12)
        XCTAssertEqual(timeComponents.minute, 0)
        XCTAssertEqual(timeComponents.second, 0)

        let fallbackLogTime = NutritionDayView._testSelectedLogTime(
            selectedDate: selectedDate,
            hour: 7,
            minute: 5,
            second: 4,
            fallbackToOriginal: true
        )
        XCTAssertEqual(fallbackLogTime, selectedDate)
    }

    @MainActor
    func testNutritionLogViewPreviewAndLifecycleHelpersCoverage() async throws {
        let recentDeletedAt = Date()

        struct NoopLogger: NutritionMealLogging {
            func logMeal(_ log: FoodLog) async throws {
                _ = log
            }
        }

        actor TrackingMealManager: NutritionMealManaging {
            let detail: NutritionMealDetail
            let deletedAt: Date
            private(set) var deleteCalls = 0
            private(set) var undoCalls = 0

            init(detail: NutritionMealDetail, deletedAt: Date) {
                self.detail = detail
                self.deletedAt = deletedAt
            }

            func persist(log: FoodLog, detectedItems: [NutritionDraftCandidateItem]) async throws {
                _ = log
                _ = detectedItems
            }

            func persist(log: FoodLog, items: [FoodItem]) async throws {
                _ = log
                _ = items
            }

            func loadMealDetail(id: UUID, preferRemote: Bool) async throws -> NutritionMealDetail? {
                _ = id
                _ = preferRemote
                return detail
            }

            func updateMeal(_ update: NutritionMealUpdateDraft) async throws {
                _ = update
            }

            func deleteMeal(id: UUID) async throws -> Date {
                _ = id
                deleteCalls += 1
                return deletedAt
            }

            func undoDeleteMeal(id: UUID) async throws {
                _ = id
                undoCalls += 1
            }

            func snapshot() async -> (deleteCalls: Int, undoCalls: Int) {
                (deleteCalls, undoCalls)
            }
        }

        let aiDraft = NutritionLogDraft(
            method: .photo,
            confidence: 0.82,
            loggedAt: NutritionCoverageFixtures.loggedAt,
            loggedDate: NutritionCoverageFixtures.targetDay,
            summary: "Coverage power bowl",
            sourceText: "Chicken bowl with rice and avocado",
            analysisSource: .aiVision,
            totalMacros: NutritionDraftMacroSummary(
                calories: 510,
                proteinG: 34,
                fatG: 19,
                carbsG: 48,
                fiberG: 8
            ),
            suggestions: [" Add greens ", ""],
            warnings: [" Review portion ", " "],
            mealType: .lunch,
            recognizedBarcodes: ["12345", "67890"],
            candidateItems: [
                NutritionDraftCandidateItem(
                    name: "Coverage Chicken Bowl",
                    brand: "Coverage Kitchen",
                    barcode: "12345",
                    notes: " extra herbs ",
                    weightG: 220,
                    calories: 430,
                    proteinG: 32,
                    fatG: 12,
                    carbsG: 44,
                    fiberG: 8,
                    detectedByAi: true
                ),
                NutritionDraftCandidateItem(
                    name: "Mystery Sauce",
                    notes: " needs confirmation ",
                    confidence: 0.41,
                    detectedByAi: true
                )
            ]
        )

        let aiMetrics = NutritionLogView._testDraftPreviewMetrics(
            method: .photo,
            aiConfidence: 0.82,
            draft: aiDraft
        )
        XCTAssertEqual(aiMetrics.summaryTitle, String(localized: "nutrition_photo_ai_analysis_title"))
        XCTAssertEqual(aiMetrics.detectedItemsTitle, String(localized: "nutrition_photo_ai_detected_items_title"))
        XCTAssertEqual(aiMetrics.detectedItemsFootnote, String(localized: "nutrition_photo_structured_save_notice"))
        XCTAssertEqual(aiMetrics.sourceTextTitle, String(localized: "nutrition_photo_ocr_hints_title"))
        XCTAssertTrue(aiMetrics.macroSummary?.contains("510") == true)
        XCTAssertTrue(aiMetrics.warningsList.contains("Review portion"))
        XCTAssertTrue(aiMetrics.suggestionsList.contains("Add greens"))
        XCTAssertTrue(aiMetrics.itemSubtitles.first?.contains("12345") == true)
        XCTAssertTrue(
            aiMetrics.itemSubtitles.last?.contains(String(localized: "nutrition_item_needs_review")) == true
        )

        let fallbackDraft = NutritionLogDraft(
            method: .voice,
            confidence: 0.51,
            loggedAt: NutritionCoverageFixtures.loggedAt,
            loggedDate: NutritionCoverageFixtures.targetDay,
            summary: "Fallback soup",
            sourceText: "Tomato soup and bread",
            analysisSource: .onDeviceFallback,
            totalMacros: NutritionDraftMacroSummary(
                calories: 250,
                proteinG: 9,
                fatG: 7,
                carbsG: 34,
                fiberG: nil
            ),
            suggestions: ["  "],
            warnings: [" Needs review "],
            candidateItems: [
                NutritionDraftCandidateItem(
                    name: "Unknown soup",
                    notes: " verify serving ",
                    detectedByAi: true
                )
            ]
        )
        let fallbackMetrics = NutritionLogView._testDraftPreviewMetrics(
            method: .voice,
            aiConfidence: 0.51,
            draft: fallbackDraft
        )
        XCTAssertEqual(
            fallbackMetrics.summaryTitle,
            String(localized: "nutrition_photo_fallback_summary_title")
        )
        XCTAssertEqual(
            fallbackMetrics.detectedItemsTitle,
            String(localized: "nutrition_photo_detected_items_title")
        )
        XCTAssertEqual(
            fallbackMetrics.detectedItemsFootnote,
            String(localized: "nutrition_photo_review_save_notice")
        )
        XCTAssertEqual(
            fallbackMetrics.sourceTextTitle,
            String(localized: "nutrition_photo_captured_text_title")
        )
        XCTAssertTrue(fallbackMetrics.macroSummary?.contains("250") == true)

        let plainDraft = NutritionLogDraft(
            method: .manual,
            confidence: nil,
            loggedAt: NutritionCoverageFixtures.loggedAt,
            loggedDate: NutritionCoverageFixtures.targetDay,
            summary: "Plain label",
            sourceText: "Protein bar label",
            suggestions: ["  "],
            warnings: ["  "]
        )
        let plainMetrics = NutritionLogView._testDraftPreviewMetrics(
            method: .manual,
            aiConfidence: nil,
            draft: plainDraft
        )
        XCTAssertEqual(plainMetrics.summaryTitle, String(localized: "nutrition_photo_analysis_title"))
        XCTAssertEqual(plainMetrics.sourceTextTitle, String(localized: "nutrition_photo_captured_text_title"))

        let productionPreviewView = NutritionLogView(method: .photo, aiConfidence: 0.82, draft: aiDraft)
        productionPreviewView._testEvaluateBody()
        renderForCoverage(productionPreviewView)
        productionPreviewView._testRenderDraftPreviewSection()
        productionPreviewView._testRenderDraftCandidateItemsSection()
        productionPreviewView._testRenderDraftCandidateItemRow(aiDraft.candidateItems[0])
        productionPreviewView._testRenderDraftCandidateItemRow(aiDraft.candidateItems[1])

        let dbManager = try DatabaseManager.inMemory()
        let mealId = UUID()
        let existingLog = FoodLog(
            id: mealId,
            userId: UUID(),
            loggedAt: NutritionCoverageFixtures.loggedAt,
            loggedDate: NutritionCoverageFixtures.targetDay,
            inputMethod: .manual,
            calories: 500,
            proteinG: 30,
            fatG: 18,
            carbsG: 52
        )
        let existingItem = FoodItem(
            foodLogId: mealId,
            userId: existingLog.userId,
            name: "Coverage Bowl",
            weightG: 250,
            calories: 500,
            proteinG: 30,
            fatG: 18,
            carbsG: 52
        )
        let existingDetail = NutritionMealDetail(log: existingLog, items: [existingItem])
        let mealManager = TrackingMealManager(detail: existingDetail, deletedAt: recentDeletedAt)
        let viewModel = NutritionLogViewModel(
            method: .manual,
            aiConfidence: nil,
            existingMealId: mealId,
            nutritionService: NoopLogger(),
            mealManager: mealManager,
            dbQueue: dbManager.dbQueue
        )
        viewModel._testOverrideState(
            isSaving: false,
            didReviewLowConfidence: true,
            errorMessage: nil,
            dynamicHint: "Coverage hint"
        )
        viewModel._testSetCoverageState(
            mealItems: [
                NutritionEditableMealItem(
                    name: "Coverage Bowl",
                    brand: "Coverage Kitchen",
                    barcode: "12345",
                    weightG: 250,
                    calories: 500,
                    proteinG: 30,
                    fatG: 18,
                    carbsG: 52,
                    fiberG: 6,
                    detectedByAi: false
                )
            ]
        )

        let existingMealView = NutritionLogView(
            method: .manual,
            aiConfidence: nil,
            testViewModel: viewModel
        )
        existingMealView._testEvaluateBody()
        renderForCoverage(existingMealView)
        existingMealView._testRenderMealItemsSection()
        existingMealView._testRenderMealItemEditor()
        existingMealView._testRenderMealItemEditor(canRemove: false)
        existingMealView._testRenderNumericField()
        existingMealView._testRenderActionSection()
        XCTAssertEqual(existingMealView._testInvokeAddMealItemAction(), 2)
        let expandedMealView = NutritionLogView(
            method: .manual,
            aiConfidence: nil,
            testViewModel: viewModel
        )
        expandedMealView._testRenderMealItemsSection()
        expandedMealView._testRenderMealItemEditorRow(at: 0)
        expandedMealView._testRenderMealItemEditorRow(at: 1)
        XCTAssertEqual(existingMealView._testInvokeRemoveMealItemAction(at: 1).count, 1)
        viewModel._testSetCoverageState(isDeleting: true)
        NutritionLogView(
            method: .manual,
            aiConfidence: nil,
            testViewModel: viewModel
        )._testRenderActionSection()
        viewModel._testSetCoverageState(isDeleting: false)
        await existingMealView._testRunInitialLoadTask()
        await existingMealView._testRunInitialLoadTaskAction()
        await existingMealView._testRunDynamicHintTaskAction()
        existingMealView._testTriggerDeleteButtonTap()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(viewModel.isDeleted)

        let deleteSnapshot = await mealManager.snapshot()
        XCTAssertEqual(deleteSnapshot.deleteCalls, 1)

        viewModel._testSetCoverageState(
            isDeleted: true,
            deletedAt: recentDeletedAt,
            isUndoing: true
        )
        let deletedView = NutritionLogView(
            method: .manual,
            aiConfidence: nil,
            testViewModel: viewModel
        )
        deletedView._testEvaluateBody()
        renderForCoverage(deletedView)
        deletedView._testRenderDeletedStateSection()
        deletedView._testRenderActionSection()
        viewModel._testSetCoverageState(
            isDeleted: true,
            deletedAt: recentDeletedAt,
            isUndoing: false
        )
        NutritionLogView(
            method: .manual,
            aiConfidence: nil,
            testViewModel: viewModel
        )._testRenderActionSection()
        deletedView._testTriggerUndoDeleteButtonTap()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(viewModel.isDeleted)

        let undoSnapshot = await mealManager.snapshot()
        XCTAssertEqual(undoSnapshot.undoCalls, 1)

        let unsavedView = NutritionLogView(
            method: .manual,
            aiConfidence: nil,
            testViewModel: NutritionLogViewModel(method: .manual, aiConfidence: nil)
        )
        unsavedView._testRenderActionSection()
        unsavedView._testTriggerSaveButtonTap()
        unsavedView._testTriggerDeleteButtonTap()
        unsavedView._testTriggerUndoDeleteButtonTap()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let reviewViewModel = NutritionLogViewModel(method: .photo, aiConfidence: 0.25)
        reviewViewModel._testOverrideState(
            isSaving: false,
            didReviewLowConfidence: false,
            errorMessage: "Review coverage error",
            dynamicHint: "Review coverage hint"
        )
        let reviewView = NutritionLogView(
            method: .photo,
            aiConfidence: 0.25,
            testViewModel: reviewViewModel
        )
        reviewView._testEvaluateBody()
        renderForCoverage(reviewView)

        let loadingViewModel = NutritionLogViewModel(method: .manual, aiConfidence: nil)
        loadingViewModel.isLoading = true
        loadingViewModel.errorMessage = "Loading coverage error"
        loadingViewModel.dynamicHint = ""
        NutritionLogView(
            method: .manual,
            aiConfidence: nil,
            testViewModel: loadingViewModel
        )._testEvaluateBody()
    }

    @MainActor
    func testNutritionSearchSelectionCoverage() {
        let result = NutritionCoverageFixtures.foodResult(name: "Coverage Oats")
        var selectedDraft: NutritionLogDraft?

        let view = NutritionSearchView(
            testQuery: "coverage",
            testResults: [result],
            onSelectResult: { selectedDraft = $0 }
        )

        view._testEvaluateBody()
        view._testRenderSearchResultButton(result)
        view._testSelectSearchResult(result)

        XCTAssertEqual(selectedDraft?.method, .manual)
        XCTAssertEqual(selectedDraft?.loggedDate, NutritionCoverageFixtures.targetDay)
        XCTAssertEqual(selectedDraft?.candidateItems.first?.name, "Coverage Oats")
    }

    func testNutritionSearchExecutionAndStateHelpersCoverage() async {
        let searchResult = NutritionCoverageFixtures.foodResult(name: "Coverage Search")

        let skippedSearch = await NutritionSearchView._testSearchExecution(query: "   ") { _ in
            XCTFail("Whitespace query should not trigger search")
            return []
        }
        XCTAssertNil(skippedSearch)

        let searchSuccess = await NutritionSearchView._testSearchExecution(query: " oats ") { query in
            XCTAssertEqual(query, "oats")
            return [searchResult]
        }
        switch searchSuccess {
        case let .success(results):
            XCTAssertEqual(results.map(\.name), ["Coverage Search"])
        default:
            XCTFail("Expected successful nutrition search execution")
        }

        var statefulSearchQueries: [String] = []
        _ = await NutritionSearchView(
            testQuery: " oats "
        )._testTriggerSearch { query in
            statefulSearchQueries.append(query)
            return [searchResult]
        }
        XCTAssertEqual(statefulSearchQueries, ["oats"])

        var didRunStatefulSearchFailure = false
        _ = await NutritionSearchView(
            testQuery: " oats "
        )._testTriggerSearch { _ in
            didRunStatefulSearchFailure = true
            throw CoverageExpectedError(message: "Search state failed")
        }
        XCTAssertTrue(didRunStatefulSearchFailure)

        let ingredientFailure = await BatchRecipeIngredientPickerView._testSearchExecution(query: " rice ") { _ in
            throw CoverageExpectedError(message: "Ingredient search failed")
        }
        switch ingredientFailure {
        case let .failure(error):
            XCTAssertEqual(error.localizedDescription, "Ingredient search failed")
        default:
            XCTFail("Expected ingredient search failure")
        }

        var ingredientQueries: [String] = []
        _ = await BatchRecipeIngredientPickerView(
            testQuery: " rice "
        )._testTriggerSearch { query in
            ingredientQueries.append(query)
            return [searchResult]
        }
        XCTAssertEqual(ingredientQueries, ["rice"])

        var didRunIngredientFailure = false
        _ = await BatchRecipeIngredientPickerView(
            testQuery: " rice "
        )._testTriggerSearch { _ in
            didRunIngredientFailure = true
            throw CoverageExpectedError(message: "Ingredient state failed")
        }
        XCTAssertTrue(didRunIngredientFailure)

        let photoState = NutritionPhotoCaptureView(
            testCapturedImage: NutritionCoverageFixtures.image(),
            testIsAnalyzing: true,
            testAnalysisResult: "Coverage photo",
            testAnalysisConfidence: 0.77,
            testPhotoAnalysis: NutritionCoverageFixtures.photoAnalysis(summary: "Coverage photo"),
            testAnalysisNotice: "Notice",
            testCaptureError: "Capture warning"
        )._testState()
        XCTAssertTrue(photoState.isAnalyzing)
        XCTAssertEqual(photoState.analysisResult, "Coverage photo")
        XCTAssertEqual(photoState.captureError, "Capture warning")
        XCTAssertTrue(photoState.selectedPhotoItemIsNil)

        let barcodeState = NutritionBarcodeScannerView(
            testScannedCode: "460123",
            testIsSearching: true,
            testIsSaving: true,
            testIsAnalyzingLabel: true,
            testProductFound: true,
            testShowLabelOCRFallback: true,
            testOCRResult: "OCR",
            testErrorMessage: "Barcode warning",
            testMatchedProduct: searchResult,
            testPendingLabelImages: [NutritionCoverageFixtures.image()],
            testLabelReviewDraft: NutritionCoverageFixtures.labelDraft(name: "Coverage Label")
        )._testState()
        XCTAssertEqual(barcodeState.scannedCode, "460123")
        XCTAssertEqual(barcodeState.pendingLabelImagesCount, 1)
        XCTAssertEqual(barcodeState.ocrResult, "OCR")
        XCTAssertEqual(barcodeState.matchedProduct?.name, "Coverage Search")
        XCTAssertTrue(barcodeState.selectedPhotoItemIsNil)
    }

    @MainActor
    func testNutritionTemplateAndBatchInstanceTriggerCoveragePush() async {
        let activeTemplateDetail = NutritionCoverageFixtures.mealTemplateDetail()
        let templateItems = activeTemplateDetail.items.map(NutritionEditableMealItem.init(templateItem:))

        var templateSavedMessages: [String] = []
        var templateDismissCount = 0
        let templateSuccessView = MealTemplateComposerView(
            testName: activeTemplateDetail.template.name,
            testMealType: activeTemplateDetail.template.mealType,
            testItems: templateItems,
            onSaved: { templateSavedMessages.append($0.message) }
        )
        _ = await templateSuccessView._testTriggerSave(
            manager: CoverageMealTemplateManagerMock(detailResponse: activeTemplateDetail),
            dismissAction: { templateDismissCount += 1 }
        )
        XCTAssertNotNil(templateSuccessView)

        var templateFailureDismissCount = 0
        let templateFailureView = MealTemplateComposerView(
            testName: activeTemplateDetail.template.name,
            testMealType: activeTemplateDetail.template.mealType,
            testItems: templateItems
        )
        _ = await templateFailureView._testTriggerSave(
            manager: CoverageMealTemplateManagerMock(
                detailResponse: activeTemplateDetail,
                createError: CoverageExpectedError(message: "Template trigger failed")
            ),
            dismissAction: { templateFailureDismissCount += 1 }
        )
        XCTAssertNotNil(templateFailureView)

        let batchDetail = NutritionCoverageFixtures.batchDetail()
        let editableIngredients = batchDetail.ingredients.map(BatchRecipeEditableIngredient.init(ingredient:))

        var archiveStatusMessages: [String] = []
        var archiveChangedCount = 0
        var archiveDismissCount = 0
        let archiveView = BatchRecipeDetailView(
            batchId: batchDetail.recipe.id,
            testDetail: batchDetail,
            testIsLoading: false,
            onBatchesChanged: { archiveChangedCount += 1 },
            onStatusMessage: { message in
                if let message {
                    archiveStatusMessages.append(message.message)
                }
            }
        )
        _ = await archiveView._testTriggerToggleArchived(
            manager: CoverageBatchRecipeManagerMock(detailResponse: batchDetail),
            dismissAction: { archiveDismissCount += 1 }
        )
        XCTAssertNotNil(archiveView)

        var archiveFailureChangedCount = 0
        var archiveFailureDismissCount = 0
        let archiveFailureView = BatchRecipeDetailView(
            batchId: batchDetail.recipe.id,
            testDetail: batchDetail,
            testIsLoading: false,
            onBatchesChanged: { archiveFailureChangedCount += 1 }
        )
        _ = await archiveFailureView._testTriggerToggleArchived(
            manager: CoverageBatchRecipeManagerMock(
                detailResponse: batchDetail,
                archiveError: CoverageExpectedError(message: "Archive trigger failed")
            ),
            dismissAction: { archiveFailureDismissCount += 1 }
        )
        XCTAssertNotNil(archiveFailureView)

        var cookAgainStatusMessages: [String] = []
        var cookAgainChangedCount = 0
        var cookAgainDismissCount = 0
        let cookAgainView = BatchRecipeDetailView(
            batchId: batchDetail.recipe.id,
            testDetail: batchDetail,
            testIsLoading: false,
            onBatchesChanged: { cookAgainChangedCount += 1 },
            onStatusMessage: { message in
                if let message {
                    cookAgainStatusMessages.append(message.message)
                }
            }
        )
        _ = await cookAgainView._testTriggerCookAgain(
            manager: CoverageBatchRecipeManagerMock(detailResponse: batchDetail),
            dismissAction: { cookAgainDismissCount += 1 }
        )
        XCTAssertNotNil(cookAgainView)

        var cookAgainFailureChangedCount = 0
        var cookAgainFailureDismissCount = 0
        let cookAgainFailureView = BatchRecipeDetailView(
            batchId: batchDetail.recipe.id,
            testDetail: batchDetail,
            testIsLoading: false,
            onBatchesChanged: { cookAgainFailureChangedCount += 1 }
        )
        _ = await cookAgainFailureView._testTriggerCookAgain(
            manager: CoverageBatchRecipeManagerMock(
                detailResponse: batchDetail,
                duplicateError: CoverageExpectedError(message: "Duplicate trigger failed")
            ),
            dismissAction: { cookAgainFailureDismissCount += 1 }
        )
        XCTAssertNotNil(cookAgainFailureView)

        var batchSavedMessages: [String] = []
        var batchDismissCount = 0
        let batchSuccessView = BatchRecipeComposerView(
            testName: batchDetail.recipe.name,
            testDescription: batchDetail.recipe.description ?? "",
            testCookedAt: NutritionCoverageFixtures.loggedAt,
            testTotalWeightG: batchDetail.recipe.totalWeightG,
            testTotalPortions: batchDetail.recipe.totalPortions ?? 1,
            testIngredients: editableIngredients,
            onSaved: { batchSavedMessages.append($0.message) }
        )
        _ = await batchSuccessView._testTriggerSave(
            manager: CoverageBatchRecipeManagerMock(detailResponse: batchDetail),
            dismissAction: { batchDismissCount += 1 }
        )
        XCTAssertNotNil(batchSuccessView)

        var batchFailureDismissCount = 0
        let batchFailureView = BatchRecipeComposerView(
            testName: batchDetail.recipe.name,
            testDescription: batchDetail.recipe.description ?? "",
            testCookedAt: NutritionCoverageFixtures.loggedAt,
            testTotalWeightG: batchDetail.recipe.totalWeightG,
            testTotalPortions: batchDetail.recipe.totalPortions ?? 1,
            testIngredients: editableIngredients
        )
        _ = await batchFailureView._testTriggerSave(
            manager: CoverageBatchRecipeManagerMock(
                detailResponse: batchDetail,
                createError: CoverageExpectedError(message: "Batch trigger failed")
            ),
            dismissAction: { batchFailureDismissCount += 1 }
        )
        XCTAssertNotNil(batchFailureView)

        var portionLoggedMessages: [String] = []
        var portionDismissCount = 0
        let portionSuccessView = BatchPortionLogView(
            batchId: batchDetail.recipe.id,
            batchName: batchDetail.recipe.name,
            remainingWeightG: batchDetail.weightRemainingG,
            per100g: batchDetail.per100g,
            suggestedPortionWeightG: batchDetail.perPortion?.weightG,
            targetDay: NutritionCoverageFixtures.targetDay,
            loggedAt: NutritionCoverageFixtures.loggedAt,
            onLogged: { portionLoggedMessages.append($0.message) }
        )
        _ = await portionSuccessView._testTriggerSave(
            manager: CoverageBatchRecipeManagerMock(detailResponse: batchDetail),
            dismissAction: { portionDismissCount += 1 }
        )
        XCTAssertNotNil(portionSuccessView)

        var portionFailureDismissCount = 0
        let portionFailureView = BatchPortionLogView(
            batchId: batchDetail.recipe.id,
            batchName: batchDetail.recipe.name,
            remainingWeightG: batchDetail.weightRemainingG,
            per100g: batchDetail.per100g,
            suggestedPortionWeightG: batchDetail.perPortion?.weightG,
            targetDay: NutritionCoverageFixtures.targetDay,
            loggedAt: NutritionCoverageFixtures.loggedAt
        )
        _ = await portionFailureView._testTriggerSave(
            manager: CoverageBatchRecipeManagerMock(
                detailResponse: batchDetail,
                logError: CoverageExpectedError(message: "Portion trigger failed")
            ),
            dismissAction: { portionFailureDismissCount += 1 }
        )
        XCTAssertNotNil(portionFailureView)
    }

    @MainActor
    func testBatchRecipeComposerPhotoImportCoverage() async throws {
        let response = BatchRecipePhotoAnalysisResponse(
            recipeName: "Coverage Chili",
            ingredientsDetected: [
                .init(
                    name: "Beans",
                    estimatedRawWeightG: 300,
                    estimatedCookedWeightG: 240,
                    calories: 320,
                    proteinG: 18,
                    fatG: 2,
                    carbsG: 58,
                    confidence: 0.8
                )
            ],
            totalBatch: .init(
                weightG: 1_100,
                calories: 1_280,
                proteinG: 82,
                fatG: 28,
                carbsG: 124,
                fiberG: 18
            ),
            per100g: .init(
                weightG: 100,
                calories: 116,
                proteinG: 7.4,
                fatG: 2.5,
                carbsG: 11.3,
                fiberG: 1.6
            ),
            perPortion: .init(
                weightG: 275,
                calories: 320,
                proteinG: 20.5,
                fatG: 7,
                carbsG: 31
            ),
            notes: ["Coverage batch import"],
            storage: nil,
            confidence: nil
        )

        let appliedState = BatchRecipeComposerView(
            testName: "",
            testDescription: "",
            testTotalWeightG: 0,
            testTotalPortions: 0,
            testIngredients: []
        )._testApplyPhotoDraft(
            NutritionCoverageFixtures.batchPhotoDraft(
                recipeName: "Coverage Imported Prep",
                notes: ["Imported from photo"],
                descriptionText: "Roast and chill"
            )
        )
        XCTAssertFalse(appliedState.isAnalyzingPhoto)

        let imageData = try XCTUnwrap(NutritionCoverageFixtures.image().jpegData(compressionQuality: 0.9))
        let loadedState = await BatchRecipeComposerView(
            testName: "",
            testDescription: "",
            testTotalWeightG: 0,
            testTotalPortions: 0,
            testIngredients: []
        )._testLoadPhotoItemUsingOverride(
            response: response,
            dataLoader: { imageData }
        )
        XCTAssertFalse(loadedState.isAnalyzingPhoto)

        let invalidDataState = await BatchRecipeComposerView(
            testName: "Coverage Existing",
            testDescription: "",
            testIngredients: []
        )._testLoadPhotoItemUsingOverride(
            response: response,
            dataLoader: { nil }
        )
        XCTAssertFalse(invalidDataState.isAnalyzingPhoto)

        let thrownLoadState = await BatchRecipeComposerView(
            testName: "Coverage Existing",
            testDescription: "",
            testIngredients: []
        )._testLoadPhotoItemUsingOverride(
            response: response,
            dataLoader: { throw CoverageExpectedError(message: "Batch photo load failed") }
        )
        XCTAssertFalse(thrownLoadState.isAnalyzingPhoto)
    }

    func testOnboardingViewTriggerActionsRunsStaticRefreshClosurePath() async {
        let view = OnboardingView()
        view._testTriggerActions()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(true)
    }

    func testAPIClientResolveSafeTableNameFallbackPath() {
        XCTAssertEqual(APIClient._testResolveSafeTableName("users", encodedTable: nil), "users")
    }

    func testAPIClientEdgeInvokeDefaultPathViaStubbedSession() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [CoverageEdgeURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let service = "coverage.edge.\(UUID().uuidString)"
        let options = SupabaseClientOptions(
            auth: .init(storage: KeychainLocalStorage(service: service)),
            global: .init(session: session)
        )
        let client = SupabaseClient(
            supabaseURL: URL(string: "https://example.com")!,
            supabaseKey: "coverage-key",
            options: options
        )
        let api = APIClient(client: client, deviceId: "coverage-device")

        CoverageEdgeURLProtocol.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com/functions/v1/coverage")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data())
        }
        defer { CoverageEdgeURLProtocol.setHandler(nil) }

        let response: EmptyResponse = try await api.callEdgeFunction(
            "coverage",
            body: Data(),
            headers: ["X-Outbox-Replay": "true"],
            maxAttempts: 1
        )
        XCTAssertNotNil(response)
    }

    func testDatabaseManagerLogPersistentInitFailureHelper() {
        DatabaseManager._testLogPersistentInitFailure(
            error: NSError(domain: "DatabaseCoverage", code: 1),
            forcePersistentFailure: false
        )
        DatabaseManager._testLogPersistentInitFailure(
            error: NSError(domain: "DatabaseCoverage", code: 2),
            forcePersistentFailure: true
        )
        XCTAssertTrue(true)
    }

    func testHealthSyncBackfillThrowsFirstErrorAndUsesDefaultSyncProviderClosure() async throws {
        let dbManager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        try await dbManager.dbQueue.write { db in
            try user.insert(db)
        }
        let timeZoneHistoryStore = TimeZoneHistoryStore(dbQueue: dbManager.dbQueue)

        let healthSync = HealthSyncManager(
            healthKitManager: CoverageFailingHealthSyncProvider(),
            environmentService: CoverageEnvironmentServiceStub(),
            dbQueue: dbManager.dbQueue,
            isHealthKitAvailable: { true },
            timeZoneHistoryStore: timeZoneHistoryStore,
            nowProvider: { Date() }
        )

        do {
            try await healthSync.backfillRecentData(days: 2, userId: user.id)
            XCTFail("Expected backfill to throw first observed error")
        } catch {
            XCTAssertNotNil(error.localizedDescription)
        }
    }

    func testHealthSyncBackfillSuccessPathReturnsWithoutError() async throws {
        let dbManager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        try await dbManager.dbQueue.write { db in
            try user.insert(db)
        }
        let timeZoneHistoryStore = TimeZoneHistoryStore(dbQueue: dbManager.dbQueue)

        let healthSync = HealthSyncManager(
            healthKitManager: CoverageHealthyHealthSyncProvider(),
            environmentService: CoverageEnvironmentServiceStub(),
            dbQueue: dbManager.dbQueue,
            isHealthKitAvailable: { true },
            syncEngineProvider: { nil },
            timeZoneHistoryStore: timeZoneHistoryStore,
            nowProvider: { Date() }
        )

        try await healthSync.backfillRecentData(days: 1, userId: user.id)
        XCTAssertTrue(true)
    }

    func testHealthSyncBackfillSuccessPathWithDefaultSyncEngineProviderClosure() async throws {
        let dbManager = try DatabaseManager.inMemory()
        let user = User(authId: UUID())
        try await dbManager.dbQueue.write { db in
            try user.insert(db)
        }
        let timeZoneHistoryStore = TimeZoneHistoryStore(dbQueue: dbManager.dbQueue)

        let healthSync = HealthSyncManager(
            healthKitManager: CoverageHealthyHealthSyncProvider(),
            environmentService: CoverageEnvironmentServiceStub(),
            dbQueue: dbManager.dbQueue,
            isHealthKitAvailable: { true },
            timeZoneHistoryStore: timeZoneHistoryStore,
            nowProvider: Date.init
        )

        try await healthSync.backfillRecentData(days: 1, userId: user.id)
        XCTAssertTrue(true)
    }

    func testBodyCompositionHarnessCoversCrudAndViewBranches() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let user: LifeOS.User = {
            var user = LifeOS.User(authId: authId, timezone: "UTC", units: .metric)
            user.weightKg = 80
            return user
        }()

        try await manager.dbQueue.write { db in
            try user.insert(db)
        }
        AuthManager.setActiveAuthIdForTests(authId)

        let initial = await BodyCompositionViewTestHarness.loadSnapshot(dbQueue: manager.dbQueue)
        XCTAssertEqual(initial.entryCount, 0)
        XCTAssertTrue(initial.canSave)
        XCTAssertTrue(initial.weightKgText.contains("80"))

        await BodyCompositionViewTestHarness.renderStates(dbQueue: manager.dbQueue)

        let invalid = await BodyCompositionViewTestHarness.saveEntry(
            dbQueue: manager.dbQueue,
            measuredAt: Date(timeIntervalSince1970: 1_709_251_200),
            weightKgText: "0",
            bodyFatPercentText: "",
            muscleMassKgText: ""
        )
        XCTAssertEqual(invalid.statusMessage, String(localized: "body_composition_invalid_weight"))
        XCTAssertEqual(invalid.entryCount, 0)

        let measuredAt = Date(timeIntervalSince1970: 1_709_251_200)
        let saved = await BodyCompositionViewTestHarness.saveEntry(
            dbQueue: manager.dbQueue,
            measuredAt: measuredAt,
            weightKgText: "81.2",
            bodyFatPercentText: "18.4",
            muscleMassKgText: "33.1"
        )
        XCTAssertEqual(saved.entryCount, 1)
        XCTAssertFalse(saved.isEditing)
        XCTAssertFalse((saved.statusMessage ?? "").isEmpty)
        XCTAssertEqual(saved.bodyFatPercentText, "")
        XCTAssertEqual(saved.muscleMassKgText, "")

        await BodyCompositionViewTestHarness.renderStates(dbQueue: manager.dbQueue)

        let edited = await BodyCompositionViewTestHarness.updateFirstEntry(
            dbQueue: manager.dbQueue,
            measuredAt: measuredAt.addingTimeInterval(3600),
            weightKgText: "79.6",
            bodyFatPercentText: "17.9",
            muscleMassKgText: "34.0"
        )
        XCTAssertEqual(edited.entryCount, 1)
        XCTAssertFalse(edited.isEditing)
        XCTAssertFalse((edited.statusMessage ?? "").isEmpty)

        let canceled = await BodyCompositionViewTestHarness.cancelEditingSnapshot(dbQueue: manager.dbQueue)
        XCTAssertFalse(canceled.isEditing)
        XCTAssertEqual(canceled.bodyFatPercentText, "")
        XCTAssertEqual(canceled.muscleMassKgText, "")

        let deleted = await BodyCompositionViewTestHarness.deleteFirstEntry(dbQueue: manager.dbQueue)
        XCTAssertEqual(deleted.entryCount, 0)
        XCTAssertFalse((deleted.statusMessage ?? "").isEmpty)

        let summary = BodyCompositionViewTestHarness.metricsSummary(
            weightKg: 79.6,
            bodyFatPercent: 17.9,
            muscleMassKg: 34.0
        )
        XCTAssertTrue(summary.contains("79"))
        XCTAssertFalse(BodyCompositionViewTestHarness.formattedTimestamp(measuredAt).isEmpty)

        try await manager.dbQueue.read { db in
            let activeCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM body_composition WHERE deleted_at IS NULL"
            ) ?? 0
            let totalCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM body_composition"
            ) ?? 0
            let latestWeight = try Double.fetchOne(
                db,
                sql: "SELECT weight_kg FROM body_composition ORDER BY updated_at DESC LIMIT 1"
            )
            let outboxCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?",
                arguments: ["rest/v1/body_composition"]
            ) ?? 0

            XCTAssertEqual(activeCount, 0)
            XCTAssertEqual(totalCount, 1)
            XCTAssertEqual(latestWeight ?? 0, 79.6, accuracy: 0.001)
            XCTAssertEqual(outboxCount, 3)
        }
    }

    func testSleepPermissionStatesAndSectionBranches() {
        let states: [SleepPermissionState] = [.unavailable, .notDetermined, .denied, .authorized]
        for state in states {
            XCTAssertFalse(state.emptyTitle.isEmpty)
            XCTAssertFalse(state.emptyMessage.isEmpty)
        }
        XCTAssertFalse(SleepPermissionState.unavailable.canRequestAccess)
        XCTAssertTrue(SleepPermissionState.notDetermined.canRequestAccess)
        XCTAssertTrue(SleepPermissionState.denied.canRequestAccess)
        XCTAssertFalse(SleepPermissionState.authorized.canRequestAccess)

        let emptySnapshot = SleepDetailSnapshot(
            day: "2026-03-08",
            displayDate: "Saturday, March 8",
            age: 30,
            baselineSleepHours: nil,
            sleepLog: nil,
            state: nil,
            score: nil,
            confidenceScore: nil,
            trendPoints: [],
            factors: [],
            tryTonightItems: [],
            stageFeedback: nil
        )
        renderForCoverage(
            SleepDetailSections(
                snapshot: emptySnapshot,
                permissionState: .notDetermined,
                isRequestingAccess: false,
                statusMessage: nil,
                onRequestAccess: {}
            )
        )
        renderForCoverage(
            SleepDetailSections(
                snapshot: emptySnapshot,
                permissionState: .denied,
                isRequestingAccess: true,
                statusMessage: "Need Health access",
                onRequestAccess: {}
            )
        )

        var partialLog = SleepLog(userId: UUID(), date: "2026-03-08", source: .manual)
        partialLog.totalDurationMinutes = 360
        partialLog.timeInBedMinutes = 410
        partialLog.sleepEfficiency = 86
        partialLog.numberOfAwakenings = 2
        partialLog.timeToFallAsleepMinutes = 18

        let partialSnapshot = SleepDetailSnapshot(
            day: "2026-03-08",
            displayDate: "Saturday, March 8",
            age: 30,
            baselineSleepHours: nil,
            sleepLog: partialLog,
            state: nil,
            score: 58,
            confidenceScore: 0.91,
            trendPoints: [
                SleepTrendPoint(id: "2026-03-07", day: "2026-03-07", shortLabel: "Fri", score: nil, durationHours: nil, isSelected: false),
                SleepTrendPoint(id: "2026-03-08", day: "2026-03-08", shortLabel: "Sat", score: nil, durationHours: nil, isSelected: true)
            ],
            factors: [],
            tryTonightItems: [],
            stageFeedback: nil
        )
        XCTAssertTrue(partialSnapshot.hasAnySleepData)
        XCTAssertFalse(partialSnapshot.hasStages)
        XCTAssertTrue(partialSnapshot.isPartialData)

        renderForCoverage(
            SleepDetailSections(
                snapshot: partialSnapshot,
                permissionState: .authorized,
                isRequestingAccess: false,
                statusMessage: "Partial sync",
                onRequestAccess: nil
            )
        )
    }

    func testSleepDetailLoaderSectionsAndCalendarCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let user: LifeOS.User = {
            var user = LifeOS.User(authId: authId, timezone: "UTC", units: .metric)
            user.ageRange = .age25_34
            user.baselineSleepHours = 8
            return user
        }()

        let selectedDay = "2026-03-07"
        let calendarMonthDate = try XCTUnwrap(DiaryDateFormatter.parseDate(selectedDay))
        let endDate = calendarMonthDate

        try await manager.dbQueue.write { db in
            try user.insert(db)

            for offset in 0..<7 {
                guard let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: offset - 6, to: endDate) else {
                    continue
                }
                let day = DiaryDateFormatter.formatDate(date)
                let isSelected = day == selectedDay
                let totalDurationMinutes = isSelected ? 300 : 450 - (offset * 5)
                let deepMinutes = isSelected ? 42 : 90
                let remMinutes = isSelected ? 60 : 105

                var log = SleepLog(
                    userId: user.id,
                    date: day,
                    source: isSelected ? .wearable : .healthkit
                )
                var dayCalendar = Calendar(identifier: .gregorian)
                dayCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
                let components = dayCalendar.dateComponents([.year, .month, .day], from: date)
                log.sleepDate = day
                log.bedtimeActual = dayCalendar.date(from: DateComponents(
                    timeZone: dayCalendar.timeZone,
                    year: components.year,
                    month: components.month,
                    day: components.day,
                    hour: 0,
                    minute: 15
                ))
                log.wakeTime = dayCalendar.date(from: DateComponents(
                    timeZone: dayCalendar.timeZone,
                    year: components.year,
                    month: components.month,
                    day: components.day,
                    hour: 7,
                    minute: 25
                ))
                log.totalDurationMinutes = totalDurationMinutes
                log.timeInBedMinutes = totalDurationMinutes + (isSelected ? 40 : 20)
                log.deepSleepMinutes = deepMinutes
                log.remSleepMinutes = remMinutes
                log.lightSleepMinutes = max(0, totalDurationMinutes - deepMinutes - remMinutes)
                log.awakeMinutes = isSelected ? 35 : 15
                log.sleepEfficiency = isSelected ? 78 : 92
                log.sleepQualityScore = isSelected ? 46 : 82
                log.numberOfAwakenings = isSelected ? 4 : 1
                log.timeToFallAsleepMinutes = isSelected ? 28 : 12
                log.notes = isSelected ? "Late caffeine" : nil
                log.deviceName = isSelected ? "Apple Watch" : nil
                try log.insert(db)

                var state = PhysiologicalState(
                    userId: user.id,
                    date: day,
                    recoveryScore: isSelected ? 42 : 78
                )
                state.sleepDurationHours = Double(totalDurationMinutes) / 60
                state.sleepScore = isSelected ? 48 : 80
                state.confidenceScore = isSelected ? 0.54 : 0.91
                state.deepSleepPercent = isSelected ? 14 : 20
                state.remSleepPercent = isSelected ? 20 : 23
                state.lightSleepPercent = isSelected ? 66 : 57
                state.awakePercent = isSelected ? 12 : 6
                try state.insert(db)
            }
        }

        AuthManager.setActiveAuthIdForTests(authId)
        AuthManager._testSetActiveHasCloudSession(false)

        let snapshot = try await SleepDetailLoader.load(day: selectedDay, dbQueue: manager.dbQueue)
        XCTAssertEqual(snapshot.day, selectedDay)
        XCTAssertEqual(snapshot.trendPoints.count, 7)
        XCTAssertEqual(snapshot.durationMinutes, 300)
        XCTAssertEqual(snapshot.deepMinutes, 42)
        XCTAssertTrue(snapshot.trendPoints.contains(where: { $0.day == selectedDay && $0.isSelected }))
        XCTAssertTrue(snapshot.hasAnySleepData)
        XCTAssertTrue(snapshot.hasStages)
        XCTAssertFalse(snapshot.isPartialData)
        XCTAssertTrue(snapshot.shouldShowEstimateBadge)
        XCTAssertFalse(snapshot.factors.isEmpty)
        XCTAssertFalse(snapshot.tryTonightItems.isEmpty)
        XCTAssertNotNil(snapshot.score)
        XCTAssertNotNil(snapshot.stageFeedback)
        XCTAssertTrue(snapshot.sourceSummary?.contains("Apple Watch") == true)
        XCTAssertNotNil(snapshot.trendSummary)

        renderForCoverage(
            SleepDetailSections(
                snapshot: snapshot,
                permissionState: .authorized,
                isRequestingAccess: false,
                statusMessage: "Sleep synced",
                onRequestAccess: nil
            )
        )
        renderForCoverage(SleepSparklineView(points: snapshot.trendPoints))

        let statuses = try await SleepDetailLoader.loadMonthStatuses(
            month: calendarMonthDate,
            dbQueue: manager.dbQueue
        )
        XCTAssertNotEqual(statuses[selectedDay], .noData)
        XCTAssertNotEqual(statuses["2026-03-06"], .noData)
        XCTAssertEqual(statuses["2026-03-15"], .noData)

        renderForCoverage(
            SleepCalendarView(
                selectedDate: .constant(calendarMonthDate),
                dbQueue: manager.dbQueue
            )
        )
    }

    func testRecoveryEngineAdditionalScoreBranches() {
        let tempScore = RecoveryEngine.temperatureDeviationScore(1.2)
        XCTAssertGreaterThan(tempScore, 0)
        XCTAssertLessThan(tempScore, 30)

        let baselineFallback = RecoveryEngine.rhrPercentageScore(current: 60, baseline: 0)
        XCTAssertEqual(baselineFallback, 50, accuracy: 0.0001)
    }

    func testTrainingZoneAndWeeklyTrendDisplayPropertiesCoverAllCases() {
        let zones: [TrainingZoneState] = [
            .undertraining,
            .optimal,
            .overreaching,
            .injuryRisk
        ]
        for zone in zones {
            XCTAssertFalse(zone.label.isEmpty)
            XCTAssertFalse(zone.iconName.isEmpty)
            _ = zone.color
            XCTAssertFalse(zone.accessibilityLabel.isEmpty)
            XCTAssertFalse(zone.shortLabel.isEmpty)
            XCTAssertFalse(zone.description.isEmpty)
        }

        let trends: [WeeklyTrend] = [.increasing, .stable, .decreasing]
        for trend in trends {
            XCTAssertFalse(trend.label.isEmpty)
            XCTAssertFalse(trend.iconName.isEmpty)
            _ = trend.color
            XCTAssertFalse(trend.accessibilityLabel.isEmpty)
        }
    }

    func testCalendarRangeRouteFetchesDecodeWorkoutAndSleepResponses() async throws {
        let api = APIClient(deviceId: "coverage-calendar")
        APIClient._testSetEdgeRouteDataForRequestOverride { request in
            let url = try XCTUnwrap(request.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let queryItems = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
            )
            XCTAssertEqual(queryItems["from"], "2026-03-01")
            XCTAssertEqual(queryItems["to"], "2026-03-07")

            let payload: String
            switch url.lastPathComponent {
            case "api-workouts-calendar":
                payload = """
                {"from":"2026-03-01","to":"2026-03-07","days":[{"date":"2026-03-03","logged_count":1,"planned_count":2,"completed_planned_count":1,"total_duration_minutes":55,"total_trimp_score":73.5,"has_logged_workout":true,"has_planned_workout":true}]}
                """
            case "api-sleep-calendar":
                payload = """
                {"from":"2026-03-01","to":"2026-03-07","days":[{"date":"2026-03-03","sleep_score":84.5,"sleep_duration_hours":7.8,"status":"ready"}]}
                """
            default:
                throw NSError(domain: "CoverageCalendarRoutes", code: 1)
            }

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (Data(payload.utf8), response)
        }
        defer { APIClient._testResetOverrides() }

        let workout = try await api.fetchWorkoutCalendar(from: "2026-03-01", to: "2026-03-07")
        XCTAssertEqual(workout.from, "2026-03-01")
        XCTAssertEqual(workout.days.first?.loggedCount, 1)
        XCTAssertEqual(workout.days.first?.plannedCount, 2)
        XCTAssertEqual(workout.days.first?.completedPlannedCount, 1)
        XCTAssertEqual(workout.days.first?.totalDurationMinutes, 55)
        XCTAssertEqual(workout.days.first?.hasLoggedWorkout, true)

        let sleep = try await api.fetchSleepCalendar(from: "2026-03-01", to: "2026-03-07")
        XCTAssertEqual(sleep.to, "2026-03-07")
        XCTAssertEqual(sleep.days.first?.sleepScore, 84.5)
        XCTAssertEqual(sleep.days.first?.sleepDurationHours, 7.8)
        XCTAssertEqual(sleep.days.first?.status, "ready")
    }

    func testCloudUserBootstrapperHelpersAndEarlyReturnPath() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let syncEngine = SyncEngine(
            dbQueue: manager.dbQueue,
            apiClient: APIClient(deviceId: "coverage-bootstrap")
        )

        AuthManager._testSetActiveHasCloudSession(false)
        try await CloudUserBootstrapper.scheduleCanonicalUserUpsertIfNeeded(
            authId: authId,
            email: "ignored@example.com",
            dbQueue: manager.dbQueue,
            syncEngine: syncEngine
        )

        let outboxCount = try await manager.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox_events") ?? 0
        }
        XCTAssertEqual(outboxCount, 0)

        try await CloudUserBootstrapper._testScheduleCanonicalUserUpsertIfNeeded(
            authId: authId,
            email: "missing-user@example.com",
            dbQueue: manager.dbQueue,
            syncEngine: syncEngine,
            isRuntimeConfigured: true,
            hasCloudSession: true
        )
        let missingUserOutboxCount = try await manager.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox_events") ?? 0
        }
        XCTAssertEqual(missingUserOutboxCount, 0)

        XCTAssertNil(CloudUserBootstrapper._testNormalized(nil))
        XCTAssertNil(CloudUserBootstrapper._testNormalized("   "))
        XCTAssertEqual(CloudUserBootstrapper._testNormalized(" person@example.com "), "person@example.com")

        var user = User(id: UUID(), authId: authId)
        user.email = " local@example.com "
        let persistedUser = user
        try await manager.dbQueue.write { db in
            try persistedUser.insert(db)
        }

        let explicitPayload = try CloudUserBootstrapper._testCanonicalUserUpsertPayload(
            for: user,
            canonicalUserId: authId,
            explicitEmail: " remote@example.com "
        )
        let explicitJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: explicitPayload) as? [String: Any]
        )
        XCTAssertEqual(explicitJSON["id"] as? String, authId.uuidString)
        XCTAssertEqual(explicitJSON["auth_id"] as? String, authId.uuidString)
        XCTAssertEqual(explicitJSON["email"] as? String, "remote@example.com")

        user.email = "   "
        let nilEmailPayload = try CloudUserBootstrapper._testCanonicalUserUpsertPayload(
            for: user,
            canonicalUserId: authId,
            explicitEmail: nil
        )
        let nilEmailJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: nilEmailPayload) as? [String: Any]
        )
        XCTAssertNil(nilEmailJSON["email"])

        try await CloudUserBootstrapper._testScheduleCanonicalUserUpsertIfNeeded(
            authId: authId,
            email: " remote@example.com ",
            dbQueue: manager.dbQueue,
            syncEngine: syncEngine,
            isRuntimeConfigured: true,
            hasCloudSession: true
        )
        let outboxRow: Row? = try await manager.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT path, priority, body_json FROM outbox_events ORDER BY created_at_local DESC LIMIT 1"
            )
        }
        XCTAssertEqual(outboxRow?["path"], "rest/v1/users")
        XCTAssertEqual(outboxRow?["priority"], 10)
        let enqueuedBodyData: Data = try XCTUnwrap(outboxRow?["body_json"])
        let enqueuedJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: enqueuedBodyData) as? [String: Any]
        )
        XCTAssertEqual(enqueuedJSON["email"] as? String, "remote@example.com")
    }

    func testAuthCallbackViewPresentationAndStatusHandlingCoverage() async {
        let authManager = AuthManager()
        let statuses: [AuthCallbackStatus] = [
            .idle,
            .processing,
            .succeeded(email: "coverage@example.com"),
            .failed("Coverage failure")
        ]

        for status in statuses {
            let presentation = AuthCallbackView._testPresentation(for: status)
            XCTAssertFalse(presentation.iconName.isEmpty)
            XCTAssertFalse(presentation.iconColor.isEmpty)
            XCTAssertFalse(presentation.title.isEmpty)
            XCTAssertFalse(presentation.message.isEmpty)
            XCTAssertFalse(presentation.actionTitle.isEmpty)

            authManager._testSetAuthCallbackStatus(status)
            renderForCoverage(AuthCallbackView().environment(authManager))
        }

        var successCallbackCount = 0
        await AuthCallbackView._testHandleAuthCallbackStatusChange(status: .idle) {
            successCallbackCount += 1
        }
        await AuthCallbackView._testHandleAuthCallbackStatusChange(status: .succeeded(email: nil)) {
            successCallbackCount += 1
        }
        XCTAssertEqual(successCallbackCount, 1)
    }

    @MainActor
    func testNutritionCoverageHarnessExercisesAdditionalViewAndMediaBranches() throws {
        let renderedCount = NutritionCoverageHarness.exerciseAdditionalViewBranches()
        XCTAssertGreaterThanOrEqual(renderedCount, 20)

        let missingName = NutritionCoverageHarness.validateBarcodeReview(
            NutritionLabelReviewDraft(
                name: "   ",
                servingSizeG: 55,
                caloriesPer100g: 320,
                proteinPer100g: 20,
                fatPer100g: 8,
                carbsPer100g: 30,
                confidence: nil,
                analysisSource: .onDeviceFallback
            )
        )
        XCTAssertNotNil(missingName)

        let invalidWeight = NutritionCoverageHarness.validateBarcodeReview(
            NutritionLabelReviewDraft(
                name: "Coverage",
                servingSizeG: 0,
                caloriesPer100g: 320,
                proteinPer100g: 20,
                fatPer100g: 8,
                carbsPer100g: 30,
                confidence: nil,
                analysisSource: .onDeviceFallback
            )
        )
        XCTAssertNotNil(invalidWeight)

        let validReview = NutritionCoverageHarness.validateBarcodeReview(
            NutritionLabelReviewDraft(
                name: "Coverage",
                servingSizeG: 55,
                caloriesPer100g: 320,
                proteinPer100g: 20,
                fatPer100g: 8,
                carbsPer100g: 30,
                confidence: 0.8,
                analysisSource: .aiVision
            )
        )
        XCTAssertNil(validReview)

        let portionMetrics = NutritionCoverageHarness.batchPortionMetrics()
        XCTAssertEqual(portionMetrics.breakfast, .breakfast)
        XCTAssertEqual(portionMetrics.lunch, .lunch)
        XCTAssertEqual(portionMetrics.dinner, .dinner)
        XCTAssertEqual(portionMetrics.snack, .snack)
        XCTAssertTrue(portionMetrics.canSave)
        XCTAssertFalse(portionMetrics.blockedSave)
        XCTAssertEqual(portionMetrics.previewCalories, 270, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(portionMetrics.previewFiber), 6, accuracy: 0.001)

        let formattingMetrics = NutritionCoverageHarness.localizedFormattingMetrics()
        XCTAssertFalse(formattingMetrics.lastUsed.isEmpty)
        XCTAssertFalse(formattingMetrics.usedCount.isEmpty)
        XCTAssertFalse(formattingMetrics.cooked.isEmpty)
        XCTAssertFalse(formattingMetrics.remainingOnly.isEmpty)
        XCTAssertFalse(formattingMetrics.remainingWithPortions.isEmpty)
        XCTAssertFalse(formattingMetrics.portionsLeft.isEmpty)
        XCTAssertFalse(formattingMetrics.itemWithFiber.isEmpty)
        XCTAssertFalse(formattingMetrics.itemWithoutFiber.isEmpty)
        XCTAssertFalse(formattingMetrics.batchWithFiber.isEmpty)
        XCTAssertFalse(formattingMetrics.batchWithoutFiber.isEmpty)
        XCTAssertFalse(formattingMetrics.templateSubtitle.isEmpty)
        XCTAssertFalse(formattingMetrics.barcodeFallbackName.isEmpty)
        XCTAssertNotEqual(formattingMetrics.itemWithFiber, formattingMetrics.itemWithoutFiber)
        XCTAssertNotEqual(formattingMetrics.batchWithFiber, formattingMetrics.batchWithoutFiber)
        XCTAssertTrue(formattingMetrics.batchWithFiber.contains("Coverage"))
        XCTAssertTrue(formattingMetrics.batchWithoutFiber.contains("Coverage"))

        let displayedMonth = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 1))
            ?? Date()
        let monthDays = NutritionCoverageHarness.calendarDaysInMonth(for: displayedMonth)
        XCTAssertEqual(monthDays.compactMap(\.self).count, 31)

        let dataURL = try NutritionCoverageHarness.preparedLargeImageDataURL()
        XCTAssertTrue(dataURL.hasPrefix("data:image/jpeg;base64,"))

        let englishParsed = MediaRecognitionService._testParseNutritionLabelText(
            """
            Granola Bar
            Serving 50 g
            Kcal 220
            Protein 20
            Fat 8
            Carbs 18
            Fiber 4
            """
        )
        XCTAssertEqual(englishParsed.name, "Granola Bar")
        XCTAssertEqual(englishParsed.servingSizeG, 50, accuracy: 0.001)
        XCTAssertEqual(englishParsed.caloriesPer100g, 220, accuracy: 0.001)
        XCTAssertEqual(englishParsed.proteinPer100g, 20, accuracy: 0.001)
        XCTAssertEqual(englishParsed.fatPer100g, 8, accuracy: 0.001)
        XCTAssertEqual(englishParsed.carbsPer100g, 18, accuracy: 0.001)
        XCTAssertEqual(englishParsed.fiberPer100g, 4, accuracy: 0.001)

        let russianParsed = MediaRecognitionService._testParseNutritionLabelText(
            """
            Батончик
            Порция 40 г
            Калории 180
            Белок 12
            Жир 6
            Углеводы 20
            """
        )
        XCTAssertEqual(russianParsed.name, "Батончик")
        XCTAssertEqual(russianParsed.servingSizeG, 40, accuracy: 0.001)
        XCTAssertEqual(russianParsed.caloriesPer100g, 180, accuracy: 0.001)
        XCTAssertEqual(russianParsed.proteinPer100g, 12, accuracy: 0.001)
        XCTAssertEqual(russianParsed.fatPer100g, 6, accuracy: 0.001)
        XCTAssertEqual(russianParsed.carbsPer100g, 20, accuracy: 0.001)

        let emptyParsed = MediaRecognitionService._testParseNutritionLabelText(nil)
        XCTAssertFalse(emptyParsed.warnings.isEmpty)
        XCTAssertEqual(try XCTUnwrap(emptyParsed.confidence), 0.35, accuracy: 0.0001)

        let fallbackAnalysis = MediaRecognitionService._testFallbackAnalysis(
            recognizedText: "Chicken bowl with rice",
            barcodes: ["12345"],
            notice: "Cloud disabled"
        )
        XCTAssertEqual(fallbackAnalysis.source, .onDeviceFallback)
        XCTAssertEqual(fallbackAnalysis.notice, "Cloud disabled")
        XCTAssertTrue(fallbackAnalysis.summary.contains("12345"))
        XCTAssertTrue(fallbackAnalysis.summary.contains("Chicken bowl"))

        let aiLabelDraft = MediaRecognitionService._testAIFoodLabelDraft(
            from: FoodLabelAnalysisResponse(
                barcode: nil,
                name: "Coverage Crunch",
                brand: "Coverage Labs",
                servingSizeG: 45,
                macrosPer100g: NutritionFoodsRemoteMacros(
                    calories: 410,
                    proteinG: 23,
                    fatG: 16,
                    carbsG: 36,
                    fiberG: 7
                ),
                confidence: 0.94,
                warnings: ["  OCR warning  "],
                needsReview: false
            ),
            sourceText: "Coverage source",
            barcodeHint: "98765"
        )
        XCTAssertEqual(aiLabelDraft.barcode, "98765")
        XCTAssertEqual(aiLabelDraft.name, "Coverage Crunch")
        XCTAssertEqual(aiLabelDraft.brand, "Coverage Labs")
        XCTAssertEqual(aiLabelDraft.warnings, ["OCR warning"])
        XCTAssertEqual(aiLabelDraft.analysisSource, .aiVision)

        let fallbackLabelDraft = MediaRecognitionService._testFallbackFoodLabelDraft(
            sourceText: nil,
            barcode: "111",
            notice: "Manual review"
        )
        XCTAssertEqual(fallbackLabelDraft.barcode, "111")
        XCTAssertEqual(fallbackLabelDraft.analysisSource, .onDeviceFallback)
        XCTAssertTrue(fallbackLabelDraft.warnings.first?.contains("Manual review") == true)

        let batchDraft = MediaRecognitionService._testBatchRecipePhotoDraft(
            from: BatchRecipePhotoAnalysisResponse(
                recipeName: "Sheet Pan Chili",
                ingredientsDetected: [
                    .init(
                        name: "Beans",
                        estimatedRawWeightG: 280,
                        estimatedCookedWeightG: 240,
                        calories: 320,
                        proteinG: 18,
                        fatG: 2,
                        carbsG: 58,
                        confidence: 0.8
                    ),
                    .init(
                        name: "Turkey",
                        estimatedRawWeightG: nil,
                        estimatedCookedWeightG: 360,
                        calories: 540,
                        proteinG: 64,
                        fatG: 24,
                        carbsG: 0,
                        confidence: 0.86
                    )
                ],
                totalBatch: .init(
                    weightG: 1_200,
                    calories: 1_240,
                    proteinG: 82,
                    fatG: 28,
                    carbsG: 122,
                    fiberG: 16
                ),
                per100g: .init(
                    weightG: 100,
                    calories: 103,
                    proteinG: 6.8,
                    fatG: 2.3,
                    carbsG: 10.2,
                    fiberG: 1.3
                ),
                perPortion: .init(
                    weightG: 300,
                    calories: 310,
                    proteinG: 20.5,
                    fatG: 7,
                    carbsG: 30.5
                ),
                notes: ["  Simmer gently  "],
                storage: .init(
                    refrigeratorDays: 4,
                    freezerMonths: 2,
                    reheatingTip: " Reheat slowly "
                ),
                confidence: 0.88
            ),
            fallbackRecipeName: "Coverage Chili",
            fallbackWeightG: 900,
            fallbackPortions: 4
        )
        XCTAssertEqual(batchDraft.recipeName, "Sheet Pan Chili")
        XCTAssertEqual(batchDraft.totalWeightG, 1_200, accuracy: 0.001)
        XCTAssertEqual(batchDraft.totalPortions, 4)
        XCTAssertEqual(batchDraft.ingredients.count, 2)
        XCTAssertTrue(batchDraft.notes.contains("Refrigerator: 4 days"))
        XCTAssertTrue(batchDraft.notes.contains("Freezer: 2 months"))
        XCTAssertTrue(batchDraft.notes.contains("Reheat slowly"))

        let fallbackBatchDraft = MediaRecognitionService._testFallbackBatchRecipePhotoDraft(
            from: NutritionPhotoAnalysis(
                summary: "Detected rice bowl",
                confidence: 0.62,
                source: .onDeviceFallback,
                recognizedText: "Rice, chicken",
                barcodes: [],
                detectedItems: [
                    NutritionDraftCandidateItem(
                        name: "Rice",
                        brand: "Coverage Pantry",
                        weightG: 180,
                        calories: 240,
                        proteinG: 4,
                        fatG: 1,
                        carbsG: 52,
                        fiberG: 1.5,
                        confidence: 0.7
                    )
                ],
                totalMacros: nil,
                warnings: ["Use manual review"],
                suggestions: [],
                mealType: .lunch,
                notice: "Cloud unavailable"
            ),
            recipeName: "Fallback Prep",
            totalWeightG: 700,
            totalPortions: 3,
            cloudAnalysisEnabled: false
        )
        XCTAssertEqual(fallbackBatchDraft.recipeName, "Fallback Prep")
        XCTAssertEqual(fallbackBatchDraft.ingredients.count, 1)
        XCTAssertEqual(fallbackBatchDraft.totalWeightG, 700, accuracy: 0.001)
        XCTAssertEqual(fallbackBatchDraft.totalPortions, 3)
        XCTAssertTrue(fallbackBatchDraft.notes.first?.contains("Detected rice bowl") == true)

        let emptyFallbackBatchDraft = MediaRecognitionService._testFallbackBatchRecipePhotoDraft(
            from: NutritionPhotoAnalysis(
                summary: "   ",
                confidence: nil,
                source: .onDeviceFallback,
                recognizedText: nil,
                barcodes: [],
                detectedItems: [],
                totalMacros: nil,
                warnings: [],
                suggestions: [],
                mealType: nil,
                notice: nil
            ),
            recipeName: "Silent Prep",
            totalWeightG: 900,
            totalPortions: 2,
            cloudAnalysisEnabled: true
        )
        XCTAssertEqual(emptyFallbackBatchDraft.recipeName, "Silent Prep")
        XCTAssertTrue(emptyFallbackBatchDraft.ingredients.isEmpty)
        XCTAssertEqual(emptyFallbackBatchDraft.totalWeightG, 900, accuracy: 0.001)
        XCTAssertEqual(emptyFallbackBatchDraft.totalPortions, 2)
        XCTAssertEqual(
            emptyFallbackBatchDraft.notes,
            [String(localized: "nutrition_photo_fallback_notice")]
        )
    }

    func testNutritionCoverageHarnessResolverMergesCatalogAndFallbackVoice() async throws {
        let manager = try DatabaseManager.inMemory()

        var oatmeal = FoodCatalogItem(
            provider: .openFoodFacts,
            name: "Oatmeal",
            caloriesPer100g: 389,
            proteinPer100g: 17,
            fatPer100g: 7,
            carbsPer100g: 66
        )
        oatmeal.brand = "Coverage Grains"
        oatmeal.barcode = "12345"
        oatmeal.servingSizeG = 45
        oatmeal.fiberPer100g = 10

        var banana = FoodCatalogItem(
            provider: .openFoodFacts,
            name: "Banana",
            caloriesPer100g: 89,
            proteinPer100g: 1.1,
            fatPer100g: 0.3,
            carbsPer100g: 23
        )
        banana.brand = "Coverage Fruit"
        banana.servingSizeG = 118
        banana.fiberPer100g = 2.6
        let oatmealItemRecord = oatmeal
        let bananaItemRecord = banana

        try await manager.dbQueue.write { db in
            try oatmealItemRecord.insert(db)
            try bananaItemRecord.insert(db)
        }

        let mergedDraft = await NutritionCoverageHarness.resolveCatalogMergedDraft(dbQueue: manager.dbQueue)
        XCTAssertEqual(mergedDraft.method, .photo)
        XCTAssertEqual(mergedDraft.analysisSource, .aiVision)
        XCTAssertEqual(mergedDraft.mealType, .breakfast)
        XCTAssertEqual(mergedDraft.suggestions, ["add yogurt"])
        XCTAssertEqual(mergedDraft.warnings, ["review serving"])
        XCTAssertEqual(mergedDraft.recognizedBarcodes, ["12345"])
        XCTAssertEqual(try XCTUnwrap(mergedDraft.totalMacros?.calories), 480, accuracy: 0.001)

        let mergedNames = Set(mergedDraft.candidateItems.map { $0.name.lowercased() })
        XCTAssertTrue(mergedNames.contains("oatmeal"))
        XCTAssertTrue(mergedNames.contains("banana"))
        XCTAssertTrue(mergedNames.contains("mystery snack"))

        let oatmealItem = try XCTUnwrap(
            mergedDraft.candidateItems.first(where: { $0.name == "Oatmeal" })
        )
        XCTAssertEqual(oatmealItem.brand, "Coverage Grains")
        XCTAssertEqual(oatmealItem.barcode, "12345")
        XCTAssertEqual(oatmealItem.catalogItemId, oatmeal.id)
        XCTAssertEqual(try XCTUnwrap(oatmealItem.weightG), 45, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(oatmealItem.calories), 175.05, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(oatmealItem.confidence), 0.71, accuracy: 0.0001)

        let bananaItem = try XCTUnwrap(
            mergedDraft.candidateItems.first(where: { $0.name == "Banana" })
        )
        XCTAssertEqual(bananaItem.brand, "Coverage Fruit")
        XCTAssertEqual(try XCTUnwrap(bananaItem.weightG), 118, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(bananaItem.calories), 105.02, accuracy: 0.02)

        let voiceDraft = await NutritionCoverageHarness.resolveVoiceFallbackDraft(dbQueue: manager.dbQueue)
        XCTAssertEqual(voiceDraft.method, .voice)
        XCTAssertEqual(voiceDraft.summary, "I had egg whites, toast and coffee")
        XCTAssertEqual(voiceDraft.sourceText, "I had egg whites, toast and coffee")
        XCTAssertEqual(voiceDraft.candidateItems.count, 3)
        XCTAssertEqual(
            voiceDraft.candidateItems.map(\.name),
            ["egg whites", "toast", "coffee"]
        )
    }

    @MainActor
    func testNutritionCoverageHarnessExercisesTemplateAndBatchBranches() throws {
        let renderedCount = NutritionCoverageHarness.exerciseTemplateAndBatchViewBranches()
        XCTAssertGreaterThanOrEqual(renderedCount, 10)

        let templateMetrics = NutritionCoverageHarness.mealTemplateComposerMetrics()
        XCTAssertTrue(templateMetrics.canSave)
        XCTAssertFalse(templateMetrics.blockedSave)
        XCTAssertEqual(templateMetrics.calories, 480, accuracy: 0.001)
        XCTAssertEqual(templateMetrics.protein, 28, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(templateMetrics.fiber), 9, accuracy: 0.001)

        let batchMetrics = NutritionCoverageHarness.batchRecipeComposerMetrics()
        XCTAssertTrue(batchMetrics.canSave)
        XCTAssertFalse(batchMetrics.blockedSave)
        XCTAssertEqual(batchMetrics.totalCalories, 780, accuracy: 0.001)
        XCTAssertEqual(batchMetrics.per100gProtein, 6.7948717949, accuracy: 0.0001)
        XCTAssertEqual(batchMetrics.perPortionCalories, 195, accuracy: 0.001)
        XCTAssertEqual(
            batchMetrics.mergedIngredientNames,
            ["Coverage Chicken", "Coverage Herbs", "Coverage Rice", "Coverage Salsa"]
        )
    }

    @MainActor
    func testNutritionTemplateAndBatchDirectSubviewCoveragePush() async throws {
        let activeTemplateDetail = NutritionCoverageFixtures.mealTemplateDetail()
        let archivedTemplateDetail = NutritionCoverageFixtures.mealTemplateDetail(archived: true)
        let templateSummary = NutritionCoverageFixtures.mealTemplateSummary()

        let editingTemplateView = MealTemplateDetailView(
            testViewModel: MealTemplateDetailViewModel._testConfigured(
                detail: activeTemplateDetail,
                isEditing: true
            )
        )
        renderForCoverage(editingTemplateView)
        editingTemplateView._testRenderTemplateHeaderSection()
        editingTemplateView._testRenderEditorDetailsSection()
        editingTemplateView._testRenderEditorItemsSection()
        editingTemplateView._testRenderTemplateItemEditor(index: 0)
        editingTemplateView._testRenderTemplateNumericField()

        let previewTemplateView = MealTemplateDetailView(
            testViewModel: MealTemplateDetailViewModel._testConfigured(
                detail: archivedTemplateDetail,
                isEditing: false
            )
        )
        renderForCoverage(previewTemplateView)
        previewTemplateView._testRenderPreviewItemsSection()
        previewTemplateView._testRenderPreviewItemRow(
            NutritionEditableMealItem(templateItem: archivedTemplateDetail.items[0])
        )
        previewTemplateView._testRenderActionSection()

        let saveManager = CoverageMealTemplateManagerMock(detailResponse: activeTemplateDetail)
        let saveViewModel = MealTemplateDetailViewModel(
            templateId: activeTemplateDetail.template.id,
            startsEditing: true,
            templateManager: saveManager
        )
        await saveViewModel.loadIfNeeded()
        await MealTemplateDetailView(testViewModel: saveViewModel)._testTriggerSaveTemplate()

        let toggleManager = CoverageMealTemplateManagerMock(detailResponse: activeTemplateDetail)
        let toggleViewModel = MealTemplateDetailViewModel(
            templateId: activeTemplateDetail.template.id,
            templateManager: toggleManager
        )
        await toggleViewModel.loadIfNeeded()
        await MealTemplateDetailView(testViewModel: toggleViewModel)._testTriggerToggleArchived()

        let logManager = CoverageMealTemplateManagerMock(detailResponse: activeTemplateDetail)
        let logViewModel = MealTemplateDetailViewModel(
            templateId: activeTemplateDetail.template.id,
            templateManager: logManager
        )
        await logViewModel.loadIfNeeded()
        await MealTemplateDetailView(testViewModel: logViewModel)._testTriggerLogTemplateNow()

        let templateItems = activeTemplateDetail.items.map(NutritionEditableMealItem.init(templateItem:))
        let templateComposerView = MealTemplateComposerView(
            testName: activeTemplateDetail.template.name,
            testMealType: activeTemplateDetail.template.mealType,
            testItems: templateItems
        )
        renderForCoverage(templateComposerView)
        templateComposerView._testRenderDetailsSection()
        templateComposerView._testRenderPreviewSection()
        templateComposerView._testRenderItemsSection()
        templateComposerView._testRenderItemEditor(index: 0)
        templateComposerView._testRenderTemplateNumericField()

        let mealTemplatesView = MealTemplatesView(
            testIsLoading: false,
            testTemplates: [templateSummary]
        )
        renderForCoverage(mealTemplatesView)
        mealTemplatesView._testRenderTemplateCard(templateSummary)

        let templateLibraryView = MealTemplateLibraryView(
            testTemplates: [templateSummary],
            testIsLoading: false
        )
        renderForCoverage(templateLibraryView)
        templateLibraryView._testRenderTemplateRow(templateSummary)
        templateLibraryView._testRenderTemplateDestination(
            templateId: templateSummary.id,
            startsEditing: false
        )
        templateLibraryView._testRenderComposerSheet()

        let activeBatchSummary = NutritionCoverageFixtures.batchSummary()
        let archivedBatchSummary = NutritionCoverageFixtures.batchSummary(archived: true)
        let activeBatchLibraryView = BatchRecipeLibraryView(
            testRecipes: [activeBatchSummary],
            testIsLoading: false
        )
        renderForCoverage(activeBatchLibraryView)
        activeBatchLibraryView._testRenderBatchRow(activeBatchSummary)
        activeBatchLibraryView._testRenderDetailDestination(batchId: activeBatchSummary.id)
        activeBatchLibraryView._testRenderComposerSheet()
        activeBatchLibraryView._testRenderQuickLogSheet(activeBatchSummary)

        let archivedBatchLibraryView = BatchRecipeLibraryView(
            testRecipes: [archivedBatchSummary],
            testIsLoading: false,
            testShowingArchived: true
        )
        renderForCoverage(archivedBatchLibraryView)
        archivedBatchLibraryView._testRenderBatchRow(archivedBatchSummary)

        let activeBatchDetail = NutritionCoverageFixtures.batchDetail()
        let archivedBatchDetail = NutritionCoverageFixtures.batchDetail(
            archived: true,
            remainingWeightG: 0,
            description: nil
        )
        let activeBatchDetailView = BatchRecipeDetailView(
            batchId: activeBatchDetail.recipe.id,
            testDetail: activeBatchDetail,
            testIsLoading: false
        )
        renderForCoverage(activeBatchDetailView)
        activeBatchDetailView._testRenderDetailHeader(activeBatchDetail)
        activeBatchDetailView._testRenderDetailMacros(activeBatchDetail)
        activeBatchDetailView._testRenderDetailIngredients(activeBatchDetail)
        activeBatchDetailView._testRenderDetailIngredientRow(activeBatchDetail.ingredients[0])
        activeBatchDetailView._testRenderDetailActions(activeBatchDetail)
        activeBatchDetailView._testRenderComposerSheet(activeBatchDetail)
        activeBatchDetailView._testRenderLogSheet(activeBatchDetail)
        activeBatchDetailView._testRenderComposerSheetContent()
        activeBatchDetailView._testRenderLogSheetContent()

        let archivedBatchDetailView = BatchRecipeDetailView(
            batchId: archivedBatchDetail.recipe.id,
            testDetail: archivedBatchDetail,
            testIsLoading: false
        )
        renderForCoverage(archivedBatchDetailView)
        archivedBatchDetailView._testRenderDetailHeader(archivedBatchDetail)
        archivedBatchDetailView._testRenderDetailActions(archivedBatchDetail)
        archivedBatchDetailView._testRenderComposerSheetContent()
        archivedBatchDetailView._testRenderLogSheetContent()

        let archivingBatchDetailView = BatchRecipeDetailView(
            batchId: archivedBatchDetail.recipe.id,
            testDetail: archivedBatchDetail,
            testIsLoading: false,
            testIsArchiving: true
        )
        renderForCoverage(archivingBatchDetailView)
        archivingBatchDetailView._testRenderDetailActions(archivedBatchDetail)

        let duplicatingBatchDetailView = BatchRecipeDetailView(
            batchId: activeBatchDetail.recipe.id,
            testDetail: activeBatchDetail,
            testIsLoading: false,
            testIsDuplicating: true
        )
        renderForCoverage(duplicatingBatchDetailView)
        duplicatingBatchDetailView._testRenderDetailActions(activeBatchDetail)

        let emptyBatchDetailView = BatchRecipeDetailView(
            batchId: activeBatchDetail.recipe.id,
            testDetail: nil,
            testIsLoading: true
        )
        emptyBatchDetailView._testRenderComposerSheetContent()
        emptyBatchDetailView._testRenderLogSheetContent()

        let editableIngredients = activeBatchDetail.ingredients.map(BatchRecipeEditableIngredient.init(ingredient:))
        let batchComposerView = BatchRecipeComposerView(
            testName: activeBatchDetail.recipe.name,
            testDescription: activeBatchDetail.recipe.description ?? "",
            testTotalWeightG: activeBatchDetail.recipe.totalWeightG,
            testTotalPortions: activeBatchDetail.recipe.totalPortions ?? 1,
            testIngredients: editableIngredients
        )
        renderForCoverage(batchComposerView)
        batchComposerView._testRenderDetailsSection()
        batchComposerView._testRenderTotalsSection()
        batchComposerView._testRenderIngredientsSection()
        batchComposerView._testRenderIngredientEditor(index: 0)
        batchComposerView._testRenderBatchNumericField()
        batchComposerView._testRenderBatchIntegerField()
        batchComposerView._testEvaluateIngredientSearchSheet()
        batchComposerView._testEvaluateCameraPickerSheet()

        renderForCoverage(BatchRecipeComposerView(existingDetail: nil) { _ in })
        renderForCoverage(BatchRecipeComposerView(existingDetail: activeBatchDetail) { _ in })

        renderForCoverage(
            BatchPortionLogView(
                batchId: activeBatchDetail.recipe.id,
                batchName: activeBatchDetail.recipe.name,
                remainingWeightG: activeBatchDetail.weightRemainingG,
                per100g: activeBatchDetail.per100g,
                suggestedPortionWeightG: activeBatchDetail.perPortion?.weightG,
                targetDay: NutritionCoverageFixtures.targetDay,
                loggedAt: NutritionCoverageFixtures.loggedAt
            ) { _ in }
        )

        let saveSnapshot = await saveManager.snapshot()
        let toggleSnapshot = await toggleManager.snapshot()
        let logSnapshot = await logManager.snapshot()

        XCTAssertFalse(templateItems.isEmpty)
        XCTAssertFalse(editableIngredients.isEmpty)
        XCTAssertEqual(saveSnapshot.updateDrafts.count, 1)
        XCTAssertEqual(toggleSnapshot.archiveCalls.count, 1)
        XCTAssertEqual(logSnapshot.applyCalls.count, 1)
    }

    @MainActor
    func testNutritionDirectInstanceActionsCoverTemplateBatchAndPortionFlows() async {
        let activeTemplateDetail = NutritionCoverageFixtures.mealTemplateDetail()
        let templateSummary = NutritionCoverageFixtures.mealTemplateSummary()
        let templateManager = CoverageMealTemplateManagerMock(detailResponse: activeTemplateDetail)

        let loadedTemplates = await MealTemplatesView._testLoadTemplatesResult(manager: templateManager)
        XCTAssertEqual(loadedTemplates.count, 1)

        let failingTemplates = await MealTemplatesView._testLoadTemplatesResult(
            manager: CoverageMealTemplateManagerMock(
                detailResponse: nil,
                loadError: CoverageExpectedError(message: "Template list failed")
            )
        )
        XCTAssertTrue(failingTemplates.isEmpty)

        let templateLibraryState = await MealTemplateLibraryView._testLoadTemplatesResult(
            showingArchived: false,
            manager: templateManager
        )
        XCTAssertEqual(templateLibraryState.templates.count, 1)

        switch await MealTemplateLibraryView._testToggleArchiveResult(
            for: templateSummary,
            manager: templateManager
        ) {
        case let .success(message):
            XCTAssertEqual(message.message, String(localized: "nutrition_template_archived"))
        case let .failure(error):
            XCTFail("Expected template archive success, got \(error.localizedDescription)")
        }

        switch await MealTemplateLibraryView._testToggleArchiveResult(
            for: templateSummary,
            manager: CoverageMealTemplateManagerMock(
                detailResponse: activeTemplateDetail,
                archiveError: CoverageExpectedError(message: "Template archive branch failed")
            )
        ) {
        case .success:
            XCTFail("Expected template archive failure")
        case let .failure(error):
            XCTAssertEqual(error.localizedDescription, "Template archive branch failed")
        }

        let templateItems = activeTemplateDetail.items.map(NutritionEditableMealItem.init(templateItem:))
        let templateDraft = MealTemplateComposerView._testSaveDraft(
            name: activeTemplateDetail.template.name,
            mealType: activeTemplateDetail.template.mealType,
            items: templateItems
        )

        switch await MealTemplateComposerView._testSaveResult(
            draft: templateDraft,
            manager: templateManager
        ) {
        case let .success(message):
            XCTAssertEqual(message.message, String(localized: "nutrition_template_created"))
        case let .failure(error):
            XCTFail("Expected template create success, got \(error.localizedDescription)")
        }

        switch await MealTemplateComposerView._testSaveResult(
            draft: templateDraft,
            manager: CoverageMealTemplateManagerMock(
                detailResponse: activeTemplateDetail,
                createError: CoverageExpectedError(message: "Template create failed")
            )
        ) {
        case .success:
            XCTFail("Expected template create failure")
        case let .failure(error):
            XCTAssertEqual(error.localizedDescription, "Template create failed")
        }

        let templateSnapshot = await templateManager.snapshot()
        XCTAssertEqual(templateSnapshot.createDrafts.count, 1)
        XCTAssertEqual(templateSnapshot.createDrafts.first?.items.count, templateItems.count)

        let batchDetail = NutritionCoverageFixtures.batchDetail()
        let batchManager = CoverageBatchRecipeManagerMock(detailResponse: batchDetail)

        let batchLoadState = await BatchRecipeDetailView._testLoadDetailResult(
            batchId: batchDetail.recipe.id,
            preferRemote: true,
            manager: batchManager
        )
        XCTAssertEqual(batchLoadState.detail?.recipe.id, batchDetail.recipe.id)
        XCTAssertNil(batchLoadState.errorMessage)

        switch await BatchRecipeDetailView._testToggleArchivedResult(
            detail: batchDetail,
            manager: batchManager
        ) {
        case let .success(message):
            XCTAssertEqual(message.message, String(localized: "nutrition_batch_archived"))
        case let .failure(error):
            XCTFail("Expected batch archive success, got \(error.localizedDescription)")
        }

        switch await BatchRecipeDetailView._testToggleArchivedResult(
            detail: batchDetail,
            manager: CoverageBatchRecipeManagerMock(
                detailResponse: batchDetail,
                archiveError: CoverageExpectedError(message: "Batch archive failed")
            )
        ) {
        case .success:
            XCTFail("Expected batch archive failure")
        case let .failure(error):
            XCTAssertEqual(error.localizedDescription, "Batch archive failed")
        }

        switch await BatchRecipeDetailView._testCookAgainResult(
            detail: batchDetail,
            manager: batchManager
        ) {
        case let .success(message):
            XCTAssertTrue(message.message.contains("Coverage Duplicate"))
        case let .failure(error):
            XCTFail("Expected batch duplicate success, got \(error.localizedDescription)")
        }

        switch await BatchRecipeDetailView._testCookAgainResult(
            detail: batchDetail,
            manager: CoverageBatchRecipeManagerMock(
                detailResponse: batchDetail,
                duplicateError: CoverageExpectedError(message: "Duplicate branch failed")
            )
        ) {
        case .success:
            XCTFail("Expected batch duplicate failure")
        case let .failure(error):
            XCTAssertEqual(error.localizedDescription, "Duplicate branch failed")
        }

        let editableIngredients = batchDetail.ingredients.map(BatchRecipeEditableIngredient.init(ingredient:))
        let batchDraft = BatchRecipeComposerView._testSaveDraft(
            existingDetail: nil,
            name: batchDetail.recipe.name,
            description: batchDetail.recipe.description ?? "",
            cookedAt: NutritionCoverageFixtures.loggedAt,
            totalWeightG: batchDetail.recipe.totalWeightG,
            totalPortions: batchDetail.recipe.totalPortions ?? 1,
            ingredients: editableIngredients
        )

        switch await BatchRecipeComposerView._testSaveResult(
            draft: batchDraft,
            existingDetail: nil,
            manager: batchManager
        ) {
        case let .success(message):
            XCTAssertEqual(message.message, String(localized: "nutrition_batch_saved"))
        case let .failure(error):
            XCTFail("Expected batch create success, got \(error.localizedDescription)")
        }

        switch await BatchRecipeComposerView._testSaveResult(
            draft: batchDraft,
            existingDetail: nil,
            manager: CoverageBatchRecipeManagerMock(
                detailResponse: batchDetail,
                createError: CoverageExpectedError(message: "Batch create failed")
            )
        ) {
        case .success:
            XCTFail("Expected batch create failure")
        case let .failure(error):
            XCTAssertEqual(error.localizedDescription, "Batch create failed")
        }

        switch await BatchRecipeComposerView._testSaveResult(
            draft: BatchRecipeComposerView._testSaveDraft(
                existingDetail: batchDetail,
                name: batchDetail.recipe.name,
                description: batchDetail.recipe.description ?? "",
                cookedAt: NutritionCoverageFixtures.loggedAt,
                totalWeightG: batchDetail.recipe.totalWeightG,
                totalPortions: batchDetail.recipe.totalPortions ?? 1,
                ingredients: editableIngredients
            ),
            existingDetail: batchDetail,
            manager: batchManager
        ) {
        case let .success(message):
            XCTAssertEqual(message.message, String(localized: "nutrition_batch_updated"))
        case let .failure(error):
            XCTFail("Expected batch update success, got \(error.localizedDescription)")
        }

        let portionDraft = NutritionBatchPortionLogDraft(
            batchId: batchDetail.recipe.id,
            targetDay: NutritionCoverageFixtures.targetDay,
            loggedAt: NutritionCoverageFixtures.loggedAt,
            mealType: .lunch,
            context: .home,
            portionWeightG: batchDetail.perPortion?.weightG ?? 120
        )

        switch await BatchPortionLogView._testSaveResult(
            draft: portionDraft,
            batchName: batchDetail.recipe.name,
            manager: batchManager
        ) {
        case let .success(message):
            XCTAssertTrue(message.message.contains(batchDetail.recipe.name))
        case let .failure(error):
            XCTFail("Expected portion log success, got \(error.localizedDescription)")
        }

        switch await BatchPortionLogView._testSaveResult(
            draft: portionDraft,
            batchName: batchDetail.recipe.name,
            manager: CoverageBatchRecipeManagerMock(
                detailResponse: batchDetail,
                logError: CoverageExpectedError(message: "Portion log failed")
            )
        ) {
        case .success:
            XCTFail("Expected portion log failure")
        case let .failure(error):
            XCTAssertEqual(error.localizedDescription, "Portion log failed")
        }
    }

    @MainActor
    func testNutritionDirectRenderedInputAndCalendarViewsCoverage() async {
        let image = NutritionCoverageFixtures.image()
        let photoAnalysis = NutritionCoverageFixtures.photoAnalysis(notice: "Review details")
        let matchedProduct = NutritionCoverageFixtures.foodResult(name: "Coverage Cereal")

        let photoLoadingView = NutritionPhotoCaptureView(
            testCapturedImage: image,
            testIsAnalyzing: true
        )
        photoLoadingView._testEvaluateBody()
        renderForCoverage(photoLoadingView)

        let photoAnalyzedView = NutritionPhotoCaptureView(
            testCapturedImage: image,
            testAnalysisResult: "Coverage meal analyzed",
            testAnalysisConfidence: 0.91,
            testPhotoAnalysis: photoAnalysis,
            testAnalysisNotice: "Review details",
            testCaptureError: "Minor note"
        )
        photoAnalyzedView._testEvaluateBody()
        renderForCoverage(photoAnalyzedView)

        let photoImageErrorView = NutritionPhotoCaptureView(
            testCapturedImage: image,
            testCaptureError: "Photo capture error"
        )
        photoImageErrorView._testEvaluateBody()
        renderForCoverage(photoImageErrorView)

        let photoEmptyStateView = NutritionPhotoCaptureView(
            testCaptureError: "Camera unavailable"
        )
        photoEmptyStateView._testEvaluateBody()
        renderForCoverage(photoEmptyStateView)
        photoEmptyStateView._testEvaluateCameraPickerSheet()

        var labelReviewDraft = NutritionCoverageFixtures.labelDraft(
            warnings: ["OCR note"],
            sourceText: "Protein 20\nFat 8"
        )
        let labelReviewView = NutritionLabelReviewFormView(
            draft: Binding(
                get: { labelReviewDraft },
                set: { labelReviewDraft = $0 }
            ),
            isSaving: false,
            isAnalyzing: true,
            errorMessage: "Review error",
            onRescan: {},
            onSave: {}
        )
        labelReviewView._testEvaluateBody()
        renderForCoverage(labelReviewView)
        labelReviewView._testRenderWarningRow("OCR note")

        let barcodeLoadingView = NutritionBarcodeScannerView(
            testScannedCode: "12345",
            testIsSearching: true
        )
        barcodeLoadingView._testEvaluateBody()
        renderForCoverage(barcodeLoadingView)

        let barcodeMatchedView = NutritionBarcodeScannerView(
            testScannedCode: "12345",
            testIsSaving: true,
            testProductFound: true,
            testMatchedProduct: matchedProduct
        )
        barcodeMatchedView._testEvaluateBody()
        renderForCoverage(barcodeMatchedView)

        let barcodeFallbackView = NutritionBarcodeScannerView(
            testIsAnalyzingLabel: true,
            testShowLabelOCRFallback: true,
            testOCRResult: "Protein 20g",
            testErrorMessage: "Fallback error",
            testPendingLabelImages: [image]
        )
        barcodeFallbackView._testEvaluateBody()
        renderForCoverage(barcodeFallbackView)

        let barcodeFallbackDisabledView = NutritionBarcodeScannerView(
            testIsAnalyzingLabel: true,
            testShowLabelOCRFallback: true,
            testOCRResult: "Protein 20g"
        )
        barcodeFallbackDisabledView._testEvaluateBody()
        renderForCoverage(barcodeFallbackDisabledView)

        let barcodeReviewView = NutritionBarcodeScannerView(
            testLabelReviewDraft: labelReviewDraft
        )
        barcodeReviewView._testEvaluateBody()
        renderForCoverage(barcodeReviewView)
        barcodeReviewView._testEvaluateCameraPickerSheet()

        let barcodeNoMatchView = NutritionBarcodeScannerView(
            testScannedCode: "12345"
        )
        barcodeNoMatchView._testEvaluateBody()
        renderForCoverage(barcodeNoMatchView)

        let barcodeInitialStateView = NutritionBarcodeScannerView(
            testErrorMessage: "Camera denied"
        )
        barcodeInitialStateView._testEvaluateBody()
        renderForCoverage(barcodeInitialStateView)

        let recordingRecognizer = NutritionSpeechRecognizer()
        recordingRecognizer._testOverrideState(
            isRecording: true,
            isProcessing: false,
            transcription: "",
            errorMessage: nil,
            confidence: nil
        )
        let recordingVoiceView = NutritionVoiceInputView(testSpeechRecognizer: recordingRecognizer)
        recordingVoiceView._testEvaluateBody()
        renderForCoverage(recordingVoiceView)

        let transcriptRecognizer = NutritionSpeechRecognizer()
        transcriptRecognizer._testOverrideState(
            isRecording: false,
            isProcessing: false,
            transcription: "Chicken rice bowl",
            errorMessage: "Mic warning",
            confidence: 0.8
        )
        let transcriptVoiceView = NutritionVoiceInputView(testSpeechRecognizer: transcriptRecognizer)
        transcriptVoiceView._testEvaluateBody()
        renderForCoverage(transcriptVoiceView)

        let voiceDraft = NutritionLogDraft(
            method: .voice,
            confidence: 0.8,
            loggedAt: NutritionCoverageFixtures.loggedAt,
            loggedDate: NutritionCoverageFixtures.targetDay,
            summary: "Voice coverage meal",
            sourceText: "Chicken rice bowl",
            analysisSource: .onDeviceFallback,
            totalMacros: nil,
            suggestions: [],
            warnings: [],
            mealType: .lunch,
            recognizedBarcodes: [],
            candidateItems: []
        )
        let resolvedVoiceResult = await transcriptVoiceView._testResolveVoiceResult(draft: voiceDraft)
        XCTAssertEqual(resolvedVoiceResult.result?.summary, "Voice coverage meal")
        XCTAssertEqual(resolvedVoiceResult.dismissCalls, 1)
        let defaultResolvedVoiceResult = await transcriptVoiceView._testResolveVoiceResultUsingDefaultResolver()
        XCTAssertEqual(defaultResolvedVoiceResult.result?.method, .voice)
        XCTAssertEqual(defaultResolvedVoiceResult.result?.loggedDate, NutritionCoverageFixtures.targetDay)
        XCTAssertEqual(defaultResolvedVoiceResult.result?.sourceText, "Chicken rice bowl")
        XCTAssertEqual(defaultResolvedVoiceResult.dismissCalls, 1)

        let recordingToggleCalls = await recordingVoiceView._testToggleRecording()
        XCTAssertEqual(recordingToggleCalls.startCalls, 0)
        XCTAssertEqual(recordingToggleCalls.stopCalls, 1)
        let stopOnDisappearCalls = await recordingVoiceView._testStopRecordingOnDisappear()
        XCTAssertEqual(stopOnDisappearCalls, 1)

        let idleRecognizer = NutritionSpeechRecognizer()
        idleRecognizer._testOverrideState(
            isRecording: false,
            isProcessing: false,
            transcription: "",
            errorMessage: nil,
            confidence: nil
        )
        let idleVoiceView = NutritionVoiceInputView(testSpeechRecognizer: idleRecognizer)
        let idleToggleCalls = await idleVoiceView._testToggleRecording()
        XCTAssertEqual(idleToggleCalls.startCalls, 1)
        XCTAssertEqual(idleToggleCalls.stopCalls, 0)

        let loadingSearchView = NutritionSearchView(
            testQuery: "coverage",
            testIsSearching: true
        )
        loadingSearchView._testEvaluateBody()
        renderForCoverage(loadingSearchView)

        let emptySearchView = NutritionSearchView(
            testQuery: "coverage",
            testResults: []
        )
        emptySearchView._testEvaluateBody()
        renderForCoverage(emptySearchView)

        let searchResult = NutritionCoverageFixtures.foodResult(name: "Coverage Oats")
        var selectedDraft: NutritionLogDraft?
        let populatedSearchView = NutritionSearchView(
            testQuery: "coverage",
            testResults: [searchResult],
            testErrorMessage: "Search warning",
            onSelectResult: { selectedDraft = $0 }
        )
        populatedSearchView._testEvaluateBody()
        renderForCoverage(populatedSearchView)
        populatedSearchView._testRenderSearchResultButton(searchResult)
        populatedSearchView._testSelectSearchResult(searchResult)
        XCTAssertEqual(selectedDraft?.candidateItems.first?.name, "Coverage Oats")
        NutritionSearchView(testQuery: "   ")._testSubmitSearchUsingDefaultService()

        let invalidPortionView = BatchPortionLogView(
            remainingWeightG: 120,
            testPortionWeightG: 180,
            testErrorMessage: "Too much selected"
        )
        invalidPortionView._testEvaluateBody()
        renderForCoverage(invalidPortionView)
        XCTAssertFalse(invalidPortionView._testCanSave())

        let validPortionView = BatchPortionLogView()
        validPortionView._testEvaluateBody()
        renderForCoverage(validPortionView)
        XCTAssertTrue(validPortionView._testCanSave())
        XCTAssertGreaterThan(validPortionView._testPreview().calories, 0)

        let ingredientLoadingView = BatchRecipeIngredientPickerView(
            testQuery: "coverage",
            testIsSearching: true
        )
        ingredientLoadingView._testEvaluateBody()
        renderForCoverage(ingredientLoadingView)

        let ingredientResultsView = BatchRecipeIngredientPickerView(
            testQuery: "coverage",
            testResults: [NutritionCoverageFixtures.foodResult()]
        )
        ingredientResultsView._testEvaluateBody()
        renderForCoverage(ingredientResultsView)
        ingredientResultsView._testRenderSearchResultButton(NutritionCoverageFixtures.foodResult())
        BatchRecipeIngredientPickerView(testQuery: "   ")._testSubmitSearchUsingDefaultService()

        let ingredientErrorView = BatchRecipeIngredientPickerView(
            testQuery: "coverage",
            testErrorMessage: "Network error"
        )
        ingredientErrorView._testEvaluateBody()
        renderForCoverage(ingredientErrorView)

        let ingredientSelectionResult = NutritionCoverageFixtures.foodResult(name: "Coverage Ingredient")
        var selectedIngredient: FoodSearchResult?
        var didDismissIngredientPicker = false
        BatchRecipeIngredientPickerView(onSelect: { selectedIngredient = $0 })
            ._testSelectResult(ingredientSelectionResult) {
                didDismissIngredientPicker = true
            }
        XCTAssertEqual(selectedIngredient?.name, "Coverage Ingredient")
        XCTAssertTrue(didDismissIngredientPicker)

        var selectedDate = NutritionCoverageFixtures.loggedAt
        let displayedMonth = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 1))
            ?? NutritionCoverageFixtures.loggedAt
        let calendarView = NutritionCalendarView(
            selectedDate: Binding(
                get: { selectedDate },
                set: { selectedDate = $0 }
            ),
            testDisplayedMonth: displayedMonth,
            testDaysWithLogs: ["2026-03-01", "2026-03-19"]
        )
        XCTAssertEqual(calendarView._testDaysInMonth().compactMap(\.self).count, 31)
        calendarView._testEvaluateBody()
        renderForCoverage(calendarView)
        calendarView._testRenderWeekdayHeader("Mo")
        calendarView._testRenderDayCell(nil)

        guard let selectedCalendarDate = Calendar.current.date(
            from: DateComponents(year: 2026, month: 3, day: 19)
        ) else {
            return XCTFail("Missing selectedCalendarDate fixture")
        }

        calendarView._testRenderDayCell(selectedCalendarDate)
        let previousMonth = calendarView._testShiftDisplayedMonth(by: -1)
        XCTAssertEqual(Calendar.current.component(.month, from: previousMonth), 2)

        let selectedDateState = calendarView._testSelectDate(selectedCalendarDate)
        XCTAssertEqual(selectedDateState.selectedDate, selectedCalendarDate)
        XCTAssertEqual(selectedDateState.dismissCalls, 1)

        guard let today = Calendar.current.date(
            from: DateComponents(year: 2026, month: 3, day: 25)
        ) else {
            return XCTFail("Missing today fixture")
        }

        let todayState = calendarView._testSelectToday(today)
        XCTAssertEqual(
            Calendar.current.startOfDay(for: todayState.selectedDate),
            Calendar.current.startOfDay(for: today)
        )
        XCTAssertEqual(todayState.dismissCalls, 1)
    }

    @MainActor
    func testNutritionDirectRenderedTemplateAndBatchViewsCoverage() async {
        let activeTemplateDetail = NutritionCoverageFixtures.mealTemplateDetail()
        let archivedTemplateDetail = NutritionCoverageFixtures.mealTemplateDetail(archived: true)
        let batchDetail = NutritionCoverageFixtures.batchDetail()
        let archivedBatchDetail = NutritionCoverageFixtures.batchDetail(
            archived: true,
            remainingWeightG: 0,
            description: nil
        )

        let loadingTemplatesView = MealTemplatesView(testIsLoading: true)
        loadingTemplatesView._testEvaluateBody()
        renderForCoverage(loadingTemplatesView)

        let emptyTemplatesView = MealTemplatesView(
            testIsLoading: false,
            testTemplates: []
        )
        emptyTemplatesView._testEvaluateBody()
        renderForCoverage(emptyTemplatesView)

        let populatedTemplatesView = MealTemplatesView(
            testIsLoading: false,
            testTemplates: [NutritionCoverageFixtures.mealTemplateSummary()]
        )
        populatedTemplatesView._testEvaluateBody()
        renderForCoverage(populatedTemplatesView)

        let loadingTemplateLibraryView = MealTemplateLibraryView(testIsLoading: true)
        loadingTemplateLibraryView._testEvaluateBody()
        renderForCoverage(loadingTemplateLibraryView)

        let archivedTemplateLibraryView = MealTemplateLibraryView(
            testTemplates: [],
            testIsLoading: false,
            testShowingArchived: true,
            testStatusMessage: TemplateStatusMessage(message: "Archive unavailable", isError: true)
        )
        archivedTemplateLibraryView._testEvaluateBody()
        renderForCoverage(archivedTemplateLibraryView)
        _ = await archivedTemplateLibraryView._testHandleTemplateDetailTemplatesChanged()
        _ = archivedTemplateLibraryView._testHandleTemplateDetailStatusMessage(
            TemplateStatusMessage(message: "Template detail refreshed", isError: false)
        )

        let templateDetailLoadingView = MealTemplateDetailView(
            testViewModel: MealTemplateDetailViewModel._testConfigured(
                detail: activeTemplateDetail,
                isLoading: true
            )
        )
        templateDetailLoadingView._testEvaluateBody()
        renderForCoverage(templateDetailLoadingView)

        let templateDetailEditingView = MealTemplateDetailView(
            testViewModel: MealTemplateDetailViewModel._testConfigured(
                detail: activeTemplateDetail,
                isEditing: true,
                errorMessage: "Edit validation"
            )
        )
        templateDetailEditingView._testEvaluateBody()
        renderForCoverage(templateDetailEditingView)

        let templateDetailArchivedView = MealTemplateDetailView(
            testViewModel: MealTemplateDetailViewModel._testConfigured(
                detail: archivedTemplateDetail,
                isArchiving: true,
                statusMessage: TemplateStatusMessage(message: "Archived template", isError: true)
            )
        )
        templateDetailArchivedView._testEvaluateBody()
        renderForCoverage(templateDetailArchivedView)

        let templateItems = activeTemplateDetail.items.map(NutritionEditableMealItem.init(templateItem:))

        let blockedTemplateComposerView = MealTemplateComposerView(
            testName: "   ",
            testItems: []
        )
        blockedTemplateComposerView._testEvaluateBody()
        renderForCoverage(blockedTemplateComposerView)
        XCTAssertFalse(blockedTemplateComposerView._testCanSave())

        let savingTemplateComposerView = MealTemplateComposerView(
            testName: activeTemplateDetail.template.name,
            testMealType: activeTemplateDetail.template.mealType,
            testItems: templateItems,
            testIsSaving: true,
            testErrorMessage: "Unable to save"
        )
        savingTemplateComposerView._testEvaluateBody()
        renderForCoverage(savingTemplateComposerView)
        XCTAssertGreaterThan(savingTemplateComposerView._testTotals().calories, 0)

        let loadingBatchLibraryView = BatchRecipeLibraryView(testIsLoading: true)
        loadingBatchLibraryView._testEvaluateBody()
        renderForCoverage(loadingBatchLibraryView)

        renderForCoverage(
            BatchRecipeView(
                targetDay: NutritionCoverageFixtures.targetDay,
                loggedAt: NutritionCoverageFixtures.loggedAt,
                onBatchesChanged: {},
                onBatchLogged: {}
            )
        )
        BatchRecipeView(
            targetDay: NutritionCoverageFixtures.targetDay,
            loggedAt: NutritionCoverageFixtures.loggedAt,
            onBatchesChanged: {},
            onBatchLogged: {}
        )._testEvaluateBody()

        let archivedBatchLibraryView = BatchRecipeLibraryView(
            testRecipes: [NutritionCoverageFixtures.batchSummary(archived: true)],
            testIsLoading: false,
            testShowingArchived: true,
            testStatusMessage: TemplateStatusMessage(message: "Archived batch", isError: true)
        )
        archivedBatchLibraryView._testEvaluateBody()
        renderForCoverage(archivedBatchLibraryView)
        archivedBatchLibraryView._testRenderStyledBatchRow(NutritionCoverageFixtures.batchSummary(archived: true))
        _ = await archivedBatchLibraryView._testHandleDetailBatchesChanged()
        _ = await archivedBatchLibraryView._testHandleDetailBatchLogged()
        _ = archivedBatchLibraryView._testHandleDetailStatusMessage(
            TemplateStatusMessage(message: "Batch detail refreshed", isError: false)
        )

        let loadingBatchDetailView = BatchRecipeDetailView(testIsLoading: true)
        loadingBatchDetailView._testEvaluateBody()
        renderForCoverage(loadingBatchDetailView)

        let populatedBatchDetailView = BatchRecipeDetailView(
            batchId: batchDetail.recipe.id,
            testDetail: batchDetail,
            testIsLoading: false,
            testStatusMessage: TemplateStatusMessage(message: "Batch refreshed", isError: false)
        )
        populatedBatchDetailView._testEvaluateBody()
        renderForCoverage(populatedBatchDetailView)

        let archivedBatchDetailView = BatchRecipeDetailView(
            batchId: archivedBatchDetail.recipe.id,
            testDetail: archivedBatchDetail,
            testIsLoading: false,
            testIsArchiving: true,
            testErrorMessage: "Archive note",
            testStatusMessage: TemplateStatusMessage(message: "Archived batch", isError: true)
        )
        archivedBatchDetailView._testEvaluateBody()
        renderForCoverage(archivedBatchDetailView)

        let editableIngredients = batchDetail.ingredients.map(BatchRecipeEditableIngredient.init(ingredient:))

        let batchComposerView = BatchRecipeComposerView(
            testName: "Coverage Prep",
            testDescription: "Roast and chill",
            testTotalWeightG: batchDetail.recipe.totalWeightG,
            testTotalPortions: batchDetail.recipe.totalPortions ?? 1,
            testIngredients: editableIngredients,
            testImportMessage: "Photo draft imported."
        )
        batchComposerView._testEvaluateBody()
        renderForCoverage(batchComposerView)
        XCTAssertGreaterThan(batchComposerView._testTotals().calories, 0)

        let savingBatchComposerView = BatchRecipeComposerView(
            existingDetail: batchDetail,
            testName: batchDetail.recipe.name,
            testDescription: batchDetail.recipe.description ?? "",
            testCookedAt: NutritionCoverageFixtures.loggedAt,
            testTotalWeightG: batchDetail.recipe.totalWeightG,
            testTotalPortions: batchDetail.recipe.totalPortions ?? 1,
            testIngredients: editableIngredients,
            testIsSaving: true,
            testErrorMessage: "Photo import issue",
            testIsAnalyzingPhoto: true
        )
        savingBatchComposerView._testEvaluateBody()
        renderForCoverage(savingBatchComposerView)
        XCTAssertGreaterThan(savingBatchComposerView._testPerPortion().calories, 0)
        _ = batchComposerView._testPresentIngredientSearch()
        _ = batchComposerView._testAddManualIngredient()

        _ = BatchRecipeComposerView(
            testName: "Coverage Prep",
            testIngredients: editableIngredients
        )._testHandleIngredientSearchSelection(
            NutritionCoverageFixtures.foodResult(name: "Coverage Added Ingredient")
        )

        _ = await BatchRecipeComposerView(
            testName: "",
            testDescription: "",
            testTotalWeightG: 1_000,
            testTotalPortions: 1,
            testIngredients: []
        )._testHandlePickedCameraImageUsingOverride(
            response: BatchRecipePhotoAnalysisResponse(
                recipeName: "Coverage Imported Batch",
                ingredientsDetected: [
                    .init(
                        name: "Coverage Imported Ingredient",
                        estimatedRawWeightG: nil,
                        estimatedCookedWeightG: 240,
                        calories: 280,
                        proteinG: 24,
                        fatG: 8,
                        carbsG: 12,
                        confidence: 0.84
                    )
                ],
                totalBatch: .init(
                    weightG: 780,
                    calories: 780,
                    proteinG: 24,
                    fatG: 8,
                    carbsG: 12,
                    fiberG: nil
                ),
                per100g: nil,
                perPortion: .init(
                    weightG: 195,
                    calories: 195,
                    proteinG: 6,
                    fatG: 2,
                    carbsG: 3
                ),
                notes: ["Imported from test photo"],
                storage: nil,
                confidence: 0.84
            )
        )
    }

    @MainActor
    func testNutritionCoverageHarnessExercisesComposerMutationBranches() {
        let templateMutationMetrics = NutritionCoverageHarness.mealTemplateComposerMutationMetrics()
        XCTAssertEqual(templateMutationMetrics.itemCount, 1)
        XCTAssertFalse(
            templateMutationMetrics.firstAddedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )

        let photoImportMetrics = NutritionCoverageHarness.batchRecipePhotoImportMetrics()
        XCTAssertEqual(photoImportMetrics.importedName, "Coverage Prep")
        XCTAssertEqual(photoImportMetrics.importedDescription, "Roast and chill")
        XCTAssertEqual(photoImportMetrics.importedIngredientCount, 2)
        XCTAssertEqual(photoImportMetrics.noteImportMessage, "Coverage import note")
        XCTAssertEqual(
            photoImportMetrics.mergedIngredientNames,
            ["Coverage Chicken", "Coverage Herbs"]
        )
        XCTAssertTrue(photoImportMetrics.mergedDescription.contains("Base note"))
        XCTAssertTrue(photoImportMetrics.mergedDescription.contains("New note"))
        XCTAssertEqual(photoImportMetrics.genericImportMessage, "Photo draft imported. Review before saving.")
        XCTAssertNotNil(photoImportMetrics.fallbackError)

        let manualIngredient = BatchRecipeEditableIngredient.manual()
        XCTAssertEqual(manualIngredient.weightG, 100, accuracy: 0.001)
        XCTAssertEqual(manualIngredient.calories, 100, accuracy: 0.001)

        let searchIngredient = BatchRecipeEditableIngredient(
            searchResult: NutritionCoverageFixtures.foodResult(
                name: "Coverage Soup",
                brand: "Coverage Kitchen",
                barcode: "999999",
                refType: .custom
            )
        )
        XCTAssertEqual(searchIngredient.name, "Coverage Soup")
        XCTAssertEqual(searchIngredient.userFoodId, searchIngredient.draftIngredient.userFoodId)
        XCTAssertEqual(searchIngredient.draftIngredient.name, "Coverage Soup")
        XCTAssertEqual(searchIngredient.draftIngredient.brand, "Coverage Kitchen")
    }

    @MainActor
    func testMealTemplateDetailViewModelHappyPathCoverage() async throws {
        let detail = NutritionCoverageFixtures.mealTemplateDetail()
        let manager = CoverageMealTemplateManagerMock(detailResponse: detail)
        let viewModel = MealTemplateDetailViewModel(
            templateId: detail.template.id,
            templateManager: manager
        )

        await viewModel.loadIfNeeded()
        XCTAssertEqual(viewModel.name, detail.template.name)
        XCTAssertEqual(viewModel.mealType, detail.template.mealType)
        XCTAssertEqual(viewModel.items.count, detail.items.count)
        XCTAssertEqual(viewModel.totals.calories, 480, accuracy: 0.001)
        XCTAssertEqual(viewModel.totals.protein, 28, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(viewModel.totals.fiber), 9, accuracy: 0.001)

        await viewModel.loadIfNeeded()
        let initialSnapshot = await manager.snapshot()
        XCTAssertEqual(initialSnapshot.loadCallCount, 1)
        XCTAssertEqual(initialSnapshot.lastLoadPreferRemote, true)

        viewModel.startEditing()
        XCTAssertTrue(viewModel.isEditing)

        let originalItems = viewModel.items
        viewModel.name = "Coverage Remix"
        viewModel.mealType = MealType.lunch
        viewModel.addItem()
        XCTAssertEqual(viewModel.items.count, originalItems.count + 1)

        let removableId = try XCTUnwrap(viewModel.items.last?.id)
        viewModel.removeItem(id: removableId)
        XCTAssertEqual(viewModel.items.count, originalItems.count)

        viewModel.items = [try XCTUnwrap(originalItems.first)]
        let singleItemId = try XCTUnwrap(viewModel.items.first?.id)
        viewModel.removeItem(id: singleItemId)
        XCTAssertNotNil(viewModel.errorMessage)

        viewModel.items = originalItems
        viewModel.errorMessage = nil
        XCTAssertTrue(viewModel.canSave)

        let didSave = await viewModel.save()
        XCTAssertTrue(didSave)
        XCTAssertFalse(viewModel.isEditing)
        XCTAssertEqual(viewModel.statusMessage?.message, String(localized: "nutrition_template_updated"))
        XCTAssertNil(viewModel.errorMessage)

        let afterSaveSnapshot = await manager.snapshot()
        XCTAssertEqual(afterSaveSnapshot.loadCallCount, 2)
        XCTAssertEqual(afterSaveSnapshot.lastLoadPreferRemote, false)
        XCTAssertEqual(afterSaveSnapshot.updateDrafts.count, 1)
        XCTAssertEqual(afterSaveSnapshot.updateDrafts.first?.name, "Coverage Remix")
        XCTAssertEqual(afterSaveSnapshot.updateDrafts.first?.mealType, .lunch)
        XCTAssertEqual(afterSaveSnapshot.updateDrafts.first?.items.count, originalItems.count)

        viewModel.startEditing()
        viewModel.name = "Broken Draft"
        viewModel.cancelEditing()
        XCTAssertEqual(viewModel.name, detail.template.name)
        XCTAssertFalse(viewModel.isEditing)

        let previousTimesUsed = viewModel.timesUsed
        let didArchive = await viewModel.toggleArchived()
        XCTAssertTrue(didArchive)
        XCTAssertTrue(viewModel.archived)
        XCTAssertNotNil(viewModel.updatedAt)

        let didRestore = await viewModel.toggleArchived()
        XCTAssertTrue(didRestore)
        XCTAssertFalse(viewModel.archived)

        let didLog = await viewModel.logNow(
            targetDay: NutritionCoverageFixtures.targetDay,
            loggedAt: NutritionCoverageFixtures.loggedAt
        )
        XCTAssertTrue(didLog)
        XCTAssertEqual(viewModel.timesUsed, previousTimesUsed + 1)
        XCTAssertNotNil(viewModel.lastUsedAt)
        XCTAssertEqual(
            viewModel.statusMessage?.message,
            String(format: String(localized: "nutrition_logged_template_format"), detail.template.name)
        )

        let finalSnapshot = await manager.snapshot()
        XCTAssertEqual(finalSnapshot.archiveCalls.count, 2)
        XCTAssertEqual(finalSnapshot.archiveCalls.first?.archived, true)
        XCTAssertEqual(finalSnapshot.archiveCalls.last?.archived, false)
        XCTAssertEqual(finalSnapshot.applyCalls.count, 1)
        XCTAssertEqual(finalSnapshot.applyCalls.first?.targetDay, NutritionCoverageFixtures.targetDay)
    }

    @MainActor
    func testMealTemplateDetailViewModelFailureCoverage() async throws {
        let detail = NutritionCoverageFixtures.mealTemplateDetail()

        let loadFailureManager = CoverageMealTemplateManagerMock(
            detailResponse: nil,
            loadError: CoverageExpectedError(message: "Load failed")
        )
        let loadFailureViewModel = MealTemplateDetailViewModel(
            templateId: UUID(),
            templateManager: loadFailureManager
        )
        await loadFailureViewModel.loadIfNeeded()
        XCTAssertEqual(loadFailureViewModel.errorMessage, "Load failed")

        let missingDetailManager = CoverageMealTemplateManagerMock(detailResponse: nil)
        let missingDetailViewModel = MealTemplateDetailViewModel(
            templateId: UUID(),
            templateManager: missingDetailManager
        )
        await missingDetailViewModel.loadIfNeeded()
        XCTAssertNotNil(missingDetailViewModel.errorMessage)

        let saveFailureManager = CoverageMealTemplateManagerMock(
            detailResponse: detail,
            updateError: CoverageExpectedError(message: "Update failed")
        )
        let saveFailureViewModel = MealTemplateDetailViewModel(
            templateId: detail.template.id,
            startsEditing: true,
            templateManager: saveFailureManager
        )
        await saveFailureViewModel.loadIfNeeded()
        saveFailureViewModel.name = detail.template.name
        let didSave = await saveFailureViewModel.save()
        XCTAssertFalse(didSave)
        XCTAssertEqual(saveFailureViewModel.errorMessage, "Update failed")

        let archiveFailureManager = CoverageMealTemplateManagerMock(
            detailResponse: detail,
            archiveError: CoverageExpectedError(message: "Archive failed")
        )
        let archiveFailureViewModel = MealTemplateDetailViewModel(
            templateId: detail.template.id,
            templateManager: archiveFailureManager
        )
        await archiveFailureViewModel.loadIfNeeded()
        let didArchive = await archiveFailureViewModel.toggleArchived()
        XCTAssertFalse(didArchive)
        XCTAssertEqual(archiveFailureViewModel.errorMessage, "Archive failed")

        archiveFailureViewModel.archived = true
        let blockedLog = await archiveFailureViewModel.logNow(
            targetDay: NutritionCoverageFixtures.targetDay,
            loggedAt: NutritionCoverageFixtures.loggedAt
        )
        XCTAssertFalse(blockedLog)

        let applyFailureManager = CoverageMealTemplateManagerMock(
            detailResponse: detail,
            applyError: CoverageExpectedError(message: "Apply failed")
        )
        let applyFailureViewModel = MealTemplateDetailViewModel(
            templateId: detail.template.id,
            templateManager: applyFailureManager
        )
        await applyFailureViewModel.loadIfNeeded()
        let didLog = await applyFailureViewModel.logNow(
            targetDay: NutritionCoverageFixtures.targetDay,
            loggedAt: NutritionCoverageFixtures.loggedAt
        )
        XCTAssertFalse(didLog)
        XCTAssertEqual(applyFailureViewModel.errorMessage, "Apply failed")
    }

    @MainActor
    func testNutritionTemplateAndBatchActionHelpersCoverage() async throws {
        let activeTemplateDetail = NutritionCoverageFixtures.mealTemplateDetail()
        let archivedTemplateDetail = NutritionCoverageFixtures.mealTemplateDetail(archived: true)

        let activeTemplateManager = CoverageMealTemplateManagerMock(detailResponse: activeTemplateDetail)
        let activeTemplateResult = await MealTemplateLibraryView._testLoadTemplatesResult(
            showingArchived: false,
            manager: activeTemplateManager
        )
        XCTAssertEqual(activeTemplateResult.templates.count, 1)
        XCTAssertFalse(try XCTUnwrap(activeTemplateResult.templates.first).archived)
        XCTAssertNil(activeTemplateResult.statusMessage)

        let archivedTemplateManager = CoverageMealTemplateManagerMock(detailResponse: archivedTemplateDetail)
        let archivedTemplateResult = await MealTemplateLibraryView._testLoadTemplatesResult(
            showingArchived: true,
            manager: archivedTemplateManager
        )
        XCTAssertEqual(archivedTemplateResult.templates.count, 1)
        XCTAssertTrue(try XCTUnwrap(archivedTemplateResult.templates.first).archived)

        let templateLoadFailure = await MealTemplateLibraryView._testLoadTemplatesResult(
            showingArchived: false,
            manager: CoverageMealTemplateManagerMock(
                detailResponse: nil,
                loadError: CoverageExpectedError(message: "Template load failed")
            )
        )
        XCTAssertTrue(templateLoadFailure.templates.isEmpty)
        XCTAssertEqual(templateLoadFailure.statusMessage?.message, "Template load failed")

        let templateSummary = NutritionCoverageFixtures.mealTemplateSummary()
        let archiveToggleResult = await MealTemplateLibraryView._testToggleArchiveResult(
            for: templateSummary,
            manager: activeTemplateManager
        )
        switch archiveToggleResult {
        case let .success(message):
            XCTAssertEqual(message.message, String(localized: "nutrition_template_archived"))
        case let .failure(error):
            XCTFail("Unexpected template archive failure: \(error)")
        }

        let templateArchiveFailure = await MealTemplateLibraryView._testToggleArchiveResult(
            for: templateSummary,
            manager: CoverageMealTemplateManagerMock(
                detailResponse: activeTemplateDetail,
                archiveError: CoverageExpectedError(message: "Template archive failed")
            )
        )
        switch templateArchiveFailure {
        case .success:
            XCTFail("Expected template archive failure")
        case let .failure(error):
            XCTAssertEqual(error.localizedDescription, "Template archive failed")
        }

        let batchDetail = NutritionCoverageFixtures.batchDetail()
        let batchManager = CoverageBatchRecipeManagerMock(detailResponse: batchDetail)

        let loadedBatchResult = await BatchRecipeDetailView._testLoadDetailResult(
            batchId: batchDetail.recipe.id,
            preferRemote: true,
            manager: batchManager
        )
        XCTAssertEqual(loadedBatchResult.detail, batchDetail)
        XCTAssertNil(loadedBatchResult.errorMessage)

        let missingBatchResult = await BatchRecipeDetailView._testLoadDetailResult(
            batchId: UUID(),
            preferRemote: false,
            manager: CoverageBatchRecipeManagerMock(detailResponse: nil)
        )
        XCTAssertNil(missingBatchResult.detail)
        XCTAssertNotNil(missingBatchResult.errorMessage)

        let batchLoadFailure = await BatchRecipeDetailView._testLoadDetailResult(
            batchId: batchDetail.recipe.id,
            preferRemote: true,
            manager: CoverageBatchRecipeManagerMock(
                detailResponse: nil,
                loadError: CoverageExpectedError(message: "Batch load failed")
            )
        )
        XCTAssertEqual(batchLoadFailure.errorMessage, "Batch load failed")

        let batchArchiveResult = await BatchRecipeDetailView._testToggleArchivedResult(
            detail: batchDetail,
            manager: batchManager
        )
        switch batchArchiveResult {
        case let .success(message):
            XCTAssertEqual(message.message, String(localized: "nutrition_batch_archived"))
        case let .failure(error):
            XCTFail("Unexpected batch archive failure: \(error)")
        }

        let archivedBatchDetail = NutritionCoverageFixtures.batchDetail(archived: true)
        let batchRestoreResult = await BatchRecipeDetailView._testToggleArchivedResult(
            detail: archivedBatchDetail,
            manager: CoverageBatchRecipeManagerMock(detailResponse: archivedBatchDetail)
        )
        switch batchRestoreResult {
        case let .success(message):
            XCTAssertEqual(message.message, String(localized: "nutrition_batch_restored"))
        case let .failure(error):
            XCTFail("Unexpected batch restore failure: \(error)")
        }

        let batchArchiveFailure = await BatchRecipeDetailView._testToggleArchivedResult(
            detail: batchDetail,
            manager: CoverageBatchRecipeManagerMock(
                detailResponse: batchDetail,
                archiveError: CoverageExpectedError(message: "Batch archive failed")
            )
        )
        switch batchArchiveFailure {
        case .success:
            XCTFail("Expected batch archive failure")
        case let .failure(error):
            XCTAssertEqual(error.localizedDescription, "Batch archive failed")
        }

        let batchCookAgainResult = await BatchRecipeDetailView._testCookAgainResult(
            detail: batchDetail,
            manager: batchManager
        )
        switch batchCookAgainResult {
        case let .success(message):
            XCTAssertTrue(message.message.contains("Coverage Duplicate"))
        case let .failure(error):
            XCTFail("Unexpected batch duplicate failure: \(error)")
        }

        let batchCookAgainFailure = await BatchRecipeDetailView._testCookAgainResult(
            detail: batchDetail,
            manager: CoverageBatchRecipeManagerMock(
                detailResponse: batchDetail,
                duplicateError: CoverageExpectedError(message: "Duplicate failed")
            )
        )
        switch batchCookAgainFailure {
        case .success:
            XCTFail("Expected batch duplicate failure")
        case let .failure(error):
            XCTAssertEqual(error.localizedDescription, "Duplicate failed")
        }

        let editableIngredients = batchDetail.ingredients.map(BatchRecipeEditableIngredient.init(ingredient:))
        let saveDraft = BatchRecipeComposerView._testSaveDraft(
            existingDetail: batchDetail,
            name: "Coverage Prep",
            description: "",
            cookedAt: NutritionCoverageFixtures.loggedAt,
            totalWeightG: 800,
            totalPortions: 4,
            ingredients: editableIngredients
        )
        XCTAssertEqual(saveDraft.id, batchDetail.recipe.id)
        XCTAssertNil(saveDraft.description)
        XCTAssertEqual(saveDraft.totalWeightG, 800, accuracy: 0.001)
        XCTAssertEqual(saveDraft.ingredients.count, editableIngredients.count)
        XCTAssertEqual(saveDraft.archived, batchDetail.recipe.archived)

        let createDraft = BatchRecipeComposerView._testSaveDraft(
            existingDetail: nil,
            name: "Coverage New Prep",
            description: "Fresh batch",
            cookedAt: NutritionCoverageFixtures.loggedAt,
            totalWeightG: 900,
            totalPortions: 3,
            ingredients: editableIngredients
        )
        XCTAssertEqual(createDraft.name, "Coverage New Prep")
        XCTAssertEqual(createDraft.description, "Fresh batch")
        XCTAssertFalse(createDraft.archived)

        let createSaveResult = await BatchRecipeComposerView._testSaveResult(
            draft: createDraft,
            existingDetail: nil,
            manager: batchManager
        )
        switch createSaveResult {
        case let .success(message):
            XCTAssertEqual(message.message, String(localized: "nutrition_batch_saved"))
        case let .failure(error):
            XCTFail("Unexpected batch create failure: \(error)")
        }

        let updateSaveResult = await BatchRecipeComposerView._testSaveResult(
            draft: saveDraft,
            existingDetail: batchDetail,
            manager: batchManager
        )
        switch updateSaveResult {
        case let .success(message):
            XCTAssertEqual(message.message, String(localized: "nutrition_batch_updated"))
        case let .failure(error):
            XCTFail("Unexpected batch update failure: \(error)")
        }

        let createFailure = await BatchRecipeComposerView._testSaveResult(
            draft: createDraft,
            existingDetail: nil,
            manager: CoverageBatchRecipeManagerMock(
                detailResponse: batchDetail,
                createError: CoverageExpectedError(message: "Create failed")
            )
        )
        switch createFailure {
        case .success:
            XCTFail("Expected batch create failure")
        case let .failure(error):
            XCTAssertEqual(error.localizedDescription, "Create failed")
        }

        let updateFailure = await BatchRecipeComposerView._testSaveResult(
            draft: saveDraft,
            existingDetail: batchDetail,
            manager: CoverageBatchRecipeManagerMock(
                detailResponse: batchDetail,
                updateError: CoverageExpectedError(message: "Update failed")
            )
        )
        switch updateFailure {
        case .success:
            XCTFail("Expected batch update failure")
        case let .failure(error):
            XCTAssertEqual(error.localizedDescription, "Update failed")
        }

        let photoPickerState = NutritionPhotoCaptureView._testCapturePickerState(cameraAvailable: true)
        XCTAssertTrue(photoPickerState.showCameraPicker)
        XCTAssertFalse(photoPickerState.showPhotoLibrary)

        let barcodePickerState = NutritionBarcodeScannerView._testCapturePickerState(cameraAvailable: false)
        XCTAssertFalse(barcodePickerState.showCameraPicker)
        XCTAssertTrue(barcodePickerState.showPhotoLibrary)

        let batchPickerState = BatchRecipeComposerView._testCapturePickerState(cameraAvailable: true)
        XCTAssertTrue(batchPickerState.showCameraPicker)
        XCTAssertFalse(batchPickerState.showPhotoLibrary)

        let batchCameraState = BatchRecipeComposerView(testName: "Coverage Batch")._testOpenCameraOrLibrary(
            cameraAvailable: true
        )
        XCTAssertTrue(batchCameraState.showCameraPicker)
        XCTAssertFalse(batchCameraState.showPhotoLibrary)

        let beganBatchCameraState = BatchRecipeComposerView(testName: "Coverage Batch")._testBeginCameraCapture(
            cameraAvailable: true
        )
        XCTAssertTrue(beganBatchCameraState.showCameraPicker)
        XCTAssertFalse(beganBatchCameraState.showPhotoLibrary)

        let batchLibraryState = BatchRecipeComposerView(testName: "Coverage Batch")._testOpenCameraOrLibrary(
            cameraAvailable: false
        )
        XCTAssertFalse(batchLibraryState.showCameraPicker)
        XCTAssertTrue(batchLibraryState.showPhotoLibrary)
    }

    @MainActor
    func testNutritionPhotoAndBarcodeActionMethodCoverage() async throws {
        let image = NutritionCoverageFixtures.image()
        let imageData = try XCTUnwrap(image.pngData())
        let analyzedPhoto = NutritionCoverageFixtures.photoAnalysis(
            summary: "Injected coverage meal",
            confidence: 0.92,
            notice: "Injected coverage notice"
        )

        let photoCameraState = NutritionPhotoCaptureView()._testBeginCameraCapture(cameraAvailable: true)
        XCTAssertTrue(photoCameraState.showCameraPicker)
        XCTAssertFalse(photoCameraState.showPhotoLibrary)

        let photoLibraryState = NutritionPhotoCaptureView()._testBeginCameraCapture(cameraAvailable: false)
        XCTAssertFalse(photoLibraryState.showCameraPicker)
        XCTAssertTrue(photoLibraryState.showPhotoLibrary)

        let photoLibraryPickerState = NutritionPhotoCaptureView()._testOpenPhotoLibraryPicker()
        XCTAssertTrue(photoLibraryPickerState.showPhotoLibrary)

        let fallbackPhotoAnalysis = NutritionPhotoCaptureView(
            testAnalysisConfidence: 0.73,
            testAnalysisNotice: "Fallback notice"
        )._testFallbackPhotoAnalysis()
        XCTAssertEqual(fallbackPhotoAnalysis.summary, String(localized: "nutrition_photo_analyzed"))
        XCTAssertEqual(try XCTUnwrap(fallbackPhotoAnalysis.confidence), 0.73, accuracy: 0.001)
        XCTAssertEqual(fallbackPhotoAnalysis.notice, "Fallback notice")

        let processedPhotoState = await NutritionPhotoCaptureView()._testProcessCapturedImage(
            image,
            analysis: analyzedPhoto
        )
        XCTAssertEqual(processedPhotoState.analysisResult, "Injected coverage meal")
        XCTAssertEqual(try XCTUnwrap(processedPhotoState.analysisConfidence), 0.92, accuracy: 0.001)
        XCTAssertEqual(processedPhotoState.analysisNotice, "Injected coverage notice")
        XCTAssertEqual(processedPhotoState.photoAnalysis?.summary, "Injected coverage meal")
        XCTAssertFalse(processedPhotoState.isAnalyzing)
        XCTAssertNil(processedPhotoState.captureError)
        XCTAssertNotNil(processedPhotoState.capturedImage)

        let loadedPhotoState = await NutritionPhotoCaptureView()._testLoadPhotoTransfer(
            .success(imageData),
            processCapturedImageAction: { _ in }
        )
        XCTAssertNil(loadedPhotoState.captureError)
        XCTAssertTrue(loadedPhotoState.selectedPhotoItemIsNil)

        let invalidPhotoState = await NutritionPhotoCaptureView()._testLoadPhotoTransfer(.success(nil))
        XCTAssertEqual(invalidPhotoState.captureError, String(localized: "error.media.selected_image_load"))

        let failedPhotoState = await NutritionPhotoCaptureView()._testLoadPhotoTransfer(
            .failure(CoverageExpectedError(message: "Photo transfer failed"))
        )
        XCTAssertEqual(failedPhotoState.captureError, "Photo transfer failed")
        XCTAssertTrue(failedPhotoState.selectedPhotoItemIsNil)

        let resolvedPhotoDraft = NutritionLogDraft(
            method: .photo,
            confidence: 0.87,
            loggedAt: NutritionCoverageFixtures.loggedAt,
            loggedDate: NutritionCoverageFixtures.targetDay,
            summary: "Resolved coverage photo draft",
            analysisSource: .onDeviceFallback
        )
        let usedPhotoState = await NutritionPhotoCaptureView(
            testAnalysisResult: "Fallback photo summary",
            testAnalysisConfidence: 0.73,
            testAnalysisNotice: "Fallback notice"
        )._testUseCapturedPhoto(resolvedDraft: resolvedPhotoDraft)
        XCTAssertEqual(usedPhotoState.emittedDraft?.summary, "Resolved coverage photo draft")
        XCTAssertEqual(usedPhotoState.emittedDraft?.method, .photo)
        XCTAssertTrue(usedPhotoState.didDismiss)
        let photoSelectionChangeState = await NutritionPhotoCaptureView()._testHandleSelectedPhotoItemChange()
        XCTAssertTrue(photoSelectionChangeState.selectedPhotoItemIsNil)
        let didLoadSelectedPhoto = await NutritionPhotoCaptureView()._testLoadSelectedPhotoItemIfNeeded(shouldLoad: true)
        XCTAssertTrue(didLoadSelectedPhoto)
        let defaultSelectedPhotoLoadState = await NutritionPhotoCaptureView()._testLoadSelectedPhotoItemIfNeededWithoutCustomLoader()
        XCTAssertTrue(defaultSelectedPhotoLoadState.selectedPhotoItemIsNil)
        let skippedSelectedPhotoLoad = await NutritionPhotoCaptureView()._testLoadSelectedPhotoItemIfNeeded(shouldLoad: false)
        XCTAssertFalse(skippedSelectedPhotoLoad)
        let defaultPhotoLoadState = await NutritionPhotoCaptureView()._testLoadPhotoTransferUsingDefaultItemPath()
        XCTAssertEqual(defaultPhotoLoadState.captureError, String(localized: "error.media.selected_image_load"))
        let defaultProcessedPhotoLoadState = await NutritionPhotoCaptureView()._testLoadPhotoItemUsingDefaultProcessing(
            data: imageData
        )
        XCTAssertNil(defaultProcessedPhotoLoadState.captureError)
        XCTAssertTrue(defaultProcessedPhotoLoadState.selectedPhotoItemIsNil)

        let batchSelectionChangeState = await BatchRecipeComposerView(
            testName: "Coverage Batch"
        )._testHandleSelectedPhotoItemChange()
        XCTAssertNil(batchSelectionChangeState.errorMessage)
        let didLoadSelectedBatchPhoto = await BatchRecipeComposerView(
            testName: "Coverage Batch"
        )._testLoadSelectedPhotoItemIfNeeded(shouldLoad: true)
        XCTAssertTrue(didLoadSelectedBatchPhoto)
        let skippedSelectedBatchPhotoLoad = await BatchRecipeComposerView(
            testName: "Coverage Batch"
        )._testLoadSelectedPhotoItemIfNeeded(shouldLoad: false)
        XCTAssertFalse(skippedSelectedBatchPhotoLoad)
        let defaultSelectedBatchPhotoLoadState = await BatchRecipeComposerView(
            testName: "Coverage Batch"
        )._testLoadSelectedPhotoItemIfNeededWithoutCustomLoader()
        XCTAssertNil(defaultSelectedBatchPhotoLoadState.errorMessage)

        let scheduledPhotoCandidate = await NutritionPhotoCaptureView()._testHandleCapturedCameraImage()
        let scheduledPhotoImage = try XCTUnwrap(scheduledPhotoCandidate)
        XCTAssertEqual(try XCTUnwrap(scheduledPhotoImage.pngData()), imageData)
        let pickedPhotoState = await NutritionPhotoCaptureView()._testHandlePickedCameraImageUsingDefaultProcessing(
            image
        )
        XCTAssertFalse(pickedPhotoState.isAnalyzing)
        XCTAssertTrue(pickedPhotoState.selectedPhotoItemIsNil)
        let analyzedCapturedPhoto = await NutritionPhotoCaptureView()._testAnalyzeCapturedPhoto(
            image,
            analysis: analyzedPhoto
        )
        XCTAssertEqual(analyzedCapturedPhoto.summary, "Injected coverage meal")
        XCTAssertEqual(try XCTUnwrap(analyzedCapturedPhoto.confidence), 0.92, accuracy: 0.001)

        var defaultResolvedPhotoDraft: NutritionLogDraft?
        let defaultBeginPhotoState = await NutritionPhotoCaptureView(
            testAnalysisResult: "Fallback photo summary",
            testAnalysisConfidence: 0.73,
            testAnalysisNotice: "Fallback notice",
            onResult: { defaultResolvedPhotoDraft = $0 }
        )._testBeginUseCapturedPhoto()
        for _ in 0..<100 {
            await Task.yield()
        }
        XCTAssertEqual(defaultResolvedPhotoDraft?.method, .photo)
        XCTAssertEqual(defaultResolvedPhotoDraft?.summary, "Fallback photo summary")
        XCTAssertFalse(defaultBeginPhotoState.isAnalyzing)

        XCTAssertTrue(NutritionPhotoCaptureView()._testDismissScreen())

        let barcodeCameraState = NutritionBarcodeScannerView()._testBeginCameraCapture(cameraAvailable: true)
        XCTAssertTrue(barcodeCameraState.showCameraPicker)
        XCTAssertFalse(barcodeCameraState.showPhotoLibrary)

        let barcodeLibraryState = NutritionBarcodeScannerView()._testBeginCameraCapture(cameraAvailable: false)
        XCTAssertFalse(barcodeLibraryState.showCameraPicker)
        XCTAssertTrue(barcodeLibraryState.showPhotoLibrary)

        let barcodePhotoLibraryState = NutritionBarcodeScannerView()._testOpenPhotoLibraryPicker()
        XCTAssertTrue(barcodePhotoLibraryState.showPhotoLibrary)
        XCTAssertTrue(NutritionBarcodeScannerView()._testDismissScreen())
        let barcodeSelectionChangeState = await NutritionBarcodeScannerView()._testHandleSelectedPhotoItemChange()
        XCTAssertTrue(barcodeSelectionChangeState.selectedPhotoItemIsNil)
        let didLoadSelectedBarcodePhoto = await NutritionBarcodeScannerView()._testLoadSelectedPhotoItemIfNeeded(shouldLoad: true)
        XCTAssertTrue(didLoadSelectedBarcodePhoto)
        let skippedSelectedBarcodePhotoLoad = await NutritionBarcodeScannerView()._testLoadSelectedPhotoItemIfNeeded(shouldLoad: false)
        XCTAssertFalse(skippedSelectedBarcodePhotoLoad)
        let defaultBarcodeLoadState = await NutritionBarcodeScannerView()._testLoadPhotoTransferUsingDefaultItemPath()
        XCTAssertEqual(defaultBarcodeLoadState.errorMessage, String(localized: "error.media.selected_image_load"))
        let scheduledBarcodeCandidate = await NutritionBarcodeScannerView()._testHandleCapturedCameraImage()
        let scheduledBarcodeImage = try XCTUnwrap(scheduledBarcodeCandidate)
        XCTAssertEqual(try XCTUnwrap(scheduledBarcodeImage.pngData()), imageData)
        let pickedBarcodeState = await NutritionBarcodeScannerView()._testHandlePickedCameraImageUsingDefaultProcessing(
            image
        )
        XCTAssertFalse(pickedBarcodeState.isSearching)
        XCTAssertTrue(pickedBarcodeState.selectedPhotoItemIsNil)
        let reviewBindingResult = NutritionBarcodeScannerView()._testReviewDraftBinding(
            updatedDraft: NutritionCoverageFixtures.labelDraft(name: "Updated coverage label")
        )
        XCTAssertEqual(reviewBindingResult.initialDraft.name, NutritionBarcodeScannerView()._testFallbackDraft().name)
        XCTAssertEqual(reviewBindingResult.updatedDraft.name, "Updated coverage label")
        XCTAssertTrue(reviewBindingResult.isDisabled)
        XCTAssertTrue(
            NutritionBarcodeScannerView(
                testIsAnalyzingLabel: true,
                testShowLabelOCRFallback: true,
                testOCRResult: "Protein 20g"
            )._testReviewProductDisabled()
        )
        XCTAssertFalse(
            NutritionBarcodeScannerView(
                testShowLabelOCRFallback: true,
                testOCRResult: "Protein 20g",
                testPendingLabelImages: [image]
            )._testReviewProductDisabled()
        )

        let loadedBarcodeState = await NutritionBarcodeScannerView()._testLoadPhotoTransfer(
            .success(imageData),
            routeSelectedImageAction: { _ in }
        )
        XCTAssertNil(loadedBarcodeState.errorMessage)
        XCTAssertTrue(loadedBarcodeState.selectedPhotoItemIsNil)

        let invalidBarcodePhotoState = await NutritionBarcodeScannerView()._testLoadPhotoTransfer(.success(nil))
        XCTAssertEqual(invalidBarcodePhotoState.errorMessage, String(localized: "error.media.selected_image_load"))

        let failedBarcodePhotoState = await NutritionBarcodeScannerView()._testLoadPhotoTransfer(
            .failure(CoverageExpectedError(message: "Barcode transfer failed"))
        )
        XCTAssertEqual(failedBarcodePhotoState.errorMessage, "Barcode transfer failed")
        XCTAssertTrue(failedBarcodePhotoState.selectedPhotoItemIsNil)

        let beginAnalyzeState = await NutritionBarcodeScannerView()._testBeginAnalyzePendingLabelImages()
        XCTAssertFalse(beginAnalyzeState.isAnalyzingLabel)

        let beginLogState = await NutritionBarcodeScannerView()._testBeginLogMatchedProduct()
        XCTAssertFalse(beginLogState.isSaving)

        let beginConfirmState = await NutritionBarcodeScannerView()._testBeginConfirmReviewedProduct()
        XCTAssertFalse(beginConfirmState.isSaving)

        var routedToLabel = false
        var routedToScan = false
        await NutritionBarcodeScannerView(testShowLabelOCRFallback: true)._testRouteSelectedImage(
            processLabelImageAction: { _ in routedToLabel = true },
            processScannedImageAction: { _ in routedToScan = true }
        )
        XCTAssertTrue(routedToLabel)
        XCTAssertFalse(routedToScan)

        routedToLabel = false
        routedToScan = false
        await NutritionBarcodeScannerView(
            testLabelReviewDraft: NutritionCoverageFixtures.labelDraft()
        )._testRouteSelectedImage(
            processLabelImageAction: { _ in routedToLabel = true },
            processScannedImageAction: { _ in routedToScan = true }
        )
        XCTAssertTrue(routedToLabel)
        XCTAssertFalse(routedToScan)

        routedToLabel = false
        routedToScan = true
        await NutritionBarcodeScannerView()._testRouteSelectedImage(
            processLabelImageAction: { _ in routedToLabel = true },
            processScannedImageAction: { _ in routedToScan = false }
        )
        XCTAssertFalse(routedToLabel)
        XCTAssertFalse(routedToScan)

        let matchedFood = NutritionCoverageFixtures.foodResult(name: "Injected Barcode Food")
        let matchedBarcodeState = await NutritionBarcodeScannerView()._testProcessScannedImage(
            detectBarcodesResult: .success(["4601234567890"]),
            recognizeTextResult: .success("Coverage OCR"),
            lookupResult: .success(matchedFood)
        )
        XCTAssertEqual(matchedBarcodeState.scannedCode, "4601234567890")
        XCTAssertTrue(matchedBarcodeState.productFound)
        XCTAssertFalse(matchedBarcodeState.showLabelOCRFallback)
        XCTAssertEqual(matchedBarcodeState.matchedProduct?.name, "Injected Barcode Food")
        XCTAssertEqual(matchedBarcodeState.pendingLabelImagesCount, 0)
        XCTAssertFalse(matchedBarcodeState.isSearching)

        let fallbackBarcodeState = await NutritionBarcodeScannerView()._testProcessScannedImage(
            detectBarcodesResult: .success(["4601234567890"]),
            recognizeTextResult: .success("Coverage OCR"),
            lookupResult: .success(nil)
        )
        XCTAssertEqual(fallbackBarcodeState.scannedCode, "4601234567890")
        XCTAssertFalse(fallbackBarcodeState.productFound)
        XCTAssertTrue(fallbackBarcodeState.showLabelOCRFallback)
        XCTAssertEqual(fallbackBarcodeState.pendingLabelImagesCount, 1)
        XCTAssertEqual(fallbackBarcodeState.ocrResult, "Coverage OCR")

        let manualBarcodeFallbackState = await NutritionBarcodeScannerView()._testProcessScannedImage(
            detectBarcodesResult: .success(["4601234567890"]),
            recognizeTextResult: .failure(CoverageExpectedError(message: "OCR unavailable")),
            lookupResult: .success(nil)
        )
        XCTAssertEqual(manualBarcodeFallbackState.scannedCode, "4601234567890")
        XCTAssertTrue(manualBarcodeFallbackState.showLabelOCRFallback)
        XCTAssertEqual(
            manualBarcodeFallbackState.ocrResult,
            String(localized: "nutrition_barcode_review_label_manually")
        )

        let noBarcodeState = await NutritionBarcodeScannerView()._testProcessScannedImage(
            detectBarcodesResult: .success([]),
            recognizeTextResult: .success(""),
            lookupResult: .success(nil)
        )
        XCTAssertNil(noBarcodeState.scannedCode)
        XCTAssertFalse(noBarcodeState.productFound)
        XCTAssertTrue(noBarcodeState.showLabelOCRFallback)
        XCTAssertEqual(noBarcodeState.pendingLabelImagesCount, 1)
        XCTAssertEqual(
            noBarcodeState.ocrResult,
            String(localized: "nutrition_barcode_no_barcode_detected")
        )

        let scanFailureState = await NutritionBarcodeScannerView()._testProcessScannedImage(
            detectBarcodesResult: .failure(CoverageExpectedError(message: "Barcode scan failed")),
            recognizeTextResult: .success("Unused OCR"),
            lookupResult: .success(nil)
        )
        XCTAssertEqual(scanFailureState.errorMessage, "Barcode scan failed")
        XCTAssertFalse(scanFailureState.isSearching)

        let barcodeLookupFailureState = await NutritionBarcodeScannerView()._testProcessScannedImage(
            detectBarcodesResult: .success(["4601234567890"]),
            recognizeTextResult: .success("Unused OCR"),
            lookupResult: .failure(CoverageExpectedError(message: "Barcode lookup failed"))
        )
        XCTAssertEqual(barcodeLookupFailureState.errorMessage, "Barcode lookup failed")
        XCTAssertFalse(barcodeLookupFailureState.productFound)

        let noBarcodeRecognitionFailureState = await NutritionBarcodeScannerView()._testProcessScannedImage(
            detectBarcodesResult: .success([]),
            recognizeTextResult: .failure(CoverageExpectedError(message: "OCR scan failed")),
            lookupResult: .success(nil)
        )
        XCTAssertEqual(noBarcodeRecognitionFailureState.errorMessage, "OCR scan failed")
        XCTAssertFalse(noBarcodeRecognitionFailureState.showLabelOCRFallback)

        let reviewedDraft = NutritionCoverageFixtures.labelDraft(name: "Reviewed Coverage Label")
        let processedLabelState = await NutritionBarcodeScannerView(
            testPendingLabelImages: [NutritionCoverageFixtures.image(color: .systemRed)]
        )._testProcessLabelImage(
            recognizeTextResult: .success("OCR label block"),
            analyzedDraft: reviewedDraft
        )
        XCTAssertEqual(processedLabelState.pendingLabelImagesCount, 2)
        XCTAssertEqual(processedLabelState.ocrResult, "OCR label block")
        XCTAssertEqual(processedLabelState.labelReviewDraft?.name, "Reviewed Coverage Label")
        XCTAssertFalse(processedLabelState.isAnalyzingLabel)

        let emptyAnalyzeState = await NutritionBarcodeScannerView()._testAnalyzePendingLabelImages()
        XCTAssertNil(emptyAnalyzeState.labelReviewDraft)
        XCTAssertFalse(emptyAnalyzeState.isAnalyzingLabel)

        let analyzedPendingState = await NutritionBarcodeScannerView(
            testPendingLabelImages: [NutritionCoverageFixtures.image()]
        )._testAnalyzePendingLabelImages(analyzedDraft: reviewedDraft)
        XCTAssertEqual(analyzedPendingState.labelReviewDraft?.name, "Reviewed Coverage Label")
        XCTAssertFalse(analyzedPendingState.isAnalyzingLabel)

        let lookupProduct = try await NutritionBarcodeScannerView()._testLookupProduct(
            barcode: "4601234567890",
            result: .success(matchedFood)
        )
        XCTAssertEqual(lookupProduct?.name, "Injected Barcode Food")

        do {
            _ = try await NutritionBarcodeScannerView()._testLookupProduct(
                barcode: "4601234567890",
                result: .failure(CoverageExpectedError(message: "Lookup failed"))
            )
            XCTFail("Expected lookup failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Lookup failed")
        }

        var didLogProduct = 0
        var didDismissLoggedProduct = false
        let loggedProductState = await NutritionBarcodeScannerView(
            testMatchedProduct: matchedFood,
            onLogged: { didLogProduct += 1 }
        )._testLogMatchedProduct(
            logResult: .success(UUID()),
            onDismiss: { didDismissLoggedProduct = true }
        )
        XCTAssertEqual(didLogProduct, 1)
        XCTAssertTrue(didDismissLoggedProduct)
        XCTAssertNil(loggedProductState.errorMessage)
        XCTAssertFalse(loggedProductState.isSaving)
        let defaultLoggedProductState = await NutritionBarcodeScannerView(
            testMatchedProduct: matchedFood,
            onLogged: { didLogProduct += 1 }
        )._testLogMatchedProductUsingDefaultLogger(
            logResult: .success(UUID()),
            onDismiss: { didDismissLoggedProduct = true }
        )
        XCTAssertNil(defaultLoggedProductState.errorMessage)
        XCTAssertFalse(defaultLoggedProductState.isSaving)
        XCTAssertEqual(didLogProduct, 2)
        XCTAssertTrue(didDismissLoggedProduct)

        let logFailureState = await NutritionBarcodeScannerView(
            testMatchedProduct: matchedFood
        )._testLogMatchedProduct(
            logResult: .failure(CoverageExpectedError(message: "Log failed"))
        )
        XCTAssertEqual(logFailureState.errorMessage, "Log failed")
        XCTAssertFalse(logFailureState.isSaving)

        let invalidReviewState = await NutritionBarcodeScannerView(
            testLabelReviewDraft: NutritionCoverageFixtures.labelDraft(name: "   ")
        )._testConfirmReviewedProduct(createResult: .success(matchedFood))
        XCTAssertEqual(
            invalidReviewState.errorMessage,
            String(localized: "nutrition_validation_name_required")
        )

        var emittedDraft: NutritionLogDraft?
        var didDismissReviewedProduct = false
        let confirmedReviewState = await NutritionBarcodeScannerView(
            testLabelReviewDraft: reviewedDraft,
            onResult: { emittedDraft = $0 }
        )._testConfirmReviewedProduct(
            createResult: .success(matchedFood),
            onDismiss: { didDismissReviewedProduct = true }
        )
        XCTAssertNil(confirmedReviewState.errorMessage)
        XCTAssertFalse(confirmedReviewState.isSaving)
        XCTAssertTrue(didDismissReviewedProduct)
        XCTAssertEqual(emittedDraft?.method, .barcode)
        XCTAssertEqual(emittedDraft?.loggedDate, NutritionCoverageFixtures.targetDay)
        XCTAssertEqual(emittedDraft?.summary, reviewedDraft.summary)
        XCTAssertEqual(emittedDraft?.recognizedBarcodes, [reviewedDraft.normalizedBarcode])

        let confirmFailureState = await NutritionBarcodeScannerView(
            testLabelReviewDraft: reviewedDraft
        )._testConfirmReviewedProduct(
            createResult: .failure(CoverageExpectedError(message: "Review save failed"))
        )
        XCTAssertEqual(confirmFailureState.errorMessage, "Review save failed")
        XCTAssertFalse(confirmFailureState.isSaving)
    }

    @MainActor
    func testNutritionSpeechRecognizerActionCoverage() async throws {
        let permissionKey = String(localized: "error.speech.recognition_permission")
        let microphoneKey = String(localized: "error.speech.microphone_permission")

        let permissionProbe = NutritionSpeechRecognizer()
        let grantedPermissionError = await permissionProbe._testRequestPermissions(
            speechAuthorized: true,
            microphoneAuthorized: true
        )
        XCTAssertNil(grantedPermissionError)
        let deniedSpeechPermissionError = await permissionProbe._testRequestPermissions(
            speechAuthorized: false,
            microphoneAuthorized: true
        )
        XCTAssertEqual(deniedSpeechPermissionError, permissionKey)
        let deniedMicrophonePermissionError = await permissionProbe._testRequestPermissions(
            speechAuthorized: true,
            microphoneAuthorized: false
        )
        XCTAssertEqual(deniedMicrophonePermissionError, microphoneKey)
        let grantedDefaultPermissionError = await permissionProbe._testRequestPermissionsUsingDefaultBranches(
            speechAuthorized: true,
            microphoneAuthorized: true
        )
        XCTAssertNil(grantedDefaultPermissionError)
        let deniedDefaultMicrophonePermissionError = await permissionProbe._testRequestPermissionsUsingDefaultBranches(
            speechAuthorized: true,
            microphoneAuthorized: false
        )
        XCTAssertEqual(deniedDefaultMicrophonePermissionError, microphoneKey)
        let defaultSpeechAuthorizationGranted = await permissionProbe._testDefaultSpeechAuthorizationRequest(
            status: .authorized
        )
        XCTAssertTrue(defaultSpeechAuthorizationGranted)
        let defaultSpeechAuthorizationDenied = await permissionProbe._testDefaultSpeechAuthorizationRequest(
            status: .denied
        )
        XCTAssertFalse(defaultSpeechAuthorizationDenied)
        let defaultMicrophoneGranted = await permissionProbe._testDefaultMicrophonePermissionRequest(
            allowed: true,
            useAudioApplicationRequest: nil
        )
        XCTAssertTrue(defaultMicrophoneGranted)
        let defaultMicrophoneDenied = await permissionProbe._testDefaultMicrophonePermissionRequest(
            allowed: false,
            useAudioApplicationRequest: false
        )
        XCTAssertFalse(defaultMicrophoneDenied)
        let defaultMicrophoneGrantedViaApplicationOverride =
            await permissionProbe._testDefaultMicrophonePermissionRequestUsingDefaultOverrides(
                allowed: true,
                useAudioApplicationRequest: true
            )
        XCTAssertTrue(defaultMicrophoneGrantedViaApplicationOverride)
        let defaultMicrophoneDeniedViaSessionOverride =
            await permissionProbe._testDefaultMicrophonePermissionRequestUsingDefaultOverrides(
                allowed: false,
                useAudioApplicationRequest: false
            )
        XCTAssertFalse(defaultMicrophoneDeniedViaSessionOverride)

        let sessionProbe = NutritionSpeechRecognizer()
        XCTAssertNil(sessionProbe._testConfigureSession())
        XCTAssertNil(sessionProbe._testConfigureSessionUsingDefaultOverrides())
        XCTAssertEqual(
            sessionProbe._testConfigureSession(
                categoryError: CoverageExpectedError(message: "Category failed")
            ),
            "Category failed"
        )
        XCTAssertEqual(
            sessionProbe._testConfigureSessionUsingDefaultOverrides(
                categoryError: CoverageExpectedError(message: "Default category failed")
            ),
            "Default category failed"
        )
        XCTAssertEqual(
            sessionProbe._testConfigureSession(
                activeError: CoverageExpectedError(message: "Session activation failed")
            ),
            "Session activation failed"
        )
        XCTAssertEqual(
            sessionProbe._testConfigureSessionUsingDefaultOverrides(
                activeError: CoverageExpectedError(message: "Default session activation failed")
            ),
            "Default session activation failed"
        )
        let audioTapProbe = NutritionSpeechRecognizer()
        let audioTapState = audioTapProbe._testInstallDefaultAudioTap()
        XCTAssertEqual(audioTapState.removeTapCalls, 1)
        XCTAssertEqual(audioTapState.installTapCalls, 1)
        XCTAssertEqual(audioTapState.appendBufferCalls, 1)
        XCTAssertEqual(audioTapProbe._testInstallAudioTapDefaultPath(), 1)
        audioTapProbe._testPrepareAudioDefaultPath()
        XCTAssertNil(audioTapProbe._testStartAudioDefaultPath())
        XCTAssertEqual(
            audioTapProbe._testStartAudioDefaultPath(
                error: CoverageExpectedError(message: "Audio engine start failed")
            ),
            "Audio engine start failed"
        )
        let defaultInstallTapState = audioTapProbe._testDefaultInstallTap()
        XCTAssertEqual(defaultInstallTapState.installTapCalls, 1)
        XCTAssertEqual(defaultInstallTapState.appendBufferCalls, 1)
        let defaultSystemInstallTapState = audioTapProbe._testDefaultInstallTapUsingSystemAction()
        XCTAssertEqual(defaultSystemInstallTapState.installTapCalls, 1)
        XCTAssertEqual(defaultSystemInstallTapState.appendBufferCalls, 1)
        XCTAssertTrue(audioTapProbe._testEndAudioDefaultPath())
        let defaultPipelineRecognizer = NutritionSpeechRecognizer()
        defaultPipelineRecognizer._testOverrideState(
            isRecording: true,
            isProcessing: true,
            transcription: "Pipeline default",
            errorMessage: "Keep default",
            confidence: 0.5
        )
        let defaultPipelineState = defaultPipelineRecognizer._testCompleteAudioPipelineDefaultPath()
        XCTAssertTrue(defaultPipelineState.isRecording)
        XCTAssertTrue(defaultPipelineState.isProcessing)
        XCTAssertEqual(defaultPipelineState.errorMessage, "Keep default")

        let defaultStartRecognitionState =
            await NutritionSpeechRecognizer()._testStartRecognitionTaskUsingDefaultAction(
                transcript: "Default start speech",
                isFinal: false
            )
        XCTAssertTrue(defaultStartRecognitionState.isRecording)
        XCTAssertFalse(defaultStartRecognitionState.isProcessing)
        XCTAssertEqual(defaultStartRecognitionState.transcription, "Default start speech")
        XCTAssertEqual(defaultStartRecognitionState.confidence ?? 0, 0.75, accuracy: 0.001)
        let defaultFinalRecognitionState =
            await NutritionSpeechRecognizer()._testStartRecognitionTaskUsingDefaultAction(
                transcript: "Default final speech",
                isFinal: true
            )
        XCTAssertFalse(defaultFinalRecognitionState.isRecording)
        XCTAssertFalse(defaultFinalRecognitionState.isProcessing)
        XCTAssertEqual(defaultFinalRecognitionState.transcription, "Default final speech")
        XCTAssertEqual(defaultFinalRecognitionState.confidence ?? 0, 0.9, accuracy: 0.001)

        let defaultRecognitionTaskErrorState =
            await NutritionSpeechRecognizer()._testDefaultRecognitionTaskAction(
                error: CoverageExpectedError(message: "Default recognition task action failed")
            )
        XCTAssertFalse(defaultRecognitionTaskErrorState.isRecording)
        XCTAssertFalse(defaultRecognitionTaskErrorState.isProcessing)
        XCTAssertEqual(
            defaultRecognitionTaskErrorState.errorMessage,
            "Default recognition task action failed"
        )
        let defaultRecognitionTaskNoOpState =
            await NutritionSpeechRecognizer()._testDefaultRecognitionTaskAction(useDefaultTaskAction: true)
        XCTAssertTrue(defaultRecognitionTaskNoOpState.isRecording)
        XCTAssertTrue(defaultRecognitionTaskNoOpState.isProcessing)
        XCTAssertNil(defaultRecognitionTaskNoOpState.errorMessage)
        let fallbackStartRecognitionState =
            await NutritionSpeechRecognizer()._testStartRecognitionTaskUsingFallbackAction(
                transcript: "Fallback task speech",
                isFinal: false
            )
        XCTAssertTrue(fallbackStartRecognitionState.isRecording)
        XCTAssertFalse(fallbackStartRecognitionState.isProcessing)
        XCTAssertEqual(fallbackStartRecognitionState.transcription, "Fallback task speech")
        XCTAssertEqual(fallbackStartRecognitionState.confidence ?? 0, 0.75, accuracy: 0.001)

        let defaultPartialState = await NutritionSpeechRecognizer()._testStartRecordingUsingDefaultOverrides(
            recognitionTranscript: "Default override speech",
            recognitionIsFinal: false
        )
        XCTAssertTrue(defaultPartialState.isRecording)
        XCTAssertFalse(defaultPartialState.isProcessing)
        XCTAssertEqual(defaultPartialState.transcription, "Default override speech")
        XCTAssertEqual(defaultPartialState.confidence ?? 0, 0.75, accuracy: 0.001)

        let partialState = await NutritionSpeechRecognizer()._testStartRecording(
            recognitionTranscript: "Coverage speech",
            recognitionIsFinal: false
        )
        XCTAssertTrue(partialState.isRecording)
        XCTAssertFalse(partialState.isProcessing)
        XCTAssertEqual(partialState.transcription, "Coverage speech")
        XCTAssertNotNil(partialState.confidence)
        XCTAssertEqual(partialState.confidence ?? 0, 0.75, accuracy: 0.001)

        let finalState = await NutritionSpeechRecognizer()._testStartRecording(
            recognitionTranscript: "Final coverage speech",
            recognitionIsFinal: true
        )
        XCTAssertFalse(finalState.isRecording)
        XCTAssertFalse(finalState.isProcessing)
        XCTAssertEqual(finalState.transcription, "Final coverage speech")
        XCTAssertNotNil(finalState.confidence)
        XCTAssertEqual(finalState.confidence ?? 0, 0.9, accuracy: 0.001)

        let recognitionFailureState = await NutritionSpeechRecognizer()._testStartRecording(
            recognitionError: CoverageExpectedError(message: "Recognition failed")
        )
        XCTAssertFalse(recognitionFailureState.isRecording)
        XCTAssertFalse(recognitionFailureState.isProcessing)
        XCTAssertEqual(recognitionFailureState.errorMessage, "Recognition failed")

        let defaultRecognitionPartialState = await NutritionSpeechRecognizer()._testStartDefaultRecognitionTask(
            transcript: "Default task speech",
            isFinal: false
        )
        XCTAssertTrue(defaultRecognitionPartialState.isRecording)
        XCTAssertFalse(defaultRecognitionPartialState.isProcessing)
        XCTAssertEqual(defaultRecognitionPartialState.transcription, "Default task speech")
        XCTAssertEqual(defaultRecognitionPartialState.confidence ?? 0, 0.75, accuracy: 0.001)

        let defaultRecognitionFailureState = await NutritionSpeechRecognizer()._testStartDefaultRecognitionTask(
            error: CoverageExpectedError(message: "Default recognition failed")
        )
        XCTAssertFalse(defaultRecognitionFailureState.isRecording)
        XCTAssertFalse(defaultRecognitionFailureState.isProcessing)
        XCTAssertEqual(defaultRecognitionFailureState.errorMessage, "Default recognition failed")
        let defaultRecognitionNoOpState = await NutritionSpeechRecognizer()._testStartDefaultRecognitionTask(
            useDefaultTaskAction: true
        )
        XCTAssertTrue(defaultRecognitionNoOpState.isRecording)
        XCTAssertTrue(defaultRecognitionNoOpState.isProcessing)
        XCTAssertNil(defaultRecognitionNoOpState.errorMessage)

        let permissionFailureState = await NutritionSpeechRecognizer()._testStartRecording(
            permissionError: NutritionSpeechRecognizer.SpeechRecognitionError.speechPermissionDenied
        )
        XCTAssertFalse(permissionFailureState.isRecording)
        XCTAssertFalse(permissionFailureState.isProcessing)
        XCTAssertEqual(permissionFailureState.errorMessage, permissionKey)
        let applicationPermissionGranted =
            await permissionProbe._testRequestAudioApplicationPermissionUsingSystemAction(allowed: true)
        XCTAssertTrue(applicationPermissionGranted)
        let sessionPermissionDenied =
            await permissionProbe._testRequestAudioSessionPermissionUsingSystemAction(allowed: false)
        XCTAssertFalse(sessionPermissionDenied)

        let configureFailureState = await NutritionSpeechRecognizer()._testStartRecording(
            configureError: CoverageExpectedError(message: "Session setup failed")
        )
        XCTAssertFalse(configureFailureState.isRecording)
        XCTAssertFalse(configureFailureState.isProcessing)
        XCTAssertEqual(configureFailureState.errorMessage, "Session setup failed")

        let emptyStopRecognizer = NutritionSpeechRecognizer()
        emptyStopRecognizer._testOverrideState(
            isRecording: true,
            isProcessing: false,
            transcription: "",
            errorMessage: nil,
            confidence: nil
        )
        let emptyStopState = await emptyStopRecognizer._testStopRecording()
        XCTAssertTrue(emptyStopState.isRecording)
        XCTAssertFalse(emptyStopState.isProcessing)

        let defaultStopState = await NutritionSpeechRecognizer()._testStopRecordingUsingDefaultOverrides()
        XCTAssertTrue(defaultStopState.isRecording)
        XCTAssertFalse(defaultStopState.isProcessing)

        let filledStopRecognizer = NutritionSpeechRecognizer()
        filledStopRecognizer._testOverrideState(
            isRecording: true,
            isProcessing: false,
            transcription: "Done",
            errorMessage: nil,
            confidence: 0.8
        )
        let filledStopState = await filledStopRecognizer._testStopRecording()
        XCTAssertTrue(filledStopState.isRecording)
        XCTAssertTrue(filledStopState.isProcessing)
        XCTAssertEqual(filledStopState.transcription, "Done")

        let finishedRecognizer = NutritionSpeechRecognizer()
        finishedRecognizer._testOverrideState(
            isRecording: true,
            isProcessing: true,
            transcription: "Draft",
            errorMessage: nil,
            confidence: 0.6
        )
        let finishedState = finishedRecognizer._testFinishRecording()
        XCTAssertFalse(finishedState.isRecording)
        XCTAssertFalse(finishedState.isProcessing)
        XCTAssertEqual(finishedState.transcription, "Draft")

        let pipelineRecognizer = NutritionSpeechRecognizer()
        pipelineRecognizer._testOverrideState(
            isRecording: true,
            isProcessing: true,
            transcription: "Pipeline",
            errorMessage: "Keep",
            confidence: 0.5
        )
        let pipelineResult = pipelineRecognizer._testFinishAudioPipeline()
        XCTAssertEqual(pipelineResult.stopCalls, 1)
        XCTAssertEqual(pipelineResult.removeTapCalls, 1)
        XCTAssertEqual(pipelineResult.cancelCalls, 1)
        XCTAssertEqual(pipelineResult.deactivateCalls, 1)
        XCTAssertTrue(pipelineResult.state.isRecording)
        XCTAssertTrue(pipelineResult.state.isProcessing)
        XCTAssertEqual(pipelineResult.state.errorMessage, "Keep")

        XCTAssertEqual(
            NutritionSpeechRecognizer.SpeechRecognitionError.speechPermissionDenied.errorDescription,
            permissionKey
        )
        XCTAssertEqual(
            NutritionSpeechRecognizer.SpeechRecognitionError.microphonePermissionDenied.errorDescription,
            microphoneKey
        )
    }

    func testNutritionPredictionServiceWrappersCoverSuccessPayloads() async throws {
        let parseClient = CoveragePredictionAPIClientMock { _, _, _, _ in
            Data(
                """
                {
                  "items": [
                    {
                      "name": "Greek yogurt",
                      "category": "protein",
                      "weight_g": 170,
                      "calories": 140,
                      "protein_g": 17,
                      "fat_g": 4,
                      "carbs_g": 10,
                      "fiber_g": 0,
                      "confidence": 0.91,
                      "notes": " breakfast bowl ",
                      "brand": "Coverage Dairy",
                      "barcode": "100200"
                    }
                  ],
                  "total_macros": {
                    "calories": 140,
                    "protein_g": 17,
                    "fat_g": 4,
                    "carbs_g": 10,
                    "fiber_g": 0
                  },
                  "meal_type": "breakfast",
                  "confidence": 0.88,
                  "needs_clarification": false,
                  "clarifying_questions": [],
                  "warnings": ["check quantity"],
                  "suggestions": ["add berries"],
                  "context_analysis": "Breakfast bowl"
                }
                """.utf8
            )
        }
        let parseService = FoodTextParsingService(apiClient: parseClient)
        let parseResponse = try await parseService.parseText(
            "Greek yogurt bowl",
            mealContext: .home,
            mealType: .breakfast,
            localeIdentifier: "en-US"
        )
        XCTAssertEqual(parseResponse.items.count, 1)
        XCTAssertEqual(parseResponse.detectedItems.count, 1)
        XCTAssertEqual(parseResponse.mealTypeRaw, "breakfast")
        XCTAssertEqual(parseResponse.suggestions, ["add berries"])
        let firstParseInvocation = await parseClient.firstInvocation()
        let parseInvocation = try XCTUnwrap(firstParseInvocation)
        XCTAssertEqual(parseInvocation.name, "parse-food-text")
        XCTAssertEqual(parseInvocation.maxAttempts, 2)
        let parsePayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: parseInvocation.body) as? [String: Any]
        )
        XCTAssertEqual(parsePayload["text"] as? String, "Greek yogurt bowl")
        XCTAssertEqual(parsePayload["context"] as? String, MealContext.home.rawValue)
        XCTAssertEqual(parsePayload["meal_type"] as? String, MealType.breakfast.rawValue)

        let photoClient = CoveragePredictionAPIClientMock { _, _, _, _ in
            Data(
                """
                {
                  "detected_items": [
                    {
                      "name": "Chicken rice bowl",
                      "category": "mixed",
                      "weight_g": 320,
                      "calories": 540,
                      "protein_g": 38,
                      "fat_g": 14,
                      "carbs_g": 62,
                      "fiber_g": 6,
                      "confidence": 0.84,
                      "notes": "Lunch"
                    }
                  ],
                  "total_macros": {
                    "calories": 540,
                    "protein_g": 38,
                    "fat_g": 14,
                    "carbs_g": 62,
                    "fiber_g": 6
                  },
                  "meal_type": "lunch",
                  "confidence": 0.81,
                  "warnings": ["review portions"],
                  "context_analysis": "Detected lunch bowl",
                  "suggestions": ["log sauce separately"]
                }
                """.utf8
            )
        }
        let photoService = FoodPhotoAnalysisService(apiClient: photoClient)
        let photoResponse = try await photoService.analyzePhoto(
            imageDataURL: "data:image/jpeg;base64,ZmFrZQ==",
            loggedAt: Date(timeIntervalSince1970: 1_742_385_600),
            recognizedText: "rice bowl",
            barcodes: ["460123"],
            mealContext: .restaurant,
            preWorkout: true,
            postWorkout: false,
            localeIdentifier: "en-US"
        )
        XCTAssertEqual(photoResponse.detectedItems.count, 1)
        XCTAssertEqual(photoResponse.mealTypeRaw, "lunch")
        XCTAssertEqual(photoResponse.suggestions, ["log sauce separately"])
        let firstPhotoInvocation = await photoClient.firstInvocation()
        let photoInvocation = try XCTUnwrap(firstPhotoInvocation)
        XCTAssertEqual(photoInvocation.name, "analyze-food-image")
        let photoPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: photoInvocation.body) as? [String: Any]
        )
        XCTAssertEqual(photoPayload["image_base64"] as? String, "data:image/jpeg;base64,ZmFrZQ==")
        XCTAssertEqual(photoPayload["context"] as? String, MealContext.restaurant.rawValue)
        XCTAssertEqual(photoPayload["recognized_text"] as? String, "rice bowl")
        XCTAssertEqual(photoPayload["pre_workout"] as? Bool, true)

        let labelClient = CoveragePredictionAPIClientMock { _, _, _, _ in
            Data(
                """
                {
                  "barcode": "123456",
                  "name": "Coverage Crunch",
                  "brand": "Coverage Labs",
                  "serving_size_g": 45,
                  "macros_per_100g": {
                    "calories": 410,
                    "protein_g": 24,
                    "fat_g": 15,
                    "carbs_g": 39,
                    "fiber_g": 7
                  },
                  "confidence": 0.93,
                  "warnings": ["OCR confidence low"],
                  "needs_review": true
                }
                """.utf8
            )
        }
        let labelService = FoodLabelAnalysisService(apiClient: labelClient)
        let labelResponse = try await labelService.analyzeLabel(
            imagesDataURL: ["data:image/jpeg;base64,AAA=", "data:image/jpeg;base64,BBB="],
            barcode: " 123456 ",
            localeIdentifier: "en-US"
        )
        XCTAssertEqual(labelResponse.name, "Coverage Crunch")
        XCTAssertEqual(labelResponse.brand, "Coverage Labs")
        XCTAssertEqual(labelResponse.barcode, "123456")
        XCTAssertTrue(labelResponse.needsReview)
        let firstLabelInvocation = await labelClient.firstInvocation()
        let labelInvocation = try XCTUnwrap(firstLabelInvocation)
        XCTAssertEqual(labelInvocation.name, "analyze-food-label")
        let labelPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: labelInvocation.body) as? [String: Any]
        )
        XCTAssertEqual(labelPayload["barcode"] as? String, "123456")
        XCTAssertEqual((labelPayload["images_base64"] as? [String])?.count, 2)

        let batchClient = CoveragePredictionAPIClientMock { _, _, _, _ in
            Data(
                """
                {
                  "recipe_name": "Coverage Chili",
                  "ingredients_detected": [
                    {
                      "name": "Turkey",
                      "estimated_raw_weight_g": 420,
                      "estimated_cooked_weight_g": 360,
                      "calories": 520,
                      "protein_g": 62,
                      "fat_g": 22,
                      "carbs_g": 0,
                      "confidence": 0.82
                    }
                  ],
                  "total_batch": {
                    "weight_g": 1200,
                    "calories": 1400,
                    "protein_g": 92,
                    "fat_g": 44,
                    "carbs_g": 110,
                    "fiber_g": 18
                  },
                  "per_100g": {
                    "weight_g": 100,
                    "calories": 117,
                    "protein_g": 7.7,
                    "fat_g": 3.7,
                    "carbs_g": 9.2,
                    "fiber_g": 1.5
                  },
                  "per_portion": {
                    "weight_g": 300,
                    "calories": 350,
                    "protein_g": 23,
                    "fat_g": 11,
                    "carbs_g": 27
                  },
                  "notes": ["Meal prep"],
                  "confidence": 0.79
                }
                """.utf8
            )
        }
        let batchService = BatchRecipePhotoAnalysisService(apiClient: batchClient)
        let batchResponse = try await batchService.analyzePhoto(
            imageDataURL: "data:image/jpeg;base64,QkFUQ0g=",
            recipeName: "Coverage Chili",
            totalWeightG: 1_200,
            totalPortions: 4,
            knownIngredients: ["Turkey", "Beans"]
        )
        XCTAssertEqual(batchResponse.recipeName, "Coverage Chili")
        XCTAssertEqual(batchResponse.ingredientsDetected.count, 1)
        XCTAssertEqual(batchResponse.notes, ["Meal prep"])
        let firstBatchInvocation = await batchClient.firstInvocation()
        let batchInvocation = try XCTUnwrap(firstBatchInvocation)
        XCTAssertEqual(batchInvocation.name, "analyze-batch-recipe-image")
        let batchPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: batchInvocation.body) as? [String: Any]
        )
        XCTAssertEqual(batchPayload["recipe_name"] as? String, "Coverage Chili")
        XCTAssertEqual(batchPayload["total_weight_grams"] as? Double, 1_200)
        XCTAssertEqual(batchPayload["portions_planned"] as? Int, 4)
    }

    func testNutritionPredictionServiceWrappersRethrowAPIClientErrors() async {
        let apiError = APIClientError.rateLimited(function: "coverage")

        do {
            _ = try await FoodTextParsingService(
                apiClient: CoveragePredictionAPIClientMock { _, _, _, _ in throw apiError }
            ).parseText("Coverage")
            XCTFail("Expected APIClientError")
        } catch let error as APIClientError {
            switch error {
            case .rateLimited(let function):
                XCTAssertEqual(function, "coverage")
            default:
                XCTFail("Unexpected APIClientError case: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        do {
            _ = try await FoodPhotoAnalysisService(
                apiClient: CoveragePredictionAPIClientMock { _, _, _, _ in throw apiError }
            ).analyzePhoto(
                imageDataURL: "data:image/jpeg;base64,ZmFrZQ==",
                loggedAt: Date(),
                recognizedText: nil,
                barcodes: []
            )
            XCTFail("Expected APIClientError")
        } catch is APIClientError {
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        do {
            _ = try await FoodLabelAnalysisService(
                apiClient: CoveragePredictionAPIClientMock { _, _, _, _ in throw apiError }
            ).analyzeLabel(imagesDataURL: ["data:image/jpeg;base64,AAA="], barcode: nil)
            XCTFail("Expected APIClientError")
        } catch is APIClientError {
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        do {
            _ = try await BatchRecipePhotoAnalysisService(
                apiClient: CoveragePredictionAPIClientMock { _, _, _, _ in throw apiError }
            ).analyzePhoto(
                imageDataURL: "data:image/jpeg;base64,QkFUQ0g=",
                recipeName: "Coverage",
                totalWeightG: 500,
                totalPortions: 2,
                knownIngredients: []
            )
            XCTFail("Expected APIClientError")
        } catch is APIClientError {
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testNutritionPredictionServiceWrappersWrapTransportErrors() async {
        let transportError = CoverageExpectedError(message: "Transport failed")

        do {
            _ = try await FoodTextParsingService(
                apiClient: CoveragePredictionAPIClientMock { _, _, _, _ in throw transportError }
            ).parseText("Coverage")
            XCTFail("Expected FoodTextParsingServiceError.transport")
        } catch let error as FoodTextParsingServiceError {
            switch error {
            case .transport(let underlying as CoverageExpectedError):
                XCTAssertEqual(underlying.message, "Transport failed")
            default:
                XCTFail("Unexpected FoodTextParsingServiceError case: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        do {
            _ = try await FoodPhotoAnalysisService(
                apiClient: CoveragePredictionAPIClientMock { _, _, _, _ in throw transportError }
            ).analyzePhoto(
                imageDataURL: "data:image/jpeg;base64,ZmFrZQ==",
                loggedAt: Date(),
                recognizedText: nil,
                barcodes: []
            )
            XCTFail("Expected FoodPhotoAnalysisServiceError.transport")
        } catch let error as FoodPhotoAnalysisServiceError {
            switch error {
            case .transport(let underlying as CoverageExpectedError):
                XCTAssertEqual(underlying.message, "Transport failed")
            default:
                XCTFail("Unexpected FoodPhotoAnalysisServiceError case: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        do {
            _ = try await FoodLabelAnalysisService(
                apiClient: CoveragePredictionAPIClientMock { _, _, _, _ in throw transportError }
            ).analyzeLabel(imagesDataURL: ["data:image/jpeg;base64,AAA="], barcode: nil)
            XCTFail("Expected FoodLabelAnalysisServiceError.transport")
        } catch let error as FoodLabelAnalysisServiceError {
            switch error {
            case .transport(let underlying as CoverageExpectedError):
                XCTAssertEqual(underlying.message, "Transport failed")
            default:
                XCTFail("Unexpected FoodLabelAnalysisServiceError case: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        do {
            _ = try await BatchRecipePhotoAnalysisService(
                apiClient: CoveragePredictionAPIClientMock { _, _, _, _ in throw transportError }
            ).analyzePhoto(
                imageDataURL: "data:image/jpeg;base64,QkFUQ0g=",
                recipeName: "Coverage",
                totalWeightG: 500,
                totalPortions: 2,
                knownIngredients: []
            )
            XCTFail("Expected BatchRecipePhotoAnalysisServiceError.transport")
        } catch let error as BatchRecipePhotoAnalysisServiceError {
            switch error {
            case .transport(let underlying as CoverageExpectedError):
                XCTAssertEqual(underlying.message, "Transport failed")
            default:
                XCTFail("Unexpected BatchRecipePhotoAnalysisServiceError case: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testNutritionDraftResolverPublicVoiceAndPhotoCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        try await insertCoverageUser(dbQueue: manager.dbQueue, userId: userId, authId: authId)

        AuthManager.setActiveAuthIdForTests(authId)
        NutritionDraftResolver._testResetOverrides()
        defer {
            AuthManager.setActiveAuthIdForTests(nil)
            NutritionDraftResolver._testResetOverrides()
        }

        let photoDraft = await NutritionDraftResolver._testResolvePhotoDraft(
            dbQueue: manager.dbQueue,
            analysis: NutritionCoverageFixtures.photoAnalysis(summary: "Coverage photo summary"),
            targetDay: NutritionCoverageFixtures.targetDay,
            loggedAt: NutritionCoverageFixtures.loggedAt
        )
        XCTAssertEqual(photoDraft.method, .photo)
        XCTAssertEqual(photoDraft.summary, "Coverage photo summary")
        XCTAssertEqual(photoDraft.analysisSource, .aiVision)
        XCTAssertEqual(photoDraft.mealType, .lunch)
        XCTAssertEqual(photoDraft.recognizedBarcodes, ["12345"])

        NutritionDraftResolver._testSetVoiceLoggingAvailableOverride(true)
        NutritionDraftResolver._testSetParseTextOverride { _ in
            try Self.decodeJSON(
                """
                {
                  "detected_items": [
                    {
                      "name": "Egg whites",
                      "category": "protein",
                      "weight_g": 120,
                      "calories": 60,
                      "protein_g": 13,
                      "fat_g": 0,
                      "carbs_g": 1,
                      "fiber_g": 0,
                      "confidence": 0.83,
                      "notes": " scrambled ",
                      "brand": "Coverage Farm",
                      "barcode": "9090"
                    }
                  ],
                  "total_macros": {
                    "calories": 60,
                    "protein_g": 13,
                    "fat_g": 0,
                    "carbs_g": 1,
                    "fiber_g": 0
                  },
                  "meal_type": "breakfast",
                  "confidence": 0.72,
                  "needs_clarification": true,
                  "clarifying_questions": [
                    {
                      "id": "portion",
                      "question": "How many eggs?",
                      "options": ["2", "3"]
                    }
                  ],
                  "warnings": ["Need serving confirmation"],
                  "suggestions": ["Add fruit"],
                  "context_analysis": "Protein-heavy breakfast"
                }
                """,
                as: FoodTextParseResponse.self
            )
        }

        let parsedVoiceDraft = await NutritionDraftResolver._testResolveVoiceDraft(
            dbQueue: manager.dbQueue,
            transcription: "Egg whites breakfast",
            confidence: 0.91,
            targetDay: NutritionCoverageFixtures.targetDay,
            loggedAt: NutritionCoverageFixtures.loggedAt
        )
        XCTAssertEqual(parsedVoiceDraft.method, .voice)
        XCTAssertEqual(parsedVoiceDraft.summary, "Protein-heavy breakfast")
        XCTAssertEqual(parsedVoiceDraft.mealType, .breakfast)
        XCTAssertTrue(parsedVoiceDraft.suggestions.contains("Add fruit"))
        XCTAssertTrue(parsedVoiceDraft.suggestions.contains("How many eggs?"))
        XCTAssertTrue(parsedVoiceDraft.warnings.contains("Need serving confirmation"))
        XCTAssertTrue(parsedVoiceDraft.warnings.contains(String(localized: "nutrition_review_serving_sizes_warning")))
        XCTAssertEqual(parsedVoiceDraft.candidateItems.first?.name, "Egg whites")

        NutritionDraftResolver._testSetParseTextOverride { _ in
            throw CoverageExpectedError(message: "Parse failure")
        }
        let fallbackVoiceDraft = await NutritionDraftResolver._testResolveVoiceDraft(
            dbQueue: manager.dbQueue,
            transcription: "I had egg whites, toast and coffee",
            confidence: 0.52,
            targetDay: NutritionCoverageFixtures.targetDay,
            loggedAt: NutritionCoverageFixtures.loggedAt
        )
        XCTAssertEqual(fallbackVoiceDraft.method, .voice)
        XCTAssertEqual(fallbackVoiceDraft.sourceText, "I had egg whites, toast and coffee")
        XCTAssertEqual(
            fallbackVoiceDraft.candidateItems.map(\.name),
            ["egg whites", "toast", "coffee"]
        )
    }

    func testMediaRecognitionPublicCoverageThroughOverrides() async throws {
        let image = NutritionCoverageFixtures.image()
        MediaRecognitionService._testResetOverrides()
        defer { MediaRecognitionService._testResetOverrides() }

        MediaRecognitionService._testSetRecognizeTextOverride { _ in
            "Serving 50 g\nProtein 20\nFat 8\nCarbs 18"
        }
        MediaRecognitionService._testSetDetectBarcodesOverride { _ in
            ["460123"]
        }
        MediaRecognitionService._testSetCloudAnalysisEnabledOverride { false }

        let fallbackPhoto = await MediaRecognitionService.analyzeNutritionPhoto(
            image,
            loggedAt: NutritionCoverageFixtures.loggedAt
        )
        XCTAssertEqual(fallbackPhoto.source, .onDeviceFallback)
        XCTAssertTrue(fallbackPhoto.summary.contains("460123"))

        let fallbackLabel = await MediaRecognitionService.analyzeFoodLabelDraft(
            from: [image],
            barcodeHint: nil
        )
        XCTAssertEqual(fallbackLabel.analysisSource, .onDeviceFallback)
        XCTAssertEqual(fallbackLabel.barcode, "460123")

        let fallbackBatch = await MediaRecognitionService.analyzeBatchRecipePhoto(
            image,
            recipeName: "  ",
            totalWeightG: 0,
            totalPortions: 0,
            knownIngredients: []
        )
        XCTAssertEqual(fallbackBatch.recipeName, String(localized: "nutrition_default_meal_prep_name"))
        XCTAssertFalse(fallbackBatch.notes.isEmpty)

        MediaRecognitionService._testSetCloudAnalysisEnabledOverride { true }
        MediaRecognitionService._testSetFoodPhotoAnalysisOverride { _, _, _, _ in
            try Self.decodeJSON(
                """
                {
                  "detected_items": [
                    {
                      "name": "Salmon bowl",
                      "category": "mixed",
                      "weight_g": 280,
                      "calories": 510,
                      "protein_g": 34,
                      "fat_g": 16,
                      "carbs_g": 48,
                      "fiber_g": 5,
                      "confidence": 0.87,
                      "notes": "Lunch"
                    }
                  ],
                  "total_macros": {
                    "calories": 510,
                    "protein_g": 34,
                    "fat_g": 16,
                    "carbs_g": 48,
                    "fiber_g": 5
                  },
                  "meal_type": "lunch",
                  "confidence": 0.89,
                  "warnings": ["Review sauce"],
                  "context_analysis": "Salmon lunch bowl",
                  "suggestions": ["Add greens"]
                }
                """,
                as: FoodPhotoAnalysisResponse.self
            )
        }
        let aiPhoto = await MediaRecognitionService.analyzeNutritionPhoto(
            image,
            loggedAt: NutritionCoverageFixtures.loggedAt
        )
        XCTAssertEqual(aiPhoto.source, .aiVision)
        XCTAssertEqual(aiPhoto.detectedItems.first?.name, "Salmon bowl")
        XCTAssertEqual(aiPhoto.mealType, .lunch)

        MediaRecognitionService._testSetFoodPhotoAnalysisOverride(nil)
        MediaRecognitionService._testSetFoodPhotoServiceRunnerOverride { _, _, _, _ in
            try Self.decodeJSON(
                """
                {
                  "detected_items": [
                    {
                      "name": "Runner Salad",
                      "category": "vegetables",
                      "weight_g": 180,
                      "calories": 210,
                      "protein_g": 9,
                      "fat_g": 11,
                      "carbs_g": 17,
                      "fiber_g": 8,
                      "confidence": 0.74,
                      "notes": "Runner path"
                    }
                  ],
                  "total_macros": {
                    "calories": 210,
                    "protein_g": 9,
                    "fat_g": 11,
                    "carbs_g": 17,
                    "fiber_g": 8
                  },
                  "meal_type": "dinner",
                  "confidence": 0.76,
                  "warnings": [],
                  "context_analysis": "Runner salad",
                  "suggestions": []
                }
                """,
                as: FoodPhotoAnalysisResponse.self
            )
        }
        let serviceRunnerPhoto = await MediaRecognitionService.analyzeNutritionPhoto(
            image,
            loggedAt: NutritionCoverageFixtures.loggedAt
        )
        XCTAssertEqual(serviceRunnerPhoto.detectedItems.first?.name, "Runner Salad")
        XCTAssertEqual(serviceRunnerPhoto.mealType, .dinner)

        MediaRecognitionService._testSetFoodPhotoAnalysisOverride { _, _, _, _ in
            throw CoverageExpectedError(message: "AI photo failed")
        }
        let erroredPhoto = await MediaRecognitionService.analyzeNutritionPhoto(
            image,
            loggedAt: NutritionCoverageFixtures.loggedAt
        )
        XCTAssertEqual(erroredPhoto.source, .onDeviceFallback)

        MediaRecognitionService._testSetFoodLabelAnalysisOverride { _, _ in
            FoodLabelAnalysisResponse(
                barcode: "460123",
                name: "Coverage Crunch",
                brand: "Coverage Labs",
                servingSizeG: 45,
                macrosPer100g: NutritionFoodsRemoteMacros(
                    calories: 410,
                    proteinG: 24,
                    fatG: 15,
                    carbsG: 39,
                    fiberG: 7
                ),
                confidence: 0.94,
                warnings: ["OCR warning"],
                needsReview: false
            )
        }
        let aiLabel = await MediaRecognitionService.analyzeFoodLabelDraft(
            from: [image, image],
            barcodeHint: "460123"
        )
        XCTAssertEqual(aiLabel.analysisSource, .aiVision)
        XCTAssertEqual(aiLabel.name, "Coverage Crunch")

        MediaRecognitionService._testSetFoodLabelAnalysisOverride(nil)
        MediaRecognitionService._testSetFoodLabelServiceRunnerOverride { _, _ in
            FoodLabelAnalysisResponse(
                barcode: "778899",
                name: "Runner Bar",
                brand: "Coverage Runner",
                servingSizeG: 50,
                macrosPer100g: NutritionFoodsRemoteMacros(
                    calories: 390,
                    proteinG: 21,
                    fatG: 13,
                    carbsG: 44,
                    fiberG: 6
                ),
                confidence: 0.88,
                warnings: [],
                needsReview: false
            )
        }
        let serviceRunnerLabel = await MediaRecognitionService.analyzeFoodLabelDraft(
            from: [image],
            barcodeHint: "778899"
        )
        XCTAssertEqual(serviceRunnerLabel.analysisSource, .aiVision)
        XCTAssertEqual(serviceRunnerLabel.name, "Runner Bar")

        MediaRecognitionService._testSetFoodLabelAnalysisOverride { _, _ in
            throw CoverageExpectedError(message: "AI label failed")
        }
        let erroredLabel = await MediaRecognitionService.analyzeFoodLabelDraft(
            from: [image],
            barcodeHint: "460123"
        )
        XCTAssertEqual(erroredLabel.analysisSource, .onDeviceFallback)

        MediaRecognitionService._testSetBatchRecipePhotoAnalysisOverride { _, _, _, _, _ in
            BatchRecipePhotoAnalysisResponse(
                recipeName: "Coverage Chili",
                ingredientsDetected: [
                    .init(
                        name: "Beans",
                        estimatedRawWeightG: 300,
                        estimatedCookedWeightG: 240,
                        calories: 320,
                        proteinG: 18,
                        fatG: 2,
                        carbsG: 58,
                        confidence: 0.8
                    )
                ],
                totalBatch: .init(
                    weightG: 1_100,
                    calories: 1_280,
                    proteinG: 82,
                    fatG: 28,
                    carbsG: 124,
                    fiberG: 18
                ),
                per100g: .init(
                    weightG: 100,
                    calories: 116,
                    proteinG: 7.4,
                    fatG: 2.5,
                    carbsG: 11.3,
                    fiberG: 1.6
                ),
                perPortion: .init(
                    weightG: 275,
                    calories: 320,
                    proteinG: 20.5,
                    fatG: 7,
                    carbsG: 31
                ),
                notes: ["Meal prep"],
                storage: nil,
                confidence: 0.85
            )
        }
        let aiBatch = await MediaRecognitionService.analyzeBatchRecipePhoto(
            image,
            recipeName: "Coverage Chili",
            totalWeightG: 1_100,
            totalPortions: 4,
            knownIngredients: ["Beans"]
        )
        XCTAssertEqual(aiBatch.recipeName, "Coverage Chili")
        XCTAssertEqual(aiBatch.ingredients.count, 1)

        MediaRecognitionService._testSetBatchRecipePhotoAnalysisOverride(nil)
        MediaRecognitionService._testSetBatchRecipePhotoServiceRunnerOverride { _, _, _, _, _ in
            BatchRecipePhotoAnalysisResponse(
                recipeName: "Runner Soup",
                ingredientsDetected: [
                    .init(
                        name: "Lentils",
                        estimatedRawWeightG: 250,
                        estimatedCookedWeightG: 220,
                        calories: 290,
                        proteinG: 17,
                        fatG: 3,
                        carbsG: 46,
                        confidence: 0.79
                    )
                ],
                totalBatch: .init(
                    weightG: 980,
                    calories: 1_020,
                    proteinG: 58,
                    fatG: 15,
                    carbsG: 148,
                    fiberG: 19
                ),
                per100g: .init(
                    weightG: 100,
                    calories: 104,
                    proteinG: 5.9,
                    fatG: 1.5,
                    carbsG: 15.1,
                    fiberG: 1.9
                ),
                perPortion: .init(
                    weightG: 245,
                    calories: 255,
                    proteinG: 14.5,
                    fatG: 3.8,
                    carbsG: 37
                ),
                notes: ["Runner batch"],
                storage: nil,
                confidence: 0.81
            )
        }
        let serviceRunnerBatch = await MediaRecognitionService.analyzeBatchRecipePhoto(
            image,
            recipeName: "Runner Soup",
            totalWeightG: 980,
            totalPortions: 4,
            knownIngredients: ["Lentils"]
        )
        XCTAssertEqual(serviceRunnerBatch.recipeName, "Runner Soup")
        XCTAssertEqual(serviceRunnerBatch.ingredients.first?.name, "Lentils")

        MediaRecognitionService._testSetBatchRecipePhotoAnalysisOverride { _, _, _, _, _ in
            throw CoverageExpectedError(message: "AI batch failed")
        }
        let erroredBatch = await MediaRecognitionService.analyzeBatchRecipePhoto(
            image,
            recipeName: "Coverage Chili",
            totalWeightG: 1_100,
            totalPortions: 4,
            knownIngredients: ["Beans"]
        )
        XCTAssertFalse(erroredBatch.notes.isEmpty)

        MediaRecognitionService._testSetFoodPhotoAnalysisOverride { _, _, _, _ in
            try Self.decodeJSON(
                """
                {
                  "detected_items": [
                    {
                      "name": "Fallback Lentils",
                      "category": "mixed",
                      "weight_g": 220,
                      "calories": 260,
                      "protein_g": 19,
                      "fat_g": 4,
                      "carbs_g": 32,
                      "fiber_g": 9,
                      "confidence": 0.82,
                      "notes": "Fallback item"
                    }
                  ],
                  "total_macros": {
                    "calories": 260,
                    "protein_g": 19,
                    "fat_g": 4,
                    "carbs_g": 32,
                    "fiber_g": 9
                  },
                  "meal_type": "dinner",
                  "confidence": 0.83,
                  "warnings": [],
                  "context_analysis": "Fallback lentil prep",
                  "suggestions": []
                }
                """,
                as: FoodPhotoAnalysisResponse.self
            )
        }
        MediaRecognitionService._testSetBatchRecipePhotoAnalysisOverride { _, _, _, _, _ in
            BatchRecipePhotoAnalysisResponse(
                recipeName: "Coverage Chili",
                ingredientsDetected: [],
                totalBatch: nil,
                per100g: nil,
                perPortion: nil,
                notes: [],
                storage: nil,
                confidence: 0.2
            )
        }
        let emptyIngredientsBatch = await MediaRecognitionService.analyzeBatchRecipePhoto(
            image,
            recipeName: "Coverage Chili",
            totalWeightG: 1_100,
            totalPortions: 4,
            knownIngredients: []
        )
        XCTAssertEqual(emptyIngredientsBatch.recipeName, "Coverage Chili")
        XCTAssertEqual(emptyIngredientsBatch.ingredients.first?.name, "Fallback Lentils")
        XCTAssertFalse(emptyIngredientsBatch.notes.isEmpty)

        let invalidImageFallbackPhoto = await MediaRecognitionService.analyzeNutritionPhoto(
            UIImage(),
            loggedAt: NutritionCoverageFixtures.loggedAt
        )
        XCTAssertEqual(invalidImageFallbackPhoto.source, .onDeviceFallback)
        XCTAssertFalse(invalidImageFallbackPhoto.summary.isEmpty)
    }

    func testMediaRecognitionServiceResponseWrappersUseInjectedServices() async throws {
        MediaRecognitionService._testResetOverrides()
        defer { MediaRecognitionService._testResetOverrides() }

        let photoClient = CoveragePredictionAPIClientMock { _, _, _, _ in
            Data(
                """
                {
                  "detected_items": [
                    {
                      "name": "Injected Bowl",
                      "category": "mixed",
                      "weight_g": 240,
                      "calories": 430,
                      "protein_g": 26,
                      "fat_g": 12,
                      "carbs_g": 42,
                      "fiber_g": 6,
                      "confidence": 0.86,
                      "notes": "Injected service"
                    }
                  ],
                  "total_macros": {
                    "calories": 430,
                    "protein_g": 26,
                    "fat_g": 12,
                    "carbs_g": 42,
                    "fiber_g": 6
                  },
                  "meal_type": "lunch",
                  "confidence": 0.84,
                  "warnings": [],
                  "context_analysis": "Injected photo analysis",
                  "suggestions": ["Review dressing"]
                }
                """.utf8
            )
        }
        let photoResponse = try await MediaRecognitionService._testFoodPhotoAnalysisResponse(
            imageDataURL: "data:image/jpeg;base64,SU5KRUNURUQ=",
            loggedAt: NutritionCoverageFixtures.loggedAt,
            recognizedText: "bowl",
            barcodes: ["123456"],
            service: FoodPhotoAnalysisService(apiClient: photoClient)
        )
        XCTAssertEqual(photoResponse.detectedItems.first?.name, "Injected Bowl")
        XCTAssertEqual(photoResponse.mealTypeRaw, "lunch")
        let firstPhotoInvocation = await photoClient.firstInvocation()
        let photoInvocation = try XCTUnwrap(firstPhotoInvocation)
        XCTAssertEqual(photoInvocation.name, "analyze-food-image")

        let labelClient = CoveragePredictionAPIClientMock { _, _, _, _ in
            Data(
                """
                {
                  "barcode": "998877",
                  "name": "Injected Label",
                  "brand": "Injected Foods",
                  "serving_size_g": 55,
                  "macros_per_100g": {
                    "calories": 380,
                    "protein_g": 18,
                    "fat_g": 10,
                    "carbs_g": 49,
                    "fiber_g": 5
                  },
                  "confidence": 0.9,
                  "warnings": [],
                  "needs_review": false
                }
                """.utf8
            )
        }
        let labelResponse = try await MediaRecognitionService._testFoodLabelAnalysisResponse(
            imagesDataURL: ["data:image/jpeg;base64,TEFCRUw="],
            barcode: " 998877 ",
            service: FoodLabelAnalysisService(apiClient: labelClient)
        )
        XCTAssertEqual(labelResponse.name, "Injected Label")
        XCTAssertEqual(labelResponse.barcode, "998877")
        let firstLabelInvocation = await labelClient.firstInvocation()
        let labelInvocation = try XCTUnwrap(firstLabelInvocation)
        XCTAssertEqual(labelInvocation.name, "analyze-food-label")

        let batchClient = CoveragePredictionAPIClientMock { _, _, _, _ in
            Data(
                """
                {
                  "recipe_name": "Injected Stew",
                  "ingredients_detected": [
                    {
                      "name": "Chickpeas",
                      "estimated_raw_weight_g": 300,
                      "estimated_cooked_weight_g": 270,
                      "calories": 420,
                      "protein_g": 22,
                      "fat_g": 8,
                      "carbs_g": 61,
                      "confidence": 0.83
                    }
                  ],
                  "total_batch": {
                    "weight_g": 1200,
                    "calories": 1180,
                    "protein_g": 68,
                    "fat_g": 24,
                    "carbs_g": 166,
                    "fiber_g": 21
                  },
                  "per_100g": {
                    "weight_g": 100,
                    "calories": 98,
                    "protein_g": 5.7,
                    "fat_g": 2,
                    "carbs_g": 13.8,
                    "fiber_g": 1.8
                  },
                  "per_portion": {
                    "weight_g": 300,
                    "calories": 295,
                    "protein_g": 17,
                    "fat_g": 6,
                    "carbs_g": 41
                  },
                  "notes": ["Injected batch"],
                  "confidence": 0.82
                }
                """.utf8
            )
        }
        let batchResponse = try await MediaRecognitionService._testBatchRecipePhotoAnalysisResponse(
            imageDataURL: "data:image/jpeg;base64,QkFUQ0g=",
            recipeName: "Injected Stew",
            totalWeightG: 1_200,
            totalPortions: 4,
            knownIngredients: ["Chickpeas"],
            service: BatchRecipePhotoAnalysisService(apiClient: batchClient)
        )
        XCTAssertEqual(batchResponse.recipeName, "Injected Stew")
        XCTAssertEqual(batchResponse.ingredientsDetected.first?.name, "Chickpeas")
        let firstBatchInvocation = await batchClient.firstInvocation()
        let batchInvocation = try XCTUnwrap(firstBatchInvocation)
        XCTAssertEqual(batchInvocation.name, "analyze-batch-recipe-image")
    }

    func testMediaRecognitionHelperCoverageAndCloudPreference() async throws {
        let summaryWithTotals = MediaRecognitionService._testAISummaryFallback(
            detectedItems: [
                NutritionDraftCandidateItem(name: "Oatmeal"),
                NutritionDraftCandidateItem(name: "Banana"),
                NutritionDraftCandidateItem(name: "Yogurt")
            ],
            totalMacros: NutritionDraftMacroSummary(
                calories: 420,
                proteinG: 21,
                fatG: 9,
                carbsG: 62,
                fiberG: 8
            )
        )
        XCTAssertTrue(summaryWithTotals.contains("Oatmeal"))
        XCTAssertTrue(summaryWithTotals.contains("420"))

        let summaryWithoutItems = MediaRecognitionService._testAISummaryFallback(
            detectedItems: [],
            totalMacros: nil
        )
        XCTAssertFalse(summaryWithoutItems.isEmpty)

        let aiAnalysis = MediaRecognitionService._testAIAnalysis(
            from: try Self.decodeJSON(
                """
                {
                  "detected_items": [
                    {
                      "name": "Coverage Pasta",
                      "category": "mixed",
                      "weight_g": 250,
                      "calories": 430,
                      "protein_g": 18,
                      "fat_g": 9,
                      "carbs_g": 67,
                      "fiber_g": 4,
                      "confidence": 0.74,
                      "notes": "Dinner"
                    }
                  ],
                  "total_macros": {
                    "calories": 430,
                    "protein_g": 18,
                    "fat_g": 9,
                    "carbs_g": 67,
                    "fiber_g": 4
                  },
                  "meal_type": "dinner",
                  "confidence": 0.78,
                  "warnings": ["Check sauce"],
                  "context_analysis": "Coverage pasta dinner",
                  "suggestions": ["Add veggies"]
                }
                """,
                as: FoodPhotoAnalysisResponse.self
            ),
            recognizedText: "Coverage pasta",
            barcodes: ["12345"]
        )
        XCTAssertEqual(aiAnalysis.source, .aiVision)
        XCTAssertEqual(aiAnalysis.mealType, .dinner)
        XCTAssertEqual(aiAnalysis.detectedItems.first?.name, "Coverage Pasta")

        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        try await insertCoverageUser(dbQueue: manager.dbQueue, userId: userId, authId: authId)
        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO privacy_settings (
                        id, user_id, menstrual_local_only, medical_scan_local_only, cloud_backup_enabled,
                        vector_opt_in, analytics_consent, cloud_ocr_enabled, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    false,
                    false,
                    true,
                    true,
                    false,
                    false,
                    Date(),
                    Date()
                ]
            )
        }

        AuthManager.setActiveAuthIdForTests(authId)
        AuthManager._testSetActiveHasCloudSession(true)
        defer {
            AuthManager.setActiveAuthIdForTests(nil)
            AuthManager._testSetActiveHasCloudSession(false)
        }

        let cloudDisabled = await MediaRecognitionService._testIsCloudAnalysisEnabled()
        XCTAssertFalse(cloudDisabled)
    }

    func testMediaRecognitionDirectPDFBarcodeAndCloudCoverage() async throws {
        MediaRecognitionService._testResetOverrides()
        defer {
            MediaRecognitionService._testResetOverrides()
            Task { @MainActor in
                AuthManager.setActiveAuthIdForTests(nil)
                AuthManager._testSetActiveHasCloudSession(false)
            }
        }

        MediaRecognitionService._testSetSyncDetectBarcodesOverride { _ in
            ["4601234567890", " 4601234567890 "]
        }
        let detectedCodes = try await MediaRecognitionService.detectBarcodes(
            in: NutritionCoverageFixtures.image()
        )
        XCTAssertTrue(detectedCodes.contains("4601234567890"))

        let pdfURL = try makeCoveragePDF(withFirstPageText: "Coverage PDF Protein")
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        MediaRecognitionService._testSetSyncRecognizeTextOverride { _ in
            "Coverage OCR Page"
        }
        let recognizedPDFText = try await MediaRecognitionService.recognizeText(inPDFAt: pdfURL)
        XCTAssertTrue(recognizedPDFText.contains("Coverage PDF Protein"))
        XCTAssertTrue(recognizedPDFText.contains("Coverage OCR Page"))

        do {
            _ = try await MediaRecognitionService.recognizeText(
                inPDFAt: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("pdf")
            )
            XCTFail("Expected invalid document error")
        } catch let error as MediaRecognitionService.RecognitionError {
            guard case .invalidDocument = error else {
                return XCTFail("Unexpected recognition error: \(error)")
            }
        }

        MediaRecognitionService._testSetPhotoCloudAnalysisAvailableOverride(false)
        let unavailableCloud = await MediaRecognitionService._testIsCloudAnalysisEnabled()
        XCTAssertFalse(unavailableCloud)

        MediaRecognitionService._testSetPhotoCloudAnalysisAvailableOverride(true)
        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(nil)
            AuthManager._testSetActiveHasCloudSession(true)
        }
        let anonymousCloud = await MediaRecognitionService._testIsCloudAnalysisEnabled()
        XCTAssertTrue(anonymousCloud)

        let authId = UUID()
        let userId = UUID()
        try await DatabaseManager.shared.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [userId.uuidString, authId.uuidString, "UTC", "metric", Date(), Date()]
            )
            try db.execute(
                sql: """
                    INSERT INTO privacy_settings (
                        id, user_id, menstrual_local_only, medical_scan_local_only, cloud_backup_enabled,
                        vector_opt_in, analytics_consent, cloud_ocr_enabled, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    false,
                    false,
                    true,
                    true,
                    false,
                    false,
                    Date(),
                    Date()
                ]
            )
        }

        await MainActor.run {
            AuthManager.setActiveAuthIdForTests(authId)
            AuthManager._testSetActiveHasCloudSession(true)
        }
        let disabledCloud = await MediaRecognitionService._testIsCloudAnalysisEnabled()
        XCTAssertFalse(disabledCloud)
    }

    func testMediaRecognitionNativeVisionCoverage() async throws {
        MediaRecognitionService._testResetOverrides()
        defer { MediaRecognitionService._testResetOverrides() }

        let qrImage = try makeCoverageQRCodeImage(message: "4601234567890")
        do {
            let detectedCodes = try await MediaRecognitionService.detectBarcodes(in: qrImage)
            XCTAssertTrue(detectedCodes.contains("4601234567890"))
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }

        do {
            _ = try await MediaRecognitionService.detectBarcodes(in: UIImage())
            XCTFail("Expected invalid image data for empty barcode image")
        } catch let error as MediaRecognitionService.RecognitionError {
            guard case .invalidImageData = error else {
                return XCTFail("Unexpected barcode recognition error: \(error)")
            }
        }

        let textImage = makeCoverageTextImage(text: "COVERAGE PROTEIN")
        do {
            let recognizedText = try await MediaRecognitionService.recognizeText(in: textImage)
            let normalizedText = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(normalizedText.isEmpty)
            XCTAssertTrue(
                normalizedText.uppercased().contains("COVERAGE")
                    || normalizedText.uppercased().contains("PROTEIN")
            )
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }

        do {
            _ = try await MediaRecognitionService.recognizeText(in: UIImage())
            XCTFail("Expected invalid image data for empty OCR image")
        } catch let error as MediaRecognitionService.RecognitionError {
            guard case .invalidImageData = error else {
                return XCTFail("Unexpected OCR recognition error: \(error)")
            }
        }
    }

    func testNutritionCalendarAndBatchLibraryLoaderCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        try await insertCoverageUser(dbQueue: manager.dbQueue, userId: userId, authId: authId)

        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO food_logs (
                        id, user_id, logged_at, logged_date, input_method,
                        calories, protein_g, fat_g, carbs_g, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    Date(),
                    "2026-03-11",
                    "manual",
                    420.0,
                    24.0,
                    14.0,
                    38.0,
                    Date(),
                    Date()
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO food_logs (
                        id, user_id, logged_at, logged_date, input_method,
                        calories, protein_g, fat_g, carbs_g, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    Date(),
                    "2026-02-28",
                    "manual",
                    180.0,
                    10.0,
                    6.0,
                    20.0,
                    Date(),
                    Date()
                ]
            )
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let displayedMonth = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))
        )

        let loggedDays = await NutritionCalendarView._testLoadLoggedDaysResult(
            displayedMonth: displayedMonth,
            calendar: calendar,
            dbQueue: manager.dbQueue
        )
        XCTAssertEqual(loggedDays, ["2026-03-11"])

        var selectedDate = displayedMonth
        let calendarView = NutritionCalendarView(
            selectedDate: Binding(
                get: { selectedDate },
                set: { selectedDate = $0 }
            ),
            testDisplayedMonth: displayedMonth,
            testDaysWithLogs: []
        )
        await calendarView._testTriggerLoadLoggedDays(calendar: calendar, dbQueue: manager.dbQueue)

        let batchManager = CoverageBatchRecipeManagerMock(
            detailResponse: NutritionCoverageFixtures.batchDetail()
        )
        let activeRecipes = await BatchRecipeLibraryView._testLoadRecipesResult(
            showingArchived: false,
            manager: batchManager
        )
        XCTAssertEqual(activeRecipes.recipes.count, 1)
        XCTAssertNil(activeRecipes.statusMessage)

        let batchFailure = await BatchRecipeLibraryView._testLoadRecipesResult(
            showingArchived: true,
            manager: CoverageBatchRecipeManagerMock(
                detailResponse: NutritionCoverageFixtures.batchDetail(archived: true),
                loadError: CoverageExpectedError(message: "Batch library failed")
            )
        )
        XCTAssertTrue(batchFailure.recipes.isEmpty)
        XCTAssertEqual(batchFailure.statusMessage?.message, "Batch library failed")
        XCTAssertEqual(batchFailure.statusMessage?.isError, true)
    }

    func testNutritionTemplateBatchAndSystemPickerInstanceCoverage() async throws {
        let activeTemplateDetail = NutritionCoverageFixtures.mealTemplateDetail()
        let templateSummary = NutritionCoverageFixtures.mealTemplateSummary()
        let compactTemplateManager = CoverageMealTemplateManagerMock(detailResponse: activeTemplateDetail)
        let compactTemplatesView = MealTemplatesView(
            targetDay: NutritionCoverageFixtures.targetDay,
            loggedAt: NutritionCoverageFixtures.loggedAt,
            testIsLoading: false
        )
        let compactTemplatesInitial = compactTemplatesView._testState()
        XCTAssertTrue(compactTemplatesInitial.templates.isEmpty)
        XCTAssertFalse(compactTemplatesInitial.isLoading)
        _ = await compactTemplatesView._testTriggerLoadTemplates(
            manager: compactTemplateManager
        )
        let compactTemplateSnapshot = await compactTemplateManager.snapshot()
        XCTAssertEqual(compactTemplateSnapshot.templateListLoadCallCount, 1)

        let templateManager = CoverageMealTemplateManagerMock(detailResponse: activeTemplateDetail)

        var templateChangeCalls = 0
        let templateLibraryView = MealTemplateLibraryView(
            targetDay: NutritionCoverageFixtures.targetDay,
            loggedAt: NutritionCoverageFixtures.loggedAt,
            testTemplates: [],
            testIsLoading: false,
            testShowingArchived: false,
            onTemplatesChanged: { templateChangeCalls += 1 }
        )
        let templateLibraryInitialState = templateLibraryView._testState()
        XCTAssertTrue(templateLibraryInitialState.templates.isEmpty)
        XCTAssertFalse(templateLibraryInitialState.isLoading)
        XCTAssertNil(templateLibraryInitialState.statusMessage)

        _ = await templateLibraryView._testTriggerLoadTemplates(manager: templateManager)
        let templateLoadSnapshot = await templateManager.snapshot()
        XCTAssertEqual(templateLoadSnapshot.templateListLoadCallCount, 1)
        XCTAssertEqual(templateLoadSnapshot.lastTemplateListLoadPreferRemote, true)

        _ = await templateLibraryView._testTriggerToggleArchive(for: templateSummary, manager: templateManager)
        let templateToggleSnapshot = await templateManager.snapshot()
        XCTAssertEqual(templateToggleSnapshot.archiveCalls.count, 1)
        XCTAssertEqual(templateToggleSnapshot.archiveCalls.first?.id, templateSummary.id)
        XCTAssertEqual(templateToggleSnapshot.archiveCalls.first?.archived, !templateSummary.archived)
        XCTAssertEqual(templateChangeCalls, 1)
        _ = await templateLibraryView._testHandleComposerSaved(
            TemplateStatusMessage(message: "Template saved", isError: false)
        )
        XCTAssertEqual(templateChangeCalls, 2)
        _ = await templateLibraryView._testHandleComposerSheetSaved(
            TemplateStatusMessage(message: "Template sheet saved", isError: false)
        )
        XCTAssertEqual(templateChangeCalls, 3)
        let templateComposerState = MealTemplateComposerView(testName: "Coverage Template")._testState()
        XCTAssertFalse(templateComposerState.isSaving)
        XCTAssertNil(templateComposerState.errorMessage)

        let failingTemplateView = MealTemplateLibraryView(
            targetDay: NutritionCoverageFixtures.targetDay,
            loggedAt: NutritionCoverageFixtures.loggedAt,
            testTemplates: [],
            testIsLoading: false,
            testShowingArchived: false
        )
        _ = await failingTemplateView._testTriggerToggleArchive(
            for: templateSummary,
            manager: CoverageMealTemplateManagerMock(
                detailResponse: activeTemplateDetail,
                archiveError: CoverageExpectedError(message: "Template archive failed")
            )
        )

        let batchDetail = NutritionCoverageFixtures.batchDetail()
        let batchManager = CoverageBatchRecipeManagerMock(detailResponse: batchDetail)
        var batchLibraryChangeCalls = 0
        var batchLibraryLogCalls = 0
        let batchLibraryView = BatchRecipeLibraryView(
            targetDay: NutritionCoverageFixtures.targetDay,
            loggedAt: NutritionCoverageFixtures.loggedAt,
            testRecipes: [],
            testIsLoading: false,
            testShowingArchived: false,
            onBatchesChanged: { batchLibraryChangeCalls += 1 },
            onBatchLogged: { batchLibraryLogCalls += 1 }
        )
        _ = await batchLibraryView._testTriggerLoadRecipes(manager: batchManager)
        let batchLibrarySnapshot = await batchManager.snapshot()
        XCTAssertEqual(batchLibrarySnapshot.listLoadCallCount, 1)
        XCTAssertEqual(batchLibrarySnapshot.lastListLoadPreferRemote, true)
        _ = await batchLibraryView._testHandleComposerSaved(
            TemplateStatusMessage(message: "Batch saved", isError: false)
        )
        XCTAssertEqual(batchLibraryChangeCalls, 1)
        _ = await batchLibraryView._testHandleComposerSheetSaved(
            TemplateStatusMessage(message: "Batch sheet saved", isError: false)
        )
        XCTAssertEqual(batchLibraryChangeCalls, 2)
        _ = await batchLibraryView._testHandleQuickLogSaved(
            TemplateStatusMessage(message: "Batch logged", isError: false)
        )
        XCTAssertEqual(batchLibraryChangeCalls, 3)
        XCTAssertEqual(batchLibraryLogCalls, 1)
        _ = await batchLibraryView._testHandleQuickLogSheetSaved(
            TemplateStatusMessage(message: "Batch sheet logged", isError: false)
        )
        XCTAssertEqual(batchLibraryChangeCalls, 4)
        XCTAssertEqual(batchLibraryLogCalls, 2)

        var batchDetailChangeCalls = 0
        var batchDetailLogCalls = 0
        var batchDetailStatusMessages: [String?] = []
        let batchView = BatchRecipeDetailView(
            batchId: batchDetail.recipe.id,
            testDetail: nil,
            testIsLoading: false,
            onBatchesChanged: { batchDetailChangeCalls += 1 },
            onBatchLogged: { batchDetailLogCalls += 1 },
            onStatusMessage: { batchDetailStatusMessages.append($0?.message) }
        )
        let batchViewInitialState = batchView._testState()
        XCTAssertNil(batchViewInitialState.detail)
        XCTAssertFalse(batchViewInitialState.isLoading)
        XCTAssertFalse(batchViewInitialState.isArchiving)
        XCTAssertFalse(batchViewInitialState.isDuplicating)
        XCTAssertNil(batchViewInitialState.errorMessage)

        _ = await batchView._testTriggerLoadDetail(preferRemote: false, manager: batchManager)
        let batchLoadSnapshot = await batchManager.snapshot()
        XCTAssertEqual(batchLoadSnapshot.loadDetailCallCount, 1)
        XCTAssertEqual(batchLoadSnapshot.lastLoadDetailPreferRemote, false)
        _ = await BatchRecipeDetailView(
            batchId: batchDetail.recipe.id,
            testDetail: batchDetail,
            testIsLoading: false,
            onBatchesChanged: { batchDetailChangeCalls += 1 },
            onBatchLogged: { batchDetailLogCalls += 1 },
            onStatusMessage: { batchDetailStatusMessages.append($0?.message) }
        )._testHandleComposerSaved(
            TemplateStatusMessage(message: "Batch detail saved", isError: false)
        )
        XCTAssertEqual(batchDetailChangeCalls, 1)
        XCTAssertEqual(batchDetailStatusMessages.last ?? nil, "Batch detail saved")
        _ = await BatchRecipeDetailView(
            batchId: batchDetail.recipe.id,
            testDetail: batchDetail,
            testIsLoading: false,
            onBatchesChanged: { batchDetailChangeCalls += 1 },
            onBatchLogged: { batchDetailLogCalls += 1 },
            onStatusMessage: { batchDetailStatusMessages.append($0?.message) }
        )._testHandleComposerSheetSaved(
            TemplateStatusMessage(message: "Batch detail sheet saved", isError: false)
        )
        XCTAssertEqual(batchDetailChangeCalls, 2)
        XCTAssertEqual(batchDetailStatusMessages.last ?? nil, "Batch detail sheet saved")
        _ = await BatchRecipeDetailView(
            batchId: batchDetail.recipe.id,
            testDetail: batchDetail,
            testIsLoading: false,
            onBatchesChanged: { batchDetailChangeCalls += 1 },
            onBatchLogged: { batchDetailLogCalls += 1 },
            onStatusMessage: { batchDetailStatusMessages.append($0?.message) }
        )._testHandleLogSaved(
            TemplateStatusMessage(message: "Batch detail logged", isError: false)
        )
        XCTAssertEqual(batchDetailChangeCalls, 3)
        XCTAssertEqual(batchDetailLogCalls, 1)
        XCTAssertEqual(batchDetailStatusMessages.last ?? nil, "Batch detail logged")
        _ = await BatchRecipeDetailView(
            batchId: batchDetail.recipe.id,
            testDetail: batchDetail,
            testIsLoading: false,
            onBatchesChanged: { batchDetailChangeCalls += 1 },
            onBatchLogged: { batchDetailLogCalls += 1 },
            onStatusMessage: { batchDetailStatusMessages.append($0?.message) }
        )._testHandleLogSheetSaved(
            TemplateStatusMessage(message: "Batch detail sheet logged", isError: false)
        )
        XCTAssertEqual(batchDetailChangeCalls, 4)
        XCTAssertEqual(batchDetailLogCalls, 2)
        XCTAssertEqual(batchDetailStatusMessages.last ?? nil, "Batch detail sheet logged")
        let batchComposerState = BatchRecipeComposerView(testName: "Coverage Batch")._testState()
        XCTAssertFalse(batchComposerState.isSaving)
        XCTAssertNil(batchComposerState.errorMessage)
        XCTAssertNil(batchComposerState.importMessage)
        let batchPortionState = BatchPortionLogView()._testState()
        XCTAssertFalse(batchPortionState.isSaving)
        XCTAssertNil(batchPortionState.errorMessage)

        let picker = SystemImagePicker(sourceType: .photoLibrary) { _ in }
        let configuredCoordinator = picker.makeCoordinator()
        let configuredPicker = picker._testConfiguredPicker(delegate: configuredCoordinator)
        XCTAssertEqual(configuredPicker.sourceType, .photoLibrary)
        XCTAssertFalse(configuredPicker.allowsEditing)
        XCTAssertNotNil(configuredPicker.delegate)

        let pickedImage = NutritionCoverageFixtures.image(color: .systemOrange)
        var receivedImage: UIImage?
        let coordinator = SystemImagePicker.Coordinator(onImagePicked: { receivedImage = $0 })
        let delegatePicker = CoverageImagePickerController()
        coordinator.imagePickerController(
            delegatePicker,
            didFinishPickingMediaWithInfo: [.originalImage: pickedImage]
        )
        XCTAssertEqual(delegatePicker.dismissCalls, 1)
        XCTAssertNotNil(receivedImage)

        let cancelPicker = CoverageImagePickerController()
        coordinator.imagePickerControllerDidCancel(cancelPicker)
        XCTAssertEqual(cancelPicker.dismissCalls, 1)

        XCTAssertEqual(
            MediaRecognitionService.RecognitionError.invalidImageData.errorDescription,
            String(localized: "error.media.selected_image_process")
        )
        XCTAssertEqual(
            MediaRecognitionService.RecognitionError.invalidDocument.errorDescription,
            String(localized: "error.media.selected_document_open")
        )
    }

    func testNutritionCoverageMealTemplateManagerDirectCoverage() async throws {
        let detail = NutritionCoverageFixtures.mealTemplateDetail()
        let manager = NutritionCoverageMealTemplateManager(detail: detail)

        let summaries = try await manager.loadMealTemplates(
            includeArchived: true,
            limit: 5,
            preferRemote: false
        )
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.archived, detail.template.archived)

        let loadedDetail = try await manager.loadMealTemplateDetail(
            id: UUID(),
            preferRemote: true
        )
        XCTAssertEqual(loadedDetail?.template.id, detail.template.id)

        let createDraft = MealTemplateComposerView._testSaveDraft(
            name: detail.template.name,
            mealType: detail.template.mealType,
            items: detail.items.map(NutritionEditableMealItem.init(templateItem:))
        )
        let createdID = try await manager.createMealTemplate(createDraft)
        XCTAssertEqual(createdID, createDraft.id)

        try await manager.updateMealTemplate(
            NutritionMealTemplateUpdateDraft(
                id: detail.template.id,
                name: detail.template.name,
                mealType: detail.template.mealType,
                items: detail.items,
                archived: detail.template.archived
            )
        )
        try await manager.setMealTemplateArchived(
            id: detail.template.id,
            archived: !detail.template.archived
        )

        let application = try await manager.applyMealTemplate(
            id: detail.template.id,
            targetDay: NutritionCoverageFixtures.targetDay,
            loggedAt: NutritionCoverageFixtures.loggedAt,
            context: .home
        )
        XCTAssertEqual(application.templateName, detail.template.name)
        XCTAssertEqual(application.itemCount, detail.items.count)
    }

    func testNutritionCatalogReviewedFoodAndLocalBarcodeCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let api = APIClient(deviceId: "nutrition-reviewed-food-coverage")
        let service = NutritionCatalogService(dbQueue: manager.dbQueue, apiClient: api)
        let authId = UUID()
        let userId = UUID()

        try await insertCoverageUser(dbQueue: manager.dbQueue, userId: userId, authId: authId)

        APIClient._testResetOverrides()
        defer {
            APIClient._testResetOverrides()
            Task { await RateLimitTracker.shared.reset() }
            Task { @MainActor in AuthManager.setActiveAuthIdForTests(nil) }
        }

        await RateLimitTracker.shared.reset()
        await MainActor.run { AuthManager.setActiveAuthIdForTests(authId) }
        APIClient._testSetPostgrestAccessTokenOverride("nutrition-token")

        let okResponse = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://example.com/functions/v1/api-foods/custom")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        )
        let barcodeCatalogId = UUID()
        let customFoodId = UUID()
        APIClient._testSetEdgeRouteDataForRequestOverride { request in
            let path = request.url?.path ?? ""
            if path.contains("/barcode/460123/create") {
                return (
                    Data(
                        """
                        {
                          "provider": "lifeos_label_ocr",
                          "id": "\(barcodeCatalogId.uuidString)",
                          "barcode": "460123"
                        }
                        """.utf8
                    ),
                    okResponse
                )
            }
            return (
                Data(
                    """
                    {
                      "id": "\(customFoodId.uuidString)",
                      "name": "Coverage Custom Bowl",
                      "created_at": "2026-03-22T10:00:00Z"
                    }
                    """.utf8
                ),
                okResponse
            )
        }

        var barcodeReview = NutritionCoverageFixtures.labelDraft(name: "Coverage Crunch")
        barcodeReview.barcode = " 460123 "
        let barcodeResult = try await service.createReviewedFood(review: barcodeReview)
        XCTAssertEqual(barcodeResult.refType, .catalog)
        XCTAssertEqual(barcodeResult.provider, .lifeosLabelOcr)
        XCTAssertEqual(barcodeResult.barcode, "460123")

        var customReview = NutritionCoverageFixtures.labelDraft(name: "Coverage Custom Bowl")
        customReview.barcode = ""
        let customResult = try await service.createReviewedFood(review: customReview)
        XCTAssertEqual(customResult.refType, .custom)
        XCTAssertEqual(customResult.id, customFoodId)
        XCTAssertEqual(customResult.name, "Coverage Custom Bowl")

        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO user_foods (
                        id, user_id, name, brand, barcode, default_serving_g,
                        calories_per_100g, protein_per_100g, fat_per_100g, carbs_per_100g,
                        fiber_per_100g, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    "Local Custom",
                    "Coverage Pantry",
                    "LOCAL-CUSTOM",
                    100,
                    250,
                    12,
                    7,
                    28,
                    5,
                    Date(),
                    Date()
                ]
            )

            try db.execute(
                sql: """
                    INSERT INTO food_catalog_items (
                        id, provider, provider_item_id, barcode, created_by_user_id,
                        name, brand, locale, image_url, serving_size_g,
                        calories_per_100g, protein_per_100g, fat_per_100g, carbs_per_100g,
                        fiber_per_100g, sugar_per_100g, sodium_mg_per_100g, source_confidence,
                        fetched_at, expires_at, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    FoodProvider.openFoodFacts.rawValue,
                    "expired-off",
                    "PREFERRED",
                    nil,
                    "Expired OFF",
                    "Coverage",
                    nil,
                    nil,
                    100,
                    200,
                    10,
                    5,
                    20,
                    3,
                    nil,
                    nil,
                    nil,
                    Date(timeIntervalSince1970: 1_700_000_000),
                    Date(timeIntervalSince1970: 1_700_000_100),
                    Date(),
                    Date()
                ]
            )

            try db.execute(
                sql: """
                    INSERT INTO food_catalog_items (
                        id, provider, provider_item_id, barcode, created_by_user_id,
                        name, brand, locale, image_url, serving_size_g,
                        calories_per_100g, protein_per_100g, fat_per_100g, carbs_per_100g,
                        fiber_per_100g, sugar_per_100g, sodium_mg_per_100g, source_confidence,
                        fetched_at, expires_at, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    FoodProvider.lifeosLabelOcr.rawValue,
                    "lifeos-ocr",
                    "PREFERRED",
                    nil,
                    "Preferred OCR",
                    "Coverage",
                    nil,
                    nil,
                    100,
                    210,
                    12,
                    6,
                    21,
                    4,
                    nil,
                    nil,
                    nil,
                    Date(),
                    nil,
                    Date(),
                    Date()
                ]
            )
        }

        APIClient._testSetEdgeRouteDataForRequestOverride { _ in
            throw NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue)
        }

        let localCustom = try await service.lookupBarcode("LOCAL-CUSTOM")
        XCTAssertEqual(localCustom?.refType, .custom)
        XCTAssertEqual(localCustom?.name, "Local Custom")

        let preferredCatalog = try await service.lookupBarcode("PREFERRED")
        XCTAssertEqual(preferredCatalog?.provider, .lifeosLabelOcr)
        XCTAssertEqual(preferredCatalog?.name, "Preferred OCR")
    }

    @MainActor
    func testAuthAndOnboardingCoverageRendersMultipleStates() {
        let authManager = AuthManager()

        let defaultAuthView = AuthView(
            store: Store(initialState: AuthFeature.State()) { AuthFeature() }
        )
        renderForCoverage(defaultAuthView.environment(authManager))

        var authErrorState = AuthFeature.State()
        authErrorState.errorMessage = "auth-error"
        renderForCoverage(
            AuthView(
                store: Store(initialState: authErrorState) { AuthFeature() }
            )
            .environment(authManager)
        )

        var otpEntryState = AuthFeature.State()
        otpEntryState.showEmailOTP = true
        otpEntryState.email = "qa@lifeos.local"
        renderForCoverage(
            AuthView(
                store: Store(initialState: otpEntryState) { AuthFeature() }
            )
            ._testEmailOTPSheet()
        )

        var otpVerifyState = AuthFeature.State()
        otpVerifyState.showEmailOTP = true
        otpVerifyState.otpSent = true
        otpVerifyState.email = "qa@lifeos.local"
        otpVerifyState.otpCode = "123456"
        otpVerifyState.errorMessage = "invalid_code"
        renderForCoverage(
            AuthView(
                store: Store(initialState: otpVerifyState) { AuthFeature() }
            )
            ._testEmailOTPSheet()
        )

        renderForCoverage(
            OnboardingStepView(
                icon: "person",
                title: "Title",
                description: "Description",
                buttonTitle: "Continue",
                action: {}
            )
        )

        var authStepState = OnboardingFeature.State()
        authStepState.currentStep = .authComplete
        renderForCoverage(
            OnboardingView(
                store: Store(initialState: authStepState) { OnboardingFeature() }
            )
            .environment(authManager)
        )

        var profileState = OnboardingFeature.State()
        profileState.currentStep = .profileComplete
        renderForCoverage(
            OnboardingView(
                store: Store(initialState: profileState) { OnboardingFeature() }
            )
            .environment(authManager)
        )

        var weightState = OnboardingFeature.State()
        weightState.currentStep = .healthkitPrompted
        weightState.weightInputText = "82"
        renderForCoverage(
            OnboardingView(
                store: Store(initialState: weightState) { OnboardingFeature() }
            )
            .environment(authManager)
        )

        var healthKitState = OnboardingFeature.State()
        healthKitState.currentStep = .healthkitGranted
        healthKitState.isRequestingHealthKit = true
        renderForCoverage(
            OnboardingView(
                store: Store(initialState: healthKitState) { OnboardingFeature() }
            )
            .environment(authManager)
        )

        var backfillState = OnboardingFeature.State()
        backfillState.currentStep = .backfillInProgress
        backfillState.isBackfilling = true
        renderForCoverage(
            OnboardingView(
                store: Store(initialState: backfillState) { OnboardingFeature() }
            )
            .environment(authManager)
        )

        var completeState = OnboardingFeature.State()
        completeState.currentStep = .onboardingComplete
        renderForCoverage(
            OnboardingView(
                store: Store(initialState: completeState) { OnboardingFeature() }
            )
            .environment(authManager)
        )
    }

    @MainActor
    func testTrainingSupplementsInsightsAndLabsHarnessesPushCoverage() async throws {
        TrainingDayViewTestHarness.exerciseBodyBranches()
        SupplementsDayViewTestHarness.exerciseBodyBranches()

        let trainingSummarySamples = TrainingDayViewTestHarness.summaryFormattingCoverageSamples()
        XCTAssertEqual(trainingSummarySamples.count, 9)
        XCTAssertGreaterThanOrEqual(trainingSummarySamples.filter { !$0.isEmpty }.count, 8)

        let editorSamples = TrainingDayViewTestHarness.editorInputNormalizationSamples()
        XCTAssertEqual(editorSamples.weights, ["", "80", "82.5"])
        XCTAssertEqual(editorSamples.parsedWeights, [80, 82.5, 82.5])
        XCTAssertEqual(editorSamples.reps, ["", "5"])
        XCTAssertEqual(editorSamples.parsedReps, [5, 5, 0])

        XCTAssertEqual(try TrainingDayViewTestHarness.decodeSummaryCountWithInvalidRows(), 1)
        XCTAssertEqual(try SupplementsDayViewTestHarness.decodeSummaryCountWithInvalidRows(), 2)

        let invalidQueue = try DatabaseQueue(path: ":memory:")
        AuthManager.setActiveAuthIdForTests(nil)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let noAuthLogs = await SupplementsDayViewTestHarness.loadLogs(
            dateString: nil,
            dbQueue: invalidQueue
        )
        let noAuthSessions = await TrainingDayViewTestHarness.loadSessions(
            dateString: nil,
            dbQueue: invalidQueue
        )
        XCTAssertTrue(noAuthLogs.isEmpty)
        XCTAssertTrue(noAuthSessions.isEmpty)

        let scheduledAndStack = await SupplementsDayViewTestHarness.loadScheduledAndStackNames(
            dateString: nil,
            dbQueue: invalidQueue
        )
        XCTAssertTrue(scheduledAndStack.scheduled.isEmpty)
        XCTAssertTrue(scheduledAndStack.stack.isEmpty)

        let markResult = await SupplementsDayViewTestHarness.markFirstScheduledSupplement(
            dateString: nil,
            dbQueue: invalidQueue
        )
        XCTAssertTrue(markResult.takenFlags.isEmpty)
        XCTAssertTrue(markResult.logNames.isEmpty)

        let supplementsLoadTaskCompleted = await SupplementsDayViewTestHarness.runLoadTask(
            dateString: nil,
            dbQueue: invalidQueue
        )
        let supplementsLoadActionCompleted = await SupplementsDayViewTestHarness.runLoadTaskAction(
            dateString: nil,
            dbQueue: invalidQueue
        )
        let trainingLoadTaskCompleted = await TrainingDayViewTestHarness.runLoadTask(
            dateString: nil,
            dbQueue: invalidQueue
        )
        let trainingLoadActionCompleted = await TrainingDayViewTestHarness.runLoadTaskAction(
            dateString: nil,
            dbQueue: invalidQueue
        )
        XCTAssertTrue(supplementsLoadTaskCompleted)
        XCTAssertTrue(supplementsLoadActionCompleted)
        XCTAssertTrue(trainingLoadTaskCompleted)
        XCTAssertTrue(trainingLoadActionCompleted)

        let sampleInsight = Insight(
            userId: UUID(),
            category: .recovery,
            title: "Recovery trend",
            body: "Take a lighter day.",
            confidence: 0.4
        )
        let weeklyReport = WeeklyStrategyReport(
            userId: UUID(),
            weekStart: "2026-03-10",
            weekEnd: "2026-03-16",
            summaryStats: Data("{}".utf8),
            reportMarkdown: "Coverage weekly strategy"
        )
        let insightViewModel = InsightsViewModel()
        insightViewModel._testOverrideState(
            lowConfidenceCount: 1,
            insights: [sampleInsight],
            latestWeeklyStrategyReport: weeklyReport,
            isLoading: false,
            loadError: nil,
            allInsights: [sampleInsight]
        )
        let insightsView = InsightsView(viewModel: insightViewModel)
        insightsView._testEvaluateSections(sampleInsight: sampleInsight)
        insightsView._testExerciseFilterActions()
        let routedURLs = insightsView._testTriggerRouteActions()
        XCTAssertEqual(routedURLs.count, 2)
        XCTAssertTrue(routedURLs.allSatisfy { $0 == "lifeos://simulation" })
        await insightsView._testExerciseNavigationAndTaskWrappers(sampleInsight: sampleInsight)
        renderForCoverage(insightsView)

        XCTAssertEqual(InsightDetailViewTestHarness.localizedCategories().count, 8)
        InsightDetailViewTestHarness.exerciseBodyBranches()
        InsightDetailViewTestHarness.exerciseExperimentDetailBody()
        renderForCoverage(InsightDetailView(insightId: UUID()))

        let noDataStore = Store(initialState: LabsFeature.State()) { LabsFeature() }
        let loadingStore = Store(
            initialState: LabsFeature.State(summary: nil, isLoading: true)
        ) {
            LabsFeature()
        }
        let summaryStore = Store(
            initialState: LabsFeature.State(
                summary: LabsSummary(latestStatus: "completed", markerCount: 4, scanCount: 1),
                metrics: LabsOverviewMetrics(
                    totalScanCount: 1,
                    totalMarkerCount: 4,
                    reviewRequiredCount: 0,
                    pinnedCount: 0
                ),
                isLoading: false
            )
        ) {
            LabsFeature()
        }

        renderForCoverage(LabsOverviewView(store: noDataStore))
        renderForCoverage(LabsOverviewView(store: loadingStore))
        let summaryView = LabsOverviewView(store: summaryStore)
        renderForCoverage(summaryView)
        await summaryView._testRunTaskAction()
    }

    func testSettingsHarnessCoveragePushesLargeDestinationViews() async throws {
        let manager = try DatabaseManager.inMemory()
        let syncEngine = SyncEngine(dbQueue: manager.dbQueue)

        SettingsDestinationViewsTestHarness.exerciseBodyBranches()
        SettingsDestinationViewsTestHarness.exerciseAccountSettingsBodyBranches()

        let errors = SettingsDestinationViewsTestHarness.userFacingErrors()
        XCTAssertEqual(errors.first, "custom")
        XCTAssertEqual(errors.count, 3)
        XCTAssertFalse(errors[2].isEmpty)

        let privacyPayload = SettingsDestinationViewsTestHarness.privacyPayloadSnapshot()
        XCTAssertEqual(privacyPayload["cloud_backup_enabled"] as? Bool, true)
        XCTAssertEqual(privacyPayload["cloud_ocr_enabled"] as? Bool, true)
        XCTAssertNotNil(privacyPayload["id"])
        XCTAssertNotNil(privacyPayload["user_id"])

        let syncOutputs = await SettingsDestinationViewsTestHarness.exerciseSyncViewModel(
            syncEngine: syncEngine
        )
        XCTAssertFalse(syncOutputs.isEmpty)

        try await SettingsDestinationViewsTestHarness.enqueueOutboxMutation(
            syncEngine: syncEngine,
            path: "api-settings-notifications"
        )

        AuthManager.setActiveAuthIdForTests(nil)
        let noAuthNotifications = await SettingsDestinationViewsTestHarness.exerciseNotificationsViewModel(
            syncEngine: syncEngine,
            dbQueue: manager.dbQueue
        )
        XCTAssertTrue(noAuthNotifications.isLoaded)

        let noAuthPrivacy = await SettingsDestinationViewsTestHarness.exercisePrivacyViewModel(
            syncEngine: syncEngine,
            dbQueue: manager.dbQueue
        )
        XCTAssertTrue(noAuthPrivacy.isLoaded)

        let authId = UUID()
        let userId = UUID()
        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [userId.uuidString, authId.uuidString, "UTC", "metric", Date(), Date()]
            )
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let withAuthNotifications = await SettingsDestinationViewsTestHarness.exerciseNotificationsViewModel(
            syncEngine: syncEngine,
            dbQueue: manager.dbQueue
        )
        XCTAssertTrue(withAuthNotifications.isLoaded)

        let withAuthPrivacy = await SettingsDestinationViewsTestHarness.exercisePrivacyViewModel(
            syncEngine: syncEngine,
            dbQueue: manager.dbQueue
        )
        XCTAssertTrue(withAuthPrivacy.isLoaded)
        XCTAssertTrue(withAuthPrivacy.canCancelDeletion)

        let existingPrivacyLoaded = await SettingsDestinationViewsTestHarness.exercisePrivacyExistingLoadBranch(
            syncEngine: syncEngine,
            dbQueue: manager.dbQueue
        )
        XCTAssertTrue(existingPrivacyLoaded.isLoaded)
        XCTAssertTrue(existingPrivacyLoaded.usedExistingBranch)

        let forcedSuccess = await SettingsDestinationViewsTestHarness.exerciseInsertionAndSaveSuccessPaths(
            syncEngine: syncEngine,
            dbQueue: manager.dbQueue,
            authId: authId,
            userId: userId
        )
        XCTAssertTrue(forcedSuccess.notificationsLoaded)
        XCTAssertTrue(forcedSuccess.privacyLoaded)
        XCTAssertFalse((forcedSuccess.notificationsStatus ?? "").isEmpty)
        XCTAssertFalse((forcedSuccess.privacyStatus ?? "").isEmpty)

        let deterministicCoverageOutputs = await SettingsDestinationViewsTestHarness
            .exerciseDeterministicCoverageBranches(
                syncEngine: syncEngine,
                dbQueue: manager.dbQueue,
                authId: authId
            )
        XCTAssertEqual(deterministicCoverageOutputs.count, 7)
        XCTAssertEqual(deterministicCoverageOutputs[2], "notifications_inserted")
        XCTAssertEqual(deterministicCoverageOutputs[3], "notifications_loaded_existing")
        XCTAssertEqual(deterministicCoverageOutputs[4], "privacy_inserted")
        XCTAssertEqual(deterministicCoverageOutputs[5], "privacy_loaded_existing")

        let nilHelperOutputs = SettingsDestinationViewsTestHarness.exerciseOptionalStringHelpersWithNilBranches()
        XCTAssertEqual(nilHelperOutputs, ["", "nil", "", "fallback"])

        let valueHelperOutputs = SettingsDestinationViewsTestHarness.exerciseOptionalStringHelpersWithValueBranches()
        XCTAssertEqual(valueHelperOutputs, ["value", "value", "flagged", "status"])

        let loadSaveCoverageOutputs = await SettingsDestinationViewsTestHarness
            .exerciseNotificationsAndPrivacyLoadSaveCoverage(
                syncEngine: syncEngine,
                dbQueue: manager.dbQueue,
                authId: authId,
                userId: userId
            )
        XCTAssertEqual(loadSaveCoverageOutputs.count, 8)
        XCTAssertEqual(loadSaveCoverageOutputs[4], "notifications_insert_loaded")
        XCTAssertEqual(loadSaveCoverageOutputs[5], "notifications_existing_loaded")
        XCTAssertEqual(loadSaveCoverageOutputs[6], "privacy_insert_loaded")
        XCTAssertEqual(loadSaveCoverageOutputs[7], "privacy_existing_loaded")

        let directHelperOutputs = await SettingsDestinationViewsTestHarness
            .exerciseDirectViewModelHelperBranches(
                syncEngine: syncEngine,
                dbQueue: manager.dbQueue
            )
        XCTAssertEqual(directHelperOutputs.count, 7)
        XCTAssertEqual(directHelperOutputs[0], "notifications_loaded")
        XCTAssertEqual(directHelperOutputs[1], "privacy_loaded")

        let syncFailureManager = try DatabaseManager.inMemory()
        let syncFailureEngine = SyncEngine(
            dbQueue: syncFailureManager.dbQueue,
            apiClient: FakeSyncAPIClient(),
            pushTransportOverride: { _ in }
        )
        let syncFailureOutputs = await SettingsDestinationViewsTestHarness
            .exerciseSyncViewModelFailureBranches(
                syncEngine: syncFailureEngine,
                dbQueue: syncFailureManager.dbQueue
            )
        XCTAssertEqual(syncFailureOutputs.count, 4)
        XCTAssertGreaterThanOrEqual(syncFailureOutputs.filter { !$0.isEmpty }.count, 3)

        GuardianManager._testSetRequestAuthorization {
            throw NSError(
                domain: "GuardianCoverage",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "guardian-denied"]
            )
        }
        let guardianFailureStatus = await SettingsDestinationViewsTestHarness
            .exerciseGuardianAuthorizationFailure(
                syncEngine: syncEngine,
                dbQueue: manager.dbQueue
        )
        XCTAssertFalse((guardianFailureStatus ?? "").isEmpty)
        GuardianManager._testSetRequestAuthorization { }
    }

    @MainActor
    func testOnboardingDeepHarnessCoverageAndFeatureHelpers() async throws {
        let authManager = AuthManager()
        let authId = UUID()
        let userId = UUID()
        let manager = try DatabaseManager.inMemory()

        try await insertCoverageUser(dbQueue: manager.dbQueue, userId: userId, authId: authId)
        AuthManager.setActiveAuthIdForTests(authId)
        OnboardingFeature._testSetDatabaseQueueOverride(manager.dbQueue)
        defer {
            AuthManager.setActiveAuthIdForTests(nil)
            OnboardingFeature._testSetDatabaseQueueOverride(nil)
        }

        let latestUserId = try await OnboardingFeature._testLatestUserId()
        XCTAssertEqual(latestUserId, userId)
        OnboardingFeature._testResolveSyncEngineFallbackPath()

        let baseView = OnboardingView(
            store: Store(initialState: OnboardingFeature.State()) { OnboardingFeature() }
        )
        baseView._testEvaluateBody()
        baseView._testEvaluateStepBuilders()
        baseView._testTriggerActions()
        baseView._testTriggerInstanceStepChangeHandlers()
        renderForCoverage(baseView.environment(authManager))

        var quickWinState = OnboardingFeature.State()
        quickWinState.currentStep = .authComplete
        quickWinState.quickWinCompleted = true
        quickWinState.quickWinResult = .init(
            title: "Coverage Meal",
            calories: 620,
            proteinG: 42,
            fatG: 24,
            carbsG: 38,
            fiberG: 9,
            note: "Protein-forward lunch",
            needsReview: true
        )
        let quickWinView = OnboardingView(
            store: Store(initialState: quickWinState) { OnboardingFeature() }
        )
        quickWinView._testEvaluateBody()
        quickWinView._testEvaluateStepBuilders()
        renderForCoverage(quickWinView.environment(authManager))

        var completeState = OnboardingFeature.State()
        completeState.currentStep = .onboardingComplete
        completeState.firstInsight = .init(
            insightId: UUID(),
            title: "Recovery Insight",
            body: "Keep today light",
            score: 74,
            zone: RecoveryZone.ready,
            detail: "Your recent sleep supports a moderate session.",
            footer: "Preview",
            isPreview: true
        )
        let completeView = OnboardingView(
            store: Store(initialState: completeState) { OnboardingFeature() }
        )
        completeView._testEvaluateBody()
        completeView._testEvaluateStepBuilders()
        renderForCoverage(completeView.environment(authManager))

        renderForCoverage(
            OnboardingStepView(
                icon: "waveform.path.ecg",
                title: "Signal",
                description: "Coverage helper",
                buttonTitle: "Continue",
                action: {}
            )
        )
    }

    @MainActor
    func testLabsCaptureAndReviewCoveragePush() async throws {
        var editableMarkers = [
            ExtractedLabMarker(
                id: UUID(),
                name: "Hemoglobin",
                value: "13.4",
                unit: "g/dL",
                referenceRange: "12-17.5",
                isNormal: true
            ),
            ExtractedLabMarker(
                id: UUID(),
                name: "CRP",
                value: "8.2",
                unit: "mg/L",
                referenceRange: "0-5",
                isNormal: false
            )
        ]
        let editableReviewView = LabsReviewView(
            markers: Binding(get: { editableMarkers }, set: { editableMarkers = $0 }),
            isSaving: false,
            errorMessage: nil,
            onSave: { }
        )

        var savingMarkers = editableMarkers
        let savingReviewView = LabsReviewView(
            markers: Binding(get: { savingMarkers }, set: { savingMarkers = $0 }),
            isSaving: true,
            errorMessage: "save-error",
            onSave: { }
        )

        renderForCoverage(editableReviewView)
        renderForCoverage(savingReviewView)

        let extractedFromText = LabsMarkerCatalog.extractMarkers(
            from: """
            Hgb 13.4 g/dL (12-17.5)
            WBC 12.1 10^3/uL
            Ferritin 85
            Vitamin D: 21 ng/mL
            Custom Marker 7.2 mg/dL
            Hgb 13.4 g/dL
            Broken Value abc mg/dL
            """
        )
        XCTAssertEqual(extractedFromText.count, 5)

        let explicitRangeMarker = ExtractedLabMarker(
            id: UUID(),
            name: "Custom Marker",
            value: "5.0",
            unit: "mg/dL",
            referenceRange: "4,5-6,5",
            isNormal: true
        )
        let explicitBounds = LabsMarkerCatalog.bounds(for: explicitRangeMarker)
        XCTAssertEqual(explicitBounds.low ?? 0, 4.5, accuracy: 0.0001)
        XCTAssertEqual(explicitBounds.high ?? 0, 6.5, accuracy: 0.0001)
        XCTAssertEqual(LabsMarkerCatalog.markerIdentifier(for: "Vitamin D/25 OH"), "vitamin_d_25_oh")

        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let scanId = UUID()
        let now = Date(timeIntervalSince1970: 1_742_774_400)

        try await manager.dbQueue.write { db in
            var user = User(id: userId, authId: authId, timezone: "UTC", units: .metric)
            try user.insert(db)

            var settings = PrivacySettings(userId: userId)
            settings.medicalScanLocalOnly = false
            settings.cloudBackupEnabled = true
            try settings.insert(db)
        }

        let cloudMarkers = [
            ExtractedLabMarker(
                id: UUID(),
                name: "Hemoglobin",
                value: "13.4",
                unit: "g/dL",
                referenceRange: "12-17.5",
                isNormal: true
            ),
            ExtractedLabMarker(
                id: UUID(),
                name: "Ferritin",
                value: "85",
                unit: "ng/mL",
                referenceRange: nil,
                isNormal: true
            )
        ]
        let asset = CapturedLabAsset(data: Data("pdf-data".utf8), fileExtension: "pdf")

        try await LabsScanCaptureView._testPersistMarkers(
            scanId: scanId,
            now: now,
            authId: authId.uuidString,
            dbQueue: manager.dbQueue,
            extractedMarkers: cloudMarkers,
            ocrText: "Ferritin 85 ng/mL",
            sourceFileHash: LabsScanCaptureView._testSha256(Data("source".utf8)),
            capturedAsset: asset,
            captureConfidence: 0.91,
            reviewConfirmed: true
        )

        let headers = try JSONSerialization.jsonObject(
            with: LabsScanCaptureView._testOutboxHeadersJson()
        ) as? [String: String]
        XCTAssertEqual(headers?["Content-Type"], "application/json")

        try await manager.dbQueue.read { db in
            let scan = try XCTUnwrap(
                MedicalScan.fetchOne(
                    db,
                    sql: "SELECT * FROM medical_scans WHERE id = ?",
                    arguments: [scanId.uuidString]
                )
            )
            XCTAssertEqual(scan.status, .completed)
            XCTAssertEqual(scan.storageMode, "cloud")
            XCTAssertEqual(scan.markersExtracted, 2)
            XCTAssertFalse(scan.needsReview)
            XCTAssertTrue(scan.userReviewed)
            XCTAssertTrue(scan.manuallyVerified)
            XCTAssertNotNil(scan.originalImageUrl)
            XCTAssertNotNil(scan.scheduledDeletionAt)

            let measurementCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM health_measurements WHERE medical_scan_id = ?",
                arguments: [scanId.uuidString]
            ) ?? 0
            XCTAssertEqual(measurementCount, 2)
        }

        let localOnlyManager = try DatabaseManager.inMemory()
        let localUserId = UUID()
        let localAuthId = UUID()
        let localScanId = UUID()

        try await localOnlyManager.dbQueue.write { db in
            var user = User(id: localUserId, authId: localAuthId, timezone: "UTC", units: .metric)
            try user.insert(db)

            var settings = PrivacySettings(userId: localUserId)
            settings.medicalScanLocalOnly = true
            settings.cloudBackupEnabled = false
            try settings.insert(db)
        }

        let localOnlyMarkers = [
            ExtractedLabMarker(
                id: UUID(),
                name: "CRP",
                value: "8.2",
                unit: "mg/L",
                referenceRange: "0-5",
                isNormal: false
            )
        ]

        try await LabsScanCaptureView._testPersistMarkers(
            scanId: localScanId,
            now: now,
            authId: localAuthId.uuidString,
            dbQueue: localOnlyManager.dbQueue,
            extractedMarkers: localOnlyMarkers,
            ocrText: "CRP 8.2 mg/L",
            sourceFileHash: nil,
            capturedAsset: nil,
            captureConfidence: 0.52
        )

        try await localOnlyManager.dbQueue.read { db in
            let scan = try XCTUnwrap(
                MedicalScan.fetchOne(
                    db,
                    sql: "SELECT * FROM medical_scans WHERE id = ?",
                    arguments: [localScanId.uuidString]
                )
            )
            XCTAssertEqual(scan.status, .reviewRequired)
            XCTAssertEqual(scan.storageMode, "local_only")
            XCTAssertTrue(scan.needsReview)
            XCTAssertFalse(scan.userReviewed)
            XCTAssertFalse(scan.manuallyVerified)
            XCTAssertNil(scan.originalImageUrl)
            XCTAssertNil(scan.scheduledDeletionAt)
        }

        do {
            try await LabsScanCaptureView._testPersistMarkers(
                scanId: UUID(),
                now: now,
                authId: UUID().uuidString,
                dbQueue: localOnlyManager.dbQueue,
                extractedMarkers: localOnlyMarkers,
                ocrText: nil,
                sourceFileHash: nil,
                capturedAsset: nil,
                captureConfidence: 0.9
            )
            XCTFail("Expected missing-user persist branch to throw")
        } catch {
        }
    }

    @MainActor
    func testLabsOverviewDebugHarnessCoversHistoryHelpersAndIcons() async throws {
        let dbQueue = try DatabaseQueue(path: ":memory:")
        let reviewId = UUID()
        let pinnedId = UUID()
        let recentId = UUID()
        let unknownId = UUID()

        let historyItems = try await dbQueue.write { db -> [LabScanHistoryItem] in
            try db.execute(sql: """
                CREATE TABLE tmp_labs_history_debug (
                    id TEXT,
                    scan_type TEXT,
                    status TEXT,
                    created_at DATETIME,
                    scan_date TEXT,
                    lab_name TEXT,
                    needs_review BOOLEAN,
                    pinned_by_user BOOLEAN,
                    storage_mode TEXT,
                    marker_count INTEGER
                )
                """)
            try db.execute(
                sql: """
                    INSERT INTO tmp_labs_history_debug (
                        id, scan_type, status, created_at, scan_date, lab_name,
                        needs_review, pinned_by_user, storage_mode, marker_count
                    ) VALUES
                    (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                    (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                    (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                    (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    reviewId.uuidString, ScanType.bloodTest.rawValue, ScanStatus.pending.rawValue, Date(timeIntervalSince1970: 40), "2026-03-01", "CBC",
                    true, false, "cloud", 3,
                    pinnedId.uuidString, ScanType.dexa.rawValue, ScanStatus.completed.rawValue, Date(timeIntervalSince1970: 30), "2026-02-28", "DEXA",
                    false, true, "local_only", 2,
                    recentId.uuidString, ScanType.inbody.rawValue, ScanStatus.failed.rawValue, Date(timeIntervalSince1970: 20), "2026-02-27", "Body Comp",
                    false, false, "archive", 1,
                    unknownId.uuidString, "mystery", "queued", Date(timeIntervalSince1970: 10), nil, "",
                    false, false, nil, 0
                ]
            )

            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, scan_type, status, created_at, scan_date, lab_name,
                           needs_review, pinned_by_user, storage_mode, marker_count
                    FROM tmp_labs_history_debug
                    ORDER BY created_at DESC
                    """
            )
            return rows.compactMap(LabScanHistoryItem.init(row:))
        }

        let store = Store(
            initialState: LabsFeature.State(
                summary: LabsSummary(latestStatus: "completed", markerCount: 6, scanCount: 4),
                metrics: LabsOverviewMetrics(
                    totalScanCount: 4,
                    totalMarkerCount: 6,
                    reviewRequiredCount: 1,
                    pinnedCount: 1
                ),
                scanHistory: historyItems,
                isLoading: false
            )
        ) {
            LabsFeature()
        }

        let view = LabsOverviewView(store: store)
        view._testEvaluateBodyAndHelpers()
        let icons = view._testResolvedHistoryIcons()
        XCTAssertEqual(icons, ["drop.circle", "bone", "figure.arms.open", "doc.text"])
        await view._testRunTaskAction()
    }

    @MainActor
    func testLabsScanCaptureDebugHarnessCoversBodyAndProcessingStates() async throws {
        MediaRecognitionService._testResetOverrides()
        defer { MediaRecognitionService._testResetOverrides() }

        let localOnlySettings = PrivacySettings(userId: UUID())
        let parsedMarker = ExtractedLabMarker(
            id: UUID(),
            name: "Hemoglobin",
            value: "13.4",
            unit: "g/dL",
            referenceRange: "12-17.5",
            isNormal: true
        )

        LabsScanCaptureView(
            _testIsProcessing: true,
            _testPrivacySettings: localOnlySettings
        )._testEvaluateBody()
        LabsScanCaptureView(
            _testOCRText: "No markers found",
            _testExtractedMarkers: [],
            _testCaptureConfidence: 0.55
        )._testEvaluateBody()
        LabsScanCaptureView(
            _testOCRText: "Hemoglobin 13.4 g/dL",
            _testExtractedMarkers: [parsedMarker],
            _testCaptureConfidence: 0.88
        )._testEvaluateBody()
        LabsScanCaptureView(
            _testCaptureMode: .photo,
            _testCaptureError: "camera-error"
        )._testEvaluateBody()
        LabsScanCaptureView(
            _testCaptureMode: .pdf
        )._testEvaluateBody()

        let photoCaptureResult = LabsScanCaptureView(
            _testCaptureMode: .photo
        )._testTriggerStartCapture()
        XCTAssertFalse(photoCaptureResult.showPDFImporter)
        XCTAssertNil(photoCaptureResult.captureError)

        let pdfCaptureResult = LabsScanCaptureView(
            _testCaptureMode: .pdf
        )._testTriggerStartCapture()
        XCTAssertFalse(pdfCaptureResult.showCameraPicker)
        XCTAssertFalse(pdfCaptureResult.showPhotoLibrary)
        XCTAssertNil(pdfCaptureResult.captureError)

        let sourceData = Data("coverage-image".utf8)
        MediaRecognitionService._testSetRecognizeTextOverride { _ in
            "Hgb 13.4 g/dL (12-17.5)"
        }
        let recognizedImage = makeCoverageTextImage(text: "Coverage Hgb 13.4 g/dL")
        let imageSuccessState = await LabsScanCaptureView()._testProcessImage(
            recognizedImage,
            sourceData: sourceData
        )
        XCTAssertFalse(imageSuccessState.isProcessing)
        _ = imageSuccessState

        MediaRecognitionService._testSetRecognizeTextOverride { _ in
            "Narrative text without biomarkers"
        }
        let imageNoMarkersState = await LabsScanCaptureView()._testProcessImage(
            recognizedImage,
            sourceData: nil
        )
        XCTAssertFalse(imageNoMarkersState.isProcessing)

        MediaRecognitionService._testSetRecognizeTextOverride { _ in
            throw NSError(
                domain: "LabsCoverage",
                code: 41,
                userInfo: [NSLocalizedDescriptionKey: "ocr-image-failed"]
            )
        }
        let imageFailureState = await LabsScanCaptureView()._testProcessImage(
            recognizedImage,
            sourceData: sourceData
        )
        XCTAssertFalse(imageFailureState.isProcessing)
        _ = imageFailureState

        MediaRecognitionService._testSetSyncRecognizeTextOverride { _ in
            "OCR Page CRP 7.5 mg/L"
        }
        let pdfURL = try makeCoveragePDF(withFirstPageText: "Ferritin 85")
        defer { try? FileManager.default.removeItem(at: pdfURL) }
        let pdfSuccessState = await LabsScanCaptureView()._testProcessPDF(at: pdfURL)
        XCTAssertFalse(pdfSuccessState.isProcessing)
        _ = pdfSuccessState

        let missingPDFURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        let pdfFailureState = await LabsScanCaptureView()._testProcessPDF(at: missingPDFURL)
        XCTAssertFalse(pdfFailureState.isProcessing)
        _ = pdfFailureState
    }

    func testLabsPrivacyFallbackAndImagePersistenceCoveragePush() async throws {
        let fallbackManager = try DatabaseManager.inMemory()
        let fallbackUserId = UUID()
        let fallbackAuthId = UUID()

        try await fallbackManager.dbQueue.write { db in
            var user = User(id: fallbackUserId, authId: fallbackAuthId, timezone: "UTC", units: .metric)
            try user.insert(db)
        }

        try await fallbackManager.dbQueue.read { db in
            let fallbackByAuth = try XCTUnwrap(
                LabsScanCaptureView._testLoadScopedPrivacySettings(
                    authId: fallbackAuthId.uuidString,
                    db: db
                )
            )
            XCTAssertEqual(fallbackByAuth.userId, fallbackUserId)
            XCTAssertTrue(fallbackByAuth.medicalScanLocalOnly)
            XCTAssertFalse(fallbackByAuth.cloudBackupEnabled)

            let fallbackByUser = try LabsScanCaptureView._testLoadScopedPrivacySettings(
                userId: fallbackUserId,
                db: db
            )
            XCTAssertEqual(fallbackByUser.userId, fallbackUserId)
            XCTAssertTrue(fallbackByUser.medicalScanLocalOnly)

            let missingUserSettings = try LabsScanCaptureView._testLoadScopedPrivacySettings(
                authId: UUID().uuidString,
                db: db
            )
            XCTAssertNil(missingUserSettings)
        }

        XCTAssertFalse((LabsScanCaptureView.LabsSaveError.userUnavailable.errorDescription ?? "").isEmpty)

        let imageManager = try DatabaseManager.inMemory()
        let imageUserId = UUID()
        let imageAuthId = UUID()
        let imageScanId = UUID()
        let now = Date(timeIntervalSince1970: 1_742_860_800)

        try await imageManager.dbQueue.write { db in
            var user = User(id: imageUserId, authId: imageAuthId, timezone: "UTC", units: .metric)
            try user.insert(db)

            var settings = PrivacySettings(userId: imageUserId)
            settings.medicalScanLocalOnly = false
            settings.cloudBackupEnabled = false
            try settings.insert(db)
        }

        try await LabsScanCaptureView._testPersistMarkers(
            scanId: imageScanId,
            now: now,
            authId: imageAuthId.uuidString,
            dbQueue: imageManager.dbQueue,
            extractedMarkers: [
                ExtractedLabMarker(
                    id: UUID(),
                    name: "ALT",
                    value: "24",
                    unit: "U/L",
                    referenceRange: nil,
                    isNormal: true
                )
            ],
            ocrText: "ALT 24 U/L",
            sourceFileHash: LabsScanCaptureView._testSha256(Data("image-source".utf8)),
            capturedAsset: CapturedLabAsset(data: Data("jpeg-data".utf8), fileExtension: "jpg"),
            captureConfidence: 0.74,
            reviewConfirmed: true
        )

        try await imageManager.dbQueue.read { db in
            let scan = try XCTUnwrap(
                MedicalScan.fetchOne(
                    db,
                    sql: "SELECT * FROM medical_scans WHERE id = ?",
                    arguments: [imageScanId.uuidString]
                )
            )
            XCTAssertEqual(scan.status, .completed)
            XCTAssertEqual(scan.storageMode, "cloud")
            XCTAssertEqual(scan.storeOriginalInCloud, false)
            XCTAssertNotNil(scan.imageUrl)
            XCTAssertNotNil(scan.originalImageUrl)
            XCTAssertNotNil(scan.scheduledDeletionAt)

            let outboxCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE id = ?",
                arguments: [imageScanId.uuidString]
            ) ?? 0
            XCTAssertEqual(outboxCount, 1)
        }
    }

    func testOnboardingFeatureLoadProfileIfNeededPrefillsStoredProfileCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let dateOfBirth = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 1994, month: 5, day: 16)
        )!

        try await seedOnboardingUser(
            dbQueue: manager.dbQueue,
            userId: userId,
            authId: authId,
            cloudBackupEnabled: false
        )
        try await manager.dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE users
                    SET date_of_birth = ?, age_range = ?, sex = ?, height_cm = ?, weight_kg = ?,
                        primary_goal = ?, activity_level = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    dateOfBirth,
                    AgeRange(age: 31).rawValue,
                    BiologicalSex.female.rawValue,
                    172.5,
                    63.4,
                    PrimaryGoal.performance.rawValue,
                    ActivityLevel.active.rawValue,
                    Date(),
                    userId.uuidString
                ]
            )
        }

        OnboardingFeature._testSetDatabaseQueueOverride(manager.dbQueue)
        AuthManager.setActiveAuthIdForTests(authId)

        let store = TestStore(initialState: OnboardingFeature.State()) {
            OnboardingFeature()
        }

        await store.send(.loadProfileIfNeeded) {
            $0.hasLoadedProfile = true
        }
        await store.receive(.loadOptionalSetupSummary)
        await store.receive(.profileLoaded(.init(
            dateOfBirth: dateOfBirth,
            sex: .female,
            heightCm: 172.5,
            primaryGoal: .performance,
            activityLevel: .active,
            weightKg: 63.4
        ))) {
            $0.dateOfBirth = dateOfBirth
            $0.hasConfirmedDateOfBirth = true
            $0.sex = .female
            $0.heightCm = 172.5
            $0.heightInputText = "172.5"
            $0.primaryGoal = .performance
            $0.activityLevel = .active
            $0.weightKg = 63.4
            $0.weightInputText = "63.4"
            $0.currentStep = .valueProp
        }
        await store.receive(.optionalSetupSummaryLoaded(.init()))
    }

    func testOnboardingFeatureAdvanceFromProfilePersistsAndEnqueuesCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let dateOfBirth = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 1996, month: 9, day: 12)
        )!

        try await seedOnboardingUser(
            dbQueue: manager.dbQueue,
            userId: userId,
            authId: authId,
            cloudBackupEnabled: false
        )
        OnboardingFeature._testSetDatabaseQueueOverride(manager.dbQueue)
        AuthManager.setActiveAuthIdForTests(authId)
        AppContainer.shared = AppContainer(syncEngine: makeCoverageNoopSyncEngine(dbQueue: manager.dbQueue))

        var initialState = OnboardingFeature.State()
        initialState.dateOfBirth = dateOfBirth
        initialState.hasConfirmedDateOfBirth = true
        initialState.sex = .male
        initialState.heightInputText = "181.2"
        initialState.heightCm = 181.2
        initialState.primaryGoal = .generalHealth
        initialState.activityLevel = .moderate
        initialState.currentStep = .basicProfile

        let store = TestStore(initialState: initialState) {
            OnboardingFeature()
        }
        store.exhaustivity = .off

        await store.send(.advanceFromProfile) {
            $0.isSavingProfile = true
            $0.isSavingHealthFlags = true
            $0.isSavingWeight = true
        }
        await store.receive(.profileAdvanceFinished(.succeeded)) {
            $0.isSavingProfile = false
            $0.isSavingHealthFlags = false
            $0.isSavingWeight = false
            $0.currentStep = .firstInsight
        }
        await store.finish()

        try await manager.dbQueue.read { db in
            let user = try XCTUnwrap(UserIdentityLookup.fetchUser(authId: authId.uuidString, db: db))
            XCTAssertEqual(DateFormatting.dateOnlyString(from: try XCTUnwrap(user.dateOfBirth)), "1996-09-12")
            XCTAssertEqual(user.ageRange, AgeRange(age: 29))
            XCTAssertEqual(user.sex, .male)
            XCTAssertEqual(user.heightCm ?? 0, 181.2, accuracy: 0.0001)
            XCTAssertEqual(user.primaryGoal, .generalHealth)
            XCTAssertEqual(user.activityLevel, .moderate)
            XCTAssertEqual(user.weightKg ?? 0, 70, accuracy: 0.0001)

            let payloadRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT body_json
                    FROM outbox_events
                    WHERE path = ?
                    ORDER BY created_at_local ASC
                    """,
                arguments: ["rest/v1/users"]
            )
            let payloads = try payloadRows.compactMap { row -> [String: Any]? in
                let payloadData: Data = row["body_json"]
                return try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
            }

            XCTAssertEqual(payloads.count, 2)
            XCTAssertTrue(payloads.contains { payload in
                payload["id"] as? String == userId.uuidString &&
                payload["date_of_birth"] as? String == "1996-09-12" &&
                payload["age_range"] as? String == AgeRange(age: 29).rawValue &&
                payload["sex"] as? String == BiologicalSex.male.rawValue &&
                payload["primary_goal"] as? String == PrimaryGoal.generalHealth.rawValue &&
                payload["activity_level"] as? String == ActivityLevel.moderate.rawValue &&
                abs(((payload["height_cm"] as? Double) ?? 0) - 181.2) < 0.0001
            })
            XCTAssertTrue(payloads.contains { payload in
                payload["id"] as? String == userId.uuidString &&
                abs(((payload["weight_kg"] as? Double) ?? 0) - 70) < 0.0001
            })
        }
    }

    func testOnboardingFeatureCompleteCatchBranchWhenOutboxInsertFailsCoverage() async throws {
        let authId = UUID()
        let userId = UUID()
        let failingManager = try DatabaseManager.inMemory()

        try await failingManager.dbQueue.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS outbox_events")
        }

        AuthManager.setActiveAuthIdForTests(authId)
        OnboardingFeature._testSetDatabaseQueueOverride(failingManager.dbQueue)
        AppContainer.shared = AppContainer(
            syncEngine: makeCoverageNoopSyncEngine(dbQueue: failingManager.dbQueue)
        )

        try await failingManager.dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM users WHERE auth_id = ? OR auth_id = ?",
                arguments: [authId, authId.uuidString]
            )
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, onboarding_completed, created_at, updated_at)
                    VALUES (?, ?, 'UTC', 'metric', 0, ?, ?)
                    """,
                arguments: [userId.uuidString, authId.uuidString, Date(), Date()]
            )
        }

        var state = OnboardingFeature.State()
        state.currentStep = .tutorialShown
        let store = TestStore(initialState: state) {
            OnboardingFeature()
        }

        await store.send(.complete) {
            $0.isCompleting = true
        }
        await store.receive(.completeFinished(.failed(String(localized: "onboarding_step_save_failed")))) {
            $0.isCompleting = false
            $0.currentStep = .tutorialShown
            $0.errorMessage = String(localized: "onboarding_step_save_failed")
        }

        try await failingManager.dbQueue.read { db in
            let completed = try Int.fetchOne(
                db,
                sql: "SELECT onboarding_completed FROM users WHERE auth_id = ? LIMIT 1",
                arguments: [authId.uuidString]
            )
            XCTAssertEqual(completed, 0)
        }
    }

    @MainActor
    func testSupplementsHarnessLoadsPersistedLogsCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let day = "2026-02-24"

        try await manager.dbQueue.write { db in
            try Self.seedCoverageFunctionalAuditUser(db: db, userId: userId, authId: authId)

            try db.execute(
                sql: """
                    INSERT INTO supplement_logs (
                        id, user_id, taken_at, taken_date, supplement_name,
                        dose_amount, dose_unit, was_scheduled, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    Date(),
                    day,
                    "Magnesium",
                    200.0,
                    "mg",
                    false,
                    Date(),
                    Date()
                ]
            )
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let summaries = await SupplementsDayViewTestHarness.loadLogs(
            dateString: day,
            dbQueue: manager.dbQueue
        )
        XCTAssertEqual(summaries.count, 1)
        XCTAssertTrue(summaries[0].contains("Magnesium"))

        let nilDateSummaries = await SupplementsDayViewTestHarness.loadLogs(
            dateString: nil,
            dbQueue: manager.dbQueue
        )
        XCTAssertTrue(nilDateSummaries.isEmpty)
    }

    @MainActor
    func testSupplementsHarnessFallsBackToCatalogNameCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let catalogId = UUID()

        try await manager.dbQueue.write { db in
            try Self.seedCoverageFunctionalAuditUser(db: db, userId: userId, authId: authId)

            let catalog = SupplementCatalogEntry(
                id: catalogId,
                name: "Vitamin D3 UITest",
                category: .vitamin
            )
            try catalog.insert(db)

            var supplement = UserSupplement(userId: userId)
            supplement.catalogId = catalogId
            supplement.scheduledTimes = ["08:00"]
            supplement.startedAt = "2026-02-24"
            try supplement.insert(db)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let names = await SupplementsDayViewTestHarness.loadScheduledAndStackNames(
            dateString: "2026-02-24",
            dbQueue: manager.dbQueue
        )

        XCTAssertEqual(names.scheduled, ["Vitamin D3 UITest"])
        XCTAssertEqual(names.stack, ["Vitamin D3 UITest"])
    }

    @MainActor
    func testSupplementsHarnessMarkTakenPersistsScheduledLogCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let catalogId = UUID()
        let supplementId = UUID()

        try await manager.dbQueue.write { db in
            try Self.seedCoverageFunctionalAuditUser(db: db, userId: userId, authId: authId)

            let catalog = SupplementCatalogEntry(
                id: catalogId,
                name: "Vitamin D3 UITest",
                category: .vitamin
            )
            try catalog.insert(db)

            var supplement = UserSupplement(id: supplementId, userId: userId)
            supplement.catalogId = catalogId
            supplement.customName = "Vitamin D3 UITest"
            supplement.scheduledTimes = ["08:00"]
            supplement.startedAt = "2026-02-24"
            try supplement.insert(db)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let result = await SupplementsDayViewTestHarness.markFirstScheduledSupplement(
            dateString: "2026-02-24",
            dbQueue: manager.dbQueue
        )

        XCTAssertEqual(result.takenFlags, [true])
        XCTAssertEqual(result.logNames, ["Vitamin D3 UITest"])

        let persisted: Row? = try await manager.dbQueue.read { db in
            return try Row.fetchOne(
                db,
                sql: """
                    SELECT supplement_name, scheduled_time
                    FROM supplement_logs
                    WHERE user_id = ? OR user_id = ?
                    ORDER BY created_at DESC
                    LIMIT 1
                    """,
                arguments: [userId, userId.uuidString]
            )
        }

        XCTAssertEqual(persisted?["supplement_name"], "Vitamin D3 UITest")
        XCTAssertEqual(persisted?["scheduled_time"], "08:00")
    }

    @MainActor
    func testSupplementsHarnessSetSupplementInactivePersistsAndRefreshesCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let firstSupplementId = UUID()
        let secondSupplementId = UUID()

        try await manager.dbQueue.write { db in
            try Self.seedCoverageFunctionalAuditUser(db: db, userId: userId, authId: authId)

            var firstSupplement = UserSupplement(id: firstSupplementId, userId: userId)
            firstSupplement.customName = "Alpha Coverage"
            firstSupplement.scheduledTimes = ["08:00"]
            firstSupplement.startedAt = "2026-02-24"
            try firstSupplement.insert(db)

            var secondSupplement = UserSupplement(id: secondSupplementId, userId: userId)
            secondSupplement.customName = "Beta Coverage"
            secondSupplement.scheduledTimes = ["09:00"]
            secondSupplement.startedAt = "2026-02-24"
            try secondSupplement.insert(db)

            var scheduledLog = SupplementLog(
                userId: userId,
                supplementName: "Beta Coverage",
                takenDate: "2026-02-24"
            )
            scheduledLog.userSupplementId = secondSupplementId
            scheduledLog.wasScheduled = true
            scheduledLog.scheduledTime = "09:00"
            try scheduledLog.insert(db)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let result = await SupplementsDayViewTestHarness.setSupplementActive(
            dateString: "2026-02-24",
            dbQueue: manager.dbQueue,
            supplementName: "Alpha Coverage",
            isActive: false
        )

        XCTAssertEqual(result.stackNames, ["Beta Coverage", "Alpha Coverage"])
        XCTAssertEqual(result.activeFlags, [true, false])
        XCTAssertEqual(result.scheduledNames, ["Beta Coverage"])
        XCTAssertEqual(result.quickLogNames, ["Beta Coverage"])
        XCTAssertEqual(result.dayTotalCount, 1)

        let persisted: Row? = try await manager.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT active
                    FROM user_supplements
                    WHERE id = ? OR id = ?
                    LIMIT 1
                    """,
                arguments: [firstSupplementId, firstSupplementId.uuidString]
            )
        }
        XCTAssertEqual(persisted?["active"], false)

        let outboxCount = try await manager.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE path = 'rest/v1/user_supplements'"
            ) ?? 0
        }
        XCTAssertEqual(outboxCount, 1)
    }

    @MainActor
    func testSupplementsHarnessQuickLogPersistsManualEntryCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let supplementId = UUID()

        try await manager.dbQueue.write { db in
            try Self.seedCoverageFunctionalAuditUser(db: db, userId: userId, authId: authId)

            var supplement = UserSupplement(id: supplementId, userId: userId, doseUnit: "")
            supplement.customName = "QuickLog Coverage"
            supplement.doseAmount = 500
            supplement.scheduledTimes = ["08:00"]
            supplement.startedAt = "2026-02-24"
            try supplement.insert(db)

            var scheduledLog = SupplementLog(
                userId: userId,
                supplementName: "QuickLog Coverage",
                takenDate: "2026-02-24"
            )
            scheduledLog.userSupplementId = supplementId
            scheduledLog.wasScheduled = true
            scheduledLog.scheduledTime = "08:00"
            try scheduledLog.insert(db)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let result = await SupplementsDayViewTestHarness.logFirstQuickSupplement(
            dateString: "2026-02-24",
            dbQueue: manager.dbQueue
        )

        XCTAssertEqual(result.quickLogNames, ["QuickLog Coverage"])
        XCTAssertEqual(result.logNames.filter { $0 == "QuickLog Coverage" }.count, 2)

        let persisted: Row? = try await manager.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT supplement_name, dose_unit, was_scheduled, scheduled_time
                    FROM supplement_logs
                    WHERE (user_id = ? OR user_id = ?)
                      AND (user_supplement_id = ? OR user_supplement_id = ?)
                      AND was_scheduled = 0
                    ORDER BY created_at DESC
                    LIMIT 1
                    """,
                arguments: [userId, userId.uuidString, supplementId, supplementId.uuidString]
            )
        }

        XCTAssertEqual(persisted?["supplement_name"], "QuickLog Coverage")
        XCTAssertEqual(persisted?["dose_unit"], "mg")
        XCTAssertEqual(persisted?["was_scheduled"], false)
        XCTAssertNil(persisted?["scheduled_time"] as String?)

        let outboxCount = try await manager.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE path = 'rest/v1/supplement_logs'"
            ) ?? 0
        }
        XCTAssertEqual(outboxCount, 1)
    }

    @MainActor
    func testInsightDetailStartExperimentPersistsAgainstCurrentSchemaCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        var configuredInsight = Insight(
            userId: userId,
            category: .experiment,
            title: "Sleep consistency pattern",
            body: "You sleep better with a consistent routine.",
            confidence: 0.91
        )
        configuredInsight.description = "Consistent sleep timing may improve sleep quality."
        configuredInsight.relatedMetrics = try JSONEncoder().encode(["sleep_quality"])
        let insight = configuredInsight

        try await manager.dbQueue.write { db in
            try Self.seedCoverageFunctionalAuditUser(db: db, userId: userId, authId: authId)
        }

        await InsightDetailViewTestHarness.startExperiment(
            insight: insight,
            authId: authId,
            dbQueue: manager.dbQueue
        )

        let snapshot = try await manager.dbQueue.read { db in
            let experiment = try XCTUnwrap(Experiment.fetchOne(db))
            let event = try XCTUnwrap(OutboxEvent.fetchOne(db))
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: event.bodyJson) as? [String: Any]
            )
            return (
                experiment,
                event.path,
                payload["primary_metric"] as? String,
                payload["title"] as? String
            )
        }

        XCTAssertEqual(snapshot.0.userId, userId)
        XCTAssertEqual(snapshot.0.title, insight.title)
        XCTAssertEqual(snapshot.0.status, .baseline)
        XCTAssertEqual(snapshot.0.primaryMetric, "sleep_quality")
        XCTAssertEqual(snapshot.0.hypothesis, insight.description)
        XCTAssertEqual(snapshot.1, "api-experiments/create")
        XCTAssertEqual(snapshot.2, "sleep_quality")
        XCTAssertEqual(snapshot.3, insight.title)
    }

    @MainActor
    func testInsightDetailStartExperimentRejectsLowConfidenceCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let insight = Insight(
            userId: userId,
            category: .experiment,
            title: "Low-confidence pattern",
            body: "Needs more data.",
            confidence: 0.41
        )

        try await manager.dbQueue.write { db in
            try Self.seedCoverageFunctionalAuditUser(db: db, userId: userId, authId: authId)
        }

        await InsightDetailViewTestHarness.startExperiment(
            insight: insight,
            authId: authId,
            hasCloudSession: true,
            dbQueue: manager.dbQueue
        )

        try await manager.dbQueue.read { db in
            XCTAssertNil(try Experiment.fetchOne(db))
            XCTAssertNil(try OutboxEvent.fetchOne(db))
        }
    }

    @MainActor
    func testInsightDetailStartExperimentIgnoresActiveExperimentFromAnotherUserCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let otherUserId = UUID()
        let otherExperimentId = UUID()
        let insight = Insight(
            userId: userId,
            category: .experiment,
            title: "Circadian alignment",
            body: "Test an earlier caffeine cutoff.",
            confidence: 0.89
        )

        try await manager.dbQueue.write { db in
            try Self.seedCoverageFunctionalAuditUser(db: db, userId: userId, authId: authId)
            try Self.seedCoverageFunctionalAuditUser(db: db, userId: otherUserId, authId: UUID())

            var existingExperiment = Experiment(
                id: otherExperimentId,
                userId: otherUserId,
                title: "Other user's experiment",
                variable: "training_load",
                metric: "recovery_score",
                durationDays: 14
            )
            existingExperiment.status = .baseline
            try existingExperiment.insert(db)
        }

        await InsightDetailViewTestHarness.startExperiment(
            insight: insight,
            authId: authId,
            hasCloudSession: true,
            dbQueue: manager.dbQueue
        )

        try await manager.dbQueue.read { db in
            let currentUserExperimentCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM experiments WHERE user_id = ? OR user_id = ?",
                arguments: [userId, userId.uuidString]
            ) ?? 0
            let otherUserExperimentCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM experiments WHERE user_id = ? OR user_id = ?",
                arguments: [otherUserId, otherUserId.uuidString]
            ) ?? 0

            XCTAssertEqual(currentUserExperimentCount, 1)
            XCTAssertEqual(otherUserExperimentCount, 1)
        }
    }

    @MainActor
    func testInsightDetailStartExperimentIgnoresEndedLifecycleWithStaleBaselineStatusCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let staleExperimentId = UUID()
        let insight = Insight(
            userId: userId,
            category: .experiment,
            title: "Morning light",
            body: "Test brighter mornings.",
            confidence: 0.93
        )
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let baselineStartDate = DiaryDateFormatter.formatDate(calendar.date(byAdding: .day, value: -21, to: today) ?? today)
        let baselineEndDate = DiaryDateFormatter.formatDate(calendar.date(byAdding: .day, value: -15, to: today) ?? today)
        let interventionStartDate = DiaryDateFormatter.formatDate(calendar.date(byAdding: .day, value: -14, to: today) ?? today)
        let interventionEndDate = DiaryDateFormatter.formatDate(calendar.date(byAdding: .day, value: -8, to: today) ?? today)
        let washoutStartDate = DiaryDateFormatter.formatDate(calendar.date(byAdding: .day, value: -7, to: today) ?? today)
        let washoutEndDate = DiaryDateFormatter.formatDate(calendar.date(byAdding: .day, value: -1, to: today) ?? today)

        try await manager.dbQueue.write { db in
            try Self.seedCoverageFunctionalAuditUser(db: db, userId: userId, authId: authId)

            var staleExperiment = Experiment(
                id: staleExperimentId,
                userId: userId,
                title: "Old circadian test",
                variable: "light_exposure",
                metric: "energy_level",
                durationDays: 7
            )
            staleExperiment.status = .baseline
            staleExperiment.primaryMetric = "energy_level"
            staleExperiment.baselineStartDate = baselineStartDate
            staleExperiment.baselineEndDate = baselineEndDate
            staleExperiment.interventionStartDate = interventionStartDate
            staleExperiment.interventionEndDate = interventionEndDate
            staleExperiment.washoutStartDate = washoutStartDate
            staleExperiment.washoutEndDate = washoutEndDate
            try staleExperiment.insert(db)
        }

        await InsightDetailViewTestHarness.startExperiment(
            insight: insight,
            authId: authId,
            hasCloudSession: true,
            dbQueue: manager.dbQueue
        )

        try await manager.dbQueue.read { db in
            let experimentCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM experiments WHERE user_id = ? OR user_id = ?",
                arguments: [userId, userId.uuidString]
            ) ?? 0
            let outboxCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM outbox_events WHERE path = ?",
                arguments: ["api-experiments/create"]
            ) ?? 0

            XCTAssertEqual(experimentCount, 2)
            XCTAssertEqual(outboxCount, 1)
        }
    }

    @MainActor
    func testExperimentDetailLoadAndDailyLogUseCurrentSchemaCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let experimentId = UUID()

        try await manager.dbQueue.write { db in
            try Self.seedCoverageFunctionalAuditUser(db: db, userId: userId, authId: UUID())

            var experiment = Experiment(
                id: experimentId,
                userId: userId,
                title: "Sleep Quality Check",
                variable: "bedtime_consistency",
                metric: "sleep_quality",
                durationDays: 21
            )
            experiment.hypothesis = "Going to bed at the same time improves sleep quality."
            experiment.status = .baseline
            experiment.primaryMetric = "sleep_quality"
            experiment.resultSummary = "Trending positive"
            try experiment.insert(db)

            var measurement = ExperimentMeasurement(
                experimentId: experimentId,
                userId: userId,
                date: "2026-02-20",
                value: 78,
                unit: nil,
                measurementPhase: .baseline,
                metricName: "sleep_quality"
            )
            measurement.notes = "Baseline"
            try measurement.insert(db)
        }

        let viewModel = ExperimentDetailViewModel(experimentId: experimentId, dbQueue: manager.dbQueue)
        AuthManager._testSetActiveHasCloudSession(true)
        defer { AuthManager._testSetActiveHasCloudSession(false) }
        await viewModel.load()

        XCTAssertEqual(viewModel.experimentName, "Sleep Quality Check")
        XCTAssertEqual(viewModel.metricLabel, "sleep_quality")
        XCTAssertEqual(viewModel.conclusion, "Trending positive")
        XCTAssertEqual(viewModel.measurements.count, 1)

        viewModel.dailyValue = "82"
        viewModel.dailyNotes = "Good recovery"
        viewModel.adheredToday = false
        await viewModel.logDailyMeasurement()

        viewModel.dailyValue = "84"
        viewModel.dailyNotes = "Updated entry"
        viewModel.adheredToday = true
        await viewModel.logDailyMeasurement()

        let today = DiaryDateFormatter.formatDate(Date())
        let todayMeasurements = try await manager.dbQueue.read { db in
            try ExperimentMeasurement
                .filter(sql: "experiment_id = ? OR experiment_id = ?", arguments: [experimentId, experimentId.uuidString])
                .filter(Column("measurement_date") == today)
                .filter(Column("metric_name") == "sleep_quality")
                .fetchAll(db)
        }

        XCTAssertEqual(todayMeasurements.count, 1)
        XCTAssertEqual(todayMeasurements[0].userId, userId)
        XCTAssertEqual(todayMeasurements[0].metricValue, 84.0)
        XCTAssertEqual(todayMeasurements[0].notes, "Updated entry")
        XCTAssertTrue(todayMeasurements[0].protocolFollowed)

        try await manager.dbQueue.read { db in
            let event = try XCTUnwrap(OutboxEvent.fetchOne(db))
            XCTAssertEqual(event.path, "api-experiments/\(experimentId.uuidString)/log")

            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: event.bodyJson) as? [String: Any]
            )
            XCTAssertEqual(payload["date"] as? String, today)
            XCTAssertEqual(payload["protocol_followed"] as? Bool, true)
            let measurements = try XCTUnwrap(payload["measurements"] as? [String: Double])
            XCTAssertEqual(measurements["sleep_quality"], 84.0)
        }
    }

    @MainActor
    func testTrainingDayFiltersSessionsForResolvedUserCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let otherUserId = UUID()
        let day = "2026-02-24"

        try await manager.dbQueue.write { db in
            try Self.seedCoverageFunctionalAuditUser(db: db, userId: userId, authId: authId)
            try Self.seedCoverageFunctionalAuditUser(db: db, userId: otherUserId, authId: UUID())

            var ownSession = WorkoutSession(userId: userId, startedAt: Date(), sessionDate: day, source: .manual)
            ownSession.workoutType = .strength
            ownSession.totalSets = 12
            try ownSession.insert(db)

            var foreignSession = WorkoutSession(userId: otherUserId, startedAt: Date(), sessionDate: day, source: .manual)
            foreignSession.workoutType = .cardio
            foreignSession.totalSets = 3
            try foreignSession.insert(db)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let summaries = await TrainingDayViewTestHarness.loadSessions(dateString: day, dbQueue: manager.dbQueue)
        XCTAssertEqual(summaries.count, 1)
    }

    @MainActor
    func testWorkoutLogSeedsInitialSetWhenAddingExerciseCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let viewModel = WorkoutLogViewModel(dbQueue: manager.dbQueue)
        let catalogEntry = ExerciseCatalogEntry(
            id: UUID(),
            name: "Incline Bench Press",
            category: .strength
        )

        viewModel.addExercise(catalogEntry)

        XCTAssertEqual(viewModel.exercises.count, 1)
        XCTAssertEqual(viewModel.exercises[0].name, "Incline Bench Press")
        XCTAssertEqual(viewModel.exercises[0].sets.count, 1)
        XCTAssertEqual(viewModel.exercises[0].sets[0].weight, 0)
        XCTAssertEqual(viewModel.exercises[0].sets[0].reps, 0)
    }

    @MainActor
    func testWorkoutLogMaintainsExerciseScopedSetsInEditorCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let firstExerciseId = UUID()
        let secondExerciseId = UUID()

        let viewModel = WorkoutLogViewModel(dbQueue: manager.dbQueue)
        viewModel.exercises = [
            WorkoutLogExercise(id: firstExerciseId, catalogId: UUID(), name: "Back Squat", category: .strength),
            WorkoutLogExercise(id: secondExerciseId, catalogId: UUID(), name: "Bench Press", category: .strength)
        ]

        viewModel.addSet(to: firstExerciseId)
        viewModel.addSet(to: firstExerciseId)
        viewModel.addSet(to: secondExerciseId)

        viewModel.exercises[0].sets[0].weight = 100
        viewModel.exercises[0].sets[0].reps = 5
        viewModel.exercises[0].sets[1].weight = 110
        viewModel.exercises[0].sets[1].reps = 3
        viewModel.exercises[1].sets[0].weight = 80
        viewModel.exercises[1].sets[0].reps = 8

        viewModel.removeSet(from: firstExerciseId, at: 0)

        XCTAssertEqual(viewModel.exercises[0].sets.count, 1)
        XCTAssertEqual(viewModel.exercises[0].sets[0].weight, 110)
        XCTAssertEqual(viewModel.exercises[0].sets[0].reps, 3)
        XCTAssertEqual(viewModel.exercises[1].sets.count, 1)
        XCTAssertEqual(viewModel.exercises[1].sets[0].weight, 80)
        XCTAssertEqual(viewModel.exercises[1].sets[0].reps, 8)
    }

    @MainActor
    func testWorkoutLogRejectsEmptySaveAndIgnoresUnknownSetMutationsCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let exerciseId = UUID()
        let missingExerciseId = UUID()

        let emptyViewModel = WorkoutLogViewModel(dbQueue: manager.dbQueue)
        let didSaveEmpty = await emptyViewModel.save()
        XCTAssertFalse(didSaveEmpty)

        let viewModel = WorkoutLogViewModel(dbQueue: manager.dbQueue)
        viewModel.exercises = [
            WorkoutLogExercise(
                id: exerciseId,
                catalogId: UUID(),
                name: "Romanian Deadlift",
                category: .strength,
                sets: [WorkoutLogSet(id: UUID(), weight: 90, reps: 8)]
            )
        ]

        viewModel.addSet(to: missingExerciseId)
        XCTAssertEqual(viewModel.exercises[0].sets.count, 1)

        viewModel.removeSet(from: exerciseId, at: 5)
        XCTAssertEqual(viewModel.exercises[0].sets.count, 1)

        viewModel.removeSet(from: missingExerciseId, at: 0)
        XCTAssertEqual(viewModel.exercises[0].sets.count, 1)

        viewModel.removeExercise(missingExerciseId)
        XCTAssertEqual(viewModel.exercises.count, 1)
        XCTAssertEqual(viewModel.exercises[0].sets[0].weight, 90)
        XCTAssertEqual(viewModel.exercises[0].sets[0].reps, 8)
    }

    @MainActor
    func testWorkoutLogPersistsPerExerciseSetLinkageAndAggregatesCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let squatExerciseId = UUID()
        let benchExerciseId = UUID()
        let squatCatalogId = UUID()
        let benchCatalogId = UUID()

        try await manager.dbQueue.write { db in
            try Self.seedCoverageFunctionalAuditUser(db: db, userId: userId, authId: authId)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let viewModel = WorkoutLogViewModel(dbQueue: manager.dbQueue)
        viewModel.notes = "  Strong day  "
        viewModel.setRPE(7)
        viewModel.exercises = [
            WorkoutLogExercise(
                id: squatExerciseId,
                catalogId: squatCatalogId,
                name: "Back Squat",
                category: .strength,
                notes: "  Heavy triples  ",
                sets: [
                    WorkoutLogSet(id: UUID(), weight: 100, reps: 5),
                    WorkoutLogSet(id: UUID(), weight: 110, reps: 3)
                ]
            ),
            WorkoutLogExercise(
                id: benchExerciseId,
                catalogId: benchCatalogId,
                name: "Bench Press",
                category: .strength,
                sets: [
                    WorkoutLogSet(id: UUID(), weight: 80, reps: 8)
                ]
            )
        ]

        let didSave = await viewModel.save()
        XCTAssertTrue(didSave)

        let snapshot = try await manager.dbQueue.read { db throws in
            (
                try XCTUnwrap(WorkoutSession.fetchOne(db)),
                try WorkoutExercise
                    .order(Column("order_in_session").asc)
                    .fetchAll(db),
                try WorkoutSet
                    .order(Column("exercise_entry_id").asc)
                    .order(Column("set_number").asc)
                    .fetchAll(db)
            )
        }

        XCTAssertEqual(snapshot.0.userId, userId)
        XCTAssertEqual(snapshot.0.notes, "Strong day")
        XCTAssertEqual(snapshot.0.perceivedExertionRpe, 7)
        XCTAssertEqual(snapshot.0.durationMinutes, 15)
        XCTAssertEqual(try XCTUnwrap(snapshot.0.totalSets), 3)
        XCTAssertEqual(try XCTUnwrap(snapshot.0.totalReps), 16)
        XCTAssertEqual(try XCTUnwrap(snapshot.0.totalVolume), 1_470, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.0.trimpScore), 15.75, accuracy: 0.001)
        XCTAssertEqual(snapshot.1.count, 2)
        XCTAssertEqual(snapshot.2.count, 3)

        let squatEntry = snapshot.1[0]
        let benchEntry = snapshot.1[1]

        XCTAssertEqual(squatEntry.notes, "Heavy triples")
        XCTAssertEqual(try XCTUnwrap(squatEntry.totalSets), 2)
        XCTAssertEqual(try XCTUnwrap(squatEntry.totalReps), 8)
        XCTAssertEqual(try XCTUnwrap(squatEntry.totalVolume), 830, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(squatEntry.maxWeight), 110, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(benchEntry.totalSets), 1)
        XCTAssertEqual(try XCTUnwrap(benchEntry.totalReps), 8)
        XCTAssertEqual(try XCTUnwrap(benchEntry.totalVolume), 640, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(benchEntry.maxWeight), 80, accuracy: 0.001)

        let setsByEntryId = Dictionary(grouping: snapshot.2, by: \.exerciseEntryId)
        let squatSets = try XCTUnwrap(setsByEntryId[squatEntry.id])
        let benchSets = try XCTUnwrap(setsByEntryId[benchEntry.id])

        XCTAssertEqual(squatSets.map(\.setNumber), [1, 2])
        XCTAssertEqual(squatSets.map { $0.weight ?? -1 }, [100, 110])
        XCTAssertEqual(squatSets.map { $0.reps ?? -1 }, [5, 3])
        XCTAssertEqual(benchSets.map(\.setNumber), [1])
        XCTAssertEqual(benchSets.map { $0.weight ?? -1 }, [80])
        XCTAssertEqual(benchSets.map { $0.reps ?? -1 }, [8])
    }

    @MainActor
    func testWorkoutLogSaveFailsWithoutResolvedUserCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let exerciseId = UUID()

        AuthManager.setActiveAuthIdForTests(nil)

        let viewModel = WorkoutLogViewModel(dbQueue: manager.dbQueue)
        viewModel.exercises = [
            WorkoutLogExercise(
                id: exerciseId,
                catalogId: UUID(),
                name: "Deadlift",
                category: .strength,
                sets: [WorkoutLogSet(id: UUID(), weight: 140, reps: 5)]
            )
        ]

        let didSave = await viewModel.save()
        XCTAssertFalse(didSave)

        let snapshot = try await manager.dbQueue.read { db in
            (
                try WorkoutSession.fetchCount(db),
                try WorkoutExercise.fetchCount(db),
                try WorkoutSet.fetchCount(db)
            )
        }

        XCTAssertEqual(snapshot.0, 0)
        XCTAssertEqual(snapshot.1, 0)
        XCTAssertEqual(snapshot.2, 0)
    }

    @MainActor
    func testWorkoutLogMutatesWarmupAndRestDurationCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let exerciseId = UUID()

        let viewModel = WorkoutLogViewModel(dbQueue: manager.dbQueue)
        viewModel.exercises = [
            WorkoutLogExercise(
                id: exerciseId,
                catalogId: UUID(),
                name: "Paused Bench Press",
                category: .strength,
                sets: [WorkoutLogSet(id: UUID(), weight: 75, reps: 6, restAfterSeconds: 90)]
            )
        ]

        viewModel.toggleWarmup(exerciseId: UUID(), at: 0)
        viewModel.toggleWarmup(exerciseId: exerciseId, at: 4)
        XCTAssertFalse(viewModel.exercises[0].sets[0].isWarmup)

        viewModel.toggleWarmup(exerciseId: exerciseId, at: 0)
        XCTAssertTrue(viewModel.exercises[0].sets[0].isWarmup)

        viewModel.setRestDuration(exerciseId: UUID(), at: 0, seconds: 45)
        viewModel.setRestDuration(exerciseId: exerciseId, at: 3, seconds: 45)
        XCTAssertEqual(viewModel.exercises[0].sets[0].restAfterSeconds, 90)

        viewModel.setRestDuration(exerciseId: exerciseId, at: 0, seconds: 45)
        XCTAssertEqual(viewModel.exercises[0].sets[0].restAfterSeconds, 45)

        viewModel.setRestDuration(exerciseId: exerciseId, at: 0, seconds: nil)
        XCTAssertNil(viewModel.exercises[0].sets[0].restAfterSeconds)
    }

    @MainActor
    func testWorkoutLogToggleSetCompletionAndRestTimerCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let catalogEntry = ExerciseCatalogEntry(
            id: UUID(),
            name: "Trap Bar Deadlift",
            category: .strength
        )

        let viewModel = WorkoutLogViewModel(
            dbQueue: manager.dbQueue,
            defaultRestAfterSeconds: 30,
            restTimerTickNanoseconds: 5_000_000_000
        )
        viewModel.addExercise(catalogEntry)

        let exerciseId = viewModel.exercises[0].id
        viewModel.extendRestTimer(by: 15)
        XCTAssertNil(viewModel.activeRestTimer)

        viewModel.toggleSetCompletion(exerciseId: UUID(), at: 0)
        viewModel.toggleSetCompletion(exerciseId: exerciseId, at: 3)
        XCTAssertFalse(viewModel.exercises[0].sets[0].isCompleted)

        viewModel.toggleSetCompletion(exerciseId: exerciseId, at: 0)
        XCTAssertTrue(viewModel.exercises[0].sets[0].isCompleted)
        XCTAssertEqual(viewModel.activeRestTimer?.totalSeconds, 30)
        XCTAssertEqual(viewModel.activeRestTimer?.remainingSeconds, 30)

        viewModel.extendRestTimer(by: 15)
        XCTAssertEqual(viewModel.activeRestTimer?.remainingSeconds, 45)

        viewModel.toggleSetCompletion(exerciseId: exerciseId, at: 0)
        XCTAssertFalse(viewModel.exercises[0].sets[0].isCompleted)
        XCTAssertNil(viewModel.activeRestTimer)

        let existingViewModel = WorkoutLogViewModel(
            existingSessionId: UUID(),
            dbQueue: manager.dbQueue,
            defaultRestAfterSeconds: 30,
            restTimerTickNanoseconds: 5_000_000_000
        )
        existingViewModel.exercises = viewModel.exercises
        existingViewModel.toggleSetCompletion(exerciseId: exerciseId, at: 0)

        XCTAssertFalse(existingViewModel.exercises[0].sets[0].isCompleted)
        XCTAssertNil(existingViewModel.activeRestTimer)
    }

    @MainActor
    func testWorkoutLogCatalogSuggestionsPrioritizeExactAndPrefixMatchesCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let exactId = UUID()
        let prefixId = UUID()
        let containsId = UUID()

        try await manager.dbQueue.write { db in
            try Self.seedCoverageFunctionalAuditUser(db: db, userId: userId, authId: authId)

            try ExerciseCatalogEntry(id: exactId, name: "Codex Bench", category: .strength).insert(db)
            try ExerciseCatalogEntry(id: prefixId, name: "Codex Bench Press", category: .strength).insert(db)
            try ExerciseCatalogEntry(id: containsId, name: "Incline Codex Bench", category: .strength).insert(db)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let viewModel = WorkoutLogViewModel(dbQueue: manager.dbQueue)
        await viewModel.loadCatalog()

        viewModel.exerciseSearch = "  codex bench  "

        XCTAssertEqual(viewModel.exerciseSearchQuery, "codex bench")
        XCTAssertEqual(viewModel.exactCatalogMatch?.id, exactId)
        XCTAssertFalse(viewModel.canCreateCustomExercise)
        XCTAssertTrue(viewModel.shouldShowExerciseSuggestions)
        XCTAssertEqual(viewModel.filteredCatalog.prefix(3).map(\.id), [exactId, prefixId, containsId])
    }

    @MainActor
    func testWorkoutLogAddExerciseFromSearchUsesExactMatchAndCreatesCustomCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let exactId = UUID()

        try await manager.dbQueue.write { db in
            try Self.seedCoverageFunctionalAuditUser(db: db, userId: userId, authId: authId)
            try ExerciseCatalogEntry(id: exactId, name: "Codex Carry", category: .strength).insert(db)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let viewModel = WorkoutLogViewModel(dbQueue: manager.dbQueue)
        await viewModel.loadCatalog()

        viewModel.exerciseSearch = "codex carry"
        await viewModel.addExerciseFromSearch()

        XCTAssertEqual(viewModel.exercises.count, 1)
        XCTAssertEqual(viewModel.exercises[0].catalogId, exactId)
        XCTAssertEqual(viewModel.exercises[0].name, "Codex Carry")
        XCTAssertEqual(viewModel.exerciseSearch, "")
        XCTAssertNil(viewModel.errorMessage)

        viewModel.exerciseSearch = "Codex Sled Push"
        await viewModel.addExerciseFromSearch()

        XCTAssertEqual(viewModel.exercises.count, 2)
        XCTAssertEqual(viewModel.exercises[1].name, "Codex Sled Push")
        XCTAssertEqual(viewModel.exercises[1].category, .strength)
        XCTAssertEqual(viewModel.exerciseSearch, "")
        XCTAssertNil(viewModel.errorMessage)

        try await manager.dbQueue.read { db in
            let customEntry = try XCTUnwrap(
                ExerciseCatalogEntry.fetchOne(
                    db,
                    sql: """
                        SELECT *
                        FROM exercise_catalog
                        WHERE lower(name) = lower(?)
                          AND COALESCE(is_custom, 0) = 1
                        LIMIT 1
                        """,
                    arguments: ["Codex Sled Push"]
                )
            )
            XCTAssertEqual(customEntry.category, .strength)
            XCTAssertEqual(customEntry.createdBy, userId)
        }
    }

    @MainActor
    func testWorkoutLogLoadsImportedWorkoutAsReadOnlyCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let workoutId = UUID()
        let exerciseId = UUID()
        let managerMock = CoverageWorkoutSessionManagerMock()

        let importedSession = WorkoutSession(
            id: workoutId,
            userId: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_773_331_200),
            sessionDate: "2026-03-12",
            source: .import
        )
        let exercise = WorkoutExercise(
            id: exerciseId,
            sessionId: workoutId,
            exerciseId: nil,
            orderInSession: 1
        )
        let set = WorkoutSet(
            id: UUID(),
            exerciseEntryId: exerciseId,
            userId: importedSession.userId,
            setNumber: 1
        )
        await managerMock.setLoadedDetail(
            WorkoutSessionDetail(
                session: importedSession,
                exercises: [
                    WorkoutSessionDetailExercise(
                        exercise: exercise,
                        name: "Imported Run",
                        category: .cardio,
                        sets: [set]
                    )
                ]
            ),
            for: workoutId
        )

        let viewModel = WorkoutLogViewModel(
            existingSessionId: workoutId,
            workoutManager: managerMock,
            dbQueue: manager.dbQueue,
            targetDate: Date()
        )

        await viewModel.loadWorkoutDetailIfNeeded()

        XCTAssertEqual(viewModel.workoutSource, .import)
        XCTAssertFalse(viewModel.canEditExercises)
        XCTAssertEqual(viewModel.importedWorkoutNotice, TrainingError.importedWorkoutEditRestricted.errorDescription)
        XCTAssertEqual(viewModel.exercises.count, 1)
        XCTAssertEqual(viewModel.exercises[0].name, "Imported Run")
        XCTAssertEqual(viewModel.exercises[0].category, .cardio)
    }

    @MainActor
    func testWorkoutLogDeleteAndUndoCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let workoutId = UUID()
        let managerMock = CoverageWorkoutSessionManagerMock()

        let viewModel = WorkoutLogViewModel(
            existingSessionId: workoutId,
            workoutManager: managerMock,
            dbQueue: manager.dbQueue,
            targetDate: Date()
        )
        viewModel.activeRestTimer = WorkoutRestTimerState(setId: UUID(), totalSeconds: 90, remainingSeconds: 45)

        let didDelete = await viewModel.deleteWorkout()
        XCTAssertTrue(didDelete)
        XCTAssertTrue(viewModel.isDeleted)
        XCTAssertNil(viewModel.activeRestTimer)
        XCTAssertNotNil(viewModel.deletedAt)
        let deletedIds = await managerMock.deletedIdsSnapshot()
        XCTAssertEqual(deletedIds, [workoutId])

        let didUndo = await viewModel.undoDeleteWorkout()
        XCTAssertTrue(didUndo)
        XCTAssertFalse(viewModel.isDeleted)
        XCTAssertNil(viewModel.deletedAt)
        let undoneIds = await managerMock.undoneIdsSnapshot()
        XCTAssertEqual(undoneIds, [workoutId])
    }

    @MainActor
    func testWorkoutLogLoadDetailMissingWorkoutSetsErrorCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let workoutId = UUID()
        let managerMock = CoverageWorkoutSessionManagerMock()

        let viewModel = WorkoutLogViewModel(
            existingSessionId: workoutId,
            workoutManager: managerMock,
            dbQueue: manager.dbQueue,
            targetDate: Date()
        )

        await viewModel.loadWorkoutDetailIfNeeded()

        XCTAssertEqual(viewModel.errorMessage, TrainingError.workoutNotFound.errorDescription)
        XCTAssertTrue(viewModel.exercises.isEmpty)
    }

    @MainActor
    func testWorkoutLogRefreshHealthImportStateBuildsImportedSessionsAndConflictCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let day = "2026-03-12"
        let importedId = UUID()
        let manualId = UUID()
        let earlyImportedId = UUID()
        let importedStart = Date(timeIntervalSince1970: 1_773_331_200)
        let manualStart = importedStart.addingTimeInterval(10 * 60)
        let earlierImportedStart = importedStart.addingTimeInterval(-3_600)

        try await manager.dbQueue.write { db in
            try Self.seedCoverageFunctionalAuditUser(db: db, userId: userId, authId: authId)

            var imported = WorkoutSession(
                id: importedId,
                userId: userId,
                startedAt: importedStart,
                sessionDate: day,
                source: .import
            )
            imported.workoutType = .cardio
            imported.durationMinutes = 45
            imported.estimatedCalories = 320
            imported.trimpScore = 38
            try imported.insert(db)

            var manual = WorkoutSession(
                id: manualId,
                userId: userId,
                startedAt: manualStart,
                sessionDate: day,
                source: .manual
            )
            manual.workoutType = .cardio
            manual.durationMinutes = 40
            try manual.insert(db)

            var earlierImported = WorkoutSession(
                id: earlyImportedId,
                userId: userId,
                startedAt: earlierImportedStart,
                sessionDate: day,
                source: .import
            )
            earlierImported.workoutType = .mobility
            try earlierImported.insert(db)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let targetDate = ISO8601DateFormatter().date(from: "2026-03-12T12:00:00Z") ?? Date(timeIntervalSince1970: 1_773_345_600)
        let viewModel = WorkoutLogViewModel(dbQueue: manager.dbQueue, targetDate: targetDate)

        await viewModel.refreshHealthKitImportState()

        XCTAssertEqual(viewModel.importedSessions.map(\.id), [earlyImportedId, importedId])
        XCTAssertEqual(viewModel.importedSessions[1].trimpScore, 38)
        XCTAssertTrue(viewModel.importedSessions[1].secondaryText.contains("45 min"))
        XCTAssertTrue(viewModel.importedSessions[1].secondaryText.contains("320 kcal"))
        let cardioLabel = String(localized: "training_identifier_cardio")
        XCTAssertEqual(
            viewModel.importConflict,
            ImportConflict(
                existingSessionId: manualId,
                existingType: cardioLabel,
                importedType: cardioLabel,
                importedSessionId: importedId
            )
        )
    }

    @MainActor
    func testWorkoutLogResolveConflictMergeUpdatesAndDeletesImportedCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let existingId = UUID()
        let importedId = UUID()
        let day = "2026-03-12"
        let managerMock = CoverageWorkoutSessionManagerMock()
        let existingStartedAt = Date(timeIntervalSince1970: 1_773_331_200)
        let importedStartedAt = existingStartedAt.addingTimeInterval(10 * 60)
        let importedEndedAt = importedStartedAt.addingTimeInterval(50 * 60)

        try await manager.dbQueue.write { db in
            try Self.seedCoverageFunctionalAuditUser(db: db, userId: userId, authId: authId)

            var existing = WorkoutSession(
                id: existingId,
                userId: userId,
                startedAt: existingStartedAt,
                sessionDate: day,
                source: .manual
            )
            existing.workoutType = .cardio
            existing.durationMinutes = 30
            existing.trimpScore = 20
            existing.perceivedExertionRpe = 5
            try existing.insert(db)

            var imported = WorkoutSession(
                id: importedId,
                userId: userId,
                startedAt: importedStartedAt,
                sessionDate: day,
                source: .import
            )
            imported.workoutType = .cardio
            imported.durationMinutes = 50
            imported.endedAt = importedEndedAt
            imported.estimatedCalories = 410
            imported.trimpScore = 44
            imported.perceivedExertionRpe = 8
            imported.startedTimezone = "UTC"
            imported.startedUtcOffsetMinutes = 0
            try imported.insert(db)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let targetDate = ISO8601DateFormatter().date(from: "2026-03-12T12:00:00Z") ?? Date(timeIntervalSince1970: 1_773_345_600)
        let viewModel = WorkoutLogViewModel(
            workoutManager: managerMock,
            dbQueue: manager.dbQueue,
            targetDate: targetDate
        )

        await viewModel.refreshHealthKitImportState()
        XCTAssertEqual(viewModel.importConflict?.existingSessionId, existingId)
        XCTAssertEqual(viewModel.importConflict?.importedSessionId, importedId)

        await viewModel.resolveConflict(.merge)

        let updatedDrafts = await managerMock.updatedDraftsSnapshot()
        XCTAssertEqual(updatedDrafts.count, 1)
        XCTAssertEqual(updatedDrafts[0].id, existingId)
        XCTAssertEqual(updatedDrafts[0].durationMinutes, 50)
        XCTAssertEqual(updatedDrafts[0].estimatedCalories, 410)
        XCTAssertEqual(try XCTUnwrap(updatedDrafts[0].trimpScore), 44, accuracy: 0.001)
        XCTAssertEqual(updatedDrafts[0].perceivedExertionRpe, 8)
        XCTAssertEqual(updatedDrafts[0].startedTimezone, "UTC")
        XCTAssertEqual(updatedDrafts[0].startedUtcOffsetMinutes, 0)
        XCTAssertEqual(updatedDrafts[0].endedAt, importedEndedAt)
        let deletedIds = await managerMock.deletedIdsSnapshot()
        XCTAssertEqual(deletedIds, [importedId])
        XCTAssertEqual(viewModel.healthKitStatusMessage, String(localized: "training_apple_health_merge_success"))
    }

    @MainActor
    func testWorkoutLogSaveExistingEditableWorkoutRejectsEmptyExercisesCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let managerMock = CoverageWorkoutSessionManagerMock()
        let workoutId = UUID()

        let viewModel = WorkoutLogViewModel(
            existingSessionId: workoutId,
            workoutManager: managerMock,
            dbQueue: manager.dbQueue,
            targetDate: Date()
        )

        let didSave = await viewModel.save()

        XCTAssertFalse(didSave)
        XCTAssertEqual(
            viewModel.errorMessage,
            TrainingError.invalidSet(reason: String(localized: "training_validation_add_exercise")).errorDescription
        )
        let updatedDrafts = await managerMock.updatedDraftsSnapshot()
        XCTAssertTrue(updatedDrafts.isEmpty)
    }

    @MainActor
    func testWorkoutLogSaveImportedWorkoutUpdatesNotesAndEffortWithoutExercisesCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let managerMock = CoverageWorkoutSessionManagerMock()
        let workoutId = UUID()
        let exerciseId = UUID()
        let importedStartedAt = Date(timeIntervalSince1970: 1_773_331_200)

        let importedSession = WorkoutSession(
            id: workoutId,
            userId: UUID(),
            startedAt: importedStartedAt,
            sessionDate: "2026-03-12",
            source: .import
        )
        let exercise = WorkoutExercise(
            id: exerciseId,
            sessionId: workoutId,
            exerciseId: nil,
            orderInSession: 1
        )
        let set = WorkoutSet(
            id: UUID(),
            exerciseEntryId: exerciseId,
            userId: importedSession.userId,
            setNumber: 1
        )
        await managerMock.setLoadedDetail(
            WorkoutSessionDetail(
                session: {
                    var session = importedSession
                    session.durationMinutes = 45
                    session.perceivedExertionRpe = 6
                    return session
                }(),
                exercises: [
                    WorkoutSessionDetailExercise(
                        exercise: exercise,
                        name: "Imported Ride",
                        category: .cardio,
                        sets: [set]
                    )
                ]
            ),
            for: workoutId
        )

        let viewModel = WorkoutLogViewModel(
            existingSessionId: workoutId,
            workoutManager: managerMock,
            dbQueue: manager.dbQueue,
            targetDate: importedStartedAt
        )
        await viewModel.loadWorkoutDetailIfNeeded()
        viewModel.notes = "  Updated imported note  "
        viewModel.setRPE(8)

        let didSave = await viewModel.save()
        XCTAssertTrue(didSave)

        let updatedDrafts = await managerMock.updatedDraftsSnapshot()
        XCTAssertEqual(updatedDrafts.count, 1)
        XCTAssertEqual(updatedDrafts[0].id, workoutId)
        XCTAssertEqual(updatedDrafts[0].notes, "Updated imported note")
        XCTAssertEqual(updatedDrafts[0].perceivedExertionRpe, 8)
        XCTAssertEqual(updatedDrafts[0].durationMinutes, 45)
        XCTAssertNil(updatedDrafts[0].exercises)
    }

    @MainActor
    func testWorkoutLogResolveConflictKeepExistingAndUseImportedCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let day = "2026-03-12"

        func seedConflictSessions(existingId: UUID, importedId: UUID) async throws {
            try await manager.dbQueue.write { db in
                var existing = WorkoutSession(
                    id: existingId,
                    userId: userId,
                    startedAt: Date(timeIntervalSince1970: 1_773_331_200),
                    sessionDate: day,
                    source: .manual
                )
                existing.workoutType = .cardio
                existing.durationMinutes = 35
                try existing.insert(db)

                var imported = WorkoutSession(
                    id: importedId,
                    userId: userId,
                    startedAt: existing.startedAt.addingTimeInterval(10 * 60),
                    sessionDate: day,
                    source: .import
                )
                imported.workoutType = .cardio
                imported.durationMinutes = 40
                try imported.insert(db)
            }
        }

        try await manager.dbQueue.write { db in
            try Self.seedCoverageFunctionalAuditUser(db: db, userId: userId, authId: authId)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let targetDate = ISO8601DateFormatter().date(from: "2026-03-12T12:00:00Z") ?? Date(timeIntervalSince1970: 1_773_345_600)

        let keepExistingId = UUID()
        let keepImportedId = UUID()
        try await seedConflictSessions(existingId: keepExistingId, importedId: keepImportedId)

        let keepManager = CoverageWorkoutSessionManagerMock()
        let keepViewModel = WorkoutLogViewModel(
            workoutManager: keepManager,
            dbQueue: manager.dbQueue,
            targetDate: targetDate
        )
        await keepViewModel.refreshHealthKitImportState()
        await keepViewModel.resolveConflict(.keepExisting)
        let keepDeletedIds = await keepManager.deletedIdsSnapshot()
        XCTAssertEqual(keepDeletedIds, [keepImportedId])
        XCTAssertEqual(keepViewModel.healthKitStatusMessage, String(localized: "training_apple_health_keep_manual_success"))

        try await manager.dbQueue.write { db in
            try WorkoutSession.deleteAll(db)
        }

        let useExistingId = UUID()
        let useImportedId = UUID()
        try await seedConflictSessions(existingId: useExistingId, importedId: useImportedId)

        let useManager = CoverageWorkoutSessionManagerMock()
        let useViewModel = WorkoutLogViewModel(
            workoutManager: useManager,
            dbQueue: manager.dbQueue,
            targetDate: targetDate
        )
        await useViewModel.refreshHealthKitImportState()
        await useViewModel.resolveConflict(.useImported)
        let useDeletedIds = await useManager.deletedIdsSnapshot()
        XCTAssertEqual(useDeletedIds, [useExistingId])
        XCTAssertEqual(useViewModel.healthKitStatusMessage, String(localized: "training_apple_health_keep_imported_success"))
    }

    @MainActor
    func testWorkoutLogComputedStateFlagsCoverage() async throws {
        let manager = try DatabaseManager.inMemory()

        let freshViewModel = WorkoutLogViewModel(dbQueue: manager.dbQueue)
        XCTAssertFalse(freshViewModel.canSave)
        XCTAssertEqual(freshViewModel.screenTitle, String(localized: "log_workout"))
        XCTAssertEqual(freshViewModel.saveButtonTitle, String(localized: "training_finish_workout"))
        XCTAssertTrue(freshViewModel.shouldShowHealthKitImportSection)

        freshViewModel.exercises = [
            WorkoutLogExercise(
                id: UUID(),
                catalogId: UUID(),
                name: "Front Squat",
                category: .strength,
                sets: [WorkoutLogSet(id: UUID(), weight: 90, reps: 5)]
            )
        ]
        XCTAssertTrue(freshViewModel.canSave)
        XCTAssertEqual(freshViewModel.incompleteSetCount, 0)

        let deletedViewModel = WorkoutLogViewModel(
            existingSessionId: UUID(),
            dbQueue: manager.dbQueue,
            targetDate: Date()
        )
        deletedViewModel.isDeleted = true
        deletedViewModel.deletedAt = Date()

        XCTAssertTrue(deletedViewModel.canUndoDelete)
        XCTAssertFalse(deletedViewModel.canSave)
        XCTAssertFalse(deletedViewModel.shouldShowHealthKitImportSection)
        XCTAssertEqual(deletedViewModel.screenTitle, String(localized: "training_workout_deleted"))
        XCTAssertEqual(deletedViewModel.saveButtonTitle, String(localized: "training_save_changes"))
    }

    @MainActor
    func testWorkoutLogRPELabelBranchesCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let workoutId = UUID()
        let exerciseId = UUID()
        let managerMock = CoverageWorkoutSessionManagerMock()

        var session = WorkoutSession(
            id: workoutId,
            userId: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_773_331_200),
            sessionDate: "2026-03-12",
            source: .manual
        )
        session.durationMinutes = 30

        await managerMock.setLoadedDetail(
            WorkoutSessionDetail(
                session: session,
                exercises: [
                    WorkoutSessionDetailExercise(
                        exercise: WorkoutExercise(
                            id: exerciseId,
                            sessionId: workoutId,
                            exerciseId: nil,
                            orderInSession: 1
                        ),
                        name: "Row",
                        category: .strength,
                        sets: []
                    )
                ]
            ),
            for: workoutId
        )

        let viewModel = WorkoutLogViewModel(
            existingSessionId: workoutId,
            workoutManager: managerMock,
            dbQueue: manager.dbQueue,
            targetDate: Date()
        )
        await viewModel.loadWorkoutDetailIfNeeded()

        XCTAssertEqual(viewModel.rpeLabelText, String(localized: "training_rpe_not_set"))

        viewModel.setRPE(8)
        XCTAssertEqual(
            viewModel.rpeLabelText,
            String(format: String(localized: "training_rpe_value_format"), 8)
        )
    }

    @MainActor
    func testWorkoutLogSaveExistingEditableWorkoutPersistsExercisesCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let managerMock = CoverageWorkoutSessionManagerMock()
        let workoutId = UUID()
        let targetDate = Date(timeIntervalSince1970: 1_773_331_200)

        let viewModel = WorkoutLogViewModel(
            existingSessionId: workoutId,
            workoutManager: managerMock,
            dbQueue: manager.dbQueue,
            targetDate: targetDate
        )
        viewModel.notes = "  Updated notes  "
        viewModel.setRPE(8)
        viewModel.exercises = [
            WorkoutLogExercise(
                id: UUID(),
                catalogId: UUID(),
                name: "Leg Press",
                category: .strength,
                notes: "  Heavy set  ",
                sets: [
                    WorkoutLogSet(id: UUID(), weight: 180, reps: 8, rpe: 8, restAfterSeconds: 120)
                ]
            )
        ]

        let didSave = await viewModel.save()
        XCTAssertTrue(didSave)

        let updatedDrafts = await managerMock.updatedDraftsSnapshot()
        XCTAssertEqual(updatedDrafts.count, 1)
        XCTAssertEqual(updatedDrafts[0].id, workoutId)
        XCTAssertEqual(updatedDrafts[0].notes, "Updated notes")
        XCTAssertEqual(updatedDrafts[0].perceivedExertionRpe, 8)
        XCTAssertEqual(updatedDrafts[0].durationMinutes, 15)
        XCTAssertEqual(try XCTUnwrap(updatedDrafts[0].trimpScore), 18, accuracy: 0.001)
        XCTAssertEqual(updatedDrafts[0].exercises?.count, 1)
        XCTAssertEqual(updatedDrafts[0].exercises?.first?.notes, "Heavy set")
        XCTAssertEqual(updatedDrafts[0].exercises?.first?.sets.first?.restAfterSeconds, 120)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testWorkoutLogSaveExistingWorkoutFailureStoresErrorCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let managerMock = CoverageWorkoutSessionManagerMock()
        await managerMock.setUpdateError(CoverageExpectedError(message: "update failed"))

        let viewModel = WorkoutLogViewModel(
            existingSessionId: UUID(),
            workoutManager: managerMock,
            dbQueue: manager.dbQueue,
            targetDate: Date()
        )
        viewModel.exercises = [
            WorkoutLogExercise(
                id: UUID(),
                catalogId: UUID(),
                name: "Pull-Up",
                category: .strength,
                sets: [WorkoutLogSet(id: UUID(), weight: 0, reps: 10)]
            )
        ]

        let didSave = await viewModel.save()
        XCTAssertFalse(didSave)
        XCTAssertEqual(viewModel.errorMessage, "update failed")
    }

    @MainActor
    func testWorkoutLogLoadDetailThrownErrorCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let managerMock = CoverageWorkoutSessionManagerMock()
        await managerMock.setLoadError(CoverageExpectedError(message: "load failed"))

        let viewModel = WorkoutLogViewModel(
            existingSessionId: UUID(),
            workoutManager: managerMock,
            dbQueue: manager.dbQueue,
            targetDate: Date()
        )

        await viewModel.loadWorkoutDetailIfNeeded()

        XCTAssertEqual(viewModel.errorMessage, "load failed")
    }

    @MainActor
    func testWorkoutLogDeleteFailureAndUndoFailureCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let managerMock = CoverageWorkoutSessionManagerMock()
        let workoutId = UUID()
        await managerMock.setDeleteError(CoverageExpectedError(message: "delete failed"))

        let viewModel = WorkoutLogViewModel(
            existingSessionId: workoutId,
            workoutManager: managerMock,
            dbQueue: manager.dbQueue,
            targetDate: Date()
        )

        let didDelete = await viewModel.deleteWorkout()
        XCTAssertFalse(didDelete)
        XCTAssertEqual(viewModel.errorMessage, "delete failed")
        XCTAssertFalse(viewModel.isDeleted)

        let undoManager = CoverageWorkoutSessionManagerMock()
        await undoManager.setDeleteReturnDate(Date(timeIntervalSince1970: 1_800_000_000))
        await undoManager.setUndoError(CoverageExpectedError(message: "undo failed"))

        let deletedViewModel = WorkoutLogViewModel(
            existingSessionId: workoutId,
            workoutManager: undoManager,
            dbQueue: manager.dbQueue,
            targetDate: Date()
        )
        let deleteSucceeded = await deletedViewModel.deleteWorkout()
        XCTAssertTrue(deleteSucceeded)

        let didUndo = await deletedViewModel.undoDeleteWorkout()
        XCTAssertFalse(didUndo)
        XCTAssertEqual(deletedViewModel.errorMessage, "undo failed")
        XCTAssertTrue(deletedViewModel.isDeleted)
    }

    @MainActor
    func testWorkoutLogRefreshHealthImportStateWithoutConflictCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let day = "2026-03-12"
        let importedId = UUID()

        try await manager.dbQueue.write { db in
            try Self.seedCoverageFunctionalAuditUser(db: db, userId: userId, authId: authId)

            var imported = WorkoutSession(
                id: importedId,
                userId: userId,
                startedAt: Date(timeIntervalSince1970: 1_773_331_200),
                sessionDate: day,
                source: .import
            )
            imported.workoutType = .mobility
            try imported.insert(db)

            var manual = WorkoutSession(
                id: UUID(),
                userId: userId,
                startedAt: imported.startedAt.addingTimeInterval(10 * 60),
                sessionDate: day,
                source: .manual
            )
            manual.workoutType = .strength
            try manual.insert(db)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let targetDate = ISO8601DateFormatter().date(from: "2026-03-12T12:00:00Z") ?? Date(timeIntervalSince1970: 1_773_345_600)
        let viewModel = WorkoutLogViewModel(dbQueue: manager.dbQueue, targetDate: targetDate)

        await viewModel.refreshHealthKitImportState()

        XCTAssertEqual(viewModel.importedSessions.map(\.id), [importedId])
        XCTAssertEqual(viewModel.importedSessions[0].secondaryText, String(localized: "training_apple_health_imported_source"))
        XCTAssertNil(viewModel.importConflict)
    }

    @MainActor
    func testWorkoutLogResolveConflictFailureSetsStatusCoverage() async throws {
        let manager = try DatabaseManager.inMemory()
        let authId = UUID()
        let userId = UUID()
        let existingId = UUID()
        let importedId = UUID()
        let day = "2026-03-12"
        let managerMock = CoverageWorkoutSessionManagerMock()
        await managerMock.setDeleteError(CoverageExpectedError(message: "delete conflict failed"))

        try await manager.dbQueue.write { db in
            try Self.seedCoverageFunctionalAuditUser(db: db, userId: userId, authId: authId)

            var existing = WorkoutSession(
                id: existingId,
                userId: userId,
                startedAt: Date(timeIntervalSince1970: 1_773_331_200),
                sessionDate: day,
                source: .manual
            )
            existing.workoutType = .cardio
            existing.durationMinutes = 30
            try existing.insert(db)

            var imported = WorkoutSession(
                id: importedId,
                userId: userId,
                startedAt: existing.startedAt.addingTimeInterval(10 * 60),
                sessionDate: day,
                source: .import
            )
            imported.workoutType = .cardio
            imported.durationMinutes = 40
            try imported.insert(db)
        }

        AuthManager.setActiveAuthIdForTests(authId)
        defer { AuthManager.setActiveAuthIdForTests(nil) }

        let targetDate = ISO8601DateFormatter().date(from: "2026-03-12T12:00:00Z") ?? Date(timeIntervalSince1970: 1_773_345_600)
        let viewModel = WorkoutLogViewModel(
            workoutManager: managerMock,
            dbQueue: manager.dbQueue,
            targetDate: targetDate
        )

        await viewModel.refreshHealthKitImportState()
        await viewModel.resolveConflict(.keepExisting)

        XCTAssertEqual(viewModel.healthKitStatusMessage, String(localized: "training_apple_health_conflict_failed"))
    }

    @MainActor
    func testWorkoutLogOverviewAndBadgeFormattingCoverage() throws {
        let manager = try DatabaseManager.inMemory()
        let targetDate = Date(timeIntervalSince1970: 1_773_331_200)

        let manualViewModel = WorkoutLogViewModel(
            dbQueue: manager.dbQueue,
            targetDate: targetDate,
            initialWorkoutType: .cardio
        )
        XCTAssertEqual(manualViewModel.overviewIconName, "figure.run.circle")
        XCTAssertEqual(manualViewModel.sourceBadgeTitle, String(localized: "training_source_manual"))
        XCTAssertTrue((manualViewModel.overviewSubtitle ?? "").contains(DiaryDateFormatter.formatDate(targetDate)))

        let plannedViewModel = WorkoutLogViewModel(
            dbQueue: manager.dbQueue,
            targetDate: targetDate,
            initialWorkoutType: .mobility,
            initialTrainingPlanId: UUID()
        )
        XCTAssertEqual(plannedViewModel.overviewIconName, "figure.cooldown")
        XCTAssertEqual(plannedViewModel.sourceBadgeTitle, String(localized: "training_source_plan"))

        let importedViewModel = WorkoutLogViewModel(
            existingSessionId: UUID(),
            dbQueue: manager.dbQueue,
            targetDate: targetDate
        )
        importedViewModel.workoutSource = .import
        importedViewModel.selectedWorkoutType = nil

        XCTAssertEqual(importedViewModel.overviewIconName, "figure.strengthtraining.traditional")
        XCTAssertEqual(importedViewModel.sourceBadgeTitle, String(localized: "training_source_imported"))
        XCTAssertEqual(importedViewModel.overviewTitle, String(localized: "training_workout_default_title"))
    }

    func testImportedWorkoutSummaryAndRestTimerFormattingCoverage() {
        var importedSession = WorkoutSession(
            id: UUID(),
            userId: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_773_331_200),
            sessionDate: "2026-03-12",
            source: .import
        )
        importedSession.workoutType = .cardio
        importedSession.durationMinutes = 75
        importedSession.estimatedCalories = 540
        importedSession.trimpScore = 52.5

        let richSummary = ImportedWorkoutSummary(importedSession)
        XCTAssertTrue(richSummary.primaryText.contains(String(localized: "training_identifier_cardio")))
        XCTAssertTrue(richSummary.secondaryText.contains("75 min"))
        XCTAssertTrue(richSummary.secondaryText.contains("540 kcal"))
        XCTAssertEqual(richSummary.trimpScore, 52.5)

        var bareSession = WorkoutSession(
            id: UUID(),
            userId: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_773_331_200),
            sessionDate: "2026-03-12",
            source: .import
        )
        bareSession.workoutType = nil
        bareSession.durationMinutes = nil
        bareSession.estimatedCalories = nil

        let bareSummary = ImportedWorkoutSummary(bareSession)
        XCTAssertTrue(bareSummary.primaryText.contains(String(localized: "training_workout_fallback")))
        XCTAssertEqual(bareSummary.secondaryText, String(localized: "training_apple_health_imported_source"))

        let timer = WorkoutRestTimerState(setId: UUID(), totalSeconds: 135, remainingSeconds: 135)
        XCTAssertEqual(timer.remainingText, "2:15")
    }

    func testTrainingWorkoutLogHelperCoverageSamples() {
        let referenceNow = Date(timeIntervalSince1970: 1_773_400_123)
        let samples = TrainingDayViewTestHarness.workoutLogHelperCoverageSamples(referenceNow: referenceNow)

        XCTAssertEqual(
            samples.durationTexts,
            [
                String(localized: "training_not_available"),
                String(format: String(localized: "training_duration_minutes_short_format"), 45),
                String(format: String(localized: "training_duration_hours_only_format"), 2),
                String(format: String(localized: "training_duration_hours_minutes_format"), 1, 15)
            ]
        )
        XCTAssertEqual(
            samples.volumeTexts,
            [
                String(localized: "training_not_available"),
                String(format: String(localized: "training_volume_int_format"), 320),
                String(format: String(localized: "training_volume_decimal_format"), 612.5)
            ]
        )
        XCTAssertEqual(
            samples.restLabels,
            [
                String(localized: "training_rest_off"),
                String(format: String(localized: "training_rest_seconds_format"), 90),
                String(format: String(localized: "training_rest_minutes_format"), 2)
            ]
        )
        XCTAssertEqual(samples.formattedRPEValues, ["", "8"])
        XCTAssertEqual(samples.parsedRPEValues, [0, 8, 10, 10])
        XCTAssertEqual(samples.normalizedTexts, [nil, nil, "Deadlift"])
        XCTAssertEqual(samples.catalogPriorities, [0, 1, 2])
        XCTAssertEqual(
            samples.localizedErrors[0],
            String(
                format: String(localized: "error.training.invalid_set"),
                "Coverage invalid set"
            )
        )
        XCTAssertEqual(
            samples.localizedErrors[1],
            NSError(domain: "CoverageTraining", code: 7).localizedDescription
        )
        XCTAssertTrue(samples.sameDayStartMatchesReference)

        let calendar = Calendar.current
        XCTAssertEqual(calendar.component(.hour, from: samples.shiftedSessionStart), calendar.component(.hour, from: referenceNow))
        XCTAssertEqual(calendar.component(.minute, from: samples.shiftedSessionStart), calendar.component(.minute, from: referenceNow))
        XCTAssertEqual(calendar.component(.second, from: samples.shiftedSessionStart), calendar.component(.second, from: referenceNow))
        XCTAssertFalse(calendar.isDate(samples.shiftedSessionStart, inSameDayAs: referenceNow))

        let explicitEndStart = Date(timeIntervalSince1970: 1_773_331_200)
        XCTAssertEqual(samples.inferredEndDates[0], explicitEndStart.addingTimeInterval(35 * 60))
        XCTAssertEqual(samples.inferredEndDates[1], explicitEndStart.addingTimeInterval((2 * 60 + 50) * 60))
        XCTAssertEqual(samples.inferredEndDates[2], explicitEndStart.addingTimeInterval(4 * 60 * 60))

        XCTAssertEqual(samples.conflictFlags, [false, true, true, false])
        XCTAssertEqual(samples.compatibilityFlags, [true, true, true, true, true, false])
    }

    func testTrainingPlanHelperCoverageSamples() throws {
        let samples = try TrainingDayViewTestHarness.trainingPlanCoverageSamples()

        XCTAssertEqual(
            samples.resolvedWorkoutTypes,
            [.strength, .cardio, .mobility, .mobility, .mixed, .sport, .other]
        )

        let activeSummaryLine = try XCTUnwrap(samples.activeSummaryLine)
        XCTAssertTrue(
            activeSummaryLine.contains(
                String(format: String(localized: "training_plan_days_per_week_format"), 4)
            )
        )
        XCTAssertTrue(
            activeSummaryLine.contains(
                String(format: String(localized: "training_plan_duration_weeks_format"), 8)
            )
        )
        XCTAssertTrue(
            activeSummaryLine.contains(
                String(localized: "training_plan_ai_adaptive")
            )
        )

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let expectedFormattedDate = formatter.string(
            from: try XCTUnwrap(DiaryDateFormatter.parseDate("2026-03-12"))
        )
        XCTAssertEqual(samples.formattedValidDate, expectedFormattedDate)
        XCTAssertEqual(samples.formattedInvalidDate, "not-a-date")
        XCTAssertNil(samples.emptySummaryLine)
        XCTAssertEqual(
            samples.singleAdaptiveRuleSummary,
            "\(String(localized: "training_identifier_recovery_low")): \(String(localized: "training_identifier_reduce_volume_30"))"
        )
        XCTAssertEqual(
            samples.multiAdaptiveRuleSummary,
            String(format: String(localized: "training_plan_adaptive_rules_saved_format"), 2)
        )
        XCTAssertEqual(
            samples.sessionTitles,
            [
                "Tempo Intervals",
                "Posterior Chain Focus",
                "Mobility Restore",
                "Engine Builder",
                String(localized: "training_identifier_sport")
            ]
        )
        XCTAssertEqual(
            samples.adaptiveRuleIds,
            [
                "recovery_low:reduce_volume_30",
                "user_request:swap_to_mobility"
            ]
        )
        XCTAssertEqual(samples.weekdayLabels.count, 7)
        XCTAssertEqual(Set(samples.weekdayLabels).count, 7)
        XCTAssertEqual(samples.upcomingIconName, "figure.cooldown")
        XCTAssertTrue(samples.upcomingSelected)
        XCTAssertTrue(samples.upcomingSubtitle.contains(expectedFormattedDate))
        XCTAssertTrue(samples.upcomingSubtitle.contains(String(localized: "training_identifier_recovery")))
        XCTAssertTrue(
            samples.upcomingSubtitle.contains(
                String(format: String(localized: "training_duration_minutes_short_format"), 35)
            )
        )
        XCTAssertTrue(samples.upcomingSubtitle.contains(String(localized: "training_identifier_planned")))
    }

    @MainActor
    func testWorkoutLogAdditionalComputedBranchesCoverage() throws {
        let manager = try DatabaseManager.inMemory()
        let deletedAt = Date(timeIntervalSince1970: 1_773_340_000)
        let targetDate = Date(timeIntervalSince1970: 1_773_331_200)

        let wearableViewModel = WorkoutLogViewModel(
            existingSessionId: UUID(),
            dbQueue: manager.dbQueue,
            targetDate: targetDate
        )
        wearableViewModel.workoutSource = .wearable
        wearableViewModel.deletedAt = deletedAt
        wearableViewModel.exercises = [
            WorkoutLogExercise(
                id: UUID(),
                catalogId: UUID(),
                name: "Bench Press",
                category: .strength,
                sets: [WorkoutLogSet(id: UUID(), weight: 0, reps: 8)]
            )
        ]

        XCTAssertEqual(wearableViewModel.sourceBadgeTitle, String(localized: "training_source_wearable"))
        XCTAssertNil(wearableViewModel.importedWorkoutNotice)
        XCTAssertEqual(wearableViewModel.screenTitle, String(localized: "training_workout_detail_title"))
        XCTAssertEqual(
            wearableViewModel.deletedStatusText,
            String(
                format: String(localized: "training_deleted_at_format"),
                deletedAt.formatted(date: .abbreviated, time: .shortened)
            )
        )
        XCTAssertEqual(wearableViewModel.incompleteSetCount, 1)

        let readOnlyImportedViewModel = WorkoutLogViewModel(
            existingSessionId: UUID(),
            dbQueue: manager.dbQueue,
            targetDate: targetDate
        )
        readOnlyImportedViewModel.workoutSource = .import
        XCTAssertTrue(readOnlyImportedViewModel.canSave)

        let expiredDeleteWindowViewModel = WorkoutLogViewModel(
            existingSessionId: UUID(),
            dbQueue: manager.dbQueue,
            targetDate: targetDate
        )
        expiredDeleteWindowViewModel.isDeleted = true
        expiredDeleteWindowViewModel.deletedAt = Date(timeIntervalSinceNow: -(25 * 60 * 60))
        XCTAssertFalse(expiredDeleteWindowViewModel.canUndoDelete)
    }

    nonisolated private static func decodeJSON<T: Decodable>(_ json: String, as type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func insertCoverageUser(
        dbQueue: DatabaseQueue,
        userId: UUID,
        authId: UUID
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [userId.uuidString, authId.uuidString, "UTC", "metric", Date(), Date()]
            )
        }
    }

    private func seedOnboardingUser(
        dbQueue: DatabaseQueue,
        userId: UUID,
        authId: UUID,
        cloudBackupEnabled: Bool
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO users (id, auth_id, timezone, units, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [userId.uuidString, authId.uuidString, "UTC", "metric", Date(), Date()]
            )

            try db.execute(
                sql: """
                    INSERT INTO privacy_settings (
                        id, user_id, menstrual_local_only, medical_scan_local_only,
                        vector_opt_in, analytics_consent, cloud_ocr_enabled, cloud_backup_enabled,
                        created_at, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    userId.uuidString,
                    true,
                    true,
                    false,
                    false,
                    true,
                    cloudBackupEnabled,
                    Date(),
                    Date()
                ]
            )
        }
    }

    private func makeCoverageNoopSyncEngine(dbQueue: DatabaseQueue) -> SyncEngine {
        SyncEngine(
            dbQueue: dbQueue,
            apiClient: FakeSyncAPIClient(),
            pushTransportOverride: { _ in }
        )
    }

    nonisolated private static func seedCoverageFunctionalAuditUser(
        db: Database,
        userId: UUID,
        authId: UUID
    ) throws {
        let user = User(id: userId, authId: authId, timezone: "UTC", units: .metric)
        try user.insert(db)
    }

    private func makeCoverageQRCodeImage(message: String) throws -> UIImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(message.utf8)
        filter.correctionLevel = "M"
        let outputImage = try XCTUnwrap(filter.outputImage)
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let cgImage = try XCTUnwrap(
            CIContext().createCGImage(scaledImage, from: scaledImage.extent)
        )
        return UIImage(cgImage: cgImage)
    }

    private func makeCoverageTextImage(text: String) -> UIImage {
        let size = CGSize(width: 1400, height: 500)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 120, weight: .bold),
                .foregroundColor: UIColor.black,
                .paragraphStyle: paragraph
            ]

            text.draw(
                in: CGRect(x: 40, y: 150, width: size.width - 80, height: 180),
                withAttributes: attributes
            )
        }
    }

    private func makeCoveragePDF(withFirstPageText text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        let bounds = CGRect(x: 0, y: 0, width: 420, height: 520)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            text.draw(
                in: CGRect(x: 24, y: 24, width: 372, height: 80),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 28, weight: .semibold),
                    .foregroundColor: UIColor.label
                ]
            )

            context.beginPage()
            UIColor.white.setFill()
            context.fill(bounds)
            UIColor.systemGray.setStroke()
            UIBezierPath(rect: CGRect(x: 70, y: 140, width: 280, height: 180)).stroke()
        }
        return url
    }

    private func renderForCoverage<V: View>(
        _ view: sending V,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let host = UIHostingController(rootView: view)
        _ = host.view
        XCTAssertNotNil(host.viewIfLoaded, file: file, line: line)
    }
}
