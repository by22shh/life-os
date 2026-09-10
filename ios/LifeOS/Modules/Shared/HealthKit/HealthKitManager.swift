// MARK: - HealthKit Manager
// Source of truth: life_os_healthkit_spec.md
// RULE: Read-only access. No client-side API keys. All health data stays on device.

import Foundation
import HealthKit
import UIKit
import os

/// Manages all HealthKit interactions for Life OS.
/// Read-only access to HRV, RHR, sleep analysis, wrist temperature, respiratory rate,
/// blood oxygen, active calories, steps, exercise minutes.
actor HealthKitManager {
    static let shared = HealthKitManager()

    private let store = HKHealthStore()
    private static let anchorDefaultsPrefix = "healthkit_anchor_"
#if DEBUG
    private static let testIsAvailableOverride = LockedTestOverride<Bool>()
    private static let testRequestAccessOverride = LockedTestOverride<@Sendable () async throws -> Void>()
    private static let testDefaultRequestAccessRunner = LockedTestOverride<@Sendable () async throws -> Void>()
    private static let testStoreRequestAuthorizationRunner = LockedTestOverride<
        @Sendable (HKHealthStore, Set<HKObjectType>) async throws -> Void
    >()
    private static let testDefaultStoreRequestAuthorizationRunner = LockedTestOverride<
        @Sendable (HKHealthStore, Set<HKObjectType>) async throws -> Void
    >()
    private static let testAuthorizedTypeCountOverride = LockedTestOverride<@Sendable () -> Int>()
    private static let testEnableBackgroundOverride = LockedTestOverride<@Sendable () async -> Void>()
    private static let testEnableBackgroundDeliveryRunner = LockedTestOverride<
        @Sendable ([HKSampleType]) async throws -> Void
    >()
    private static let testStoreEnableBackgroundDeliveryRunner = LockedTestOverride<
        @Sendable (HKHealthStore, HKSampleType, @escaping (Bool, Error?) -> Void) -> Void
    >()
    private static let testDefaultStoreEnableBackgroundDeliveryRunner = LockedTestOverride<
        @Sendable (HKHealthStore, HKSampleType, @escaping (Bool, Error?) -> Void) -> Void
    >()
    private static let testQuerySamplesOverride = LockedTestOverride<
        @Sendable (HKQuantityType, Date, Date, Int, Bool) async throws -> [HKQuantitySample]
    >()
    private static let testQueryAnchoredSamplesOverride = LockedTestOverride<
        @Sendable (HKQuantityType, Date, Date, String) async throws -> [HKQuantitySample]
    >()
    private static let testSleepSamplesOverride = LockedTestOverride<
        @Sendable (Date, Date) async throws -> [HKCategorySample]
    >()
    private static let testCumulativeSumOverride = LockedTestOverride<
        @Sendable (HKQuantityType, Date, HKUnit) async throws -> Double?
    >()
    private static let testDayBoundsDateByAddingRunner = LockedTestOverride<@Sendable (Calendar, Date) -> Date?>()
    private static let testEightAMDateByAddingRunner = LockedTestOverride<@Sendable (Calendar, Date) -> Date?>()
    private static let testAnchorUnarchiveRunner = LockedTestOverride<@Sendable (Data) throws -> HKQueryAnchor?>()
    private static let testAnchorArchiveRunner = LockedTestOverride<@Sendable (HKQueryAnchor) throws -> Data>()
    private static let testQuantitySampleSourceKeyOverride = LockedTestOverride<@Sendable (HKQuantitySample) -> String>()
    private static let testCategorySampleSourceKeyOverride = LockedTestOverride<@Sendable (HKCategorySample) -> String>()
#endif

    // MARK: - Authorization

    /// HealthKit types we request read access for.
    private static let readTypes: Set<HKObjectType> = {
        var types: Set<HKObjectType> = [
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.heartRate),
            HKQuantityType(.respiratoryRate),
            HKQuantityType(.oxygenSaturation),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.stepCount),
            HKQuantityType(.appleExerciseTime),
            HKQuantityType(.bodyMass),
            HKCategoryType(.sleepAnalysis),
            HKObjectType.workoutType(),
        ]
        // Wrist temperature available iOS 16+
        if #available(iOS 16.0, *) {
            types.insert(HKQuantityType(.appleSleepingWristTemperature))
        }
        return types
    }()

    /// Whether HealthKit is available on this device.
    static var isAvailable: Bool {
#if DEBUG
        if let override = testIsAvailableOverride.value {
            return override
        }
#endif
        return AppCapabilityAvailability.isHealthKitAvailable
    }

    /// Returns true when the system authorization request completes.
    /// Apple deliberately does not disclose whether read access was granted.
    func requestAuthorization() async throws -> Bool {
#if DEBUG
        let requestAccess = Self.testRequestAccessOverride.value ?? defaultRequestAccess
        let authorizedTypeCount = Self.testAuthorizedTypeCountOverride.value ?? defaultAuthorizedTypeCount
        let enableBackground = Self.testEnableBackgroundOverride.value ?? defaultEnableBackground
#else
        let requestAccess = defaultRequestAccess
        let authorizedTypeCount = defaultAuthorizedTypeCount
        let enableBackground = defaultEnableBackground
#endif

        return try await requestAuthorizationFlow(
            isAvailable: Self.isAvailable,
            requestAccess: requestAccess,
            authorizedTypeCount: authorizedTypeCount,
            enableBackground: enableBackground
        )
    }

    private func defaultRequestAccess() async throws {
#if DEBUG
        if let runner = Self.testDefaultRequestAccessRunner.value {
            try await runner()
            return
        }
#endif
        try await Self.requestReadAuthorization(store: store, readTypes: Self.readTypes)
    }

    private func defaultAuthorizedTypeCount() -> Int {
        Self.authorizedReadTypeCount(for: Self.readTypes) { type in
            store.authorizationStatus(for: type)
        }
    }

    private func defaultEnableBackground() async {
        try? await enableBackgroundDelivery()
    }

    // MARK: - HRV (SDNN → lnRMSSD Transform)

    /// Fetch the latest HRV sample and transform SDNN → lnRMSSD.
    /// Transform: `ln(SDNN × 1.1)` — approximation per spec.
    /// Rejects SDNN < 5ms as noise.
    func fetchLatestHRV(for date: Date) async throws -> Double? {
        try await fetchLatestHRV(for: Self.currentLocalDayContext(for: date))
    }

    func fetchLatestHRV(for dayContext: HistoricalLocalDayContext) async throws -> Double? {
        try await queryQuantityMetric(
            type: HKQuantityType(.heartRateVariabilitySDNN),
            limit: HKObjectQueryNoLimit,
            sortDescending: true,
            for: dayContext
        ) {
            // Source precedence: Apple Watch > third-party wearable > iPhone > manual.
            Self.latestHRVValue(from: preferredSourceSamples($0))
        }
    }

    // MARK: - Resting Heart Rate

    /// Fetch the latest resting heart rate for a given date.
    func fetchRestingHeartRate(for date: Date) async throws -> Int? {
        try await fetchRestingHeartRate(for: Self.currentLocalDayContext(for: date))
    }

    func fetchRestingHeartRate(for dayContext: HistoricalLocalDayContext) async throws -> Int? {
        try await queryQuantityMetric(
            type: HKQuantityType(.restingHeartRate),
            limit: HKObjectQueryNoLimit,
            sortDescending: true,
            for: dayContext
        ) {
            Self.meanRestingHeartRate(from: preferredSourceSamples($0))
        }
    }

    // MARK: - Sleep Analysis

    /// Fetch sleep data using the candidate window: D-1 18:00 → D 18:00 local.
    /// Returns total sleep duration in hours and stage breakdown.
    func fetchSleep(for date: Date) async throws -> SleepData? {
        try await fetchSleep(for: Self.currentLocalDayContext(for: date))
    }

    func fetchSleep(for dayContext: HistoricalLocalDayContext) async throws -> SleepData? {
        let (windowStart, windowEnd) = sleepCandidateWindow(for: dayContext)

        let samples = try await fetchSleepSamples(windowStart: windowStart, windowEnd: windowEnd)

        guard !samples.isEmpty else { return nil }
        let sourceScopedSamples = selectPreferredSleepSource(samples)
        let sleepWindowSamples = selectMainSleepBout(from: sourceScopedSamples, for: dayContext)
        return Self.sleepData(from: sleepWindowSamples)
    }

    // MARK: - Wrist Temperature

    /// Fetch wrist temperature deviation from baseline.
    @available(iOS 16.0, *)
    func fetchWristTemperature(for date: Date) async throws -> Double? {
        try await fetchWristTemperature(for: Self.currentLocalDayContext(for: date))
    }

    @available(iOS 16.0, *)
    func fetchWristTemperature(for dayContext: HistoricalLocalDayContext) async throws -> Double? {
        try await queryQuantityMetric(
            type: HKQuantityType(.appleSleepingWristTemperature),
            limit: 1,
            sortDescending: true,
            for: dayContext
        ) {
            $0.first?.quantity.doubleValue(for: .degreeCelsius())
        }
    }

    // MARK: - Activity Metrics

    /// Fetch total active calories burned for a date.
    func fetchActiveCalories(for date: Date) async throws -> Int? {
        try await fetchActiveCalories(for: Self.currentLocalDayContext(for: date))
    }

    func fetchActiveCalories(for dayContext: HistoricalLocalDayContext) async throws -> Int? {
        try await fetchCumulativeInt(
            type: HKQuantityType(.activeEnergyBurned),
            for: dayContext,
            unit: .kilocalorie()
        )
    }

    /// Fetch step count for a date.
    func fetchSteps(for date: Date) async throws -> Int? {
        try await fetchSteps(for: Self.currentLocalDayContext(for: date))
    }

    func fetchSteps(for dayContext: HistoricalLocalDayContext) async throws -> Int? {
        try await fetchCumulativeInt(
            type: HKQuantityType(.stepCount),
            for: dayContext,
            unit: .count()
        )
    }

    /// Fetch exercise minutes for a date.
    func fetchExerciseMinutes(for date: Date) async throws -> Int? {
        try await fetchExerciseMinutes(for: Self.currentLocalDayContext(for: date))
    }

    func fetchExerciseMinutes(for dayContext: HistoricalLocalDayContext) async throws -> Int? {
        try await fetchCumulativeInt(
            type: HKQuantityType(.appleExerciseTime),
            for: dayContext,
            unit: .minute()
        )
    }

    /// Fetch respiratory rate.
    func fetchRespiratoryRate(for date: Date) async throws -> Double? {
        try await fetchRespiratoryRate(for: Self.currentLocalDayContext(for: date))
    }

    func fetchRespiratoryRate(for dayContext: HistoricalLocalDayContext) async throws -> Double? {
        try await queryQuantityMetric(
            type: HKQuantityType(.respiratoryRate),
            limit: 1,
            sortDescending: true,
            for: dayContext
        ) {
            $0.first?.quantity.doubleValue(for: .count().unitDivided(by: .minute()))
        }
    }

    /// Fetch blood oxygen percentage (SpO2).
    func fetchBloodOxygen(for date: Date) async throws -> Double? {
        try await fetchBloodOxygen(for: Self.currentLocalDayContext(for: date))
    }

    func fetchBloodOxygen(for dayContext: HistoricalLocalDayContext) async throws -> Double? {
        try await queryQuantityMetric(
            type: HKQuantityType(.oxygenSaturation),
            limit: 5,
            sortDescending: true,
            for: dayContext
        ) {
            Self.bloodOxygenPercent(from: bestBySourcePrecedence($0))
        }
    }

    /// Fetch imported workout candidates for a single local day.
    func fetchWorkouts(for date: Date) async throws -> [HealthKitImportedWorkout] {
        try await fetchWorkouts(for: Self.currentLocalDayContext(for: date))
    }

    func fetchWorkouts(for dayContext: HistoricalLocalDayContext) async throws -> [HealthKitImportedWorkout] {
        let targetDay = dayContext.dayString
        let (start, end) = workoutQueryWindow(for: dayContext)
        let workouts = try await queryWorkouts(start: start, end: end)
        let deduplicated = deduplicateWorkouts(workouts)

        var imported: [HealthKitImportedWorkout] = []
        imported.reserveCapacity(deduplicated.count)

        for workout in deduplicated {
            let workoutTimeZone = Self.workoutTimeZone(for: workout) ?? dayContext.timeZone
            let sessionDate = Self.dayString(for: workout.startDate, timeZone: workoutTimeZone)
            guard sessionDate == targetDay else { continue }

            let durationMinutes = Self.workoutDurationMinutes(for: workout)
            let effort = try? await workoutEffort(for: workout, durationMinutes: durationMinutes)

            imported.append(
                HealthKitImportedWorkout(
                    sourceId: workout.uuid.uuidString,
                    startDate: workout.startDate,
                    endDate: workout.endDate,
                    sessionDate: sessionDate,
                    workoutType: Self.mapWorkoutType(workout.workoutActivityType),
                    estimatedCalories: Self.workoutEstimatedCalories(for: workout),
                    durationMinutes: durationMinutes,
                    startedTimezone: workoutTimeZone.identifier,
                    startedUTCOffsetMinutes: workoutTimeZone.secondsFromGMT(for: workout.startDate) / 60,
                    trimpScore: effort?.trimpScore,
                    inferredRPE: effort?.inferredRPE,
                    sourceRank: sourceRank(workout.sourceRevision, metadata: workout.metadata)
                )
            )
        }

        return imported.sorted { $0.startDate < $1.startDate }
    }

    /// Returns a 0-1 score indicating how complete today's health data is.
    /// Data completeness score per spec §4.3:
    /// HRV=0.35, Sleep=0.35, RHR=0.20, Activity=0.10
    ///
    /// P2 #13: Optimized overload that accepts pre-fetched data to avoid
    /// duplicate HealthKit queries when called from `syncDailyState`.
    func dataCompleteness(
        hrv: Double?,
        sleep: SleepData?,
        rhr: Int?,
        steps: Int?,
        activeCal: Int?
    ) -> Double {
        var score = 0.0
        if hrv != nil { score += 0.35 }
        if sleep != nil { score += 0.35 }
        if rhr != nil { score += 0.20 }
        if (steps ?? 0) > 0 || (activeCal ?? 0) > 0 { score += 0.10 }
        return score
    }

    /// Convenience: queries HealthKit directly (used outside syncDailyState).
    func dataCompleteness(for date: Date) async throws -> Double {
        let dayContext = Self.currentLocalDayContext(for: date)
        let hrv = try? await fetchLatestHRV(for: dayContext)
        let sleep = try? await fetchSleep(for: dayContext)
        let rhr = try? await fetchRestingHeartRate(for: dayContext)
        let steps = (try? await fetchSteps(for: dayContext)) ?? 0
        let activeCal = (try? await fetchActiveCalories(for: dayContext)) ?? 0
        return dataCompleteness(hrv: hrv, sleep: sleep, rhr: rhr, steps: steps, activeCal: activeCal)
    }

    // MARK: - Helpers

    private func fetchSleepSamples(windowStart: Date, windowEnd: Date) async throws -> [HKCategorySample] {
#if DEBUG
        if let override = Self.testSleepSamplesOverride.value {
            return try await override(windowStart, windowEnd)
        }
#endif
        let predicate = HKQuery.predicateForSamples(withStart: windowStart, end: windowEnd, options: .strictStartDate)
        let resolve: @Sendable ([HKSample]?, Error?) -> Result<[HKCategorySample], Error> = { results, error in
            Result { try Self.resolveCategorySamples(results: results, error: error) }
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKCategorySample], Error>) in
            let query = HKSampleQuery(
                sampleType: HKCategoryType(.sleepAnalysis),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                continuation.resume(with: resolve(results, error))
            }
            store.execute(query)
        }
    }

    private func queryWorkouts(start: Date, end: Date) async throws -> [HKWorkout] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKWorkout], Error>) in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let workouts = (results as? [HKWorkout]) ?? []
                continuation.resume(returning: workouts)
            }
            store.execute(query)
        }
    }

    /// Day bounds: midnight → midnight+1 for a given date.
    private func dayBounds(for date: Date) -> (start: Date, end: Date) {
        dayBounds(for: Self.currentLocalDayContext(for: date))
    }

    private func dayBounds(for dayContext: HistoricalLocalDayContext) -> (start: Date, end: Date) {
        let calendar = Self.calendar(timeZone: dayContext.timeZone)
        let startOfDay = HistoricalLocalDayContext.referenceDate(
            for: dayContext.dayString,
            timeZone: dayContext.timeZone,
            hour: 0
        ) ?? calendar.startOfDay(for: dayContext.referenceDate)
        let calculatedEnd: Date?
#if DEBUG
        if let runner = Self.testDayBoundsDateByAddingRunner.value {
            calculatedEnd = runner(calendar, startOfDay)
        } else {
            calculatedEnd = calendar.date(byAdding: .day, value: 1, to: startOfDay)
        }
#else
        calculatedEnd = calendar.date(byAdding: .day, value: 1, to: startOfDay)
#endif
        let endOfDay: Date
        if let calculatedEnd {
            endOfDay = calculatedEnd
        } else {
            endOfDay = startOfDay.addingTimeInterval(86_400)
        }
        return (startOfDay, endOfDay)
    }

    /// Query a wider window, then filter by workout-local day.
    /// This keeps historical days stable when workouts were recorded in another timezone.
    private func workoutQueryWindow(for date: Date) -> (start: Date, end: Date) {
        workoutQueryWindow(for: Self.currentLocalDayContext(for: date))
    }

    private func workoutQueryWindow(for dayContext: HistoricalLocalDayContext) -> (start: Date, end: Date) {
        let calendar = Self.calendar(timeZone: dayContext.timeZone)
        let dayStart = HistoricalLocalDayContext.referenceDate(
            for: dayContext.dayString,
            timeZone: dayContext.timeZone,
            hour: 0
        ) ?? calendar.startOfDay(for: dayContext.referenceDate)
        let start = calendar.date(byAdding: .hour, value: -24, to: dayStart)
            ?? dayStart.addingTimeInterval(-86_400)
        let end = calendar.date(byAdding: .hour, value: 48, to: dayStart)
            ?? dayStart.addingTimeInterval(172_800)
        return (start, end)
    }

    private func queryQuantityMetric<T>(
        type: HKQuantityType,
        limit: Int,
        sortDescending: Bool,
        for date: Date,
        transform: ([HKQuantitySample]) -> T
    ) async throws -> T {
        let (start, end) = dayBounds(for: date)
        return transform(
            try await querySamples(
                type: type,
                start: start,
                end: end,
                limit: limit,
                sortDescending: sortDescending
            )
        )
    }

    private func queryQuantityMetric<T>(
        type: HKQuantityType,
        limit: Int,
        sortDescending: Bool,
        for dayContext: HistoricalLocalDayContext,
        transform: ([HKQuantitySample]) -> T
    ) async throws -> T {
        let (start, end) = dayBounds(for: dayContext)
        return transform(
            try await querySamples(
                type: type,
                start: start,
                end: end,
                limit: limit,
                sortDescending: sortDescending
            )
        )
    }

    private func workoutEffort(for workout: HKWorkout, durationMinutes: Int) async throws -> WorkoutEffortEstimate {
        let samples = try await querySamples(
            type: HKQuantityType(.heartRate),
            start: workout.startDate,
            end: workout.endDate,
            limit: HKObjectQueryNoLimit,
            sortDescending: false
        )
        .filter { sample in
            let bpm = sample.quantity.doubleValue(for: .count().unitDivided(by: .minute()))
            return bpm >= 25 &&
                bpm <= 220 &&
                (sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool) != true
        }

        guard samples.count >= 30 else {
            let fallbackRPE = 3
            let fallbackTRIMP = min(Double(durationMinutes) * (Double(fallbackRPE) / 10.0) * 1.5, 200)
            return WorkoutEffortEstimate(trimpScore: fallbackTRIMP, inferredRPE: fallbackRPE)
        }

        let bpmValues = samples
            .map { $0.quantity.doubleValue(for: .count().unitDivided(by: .minute())) }
            .sorted()

        guard let peakHeartRate = Self.percentile(values: bpmValues, percentile: 0.95), peakHeartRate > 0 else {
            return WorkoutEffortEstimate(trimpScore: nil, inferredRPE: 3)
        }

        var zoneMinutes = [0.0, 0.0, 0.0, 0.0, 0.0]
        for (index, sample) in samples.enumerated() {
            let bpm = sample.quantity.doubleValue(for: .count().unitDivided(by: .minute()))
            let nextDate = index + 1 < samples.count ? samples[index + 1].startDate : workout.endDate
            let deltaMinutes = max(0, nextDate.timeIntervalSince(sample.startDate) / 60.0)
            guard deltaMinutes > 0 else { continue }

            let normalized = bpm / peakHeartRate
            let zoneIndex: Int
            switch normalized {
            case ..<0.60:
                zoneIndex = 0
            case ..<0.70:
                zoneIndex = 1
            case ..<0.80:
                zoneIndex = 2
            case ..<0.90:
                zoneIndex = 3
            default:
                zoneIndex = 4
            }
            zoneMinutes[zoneIndex] += deltaMinutes
        }

        let weights = [1.0, 2.0, 4.0, 7.0, 12.0]
        let totalZoneMinutes = zoneMinutes.reduce(0, +)
        let trimpScore = zip(zoneMinutes, weights).reduce(0.0) { $0 + ($1.0 * $1.1) }

        let weightedIntensity = totalZoneMinutes > 0
            ? zip(zoneMinutes, [1.0, 2.0, 3.0, 4.0, 5.0]).reduce(0.0) { $0 + ($1.0 * $1.1) } / totalZoneMinutes
            : 1.0
        let inferredRPE = min(10, max(3, Int((weightedIntensity * 1.75 + 1.25).rounded())))

        return WorkoutEffortEstimate(
            trimpScore: trimpScore > 0 ? trimpScore : nil,
            inferredRPE: inferredRPE
        )
    }

    private func fetchCumulativeInt(
        type: HKQuantityType,
        for date: Date,
        unit: HKUnit
    ) async throws -> Int? {
        try await fetchCumulativeSum(type: type, for: date, unit: unit).map(Int.init)
    }

    private func fetchCumulativeInt(
        type: HKQuantityType,
        for dayContext: HistoricalLocalDayContext,
        unit: HKUnit
    ) async throws -> Int? {
        try await fetchCumulativeSum(type: type, for: dayContext, unit: unit).map(Int.init)
    }

    /// Generic quantity sample query.
    private func querySamples(
        type: HKQuantityType,
        start: Date,
        end: Date,
        limit: Int,
        sortDescending: Bool
    ) async throws -> [HKQuantitySample] {
#if DEBUG
        if let override = Self.testQuerySamplesOverride.value {
            return try await override(type, start, end, limit, sortDescending)
        }
#endif
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKQuantitySample], Error>) in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: !sortDescending)]
            ) { _, results, error in
                do {
                    continuation.resume(returning: try Self.resolveQuantitySamples(results: results, error: error))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            store.execute(query)
        }
    }

    /// Anchored incremental query for quantity types.
    /// Stores/loads query anchors by key to support deterministic incremental refresh.
    func queryAnchoredSamples(
        type: HKQuantityType,
        start: Date,
        end: Date,
        anchorKey: String
    ) async throws -> [HKQuantitySample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let loadedAnchor = Self.loadAnchor(anchorKey: anchorKey)

#if DEBUG
        if let override = Self.testQueryAnchoredSamplesOverride.value {
            return try await override(type, start, end, anchorKey)
        }
#endif

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKQuantitySample], Error>) in
            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: predicate,
                anchor: loadedAnchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, _, newAnchor, error in
                do {
                    continuation.resume(returning: try Self.resolveAnchoredQuantitySamples(
                        samples: samples,
                        newAnchor: newAnchor,
                        error: error,
                        anchorKey: anchorKey
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            store.execute(query)
        }
    }

    /// Cumulative sum statistics for a quantity type over a day.
    private func fetchCumulativeSum(
        type: HKQuantityType,
        for date: Date,
        unit: HKUnit
    ) async throws -> Double? {
#if DEBUG
        if let override = Self.testCumulativeSumOverride.value {
            return try await override(type, date, unit)
        }
#endif
        let (start, end) = dayBounds(for: date)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double?, Error>) in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, error in
                do {
                    continuation.resume(returning: try Self.resolveCumulativeSum(stats: stats, error: error, unit: unit))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            store.execute(query)
        }
    }

    private func fetchCumulativeSum(
        type: HKQuantityType,
        for dayContext: HistoricalLocalDayContext,
        unit: HKUnit
    ) async throws -> Double? {
#if DEBUG
        if let override = Self.testCumulativeSumOverride.value {
            return try await override(type, dayContext.referenceDate, unit)
        }
#endif
        let (start, end) = dayBounds(for: dayContext)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double?, Error>) in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, error in
                do {
                    continuation.resume(returning: try Self.resolveCumulativeSum(stats: stats, error: error, unit: unit))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            store.execute(query)
        }
    }

    /// Source precedence: Apple Watch > third-party wearable > iPhone > manual.
    private func bestBySourcePrecedence(_ samples: [HKQuantitySample]) -> HKQuantitySample? {
        guard !samples.isEmpty else { return nil }
        return samples.sorted { lhs, rhs in
            let lhsRank = sourceRank(lhs.sourceRevision, metadata: lhs.metadata)
            let rhsRank = sourceRank(rhs.sourceRevision, metadata: rhs.metadata)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.startDate > rhs.startDate
        }.first
    }

    private func preferredSourceSamples(_ samples: [HKQuantitySample]) -> [HKQuantitySample] {
        guard !samples.isEmpty else { return [] }
        let grouped = Dictionary(grouping: samples) { sample in
#if DEBUG
            if let override = Self.testQuantitySampleSourceKeyOverride.value {
                return override(sample)
            }
#endif
            return sample.sourceRevision.source.bundleIdentifier
        }

        let bestGroup = grouped.max { lhs, rhs in
            let lhsRank = sourceRank(lhs.value[0].sourceRevision, metadata: lhs.value[0].metadata)
            let rhsRank = sourceRank(rhs.value[0].sourceRevision, metadata: rhs.value[0].metadata)
            if lhsRank != rhsRank {
                return lhsRank > rhsRank
            }
            return lhs.value.count < rhs.value.count
        }!
        return bestGroup.value
    }

    private func sourceRank(_ revision: HKSourceRevision, metadata: [String: Any]?) -> Int {
        Self.sourceRank(
            bundleIdentifier: revision.source.bundleIdentifier,
            productType: revision.productType,
            metadata: metadata
        )
    }

    private func deduplicateWorkouts(_ workouts: [HKWorkout]) -> [HKWorkout] {
        let sorted = workouts.sorted { lhs, rhs in
            let lhsRank = sourceRank(lhs.sourceRevision, metadata: lhs.metadata)
            let rhsRank = sourceRank(rhs.sourceRevision, metadata: rhs.metadata)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            if lhs.startDate != rhs.startDate {
                return lhs.startDate < rhs.startDate
            }
            return lhs.duration > rhs.duration
        }

        var deduplicated: [HKWorkout] = []
        for workout in sorted {
            let isDuplicate = deduplicated.contains { existing in
                Self.isPotentialDuplicateWorkout(existing, workout)
            }
            if !isDuplicate {
                deduplicated.append(workout)
            }
        }
        return deduplicated
    }

    private static func sourceRank(
        bundleIdentifier: String,
        productType: String?,
        metadata: [String: Any]?
    ) -> Int {
        if isWatchSource(bundleIdentifier: bundleIdentifier, productType: productType) { return 0 }
        if isIPhoneSource(productType: productType) { return 2 }
        if (metadata?[HKMetadataKeyWasUserEntered] as? Bool) == true { return 3 }
        return 1
    }

    private static func isWatchSource(bundleIdentifier: String, productType: String?) -> Bool {
        let bundle = bundleIdentifier.lowercased()
        let product = productType?.lowercased() ?? ""
        return bundle.contains("watch") || product.hasPrefix("watch")
    }

    private static func isIPhoneSource(productType: String?) -> Bool {
        let product = productType?.lowercased() ?? ""
        return product.hasPrefix("iphone")
    }

    private static func mapWorkoutType(_ activityType: HKWorkoutActivityType) -> WorkoutType {
        switch activityType {
        case .traditionalStrengthTraining, .functionalStrengthTraining:
            return .strength
        case .running,
             .walking,
             .cycling,
             .swimming,
             .rowing,
             .elliptical,
             .stairClimbing,
             .highIntensityIntervalTraining:
            return .cardio
        case .yoga, .pilates, .flexibility, .cooldown:
            return .mobility
        case .mixedCardio, .coreTraining:
            return .mixed
        case .basketball,
             .soccer,
             .tennis,
             .pickleball,
             .badminton,
             .volleyball,
             .martialArts,
             .boxing,
             .wrestling,
             .golf,
             .climbing,
             .surfingSports,
             .snowSports,
             .paddleSports:
            return .sport
        default:
            return .other
        }
    }

    private static func workoutEstimatedCalories(for workout: HKWorkout) -> Int? {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
              let quantity = workout.statistics(for: quantityType)?.sumQuantity() else {
            return nil
        }
        return Int(quantity.doubleValue(for: .kilocalorie()).rounded())
    }

    private static func workoutDurationMinutes(for workout: HKWorkout) -> Int {
        max(1, Int((workout.endDate.timeIntervalSince(workout.startDate) / 60.0).rounded()))
    }

    private static func workoutTimeZone(for workout: HKWorkout) -> TimeZone? {
        if let timeZone = workout.metadata?[HKMetadataKeyTimeZone] as? TimeZone {
            return timeZone
        }
        if let timeZone = workout.metadata?[HKMetadataKeyTimeZone] as? NSTimeZone {
            return timeZone as TimeZone
        }
        if let identifier = workout.metadata?[HKMetadataKeyTimeZone] as? String,
           let timeZone = TimeZone(identifier: identifier) {
            return timeZone
        }
        return nil
    }

    private static func dayString(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func currentLocalDayContext(for date: Date) -> HistoricalLocalDayContext {
        HistoricalLocalDayContext(
            referenceDate: date,
            dayString: dayString(for: date, timeZone: .current),
            timeZone: .current
        )
    }

    private static func calendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }

    private static func inferredEndDate(for workout: HKWorkout) -> Date {
        workout.endDate
    }

    private static func isPotentialDuplicateWorkout(_ lhs: HKWorkout, _ rhs: HKWorkout) -> Bool {
        let lhsType = mapWorkoutType(lhs.workoutActivityType)
        let rhsType = mapWorkoutType(rhs.workoutActivityType)
        guard areCompatibleWorkoutTypes(lhsType, rhsType) else {
            return false
        }

        let lhsStart = lhs.startDate
        let lhsEnd = inferredEndDate(for: lhs)
        let rhsStart = rhs.startDate
        let rhsEnd = inferredEndDate(for: rhs)

        let overlapStart = max(lhsStart, rhsStart)
        let overlapEnd = min(lhsEnd, rhsEnd)
        let overlap = max(0, overlapEnd.timeIntervalSince(overlapStart))
        let shorterDuration = max(1, min(lhsEnd.timeIntervalSince(lhsStart), rhsEnd.timeIntervalSince(rhsStart)))
        let overlapRatio = overlap / shorterDuration

        let startDelta = abs(lhsStart.timeIntervalSince(rhsStart))
        let lhsDuration = max(1, lhsEnd.timeIntervalSince(lhsStart))
        let rhsDuration = max(1, rhsEnd.timeIntervalSince(rhsStart))
        let durationDeltaRatio = abs(lhsDuration - rhsDuration) / max(lhsDuration, rhsDuration)

        return overlapRatio >= 0.6 || (startDelta <= 30 * 60 && durationDeltaRatio <= 0.25)
    }

    private static func areCompatibleWorkoutTypes(_ lhs: WorkoutType, _ rhs: WorkoutType) -> Bool {
        if lhs == rhs { return true }
        if lhs == .mixed || rhs == .mixed { return true }
        let cardioLike: Set<WorkoutType> = [.cardio, .sport]
        if cardioLike.contains(lhs) && cardioLike.contains(rhs) {
            return true
        }
        return lhs == .other || rhs == .other
    }

    private static func percentile(values: [Double], percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let bounded = min(max(percentile, 0), 1)
        let index = Int((Double(values.count - 1) * bounded).rounded(.down))
        return values[index]
    }

    private struct SleepSourceSelectionKey {
        let rank: Int
        let hasStages: Bool
        let durationSeconds: TimeInterval
    }

    private struct SleepBoutSelectionKey {
        let asleepMinutes: Double
        let distanceToEightAM: TimeInterval
        let hasStages: Bool
    }

    private func selectPreferredSleepSource(_ samples: [HKCategorySample]) -> [HKCategorySample] {
        let grouped = Dictionary(grouping: samples) { sample in
#if DEBUG
            if let override = Self.testCategorySampleSourceKeyOverride.value {
                return override(sample)
            }
#endif
            return sample.sourceRevision.source.bundleIdentifier
        }
        guard !grouped.isEmpty else { return [] }

        let groups = Array(grouped.values)
        let selectedSamples = groups.max { lhs, rhs in
            let lhsKey = sleepSourceSelectionKey(for: lhs)
            let rhsKey = sleepSourceSelectionKey(for: rhs)
            return Self.shouldPreferSleepSource(rhsKey, over: lhsKey)
        } ?? []
        return selectedSamples.sorted(by: { $0.startDate < $1.startDate })
    }

    private func sleepSourceSelectionKey(for samples: [HKCategorySample]) -> SleepSourceSelectionKey {
        guard let firstSample = samples.first else {
            return SleepSourceSelectionKey(rank: 0, hasStages: false, durationSeconds: 0)
        }
        return SleepSourceSelectionKey(
            rank: sourceRank(firstSample.sourceRevision, metadata: firstSample.metadata),
            hasStages: hasSleepStages(samples),
            durationSeconds: samples.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
        )
    }

    private func hasSleepStages(_ samples: [HKCategorySample]) -> Bool {
        samples.contains { sample in
            switch sample.value {
            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                 HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                 HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                return true
            default:
                return false
            }
        }
    }

    private func selectMainSleepBout(from samples: [HKCategorySample], for date: Date) -> [HKCategorySample] {
        selectMainSleepBout(from: samples, for: Self.currentLocalDayContext(for: date))
    }

    private func selectMainSleepBout(
        from samples: [HKCategorySample],
        for dayContext: HistoricalLocalDayContext
    ) -> [HKCategorySample] {
        guard !samples.isEmpty else { return [] }
        let sorted = samples.sorted(by: { $0.startDate < $1.startDate })
        var bouts: [[HKCategorySample]] = []
        var current: [HKCategorySample] = []

        for sample in sorted {
            guard let last = current.last else {
                current = [sample]
                continue
            }
            let gap = sample.startDate.timeIntervalSince(last.endDate)
            if gap <= 90 * 60 {
                current.append(sample)
            } else {
                bouts.append(current)
                current = [sample]
            }
        }
        if !current.isEmpty {
            bouts.append(current)
        }

        let calendar = Self.calendar(timeZone: dayContext.timeZone)
        let dayStart = HistoricalLocalDayContext.referenceDate(
            for: dayContext.dayString,
            timeZone: dayContext.timeZone,
            hour: 0
        ) ?? calendar.startOfDay(for: dayContext.referenceDate)
        let eightAM: Date
#if DEBUG
        if let runner = Self.testEightAMDateByAddingRunner.value {
            eightAM = runner(calendar, dayStart) ?? dayStart
        } else {
            eightAM = Self.defaultEightAMDate(calendar: calendar, dayStart: dayStart)
        }
#else
        eightAM = Self.defaultEightAMDate(calendar: calendar, dayStart: dayStart)
#endif

        guard let firstBout = bouts.first else { return [] }

        var selectedBout = firstBout
        var selectedKey = Self.sleepBoutSelectionKey(
            for: firstBout,
            eightAM: eightAM,
            hasStages: hasSleepStages,
            asleepMinutes: asleepMinutes
        )

        for bout in bouts.dropFirst() {
            let key = Self.sleepBoutSelectionKey(
                for: bout,
                eightAM: eightAM,
                hasStages: hasSleepStages,
                asleepMinutes: asleepMinutes
            )
            if Self.shouldPreferSleepBout(key, over: selectedKey) {
                selectedBout = bout
                selectedKey = key
            }
        }

        return selectedBout
    }

    private func sleepCandidateWindow(
        for dayContext: HistoricalLocalDayContext
    ) -> (start: Date, end: Date) {
        let calendar = Self.calendar(timeZone: dayContext.timeZone)
        let dayStart = HistoricalLocalDayContext.referenceDate(
            for: dayContext.dayString,
            timeZone: dayContext.timeZone,
            hour: 0
        ) ?? calendar.startOfDay(for: dayContext.referenceDate)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: dayStart)
            ?? dayStart.addingTimeInterval(-86_400)

        var startComponents = calendar.dateComponents([.year, .month, .day], from: yesterday)
        startComponents.hour = 18
        var endComponents = calendar.dateComponents([.year, .month, .day], from: dayStart)
        endComponents.hour = 18

        let windowStart = calendar.date(from: startComponents) ?? yesterday.addingTimeInterval(18 * 3_600)
        let windowEnd = calendar.date(from: endComponents) ?? dayStart.addingTimeInterval(18 * 3_600)
        return (windowStart, windowEnd)
    }

    private func asleepMinutes(_ samples: [HKCategorySample]) -> Double {
        samples.reduce(0.0) { partial, sample in
            switch sample.value {
            case HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                 HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                 HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                 HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                return partial + sample.endDate.timeIntervalSince(sample.startDate) / 60
            default:
                return partial
            }
        }
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        if sorted.count % 2 == 1 {
            return sorted[sorted.count / 2]
        }
        let upper = sorted[sorted.count / 2]
        let lower = sorted[sorted.count / 2 - 1]
        return (lower + upper) / 2
    }

    private func requestAuthorizationFlow(
        isAvailable: Bool,
        requestAccess: () async throws -> Void,
        authorizedTypeCount: () -> Int,
        enableBackground: () async -> Void
    ) async throws -> Bool {
        guard isAvailable else { return false }
        try await requestAccess()
        // authorizationStatus(for:) reports WRITE permission, never read access.
        // Successful request completion permits querying; denied reads return no data.
        _ = authorizedTypeCount // retained for compatibility with existing test hooks
        UserDefaults.standard.set(true, forKey: "healthkit_read_request_completed")
        await enableBackground()
        return true
    }

    private static func shouldPreferSleepSource(_ lhs: SleepSourceSelectionKey, over rhs: SleepSourceSelectionKey) -> Bool {
        if lhs.rank != rhs.rank {
            return lhs.rank < rhs.rank
        }
        if lhs.hasStages != rhs.hasStages {
            return lhs.hasStages && !rhs.hasStages
        }
        return lhs.durationSeconds > rhs.durationSeconds
    }

    private static func shouldPreferSleepBout(_ lhs: SleepBoutSelectionKey, over rhs: SleepBoutSelectionKey) -> Bool {
        if lhs.asleepMinutes != rhs.asleepMinutes {
            return lhs.asleepMinutes > rhs.asleepMinutes
        }
        if lhs.distanceToEightAM != rhs.distanceToEightAM {
            return lhs.distanceToEightAM < rhs.distanceToEightAM
        }
        return lhs.hasStages && !rhs.hasStages
    }

    private static func authorizedReadTypeCount(
        for readTypes: Set<HKObjectType>,
        status: (HKObjectType) -> HKAuthorizationStatus
    ) -> Int {
        readTypes.reduce(into: 0) { count, type in
            if status(type) == .sharingAuthorized {
                count += 1
            }
        }
    }

    private static func shouldEnableBackgroundDelivery(forAuthorizedTypeCount authorizedTypeCount: Int) -> Bool {
        authorizedTypeCount > 0
    }

    private static func latestHRVValue(from preferredSamples: [HKQuantitySample]) -> Double? {
        let validValues = preferredSamples
            .map { $0.quantity.doubleValue(for: .secondUnit(with: .milli)) }
            .filter { $0 >= 5.0 } // Reject SDNN < 5ms as noise

        // P1 #7: Use latest sample (first) instead of median for "Morning Readiness".
        // This better reflects the specific morning measurement context.
        guard let latestSdnn = validValues.first else { return nil }

        // Transform: ln(SDNN × 1.1) ≈ lnRMSSD approximation.
        return log(latestSdnn * 1.1)
    }

    private static func meanRestingHeartRate(from preferredSamples: [HKQuantitySample]) -> Int? {
        let values = preferredSamples.map { $0.quantity.doubleValue(for: .count().unitDivided(by: .minute())) }
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        return Int(mean.rounded())
    }

    private static func sleepData(from samples: [HKCategorySample]) -> SleepData {
        // Accumulate stages.
        var deepMinutes = 0.0
        var remMinutes = 0.0
        var coreMinutes = 0.0
        var awakeMinutes = 0.0
        var totalInBed = 0.0

        for sample in samples {
            let mins = sample.endDate.timeIntervalSince(sample.startDate) / 60

            switch sample.value {
            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                deepMinutes += mins
            case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                remMinutes += mins
            case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                coreMinutes += mins
            case HKCategoryValueSleepAnalysis.awake.rawValue:
                awakeMinutes += mins
            case HKCategoryValueSleepAnalysis.inBed.rawValue:
                totalInBed += mins
            default:
                // asleepUnspecified or other
                coreMinutes += mins
            }
        }

        let totalAsleepMinutes = deepMinutes + remMinutes + coreMinutes
        let totalDurationHours = totalAsleepMinutes / 60
        let efficiency = totalInBed > 0 ? (totalAsleepMinutes / totalInBed * 100) : nil

        return SleepData(
            totalHours: totalDurationHours,
            deepMinutes: Int(deepMinutes),
            remMinutes: Int(remMinutes),
            lightMinutes: Int(coreMinutes),
            awakeMinutes: Int(awakeMinutes),
            efficiency: efficiency,
            bedTime: samples.first?.startDate,
            wakeTime: samples.last?.endDate,
            hasStages: samples.contains {
                [HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                 HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                 HKCategoryValueSleepAnalysis.asleepCore.rawValue].contains($0.value)
            }
        )
    }

    private static func bloodOxygenPercent(from sample: HKQuantitySample?) -> Double? {
        guard let sample else { return nil }
        return sample.quantity.doubleValue(for: .percent()) * 100
    }

    private static func requestReadAuthorization(
        store: HKHealthStore,
        readTypes: Set<HKObjectType>
    ) async throws {
#if DEBUG
        if let testStoreRequestAuthorizationRunner = Self.testStoreRequestAuthorizationRunner.value {
            return try await testStoreRequestAuthorizationRunner(store, readTypes)
        }
        if let testDefaultStoreRequestAuthorizationRunner = Self.testDefaultStoreRequestAuthorizationRunner.value {
            return try await testDefaultStoreRequestAuthorizationRunner(store, readTypes)
        }
        return try await store.requestAuthorization(toShare: [], read: readTypes)
#else
        try await store.requestAuthorization(toShare: [], read: readTypes)
#endif
    }

    private static func loadAnchor(anchorKey: String) -> HKQueryAnchor? {
        let key = anchorDefaultsPrefix + anchorKey
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
#if DEBUG
        if let runner = testAnchorUnarchiveRunner.value {
            return try? runner(data)
        }
#endif
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private static func saveAnchor(_ anchor: HKQueryAnchor, anchorKey: String) {
        let key = anchorDefaultsPrefix + anchorKey
        let data: Data
        do {
#if DEBUG
            if let runner = testAnchorArchiveRunner.value {
                data = try runner(anchor)
            } else {
                data = try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
            }
#else
            data = try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
#endif
        } catch {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func resolveQuantitySamples(
        results: [HKSample]?,
        error: Error?
    ) throws -> [HKQuantitySample] {
        if let error {
            throw error
        }
        if let quantitySamples = results as? [HKQuantitySample] {
            return quantitySamples
        }
        return []
    }

    private static func resolveCategorySamples(
        results: [HKSample]?,
        error: Error?
    ) throws -> [HKCategorySample] {
        if let error {
            throw error
        }
        if let categorySamples = results as? [HKCategorySample] {
            return categorySamples
        }
        return []
    }

    private static func resolveAnchoredQuantitySamples(
        samples: [HKSample]?,
        newAnchor: HKQueryAnchor?,
        error: Error?,
        anchorKey: String
    ) throws -> [HKQuantitySample] {
        if let error {
            throw error
        }
        if let newAnchor {
            saveAnchor(newAnchor, anchorKey: anchorKey)
        }
        if let quantitySamples = samples as? [HKQuantitySample] {
            return quantitySamples
        }
        return []
    }

    private static func resolveCumulativeSum(
        stats: HKStatistics?,
        error: Error?,
        unit: HKUnit
    ) throws -> Double? {
        if let error {
            throw error
        }
        return stats?.sumQuantity()?.doubleValue(for: unit)
    }

    private static var backgroundDeliveryTypes: [HKSampleType] {
        [
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.restingHeartRate),
            HKCategoryType(.sleepAnalysis),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.stepCount),
            HKQuantityType(.appleExerciseTime)
        ]
    }

    // MARK: - Background Change Notifications
    //
    // enableBackgroundDelivery alone never wakes the app: per HealthKit's
    // contract, iOS only launches/suspends-resumes the process for a data type
    // when an HKObserverQuery for that type is installed. Without observers the
    // registration above is a no-op and data arrives only on foreground or
    // BGAppRefresh cycles.

    /// Reaction to HealthKit change notifications. Wired at app startup to run
    /// an incremental sync; defaults to no-op so this data layer stays
    /// independent of orchestration singletons.
    private static let backgroundChangeHandler =
        OSAllocatedUnfairLock<@Sendable () async -> Void>(initialState: {})

    static func setBackgroundChangeHandler(
        _ handler: @escaping @Sendable () async -> Void
    ) {
        backgroundChangeHandler.withLock { $0 = handler }
    }

    private nonisolated static func currentBackgroundChangeHandler()
        -> @Sendable () async -> Void {
        backgroundChangeHandler.withLock { $0 }
    }

    #if DEBUG
    private static let testInstallObserverRunner = LockedTestOverride<
        @Sendable (HKHealthStore, HKSampleType) -> Void
    >()
    private static var usesFakeDeliveryRunners: Bool {
        testStoreEnableBackgroundDeliveryRunner.value != nil ||
        testDefaultStoreEnableBackgroundDeliveryRunner.value != nil ||
        testEnableBackgroundDeliveryRunner.value != nil
    }
    #endif

    /// HealthKit's callback is not Sendable. Ownership is transferred to this
    /// locked, single-use holder before crossing the task boundary.
    private final class ObserverCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var callback: (() -> Void)?

        init(_ callback: @escaping () -> Void) { self.callback = callback }

        func finish() {
            lock.lock()
            let action = callback
            callback = nil
            lock.unlock()
            action?()
        }
    }

    @MainActor
    private final class ObserverBackgroundTask {
        private var identifier: UIBackgroundTaskIdentifier = .invalid

        func begin(onExpiration: @escaping @Sendable () -> Void) {
            identifier = UIApplication.shared.beginBackgroundTask(withName: "healthkit-observer-sync") { [weak self] in
                onExpiration()
                Task { @MainActor in self?.end() }
            }
        }

        func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }

    /// Installs the long-lived observer query required for background delivery
    /// to actually wake the process. Called once per registered type.
    private static func installObserverQuery(store: HKHealthStore, type: HKSampleType) {
        #if DEBUG
        if let runner = Self.testInstallObserverRunner.value {
            runner(store, type)
            return
        }
        // Unit tests fake the delivery path; do not touch real observer
        // machinery (or UIApplication) from hermetic tests.
        guard !Self.usesFakeDeliveryRunners else { return }
        #endif

        let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
            let completion = ObserverCompletion(completion)
            guard error == nil else {
                completion.finish()
                return
            }
            let work = Self.currentBackgroundChangeHandler()
            Task { @MainActor in
                let lease = ObserverBackgroundTask()
                lease.begin { completion.finish() }
                await work()
                lease.end()
                completion.finish()
            }
        }
        store.execute(query)
    }

    private static func enableBackgroundDelivery(
        for types: [HKSampleType],
        deliver: @escaping @Sendable (HKSampleType) async throws -> Bool
    ) async throws {
        for type in types {
            let success = try await deliver(type)
            guard success else {
                throw HealthKitError.authorizationDenied
            }
        }
    }

    private static func enableBackgroundDelivery(for types: [HKSampleType], store: HKHealthStore) async throws {
        try await enableBackgroundDelivery(for: types) { type in
            let success = try await requestBackgroundDelivery(store: store, type: type)
            guard success else { return false }
            installObserverQuery(store: store, type: type)
            return true
        }
    }

    private static func requestBackgroundDelivery(
        store: HKHealthStore,
        type: HKSampleType
    ) async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            let completion: @Sendable (Bool, Error?) -> Void = { success, error in
                continuation.resume(with: Self.backgroundDeliveryResult(success: success, error: error))
            }
            let enable: @Sendable (HKHealthStore, HKSampleType, @escaping @Sendable (Bool, Error?) -> Void) -> Void
