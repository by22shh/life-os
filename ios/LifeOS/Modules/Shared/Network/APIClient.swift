// MARK: - API Client
// Source of truth: life_os_api_specification.md §3322+
// Typed PostgREST read layer for pulling server data.

import Foundation
import Supabase
import GRDB

protocol SyncAPIClient: Sendable {
    func fetchSyncPage<T: Decodable & Sendable>(
        from table: String,
        since: Date?,
        cursor: APIClient.SyncPageCursor?,
        limit: Int,
        activeWindowDays: Int?
    ) async throws -> [T]

    func upsertRow(
        table: String,
        bodyJson: Data,
        headers: [String: String]
    ) async throws

    func callEdgeFunction<T: Decodable & Sendable>(
        _ name: String,
        body: Data,
        headers: [String: String],
        maxAttempts: Int
    ) async throws -> T

    func callEdgeRoute<T: Decodable & Sendable>(
        function name: String,
        route: String,
        method: String,
        queryItems: [URLQueryItem],
        body: Data?,
        headers: [String: String],
        maxAttempts: Int
    ) async throws -> T

    func currentAuthUserId() async throws -> UUID

    func uploadStorageObject(
        bucket: String,
        path: String,
        fileURL: URL,
        contentType: String
    ) async throws

    func shouldBlockMutationsForForceUpdate() async -> Bool
}

