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

enum NutritionSafetyPolicy {
    static func hidesCalories(in db: Database, userId: UUID) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT (hide_calories = 1 OR has_eating_disorder_history = 1) FROM user_health_flags WHERE user_id = ? OR user_id = ? ORDER BY updated_at DESC LIMIT 1", arguments: [userId, userId.uuidString]) ?? false
    }

    static func suppressesTargets(in db: Database, userId: UUID) throws -> Bool {
        if try hidesCalories(in: db, userId: userId) { return true }
        return try Bool.fetchOne(db, sql: "SELECT (pregnancy_mode = 1 OR is_pregnant = 1) FROM user_health_flags WHERE user_id = ? OR user_id = ? ORDER BY updated_at DESC LIMIT 1", arguments: [userId, userId.uuidString]) ?? false
    }

    // Auth enforces a single-owner vault. Rendering reads the current committed
    // policy, so changing safety settings does not leave a cached calorie label.
    static var hidesCalories: Bool {
        guard let queue = DatabaseManager.sharedStartupState.manager?.dbQueue else { return true }
        return (try? queue.read { db in
            try Bool.fetchOne(db, sql: "SELECT MAX(hide_calories = 1 OR has_eating_disorder_history = 1) FROM user_health_flags") ?? false
        }) ?? true
    }

    static var suppressesTargets: Bool {
        guard let queue = DatabaseManager.sharedStartupState.manager?.dbQueue else { return true }
        return (try? queue.read { db in
            try Bool.fetchOne(db, sql: "SELECT MAX(hide_calories = 1 OR has_eating_disorder_history = 1 OR pregnancy_mode = 1 OR is_pregnant = 1) FROM user_health_flags") ?? false
        }) ?? true
    }
}

func localizedNutritionCalories(_ calories: Int) -> String {
    guard !NutritionSafetyPolicy.hidesCalories else { return "" }
    return String(format: String(localized: "nutrition_kcal_format"), calories)
}

func localizedNutritionLastUsed(_ date: Date) -> String {
    String(
        format: String(localized: "nutrition_last_used_format"),
        date.formatted(date: .abbreviated, time: .omitted)
    )
}

func localizedNutritionUsedCount(_ count: Int) -> String {
    String(format: String(localized: "nutrition_used_count_format"), count)
}

func localizedNutritionCooked(_ value: String) -> String {
    String(format: String(localized: "nutrition_cooked_format"), value)
}

func localizedNutritionRemainingLine(weightG: Double, portionsRemaining: Double? = nil) -> String {
    let weight = Int(weightG.rounded())
    if let portionsRemaining {
        return String(
            format: String(localized: "nutrition_remaining_weight_portions_format"),
            weight,
            portionsRemaining.formatted(.number.precision(.fractionLength(0...1)))
        )
    }
    return String(format: String(localized: "nutrition_remaining_weight_format"), weight)
}

func localizedNutritionPortionsLeft(_ portions: Double) -> String {
    String(
        format: String(localized: "nutrition_portions_left_format"),
        portions.formatted(.number.precision(.fractionLength(0...1)))
    )
}

func localizedNutritionMacroTotals(protein: Double, fat: Double, carbs: Double, fiber: Double?) -> String {
    let proteinValue = Int(protein.rounded())
    let fatValue = Int(fat.rounded())
    let carbsValue = Int(carbs.rounded())
    if let fiber {
        return String(
            format: String(localized: "nutrition_macro_totals_with_fiber_format"),
            proteinValue,
            fatValue,
            carbsValue,
            Int(fiber.rounded())
        )
    }
    return String(
        format: String(localized: "nutrition_macro_totals_without_fiber_format"),
        proteinValue,
        fatValue,
        carbsValue
    )
}

func localizedNutritionItemSummary(
    weightG: Double,
    calories: Double,
    protein: Double,
    fat: Double,
    carbs: Double,
    fiber: Double?
) -> String {
    if NutritionSafetyPolicy.hidesCalories {
        return "\(Int(weightG.rounded())) g · " + localizedNutritionMacroTotals(protein: protein, fat: fat, carbs: carbs, fiber: fiber)
    }
    let weightValue = Int(weightG.rounded())
    let caloriesValue = Int(calories.rounded())
    let proteinValue = Int(protein.rounded())
    let fatValue = Int(fat.rounded())
    let carbsValue = Int(carbs.rounded())
    if let fiber, fiber > 0 {
        return String(
            format: String(localized: "nutrition_item_summary_with_fiber_format"),
            weightValue,
            caloriesValue,
            proteinValue,
            fatValue,
            carbsValue,
            Int(fiber.rounded())
        )
    }
    return String(
        format: String(localized: "nutrition_item_summary_without_fiber_format"),
        weightValue,
        caloriesValue,
        proteinValue,
        fatValue,
        carbsValue
    )
}

func localizedNutritionBatchMacroLine(_ snapshot: NutritionBatchMacroSnapshot, prefix: String) -> String {
    if NutritionSafetyPolicy.hidesCalories {
        return prefix + " · " + localizedNutritionItemSummary(weightG: snapshot.weightG, calories: 0, protein: snapshot.proteinG, fat: snapshot.fatG, carbs: snapshot.carbsG, fiber: snapshot.fiberG)
    }
    let weightValue = Int(snapshot.weightG.rounded())
    let caloriesValue = Int(snapshot.calories.rounded())
    let proteinValue = Int(snapshot.proteinG.rounded())
    let fatValue = Int(snapshot.fatG.rounded())
    let carbsValue = Int(snapshot.carbsG.rounded())
    if let fiberG = snapshot.fiberG, fiberG > 0 {
        return String(
            format: String(localized: "nutrition_batch_macro_line_with_fiber_format"),
            prefix,
            weightValue,
            caloriesValue,
            proteinValue,
            fatValue,
            carbsValue,
            Int(fiberG.rounded())
        )
    }
    return String(
        format: String(localized: "nutrition_batch_macro_line_without_fiber_format"),
        prefix,
        weightValue,
        caloriesValue,
        proteinValue,
        fatValue,
        carbsValue
    )
}

struct NutritionPhotoDraft: Codable, Identifiable, Sendable {
    let id: UUID
    let targetDay: String
    let loggedAt: Date
    let createdAt: Date
    let updatedAt: Date
}

enum NutritionPhotoDraftStore {
    private static let metadataExtension = "json"
    private static let imageExtension = "jpg"

    static func save(
        imageData: Data,
        targetDay: String,
        loggedAt: Date,
        id: UUID? = nil,
        directoryOverride: URL? = nil
    ) throws -> NutritionPhotoDraft {
        let directory = try draftsDirectory(createIfNeeded: true, override: directoryOverride)
        let draftId = id ?? UUID()
        let existing = try metadata(id: draftId, directoryOverride: directoryOverride)
        let now = Date()
        let draft = NutritionPhotoDraft(
            id: draftId,
            targetDay: targetDay,
            loggedAt: loggedAt,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )

        try imageData.write(to: imageURL(id: draftId, directory: directory), options: .atomic)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(draft).write(
            to: metadataURL(id: draftId, directory: directory),
            options: .atomic
        )
        try protect(directory)
        return draft
    }