#if DEBUG
            if let runner = Self.testStoreEnableBackgroundDeliveryRunner.value {
                enable = runner
            } else if let runner = Self.testDefaultStoreEnableBackgroundDeliveryRunner.value {
                enable = runner
            } else {
                enable = { store, type, completion in
                    store.enableBackgroundDelivery(for: type, frequency: .hourly, withCompletion: completion)
                }
            }
#else
            enable = { store, type, completion in
                store.enableBackgroundDelivery(for: type, frequency: .hourly, withCompletion: completion)
            }
#endif
            enable(store, type, completion)
        }
    }

    private static func defaultEightAMDate(calendar: Calendar, dayStart: Date) -> Date {
        resolvedEightAMDate(dayStart: dayStart) {
            calendar.date(byAdding: .hour, value: 8, to: $0)
        }
    }

    private static func resolvedEightAMDate(dayStart: Date, addEightHours: (Date) -> Date?) -> Date {
        if let eightAM = addEightHours(dayStart) {
            return eightAM
        }
        return dayStart
    }

    private static func sleepBoutSelectionKey(
        for bout: [HKCategorySample],
        eightAM: Date,
        hasStages: ([HKCategorySample]) -> Bool,
        asleepMinutes: ([HKCategorySample]) -> Double
    ) -> SleepBoutSelectionKey {
        let endDate = bout.last?.endDate ?? .distantPast
        return SleepBoutSelectionKey(
            asleepMinutes: asleepMinutes(bout),
            distanceToEightAM: abs(endDate.timeIntervalSince(eightAM)),
            hasStages: hasStages(bout)
        )
    }

    private static func backgroundDeliveryResult(success: Bool, error: Error?) -> Result<Bool, Error> {
        if let error {
            return .failure(error)
        }
        return .success(success)
    }

    func restoreBackgroundObservers() async {
        guard Self.isAvailable,
              UserDefaults.standard.bool(forKey: "healthkit_read_request_completed") else { return }
        try? await enableBackgroundDelivery()
    }

    private var backgroundObserversInstalled = false

    private func enableBackgroundDelivery() async throws {
        guard !backgroundObserversInstalled else { return }
#if DEBUG
        if let runner = Self.testEnableBackgroundDeliveryRunner.value {
            try await runner(Self.backgroundDeliveryTypes)
            return
        }
#endif
        try await Self.enableBackgroundDelivery(for: Self.backgroundDeliveryTypes, store: store)
        backgroundObserversInstalled = true
    }
}