/// Provides typed read access to Supabase PostgREST tables.
/// All queries go through RLS; the JWT token provides the `auth.uid()`.
actor APIClient: SyncAPIClient, PredictionAPIClient {

    struct SyncPageCursor: Sendable {
        let updatedAt: Date
        let rowId: String
    }

    private enum ComparisonOperator {
        case eq
        case gt
        case gte
    }

    private static let httpErrorDomain = "APIClientHTTPErrorDomain"
    private static let correlationIdHeader = "X-Correlation-Id"

    private let client: SupabaseClient
    private let deviceId: String
#if DEBUG
    private static let testDaysAgoDateByAddingRunner = LockedTestOverride<
        @Sendable (_ days: Int, _ now: Date) -> Date?
    >()
    private static let testExecuteDecodedQueryOverride = LockedTestOverride<
        @Sendable () -> (data: Data, response: HTTPURLResponse)
    >()
    private static let testPostgrestAccessTokenOverride = LockedTestOverride<String>()
    private static let testPostgrestDataForRequestOverride = LockedTestOverride<
        @Sendable (URLRequest) async throws -> (Data, URLResponse)
    >()
    private static let testEdgeInvokeOverride = LockedTestOverride<
        @Sendable (_ name: String, _ options: FunctionInvokeOptions) async throws -> (Data, HTTPURLResponse)
    >()
    private static let testEdgeRouteDataForRequestOverride = LockedTestOverride<
        @Sendable (URLRequest) async throws -> (Data, URLResponse)
    >()
#endif

    init(client: SupabaseClient = SupabaseConfig.client,
         deviceId: String? = nil) {
        self.client = client
        self.deviceId = deviceId ?? KeychainHelper.getOrCreateDeviceId()
    }

    // MARK: - Generic Fetch

    /// Fetch rows from a table, optionally filtering by `updated_at >= since`.
    /// Uses PostgREST via supabase-swift's `.from()` query builder.
    /// Implements Sync Window (§6.1.3): Granular tables only pull data from the last 90 days.
    /// Checks force-update headers on every response per §14.
    func fetch<T: Decodable & Sendable>(
        from table: String,
        since: Date? = nil,
        orderBy: String = "updated_at",
        ascending: Bool = true,
        limit: Int? = nil,
        offset: Int = 0,
        activeWindowDays: Int? = nil,
        exactMatch: [String: String]? = nil
    ) async throws -> [T] {
        try Self.requireRuntimeConfiguration()

        let query = client
            .from(table)
            .select()

        if let exactMatch {
            for (key, value) in exactMatch {
                _ = query.eq(key, value: value)
            }
        }

        if let since {
            let iso = ISO8601DateFormatter.supabaseString(from: since)
            _ = query.gte("updated_at", value: iso)
        }

        // Sync Window (§6.1.3) — limit historical depth for massive granular logs
        if let days = activeWindowDays, days > 0 {
            let cutoff = daysAgo(days)
            let dateColumnSpec = dateColumnSpecFor(table: table)
            let cutoffStr = cutoffString(for: cutoff, kind: dateColumnSpec.valueKind)
            _ = query.gte(dateColumnSpec.column, value: cutoffStr)
        }

        _ = query.order(orderBy, ascending: ascending)

        if let limit {
            _ = query.range(from: offset, to: offset + max(0, limit - 1))
        }

        return try await executeQueryAndCheck(query, as: [T].self)
    }

    /// Fetch a deterministic sync page ordered by `(updated_at ASC, id ASC)` using keyset pagination.
    /// Avoids offset drift when rows are updated during a pull cycle.
    func fetchSyncPage<T: Decodable & Sendable>(
        from table: String,
        since: Date?,
        cursor: SyncPageCursor?,
        limit: Int,
        activeWindowDays: Int? = nil
    ) async throws -> [T] {
        try Self.requireRuntimeConfiguration()

        return try await Self.fetchSyncPageImpl(
            since: since,
            cursor: cursor,
            limit: limit
        ) { updatedAtFilter, idGreaterThan, orderByUpdatedAt, queryLimit in
            try await self.executeSyncQuery(
                from: table,
                updatedAtFilter: updatedAtFilter,
                idGreaterThan: idGreaterThan,
                orderByUpdatedAt: orderByUpdatedAt,
                limit: queryLimit,
                activeWindowDays: activeWindowDays
            )
        }
    }

    private static func fetchSyncPageImpl<T: Decodable & Sendable>(
        since: Date?,
        cursor: SyncPageCursor?,
        limit: Int,
        executeQuery: @Sendable (
            _ updatedAtFilter: (ComparisonOperator, Date)?,
            _ idGreaterThan: String?,
            _ orderByUpdatedAt: Bool,
            _ queryLimit: Int
        ) async throws -> [T]
    ) async throws -> [T] {
        let safeLimit = max(1, limit)

        if let cursor {
            let sameTimestampRows = try await executeQuery(
                (.eq, cursor.updatedAt),
                cursor.rowId,
                false,
                safeLimit
            )

            if sameTimestampRows.count >= safeLimit {
                return sameTimestampRows
            }

            let remaining = safeLimit - sameTimestampRows.count
            let newerRows = try await executeQuery(
                (.gt, cursor.updatedAt),
                nil,
                true,
                remaining
            )
            return sameTimestampRows + newerRows
        }

        return try await executeQuery(
            since.map { (.gte, $0) },
            nil,
            true,
            safeLimit
        )
    }

    private func dateColumnSpecFor(table: String) -> SyncTableRegistry.DateColumnSpec {
        SyncTableRegistry.dateColumnSpec(forTableName: table)
    }

    private func cutoffString(for date: Date, kind: SyncTableRegistry.DateValueKind) -> String {
        switch kind {
        case .timestamp:
            return ISO8601DateFormatter.supabaseString(from: date)
        case .dateOnly:
            // For SQL DATE columns, always emit POSIX/Gregorian yyyy-MM-dd.
            return Self.utcDateOnlyString(date)
        }
    }

    private func daysAgo(_ days: Int, from now: Date = Date()) -> Date {
        guard days > 0 else { return now }
        let computedDate: Date?
#if DEBUG
        if let runner = Self.testDaysAgoDateByAddingRunner.value {
            computedDate = runner(days, now)
        } else {
            computedDate = Self.utcGregorianCalendar.date(byAdding: .day, value: -days, to: now)
        }
#else
        computedDate = Self.utcGregorianCalendar.date(byAdding: .day, value: -days, to: now)
#endif
        if let computedDate {
            return computedDate
        }
        return now.addingTimeInterval(-Double(days) * 86_400)
    }

    private func executeQueryAndCheck<T: Decodable>(
        _ query: PostgrestBuilder,
        as _: T.Type = T.self
    ) async throws -> T {
        let result: PostgrestResponse<T> = try await executeDecodedQuery(query, as: T.self)
        await checkForceUpdateHeaders(from: result.response)
        return result.value
    }

    private func executeArrayQueryAndCheck<T: Decodable>(
        _ query: PostgrestBuilder,
        as _: T.Type = T.self
    ) async throws -> [T] {
        try await executeQueryAndCheck(query, as: [T].self)
    }

    private func executeFirstRowQueryAndCheck<T: Decodable>(
        _ query: PostgrestBuilder,
        as _: T.Type = T.self
    ) async throws -> T? {
        try await executeArrayQueryAndCheck(query, as: T.self).first
    }

    // MARK: - Recovery

    /// Fetch the latest physiological state for the current user.
    func fetchLatestRecovery() async throws -> PhysiologicalState? {
        let query = client
            .from("physiological_states")
            .select()
            .order("date", ascending: false)
            .limit(1)
        return try await executeFirstRowQueryAndCheck(query, as: PhysiologicalState.self)
    }

    /// Fetch recovery trend for the last N days.
    func fetchRecoveryTrend(days: Int) async throws -> [PhysiologicalState] {
        let cutoff = daysAgo(days)
        // Use "date" column (DATE type) with locale-stable yyyy-MM-dd format.
        let cutoffStr = Self.utcDateOnlyString(cutoff)

        let query = client
            .from("physiological_states")
            .select()
            .gte("date", value: cutoffStr)
            .order("date", ascending: false)
        return try await executeArrayQueryAndCheck(query, as: PhysiologicalState.self)
    }

    // MARK: - User Profile

    /// Fetch the current user's profile.
    func fetchUserProfile() async throws -> User? {
        let query = client
            .from("users")
            .select()
            .limit(1)
        return try await executeFirstRowQueryAndCheck(query, as: User.self)
    }

    // MARK: - Nutrition

    /// Fetch food logs since a given date or within the active 90-day Sync Window.
    func fetchFoodLogs(since: Date? = nil) async throws -> [FoodLog] {
        try await fetch(from: "food_logs", since: since)
    }

    /// Fetch food items for a specific food log.
    func fetchFoodItems(forLogId logId: UUID) async throws -> [FoodItem] {
        let query = client
            .from("food_items")
            .select()
            .eq("food_log_id", value: logId.uuidString)
        return try await executeArrayQueryAndCheck(query, as: FoodItem.self)
    }

    /// Fetch daily nutrition targets since a date.
    func fetchNutritionTargets(since: Date? = nil) async throws -> [DailyNutritionTarget] {
        try await fetch(from: "daily_nutrition_targets", since: since)
    }

    // MARK: - Training

    /// Fetch workout sessions since a date.
    func fetchWorkoutSessions(since: Date? = nil) async throws -> [WorkoutSession] {
        try await fetch(from: "workout_sessions", since: since)
    }

    /// Fetch training load data since a date.
    func fetchTrainingLoads(since: Date? = nil) async throws -> [TrainingLoad] {
        try await fetch(from: "training_loads", since: since)
    }

    // MARK: - Supplements

    /// Fetch user supplements.
    func fetchUserSupplements() async throws -> [UserSupplement] {
        try await fetch(from: "user_supplements")
    }

    /// Fetch supplement logs since a date.
    func fetchSupplementLogs(since: Date? = nil) async throws -> [SupplementLog] {
        try await fetch(from: "supplement_logs", since: since)
    }

    // MARK: - Health & Wellness

    /// Fetch wellness checks since a date.
    func fetchWellnessChecks(since: Date? = nil) async throws -> [WellnessCheck] {
        try await fetch(from: "wellness_checks", since: since)
    }

    /// Fetch body composition records.
    func fetchBodyComposition(since: Date? = nil) async throws -> [BodyComposition] {
        try await fetch(from: "body_composition", since: since)
    }

    /// Fetch hydration logs since a date.
    func fetchHydrationLogs(since: Date? = nil) async throws -> [HydrationLog] {
        try await fetch(from: "hydration_logs", since: since)
    }

    // MARK: - Insights (Pull-Only)

    /// Fetch AI-generated insights.
    func fetchInsights(since: Date? = nil) async throws -> [Insight] {
        try await fetch(from: "insights", since: since)
    }

    // MARK: - Notification Settings

    /// Fetch notification settings.
    func fetchNotificationSettings() async throws -> NotificationSettings? {
        let query = client
            .from("notification_settings")
            .select()
            .limit(1)
        return try await executeFirstRowQueryAndCheck(query, as: NotificationSettings.self)
    }

    // MARK: - Onboarding

    /// Fetch onboarding state.
    func fetchOnboardingState() async throws -> OnboardingState? {
        let query = client
            .from("onboarding_state")
            .select()
            .limit(1)
        return try await executeFirstRowQueryAndCheck(query, as: OnboardingState.self)
    }

    /// Fetch user baselines.
    func fetchUserBaseline() async throws -> UserBaseline? {
        let query = client
            .from("user_baselines")
            .select()
            .limit(1)
        return try await executeFirstRowQueryAndCheck(query, as: UserBaseline.self)
    }

    // MARK: - Generic Mutations

    /// Upsert a row directly via PostgREST. Used for tables lacking explicit Edge Functions.
    func upsertRow(
        table: String,
        bodyJson: Data,
        headers: [String: String] = [:]
    ) async throws {
        try Self.requireRuntimeConfiguration()

        var attempt = 0
        var currentError: Error?
        let maxAttempts = 3
        
        // Ensure idempotency header is passed up natively if possible
        while attempt < maxAttempts {
            do {
                try await performRawPostgrestUpsert(
                    table: table,
                    payload: bodyJson,
                    headers: headers
                )
                return
            } catch {
                currentError = error
                attempt += 1

                if !isRetryable(error: error) {
                    throw error
                }
                if attempt >= maxAttempts {
                    break
                }

                let delaySeconds = RetryConfig.delay(forAttempt: attempt - 1)
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
        }
        throw APIClientError.retryLimitReached(underlying: currentError)
    }

    private nonisolated static func resolveSafeTableName(
        _ table: String,
        encodedTable: String?
    ) -> String {
        if let encodedTable {
            return encodedTable
        }
        return table
    }

    private func performRawPostgrestUpsert(
        table: String,
        payload: Data,
        headers: [String: String]
    ) async throws {
        guard !payload.isEmpty else {
            throw NSError(
                domain: "APIClient",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Empty JSON payload for PostgREST upsert"]
            )
        }

        guard (try? JSONSerialization.jsonObject(with: payload)) != nil else {
            throw NSError(
                domain: "APIClient",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Invalid JSON payload for PostgREST upsert"]
            )
        }

        let safeTable = Self.resolveSafeTableName(
            table,
            encodedTable: table.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        )
        let url = SupabaseConfig.url.appendingPathComponent("rest/v1/\(safeTable)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")

        let accessToken: String
#if DEBUG
        if let overrideToken = Self.testPostgrestAccessTokenOverride.value {
            accessToken = overrideToken
        } else if Self.testEdgeRouteDataForRequestOverride.value != nil {
            accessToken = "test-edge-route-token"
        } else {
            let session = try await client.auth.session
            accessToken = session.accessToken
        }
#else
        let session = try await client.auth.session
        accessToken = session.accessToken
#endif
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        var mergedHeaders = headers
        if mergedHeaders[Self.correlationIdHeader] == nil {
            mergedHeaders[Self.correlationIdHeader] = UUID().uuidString
        }
        for (key, value) in mergedHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let data: Data
        let response: URLResponse
#if DEBUG
        if let runner = Self.testPostgrestDataForRequestOverride.value {
            (data, response) = try await runner(request)
        } else {
            (data, response) = try await URLSession.shared.data(for: request)
        }
#else
        (data, response) = try await URLSession.shared.data(for: request)
#endif
        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: "APIClient",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        await checkForceUpdateHeaders(from: http)

        // Detect expired/invalid auth tokens — notify AuthManager to re-validate session.
        if http.statusCode == 401 {
            await MainActor.run {
                NotificationCenter.default.post(name: .apiClientReceivedUnauthorized, object: nil)
            }
        }

        guard (200...299).contains(http.statusCode) else {
            let bodyText: String
            if let decodedText = String(data: data, encoding: .utf8) {
                bodyText = decodedText
            } else {
                bodyText = "HTTP \(http.statusCode)"
            }
            var userInfo: [String: Any] = [
                NSLocalizedDescriptionKey: bodyText,
                "status": http.statusCode
            ]
            if let retryAfter = http.value(forHTTPHeaderField: "Retry-After"),
               let seconds = TimeInterval(retryAfter) {
                userInfo["retry_after_seconds"] = seconds
            }
            throw NSError(domain: Self.httpErrorDomain, code: http.statusCode, userInfo: userInfo)
        }
    }

    // MARK: - Edge Functions

    /// Call an Edge Function with JSON body.
    /// Enforces client-side rate limits per life_os_invariants.md §11 before sending.
    func callEdgeFunction<T: Decodable & Sendable>(
        _ name: String,
        body: Data = Data("{}".utf8),
        headers: [String: String] = [:],
        maxAttempts: Int = 3
    ) async throws -> T {
        try Self.requireRuntimeConfiguration()

        // §11: Client-side rate limit enforcement (sliding window).
        // Outbox replay swaps the interactive budget for the shared replay
        // window only for exemptible tiers; cost-sensitive tiers always
        // enforce their own limits, mirroring the server-side policy.
        if RateLimitPolicy.isReplayExemptible(headers: headers, function: name) {
            let replayAllowed = await RateLimitTracker.shared.checkAndRecord(
                key: "outbox_replay_per5min",
                limit: RateLimitPolicy.outboxReplayPerFiveMinutes,
                windowSeconds: 300
            )
            guard replayAllowed else {
                throw APIClientError.rateLimited(function: name)
            }
        } else {
            let allowed = await RateLimitTracker.shared.checkAllLimits(forFunction: name)
            guard allowed else {
                throw APIClientError.rateLimited(function: name)
            }
        }

        var mergedHeaders = headers
        if mergedHeaders["X-Device-Id"] == nil {
            mergedHeaders["X-Device-Id"] = deviceId
        }
        if mergedHeaders["Idempotency-Key"] == nil {
            mergedHeaders["Idempotency-Key"] = UUID().uuidString
        }
        if mergedHeaders[Self.correlationIdHeader] == nil {
            mergedHeaders[Self.correlationIdHeader] = UUID().uuidString
        }

        var attempt = 0
        var currentError: Error?

        while attempt < maxAttempts {
            do {
                let payloadData = body.isEmpty ? Data("{}".utf8) : body
                guard let payloadString = String(data: payloadData, encoding: .utf8) else {
                    throw NSError(
                        domain: "APIClient",
                        code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to encode Edge Function payload."]
                    )
                }
                if mergedHeaders["Content-Type"] == nil {
                    mergedHeaders["Content-Type"] = "application/json"
                }

                let options = FunctionInvokeOptions(headers: mergedHeaders, body: payloadString)
                let data: Data
                let httpResponse: HTTPURLResponse
#if DEBUG
                if let override = Self.testEdgeInvokeOverride.value {
                    (data, httpResponse) = try await override(name, options)
                } else {
                    (data, httpResponse) = try await client.functions.invoke(
                        name,
                        options: options,
                        decode: Self.passthroughFunctionInvokeResult
                    )
                }
#else
                (data, httpResponse) = try await client.functions.invoke(
                    name,
                    options: options,
                    decode: Self.passthroughFunctionInvokeResult
                )
#endif
                await Self.applyForceUpdateHeaders(httpResponse.allHeaderFields)

                let decodePayload = data.isEmpty ? Data("{}".utf8) : data
                let decoded: T = try JSONDecoder().decode(T.self, from: decodePayload)
                return decoded
            } catch {
                currentError = error
                attempt += 1

                if !isRetryable(error: error) {
                    throw error
                }
                if attempt >= maxAttempts {
                    break
                }

                let delaySeconds = RetryConfig.delay(forAttempt: attempt - 1)
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
        }

        throw APIClientError.retryLimitReached(underlying: currentError)
    }

    /// Call a specific HTTP route exposed by an Edge Function.
    /// Used for router-style functions such as `/functions/v1/api-foods/search`.
    func callEdgeRoute<T: Decodable & Sendable>(
        function name: String,
        route: String = "",
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        headers: [String: String] = [:],
        maxAttempts: Int = 3
    ) async throws -> T {
        try Self.requireRuntimeConfiguration()

        if RateLimitPolicy.isReplayExemptible(headers: headers, function: name) {
            let replayAllowed = await RateLimitTracker.shared.checkAndRecord(
                key: "outbox_replay_per5min",
                limit: RateLimitPolicy.outboxReplayPerFiveMinutes,
                windowSeconds: 300
            )
            guard replayAllowed else {
                throw APIClientError.rateLimited(function: name)
            }
        } else {
            let allowed = await RateLimitTracker.shared.checkAllLimits(forFunction: name)
            guard allowed else {
                throw APIClientError.rateLimited(function: name)
            }
        }

        var mergedHeaders = headers
        if mergedHeaders["X-Device-Id"] == nil {
            mergedHeaders["X-Device-Id"] = deviceId
        }
        if mergedHeaders["Idempotency-Key"] == nil {
            mergedHeaders["Idempotency-Key"] = UUID().uuidString
        }
        if mergedHeaders[Self.correlationIdHeader] == nil {
            mergedHeaders[Self.correlationIdHeader] = UUID().uuidString
        }

        var attempt = 0
        var currentError: Error?

        while attempt < maxAttempts {
            do {
                let request = try await buildEdgeRouteRequest(
                    function: name,
                    route: route,
                    method: method,
                    queryItems: queryItems,
                    body: body,
                    headers: mergedHeaders
                )

                let data: Data
                let response: URLResponse
#if DEBUG
                if let override = Self.testEdgeRouteDataForRequestOverride.value {
                    (data, response) = try await override(request)
                } else {
                    (data, response) = try await URLSession.shared.data(for: request)
                }
#else
                (data, response) = try await URLSession.shared.data(for: request)
#endif

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NSError(
                        domain: "APIClient",
                        code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
                    )
                }

                await checkForceUpdateHeaders(from: httpResponse)

                guard (200...299).contains(httpResponse.statusCode) else {
                    throw Self.makeHTTPStatusError(data: data, response: httpResponse)
                }

                let decodePayload = data.isEmpty ? Data("{}".utf8) : data
                return try decodeSupabasePayload(decodePayload, as: T.self)
            } catch {
                currentError = error
                attempt += 1

                if !isRetryable(error: error) {
                    throw error
                }
                if attempt >= maxAttempts {
                    break
                }

                let delaySeconds = RetryConfig.delay(forAttempt: attempt - 1)
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
        }

        throw APIClientError.retryLimitReached(underlying: currentError)
    }

    func currentAuthUserId() async throws -> UUID {
        try Self.requireRuntimeConfiguration()

        let authId: UUID
#if DEBUG
        if let overrideToken = Self.testPostgrestAccessTokenOverride.value {
            _ = overrideToken
            let session = try await client.auth.session
            authId = session.user.id
        } else {
            let session = try await client.auth.session
            authId = session.user.id
        }
#else
        let session = try await client.auth.session
        authId = session.user.id
#endif

        return authId
    }

    func uploadStorageObject(
        bucket: String,
        path: String,
        fileURL: URL,
        contentType: String
    ) async throws {
        try Self.requireRuntimeConfiguration()

        _ = try await client.storage
            .from(bucket)
            .upload(
                path,
                fileURL: fileURL,
                options: FileOptions(
                    cacheControl: "3600",
                    contentType: contentType,
                    upsert: true
                )
            )
    }

    func downloadAuthenticatedFile(from url: URL) async throws -> PrivacyDownloadedExportArchive {
        try Self.requireRuntimeConfiguration()

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString, forHTTPHeaderField: Self.correlationIdHeader)

        let accessToken: String
#if DEBUG
        if let overrideToken = Self.testPostgrestAccessTokenOverride.value {
            accessToken = overrideToken
        } else if Self.testEdgeRouteDataForRequestOverride.value != nil {
            accessToken = "test-edge-route-token"
        } else {
            let session = try await client.auth.session
            accessToken = session.accessToken
        }
#else
        let session = try await client.auth.session
        accessToken = session.accessToken
#endif
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
#if DEBUG
        if let override = Self.testEdgeRouteDataForRequestOverride.value {
            (data, response) = try await override(request)
        } else {
            (data, response) = try await URLSession.shared.data(for: request)
        }
#else
        (data, response) = try await URLSession.shared.data(for: request)
#endif

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "APIClient",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        await checkForceUpdateHeaders(from: httpResponse)

        if httpResponse.statusCode == 401 {
            await MainActor.run {
                NotificationCenter.default.post(name: .apiClientReceivedUnauthorized, object: nil)
            }
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw Self.makeHTTPStatusError(data: data, response: httpResponse)
        }

        return PrivacyDownloadedExportArchive(
            data: data,
            suggestedFilename: Self.suggestedFilename(
                from: httpResponse,
                fallbackURL: url
            ),
            contentType: httpResponse.value(forHTTPHeaderField: "Content-Type")
        )
    }

    func createSignedLabScanAssetURL(path: String) async throws -> URL {
        try Self.requireRuntimeConfiguration()

        return try await client.storage
            .from(LabScanCloudStorage.bucketName)
            .createSignedURL(
                path: path,
                expiresIn: LabScanCloudStorage.signedURLLifetimeSeconds,
                download: true
            )
    }

    private func isRetryable(error: Error) -> Bool {
        let nsError = error as NSError

        if let status = nsError.userInfo["status"] as? Int {
            return status == 429 || status >= 500
        }

        if nsError.domain != NSURLErrorDomain, (400...599).contains(nsError.code) {
            return nsError.code == 429 || nsError.code >= 500
        }

        if nsError.domain == NSURLErrorDomain {
            let urlErrorCode = URLError.Code(rawValue: nsError.code)
            switch urlErrorCode {
            case .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .dnsLookupFailed,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .internationalRoamingOff,
                 .callIsActive,
                 .dataNotAllowed,
                 .cannotLoadFromNetwork,
                 .resourceUnavailable,
                 .backgroundSessionWasDisconnected:
                return true
            default:
                return false
            }
        }

        return false
    }

    func shouldBlockMutationsForForceUpdate() async -> Bool {
        await MainActor.run {
            if case .forceUpdate = ForceUpdateManager.shared.status {
                return true
            }
            return false
        }
    }

    private func checkForceUpdateHeaders(from response: URLResponse?) async {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        await Self.applyForceUpdateHeaders(httpResponse.allHeaderFields)
    }

    @MainActor
    private static func applyForceUpdateHeaders(_ headers: [AnyHashable: Any]) {
        ForceUpdateManager.shared.checkHeaders(headers)
    }

    private func executeDecodedQuery<T: Decodable>(
        _ query: PostgrestBuilder,
        as _: T.Type = T.self
    ) async throws -> PostgrestResponse<T> {
        #if DEBUG
        if let override = Self.testExecuteDecodedQueryOverride.value {
            let result = override()
            return try makeDecodedPostgrestResponse(data: result.data, response: result.response, as: T.self)
        }
        #endif
        return try await executeDecodedQuery(as: T.self) {
            return try await query.execute()
        }
    }

    private func executeDecodedQuery<T: Decodable>(
        as _: T.Type = T.self,
        executeRaw: () async throws -> PostgrestResponse<Void>
    ) async throws -> PostgrestResponse<T> {
        let rawResponse = try await executeRaw()
        return try makeDecodedPostgrestResponse(
            data: rawResponse.data,
            response: rawResponse.response,
            as: T.self
        )
    }

    private func makeDecodedPostgrestResponse<T: Decodable>(
        data: Data,
        response: HTTPURLResponse,
        as _: T.Type = T.self
    ) throws -> PostgrestResponse<T> {
        let decodedValue = try decodeSupabasePayload(data, as: T.self)
        return PostgrestResponse(
            data: data,
            response: response,
            value: decodedValue
        )
    }

    nonisolated private static func passthroughFunctionInvokeResult(
        data: Data,
        response: HTTPURLResponse
    ) throws -> (Data, HTTPURLResponse) {
        (data, response)
    }

    nonisolated private static func suggestedFilename(
        from response: HTTPURLResponse,
        fallbackURL: URL
    ) -> String {
        if let contentDisposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           let parsedFilename = parsedFilename(fromContentDisposition: contentDisposition) {
            return parsedFilename
        }

        let fallbackName = fallbackURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallbackName.isEmpty ? "lifeos-export" : fallbackName
    }

    nonisolated private static func parsedFilename(fromContentDisposition contentDisposition: String) -> String? {
        let parts = contentDisposition
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        for part in parts {
            if part.lowercased().hasPrefix("filename*=") {
                let rawValue = String(part.dropFirst("filename*=".count))
                let trimmed = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if let encodedValue = trimmed.split(separator: "'", maxSplits: 2).last,
                   let decoded = String(encodedValue).removingPercentEncoding,
                   !decoded.isEmpty {
                    return decoded
                }
            }
        }

        for part in parts {
            if part.lowercased().hasPrefix("filename=") {
                let rawValue = String(part.dropFirst("filename=".count))
                let trimmed = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        return nil
    }

    private func decodeSupabasePayload<T: Decodable>(_ data: Data, as _: T.Type = T.self) throws -> T {
        do {
            return try Self.makeSupabaseDecoder(convertFromSnakeCase: false).decode(T.self, from: data)
        } catch {
            return try Self.makeSupabaseDecoder(convertFromSnakeCase: true).decode(T.self, from: data)
        }
    }

    private func buildEdgeRouteRequest(
        function name: String,
        route: String,
        method: String,
        queryItems: [URLQueryItem],
        body: Data?,
        headers: [String: String]
    ) async throws -> URLRequest {
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        var url = SupabaseConfig.url.appendingPathComponent("functions/v1/\(encodedName)")

        for pathComponent in route.split(separator: "/").map(String.init) where !pathComponent.isEmpty {
            url.appendPathComponent(pathComponent)
        }

        if !queryItems.isEmpty,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = queryItems
            if let resolvedURL = components.url {
                url = resolvedURL
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let accessToken: String
#if DEBUG
        if let overrideToken = Self.testPostgrestAccessTokenOverride.value {
            accessToken = overrideToken
        } else if Self.testEdgeRouteDataForRequestOverride.value != nil {
            accessToken = "test-edge-route-token"
        } else {
            let session = try await client.auth.session
            accessToken = session.accessToken
        }
#else
        let session = try await client.auth.session
        accessToken = session.accessToken
#endif
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        if let body {
            request.httpBody = body
        }

        var mergedHeaders = headers
        if body != nil, mergedHeaders["Content-Type"] == nil {
            mergedHeaders["Content-Type"] = "application/json"
        }
        for (key, value) in mergedHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        return request
    }

    nonisolated private static func makeSupabaseDecoder(convertFromSnakeCase: Bool) -> JSONDecoder {
        let decoder = JSONDecoder()
        if convertFromSnakeCase {
            decoder.keyDecodingStrategy = .convertFromSnakeCase
        }
        decoder.dateDecodingStrategy = .custom { nestedDecoder in
            let container = try nestedDecoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            if let parsed = parseSupabaseDate(rawValue) {
                return parsed
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid Supabase date: \(rawValue)"
            )
        }
        decoder.dataDecodingStrategy = .custom { nestedDecoder in
            let container = try nestedDecoder.singleValueContainer()
            if let stringValue = try? container.decode(String.self) {
                if let base64Decoded = Data(base64Encoded: stringValue) {
                    return base64Decoded
                }
                return Data(stringValue.utf8)
            }
            let jsonValue = try container.decode(LossyJSONValue.self)
            return try JSONSerialization.data(
                withJSONObject: jsonValue.foundationValue,
                options: [.fragmentsAllowed]
            )
        }
        return decoder
    }

    nonisolated private static func parseSupabaseDate(_ rawValue: String) -> Date? {
        let parsedDate = withFormatterLock { () -> Date? in
            if let date = ISO8601DateFormatter.supabaseDate(from: rawValue) {
                return date
            }
            if let date = iso8601NoFractionalFormatter.date(from: rawValue) {
                return date
            }
            if let date = dateOnlyFormatter.date(from: rawValue) {
                return date
            }
            return nil
        }
        if let parsedDate {
            return parsedDate
        }
        if let timestamp = TimeInterval(rawValue) {
            return Date(timeIntervalSince1970: timestamp)
        }
        return nil
    }

    nonisolated private static func utcDateOnlyString(_ date: Date) -> String {
        withFormatterLock {
            Self.dateOnlyFormatter.string(from: date)
        }
    }

    private func executeSyncQuery<T: Decodable & Sendable>(
        from table: String,
        updatedAtFilter: (ComparisonOperator, Date)?,
        idGreaterThan: String?,
        orderByUpdatedAt: Bool,
        limit: Int,
        activeWindowDays: Int?
    ) async throws -> [T] {
        let query = client
            .from(table)
            .select()

        if let updatedAtFilter {
            let iso = ISO8601DateFormatter.supabaseString(from: updatedAtFilter.1)
            switch updatedAtFilter.0 {
            case .eq:
                _ = query.eq("updated_at", value: iso)
            case .gt:
                _ = query.gt("updated_at", value: iso)
            case .gte:
                _ = query.gte("updated_at", value: iso)
            }
        }

        if let idGreaterThan, !idGreaterThan.isEmpty {
            _ = query.gt("id", value: idGreaterThan)
        }

        if let days = activeWindowDays, days > 0 {
            let cutoff = daysAgo(days)
            let dateColumnSpec = dateColumnSpecFor(table: table)
            let cutoffStr = cutoffString(for: cutoff, kind: dateColumnSpec.valueKind)
            _ = query.gte(dateColumnSpec.column, value: cutoffStr)
        }

        if orderByUpdatedAt {
            _ = query.order("updated_at", ascending: true)
        }
        _ = query.order("id", ascending: true)
        _ = query.range(from: 0, to: max(0, limit - 1))

        return try await executeQueryAndCheck(query, as: [T].self)
    }
}

enum APIClientError: LocalizedError {
    case runtimeNotConfigured
    case retryLimitReached(underlying: Error?)
    case rateLimited(function: String)

    var errorDescription: String? {
        switch self {
        case .runtimeNotConfigured:
            return "Supabase runtime is not configured."
        case .retryLimitReached(let underlying):
            return underlying?.localizedDescription ?? String(localized: "error.sync.max_retries")
        case .rateLimited(let function):
            return String(localized: "error.sync.rate_limited") + " (\(function))"
        }
    }
}

// MARK: - ISO 8601 Formatter (Supabase-compatible)

extension ISO8601DateFormatter {
    /// Supabase uses ISO 8601 with fractional seconds.
    // Formatter instances are guarded by locks in the helpers below.
    private static nonisolated(unsafe) let supabaseFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let supabaseLock = NSLock()
    private static nonisolated(unsafe) let noFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private static let noFractionalLock = NSLock()

    nonisolated static func supabaseString(from date: Date) -> String {
        supabaseLock.lock()
        defer { supabaseLock.unlock() }
        return supabaseFormatter.string(from: date)
    }

    nonisolated static func supabaseDate(from rawValue: String) -> Date? {
        supabaseLock.lock()
        defer { supabaseLock.unlock() }
        return supabaseFormatter.date(from: rawValue)
    }

    nonisolated static func noFractionalDate(from rawValue: String) -> Date? {
        noFractionalLock.lock()
        defer { noFractionalLock.unlock() }
        return noFractionalFormatter.date(from: rawValue)
    }
}

private enum LossyJSONValue: Decodable {
    case object([String: LossyJSONValue])
    case array([LossyJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let object = try? container.decode([String: LossyJSONValue].self) {
            self = .object(object)
            return
        }
        if let array = try? container.decode([LossyJSONValue].self) {
            self = .array(array)
            return
        }
        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }
        if let number = try? container.decode(Double.self) {
            self = .number(number)
            return
        }
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }
        if container.decodeNil() {
            self = .null
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported JSON value"
        )
    }

    var foundationValue: Any {
        switch self {
        case .object(let object):
            return object.mapValues(\.foundationValue)
        case .array(let array):
            return array.map(\.foundationValue)
        case .string(let string):
            return string
        case .number(let number):
            return number
        case .bool(let bool):
            return bool
        case .null:
            return NSNull()
        }
    }
}

private extension APIClient {
    nonisolated static func requireRuntimeConfiguration() throws {
#if DEBUG
        let env = ProcessInfo.processInfo.environment
        let args = ProcessInfo.processInfo.arguments
        let isRunningTests = env["XCTestConfigurationFilePath"] != nil ||
            env["LIFEOS_UI_TEST_BOOTSTRAP"] == "1" ||
            args.contains("--lifeos-ui-test-bootstrap=1")

        if isRunningTests ||
            testExecuteDecodedQueryOverride.value != nil ||
            testPostgrestAccessTokenOverride.value != nil ||
            testPostgrestDataForRequestOverride.value != nil ||
            testEdgeInvokeOverride.value != nil ||
            testEdgeRouteDataForRequestOverride.value != nil {
            return
        }
#endif
        guard SupabaseConfig.isRuntimeConfigured else {
            throw APIClientError.runtimeNotConfigured
        }
    }

    static let formatterLock = NSLock()

    nonisolated static func makeHTTPStatusError(
        data: Data,
        response: HTTPURLResponse
    ) -> NSError {
        let bodyText: String
        if let decodedText = String(data: data, encoding: .utf8), !decodedText.isEmpty {
            bodyText = decodedText
        } else {
            bodyText = "HTTP \(response.statusCode)"
        }

        var userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: bodyText,
            "status": response.statusCode
        ]
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(retryAfter) {
            userInfo["retry_after_seconds"] = seconds
        }

        return NSError(domain: httpErrorDomain, code: response.statusCode, userInfo: userInfo)
    }

    nonisolated static func withFormatterLock<T>(_ body: () -> T) -> T {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return body()
    }

    static let utcGregorianCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private static nonisolated(unsafe) let iso8601NoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

#if DEBUG
extension APIClient {
    nonisolated static func _testSetDaysAgoDateByAddingRunner(
        _ runner: (@Sendable (_ days: Int, _ now: Date) -> Date?)?
    ) {
        testDaysAgoDateByAddingRunner.value = runner
    }

    nonisolated static func _testSetExecuteDecodedQueryOverride(
        _ runner: (@Sendable () -> (data: Data, response: HTTPURLResponse))?
    ) {
        testExecuteDecodedQueryOverride.value = runner
    }

    nonisolated static func _testSetPostgrestAccessTokenOverride(_ token: String?) {
        testPostgrestAccessTokenOverride.value = token
    }

    nonisolated static func _testSetPostgrestDataForRequestOverride(
        _ runner: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    ) {
        testPostgrestDataForRequestOverride.value = runner
    }

    nonisolated static func _testSetEdgeInvokeOverride(
        _ runner: (@Sendable (_ name: String, _ options: FunctionInvokeOptions) async throws -> (Data, HTTPURLResponse))?
    ) {
        testEdgeInvokeOverride.value = runner
    }

    nonisolated static func _testSetEdgeRouteDataForRequestOverride(
        _ runner: (@Sendable (URLRequest) async throws -> (Data, URLResponse))?
    ) {
        testEdgeRouteDataForRequestOverride.value = runner
    }

    nonisolated static func _testResetOverrides() {
        testDaysAgoDateByAddingRunner.value = nil
        testExecuteDecodedQueryOverride.value = nil
        testPostgrestAccessTokenOverride.value = nil
        testPostgrestDataForRequestOverride.value = nil
        testEdgeInvokeOverride.value = nil
        testEdgeRouteDataForRequestOverride.value = nil
    }

    nonisolated static func _testParseSupabaseDate(_ rawValue: String) -> Date? {
        parseSupabaseDate(rawValue)
    }

    nonisolated static func _testUTCDateOnlyString(_ date: Date) -> String {
        utcDateOnlyString(date)
    }

    func _testIsRetryable(_ error: Error) -> Bool {
        isRetryable(error: error)
    }

    func _testDaysAgo(_ days: Int, now: Date) -> Date {
        daysAgo(days, from: now)
    }

    func _testCutoffString(forTable table: String, days: Int, now: Date) -> String {
        let cutoff = daysAgo(days, from: now)
        let dateColumnSpec = dateColumnSpecFor(table: table)
        return cutoffString(for: cutoff, kind: dateColumnSpec.valueKind)
    }

    func _testDecodePayload<T: Decodable>(_ data: Data, as _: T.Type = T.self) throws -> T {
        try decodeSupabasePayload(data, as: T.self)
    }

    nonisolated static func _testPassthroughFunctionInvokeResult(
        data: Data,
        response: HTTPURLResponse
    ) throws -> (Data, HTTPURLResponse) {
        try passthroughFunctionInvokeResult(data: data, response: response)
    }

    nonisolated static func _testUTCGregorianCalendarTimeZoneIdentifier() -> String {
        utcGregorianCalendar.timeZone.identifier
    }

    nonisolated static func _testResolveSafeTableName(_ table: String, encodedTable: String?) -> String {
        resolveSafeTableName(table, encodedTable: encodedTable)
    }

    func _testCheckForceUpdateHeaders(_ response: URLResponse?) async {
        await checkForceUpdateHeaders(from: response)
    }

    func _testFetchSyncPageImpl(
        since: Date?,
        cursor: SyncPageCursor?,
        limit: Int,
        executeQuery: @escaping @Sendable (
            _ operatorName: String?,
            _ updatedAt: Date?,
            _ idGreaterThan: String?,
            _ orderByUpdatedAt: Bool,
            _ queryLimit: Int
        ) async throws -> [Int]
    ) async throws -> [Int] {
        try await Self.fetchSyncPageImpl(since: since, cursor: cursor, limit: limit) {
            updatedAtFilter,
            idGreaterThan,
            orderByUpdatedAt,
            queryLimit in
            let operatorName: String?
            let updatedAt: Date?
            if let updatedAtFilter {
                switch updatedAtFilter.0 {
                case .eq:
                    operatorName = "eq"
                case .gt:
                    operatorName = "gt"
                case .gte:
                    operatorName = "gte"
                }
                updatedAt = updatedAtFilter.1
            } else {
                operatorName = nil
                updatedAt = nil
            }
            return try await executeQuery(
                operatorName,
                updatedAt,
                idGreaterThan,
                orderByUpdatedAt,
                queryLimit
            )
        }
    }

    func _testExecuteDecodedQueryRawPathInsightCount(
        data: Data,
        response: HTTPURLResponse
    ) async throws -> Int {
        let previousOverride = Self.testExecuteDecodedQueryOverride.value
        Self.testExecuteDecodedQueryOverride.value = nil
        defer {
            Self.testExecuteDecodedQueryOverride.value = previousOverride
        }
        let decoded: PostgrestResponse<[Insight]> = try await executeDecodedQuery(as: [Insight].self) {
            PostgrestResponse(data: data, response: response, value: ())
        }
        return decoded.value.count
    }

    nonisolated static func _testLossyJSONFoundationValue(_ data: Data) throws -> Any {
        try JSONDecoder().decode(LossyJSONValue.self, from: data).foundationValue
    }

    nonisolated static func _testTriggerLossyJSONUnsupportedBranch() -> Bool {
        struct DummyCodingKey: CodingKey {
            var stringValue: String
            var intValue: Int?
            init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
            init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
        }

        struct UnsupportedDecoder: Decoder {
            struct UnsupportedContainer: SingleValueDecodingContainer {
                var codingPath: [CodingKey] = []

                func decodeNil() -> Bool { false }
                func decode(_ type: Bool.Type) throws -> Bool { throw error() }
                func decode(_ type: String.Type) throws -> String { throw error() }
                func decode(_ type: Double.Type) throws -> Double { throw error() }
                func decode(_ type: Float.Type) throws -> Float { throw error() }
                func decode(_ type: Int.Type) throws -> Int { throw error() }
                func decode(_ type: Int8.Type) throws -> Int8 { throw error() }
                func decode(_ type: Int16.Type) throws -> Int16 { throw error() }
                func decode(_ type: Int32.Type) throws -> Int32 { throw error() }
                func decode(_ type: Int64.Type) throws -> Int64 { throw error() }
                func decode(_ type: UInt.Type) throws -> UInt { throw error() }
                func decode(_ type: UInt8.Type) throws -> UInt8 { throw error() }
                func decode(_ type: UInt16.Type) throws -> UInt16 { throw error() }
                func decode(_ type: UInt32.Type) throws -> UInt32 { throw error() }
                func decode(_ type: UInt64.Type) throws -> UInt64 { throw error() }
                func decode<T>(_ type: T.Type) throws -> T where T: Decodable { throw error() }

                private func error() -> DecodingError {
                    DecodingError.typeMismatch(
                        String.self,
                        .init(codingPath: codingPath, debugDescription: "Unsupported test value")
                    )
                }
            }

            var codingPath: [CodingKey] = []
            var userInfo: [CodingUserInfoKey: Any] = [:]

            func container<Key>(keyedBy _: Key.Type) throws -> KeyedDecodingContainer<Key> where Key: CodingKey {
                throw DecodingError.typeMismatch(
                    [String: Any].self,
                    .init(codingPath: codingPath, debugDescription: "Unsupported keyed container")
                )
            }

            func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
                throw DecodingError.typeMismatch(
                    [Any].self,
                    .init(codingPath: codingPath, debugDescription: "Unsupported unkeyed container")
                )
            }

            func singleValueContainer() throws -> any SingleValueDecodingContainer {
                UnsupportedContainer()
            }
        }

        let decoder = UnsupportedDecoder()
        _ = DummyCodingKey(stringValue: "coverage-key")
        _ = DummyCodingKey(intValue: 1)
        _ = try? decoder.container(keyedBy: DummyCodingKey.self)
        _ = try? decoder.unkeyedContainer()
        if let singleValue = try? decoder.singleValueContainer() {
            _ = try? singleValue.decode(Bool.self)
            _ = try? singleValue.decode(String.self)
            _ = try? singleValue.decode(Double.self)
            _ = try? singleValue.decode(Float.self)
            _ = try? singleValue.decode(Int.self)
            _ = try? singleValue.decode(Int8.self)
            _ = try? singleValue.decode(Int16.self)
            _ = try? singleValue.decode(Int32.self)
            _ = try? singleValue.decode(Int64.self)
            _ = try? singleValue.decode(UInt.self)
            _ = try? singleValue.decode(UInt8.self)
            _ = try? singleValue.decode(UInt16.self)
            _ = try? singleValue.decode(UInt32.self)
            _ = try? singleValue.decode(UInt64.self)
            _ = try? singleValue.decode(LossyJSONValue.self)
        }

        return (try? LossyJSONValue(from: decoder)) == nil
    }
}
#endif

// MARK: - Auth Token Notification

extension Notification.Name {
    /// Posted by APIClient when a 401 Unauthorized response is received.
    /// AuthManager listens for this to re-validate the session token.
    static let apiClientReceivedUnauthorized = Notification.Name("com.lifeos.apiClientReceivedUnauthorized")
}
