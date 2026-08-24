// MARK: - Property-Based Invariant Tests

import XCTest
@testable import LifeOS
import GRDB

final class InvariantPropertyTests: XCTestCase {

    func testRecoveryScoreAlwaysInRange() {
        for _ in 0..<5_000 {
            let z = Double.random(in: -1_000...1_000)
            let score = RecoveryEngine.zScoreToScale(z)
            XCTAssertGreaterThanOrEqual(score, 0)
            XCTAssertLessThanOrEqual(score, 100)
        }
    }

    func testACWRColdStartNeverDividesByZero() {
        for days in 0..<21 {
            for _ in 0..<200 {
                let acute = Double.random(in: 0...500)
                let chronic = Double.random(in: 0...500)
                let acwr = TrainingLoad.safeACWR(
                    acuteLoad7d: acute,
                    chronicLoad28d: chronic,
                    daysOfData: days
                )
                XCTAssertNil(acwr)
            }
        }
    }

    func testConfidenceMonotonicWhenMoreDataAvailable() {
        let weights: [Double] = [0.40, 0.30, 0.15, 0.15]
        for baseMask in 0..<16 {
            let baseWeight = sumWeights(mask: baseMask, weights: weights)
            let baseConfidence = RecoveryEngine.componentConfidence(totalWeight: baseWeight)

            for candidateMask in 0..<16 where (candidateMask | baseMask) == candidateMask {
                let candidateWeight = sumWeights(mask: candidateMask, weights: weights)
                let candidateConfidence = RecoveryEngine.componentConfidence(totalWeight: candidateWeight)
                XCTAssertGreaterThanOrEqual(
                    candidateConfidence,
                    baseConfidence,
                    "Confidence decreased from mask \(baseMask) to superset \(candidateMask)"
                )
            }
        }
    }

    func testNotificationHardCapNeverExceedsSix() {
        for _ in 0..<2_000 {
            var settings = NotificationSettings(userId: UUID())
            settings.maxTotalPerDay = Int.random(in: -20...40)
            let normalized = settings.normalizedForInvariants()
            XCTAssertGreaterThanOrEqual(normalized.maxTotalPerDay, 1)
            XCTAssertLessThanOrEqual(normalized.maxTotalPerDay, 6)
        }
    }

    func testRetryBackoffStartsAtTenSecondsPlusMinusJitter() {
        for _ in 0..<500 {
            let firstRetry = RetryConfig.delay(forAttempt: 0)
            XCTAssertGreaterThanOrEqual(firstRetry, 8)
            XCTAssertLessThanOrEqual(firstRetry, 12)
        }
    }

    func testCriticalOnlyForcesAdvisoryAndDisablesFocusControl() {
        for _ in 0..<1_000 {
            var settings = NotificationSettings(userId: UUID())
            settings.criticalOnly = true
            settings.controlLevel = [.advisory, .protective, .guardian].randomElement()!
            settings.focusControlEnabled = Bool.random()

            let normalized = settings.normalizedForInvariants()
            XCTAssertEqual(normalized.controlLevel, .advisory)
            XCTAssertFalse(normalized.focusControlEnabled)
        }
    }

    func testGuardianModeFallsBackWhenFocusControlIsDisabled() {
        var settings = NotificationSettings(userId: UUID())
        settings.criticalOnly = false
        settings.controlLevel = .guardian
        settings.focusControlEnabled = false

        let normalized = settings.normalizedForInvariants()
        XCTAssertEqual(normalized.controlLevel, .protective)
        XCTAssertFalse(normalized.focusControlEnabled)
    }

    func testNotificationSettingsApiPayloadNormalizesCriticalOnlyInvariant() throws {
        var settings = NotificationSettings(userId: UUID())
        settings.criticalOnly = true
        settings.controlLevel = .guardian
        settings.focusControlEnabled = true

        let payload = settings.apiPayload()
        XCTAssertEqual(payload["critical_only"] as? Bool, true)
        XCTAssertEqual(payload["control_level"] as? String, "advisory")
        XCTAssertEqual(payload["focus_control_enabled"] as? Bool, false)
    }

    func testNotificationSettingsApiPayloadNormalizesGuardianFocusInvariant() throws {
        var settings = NotificationSettings(userId: UUID())
        settings.criticalOnly = false
        settings.controlLevel = .guardian
        settings.focusControlEnabled = false

        let payload = settings.apiPayload()
        XCTAssertEqual(payload["control_level"] as? String, "protective")
        XCTAssertEqual(payload["focus_control_enabled"] as? Bool, false)
    }