#if DEBUG
extension HealthKitManager {
    func _testDayBounds(for date: Date) -> (start: Date, end: Date) {
        dayBounds(for: date)
    }

    func _testMedian(_ values: [Double]) -> Double? {
        median(values)
    }

    func _testHasSleepStages(_ samples: [HKCategorySample]) -> Bool {
        hasSleepStages(samples)
    }

    func _testAsleepMinutes(_ samples: [HKCategorySample]) -> Double {
        asleepMinutes(samples)
    }

    func _testSelectMainSleepBout(_ samples: [HKCategorySample], for date: Date) -> [HKCategorySample] {
        selectMainSleepBout(from: samples, for: date)
    }

    func _testSelectPreferredSleepSource(_ samples: [HKCategorySample]) -> [HKCategorySample] {
        selectPreferredSleepSource(samples)
    }

    func _testPreferredSourceSamples(_ samples: [HKQuantitySample]) -> [HKQuantitySample] {
        preferredSourceSamples(samples)
    }

    func _testBestBySourcePrecedence(_ samples: [HKQuantitySample]) -> HKQuantitySample? {
        bestBySourcePrecedence(samples)
    }

    func _testLatestHRVValue(from samples: [HKQuantitySample]) -> Double? {
        Self.latestHRVValue(from: samples)
    }

