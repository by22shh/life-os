import AVFoundation
import Combine
import GRDB
import Observation
import PDFKit
import PhotosUI
import Speech
import SwiftUI
import UIKit
import Vision
//
//  Extracted from NutritionDayView.swift as part of the module split.
//
// MARK: - Food Search View

struct NutritionSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [FoodSearchResult] = []
    @State private var favoriteResults: [FoodSearchResult] = []
    @State private var favoriteKeys: Set<String> = []
    @State private var favoriteMutationIds: Set<UUID> = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    private let catalogService = NutritionCatalogService()
    let targetDay: String
    let loggedAt: Date
    let onSelectResult: (NutritionLogDraft) -> Void

    private var displayedResults: [FoodSearchResult] {
        query.isEmpty ? favoriteResults : results
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(String(localized: "nutrition_search_food"), text: $query)
                        .textFieldStyle(.plain)
                        .onSubmit(submitSearch)
                        .accessibilityIdentifier("nutrition.search.query")
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(Spacing.s)
                .background(LifeOSColors.Surface.card)
                .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
                .padding(LayoutConstants.contentPadding)

                if isSearching {
                    ProgressView()
                        .padding(.top, Spacing.l)
                } else if results.isEmpty && !query.isEmpty {
                    Text(String(localized: "nutrition_no_results"))
                        .font(LifeOSTypography.body)
                        .foregroundStyle(.secondary)
                        .padding(.top, Spacing.l)
                } else if query.isEmpty && favoriteResults.isEmpty {
                    ContentUnavailableView(
                        String(localized: "nutrition_favorites_empty_title"),
                        systemImage: "star",
                        description: Text(String(localized: "nutrition_favorites_empty_subtitle"))
                    )
                } else {
                    List {
                        if query.isEmpty {
                            Section(String(localized: "nutrition_favorites_title")) {
                                ForEach(displayedResults, content: searchResultButton)
                            }
                        } else {
                            ForEach(displayedResults, content: searchResultButton)
                        }
                    }
                    .listStyle(.plain)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.red)
                        .padding(.top, Spacing.s)
                }

                Spacer()
            }
            .navigationTitle(String(localized: "nutrition_search_title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("nutrition.search.screen")
        .task(refreshFavorites)
    }

    private func search(
        searcher: @escaping @Sendable (String) async throws -> [FoodSearchResult]
    ) {
        guard let normalizedQuery = NutritionSearchExecutionHelper.normalizedQuery(query) else { return }
        isSearching = true
        errorMessage = nil
        Task { @MainActor in
            await applySearch(query: normalizedQuery, searcher: searcher)
        }
    }

    private func submitSearch() {
        search { query in
            try await catalogService.searchFoods(query: query)
        }
    }

    @MainActor
    private func applySearch(
        query: String,
        searcher: @escaping @Sendable (String) async throws -> [FoodSearchResult]
    ) async {
        switch await NutritionSearchExecutionHelper.run(query: query, searcher: searcher) {
        case let .success(results):
            self.results = results
        case let .failure(error):
            results = []
            errorMessage = error.localizedDescription
        }
        isSearching = false
    }

    private func searchResultButton(_ result: FoodSearchResult) -> some View {
        HStack(spacing: Spacing.s) {
            Button {
                selectSearchResult(result)
            } label: {
                searchResultLabel(result)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("nutrition.search.result.\(result.name)")

            Button {
                toggleFavorite(result)
            } label: {
                if favoriteMutationIds.contains(result.id) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: isFavorite(result) ? "star.fill" : "star")
                        .foregroundStyle(
                            isFavorite(result)
                                ? LifeOSColors.Recovery.caution
                                : Color.secondary
                        )
                }
            }
            .buttonStyle(.plain)
            .frame(
                minWidth: LayoutConstants.minTouchTarget,
                minHeight: LayoutConstants.minTouchTarget
            )
            .disabled(favoriteMutationIds.contains(result.id))
            .accessibilityIdentifier(
                "nutrition.search.favorite.\(result.id.uuidString.lowercased())"
            )
            .accessibilityLabel(
                isFavorite(result)
                    ? String(localized: "nutrition_remove_favorite")
                    : String(localized: "nutrition_add_favorite")
            )
        }
    }

    private func searchResultLabel(_ result: FoodSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(result.name)
                .font(LifeOSTypography.body)
                .foregroundStyle(.primary)
            if let brand = result.brand {
                Text(brand)
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
            }
            Text(NutritionSafetyPolicy.hidesCalories ? "" : "\(result.roundedCaloriesPer100g) kcal / 100g")
                .font(LifeOSTypography.caption)
                .foregroundStyle(.tertiary)
            if !result.tags.isEmpty {
                Text(result.tags.joined(separator: " • "))
                    .font(LifeOSTypography.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func selectSearchResult(_ result: FoodSearchResult) {
        errorMessage = nil
        onSelectResult(result.makeManualLogDraft(targetDay: targetDay, loggedAt: loggedAt))
    }

    private func refreshFavorites() async {
        favoriteKeys = await catalogService.favoriteKeys()
        favoriteResults = (try? await catalogService.favoriteFoods()) ?? []
    }

    private func isFavorite(_ result: FoodSearchResult) -> Bool {
        favoriteKeys.contains(result.favoriteKey) || result.tags.contains("favorite")
    }

    private func toggleFavorite(_ result: FoodSearchResult) {
        guard !favoriteMutationIds.contains(result.id) else { return }
        let nextValue = !isFavorite(result)
        favoriteMutationIds.insert(result.id)
        errorMessage = nil

        Task { @MainActor in
            do {
                try await catalogService.setFavorite(result, isFavorite: nextValue)
                if nextValue {
                    favoriteKeys.insert(result.favoriteKey)
                    if !favoriteResults.contains(where: {
                        $0.refType == result.refType && $0.id == result.id
                    }) {
                        favoriteResults.insert(result, at: 0)
                    }
                } else {
                    favoriteKeys.remove(result.favoriteKey)
                    favoriteResults.removeAll {
                        $0.refType == result.refType && $0.id == result.id
                    }
                }
                HapticManager.lightTap()
            } catch {
                errorMessage = error.localizedDescription
                HapticManager.error()
            }
            favoriteMutationIds.remove(result.id)
        }
    }
}

struct FoodSearchResult: Identifiable, Equatable, Sendable {
    let id: UUID
    let refType: FoodRefType
    let provider: FoodProvider?
    let name: String
    let brand: String?
    let barcode: String?
    let servingSizeG: Double?
    let caloriesPer100g: Double
    let proteinPer100g: Double
    let fatPer100g: Double
    let carbsPer100g: Double
    let fiberPer100g: Double?
    let tags: [String]

    var roundedCaloriesPer100g: Int {
        Int(caloriesPer100g.rounded())
    }

    var favoriteKey: String {
        "\(refType.rawValue):\(id.uuidString.lowercased())"
    }
}

private extension FoodSearchResult {
    func makeLogDraft(
        method: NutritionLogMethod,
        confidence: Double? = nil,
        targetDay: String,
        loggedAt: Date,
        summary: String? = nil,
        sourceText: String? = nil,
        analysisSource: NutritionAnalysisSource? = nil,
        warnings: [String] = [],
        suggestions: [String] = [],
        recognizedBarcodes: [String] = []
    ) -> NutritionLogDraft {
        let weightG = servingSizeG.flatMap { $0 > 0 ? $0 : nil } ?? 100
        let scale = weightG / 100
        let macros = NutritionDraftMacroSummary(
            calories: caloriesPer100g * scale,
            proteinG: proteinPer100g * scale,
            fatG: fatPer100g * scale,
            carbsG: carbsPer100g * scale,
            fiberG: fiberPer100g.map { $0 * scale }
        )
        let candidateItem = NutritionDraftCandidateItem(
            name: name,
            brand: brand,
            barcode: barcode,
            catalogItemId: refType == .catalog ? id : nil,
            userFoodId: refType == .custom ? id : nil,
            weightG: weightG,
            calories: macros.calories,
            proteinG: macros.proteinG,
            fatG: macros.fatG,
            carbsG: macros.carbsG,
            fiberG: macros.fiberG,
            detectedByAi: false
        )

        return NutritionLogDraft(
            method: method,
            confidence: confidence,
            loggedAt: loggedAt,
            loggedDate: targetDay,
            summary: summary,
            sourceText: sourceText,
            analysisSource: analysisSource,
            totalMacros: macros,
            suggestions: suggestions,
            warnings: warnings,
            recognizedBarcodes: recognizedBarcodes,
            candidateItems: [candidateItem]
        )
    }

    func makeManualLogDraft(targetDay: String, loggedAt: Date) -> NutritionLogDraft {
        makeLogDraft(
            method: .manual,
            targetDay: targetDay,
            loggedAt: loggedAt
        )
    }
}

actor NutritionCatalogService {
    private static let catalogSelectColumns = """
        id, provider, name, brand, barcode, serving_size_g,
        calories_per_100g, protein_per_100g, fat_per_100g, carbs_per_100g,
        fiber_per_100g, fetched_at, expires_at
        """
    private static let customSelectColumns = """
        id, name, brand, barcode, default_serving_g,
        calories_per_100g, protein_per_100g, fat_per_100g, carbs_per_100g,
        fiber_per_100g
        """
    private static let defaultCatalogTTL: TimeInterval = 30 * 24 * 60 * 60

    private let dbQueue: DatabaseQueue
    private let apiClient: APIClient
    private let syncEngineProvider: @Sendable () -> SyncEngine?

    init(
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue,
        apiClient: APIClient = APIClient(),
        syncEngineProvider: @escaping @Sendable () -> SyncEngine? = {
            AppContainer.shared?.syncEngine
        }
    ) {
        self.dbQueue = dbQueue
        self.apiClient = apiClient
        self.syncEngineProvider = syncEngineProvider
    }

    func favoriteKeys() async -> Set<String> {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        let localKeys = (try? await dbQueue.read { db in
            let userId = try NutritionIdentity.resolveUserId(authId: authId, db: db)
            return try Self.loadFavoriteKeys(userId: userId, db: db)
        }) ?? Set<String>()

        do {
            let response: NutritionFavoriteListResponse = try await apiClient.callEdgeRoute(
                function: "api-foods",
                route: "favorites",
                method: "GET",
                queryItems: [],
                headers: localeHeaders(),
                maxAttempts: 1
            )
            try await cacheRemoteFavorites(response.favorites, authId: authId)
            return Set(response.favorites.map(\.favoriteKey))
        } catch {
            return localKeys
        }
    }

    func favoriteFoods() async throws -> [FoodSearchResult] {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        return try await dbQueue.read { db in
            guard let userId = try NutritionIdentity.resolveUserId(authId: authId, db: db) else {
                return []
            }
            let favorites = try Row.fetchAll(
                db,
                sql: """
                    SELECT ref_type, ref_id
                    FROM user_food_favorites
                    WHERE user_id = ? OR user_id = ?
                    ORDER BY created_at DESC
                    """,
                arguments: [userId, userId.uuidString]
            )

            return try favorites.compactMap { favorite in
                guard let refTypeRaw: String = favorite["ref_type"],
                      let refType = FoodRefType(rawValue: refTypeRaw),
                      let refId = MixedUUIDStorage.decode(from: favorite, column: "ref_id") else {
                    return nil
                }

                switch refType {
                case .custom:
                    guard let row = try Row.fetchOne(
                        db,
                        sql: """
                            SELECT \(Self.customSelectColumns)
                            FROM user_foods
                            WHERE (id = ? OR id = ?)
                              AND (user_id = ? OR user_id = ?)
                            LIMIT 1
                            """,
                        arguments: [refId, refId.uuidString, userId, userId.uuidString]
                    ) else {
                        return nil
                    }
                    return Self.makeCustomResult(from: row, tags: ["favorite"])
                case .catalog:
                    guard let row = try Row.fetchOne(
                        db,
                        sql: """
                            SELECT \(Self.catalogSelectColumns)
                            FROM food_catalog_items
                            WHERE id = ? OR id = ?
                            LIMIT 1
                            """,
                        arguments: [refId, refId.uuidString]
                    ) else {
                        return nil
                    }
                    return Self.makeCatalogResult(from: row, tags: ["favorite"])
                }
            }
        }
    }

    func setFavorite(_ result: FoodSearchResult, isFavorite: Bool) async throws {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        guard let userId = try await dbQueue.read({ db in
            try NutritionIdentity.resolveUserId(authId: authId, db: db)
        }) else {
            throw NutritionFavoriteError.userUnavailable
        }

        let favoriteId = try await existingFavoriteId(
            userId: userId,
            result: result
        ) ?? UUID()
        let request = NutritionFavoriteMutationRequest(
            id: favoriteId,
            refType: result.refType,
            refId: result.id
        )
        let body = try JSONEncoder.supabase.encode(request)
        let event = OutboxEvent(
            httpMethod: isFavorite ? .POST : .DELETE,
            path: isFavorite
                ? "api-foods/favorites"
                : "api-foods/favorites/\(result.refType.rawValue)/\(result.id.uuidString.lowercased())",
            bodyJson: isFavorite ? body : Data(),
            priority: 45,
            idempotencyKey: [
                "food-favorite",
                isFavorite ? "add" : "remove",
                userId.uuidString.lowercased(),
                result.refType.rawValue,
                result.id.uuidString.lowercased(),
            ].joined(separator: "-")
        )

        if let syncEngine = syncEngineProvider() {
            _ = try await syncEngine.performOptimisticMutation { db in
                try Self.applyFavoriteMutation(
                    userId: userId,
                    result: result,
                    favoriteId: favoriteId,
                    isFavorite: isFavorite,
                    db: db
                )
                return (value: (), event: event)
            }
        } else {
            try await dbQueue.write { db in
                try Self.applyFavoriteMutation(
                    userId: userId,
                    result: result,
                    favoriteId: favoriteId,
                    isFavorite: isFavorite,
                    db: db
                )
            }
        }
    }

    func searchFoods(query: String, limit: Int = 20) async throws -> [FoodSearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        do {
            let response: NutritionFoodsSearchResponse = try await apiClient.callEdgeRoute(
                function: "api-foods",
                route: "search",
                queryItems: [
                    URLQueryItem(name: "q", value: trimmedQuery),
                    URLQueryItem(name: "limit", value: String(limit))
                ],
                headers: localeHeaders(),
                maxAttempts: 1
            )
            try? await cacheRemoteResults(response.results)
            return response.results.map(\.searchResult)
        } catch {
            let localResults = try await searchLocalCache(query: trimmedQuery, limit: limit)
            if !localResults.isEmpty {
                return localResults
            }
            throw error
        }
    }

    func lookupBarcode(_ barcode: String) async throws -> FoodSearchResult? {
        let code = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return nil }

        do {
            let response: NutritionFoodsRemoteResult = try await apiClient.callEdgeRoute(
                function: "api-foods",
                route: "barcode/\(code)",
                headers: localeHeaders(),
                maxAttempts: 1
            )
            try? await cacheRemoteResults([response])
            return response.searchResult
        } catch {
            if let localResult = try await lookupLocalBarcode(barcode: code) {
                return localResult
            }
            return nil
        }
    }

    func createReviewedFood(review: NutritionLabelReviewDraft) async throws -> FoodSearchResult {
        if review.usesBarcodeCatalog {
            return try await createBarcodeCatalogItem(review: review)
        }
        return try await createCustomFoodItem(review: review)
    }

    private func createBarcodeCatalogItem(review: NutritionLabelReviewDraft) async throws -> FoodSearchResult {
        let barcode = review.normalizedBarcode
        let body = try JSONEncoder().encode(
            NutritionBarcodeCatalogCreateRequest(review: review)
        )
        let response: NutritionBarcodeCatalogCreateResponse = try await apiClient.callEdgeRoute(
            function: "api-foods",
            route: "barcode/\(barcode)/create",
            method: "POST",
            queryItems: [],
            body: body,
            headers: localeHeaders()
        )

        let remote = NutritionFoodsRemoteResult(
            type: .catalog,
            id: response.id,
            provider: response.provider,
            name: review.name,
            brand: review.trimmedBrand,
            barcode: barcode,
            servingSizeG: review.servingSizeG,
            macrosPer100g: review.remoteMacros,
            tags: nil,
            fetchedAt: Date(),
            expiresAt: nil
        )
        try? await cacheRemoteResults([remote])
        return remote.searchResult
    }

    private func createCustomFoodItem(review: NutritionLabelReviewDraft) async throws -> FoodSearchResult {
        let body = try JSONEncoder().encode(
            NutritionCustomFoodCreateRequest(review: review)
        )
        let response: NutritionCustomFoodCreateResponse = try await apiClient.callEdgeRoute(
            function: "api-foods",
            route: "custom",
            method: "POST",
            queryItems: [],
            body: body,
            headers: localeHeaders()
        )

        let remote = NutritionFoodsRemoteResult(
            type: .custom,
            id: response.id,
            provider: nil,
            name: review.name,
            brand: review.trimmedBrand,
            barcode: review.normalizedBarcode.nilIfEmpty,
            servingSizeG: review.servingSizeG,
            macrosPer100g: review.remoteMacros,
            tags: ["user_override"],
            fetchedAt: Date(),
            expiresAt: nil
        )
        try? await cacheRemoteResults([remote])
        return remote.searchResult
    }

    private func cacheRemoteResults(_ results: [NutritionFoodsRemoteResult]) async throws {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }

        try await dbQueue.write { db in
            let userId = try NutritionIdentity.resolveUserId(authId: authId, db: db)
            let now = Date()

            for result in results {
                switch result.type {
                case .catalog:
                    try Self.upsertCatalogResult(result, now: now, db: db)
                case .custom:
                    guard let userId else { continue }
                    try Self.upsertCustomResult(result, userId: userId, now: now, db: db)
                }
            }
        }
    }

    private func cacheRemoteFavorites(
        _ favorites: [NutritionFavoriteRemoteItem],
        authId: String?
    ) async throws {
        try await dbQueue.write { db in
            guard let userId = try NutritionIdentity.resolveUserId(authId: authId, db: db) else {
                return
            }
            try db.execute(
                sql: "DELETE FROM user_food_favorites WHERE user_id = ? OR user_id = ?",
                arguments: [userId, userId.uuidString]
            )
            for favorite in favorites {
                try Self.upsertFavorite(
                    id: favorite.id,
                    userId: userId,
                    refType: favorite.refType,
                    refId: favorite.refId,
                    createdAt: favorite.createdAt,
                    updatedAt: favorite.updatedAt,
                    db: db
                )
            }
        }
    }

    private func existingFavoriteId(
        userId: UUID,
        result: FoodSearchResult
    ) async throws -> UUID? {
        try await dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id
                    FROM user_food_favorites
                    WHERE (user_id = ? OR user_id = ?)
                      AND ref_type = ?
                      AND (ref_id = ? OR ref_id = ?)
                    LIMIT 1
                    """,
                arguments: [
                    userId,
                    userId.uuidString,
                    result.refType.rawValue,
                    result.id,
                    result.id.uuidString
                ]
            )
            guard let row else { return nil }
            return MixedUUIDStorage.decode(from: row, column: "id")
        }
    }

    private static func applyFavoriteMutation(
        userId: UUID,
        result: FoodSearchResult,
        favoriteId: UUID,
        isFavorite: Bool,
        db: Database
    ) throws {
        if isFavorite {
            try upsertFavorite(
                id: favoriteId,
                userId: userId,
                refType: result.refType,
                refId: result.id,
                createdAt: Date(),
                updatedAt: Date(),
                db: db
            )
        } else {
            try db.execute(
                sql: """
                    DELETE FROM user_food_favorites
                    WHERE (user_id = ? OR user_id = ?)
                      AND ref_type = ?
                      AND (ref_id = ? OR ref_id = ?)
                    """,
                arguments: [
                    userId,
                    userId.uuidString,
                    result.refType.rawValue,
                    result.id,
                    result.id.uuidString
                ]
            )
        }
    }

    private static func upsertFavorite(
        id: UUID,
        userId: UUID,
        refType: FoodRefType,
        refId: UUID,
        createdAt: Date,
        updatedAt: Date,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO user_food_favorites (
                    id, user_id, ref_type, ref_id, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(user_id, ref_type, ref_id) DO UPDATE SET
                    updated_at = excluded.updated_at
                """,
            arguments: [
                id,
                userId,
                refType.rawValue,
                refId,
                createdAt,
                updatedAt
            ]
        )
    }

    private func searchLocalCache(query: String, limit: Int) async throws -> [FoodSearchResult] {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        return try await dbQueue.read { db in
            let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let likeQuery = "%\(normalizedQuery)%"
            let userId = try NutritionIdentity.resolveUserId(authId: authId, db: db)

            let favorites = try Self.loadFavoriteKeys(userId: userId, db: db)
            let recent = try Self.loadRecentKeys(userId: userId, db: db)

            let customRows: [Row]
            if let userId {
                customRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT \(Self.customSelectColumns)
                        FROM user_foods
                        WHERE (user_id = ? OR user_id = ?)
                          AND (name LIKE ? OR COALESCE(brand, '') LIKE ? OR barcode = ?)
                        ORDER BY updated_at DESC
                        LIMIT 60
                        """,
                    arguments: [userId, userId.uuidString, likeQuery, likeQuery, normalizedQuery]
                )
            } else {
                customRows = []
            }

            let catalogRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.catalogSelectColumns)
                    FROM food_catalog_items
                    WHERE name LIKE ? OR COALESCE(brand, '') LIKE ? OR barcode = ?
                    ORDER BY fetched_at DESC, name ASC
                    LIMIT 60
                    """,
                arguments: [likeQuery, likeQuery, normalizedQuery]
            )

            var candidates: [NutritionLocalSearchCandidate] = []

            for row in customRows {
                guard let result = Self.makeCustomResult(from: row, tags: Self.tags(
                    favorites: favorites,
                    recent: recent,
                    refType: .custom,
                    id: MixedUUIDStorage.decode(from: row, column: "id")
                )) else {
                    continue
                }
                candidates.append(
                    NutritionLocalSearchCandidate(
                        result: result,
                        score: Self.score(result: result, query: normalizedQuery, source: .custom, favorites: favorites, recent: recent)
                    )
                )
            }

            for row in catalogRows {
                guard let result = Self.makeCatalogResult(from: row, tags: Self.tags(
                    favorites: favorites,
                    recent: recent,
                    refType: .catalog,
                    id: MixedUUIDStorage.decode(from: row, column: "id")
                )) else {
                    continue
                }
                candidates.append(
                    NutritionLocalSearchCandidate(
                        result: result,
                        score: Self.score(result: result, query: normalizedQuery, source: .cache, favorites: favorites, recent: recent)
                    )
                )
            }

            return Self.uniqueSortedResults(candidates: candidates, limit: limit)
        }
    }

    private func lookupLocalBarcode(barcode: String) async throws -> FoodSearchResult? {
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        return try await dbQueue.read { db in
            let userId = try NutritionIdentity.resolveUserId(authId: authId, db: db)
            if let userId,
               let row = try Row.fetchOne(
                   db,
                   sql: """
                       SELECT \(Self.customSelectColumns)
                       FROM user_foods
                       WHERE (user_id = ? OR user_id = ?)
                         AND barcode = ?
                       ORDER BY updated_at DESC
                       LIMIT 1
                       """,
                   arguments: [userId, userId.uuidString, barcode]
               ),
               let result = Self.makeCustomResult(from: row, tags: ["user_override"]) {
                return result
            }

            let now = Date()
            if let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT \(Self.catalogSelectColumns)
                    FROM food_catalog_items
                    WHERE provider = ?
                      AND barcode = ?
                      AND (expires_at IS NULL OR expires_at >= ?)
                    ORDER BY fetched_at DESC
                    LIMIT 1
                    """,
                arguments: [FoodProvider.openFoodFacts.rawValue, barcode, now]
            ),
            let result = Self.makeCatalogResult(from: row) {
                return result
            }

            if let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT \(Self.catalogSelectColumns)
                    FROM food_catalog_items
                    WHERE provider = ?
                      AND barcode = ?
                    ORDER BY fetched_at DESC
                    LIMIT 1
                    """,
                arguments: [FoodProvider.lifeosLabelOcr.rawValue, barcode]
            ),
            let result = Self.makeCatalogResult(from: row) {
                return result
            }

            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT \(Self.catalogSelectColumns)
                    FROM food_catalog_items
                    WHERE barcode = ?
                    ORDER BY fetched_at DESC
                    LIMIT 1
                    """,
                arguments: [barcode]
            ) else {
                return nil
            }

            return Self.makeCatalogResult(from: row)
        }
    }

    private func localeHeaders() -> [String: String] {
        let preferredLocale = Locale.preferredLanguages.first ?? Locale.current.identifier
        return [
            "X-Locale": preferredLocale,
            "Accept-Language": preferredLocale
        ]
    }

    private static func upsertCatalogResult(_ result: NutritionFoodsRemoteResult, now: Date, db: Database) throws {
        let provider = result.provider ?? .other
        let fetchedAt = result.fetchedAt ?? now
        let expiresAt = result.expiresAt ?? (provider == .openFoodFacts
            ? now.addingTimeInterval(defaultCatalogTTL)
            : nil)
        try db.execute(
            sql: """
                INSERT INTO food_catalog_items (
                    id, provider, provider_item_id, barcode, created_by_user_id,
                    name, brand, locale, image_url, serving_size_g,
                    calories_per_100g, protein_per_100g, fat_per_100g, carbs_per_100g,
                    fiber_per_100g, sugar_per_100g, sodium_mg_per_100g, source_confidence,
                    fetched_at, expires_at, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    provider = excluded.provider,
                    provider_item_id = excluded.provider_item_id,
                    barcode = excluded.barcode,
                    created_by_user_id = excluded.created_by_user_id,
                    name = excluded.name,
                    brand = excluded.brand,
                    locale = excluded.locale,
                    image_url = excluded.image_url,
                    serving_size_g = excluded.serving_size_g,
                    calories_per_100g = excluded.calories_per_100g,
                    protein_per_100g = excluded.protein_per_100g,
                    fat_per_100g = excluded.fat_per_100g,
                    carbs_per_100g = excluded.carbs_per_100g,
                    fiber_per_100g = excluded.fiber_per_100g,
                    sugar_per_100g = excluded.sugar_per_100g,
                    sodium_mg_per_100g = excluded.sodium_mg_per_100g,
                    source_confidence = excluded.source_confidence,
                    fetched_at = excluded.fetched_at,
                    expires_at = excluded.expires_at,
                    updated_at = excluded.updated_at
                """,
            arguments: [
                MixedUUIDStorage.encode(result.id),
                provider.rawValue,
                result.barcode,
                result.barcode,
                nil,
                result.name,
                result.brand,
                nil,
                nil,
                result.servingSizeG,
                result.macrosPer100g.calories,
                result.macrosPer100g.proteinG,
                result.macrosPer100g.fatG,
                result.macrosPer100g.carbsG,
                result.macrosPer100g.fiberG,
                nil,
                nil,
                nil,
                fetchedAt,
                expiresAt,
                now,
                now
            ]
        )
    }

    private static func upsertCustomResult(
        _ result: NutritionFoodsRemoteResult,
        userId: UUID,
        now: Date,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO user_foods (
                    id, user_id, name, brand, barcode, default_serving_g,
                    calories_per_100g, protein_per_100g, fat_per_100g,
                    carbs_per_100g, fiber_per_100g, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    user_id = excluded.user_id,
                    name = excluded.name,
                    brand = excluded.brand,
                    barcode = excluded.barcode,
                    default_serving_g = excluded.default_serving_g,
                    calories_per_100g = excluded.calories_per_100g,
                    protein_per_100g = excluded.protein_per_100g,
                    fat_per_100g = excluded.fat_per_100g,
                    carbs_per_100g = excluded.carbs_per_100g,
                    fiber_per_100g = excluded.fiber_per_100g,
                    updated_at = excluded.updated_at
                """,
            arguments: [
                MixedUUIDStorage.encode(result.id),
                MixedUUIDStorage.encode(userId),
                result.name,
                result.brand,
                result.barcode,
                result.servingSizeG,
                result.macrosPer100g.calories,
                result.macrosPer100g.proteinG,
                result.macrosPer100g.fatG,
                result.macrosPer100g.carbsG,
                result.macrosPer100g.fiberG,
                now,
                now
            ]
        )
    }

    private static func loadFavoriteKeys(userId: UUID?, db: Database) throws -> Set<String> {
        guard let userId else { return [] }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT ref_type, ref_id
                FROM user_food_favorites
                WHERE user_id = ? OR user_id = ?
                """,
            arguments: [userId, userId.uuidString]
        )
        return favoriteKeys(from: rows)
    }

    private static func favoriteKeys(from rows: [Row]) -> Set<String> {
        Set(rows.compactMap { row in
            guard let refType: String = row["ref_type"],
                  let refId: String = row["ref_id"] else {
                return nil
            }
            return "\(refType):\(refId)"
        })
    }

    private static func loadRecentKeys(userId: UUID?, db: Database) throws -> Set<String> {
        guard let userId else { return [] }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT user_food_id, catalog_item_id
                FROM food_items
                WHERE user_id = ? OR user_id = ?
                ORDER BY created_at DESC
                LIMIT 80
                """,
            arguments: [userId, userId.uuidString]
        )
        return recentKeys(from: rows)
    }

    private static func recentKeys(from rows: [Row]) -> Set<String> {
        var keys = Set<String>()
        for row in rows {
            if row.columnNames.contains("user_food_id"),
               let userFoodId = MixedUUIDStorage.decode(from: row, column: "user_food_id") {
                keys.insert("custom:\(userFoodId.uuidString)")
            }
            if row.columnNames.contains("catalog_item_id"),
               let catalogItemId = MixedUUIDStorage.decode(from: row, column: "catalog_item_id") {
                keys.insert("catalog:\(catalogItemId.uuidString)")
            }
        }
        return keys
    }

    private static func tags(
        favorites: Set<String>,
        recent: Set<String>,
        refType: FoodRefType,
        id: UUID?
    ) -> [String] {
        guard let id else { return [] }
        let key = "\(refType.rawValue):\(id.uuidString)"
        var values: [String] = []
        if favorites.contains(key) {
            values.append("favorite")
        }
        if recent.contains(key) {
            values.append("recent")
        }
        return values
    }

    private static func score(
        result: FoodSearchResult,
        query: String,
        source: NutritionSearchScoreSource,
        favorites: Set<String>,
        recent: Set<String>
    ) -> Int {
        let key = "\(result.refType.rawValue):\(result.id.uuidString)"
        let normalizedQuery = query.lowercased()
        let normalizedName = result.name.lowercased()
        let normalizedBrand = (result.brand ?? "").lowercased()

        let group: Int
        if favorites.contains(key) {
            group = 0
        } else if recent.contains(key) {
            group = 1
        } else if result.refType == .custom {
            group = 2
        } else {
            group = source == .provider ? 4 : 3
        }

        var value = group * 100
        if result.barcode == query {
            value -= 40
        }
        if normalizedName == normalizedQuery {
            value -= 30
        }
        if normalizedName.hasPrefix(normalizedQuery) {
            value -= 20
        }
        if normalizedName.contains(normalizedQuery) {
            value -= 10
        }
        if normalizedBrand.contains(normalizedQuery) {
            value -= 5
        }
        return value
    }

    private static func uniqueSortedResults(
        candidates: [NutritionLocalSearchCandidate],
        limit: Int
    ) -> [FoodSearchResult] {
        var seen = Set<String>()
        var unique: [FoodSearchResult] = []

        for candidate in candidates.sorted(by: {
            if $0.score != $1.score {
                return $0.score < $1.score
            }
            return $0.result.name.localizedCaseInsensitiveCompare($1.result.name) == .orderedAscending
        }) {
            let key = "\(candidate.result.refType.rawValue):\(candidate.result.id.uuidString)"
            if seen.insert(key).inserted {
                unique.append(candidate.result)
            }
            if unique.count >= limit {
                break
            }
        }

        return unique
    }

    private static func makeCustomResult(from row: Row, tags: [String] = []) -> FoodSearchResult? {
        guard let id = MixedUUIDStorage.decode(from: row, column: "id"),
              let name: String = row["name"] else {
            return nil
        }

        return FoodSearchResult(
            id: id,
            refType: .custom,
            provider: nil,
            name: name,
            brand: row["brand"],
            barcode: row["barcode"],
            servingSizeG: row["default_serving_g"],
            caloriesPer100g: row["calories_per_100g"] ?? 0,
            proteinPer100g: row["protein_per_100g"] ?? 0,
            fatPer100g: row["fat_per_100g"] ?? 0,
            carbsPer100g: row["carbs_per_100g"] ?? 0,
            fiberPer100g: row["fiber_per_100g"],
            tags: tags
        )
    }

    private static func makeCatalogResult(from row: Row, tags: [String] = []) -> FoodSearchResult? {
        guard let id = MixedUUIDStorage.decode(from: row, column: "id"),
              let name: String = row["name"] else {
            return nil
        }

        let providerRaw: String = row["provider"] ?? FoodProvider.other.rawValue
        let provider = FoodProvider(rawValue: providerRaw) ?? .other

        return FoodSearchResult(
            id: id,
            refType: .catalog,
            provider: provider,
            name: name,
            brand: row["brand"],
            barcode: row["barcode"],
            servingSizeG: row["serving_size_g"],
            caloriesPer100g: row["calories_per_100g"] ?? 0,
            proteinPer100g: row["protein_per_100g"] ?? 0,
            fatPer100g: row["fat_per_100g"] ?? 0,
            carbsPer100g: row["carbs_per_100g"] ?? 0,
            fiberPer100g: row["fiber_per_100g"],
            tags: tags
        )
    }
}