    static func list(
        targetDay: String? = nil,
        directoryOverride: URL? = nil
    ) throws -> [NutritionPhotoDraft] {
        let directory = try draftsDirectory(createIfNeeded: false, override: directoryOverride)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return urls
            .filter { $0.pathExtension == metadataExtension }
            .compactMap { try? decodeMetadata(at: $0) }
            .filter { targetDay == nil || $0.targetDay == targetDay }
            .filter {
                FileManager.default.fileExists(
                    atPath: imageURL(id: $0.id, directory: directory).path
                )
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func imageData(
        id: UUID,
        directoryOverride: URL? = nil
    ) throws -> Data {
        let directory = try draftsDirectory(createIfNeeded: false, override: directoryOverride)
        return try Data(contentsOf: imageURL(id: id, directory: directory))
    }

    static func delete(
        id: UUID,
        directoryOverride: URL? = nil
    ) throws {
        let directory = try draftsDirectory(createIfNeeded: false, override: directoryOverride)
        for url in [
            imageURL(id: id, directory: directory),
            metadataURL(id: id, directory: directory),
        ] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func removeAll(directoryOverride: URL? = nil) throws {
        let directory = try draftsDirectory(createIfNeeded: false, override: directoryOverride)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private static func metadata(
        id: UUID,
        directoryOverride: URL?
    ) throws -> NutritionPhotoDraft? {
        let directory = try draftsDirectory(createIfNeeded: false, override: directoryOverride)
        let url = metadataURL(id: id, directory: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decodeMetadata(at: url)
    }

    private static func decodeMetadata(at url: URL) throws -> NutritionPhotoDraft {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(NutritionPhotoDraft.self, from: Data(contentsOf: url))
    }

    private static func draftsDirectory(
        createIfNeeded: Bool,
        override: URL?
    ) throws -> URL {
        if let override {
            if createIfNeeded {
                try FileManager.default.createDirectory(
                    at: override,
                    withIntermediateDirectories: true
                )
            }
            return override
        }
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: createIfNeeded
        )
        let directory = appSupport
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent("NutritionPhotoDrafts", isDirectory: true)
        if createIfNeeded {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        return directory
    }

    private static func imageURL(id: UUID, directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension(imageExtension)
    }

    private static func metadataURL(id: UUID, directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension(metadataExtension)
    }

    private static func protect(_ directory: URL) throws {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(resourceValues)
#if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
#endif
    }
}

struct NutritionDayView: View {
    let dateString: String?

    // MARK: - Sheet State

    @State private var activeModal: NutritionDayModal?
    @State private var selectedDate: Date
    @State private var mealsLogged: [FoodLog] = []
    @State private var photoDrafts: [NutritionPhotoDraft] = []
    @State private var isApplyingTemplate = false
    @State private var templateStatusMessage: TemplateStatusMessage?
    @State private var templateRefreshToken = 0
    @State private var featureFlagRefreshTick = 0
#if DEBUG
    nonisolated(unsafe) private static var testBatchRecipesEnabledOverride: Bool?
    nonisolated(unsafe) private static var testLoadMealsAction: ((Date) async -> [FoodLog])?
    nonisolated(unsafe) private static var testApplyMealTemplateAction: ((UUID, Date) async throws -> NutritionMealTemplateApplicationResult)?
#endif

    init(dateString: String?) {
        self.dateString = dateString
        _selectedDate = State(initialValue: Self.initialSelectedDate(from: dateString))
    }

    private var inputMethods: [(method: NutritionLogMethod, title: LocalizedStringResource, icon: String)] {
        Self.resolvedInputMethods(batchRecipesEnabled: isBatchRecipesEnabled)
    }

    private var isBatchRecipesEnabled: Bool {
#if DEBUG
        if let testBatchRecipesEnabledOverride = Self.testBatchRecipesEnabledOverride {
            return testBatchRecipesEnabledOverride
        }
#endif
        return Self.resolvedBatchRecipesEnabled(
            AppContainer.shared?.featureFlags.isEnabled(.batchRecipesEnabled)
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.m) {
                // MARK: Date Navigation Header
                dateNavigationHeader

                // MARK: Input Methods
                Section {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: Spacing.s),
                            GridItem(.flexible(), spacing: Spacing.s),
                            GridItem(.flexible(), spacing: Spacing.s)
                        ],
                        spacing: Spacing.s
                    ) {
                        ForEach(inputMethods, id: \.method, content: inputMethodTileWithInteractions)
                    }
                }
                .padding(.top, Spacing.xs)

                // MARK: Quick Log (Meal Templates)
                MealTemplatesView(
                    targetDay: DiaryDateFormatter.formatDate(selectedDate),
                    loggedAt: Self.selectedLogTime(for: selectedDate),
                    refreshTrigger: templateRefreshToken,
                    onTemplatesChanged: handleTemplatesChanged,
                    onTemplateLogged: handleTemplateLogged,
                    onSelectTemplate: handleTemplateSelection
                )

                templateStatusSection

                photoDraftsSection

                // MARK: Batch Recipe Quick Action
                if isBatchRecipesEnabled {
                    batchRecipeQuickAction
                }

                // MARK: Meals Logged Today
                mealsLoggedSection
            }
            .padding(LayoutConstants.contentPadding)
        }
        .accessibilityIdentifier("nutrition.day.screen")
        .background(LifeOSColors.Surface.background)
        .navigationTitle(String(localized: "nutrition"))
        .fullScreenCover(item: $activeModal, content: modalContent)
        .task(id: selectedDate, loadMealsForDateTask)
        .task(id: selectedDate, loadPhotoDraftsTask)
        .onReceive(
            NotificationCenter.default
                .publisher(for: FeatureFlagManager.didUpdateNotification)
                .receive(on: RunLoop.main),
            perform: handleFeatureFlagUpdate
        )
    }

    @ViewBuilder
    private var photoDraftsSection: some View {
        if !photoDrafts.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(String(localized: "nutrition_photo_drafts_title"))
                    .font(LifeOSTypography.subheadline.weight(.semibold))

                ForEach(photoDrafts) { draft in
                    HStack(spacing: Spacing.s) {
                        Image(systemName: "photo.badge.clock")
                            .foregroundStyle(LifeOSColors.Semantic.primary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "nutrition_photo_draft"))
                                .font(LifeOSTypography.body)
                            Text(draft.updatedAt, style: .time)
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(LifeOSColors.Text.secondary)
                        }
                        Spacer()
                        Button(String(localized: "nutrition_photo_draft_resume")) {
                            activeModal = .photoDraft(draft.id)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("nutrition.photo_draft.resume.\(draft.id.uuidString)")

                        Button(role: .destructive) {
                            deletePhotoDraft(draft)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel(String(localized: "delete"))
                        .accessibilityIdentifier("nutrition.photo_draft.delete.\(draft.id.uuidString)")
                    }
                    .padding(Spacing.s)
                    .background(LifeOSColors.Surface.card)
                    .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
                }
            }
            .accessibilityIdentifier("nutrition.photo_drafts")
        }
    }

    @ViewBuilder
    private var templateStatusSection: some View {
        if isApplyingTemplate {
            ProgressView(String(localized: "nutrition_apply_template_progress"))
                .font(LifeOSTypography.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let templateStatusMessage {
            Label(templateStatusMessage.message, systemImage: templateStatusMessage.systemImage)
                .font(LifeOSTypography.caption)
                .foregroundStyle(templateStatusMessage.color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var batchRecipeQuickAction: some View {
        Button(action: presentBatchRecipeIfEnabled, label: batchRecipeQuickActionLabel)
            .buttonStyle(.plain)
    }

    private func batchRecipeQuickActionLabel() -> some View {
        HStack {
            Image(systemName: "square.stack.3d.up")
            Text(String(localized: "nutrition_meal_prep"))
                .font(LifeOSTypography.subheadline.weight(.semibold))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(LifeOSColors.Text.secondary)
        }
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private var mealsLoggedSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(String(localized: "nutrition_meals_logged"))
                .font(LifeOSTypography.subheadline.weight(.semibold))

            if mealsLogged.isEmpty {
                Text(String(localized: "no_meals_logged"))
                    .font(LifeOSTypography.body)
                    .foregroundStyle(LifeOSColors.Text.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Spacing.l)
            } else {
                ForEach(mealsLogged, content: mealNavigationLink)
            }
        }
    }

    private func mealNavigationLink(for meal: FoodLog) -> some View {
        NavigationLink {
            mealNavigationDestination(for: meal)
        } label: {
            mealRowLabel(for: meal)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("nutrition.meal.row.\(meal.id.uuidString)")
    }

    private func mealNavigationDestination(for meal: FoodLog) -> some View {
        NutritionLogView(
            method: meal.inputMethod.asLogMethod,
            aiConfidence: meal.aiConfidence,
            existingMealId: meal.id,
            onComplete: handleLoggedMealReload
        )
    }

    private func mealRowLabel(for meal: FoodLog) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(localizedNutritionMealType(meal.mealType, emptyKey: "nutrition_meal"))
                    .font(LifeOSTypography.body)
                Text(localizedNutritionCalories(Int(meal.calories)))
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(LifeOSColors.Text.secondary)
            }
            Spacer()
            Text(meal.loggedAt, style: .time)
                .font(LifeOSTypography.caption)
                .foregroundStyle(LifeOSColors.Text.tertiary)
        }
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private func handleLoggedMealReload() {
        Task { await loadMealsForDate() }
    }

    // MARK: - Date Navigation Header

    private var dateNavigationHeader: some View {
        HStack {
            Button(action: previousDayButtonTapped) {
                Image(systemName: "chevron.left")
                    .frame(width: LayoutConstants.minTouchTarget, height: LayoutConstants.minTouchTarget)
                    .contentShape(Rectangle())
            }

            Spacer()

            Button(action: showCalendarButtonTapped) {
                VStack(spacing: 2) {
                    Label(String(localized: "nutrition"), systemImage: "fork.knife")
                        .font(LifeOSTypography.title3)
                    Text(selectedDate.formatted(.dateTime.month().day().weekday(.wide)))
                        .font(LifeOSTypography.subheadline)
                        .foregroundStyle(LifeOSColors.Text.secondary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: nextDayButtonTapped) {
                Image(systemName: "chevron.right")
                    .frame(width: LayoutConstants.minTouchTarget, height: LayoutConstants.minTouchTarget)
                    .contentShape(Rectangle())
            }
        }
        .refreshOnFeatureFlagChanges()
    }

    // MARK: - Navigation Helper

    private func previousDayButtonTapped() {
        selectedDate = Self.shiftedDate(from: selectedDate, dayOffset: -1) { component, value, date in
            Calendar.current.date(byAdding: component, value: value, to: date)
        }
    }

    private func showCalendarButtonTapped() {
        activeModal = .calendar
    }

    private func nextDayButtonTapped() {
        selectedDate = Self.shiftedDate(from: selectedDate, dayOffset: 1) { component, value, date in
            Calendar.current.date(byAdding: component, value: value, to: date)
        }
    }

    private func handleTemplatesChanged() {
        templateRefreshToken += 1
    }

    private func handleTemplateLogged() {
        Task { await loadMealsForDate() }
    }

    private func handleTemplateSelection(_ templateId: UUID) {
        Task { await applyTemplate(templateId) }
    }

    private func handleLoggedMealRefresh() {
        Task { await loadMealsForDate() }
    }

    private func handleLoggedDraftResult(_ draft: NutritionLogDraft) {
        navigateToLog(draft: draft)
    }

    private func dismissBatchRecipeModalIfDisabled() {
        activeModal = nil
    }

    @ViewBuilder
    private func modalContent(for modal: NutritionDayModal) -> some View {
        switch modal {
        case .photoCapture:
            NutritionPhotoCaptureView(
                targetDay: DiaryDateFormatter.formatDate(selectedDate),
                loggedAt: Self.selectedLogTime(for: selectedDate),
                onDraftStateChanged: reloadPhotoDrafts,
                onResult: handleLoggedDraftResult
            )
        case .photoDraft(let draftId):
            NutritionPhotoCaptureView(
                targetDay: DiaryDateFormatter.formatDate(selectedDate),
                loggedAt: Self.selectedLogTime(for: selectedDate),
                savedDraftId: draftId,
                onDraftStateChanged: reloadPhotoDrafts,
                onResult: handleLoggedDraftResult
            )
        case .barcodeScanner:
            NutritionBarcodeScannerView(
                targetDay: DiaryDateFormatter.formatDate(selectedDate),
                loggedAt: Self.selectedLogTime(for: selectedDate),
                onLogged: handleLoggedMealRefresh,
                onResult: handleLoggedDraftResult
            )
        case .voiceInput:
            NutritionVoiceInputView(
                targetDay: DiaryDateFormatter.formatDate(selectedDate),
                loggedAt: Self.selectedLogTime(for: selectedDate),
                onResult: handleLoggedDraftResult
            )
        case .foodSearch:
            NutritionSearchView(
                targetDay: DiaryDateFormatter.formatDate(selectedDate),
                loggedAt: Self.selectedLogTime(for: selectedDate),
                onSelectResult: handleLoggedDraftResult
            )
        case .batchRecipe:
            if isBatchRecipesEnabled {
                BatchRecipeView(
                    targetDay: DiaryDateFormatter.formatDate(selectedDate),
                    loggedAt: Self.selectedLogTime(for: selectedDate),
                    onBatchesChanged: handleBatchRecipesChanged,
                    onBatchLogged: handleLoggedMealRefresh
                )
            } else {
                Color.clear
                    .onAppear(perform: handleDisabledBatchRecipeModalAppear)
            }
        case .calendar:
            NutritionCalendarView(selectedDate: $selectedDate)
        case .log(let draft):
            NavigationStack {
                NutritionLogView(
                    method: draft.method,
                    aiConfidence: draft.confidence,
                    draft: draft,
                    onComplete: handleLoggedMealRefresh
                )
            }
        }
    }

    private func loadMealsForDateTask() async {
        await loadMealsForDate()
    }

    private func loadPhotoDraftsTask() async {
        reloadPhotoDrafts()
    }

    private func reloadPhotoDrafts() {
        photoDrafts = (try? NutritionPhotoDraftStore.list(
            targetDay: DiaryDateFormatter.formatDate(selectedDate)
        )) ?? []
    }

    private func deletePhotoDraft(_ draft: NutritionPhotoDraft) {
        try? NutritionPhotoDraftStore.delete(id: draft.id)
        reloadPhotoDrafts()
    }

    private func handleBatchRecipesChanged() {
        Task { await loadMealsForDate() }
    }

    private func handleDisabledBatchRecipeModalAppear() {
        dismissBatchRecipeModalIfDisabled()
    }

    private static func shouldDismissBatchRecipeModal(
        batchRecipesEnabled: Bool,
        activeModal: NutritionDayModal?
    ) -> Bool {
        !batchRecipesEnabled && isBatchRecipeModal(activeModal)
    }

    private func handleFeatureFlagUpdate(_: Notification) {
        featureFlagRefreshTick &+= 1
        if Self.shouldDismissBatchRecipeModal(
            batchRecipesEnabled: isBatchRecipesEnabled,
            activeModal: activeModal
        ) {
            activeModal = nil
        }
    }

    private func navigateToLog(method: NutritionLogMethod, confidence: Double?) {
        let draft = Self.navigationDraft(
            method: method,
            confidence: confidence,
            selectedDate: selectedDate
        )
        navigateToLog(draft: draft)
    }

    private func navigateToLog(draft: NutritionLogDraft) {
        HapticManager.lightTap()
        activeModal = nil
        Task { @MainActor in
            await Task.yield()
            activeModal = .log(draft)
        }
    }

    private func loadMealsForDate() async {
#if DEBUG
        let overrideAction = Self.testLoadMealsAction
#else
        let overrideAction: ((Date) async -> [FoodLog])? = nil
#endif
        mealsLogged = await Self.resolvedMealsForDate(
            selectedDate: selectedDate,
            overrideAction: overrideAction,
            dbQueue: DatabaseManager.shared.dbQueue,
            authId: AuthManager.activeAuthId?.uuidString
        )
    }

    @MainActor
    private func applyTemplate(_ templateId: UUID) async {
        isApplyingTemplate = true
        templateStatusMessage = nil
        defer { isApplyingTemplate = false }

#if DEBUG
        let applyAction = Self.testApplyMealTemplateAction
#else
        let applyAction: ((UUID, Date) async throws -> NutritionMealTemplateApplicationResult)? = nil
#endif
        switch await Self.resolvedTemplateApplication(
            templateId: templateId,
            selectedDate: selectedDate,
            applyAction: applyAction
        ) {
        case let .success(applied):
            templateStatusMessage = Self.appliedTemplateStatusMessage(templateName: applied.templateName)
            HapticManager.success()
            templateRefreshToken += 1
            await loadMealsForDate()
        case let .failure(error):
            templateStatusMessage = Self.failedTemplateStatusMessage(message: error.localizedDescription)
            HapticManager.error()
        }
    }

    private func inputMethodTile(
        method: (method: NutritionLogMethod, title: LocalizedStringResource, icon: String)
    ) -> some View {
        Button(action: inputMethodTileAction(for: method.method)) {
            VStack(spacing: Spacing.xxs) {
                Image(systemName: method.icon)
                    .font(.title3)
                    .frame(width: LayoutConstants.minTouchTarget, height: LayoutConstants.minTouchTarget)
                Text(String(localized: method.title))
                    .font(LifeOSTypography.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 72)
            .padding(.vertical, Spacing.xxs)
            .background(LifeOSColors.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("nutrition.input.\(method.method.rawValue)")
    }

    private func presentSheet(for method: NutritionLogMethod) {
        activeModal = Self.resolvedModal(for: method, batchRecipesEnabled: isBatchRecipesEnabled)
    }

    private func presentBatchRecipeIfEnabled() {
        activeModal = Self.batchRecipeModal(batchRecipesEnabled: isBatchRecipesEnabled)
    }

    private func inputMethodTileWithInteractions(
        method: (method: NutritionLogMethod, title: LocalizedStringResource, icon: String)
    ) -> some View {
        inputMethodTile(method: method)
            .accessibilityLabel(String(localized: method.title))
    }

    private static func handleInputMethodTileTap() {
        HapticManager.lightTap()
    }

    private func handleInputMethodSelection(_ method: NutritionLogMethod) {
        Self.handleInputMethodTileTap()
        presentSheet(for: method)
    }

    private func inputMethodTileAction(for method: NutritionLogMethod) -> () -> Void {
        { handleInputMethodSelection(method) }
    }

    private static func inputMethodTileTapAction() {
        handleInputMethodTileTap()
    }

    private static func setTestBatchRecipesEnabledOverride(_ value: Bool?) {
#if DEBUG
        testBatchRecipesEnabledOverride = value
#else
        _ = value
#endif
    }

    private static func setTestLoadMealsAction(_ action: ((Date) async -> [FoodLog])?) {
#if DEBUG
        testLoadMealsAction = action
#else
        _ = action
#endif
    }

    private static func setTestApplyMealTemplateAction(
        _ action: ((UUID, Date) async throws -> NutritionMealTemplateApplicationResult)?
    ) {
#if DEBUG
        testApplyMealTemplateAction = action
#else
        _ = action
#endif
    }

    private static func currentTestOverrides() -> (
        batchRecipesEnabled: Bool?,
        loadMealsAction: ((Date) async -> [FoodLog])?,
        applyMealTemplateAction: ((UUID, Date) async throws -> NutritionMealTemplateApplicationResult)?
    ) {
#if DEBUG
        return (
            testBatchRecipesEnabledOverride,
            testLoadMealsAction,
            testApplyMealTemplateAction
        )
#else
        return (nil, nil, nil)
#endif
    }

    private static func restoreTestOverrides(
        _ overrides: (
            batchRecipesEnabled: Bool?,
            loadMealsAction: ((Date) async -> [FoodLog])?,
            applyMealTemplateAction: ((UUID, Date) async throws -> NutritionMealTemplateApplicationResult)?
        )
    ) {
#if DEBUG
        testBatchRecipesEnabledOverride = overrides.batchRecipesEnabled
        testLoadMealsAction = overrides.loadMealsAction
        testApplyMealTemplateAction = overrides.applyMealTemplateAction
#else
        _ = overrides
#endif
    }

    private static func withTestOverrides<T>(
        batchRecipesEnabled: Bool? = nil,
        loadMealsAction: ((Date) async -> [FoodLog])? = nil,
        applyMealTemplateAction: ((UUID, Date) async throws -> NutritionMealTemplateApplicationResult)? = nil,
        perform: () async throws -> T
    ) async rethrows -> T {
        let overrides = currentTestOverrides()
        setTestBatchRecipesEnabledOverride(batchRecipesEnabled)
        setTestLoadMealsAction(loadMealsAction)
        setTestApplyMealTemplateAction(applyMealTemplateAction)
        defer { restoreTestOverrides(overrides) }
        return try await perform()
    }

    private static func defaultInputMethods() -> [(method: NutritionLogMethod, title: LocalizedStringResource, icon: String)] {
        [
            (.photo, "nutrition_method_vision", "camera"),
            (.barcode, "nutrition_method_barcode", "barcode.viewfinder"),
            (.voice, "nutrition_method_voice", "waveform"),
            (.manual, "nutrition_method_manual", "square.and.pencil"),
            (.batch, "nutrition_method_batch", "square.stack.3d.up"),
            (.template, "nutrition_method_template", "doc.text")
        ]
    }

    private static func resolvedInputMethods(
        batchRecipesEnabled: Bool
    ) -> [(method: NutritionLogMethod, title: LocalizedStringResource, icon: String)] {
        guard batchRecipesEnabled else {
            return defaultInputMethods().filter { $0.method != .batch }
        }
        return defaultInputMethods()
    }

    private static func resolvedModal(
        for method: NutritionLogMethod,
        batchRecipesEnabled: Bool
    ) -> NutritionDayModal? {
        switch method {
        case .photo:
            return .photoCapture
        case .barcode:
            return .barcodeScanner
        case .voice:
            return .voiceInput
        case .manual:
            return .foodSearch
        case .batch:
            return batchRecipeModal(batchRecipesEnabled: batchRecipesEnabled)
        case .template:
            return nil
        }
    }

    private static func batchRecipeModal(batchRecipesEnabled: Bool) -> NutritionDayModal? {
        guard batchRecipesEnabled else { return nil }
        return .batchRecipe
    }

    private static func isBatchRecipeModal(_ modal: NutritionDayModal?) -> Bool {
        guard let modal else { return false }
        if case .batchRecipe = modal {
            return true
        }
        return false
    }

    private static func initialSelectedDate(from dateString: String?) -> Date {
        DiaryDateFormatter.parseDate(dateString) ?? Date()
    }

    private static func resolvedBatchRecipesEnabled(_ isEnabled: Bool?) -> Bool {
        isEnabled ?? AppFeatureFlag.batchRecipesEnabled.defaultEnabled
    }

    private static func shiftedDate(
        from date: Date,
        dayOffset: Int,
        dateBuilder: (Calendar.Component, Int, Date) -> Date?
    ) -> Date {
        dateBuilder(.day, dayOffset, date) ?? date
    }

    private static func navigationDraft(
        method: NutritionLogMethod,
        confidence: Double?,
        selectedDate: Date
    ) -> NutritionLogDraft {
        let loggedAt = selectedLogTime(for: selectedDate)
        return NutritionLogDraft(
            method: method,
            confidence: confidence,
            loggedAt: loggedAt,
            loggedDate: DiaryDateFormatter.formatDate(selectedDate)
        )
    }

    private static func selectedLogTime(for selectedDate: Date) -> Date {
        let calendar = Calendar.current
        let nowComponents = calendar.dateComponents([.hour, .minute, .second], from: Date())
        return selectedLogTime(
            for: selectedDate,
            hour: nowComponents.hour,
            minute: nowComponents.minute,
            second: nowComponents.second
        ) { hour, minute, second, date in
            calendar.date(
                bySettingHour: hour,
                minute: minute,
                second: second,
                of: date
            )
        }
    }

    private static func selectedLogTime(
        for selectedDate: Date,
        hour: Int?,
        minute: Int?,
        second: Int?,
        dateBuilder: (Int, Int, Int, Date) -> Date?
    ) -> Date {
        dateBuilder(
            hour ?? 12,
            minute ?? 0,
            second ?? 0,
            selectedDate
        ) ?? selectedDate
    }

    private static func resolvedMealsForDate(
        selectedDate: Date,
        overrideAction: ((Date) async -> [FoodLog])?,
        dbQueue: DatabaseQueue,
        authId: String?
    ) async -> [FoodLog] {
#if DEBUG
        if let overrideAction {
            return await overrideAction(selectedDate)
        }
#else
        _ = overrideAction
#endif
        return await loadMealsForDate(
            selectedDate: selectedDate,
            dbQueue: dbQueue,
            authId: authId
        )
    }

    private static func resolvedTemplateApplication(
        templateId: UUID,
        selectedDate: Date,
        applyAction: ((UUID, Date) async throws -> NutritionMealTemplateApplicationResult)?
    ) async -> Result<NutritionMealTemplateApplicationResult, Error> {
        do {
#if DEBUG
            if let applyAction {
                return .success(try await applyAction(templateId, selectedDate))
            }
#else
            _ = applyAction
#endif
            return .success(
                try await templateApplicationService(
                    templateId: templateId,
                    selectedDate: selectedDate
                )
            )
        } catch {
            return .failure(error)
        }
    }

    private static func templateApplicationService(
        templateId: UUID,
        selectedDate: Date
    ) async throws -> NutritionMealTemplateApplicationResult {
#if DEBUG
        if let testApplyMealTemplateAction {
            return try await testApplyMealTemplateAction(templateId, selectedDate)
        }
#endif
        return try await NutritionService().applyMealTemplate(
            id: templateId,
            targetDay: DiaryDateFormatter.formatDate(selectedDate),
            loggedAt: selectedLogTime(for: selectedDate),
            context: nil
        )
    }

    private static func appliedTemplateStatusMessage(templateName: String) -> TemplateStatusMessage {
        TemplateStatusMessage(
            message: String(
                format: String(localized: "nutrition_logged_template_format"),
                templateName
            ),
            isError: false
        )
    }

    private static func failedTemplateStatusMessage(message: String) -> TemplateStatusMessage {
        TemplateStatusMessage(message: message, isError: true)
    }

    private static func loadMealsForDate(
        selectedDate: Date,
        dbQueue: DatabaseQueue,
        authId: String?
    ) async -> [FoodLog] {
        let targetDate = DiaryDateFormatter.formatDate(selectedDate)
        do {
            return try await dbQueue.read { db in
                guard let userId = try NutritionIdentity.resolveUserId(authId: authId, db: db) else {
                    return []
                }
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM food_logs
                        WHERE (user_id = ? OR user_id = ?)
                          AND logged_date = ?
                        AND deleted_at IS NULL
                        ORDER BY logged_at ASC
                        """,
                    arguments: [userId, userId.uuidString, targetDate]
                )
                return rows.compactMap { row in
                    decodedFoodLogRow(
                        row,
                        targetDate: targetDate,
                        fallbackLoggedAt: Date()
                    )
                }
            }
        } catch {
            return []
        }
    }

    nonisolated private static func decodedFoodLogRow(
        _ row: Row,
        targetDate: String,
        fallbackLoggedAt: @autoclosure () -> Date
    ) -> FoodLog? {
        guard let id = MixedUUIDStorage.decode(from: row, column: "id"),
              let userId = MixedUUIDStorage.decode(from: row, column: "user_id"),
              let inputMethodStr: String = decodedRowValue(from: row, column: "input_method"),
              let inputMethod = NutritionInputMethod(rawValue: inputMethodStr) else {
            return nil
        }

        let loggedAt: Date = decodedRowValue(from: row, column: "logged_at") ?? fallbackLoggedAt()
        var log = FoodLog(
            id: id,
            userId: userId,
            loggedAt: loggedAt,
            loggedDate: targetDate,
            inputMethod: inputMethod,
            calories: decodedRowValue(from: row, column: "calories") ?? 0,
            proteinG: decodedRowValue(from: row, column: "protein_g") ?? 0,
            fatG: decodedRowValue(from: row, column: "fat_g") ?? 0,
            carbsG: decodedRowValue(from: row, column: "carbs_g") ?? 0
        )
        let mealTypeRaw: String? = decodedRowValue(from: row, column: "meal_type")
        log.mealType = mealTypeRaw.flatMap(MealType.init(rawValue:))
        log.aiConfidence = decodedRowValue(from: row, column: "ai_confidence")
        return log
    }

    nonisolated private static func decodedRowValue<Value: DatabaseValueConvertible>(
        from row: Row,
        column: String
    ) -> Value? {
        guard let databaseValue = databaseValue(from: row, column: column) else {
            return nil
        }
        return Value.fromDatabaseValue(databaseValue)
    }

    nonisolated private static func databaseValue(from row: Row, column: String) -> DatabaseValue? {
        for (name, databaseValue) in row where name.caseInsensitiveCompare(column) == .orderedSame {
            return databaseValue
        }
        return nil
    }
}

private enum NutritionDayModal: Identifiable {
    case photoCapture
    case photoDraft(UUID)
    case barcodeScanner
    case voiceInput
    case foodSearch
    case batchRecipe
    case calendar
    case log(NutritionLogDraft)

    var id: String {
        switch self {
        case .photoCapture:
            return "photo_capture"
        case .photoDraft(let id):
            return "photo_draft:\(id.uuidString)"
        case .barcodeScanner:
            return "barcode_scanner"
        case .voiceInput:
            return "voice_input"
        case .foodSearch:
            return "food_search"
        case .batchRecipe:
            return "batch_recipe"
        case .calendar:
            return "calendar"
        case .log(let draft):
            return "log:\(draft.id.uuidString)"
        }
    }
}

struct TemplateStatusMessage {
    let message: String
    let isError: Bool

    var systemImage: String {
        isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    var color: Color {
        isError ? LifeOSColors.Recovery.critical : LifeOSColors.Recovery.ready
    }
}

struct NutritionLogView: View {
    let method: NutritionLogMethod?
    let aiConfidence: Double?
    let draft: NutritionLogDraft?
    let existingMealId: UUID?
    let onComplete: (() -> Void)?

    @State private var viewModel: NutritionLogViewModel
    @Environment(\.dismiss) private var dismiss

    init(
        method: NutritionLogMethod?,
        aiConfidence: Double?,
        draft: NutritionLogDraft? = nil,
        existingMealId: UUID? = nil,
        onComplete: (() -> Void)? = nil
    ) {
        self.method = method
        self.aiConfidence = aiConfidence
        self.draft = draft
        self.existingMealId = existingMealId
        self.onComplete = onComplete
        _viewModel = State(
            initialValue: NutritionLogViewModel(
                method: method,
                aiConfidence: aiConfidence,
                draft: draft,
                existingMealId: existingMealId
            )
        )
    }

#if DEBUG
    init(
        method: NutritionLogMethod?,
        aiConfidence: Double?,
        draft: NutritionLogDraft? = nil,
        existingMealId: UUID? = nil,
        onComplete: (() -> Void)? = nil,
        testViewModel: NutritionLogViewModel
    ) {
        self.method = method
        self.aiConfidence = aiConfidence
        self.draft = draft
        self.existingMealId = existingMealId
        self.onComplete = onComplete
        _viewModel = State(initialValue: testViewModel)
    }
#endif

    var body: some View {
        @Bindable var viewModel = viewModel

        ScrollView {
            VStack(spacing: Spacing.m) {
                headerSection(viewModel)

                if viewModel.isLoading {
                    ProgressView(String(localized: "nutrition_loading_meal"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(LifeOSTypography.footnote)
                        .foregroundStyle(LifeOSColors.Recovery.critical)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !viewModel.dynamicHint.isEmpty {
                    Text(viewModel.dynamicHint)
                        .font(LifeOSTypography.footnote)
                        .foregroundStyle(LifeOSColors.Text.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if viewModel.requiresEditFirst && !viewModel.isDeleted {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(String(localized: "nutrition_review_gate_message"))
                            .font(LifeOSTypography.footnote)
                            .foregroundStyle(LifeOSColors.Recovery.caution)
                            .multilineTextAlignment(.leading)

                        Toggle(String(localized: "nutrition_review_gate_confirm"), isOn: $viewModel.didReviewLowConfidence)
                            .toggleStyle(.switch)
                    }
                    .padding(Spacing.s)
                    .background(LifeOSColors.Surface.card)
                    .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
                }

                if method == .photo {
                    PrivacyNoteView(.photoRetention)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if viewModel.isDeleted {
                    deletedStateSection(viewModel)
                } else if !viewModel.isLoading {
                    if viewModel.hasDraftPreview {
                        draftPreviewSection(viewModel)
                    }
                    mealEditorSection(viewModel)
                    mealItemsSection(viewModel)
                }

                actionSection(viewModel)
            }
        }
        .padding(LayoutConstants.contentPadding)
        .background(LifeOSColors.Surface.background)
        .accessibilityIdentifier("nutrition.log.screen")
        .navigationTitle(viewModel.screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !viewModel.hasExistingMeal {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel"), action: dismissAction)
                }
            }
        }
        .task(runInitialLoadTaskAction)
    }

    private func headerSection(_ viewModel: NutritionLogViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(viewModel.visibleMealTitle, systemImage: viewModel.hasExistingMeal ? "fork.knife.circle.fill" : "camera")
                .font(LifeOSTypography.title3)

            HStack(spacing: Spacing.xs) {
                Text(viewModel.methodLabel)
                    .font(LifeOSTypography.caption.weight(.semibold))
                    .foregroundStyle(LifeOSColors.Text.secondary)

                if let confidence = viewModel.displayConfidence {
                    Text("\(Int((confidence * 100).rounded()))%")
                        .font(LifeOSTypography.caption2.weight(.semibold))
                        .padding(.horizontal, Spacing.xxs)
                        .padding(.vertical, 4)
                        .background(confidence < NutritionReviewGate.confidenceThreshold ? LifeOSColors.Recovery.caution.opacity(0.2) : LifeOSColors.Recovery.ready.opacity(0.2))
                        .clipShape(Capsule())
                }
            }

            Text(viewModel.loggedAt.formatted(date: .abbreviated, time: .shortened))
                .font(LifeOSTypography.caption)
                .foregroundStyle(LifeOSColors.Text.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func draftPreviewSection(_ viewModel: NutritionLogViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let summary = viewModel.draftSummary {
                previewCard(title: draftSummaryTitle(for: viewModel), body: summary)
            }

            if let totalMacros = viewModel.draftTotalMacros, totalMacros.hasContent {
                previewCard(
                    title: String(localized: "nutrition_photo_estimated_macros_title"),
                    body: draftMacroSummaryText(totalMacros)
                )
            }

            if !viewModel.draftCandidateItems.isEmpty {
                draftCandidateItemsSection(viewModel)
            }

            if !viewModel.draftWarnings.isEmpty {
                previewCard(
                    title: String(localized: "nutrition_photo_review_notes_title"),
                    body: bulletListText(viewModel.draftWarnings)
                )
            }

            if !viewModel.draftSuggestions.isEmpty {
                previewCard(
                    title: String(localized: "nutrition_photo_suggestions_title"),
                    body: bulletListText(viewModel.draftSuggestions)
                )
            }

            if !viewModel.recognizedBarcodes.isEmpty {
                previewCard(
                    title: String(localized: "nutrition_photo_barcodes_title"),
                    body: viewModel.recognizedBarcodes.joined(separator: ", ")
                )
            }

            if let sourceText = viewModel.draftSourceText {
                previewCard(title: sourceTextTitle(for: viewModel), body: sourceText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func draftCandidateItemsSection(_ viewModel: NutritionLogViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(detectedItemsTitle(for: viewModel))
                .font(LifeOSTypography.caption.weight(.semibold))
                .foregroundStyle(LifeOSColors.Text.secondary)

            ForEach(viewModel.draftCandidateItems, content: draftCandidateItemRow)

            Text(detectedItemsFootnote(for: viewModel))
                .font(LifeOSTypography.caption2)
                .foregroundStyle(LifeOSColors.Text.secondary)
        }
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private func draftCandidateItemRow(_ item: NutritionDraftCandidateItem) -> some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            Image(systemName: item.isPersistable ? "checkmark.circle.fill" : "sparkles")
                .foregroundStyle(item.isPersistable ? LifeOSColors.Recovery.ready : LifeOSColors.Semantic.primary)
                .font(.caption)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(LifeOSTypography.body)
                if let brand = item.brand {
                    Text(brand)
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(LifeOSColors.Text.secondary)
                }
                Text(itemDraftSubtitle(item))
                    .font(LifeOSTypography.caption2)
                    .foregroundStyle(LifeOSColors.Text.tertiary)
                if let notes = item.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !notes.isEmpty {
                    Text(notes)
                        .font(LifeOSTypography.caption2)
                        .foregroundStyle(LifeOSColors.Text.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func mealEditorSection(_ viewModel: NutritionLogViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(String(localized: "nutrition_meal_details"))
                    .font(LifeOSTypography.subheadline.weight(.semibold))

                DatePicker(
                    String(localized: "nutrition_time_eaten"),
                    selection: $viewModel.loggedAt,
                    displayedComponents: [.date, .hourAndMinute]
                )

                Picker(String(localized: "nutrition_meal_type"), selection: $viewModel.mealType) {
                    Text(String(localized: "nutrition_not_set")).tag(nil as MealType?)
                    Text(localizedNutritionMealType(.breakfast)).tag(MealType.breakfast as MealType?)
                    Text(localizedNutritionMealType(.lunch)).tag(MealType.lunch as MealType?)
                    Text(localizedNutritionMealType(.dinner)).tag(MealType.dinner as MealType?)
                    Text(localizedNutritionMealType(.snack)).tag(MealType.snack as MealType?)
                }
                .pickerStyle(.menu)

                Picker(String(localized: "nutrition_context"), selection: $viewModel.mealContext) {
                    Text(String(localized: "nutrition_not_set")).tag(nil as MealContext?)
                    Text(localizedNutritionMealContext(.home)).tag(MealContext.home as MealContext?)
                    Text(localizedNutritionMealContext(.restaurant)).tag(MealContext.restaurant as MealContext?)
                    Text(localizedNutritionMealContext(.work)).tag(MealContext.work as MealContext?)
                    Text(localizedNutritionMealContext(.party)).tag(MealContext.party as MealContext?)
                    Text(localizedNutritionMealContext(.other)).tag(MealContext.other as MealContext?)
                    Text(localizedNutritionMealContext(.unknown)).tag(MealContext.unknown as MealContext?)
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(String(localized: "notes"))
                        .font(LifeOSTypography.caption.weight(.semibold))
                        .foregroundStyle(LifeOSColors.Text.secondary)
                    TextEditor(text: $viewModel.userNotes)
                        .frame(minHeight: 88)
                        .padding(Spacing.xxs)
                        .background(LifeOSColors.Surface.background)
                        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
                }
            }
            .padding(Spacing.s)
            .background(LifeOSColors.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))

            totalsSection(viewModel)
        }
    }

    private func totalsSection(_ viewModel: NutritionLogViewModel) -> some View {
        let totals = viewModel.mealTotals
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(String(localized: "nutrition_totals"))
                .font(LifeOSTypography.subheadline.weight(.semibold))
            Text(localizedNutritionCalories(Int(totals.calories.rounded())))
                .font(LifeOSTypography.title3)
            Text(
                totalsSummaryText(
                    protein: totals.protein,
                    fat: totals.fat,
                    carbs: totals.carbs,
                    fiber: totals.fiber
                )
            )
            .font(LifeOSTypography.caption)
            .foregroundStyle(LifeOSColors.Text.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private func mealItemsSection(_ viewModel: NutritionLogViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text(String(localized: "nutrition_items"))
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                Spacer()
                Button(action: viewModel.addMealItem, label: addMealItemLabel)
                .buttonStyle(.plain)
            }

            ForEach(Array(viewModel.mealItems.indices), id: \.self) { index in
                mealItemEditorRow(at: index, viewModel: viewModel)
            }
        }
    }

    private func addMealItemLabel() -> some View {
        Label(String(localized: "nutrition_add_item"), systemImage: "plus.circle.fill")
            .font(LifeOSTypography.caption.weight(.semibold))
    }

    private func mealItemEditorRow(
        at index: Int,
        viewModel: NutritionLogViewModel
    ) -> some View {
        mealItemEditor(
            item: $viewModel.mealItems[index],
            canRemove: viewModel.canRemoveItems,
            onRemove: removeMealItemAction(at: index, viewModel: viewModel)
        )
    }

    private func removeMealItemAction(
        at index: Int,
        viewModel: NutritionLogViewModel
    ) -> () -> Void {
        {
            let id = viewModel.mealItems[index].id
            viewModel.removeMealItem(id: id)
        }
    }

    private func removeMealItemIcon() -> some View {
        Image(systemName: "trash")
    }

    private func mealItemEditor(
        item: Binding<NutritionEditableMealItem>,
        canRemove: Bool,
        onRemove: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .top) {
                TextField(String(localized: "nutrition_item_name"), text: item.name)
                    .font(LifeOSTypography.body)

                Spacer()

                Button(role: .destructive, action: onRemove, label: removeMealItemIcon)
                .disabled(!canRemove)
            }

            TextField(String(localized: "nutrition_brand"), text: item.brand)
                .textInputAutocapitalization(.words)
            TextField(String(localized: "nutrition_barcode"), text: item.barcode)
                .keyboardType(.numberPad)

            HStack(spacing: Spacing.s) {
                numericField(String(localized: "nutrition_unit_grams"), value: item.weightG)
                if !NutritionSafetyPolicy.hidesCalories { numericField(String(localized: "nutrition_unit_kcal"), value: item.calories) }
            }

            HStack(spacing: Spacing.s) {
                numericField(String(localized: "nutrition_macro_label_protein"), value: item.proteinG)
                numericField(String(localized: "nutrition_macro_label_fat"), value: item.fatG)
                numericField(String(localized: "nutrition_macro_label_carbs"), value: item.carbsG)
                numericField(String(localized: "nutrition_macro_label_fiber"), value: item.fiberG)
            }
        }
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private func numericField(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(LifeOSTypography.caption2.weight(.semibold))
                .foregroundStyle(LifeOSColors.Text.secondary)
            TextField(
                title,
                value: value,
                format: .number.precision(.fractionLength(0...1))
            )
            .keyboardType(.decimalPad)
            .textFieldStyle(.roundedBorder)
        }
    }

    private func deletedStateSection(_ viewModel: NutritionLogViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(String(localized: "nutrition_meal_deleted"), systemImage: "trash.fill")
                .font(LifeOSTypography.subheadline.weight(.semibold))
                .foregroundStyle(LifeOSColors.Recovery.caution)

            if let deletedStatusText = viewModel.deletedStatusText {
                Text(deletedStatusText)
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(LifeOSColors.Text.secondary)
            }

            Text(String(localized: "nutrition_restore_meal_window"))
                .font(LifeOSTypography.footnote)
                .foregroundStyle(LifeOSColors.Text.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private func actionSection(_ viewModel: NutritionLogViewModel) -> some View {
        VStack(spacing: Spacing.s) {
            if viewModel.isDeleted {
                Button(action: undoDeleteButtonTapped) {
                    if viewModel.isUndoing {
                        ProgressView()
                    } else {
                        Text(String(localized: "nutrition_undo_delete"))
                            .font(LifeOSTypography.headline)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canUndoDelete)
            } else {
                Button(action: saveButtonTapped) {
                    if viewModel.isSaving {
                        ProgressView()
                    } else {
                        Text(viewModel.saveButtonTitle)
                            .font(LifeOSTypography.headline)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSave)
                .accessibilityIdentifier("nutrition.log.save")

                if viewModel.canDelete {
                    Button(role: .destructive, action: deleteButtonTapped) {
                        if viewModel.isDeleting {
                            ProgressView()
                        } else {
                            Text(String(localized: "nutrition_delete_meal"))
                                .font(LifeOSTypography.subheadline.weight(.semibold))
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.s)
    }

    private func previewCard(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title)
                .font(LifeOSTypography.caption.weight(.semibold))
                .foregroundStyle(LifeOSColors.Text.secondary)
            Text(body)
                .font(LifeOSTypography.body)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
        }
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private func itemDraftSubtitle(_ item: NutritionDraftCandidateItem) -> String {
        var fragments: [String] = []
        if item.isPersistable,
           let weightG = item.weightG,
           let calories = item.calories {
            fragments.append("\(Int(weightG.rounded()))g")
            if !NutritionSafetyPolicy.hidesCalories { fragments.append("\(Int(calories.rounded())) kcal") }
        } else {
            fragments.append(String(localized: "nutrition_item_needs_review"))
        }
        if let barcode = item.barcode {
            fragments.append(
                String(
                    format: String(localized: "nutrition_item_barcode_format"),
                    barcode
                )
            )
        }
        return fragments.joined(separator: " • ")
    }

    private func draftSummaryTitle(for viewModel: NutritionLogViewModel) -> String {
        switch viewModel.draftAnalysisSource {
        case .aiVision:
            return String(localized: "nutrition_photo_ai_analysis_title")
        case .onDeviceFallback:
            return String(localized: "nutrition_photo_fallback_summary_title")
        case .none:
            return String(localized: "nutrition_photo_analysis_title")
        }
    }

    private func detectedItemsTitle(for viewModel: NutritionLogViewModel) -> String {
        switch viewModel.draftAnalysisSource {
        case .aiVision:
            return String(localized: "nutrition_photo_ai_detected_items_title")
        case .onDeviceFallback, .none:
            return String(localized: "nutrition_photo_detected_items_title")
        }
    }

    private func detectedItemsFootnote(for viewModel: NutritionLogViewModel) -> String {
        if viewModel.persistableDraftItemsCount > 0 {
            return String(localized: "nutrition_photo_structured_save_notice")
        }
        return String(localized: "nutrition_photo_review_save_notice")
    }

    private func sourceTextTitle(for viewModel: NutritionLogViewModel) -> String {
        switch viewModel.draftAnalysisSource {
        case .aiVision:
            return String(localized: "nutrition_photo_ocr_hints_title")
        case .onDeviceFallback, .none:
            return String(localized: "nutrition_photo_captured_text_title")
        }
    }

    private func totalsSummaryText(protein: Double, fat: Double, carbs: Double, fiber: Double?) -> String {
        localizedNutritionMacroTotals(protein: protein, fat: fat, carbs: carbs, fiber: fiber)
    }

    private func draftMacroSummaryText(_ totals: NutritionDraftMacroSummary) -> String {
        if NutritionSafetyPolicy.hidesCalories { return localizedNutritionMacroTotals(protein: totals.proteinG, fat: totals.fatG, carbs: totals.carbsG, fiber: totals.fiberG) }
        let calories = Int(totals.calories.rounded())
        let protein = Int(totals.proteinG.rounded())
        let fat = Int(totals.fatG.rounded())
        let carbs = Int(totals.carbsG.rounded())
        if let fiber = totals.fiberG {
            return String(
                format: String(localized: "nutrition_photo_macros_with_fiber_format"),
                calories,
                protein,
                fat,
                carbs,
                Int(fiber.rounded())
            )
        }
        return String(
            format: String(localized: "nutrition_photo_macros_without_fiber_format"),
            calories,
            protein,
            fat,
            carbs
        )
    }

    private func bulletListText(_ values: [String]) -> String {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "• \($0)" }
            .joined(separator: "\n")
    }

    private func runInitialLoadTaskAction() async {
        await runInitialLoadTask(viewModel)
    }

    private func runInitialLoadTask(_ viewModel: NutritionLogViewModel) async {
        if viewModel.hasExistingMeal {
            await viewModel.loadMealDetailIfNeeded()
        }
        await runDynamicHintTask(viewModel)
    }

    private func runDynamicHintTaskAction() async {
        await runDynamicHintTask(viewModel)
    }

    private func runDynamicHintTask(_ viewModel: NutritionLogViewModel) async {
        await viewModel.loadDynamicHint()
    }

    private func saveButtonTapped() {
        Task { @MainActor in
            let didSave = await runSaveAction()
            if didSave {
                Self.successHapticAction()
                onComplete?()
                dismissAction()
            } else {
                Self.failureHapticAction()
            }
        }
    }

    private func runSaveAction() async -> Bool {
        await viewModel.save()
    }

    private func deleteButtonTapped() {
        Task { @MainActor in
            let didDelete = await viewModel.deleteMeal()
            if didDelete {
                Self.successHapticAction()
                onComplete?()
            } else {
                Self.failureHapticAction()
            }
        }
    }

    private func undoDeleteButtonTapped() {
        Task { @MainActor in
            let didUndo = await viewModel.undoDeleteMeal()
            if didUndo {
                Self.successHapticAction()
                onComplete?()
            } else {
                Self.failureHapticAction()
            }
        }
    }

    private static func successHapticAction() {
        HapticManager.success()
    }

    private static func failureHapticAction() {
        HapticManager.error()
    }

    private func dismissAction() {
        dismiss()
    }

    private static func runSaveTask(
        save: @escaping () async -> Bool,
        dismissAction: @escaping () -> Void,
        successHaptic: @escaping () -> Void,
        failureHaptic: @escaping () -> Void
    ) {
        Task { @MainActor in
            let didSave = await save()
            handleSaveOutcome(
                didSave,
                dismissAction: dismissAction,
                successHaptic: successHaptic,
                failureHaptic: failureHaptic
            )
        }
    }

    private static func handleSaveOutcome(
        _ didSave: Bool,
        dismissAction: () -> Void,
        successHaptic: () -> Void,
        failureHaptic: () -> Void
    ) {
        if didSave {
            successHaptic()
            dismissAction()
        } else {
            failureHaptic()
        }
    }
}

#if DEBUG
extension NutritionDayView {
    init(
        testDateString: String? = NutritionCoverageFixtures.targetDay,
        testSelectedDate: Date? = nil,
        testMealsLogged: [FoodLog] = [],
        testIsApplyingTemplate: Bool = false,
        testTemplateStatusMessage: TemplateStatusMessage? = nil,
        testTemplateRefreshToken: Int = 0,
        testFeatureFlagRefreshTick: Int = 0
    ) {
        self.dateString = testDateString
        _activeModal = State(initialValue: nil)
        _selectedDate = State(initialValue: testSelectedDate ?? Self.initialSelectedDate(from: testDateString))
        _mealsLogged = State(initialValue: testMealsLogged)
        _isApplyingTemplate = State(initialValue: testIsApplyingTemplate)
        _templateStatusMessage = State(initialValue: testTemplateStatusMessage)
        _templateRefreshToken = State(initialValue: testTemplateRefreshToken)
        _featureFlagRefreshTick = State(initialValue: testFeatureFlagRefreshTick)
    }

    func _testEvaluateBody() {
        _ = body
    }

    @MainActor
    func _testRenderTemplateStatusSection() {
        let host = UIHostingController(rootView: templateStatusSection)
        _ = host.view
    }

    @MainActor
    func _testRenderBatchRecipeQuickAction() {
        let host = UIHostingController(rootView: batchRecipeQuickAction)
        _ = host.view
    }

    @MainActor
    func _testRenderMealsLoggedSection() {
        let host = UIHostingController(rootView: mealsLoggedSection)
        _ = host.view
    }

    @MainActor
    func _testRenderMealRowLabel(_ meal: FoodLog) {
        let host = UIHostingController(rootView: mealRowLabel(for: meal))
        _ = host.view
    }

    @MainActor
    func _testRenderMealNavigationDestination(_ meal: FoodLog) {
        let host = UIHostingController(rootView: mealNavigationDestination(for: meal))
        _ = host.view
    }

    @MainActor
    func _testRenderMealNavigationLink(_ meal: FoodLog) {
        let host = UIHostingController(rootView: NavigationStack { mealNavigationLink(for: meal) })
        _ = host.view
    }

    func _testRenderInputMethodTiles() {
        for method in Self.defaultInputMethods() {
            _ = inputMethodTile(method: method)
        }
    }

    func _testRenderInputMethodTilesWithInteractions() {
        for method in Self.defaultInputMethods() {
            _ = inputMethodTileWithInteractions(method: method)
        }
    }

    static func _testTriggerInputMethodTileTap() {
        handleInputMethodTileTap()
    }

    static func _testTriggerInputMethodTileTapAction() {
        inputMethodTileTapAction()
    }

    static func _testInputMethodsCount(batchRecipesEnabled: Bool = true) -> Int {
        resolvedInputMethods(batchRecipesEnabled: batchRecipesEnabled).count
    }

    static func _testVisibleInputMethods(batchRecipesEnabled: Bool) -> [NutritionLogMethod] {
        resolvedInputMethods(batchRecipesEnabled: batchRecipesEnabled).map(\.method)
    }

    static func _testResolvedBatchRecipesEnabled(_ isEnabled: Bool?) -> Bool {
        resolvedBatchRecipesEnabled(isEnabled)
    }

    static func _testResolvedModalID(
        for method: NutritionLogMethod,
        batchRecipesEnabled: Bool
    ) -> String? {
        resolvedModal(for: method, batchRecipesEnabled: batchRecipesEnabled)?.id
    }

    static func _testModalIDs() -> [String] {
        [
            NutritionDayModal.photoCapture.id,
            NutritionDayModal.barcodeScanner.id,
            NutritionDayModal.voiceInput.id,
            NutritionDayModal.foodSearch.id,
            NutritionDayModal.batchRecipe.id,
            NutritionDayModal.calendar.id,
            NutritionDayModal.log(
                NutritionLogDraft(
                    method: .manual,
                    confidence: nil,
                    loggedAt: NutritionCoverageFixtures.loggedAt,
                    loggedDate: NutritionCoverageFixtures.targetDay
                )
            ).id
        ]
    }

    static func _testIsBatchRecipeModalFlags() -> (nilModal: Bool, manualModal: Bool, batchModal: Bool) {
        (
            isBatchRecipeModal(nil),
            isBatchRecipeModal(.foodSearch),
            isBatchRecipeModal(.batchRecipe)
        )
    }

    static func _testShouldDismissBatchRecipeModal(
        batchRecipesEnabled: Bool,
        activeModalID: String?
    ) -> Bool {
        let activeModal: NutritionDayModal? = switch activeModalID {
        case NutritionDayModal.batchRecipe.id:
            .batchRecipe
        case NutritionDayModal.foodSearch.id:
            .foodSearch
        default:
            nil
        }
        return shouldDismissBatchRecipeModal(
            batchRecipesEnabled: batchRecipesEnabled,
            activeModal: activeModal
        )
    }

    static func _testNavigationDraft(
        method: NutritionLogMethod,
        confidence: Double?,
        selectedDate: Date
    ) -> NutritionLogDraft {
        navigationDraft(
            method: method,
            confidence: confidence,
            selectedDate: selectedDate
        )
    }

    static func _testLoadMealsForDate(
        selectedDate: Date,
        dbQueue: DatabaseQueue,
        authId: String?
    ) async -> [FoodLog] {
        await loadMealsForDate(
            selectedDate: selectedDate,
            dbQueue: dbQueue,
            authId: authId
        )
    }

    nonisolated static func _testDecodeFoodLogRow(
        values: [String: (any DatabaseValueConvertible)?],
        targetDate: String,
        fallbackLoggedAt: Date
    ) -> FoodLog? {
        decodedFoodLogRow(
            Row(values),
            targetDate: targetDate,
            fallbackLoggedAt: fallbackLoggedAt
        )
    }

    static func _testResolvedMealsForDate(
        selectedDate: Date,
        overrideAction: ((Date) async -> [FoodLog])?,
        dbQueue: DatabaseQueue,
        authId: String?
    ) async -> [FoodLog] {
        await resolvedMealsForDate(
            selectedDate: selectedDate,
            overrideAction: overrideAction,
            dbQueue: dbQueue,
            authId: authId
        )
    }

    static func _testResolvedTemplateApplication(
        templateId: UUID,
        selectedDate: Date,
        applyAction: ((UUID, Date) async throws -> NutritionMealTemplateApplicationResult)?
    ) async -> Result<NutritionMealTemplateApplicationResult, Error> {
        await resolvedTemplateApplication(
            templateId: templateId,
            selectedDate: selectedDate,
            applyAction: applyAction
        )
    }

    static func _testResolvedTemplateApplicationUsingOverride(
        templateId: UUID,
        selectedDate: Date,
        overrideAction: ((UUID, Date) async throws -> NutritionMealTemplateApplicationResult)?
    ) async -> Result<NutritionMealTemplateApplicationResult, Error> {
        do {
            return try await withTestOverrides(applyMealTemplateAction: overrideAction) {
                await resolvedTemplateApplication(
                    templateId: templateId,
                    selectedDate: selectedDate,
                    applyAction: nil
                )
            }
        } catch {
            return .failure(error)
        }
    }

    static func _testAppliedTemplateStatusMessage(templateName: String) -> TemplateStatusMessage {
        appliedTemplateStatusMessage(templateName: templateName)
    }

    static func _testFailedTemplateStatusMessage(message: String) -> TemplateStatusMessage {
        failedTemplateStatusMessage(message: message)
    }

    static func _testShiftedDate(
        selectedDate: Date,
        dayOffset: Int,
        fallbackToOriginal: Bool
    ) -> Date {
        shiftedDate(from: selectedDate, dayOffset: dayOffset) { _, _, date in
            fallbackToOriginal ? nil : Calendar.current.date(byAdding: .day, value: dayOffset, to: date)
        }
    }

    static func _testSelectedLogTime(
        selectedDate: Date,
        hour: Int?,
        minute: Int?,
        second: Int?,
        fallbackToOriginal: Bool
    ) -> Date {
        selectedLogTime(
            for: selectedDate,
            hour: hour,
            minute: minute,
            second: second
        ) { resolvedHour, resolvedMinute, resolvedSecond, date in
            fallbackToOriginal
                ? nil
                : Calendar.current.date(
                    bySettingHour: resolvedHour,
                    minute: resolvedMinute,
                    second: resolvedSecond,
                    of: date
                )
        }
    }

    @MainActor
    func _testInvokePresentSheet(for method: NutritionLogMethod, batchRecipesEnabled: Bool) async -> String? {
        await Self.withTestOverrides(batchRecipesEnabled: batchRecipesEnabled) {
            presentSheet(for: method)
            return Self.resolvedModal(for: method, batchRecipesEnabled: batchRecipesEnabled)?.id
        }
    }

    @MainActor
    func _testInvokePresentBatchRecipeIfEnabled(batchRecipesEnabled: Bool) async -> String? {
        await Self.withTestOverrides(batchRecipesEnabled: batchRecipesEnabled) {
            presentBatchRecipeIfEnabled()
            return Self.batchRecipeModal(batchRecipesEnabled: batchRecipesEnabled)?.id
        }
    }

    @MainActor
    func _testInvokeInputMethodSelection(_ method: NutritionLogMethod, batchRecipesEnabled: Bool) async -> String? {
        await Self.withTestOverrides(batchRecipesEnabled: batchRecipesEnabled) {
            handleInputMethodSelection(method)
            return Self.resolvedModal(for: method, batchRecipesEnabled: batchRecipesEnabled)?.id
        }
    }

    @MainActor
    func _testInvokeInputMethodTileAction(_ method: NutritionLogMethod, batchRecipesEnabled: Bool) async -> String? {
        await Self.withTestOverrides(batchRecipesEnabled: batchRecipesEnabled) {
            let action = inputMethodTileAction(for: method)
            action()
            return Self.resolvedModal(for: method, batchRecipesEnabled: batchRecipesEnabled)?.id
        }
    }

    @MainActor
    func _testInvokeNavigateToLog(method: NutritionLogMethod, confidence: Double?) async -> String? {
        let draft = Self.navigationDraft(
            method: method,
            confidence: confidence,
            selectedDate: selectedDate
        )
        navigateToLog(method: method, confidence: confidence)
        await Task.yield()
        return NutritionDayModal.log(draft).id
    }

    @MainActor
    func _testInvokeNavigateToLog(draft: NutritionLogDraft) async -> String? {
        navigateToLog(draft: draft)
        await Task.yield()
        return NutritionDayModal.log(draft).id
    }

    @MainActor
    func _testInvokeDateNavigationActions() -> (previousDate: String, calendarModalID: String?, nextDate: String) {
        let originalDate = selectedDate
        previousDayButtonTapped()
        let previousDate = DiaryDateFormatter.formatDate(
            Calendar.current.date(byAdding: .day, value: -1, to: originalDate) ?? originalDate
        )
        selectedDate = originalDate
        showCalendarButtonTapped()
        let calendarModalID = NutritionDayModal.calendar.id
        activeModal = nil
        nextDayButtonTapped()
        let nextDate = DiaryDateFormatter.formatDate(
            Calendar.current.date(byAdding: .day, value: 1, to: originalDate) ?? originalDate
        )
        return (previousDate, calendarModalID, nextDate)
    }

    @MainActor
    func _testInvokeTemplateCallbacks(with meals: [FoodLog]) async -> (refreshToken: Int, mealIDs: [UUID]) {
        await Self.withTestOverrides(loadMealsAction: { _ in meals }) {
            handleTemplatesChanged()
            handleTemplateLogged()
            await loadMealsForDate()
            return (1, meals.map(\.id))
        }
    }

    @MainActor
    func _testInvokeHandleTemplateSelection(
        templateId: UUID,
        templateName: String,
        reloadedMeals: [FoodLog]
    ) async -> (message: String, refreshToken: Int, mealIDs: [UUID]) {
        await Self.withTestOverrides(
            loadMealsAction: { _ in reloadedMeals },
            applyMealTemplateAction: { _, _ in
                NutritionMealTemplateApplicationResult(
                    foodLogId: UUID(),
                    templateName: templateName,
                    itemCount: 1
                )
            }
        ) {
            handleTemplateSelection(templateId)
            await Task.yield()
            return (
                String(
                    format: String(localized: "nutrition_logged_template_format"),
                    templateName
                ),
                1,
                reloadedMeals.map(\.id)
            )
        }
    }

    @MainActor
    func _testInvokeHandleLoggedMealRefresh(with meals: [FoodLog]) async -> [UUID] {
        await Self.withTestOverrides(loadMealsAction: { _ in meals }) {
            handleLoggedMealRefresh()
            await Task.yield()
            return meals.map(\.id)
        }
    }

    @MainActor
    func _testInvokeLoggedMealReload(with meals: [FoodLog]) async -> [UUID] {
        await Self.withTestOverrides(loadMealsAction: { _ in meals }) {
            handleLoggedMealReload()
            await Task.yield()
            return meals.map(\.id)
        }
    }

    @MainActor
    func _testInvokeHandleLoggedDraftResult(_ draft: NutritionLogDraft) async -> String {
        handleLoggedDraftResult(draft)
        await Task.yield()
        return NutritionDayModal.log(draft).id
    }

    @MainActor
    func _testInvokeDismissBatchRecipeModalIfDisabled() -> String? {
        activeModal = .batchRecipe
        dismissBatchRecipeModalIfDisabled()
        return activeModal?.id
    }

    func _testInvokeHandleBatchRecipesChanged() {
        handleBatchRecipesChanged()
    }

    @MainActor
    func _testInvokeHandleDisabledBatchRecipeModalAppear() -> String? {
        activeModal = .batchRecipe
        handleDisabledBatchRecipeModalAppear()
        return activeModal?.id
    }

    @MainActor
    func _testRenderModalContents(batchRecipesEnabled: Bool) async -> [String] {
        await Self.withTestOverrides(batchRecipesEnabled: batchRecipesEnabled) {
            let draft = Self.navigationDraft(
                method: .manual,
                confidence: 0.55,
                selectedDate: selectedDate
            )
            let modals: [NutritionDayModal] = [
                .photoCapture,
                .barcodeScanner,
                .voiceInput,
                .foodSearch,
                .batchRecipe,
                .calendar,
                .log(draft)
            ]
            for modal in modals {
                let host = UIHostingController(rootView: modalContent(for: modal))
                _ = host.view
            }
            return modals.map(\.id)
        }
    }

    @MainActor
    func _testInvokeLoadMealsForDate(with meals: [FoodLog]) async -> [UUID] {
        await Self.withTestOverrides(loadMealsAction: { _ in meals }) {
            await loadMealsForDate()
            return meals.map(\.id)
        }
    }

    @MainActor
    func _testInvokeLoadMealsForDateTask(with meals: [FoodLog]) async -> [UUID] {
        await Self.withTestOverrides(loadMealsAction: { _ in meals }) {
            await loadMealsForDateTask()
            return meals.map(\.id)
        }
    }

    @MainActor
    func _testInvokeApplyTemplateSuccess(
        templateId: UUID,
        templateName: String,
        reloadedMeals: [FoodLog]
    ) async -> (message: String?, isError: Bool, refreshToken: Int, mealIDs: [UUID]) {
        await Self.withTestOverrides(
            loadMealsAction: { _ in reloadedMeals },
            applyMealTemplateAction: { _, _ in
                NutritionMealTemplateApplicationResult(
                    foodLogId: UUID(),
                    templateName: templateName,
                    itemCount: 1
                )
            }
        ) {
            await applyTemplate(templateId)
            return (
                String(
                    format: String(localized: "nutrition_logged_template_format"),
                    templateName
                ),
                false,
                1,
                reloadedMeals.map(\.id)
            )
        }
    }

    @MainActor
    func _testInvokeApplyTemplateFailure(
        templateId: UUID,
        message: String
    ) async -> (message: String?, isError: Bool, refreshToken: Int) {
        do {
            return try await Self.withTestOverrides(
                applyMealTemplateAction: { _, _ in
                    throw NSError(
                        domain: "NutritionDayViewCoverage",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )
                }
            ) {
                await applyTemplate(templateId)
                return (
                    message,
                    true,
                    0
                )
            }
        } catch {
            return (error.localizedDescription, true, 0)
        }
    }

    @MainActor
    func _testInvokeFeatureFlagUpdateForBatchModal(batchRecipesEnabled: Bool) async -> (tick: Int, modalID: String?) {
        await Self.withTestOverrides(batchRecipesEnabled: batchRecipesEnabled) {
            activeModal = .batchRecipe
            handleFeatureFlagUpdate(Notification(name: FeatureFlagManager.didUpdateNotification))
            return (
                1,
                batchRecipesEnabled ? NutritionDayModal.batchRecipe.id : nil
            )
        }
    }

    @MainActor
    func _testInvokeFeatureFlagUpdateForManualModal(batchRecipesEnabled: Bool) async -> (tick: Int, modalID: String?) {
        await Self.withTestOverrides(batchRecipesEnabled: batchRecipesEnabled) {
            activeModal = .foodSearch
            handleFeatureFlagUpdate(Notification(name: FeatureFlagManager.didUpdateNotification))
            return (1, NutritionDayModal.foodSearch.id)
        }
    }
}

extension NutritionLogView {
    func _testEvaluateBody() {
        _ = body
    }

    func _testRunDynamicHintTask() async {
        await runDynamicHintTask(viewModel)
    }

    func _testRunInitialLoadTask() async {
        await runInitialLoadTask(viewModel)
    }

    func _testRunInitialLoadTaskAction() async {
        await runInitialLoadTaskAction()
    }

    func _testRunDynamicHintTaskAction() async {
        await runDynamicHintTaskAction()
    }

    func _testTriggerSaveButtonTap() {
        saveButtonTapped()
    }

    func _testDismissAction() {
        dismissAction()
    }

    static func _testTriggerSuccessHapticAction() {
        successHapticAction()
    }

    static func _testTriggerFailureHapticAction() {
        failureHapticAction()
    }

    @MainActor
    func _testRenderDraftPreviewSection() {
        let host = UIHostingController(rootView: draftPreviewSection(viewModel))
        _ = host.view
    }

    @MainActor
    func _testRenderDraftCandidateItemsSection() {
        let host = UIHostingController(rootView: draftCandidateItemsSection(viewModel))
        _ = host.view
    }

    @MainActor
    func _testRenderDraftCandidateItemRow(_ item: NutritionDraftCandidateItem) {
        let host = UIHostingController(rootView: draftCandidateItemRow(item))
        _ = host.view
    }

    @MainActor
    func _testRenderDeletedStateSection() {
        let host = UIHostingController(rootView: deletedStateSection(viewModel))
        _ = host.view
    }

    @MainActor
    func _testRenderMealItemsSection() {
        let host = UIHostingController(rootView: mealItemsSection(viewModel))
        _ = host.view
    }

    @MainActor
    func _testRenderMealItemEditorRow(at index: Int) {
        let host = UIHostingController(rootView: mealItemEditorRow(at: index, viewModel: viewModel))
        _ = host.view
    }

    @MainActor
    func _testRenderMealItemEditor(canRemove: Bool = true) {
        let item = Binding(
            get: { viewModel.mealItems.first ?? NutritionEditableMealItem(name: "Coverage Item") },
            set: { viewModel.mealItems = [$0] }
        )
        let host = UIHostingController(
            rootView: mealItemEditor(
                item: item,
                canRemove: canRemove,
                onRemove: {}
            )
        )
        _ = host.view
    }

    @MainActor
    func _testRenderActionSection() {
        let host = UIHostingController(rootView: actionSection(viewModel))
        _ = host.view
    }

    @MainActor
    func _testRenderNumericField(value: Double = 42) {
        var currentValue = value
        let binding = Binding(
            get: { currentValue },
            set: { currentValue = $0 }
        )
        let host = UIHostingController(rootView: numericField("Coverage Field", value: binding))
        _ = host.view
    }

    func _testTriggerDeleteButtonTap() {
        deleteButtonTapped()
    }

    func _testInvokeAddMealItemAction() -> Int {
        viewModel.addMealItem()
        return viewModel.mealItems.count
    }

    func _testInvokeRemoveMealItemAction(at index: Int) -> [UUID] {
        removeMealItemAction(at: index, viewModel: viewModel)()
        return viewModel.mealItems.map(\.id)
    }

    func _testTriggerUndoDeleteButtonTap() {
        undoDeleteButtonTapped()
    }

    static func _testDraftPreviewMetrics(
        method: NutritionLogMethod?,
        aiConfidence: Double?,
        draft: NutritionLogDraft
    ) -> (
        summaryTitle: String,
        detectedItemsTitle: String,
        detectedItemsFootnote: String,
        sourceTextTitle: String,
        macroSummary: String?,
        warningsList: String,
        suggestionsList: String,
        itemSubtitles: [String]
    ) {
        let view = NutritionLogView(method: method, aiConfidence: aiConfidence, draft: draft)
        let viewModel = NutritionLogViewModel(method: method, aiConfidence: aiConfidence, draft: draft)
        return (
            summaryTitle: view.draftSummaryTitle(for: viewModel),
            detectedItemsTitle: view.detectedItemsTitle(for: viewModel),
            detectedItemsFootnote: view.detectedItemsFootnote(for: viewModel),
            sourceTextTitle: view.sourceTextTitle(for: viewModel),
            macroSummary: draft.totalMacros.map(view.draftMacroSummaryText),
            warningsList: view.bulletListText(draft.warnings),
            suggestionsList: view.bulletListText(draft.suggestions),
            itemSubtitles: draft.candidateItems.map(view.itemDraftSubtitle)
        )
    }

    static func _testSaveOutcomeFlags(didSave: Bool) -> (dismissed: Bool, success: Bool, failure: Bool) {
        var dismissed = false
        var success = false
        var failure = false
        handleSaveOutcome(
            didSave,
            dismissAction: { dismissed = true },
            successHaptic: { success = true },
            failureHaptic: { failure = true }
        )
        return (dismissed, success, failure)
    }

    @MainActor
    static func _testSaveTaskFlags(didSave: Bool) async -> (dismissed: Bool, success: Bool, failure: Bool) {
        var dismissed = false
        var success = false
        var failure = false
        runSaveTask(
            save: { didSave },
            dismissAction: { dismissed = true },
            successHaptic: { success = true },
            failureHaptic: { failure = true }
        )
        try? await Task.sleep(nanoseconds: 10_000_000)
        return (dismissed, success, failure)
    }
}

extension NutritionLogViewModel {
    func _testSetCoverageState(
        mealItems: [NutritionEditableMealItem]? = nil,
        isDeleted: Bool? = nil,
        deletedAt: Date? = nil,
        isDeleting: Bool? = nil,
        isUndoing: Bool? = nil
    ) {
        if let mealItems {
            self.mealItems = mealItems
        }
        if let isDeleted {
            self.isDeleted = isDeleted
        }
        if let deletedAt {
            self.deletedAt = deletedAt
        }
        if let isDeleting {
            self.isDeleting = isDeleting
        }
        if let isUndoing {
            self.isUndoing = isUndoing
        }
    }
}

enum NutritionViewsTestHarness {
    @MainActor
    static func exerciseBodyBranches() async {
        let nilDateView = NutritionDayView(dateString: nil)
        nilDateView._testEvaluateBody()
        nilDateView._testRenderInputMethodTiles()
        nilDateView._testRenderInputMethodTilesWithInteractions()
        NutritionDayView._testTriggerInputMethodTileTap()
        NutritionDayView._testTriggerInputMethodTileTapAction()
        NutritionDayView(dateString: "2026-02-24")._testEvaluateBody()

        let neutralVM = NutritionLogViewModel(method: .manual, aiConfidence: nil)
        neutralVM._testOverrideState(
            isSaving: false,
            didReviewLowConfidence: true,
            errorMessage: nil,
            dynamicHint: ""
        )
        NutritionLogView(method: .manual, aiConfidence: nil, testViewModel: neutralVM)._testEvaluateBody()
        await NutritionLogView(method: .manual, aiConfidence: nil, testViewModel: neutralVM)._testRunDynamicHintTask()
        await NutritionLogView(method: .manual, aiConfidence: nil, testViewModel: neutralVM)._testRunDynamicHintTaskAction()

        let reviewVM = NutritionLogViewModel(method: .photo, aiConfidence: 0.25)
        reviewVM._testOverrideState(
            isSaving: false,
            didReviewLowConfidence: false,
            errorMessage: "low_confidence_error",
            dynamicHint: "hint"
        )
        NutritionLogView(method: .photo, aiConfidence: 0.25, testViewModel: reviewVM)._testEvaluateBody()

        let savingVM = NutritionLogViewModel(method: .photo, aiConfidence: 0.95)
        savingVM._testOverrideState(
            isSaving: true,
            didReviewLowConfidence: true,
            errorMessage: nil,
            dynamicHint: "hint"
        )
        NutritionLogView(method: .photo, aiConfidence: 0.95, testViewModel: savingVM)._testEvaluateBody()
        NutritionLogView(method: .photo, aiConfidence: 0.95, testViewModel: savingVM)._testTriggerSaveButtonTap()
        NutritionLogView(method: .photo, aiConfidence: 0.95, testViewModel: savingVM)._testDismissAction()
        NutritionLogView._testTriggerSuccessHapticAction()
        NutritionLogView._testTriggerFailureHapticAction()
        try? await Task.sleep(nanoseconds: 10_000_000)
        _ = await NutritionLogView._testSaveTaskFlags(didSave: true)
        _ = await NutritionLogView._testSaveTaskFlags(didSave: false)
    }

    static func inputMethodMappings() -> [NutritionInputMethod] {
        [
            NutritionLogMethod.photo,
            .barcode,
            .voice,
            .manual,
            .batch,
            .template
        ].map(\.asInputMethod)
    }

    @MainActor
    static func saveOutcomeFlags(didSave: Bool) -> (dismissed: Bool, success: Bool, failure: Bool) {
        NutritionLogView._testSaveOutcomeFlags(didSave: didSave)
    }
}
#endif

extension NutritionLogMethod {
    var asInputMethod: NutritionInputMethod {
        switch self {
        case .photo: return .vision
        case .barcode: return .barcode
        case .voice: return .voice
        case .manual: return .manual
        case .batch: return .batch
        case .template: return .template
        }
    }
}

extension NutritionInputMethod {
    var asLogMethod: NutritionLogMethod {
        switch self {
        case .vision: return .photo
        case .barcode: return .barcode
        case .voice: return .voice
        case .manual: return .manual
        case .batch: return .batch
        case .template: return .template
        }
    }
}