    func _testMeanRestingHeartRate(from samples: [HKQuantitySample]) -> Int? {
        Self.meanRestingHeartRate(from: samples)
    }

    func _testSleepData(from samples: [HKCategorySample]) -> SleepData {
        Self.sleepData(from: samples)
    }

    func _testBloodOxygenPercent(from sample: HKQuantitySample?) -> Double? {
        Self.bloodOxygenPercent(from: sample)
    }

    func _testAuthorizedReadTypeCount(
        for readTypes: Set<HKObjectType>,
        statuses: [ObjectIdentifier: HKAuthorizationStatus]
    ) -> Int {
        Self.authorizedReadTypeCount(for: readTypes) { type in
            let key = ObjectIdentifier(type)
            if let status = statuses[key] {
                return status
            }
            return .notDetermined
        }
    }

    func _testShouldEnableBackgroundDelivery(forAuthorizedTypeCount count: Int) -> Bool {
        Self.shouldEnableBackgroundDelivery(forAuthorizedTypeCount: count)
    }

    func _testRequestAuthorizationFlow(
        isAvailable: Bool,
        requestAccess: @escaping () async throws -> Void,
        authorizedTypeCount: @escaping () -> Int,
        enableBackground: @escaping () async -> Void
    ) async throws -> Bool {
        try await requestAuthorizationFlow(
            isAvailable: isAvailable,
            requestAccess: requestAccess,
            authorizedTypeCount: authorizedTypeCount,
            enableBackground: enableBackground
        )
    }