private struct NutritionFoodsSearchResponse: Decodable {
    let query: String
    let limit: Int
    let results: [NutritionFoodsRemoteResult]
}

private struct NutritionFavoriteListResponse: Decodable {
    let favorites: [NutritionFavoriteRemoteItem]
}

private struct NutritionFavoriteRemoteItem: Decodable {
    let id: UUID
    let refType: FoodRefType
    let refId: UUID
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case refType = "ref_type"
        case refId = "ref_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var favoriteKey: String {
        "\(refType.rawValue):\(refId.uuidString.lowercased())"
    }
}

private struct NutritionFavoriteMutationRequest: Encodable {
    let id: UUID
    let refType: FoodRefType
    let refId: UUID

    enum CodingKeys: String, CodingKey {
        case id
        case refType = "ref_type"
        case refId = "ref_id"
    }
}

private enum NutritionFavoriteError: LocalizedError {
    case userUnavailable

    var errorDescription: String? {
        switch self {
        case .userUnavailable:
            return String(localized: "nutrition_favorite_user_unavailable")
        }
    }
}

private struct NutritionFoodsRemoteResult: Decodable {
    let type: FoodRefType
    let id: UUID
    let provider: FoodProvider?
    let name: String
    let brand: String?
    let barcode: String?
    let servingSizeG: Double?
    let macrosPer100g: NutritionFoodsRemoteMacros
    let tags: [String]?
    let fetchedAt: Date?
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case provider
        case name
        case brand
        case barcode
        case servingSizeG = "serving_size_g"
        case macrosPer100g = "macros_per_100g"
        case tags
        case fetchedAt = "fetched_at"
        case expiresAt = "expires_at"
    }

    var searchResult: FoodSearchResult {
        FoodSearchResult(
            id: id,
            refType: type,
            provider: provider,
            name: name,
            brand: brand,
            barcode: barcode,
            servingSizeG: servingSizeG,
            caloriesPer100g: macrosPer100g.calories,
            proteinPer100g: macrosPer100g.proteinG,
            fatPer100g: macrosPer100g.fatG,
            carbsPer100g: macrosPer100g.carbsG,
            fiberPer100g: macrosPer100g.fiberG,
            tags: tags ?? []
        )
    }
}