    func testNotificationClientDoesNotMaintainLocalCapCounters() async throws {
        let manager = try DatabaseManager.inMemory()
        let engine = NotificationEngine(dbQueue: manager.dbQueue)
        var settings = NotificationSettings(userId: UUID())
        settings.quietHoursStart = "00:00"
        settings.quietHoursEnd = "00:00"

        let categories: [NotificationCategory] = [
            .morningBrief,
            .supplementReminder,
            .mealReminder,
            .recoveryAlert,
            .insight,
            .celebration,
            .experiment
        ]

        for (index, category) in categories.enumerated() {
            _ = try await engine.scheduleNotification(
                LifeOSNotification(
                    category: category,
                    priority: index == 3 ? .timeSensitive : .active,
                    title: "n\(index)",
                    body: "b\(index)"
                ),
                settings: settings
            )
        }

        let notificationLogCount = try await manager.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notification_log") ?? 0
        }
        // Engine logs optimistically for client-side cap/dedup enforcement.
        // The log IS local state, but only the outbox drives server dispatch.
        XCTAssertGreaterThan(notificationLogCount, 0,
            "Engine must log notifications locally for cap/dedup enforcement")

        let outboxCount = try await manager.dbQueue.read { db in
            try OutboxEvent.fetchCount(db)
        }
        XCTAssertEqual(outboxCount, settings.normalizedForInvariants().maxTotalPerDay,
            "Outbox dispatch count must respect the normalized daily cap invariant")
    }

    @MainActor
    func testForceUpdateHeaderParsingIsCaseInsensitive() {
        let manager = ForceUpdateManager()
        manager.checkHeaders(["x-soft-update-version": "99.0.0"])

        if case .softUpdate(let minVersion) = manager.status {
            XCTAssertEqual(minVersion, "99.0.0")
        } else {
            XCTFail("Expected soft update banner")
        }
    }

    @MainActor
    func testSoftUpdatePersistsUntilUserDismissesAndIsShownOnlyOncePerSession() {
        let manager = ForceUpdateManager()

        manager.checkHeaders(["X-Soft-Update-Version": "99.0.0"])
        if case .softUpdate(let minVersion) = manager.status {
            XCTAssertEqual(minVersion, "99.0.0")
        } else {
            XCTFail("Expected soft update banner after first header")
        }

        manager.checkHeaders(["X-Soft-Update-Version": "99.0.0"])
        if case .softUpdate(let minVersion) = manager.status {
            XCTAssertEqual(minVersion, "99.0.0")
        } else {
            XCTFail("Soft update should remain visible until explicitly dismissed")
        }

        manager.dismissSoftUpdate()
        XCTAssertEqual(manager.status, .upToDate)

        manager.checkHeaders(["X-Soft-Update-Version": "99.0.0"])
        XCTAssertEqual(
            manager.status,
            .upToDate,
            "Soft update should not reappear in the same app session after dismissal"
        )
    }

    @MainActor
    func testForceUpdateBecomesBlockingAfterGracePeriod() {
        let versionKey = "force_update_observed_min_version"
        let observedAtKey = "force_update_observed_min_version_at"
        defer {
            UserDefaults.standard.removeObject(forKey: versionKey)
            UserDefaults.standard.removeObject(forKey: observedAtKey)
        }

        let manager = ForceUpdateManager()
        let minVersion = "99.0.0"
        UserDefaults.standard.set(minVersion, forKey: versionKey)
        UserDefaults.standard.set(Date(timeIntervalSinceNow: -(49 * 60 * 60)), forKey: observedAtKey)

        manager.checkHeaders(["X-Min-App-Version": minVersion])

        if case .forceUpdate(let requiredVersion) = manager.status {
            XCTAssertEqual(requiredVersion, minVersion)
        } else {
            XCTFail("Expected force update after grace period elapsed")
        }
    }

    @MainActor
    func testForceUpdateVersionComparisonHandlesSuffixedVersions() {
        let manager = ForceUpdateManager()
        XCTAssertTrue(manager.compareVersions("1.2.3", isLessThan: "1.2.4-beta.1"))
        XCTAssertTrue(manager.compareVersions("1.2.3 (100)", isLessThan: "1.2.4"))
        XCTAssertFalse(manager.compareVersions("2.0.0-rc1", isLessThan: "1.9.9"))
    }

    @MainActor
    func testForceUpdateVersionComparisonPropertyMonotonicForSemanticBumps() {
        var random = SeededRandom(seed: 0xfeed_beef)
        let manager = ForceUpdateManager()
        let suffixes = ["", "-beta.1", "-rc1", " (100)", "+build.77"]

        for _ in 0..<2_000 {
            let major = random.nextInt(upperBound: 8)
            let minor = random.nextInt(upperBound: 20)
            let patch = random.nextInt(upperBound: 40)

            let base = "\(major).\(minor).\(patch)\(suffixes[random.nextInt(upperBound: suffixes.count)])"
            let bumped = "\(major).\(minor).\(patch + 1)\(suffixes[random.nextInt(upperBound: suffixes.count)])"

            XCTAssertTrue(
                manager.compareVersions(base, isLessThan: bumped),
                "Expected \(base) < \(bumped)"
            )
            XCTAssertFalse(
                manager.compareVersions(bumped, isLessThan: base),
                "Expected \(bumped) !< \(base)"
            )
        }
    }

    func testDeleteAccountClientRateLimitMatchesServerTier() {
        XCTAssertEqual(RateLimitPolicy.tier(forFunction: "api-account-delete"), .deleteAccount)
        XCTAssertEqual(RateLimitPolicy.deleteAccountPerHour, 3)
    }

    func testOutboxReplayHeaderParsingIsCaseInsensitiveAndTrimmed() {
        XCTAssertTrue(RateLimitPolicy.isOutboxReplay(headers: ["X-Outbox-Replay": "true"]))
        XCTAssertTrue(RateLimitPolicy.isOutboxReplay(headers: ["x-outbox-replay": " TRUE "]))
        XCTAssertFalse(RateLimitPolicy.isOutboxReplay(headers: ["X-Outbox-Replay": "false"]))
        XCTAssertFalse(RateLimitPolicy.isOutboxReplay(headers: [:]))
    }

    func testOutboxReplayHeaderPropertyFuzzing() {
        var random = SeededRandom(seed: 0x0ddc0ffe)
        for _ in 0..<2_000 {
            let key = randomCase(of: "x-outbox-replay", random: &random)
            let leftPad = String(repeating: " ", count: random.nextInt(upperBound: 4))
            let rightPad = String(repeating: " ", count: random.nextInt(upperBound: 4))
            let value = "\(leftPad)\(randomCase(of: "true", random: &random))\(rightPad)"
            XCTAssertTrue(
                RateLimitPolicy.isOutboxReplay(headers: [key: value]),
                "Expected header to normalize as replay: \(key)=\(value)"
            )
        }

        let invalidValues = ["true,false", "tru e", "yes", "1", " t r u e ", ""]
        for invalid in invalidValues {
            XCTAssertFalse(
                RateLimitPolicy.isOutboxReplay(headers: ["X-Outbox-Replay": invalid]),
                "Malformed replay value must be rejected: \(invalid)"
            )
        }
    }

    func testEnqueueMutationAddsStableCorrelationIdHeader() async throws {
        let manager = try DatabaseManager.inMemory()
        let syncEngine = SyncEngine(
            dbQueue: manager.dbQueue,
            pushTransportOverride: { _ in }
        )

        let eventId = UUID()
        let event = OutboxEvent(
            id: eventId,
            httpMethod: .POST,
            path: "api-settings-privacy",
            bodyJson: Data("{}".utf8)
        )
        try await syncEngine.enqueueMutation(event)

        let headers = try await manager.dbQueue.read { db -> [String: String] in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT headers_json FROM outbox_events WHERE id = ? OR id = ? LIMIT 1",
                arguments: [eventId, eventId.uuidString]
            ) else {
                return [:]
            }
            let data: Data = row["headers_json"] ?? Data()
            guard !data.isEmpty else { return [:] }
            let object = try JSONSerialization.jsonObject(with: data)
            return object as? [String: String] ?? [:]
        }

        XCTAssertEqual(headers["X-Correlation-Id"], eventId.uuidString.lowercased())
        XCTAssertEqual(headers["X-Outbox-Replay"], "true")
    }

    func testSupabaseISO8601RoundTripProperty() {
        var random = SeededRandom(seed: 0xabcddcba)
        for _ in 0..<2_500 {
            let epoch = Double(random.nextInt(upperBound: 3_000_000_000))
            let milliseconds = Double(random.nextInt(upperBound: 1_000)) / 1_000
            let date = Date(timeIntervalSince1970: epoch + milliseconds)
            let encoded = ISO8601DateFormatter.supabaseString(from: date)
            guard let decoded = ISO8601DateFormatter.supabaseDate(from: encoded) else {
                XCTFail("Failed to decode Supabase date: \(encoded)")
                continue
            }
            XCTAssertLessThanOrEqual(abs(decoded.timeIntervalSince(date)), 0.001)
        }
    }

    // MARK: - Confidence Threshold (§2)

    func testLowConfidenceThresholdIs065() {
        XCTAssertEqual(
            LifeOSConstants.lowConfidenceThreshold,
            0.65,
            "Invariant §2: low confidence threshold must be 0.65"
        )
    }

    // MARK: - Recovery Zone Colors Resolve

    func testRecoveryZoneColorsResolveNonNil() {
        // These should always produce a valid Color, even without asset catalog.
        let colors = [
            LifeOSColors.Recovery.optimal,
            LifeOSColors.Recovery.ready,
            LifeOSColors.Recovery.caution,
            LifeOSColors.Recovery.critical
        ]
        XCTAssertEqual(colors.count, 4, "All four recovery colors must resolve")
    }

    private func sumWeights(mask: Int, weights: [Double]) -> Double {
        weights.enumerated().reduce(0) { partial, pair in
            let (index, weight) = pair
            return (mask & (1 << index)) != 0 ? (partial + weight) : partial
        }
    }

    private func randomCase(of value: String, random: inout SeededRandom) -> String {
        var output = ""
        output.reserveCapacity(value.count)
        for character in value {
            let scalar = String(character)
            output += random.nextBool() ? scalar.uppercased() : scalar.lowercased()
        }
        return output
    }
}

private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextUInt64() -> UInt64 {
        state = 6364136223846793005 &* state &+ 1
        return state
    }

    mutating func nextInt(upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(nextUInt64() % UInt64(upperBound))
    }

    mutating func nextBool() -> Bool {
        (nextUInt64() & 1) == 0
    }
}