    func _testEnableBackgroundDelivery(
        types: [HKSampleType],
        deliver: @escaping @Sendable (HKSampleType) async throws -> Bool
    ) async throws {
        try await Self.enableBackgroundDelivery(for: types, deliver: deliver)
    }

    nonisolated static func _testReadTypesCount() -> Int {
        readTypes.count
    }

    nonisolated static func _testBackgroundDeliveryTypesCount() -> Int {
        backgroundDeliveryTypes.count
    }

    nonisolated static func _testSetIsAvailableOverride(_ value: Bool?) {
        testIsAvailableOverride.value = value
    }

    nonisolated static func _testSetRequestAccessOverride(
        _ value: (@Sendable () async throws -> Void)?
    ) {
        testRequestAccessOverride.value = value
    }

    nonisolated static func _testSetDefaultRequestAccessRunner(
        _ value: (@Sendable () async throws -> Void)?
    ) {
        testDefaultRequestAccessRunner.value = value
    }

    nonisolated static func _testSetStoreRequestAuthorizationRunner(
        _ value: (@Sendable (HKHealthStore, Set<HKObjectType>) async throws -> Void)?
    ) {
        testStoreRequestAuthorizationRunner.value = value
    }

    nonisolated static func _testSetDefaultStoreRequestAuthorizationRunner(
        _ value: (@Sendable (HKHealthStore, Set<HKObjectType>) async throws -> Void)?
    ) {
        testDefaultStoreRequestAuthorizationRunner.value = value
    }