struct NutritionFoodsRemoteMacros: Codable {
    let calories: Double
    let proteinG: Double
    let fatG: Double
    let carbsG: Double
    let fiberG: Double?

    enum CodingKeys: String, CodingKey {
        case calories
        case proteinG = "protein_g"
        case fatG = "fat_g"
        case carbsG = "carbs_g"
        case fiberG = "fiber_g"
    }
}

private struct NutritionBarcodeCatalogCreateRequest: Encodable {
    let provider: String
    let name: String
    let brand: String?
    let servingSizeG: Double
    let macrosPer100g: NutritionFoodsRemoteMacros
    let sourceConfidence: Double?

    init(review: NutritionLabelReviewDraft) {
        provider = FoodProvider.lifeosLabelOcr.rawValue
        name = review.name
        brand = review.trimmedBrand
        servingSizeG = review.servingSizeG
        macrosPer100g = review.remoteMacros
        sourceConfidence = review.confidence
    }

    enum CodingKeys: String, CodingKey {
        case provider
        case name
        case brand
        case servingSizeG = "serving_size_g"
        case macrosPer100g = "macros_per_100g"
        case sourceConfidence = "source_confidence"
    }
}

private struct NutritionBarcodeCatalogCreateResponse: Decodable {
    let provider: FoodProvider
    let id: UUID
    let barcode: String
}