    nonisolated static func _testSetAuthorizedTypeCountOverride(
        _ value: (@Sendable () -> Int)?
    ) {
        testAuthorizedTypeCountOverride.value = value
    }

    nonisolated static func _testSetEnableBackgroundOverride(
        _ value: (@Sendable () async -> Void)?
    ) {
        testEnableBackgroundOverride.value = value
    }

    nonisolated static func _testSetEnableBackgroundDeliveryRunner(
        _ value: (@Sendable ([HKSampleType]) async throws -> Void)?
    ) {
        testEnableBackgroundDeliveryRunner.value = value
    }

    nonisolated static func _testSetStoreEnableBackgroundDeliveryRunner(
        _ value: (@Sendable (HKHealthStore, HKSampleType, @escaping (Bool, Error?) -> Void) -> Void)?
    ) {
        testStoreEnableBackgroundDeliveryRunner.value = value
    }

    nonisolated static func _testSetDefaultStoreEnableBackgroundDeliveryRunner(
        _ value: (@Sendable (HKHealthStore, HKSampleType, @escaping (Bool, Error?) -> Void) -> Void)?
    ) {
        testDefaultStoreEnableBackgroundDeliveryRunner.value = value
    }

    nonisolated static func _testSetQuerySamplesOverride(
        _ value: (@Sendable (HKQuantityType, Date, Date, Int, Bool) async throws -> [HKQuantitySample])?
    ) {
        testQuerySamplesOverride.value = value
    }

    nonisolated static func _testSetQueryAnchoredSamplesOverride(
        _ value: (@Sendable (HKQuantityType, Date, Date, String) async throws -> [HKQuantitySample])?
    ) {
        testQueryAnchoredSamplesOverride.value = value
    }

    nonisolated static func _testSetSleepSamplesOverride(
        _ value: (@Sendable (Date, Date) async throws -> [HKCategorySample])?
    ) {
        testSleepSamplesOverride.value = value
    }

    nonisolated static func _testSetCumulativeSumOverride(
        _ value: (@Sendable (HKQuantityType, Date, HKUnit) async throws -> Double?)?
    ) {
        testCumulativeSumOverride.value = value
    }

    nonisolated static func _testSetDayBoundsDateByAddingRunner(
        _ value: (@Sendable (Calendar, Date) -> Date?)?
    ) {
        testDayBoundsDateByAddingRunner.value = value
    }

    nonisolated static func _testSetEightAMDateByAddingRunner(
        _ value: (@Sendable (Calendar, Date) -> Date?)?
    ) {
        testEightAMDateByAddingRunner.value = value
    }

    nonisolated static func _testSetAnchorUnarchiveRunner(
        _ value: (@Sendable (Data) throws -> HKQueryAnchor?)?
    ) {
        testAnchorUnarchiveRunner.value = value
    }