private struct NutritionCustomFoodCreateRequest: Encodable {
    let id: UUID
    let name: String
    let brand: String?
    let barcode: String?
    let defaultServingG: Double
    let macrosPer100g: NutritionFoodsRemoteMacros

    init(review: NutritionLabelReviewDraft) {
        id = UUID()
        name = review.name
        brand = review.trimmedBrand
        barcode = review.normalizedBarcode.nilIfEmpty
        defaultServingG = review.servingSizeG
        macrosPer100g = review.remoteMacros
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case brand
        case barcode
        case defaultServingG = "default_serving_g"
        case macrosPer100g = "macros_per_100g"
    }
}

private struct NutritionCustomFoodCreateResponse: Decodable {
    let id: UUID
    let name: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt = "created_at"
    }
}

struct NutritionLabelReviewDraft: Equatable, Sendable {
    var barcode: String
    var name: String
    var brand: String
    var servingSizeG: Double
    var caloriesPer100g: Double
    var proteinPer100g: Double
    var fatPer100g: Double
    var carbsPer100g: Double
    var fiberPer100g: Double
    var confidence: Double?
    var warnings: [String]
    var sourceText: String?
    var analysisSource: NutritionAnalysisSource
    var summary: String?

    init(
        barcode: String = "",
        name: String,
        brand: String = "",
        servingSizeG: Double,
        caloriesPer100g: Double,
        proteinPer100g: Double,
        fatPer100g: Double,
        carbsPer100g: Double,
        fiberPer100g: Double = 0,
        confidence: Double?,
        warnings: [String] = [],
        sourceText: String? = nil,
        analysisSource: NutritionAnalysisSource,
        summary: String? = nil
    ) {
        self.barcode = barcode
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.brand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        self.servingSizeG = servingSizeG
        self.caloriesPer100g = caloriesPer100g
        self.proteinPer100g = proteinPer100g
        self.fatPer100g = fatPer100g
        self.carbsPer100g = carbsPer100g
        self.fiberPer100g = fiberPer100g
        self.confidence = confidence
        self.warnings = warnings
        self.sourceText = sourceText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.analysisSource = analysisSource
        self.summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var usesBarcodeCatalog: Bool {
        !normalizedBarcode.isEmpty
    }

    var normalizedBarcode: String {
        barcode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedBrand: String? {
        brand.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    var remoteMacros: NutritionFoodsRemoteMacros {
        NutritionFoodsRemoteMacros(
            calories: caloriesPer100g,
            proteinG: proteinPer100g,
            fatG: fatPer100g,
            carbsG: carbsPer100g,
            fiberG: fiberPer100g > 0 ? fiberPer100g : nil
        )
    }

    var logConfidence: Double? {
        guard usesBarcodeCatalog else { return nil }
        guard let confidence else {
            return NutritionReviewGate.confidenceThreshold
        }
        return max(confidence, NutritionReviewGate.confidenceThreshold)
    }

    func makeLogDraft(
        from result: FoodSearchResult,
        targetDay: String,
        loggedAt: Date
    ) -> NutritionLogDraft {
        result.makeLogDraft(
            method: usesBarcodeCatalog ? .barcode : .manual,
            confidence: logConfidence,
            targetDay: targetDay,
            loggedAt: loggedAt,
            summary: summary ?? name,
            sourceText: sourceText,
            analysisSource: analysisSource,
            warnings: warnings,
            suggestions: [],
            recognizedBarcodes: usesBarcodeCatalog ? [normalizedBarcode] : []
        )
    }
}

struct NutritionLocalSearchCandidate {
    let result: FoodSearchResult
    let score: Int
}

private enum NutritionSearchScoreSource {
    case cache
    case provider
    case custom
}

#if DEBUG
// MARK: - Test support extensions (co-located with their types)
extension NutritionSearchView {
    init(
        targetDay: String = NutritionCoverageFixtures.targetDay,
        loggedAt: Date = NutritionCoverageFixtures.loggedAt,
        testQuery: String = "",
        testResults: [FoodSearchResult] = [],
        testIsSearching: Bool = false,
        testErrorMessage: String? = nil,
        onSelectResult: @escaping (NutritionLogDraft) -> Void = { _ in }
    ) {
        self.targetDay = targetDay
        self.loggedAt = loggedAt
        self.onSelectResult = onSelectResult
        _query = State(initialValue: testQuery)
        _results = State(initialValue: testResults)
        _isSearching = State(initialValue: testIsSearching)
        _errorMessage = State(initialValue: testErrorMessage)
    }

    func _testEvaluateBody() {
        _ = body
    }

    func _testState() -> (
        results: [FoodSearchResult],
        isSearching: Bool,
        errorMessage: String?
    ) {
        (results, isSearching, errorMessage)
    }

    @MainActor
    func _testRenderSearchResultButton(_ result: FoodSearchResult) {
        let host = UIHostingController(rootView: searchResultButton(result))
        _ = host.view
    }

    func _testSelectSearchResult(_ result: FoodSearchResult) {
        selectSearchResult(result)
    }

    func _testSubmitSearchUsingDefaultService() {
        submitSearch()
    }

    func _testTriggerSearch(
        searcher: @escaping @Sendable (String) async throws -> [FoodSearchResult]
    ) async -> (
        results: [FoodSearchResult],
        isSearching: Bool,
        errorMessage: String?
    ) {
        search(searcher: searcher)
        for _ in 0..<50 {
            await Task.yield()
        }
        return _testState()
    }

    static func _testSearchExecution(
        query: String,
        searcher: @Sendable (String) async throws -> [FoodSearchResult]
    ) async -> Result<[FoodSearchResult], Error>? {
        guard let normalizedQuery = NutritionSearchExecutionHelper.normalizedQuery(query) else {
            return nil
        }
        return await NutritionSearchExecutionHelper.run(query: normalizedQuery, searcher: searcher)
    }
}

extension NutritionCatalogService {
    private static func _testRow(
        requiredColumns: [String],
        values: [String: (any DatabaseValueConvertible)?]
    ) -> Row {
        var completeValues: [String: (any DatabaseValueConvertible)?] = [:]
        for column in requiredColumns {
            completeValues[column] = nil
        }
        for (key, value) in values {
            completeValues[key] = value
        }
        return Row(completeValues)
    }

    static func _testFavoriteKeys(
        values: [[String: (any DatabaseValueConvertible)?]]
    ) -> Set<String> {
        favoriteKeys(from: values.map {
            _testRow(requiredColumns: ["ref_type", "ref_id"], values: $0)
        })
    }

    static func _testRecentKeys(
        values: [[String: (any DatabaseValueConvertible)?]]
    ) -> Set<String> {
        recentKeys(from: values.map {
            _testRow(requiredColumns: ["user_food_id", "catalog_item_id"], values: $0)
        })
    }

    static func _testLoadFavoriteKeys(userId: UUID?, db: Database) throws -> Set<String> {
        try loadFavoriteKeys(userId: userId, db: db)
    }

    static func _testLoadRecentKeys(userId: UUID?, db: Database) throws -> Set<String> {
        try loadRecentKeys(userId: userId, db: db)
    }

    static func _testTags(
        favorites: Set<String>,
        recent: Set<String>,
        refType: FoodRefType,
        id: UUID?
    ) -> [String] {
        tags(favorites: favorites, recent: recent, refType: refType, id: id)
    }

    static func _testScore(
        result: FoodSearchResult,
        query: String,
        sourceIsProvider: Bool,
        favorites: Set<String>,
        recent: Set<String>
    ) -> Int {
        score(
            result: result,
            query: query,
            source: sourceIsProvider ? .provider : .cache,
            favorites: favorites,
            recent: recent
        )
    }

    static func _testUniqueSortedResults(
        resultsWithScores: [(result: FoodSearchResult, score: Int)],
        limit: Int
    ) -> [FoodSearchResult] {
        uniqueSortedResults(
            candidates: resultsWithScores.map { NutritionLocalSearchCandidate(result: $0.result, score: $0.score) },
            limit: limit
        )
    }

    static func _testMakeCustomResult(
        values: [String: (any DatabaseValueConvertible)?],
        tags: [String] = []
    ) -> FoodSearchResult? {
        makeCustomResult(
            from: _testRow(
                requiredColumns: [
                    "id",
                    "name",
                    "brand",
                    "barcode",
                    "default_serving_g",
                    "calories_per_100g",
                    "protein_per_100g",
                    "fat_per_100g",
                    "carbs_per_100g",
                    "fiber_per_100g"
                ],
                values: values
            ),
            tags: tags
        )
    }

    static func _testMakeCatalogResult(
        values: [String: (any DatabaseValueConvertible)?],
        tags: [String] = []
    ) -> FoodSearchResult? {
        makeCatalogResult(
            from: _testRow(
                requiredColumns: [
                    "id",
                    "name",
                    "provider",
                    "brand",
                    "barcode",
                    "serving_size_g",
                    "calories_per_100g",
                    "protein_per_100g",
                    "fat_per_100g",
                    "carbs_per_100g",
                    "fiber_per_100g"
                ],
                values: values
            ),
            tags: tags
        )
    }
}
#endif