    nonisolated static func _testSetAnchorArchiveRunner(
        _ value: (@Sendable (HKQueryAnchor) throws -> Data)?
    ) {
        testAnchorArchiveRunner.value = value
    }

    nonisolated static func _testSetQuantitySampleSourceKeyOverride(
        _ value: (@Sendable (HKQuantitySample) -> String)?
    ) {
        testQuantitySampleSourceKeyOverride.value = value
    }

    nonisolated static func _testSetCategorySampleSourceKeyOverride(
        _ value: (@Sendable (HKCategorySample) -> String)?
    ) {
        testCategorySampleSourceKeyOverride.value = value
    }

    nonisolated static func _testLoadAnchor(anchorKey: String) -> HKQueryAnchor? {
        loadAnchor(anchorKey: anchorKey)
    }

    nonisolated static func _testSaveAnchor(_ anchor: HKQueryAnchor, anchorKey: String) {
        saveAnchor(anchor, anchorKey: anchorKey)
    }

    nonisolated static func _testResetOverrides() {
        testIsAvailableOverride.value = nil
        testRequestAccessOverride.value = nil
        testDefaultRequestAccessRunner.value = nil
        testStoreRequestAuthorizationRunner.value = nil
        testDefaultStoreRequestAuthorizationRunner.value = nil
        testAuthorizedTypeCountOverride.value = nil
        testEnableBackgroundOverride.value = nil
        testEnableBackgroundDeliveryRunner.value = nil
        testStoreEnableBackgroundDeliveryRunner.value = nil
        testDefaultStoreEnableBackgroundDeliveryRunner.value = nil
        testQuerySamplesOverride.value = nil
        testQueryAnchoredSamplesOverride.value = nil
        testSleepSamplesOverride.value = nil
        testCumulativeSumOverride.value = nil
        testDayBoundsDateByAddingRunner.value = nil
        testEightAMDateByAddingRunner.value = nil
        testAnchorUnarchiveRunner.value = nil
        testAnchorArchiveRunner.value = nil
        testQuantitySampleSourceKeyOverride.value = nil
        testCategorySampleSourceKeyOverride.value = nil
    }

    nonisolated static func _testSourceRank(
        bundleIdentifier: String,
        productType: String?,
        userEntered: Bool
    ) -> Int {
        sourceRank(
            bundleIdentifier: bundleIdentifier,
            productType: productType,
            metadata: userEntered ? [HKMetadataKeyWasUserEntered: true] : nil
        )
    }

    nonisolated static func _testIsWatch(bundleIdentifier: String, productType: String?) -> Bool {
        isWatchSource(bundleIdentifier: bundleIdentifier, productType: productType)
    }

    nonisolated static func _testIsIPhone(productType: String?) -> Bool {
        isIPhoneSource(productType: productType)
    }

    nonisolated static func _testShouldPreferSleepSource(
        lhsRank: Int,
        lhsHasStages: Bool,
        lhsDurationSeconds: TimeInterval,
        rhsRank: Int,
        rhsHasStages: Bool,
        rhsDurationSeconds: TimeInterval
    ) -> Bool {
        shouldPreferSleepSource(
            SleepSourceSelectionKey(
                rank: lhsRank,
                hasStages: lhsHasStages,
                durationSeconds: lhsDurationSeconds
            ),
            over: SleepSourceSelectionKey(
                rank: rhsRank,
                hasStages: rhsHasStages,
                durationSeconds: rhsDurationSeconds
            )
        )
    }

    nonisolated static func _testShouldPreferSleepBout(
        lhsAsleepMinutes: Double,
        lhsDistanceToEightAM: TimeInterval,
        lhsHasStages: Bool,
        rhsAsleepMinutes: Double,
        rhsDistanceToEightAM: TimeInterval,
        rhsHasStages: Bool
    ) -> Bool {
        shouldPreferSleepBout(
            SleepBoutSelectionKey(
                asleepMinutes: lhsAsleepMinutes,
                distanceToEightAM: lhsDistanceToEightAM,
                hasStages: lhsHasStages
            ),
            over: SleepBoutSelectionKey(
                asleepMinutes: rhsAsleepMinutes,
                distanceToEightAM: rhsDistanceToEightAM,
                hasStages: rhsHasStages
            )
        )
    }

    func _testResolveQuantitySamples(
        results: [HKSample]?,
        error: Error?
    ) throws -> [HKQuantitySample] {
        try Self.resolveQuantitySamples(results: results, error: error)
    }

    func _testResolveAnchoredQuantitySamples(
        samples: [HKSample]?,
        newAnchor: HKQueryAnchor?,
        error: Error?,
        anchorKey: String
    ) throws -> [HKQuantitySample] {
        try Self.resolveAnchoredQuantitySamples(
            samples: samples,
            newAnchor: newAnchor,
            error: error,
            anchorKey: anchorKey
        )
    }

    func _testResolveCumulativeSum(
        stats: HKStatistics?,
        error: Error?,
        unit: HKUnit
    ) throws -> Double? {
        try Self.resolveCumulativeSum(stats: stats, error: error, unit: unit)
    }

    func _testResolveCategorySamples(
        results: [HKSample]?,
        error: Error?
    ) throws -> [HKCategorySample] {
        try Self.resolveCategorySamples(results: results, error: error)
    }

    nonisolated static func _testDefaultEightAMDate(calendar: Calendar, dayStart: Date) -> Date {
        defaultEightAMDate(calendar: calendar, dayStart: dayStart)
    }

    nonisolated static func _testFallbackEightAMDate(dayStart: Date) -> Date {
        resolvedEightAMDate(dayStart: dayStart) { _ in nil }
    }

    nonisolated static func _testSleepBoutSelectionKey(
        for samples: [HKCategorySample],
        eightAM: Date,
        hasStages: @escaping ([HKCategorySample]) -> Bool,
        asleepMinutes: @escaping ([HKCategorySample]) -> Double
    ) -> (asleepMinutes: Double, distanceToEightAM: TimeInterval, hasStages: Bool) {
        let key = sleepBoutSelectionKey(
            for: samples,
            eightAM: eightAM,
            hasStages: hasStages,
            asleepMinutes: asleepMinutes
        )
        return (key.asleepMinutes, key.distanceToEightAM, key.hasStages)
    }

    nonisolated static func _testBackgroundDeliveryResult(success: Bool, error: Error?) -> Result<Bool, Error> {
        backgroundDeliveryResult(success: success, error: error)
    }

    func _testRequestReadAuthorization(
        store: HKHealthStore,
        readTypes: Set<HKObjectType>
    ) async throws {
        try await Self.requestReadAuthorization(store: store, readTypes: readTypes)
    }

    func _testEnableBackgroundDeliveryUsingStore(types: [HKSampleType], store: HKHealthStore) async throws { try await Self.enableBackgroundDelivery(for: types, store: store) }
}
#endif

// MARK: - Sleep Data

struct SleepData: Sendable {
    var totalHours: Double
    var deepMinutes: Int
    var remMinutes: Int
    var lightMinutes: Int
    var awakeMinutes: Int
    var efficiency: Double?         // 0-100
    var bedTime: Date?
    var wakeTime: Date?
    var hasStages: Bool = true

    /// Shared sleep algorithm; absent stages and efficiency are reweighted.
    var qualityScore: Double {
        SleepScorer.compositeScore(sleepLog: scoringLog, physiologicalState: nil, age: 30) ?? 0
    }

    var scoringLog: SleepLog {
        var log = SleepLog(userId: UUID(), date: "")
        log.totalDurationMinutes = Int((totalHours * 60).rounded())
        log.deepSleepMinutes = hasStages ? deepMinutes : nil
        log.remSleepMinutes = hasStages ? remMinutes : nil
        log.lightSleepMinutes = hasStages ? lightMinutes : nil
        log.awakeMinutes = hasStages ? awakeMinutes : nil
        log.sleepEfficiency = efficiency
        log.bedTime = bedTime
        log.wakeTime = wakeTime
        return log
    }

}

struct HealthKitImportedWorkout: Sendable, Equatable {
    let sourceId: String
    let startDate: Date
    let endDate: Date
    let sessionDate: String
    let workoutType: WorkoutType
    let estimatedCalories: Int?
    let durationMinutes: Int
    let startedTimezone: String?
    let startedUTCOffsetMinutes: Int?
    let trimpScore: Double?
    let inferredRPE: Int?
    let sourceRank: Int
}

private struct WorkoutEffortEstimate: Sendable, Equatable {
    let trimpScore: Double?
    let inferredRPE: Int?
}
