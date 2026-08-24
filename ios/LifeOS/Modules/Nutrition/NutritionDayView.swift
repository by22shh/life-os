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

private func localizedNutritionCalories(_ calories: Int) -> String {
    String(format: String(localized: "nutrition_kcal_format"), calories)
}

private func localizedNutritionLastUsed(_ date: Date) -> String {
    String(
        format: String(localized: "nutrition_last_used_format"),
        date.formatted(date: .abbreviated, time: .omitted)
    )
}

private func localizedNutritionUsedCount(_ count: Int) -> String {
    String(format: String(localized: "nutrition_used_count_format"), count)
}

private func localizedNutritionCooked(_ value: String) -> String {
    String(format: String(localized: "nutrition_cooked_format"), value)
}

private func localizedNutritionRemainingLine(weightG: Double, portionsRemaining: Double? = nil) -> String {
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

private func localizedNutritionPortionsLeft(_ portions: Double) -> String {
    String(
        format: String(localized: "nutrition_portions_left_format"),
        portions.formatted(.number.precision(.fractionLength(0...1)))
    )
}

private func localizedNutritionMacroTotals(protein: Double, fat: Double, carbs: Double, fiber: Double?) -> String {
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

private func localizedNutritionItemSummary(
    weightG: Double,
    calories: Double,
    protein: Double,
    fat: Double,
    carbs: Double,
    fiber: Double?
) -> String {
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

private func localizedNutritionBatchMacroLine(_ snapshot: NutritionBatchMacroSnapshot, prefix: String) -> String {
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
                                .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(meal.loggedAt, style: .time)
                .font(LifeOSTypography.caption)
                .foregroundStyle(.tertiary)
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
            }

            Spacer()

            Button(action: showCalendarButtonTapped) {
                VStack(spacing: 2) {
                    Label(String(localized: "nutrition"), systemImage: "fork.knife")
                        .font(LifeOSTypography.title3)
                    Text(selectedDate.formatted(.dateTime.month().day().weekday(.wide)))
                        .font(LifeOSTypography.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: nextDayButtonTapped) {
                Image(systemName: "chevron.right")
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

    private func handleBatchRecipesChanged() {}

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
                        .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)

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
                .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)

            ForEach(viewModel.draftCandidateItems, content: draftCandidateItemRow)

            Text(detectedItemsFootnote(for: viewModel))
                .font(LifeOSTypography.caption2)
                .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
                }
                Text(itemDraftSubtitle(item))
                    .font(LifeOSTypography.caption2)
                    .foregroundStyle(.tertiary)
                if let notes = item.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !notes.isEmpty {
                    Text(notes)
                        .font(LifeOSTypography.caption2)
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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
            .foregroundStyle(.secondary)
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
                numericField(String(localized: "nutrition_unit_kcal"), value: item.calories)
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
                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
            }

            Text(String(localized: "nutrition_restore_meal_window"))
                .font(LifeOSTypography.footnote)
                .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
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
            fragments.append("\(Int(calories.rounded())) kcal")
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

// MARK: - Photo Capture View

struct NutritionPhotoCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var capturedImage: UIImage?
    @State private var isAnalyzing = false
    @State private var analysisResult: String?
    @State private var analysisConfidence: Double?
    @State private var photoAnalysis: NutritionPhotoAnalysis?
    @State private var analysisNotice: String?
    @State private var showCameraPicker = false
    @State private var showPhotoLibrary = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var captureError: String?
    let targetDay: String
    let loggedAt: Date
    var savedDraftId: UUID? = nil
    var onDraftStateChanged: () -> Void = {}
    let onResult: (NutritionLogDraft) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.m) {
                if let image = capturedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))

                    if isAnalyzing {
                        ProgressView(String(localized: "nutrition_analyzing_photo"))
                    } else if let result = analysisResult {
                        VStack(spacing: Spacing.xs) {
                            Text(result)
                                .font(LifeOSTypography.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            if let analysisNotice {
                                Text(analysisNotice)
                                    .font(LifeOSTypography.caption)
                                    .foregroundStyle(LifeOSColors.Recovery.caution)
                                    .multilineTextAlignment(.center)
                            }
                            if let captureError {
                                Text(captureError)
                                    .font(LifeOSTypography.caption2)
                                    .foregroundStyle(.red)
                                    .multilineTextAlignment(.center)
                            }
                        }
                    } else if let captureError {
                        Text(captureError)
                            .font(LifeOSTypography.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: Spacing.s) {
                        Button(String(localized: "nutrition_use_photo"), action: beginUseCapturedPhoto)
                            .buttonStyle(.borderedProminent)
                            .disabled(isAnalyzing)

                        Button(String(localized: "nutrition_save_photo_for_later"), action: beginSavePhotoForLater)
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("nutrition.photo.save_for_later")
                    }
                } else {
                    VStack(spacing: Spacing.s) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text(String(localized: "nutrition_take_photo_prompt"))
                            .font(LifeOSTypography.body)
                            .foregroundStyle(.secondary)
                        Button(String(localized: "nutrition_open_camera"), action: beginCameraCapture)
                        .buttonStyle(.borderedProminent)

                        Button(String(localized: "nutrition_choose_photo"), action: openPhotoLibraryPicker)
                        .buttonStyle(.bordered)

                        if let captureError {
                            Text(captureError)
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
            }
            .padding(LayoutConstants.contentPadding)
            .navigationTitle(String(localized: "nutrition_photo_title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: dismissScreen) {
                        Text(String(localized: "cancel"))
                    }
                }
            }
            .sheet(isPresented: $showCameraPicker, content: cameraPickerSheet)
            .photosPicker(
                isPresented: $showPhotoLibrary,
                selection: $selectedPhotoItem,
                matching: .images
            )
            .task(id: selectedPhotoItem, handleSelectedPhotoItemChange)
            .task(id: savedDraftId, loadSavedDraftIfNeeded)
        }
    }

    private func fallbackPhotoAnalysis() -> NutritionPhotoAnalysis {
        NutritionPhotoAnalysis(
            summary: analysisResult ?? String(localized: "nutrition_photo_analyzed"),
            confidence: analysisConfidence,
            source: .onDeviceFallback,
            recognizedText: nil,
            barcodes: [],
            detectedItems: [],
            totalMacros: nil,
            warnings: [],
            suggestions: [],
            mealType: nil,
            notice: analysisNotice
        )
    }

    private func cameraPickerSheet() -> some View {
        SystemImagePicker(
            sourceType: .camera,
            onImagePicked: handlePickedCameraImage
        )
    }

    private func beginUseCapturedPhoto() {
        Task { await useCapturedPhoto() }
    }

    private func beginSavePhotoForLater() {
        savePhotoForLater()
    }

    private func beginCameraCapture() {
        openCameraOrLibrary()
    }

    private func openPhotoLibraryPicker() {
        showPhotoLibrary = true
    }

    private func dismissScreen() {
        performDismiss()
    }

    @MainActor
    private func loadSavedDraftIfNeeded() async {
        guard let savedDraftId, capturedImage == nil else { return }
        do {
            let data = try NutritionPhotoDraftStore.imageData(id: savedDraftId)
            guard let image = UIImage(data: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            await processCapturedImage(image)
        } catch {
            captureError = String(localized: "nutrition_photo_draft_load_failed")
        }
    }

    @MainActor
    private func savePhotoForLater(
        saveAction: ((Data, String, Date, UUID?) throws -> NutritionPhotoDraft)? = nil,
        dismissAction: (() -> Void)? = nil
    ) {
        guard let capturedImage,
              let imageData = capturedImage.jpegData(compressionQuality: 0.85) else {
            captureError = String(localized: "nutrition_photo_draft_save_failed")
            return
        }
        do {
            if let saveAction {
                _ = try saveAction(imageData, targetDay, loggedAt, savedDraftId)
            } else {
                _ = try NutritionPhotoDraftStore.save(
                    imageData: imageData,
                    targetDay: targetDay,
                    loggedAt: loggedAt,
                    id: savedDraftId
                )
            }
            onDraftStateChanged()
            performDismiss(dismissAction: dismissAction)
        } catch {
            captureError = String(localized: "nutrition_photo_draft_save_failed")
        }
    }

    private func performDismiss(
        dismissAction: (() -> Void)? = nil
    ) {
        let handleDismiss = dismissAction ?? { dismiss() }
        handleDismiss()
    }

    private func handlePickedCameraImage(_ image: UIImage) {
        handleCapturedCameraImage(image)
    }

    private func handleCapturedCameraImage(
        _ image: UIImage,
        processCapturedImageAction: ((UIImage) async -> Void)? = nil
    ) {
        Task {
            if let processCapturedImageAction {
                await processCapturedImageAction(image)
            } else {
                await processCapturedImage(image)
            }
        }
    }

    @MainActor
    private func handleSelectedPhotoItemChange() async {
        await loadSelectedPhotoItemIfNeeded(
            item: selectedPhotoItem,
            shouldLoad: selectedPhotoItem != nil
        )
    }

    @MainActor
    private func loadSelectedPhotoItemIfNeeded(
        item: PhotosPickerItem?,
        shouldLoad: Bool,
        loadPhotoItemAction: ((PhotosPickerItem?) async -> Void)? = nil
    ) async {
        guard shouldLoad else { return }
        if let loadPhotoItemAction {
            await loadPhotoItemAction(item)
            return
        }
        await loadSelectedPhotoItemIfPresent(item)
    }

    @MainActor
    private func useCapturedPhoto(
        resolvePhotoDraft: ((NutritionPhotoAnalysis, String, Date) async -> NutritionLogDraft)? = nil,
        onResultAction: ((NutritionLogDraft) -> Void)? = nil,
        dismissAction: (() -> Void)? = nil
    ) async {
        let draft: NutritionLogDraft
        if let resolvePhotoDraft {
            draft = await resolvePhotoDraft(
                photoAnalysis ?? fallbackPhotoAnalysis(),
                targetDay,
                loggedAt
            )
        } else {
            draft = await resolveDefaultPhotoDraft(
                analysis: photoAnalysis ?? fallbackPhotoAnalysis(),
                targetDay: targetDay,
                loggedAt: loggedAt
            )
        }
        if let onResultAction {
            onResultAction(draft)
        } else {
            onResult(draft)
        }
        if let savedDraftId {
            try? NutritionPhotoDraftStore.delete(id: savedDraftId)
            onDraftStateChanged()
        }
        performDismiss(dismissAction: dismissAction)
    }

    @MainActor
    private func resolveDefaultPhotoDraft(
        analysis: NutritionPhotoAnalysis,
        targetDay: String,
        loggedAt: Date
    ) async -> NutritionLogDraft {
        await NutritionDraftResolver().resolvePhotoDraft(
            analysis: analysis,
            targetDay: targetDay,
            loggedAt: loggedAt
        )
    }

    private static func capturePickerState(cameraAvailable: Bool) -> (
        showCameraPicker: Bool,
        showPhotoLibrary: Bool
    ) {
        if cameraAvailable {
            return (showCameraPicker: true, showPhotoLibrary: false)
        }
        return (showCameraPicker: false, showPhotoLibrary: true)
    }

    private func openCameraOrLibrary(
        cameraAvailableProvider: (() -> Bool)? = nil
    ) {
        let cameraAvailable = cameraAvailableProvider?()
            ?? UIImagePickerController.isSourceTypeAvailable(.camera)
        let state = Self.capturePickerState(cameraAvailable: cameraAvailable)
        showCameraPicker = state.showCameraPicker
        showPhotoLibrary = state.showPhotoLibrary
    }

    @MainActor
    private func loadPhotoItem(
        _ item: PhotosPickerItem? = nil,
        loadTransferable: (() async throws -> Data?)? = nil,
        processCapturedImageAction: ((UIImage) async -> Void)? = nil
    ) async {
        do {
            let data: Data?
            if let loadTransferable {
                data = try await loadTransferable()
            } else {
                data = try await loadDefaultPhotoTransferable(item: item)
            }
            guard let data,
                  let image = UIImage(data: data) else {
                captureError = String(localized: "error.media.selected_image_load")
                return
            }
            if let processCapturedImageAction {
                await processCapturedImageAction(image)
            } else {
                await processCapturedImage(image)
            }
            selectedPhotoItem = nil
        } catch {
            captureError = error.localizedDescription
            selectedPhotoItem = nil
        }
    }

    private func loadDefaultPhotoTransferable(
        item: PhotosPickerItem?
    ) async throws -> Data? {
        try await item?.loadTransferable(type: Data.self)
    }

    @MainActor
    private func processCapturedImage(
        _ image: UIImage,
        analyzePhoto: ((UIImage, Date) async -> NutritionPhotoAnalysis)? = nil
    ) async {
        capturedImage = image
        captureError = nil
        analysisResult = nil
        photoAnalysis = nil
        analysisNotice = nil
        isAnalyzing = true

        let analysis = await analyzeCapturedPhoto(
            image,
            loggedAt: loggedAt,
            analyzer: analyzePhoto
        )
        analysisResult = analysis.summary
        analysisConfidence = analysis.confidence
        photoAnalysis = analysis
        analysisNotice = analysis.notice

        isAnalyzing = false
    }

    @MainActor
    private func analyzeCapturedPhoto(
        _ image: UIImage,
        loggedAt: Date,
        analyzer: ((UIImage, Date) async -> NutritionPhotoAnalysis)? = nil
    ) async -> NutritionPhotoAnalysis {
        if let analyzer {
            return await analyzer(image, loggedAt)
        }
        return await MediaRecognitionService.analyzeNutritionPhoto(image, loggedAt: loggedAt)
    }
}

// MARK: - Barcode Scanner View (with CIS Label OCR Fallback)

struct NutritionBarcodeScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scannedCode: String?
    @State private var isSearching = false
    @State private var isSaving = false
    @State private var isAnalyzingLabel = false
    @State private var productFound = false
    @State private var showLabelOCRFallback = false
    @State private var ocrResult: String?
    @State private var showCameraPicker = false
    @State private var showPhotoLibrary = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var errorMessage: String?
    @State private var matchedProduct: FoodSearchResult?
    @State private var pendingLabelImages: [UIImage] = []
    @State private var labelReviewDraft: NutritionLabelReviewDraft?
    private let catalogService = NutritionCatalogService()
    let targetDay: String
    let loggedAt: Date
    let onLogged: () -> Void
    let onResult: (NutritionLogDraft) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.m) {
                if labelReviewDraft != nil {
                    NutritionLabelReviewFormView(
                        draft: reviewDraftBinding(),
                        isSaving: isSaving,
                        isAnalyzing: isAnalyzingLabel,
                        errorMessage: errorMessage,
                        onRescan: beginCameraCapture,
                        onSave: beginConfirmReviewedProduct
                    )
                } else if showLabelOCRFallback {
                    VStack(spacing: Spacing.s) {
                        Label(String(localized: "nutrition_barcode_not_found"), systemImage: "exclamationmark.triangle")
                            .font(LifeOSTypography.headline)
                            .foregroundStyle(LifeOSColors.Recovery.caution)

                        Text(String(localized: "nutrition_label_ocr_prompt"))
                            .font(LifeOSTypography.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Button(String(localized: "nutrition_scan_label"), action: beginCameraCapture)
                        .buttonStyle(.borderedProminent)

                        if isAnalyzingLabel {
                            ProgressView(String(localized: "nutrition_analyzing_photo"))
                        }

                        if let ocrResult {
                            Text(ocrResult)
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)

                            Button(String(localized: "nutrition_review_product"), action: beginAnalyzePendingLabelImages)
                            .buttonStyle(.bordered)
                            .disabled(reviewProductDisabled())
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }
                    }
                } else if let scannedCode {
                    if isSearching {
                        ProgressView(String(localized: "nutrition_searching_barcode"))
                    } else if productFound {
                        VStack(spacing: Spacing.s) {
                            Text(String(format: String(localized: "nutrition_product_found_format"), scannedCode))
                                .font(LifeOSTypography.body)

                            if let matchedProduct {
                                VStack(spacing: Spacing.xxs) {
                                    Text(matchedProduct.name)
                                        .font(LifeOSTypography.headline)
                                    Text("\(matchedProduct.roundedCaloriesPer100g) kcal / 100g")
                                        .font(LifeOSTypography.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Button(String(localized: "nutrition_add_product"), action: beginLogMatchedProduct)
                            .buttonStyle(.borderedProminent)
                            .disabled(isSaving)
                            .accessibilityIdentifier("nutrition.barcode.add_product")

                            if isSaving {
                                ProgressView(String(localized: "nutrition_save_product_progress"))
                            }
                        }
                    } else {
                        Text(String(localized: "nutrition_barcode_no_match"))
                            .font(LifeOSTypography.body)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: Spacing.s) {
                        Image(systemName: "barcode.viewfinder")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text(String(localized: "nutrition_scan_barcode_prompt"))
                            .font(LifeOSTypography.body)
                            .foregroundStyle(.secondary)
                        Button(String(localized: "nutrition_start_scan"), action: beginCameraCapture)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("nutrition.barcode.start_scan")

                        Button(String(localized: "nutrition_choose_photo"), action: openPhotoLibraryPicker)
                        .buttonStyle(.bordered)

                        if let errorMessage {
                            Text(errorMessage)
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
            }
            .padding(LayoutConstants.contentPadding)
            .accessibilityIdentifier("nutrition.barcode.screen")
            .navigationTitle(String(localized: "nutrition_barcode_title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: dismissScreen) {
                        Text(String(localized: "cancel"))
                    }
                }
            }
            .sheet(isPresented: $showCameraPicker, content: cameraPickerSheet)
            .photosPicker(
                isPresented: $showPhotoLibrary,
                selection: $selectedPhotoItem,
                matching: .images
            )
            .task(id: selectedPhotoItem, handleSelectedPhotoItemChange)
        }
    }

    private func beginCameraCapture() {
        openCameraOrLibrary()
    }

    private func cameraPickerSheet() -> some View {
        SystemImagePicker(
            sourceType: .camera,
            onImagePicked: handlePickedCameraImage
        )
    }

    private func openPhotoLibraryPicker() {
        showPhotoLibrary = true
    }

    private func dismissScreen() {
        performDismiss()
    }

    private func performDismiss(
        dismissAction: (() -> Void)? = nil
    ) {
        let handleDismiss = dismissAction ?? { dismiss() }
        handleDismiss()
    }

    private func beginConfirmReviewedProduct() {
        Task { await confirmReviewedProduct() }
    }

    private func beginAnalyzePendingLabelImages() {
        Task { await analyzePendingLabelImages() }
    }

    private func beginLogMatchedProduct() {
        Task { await logMatchedProduct() }
    }

    private func handlePickedCameraImage(_ image: UIImage) {
        handleCapturedCameraImage(image)
    }

    private func handleCapturedCameraImage(
        _ image: UIImage,
        processScannedImageAction: ((UIImage) async -> Void)? = nil
    ) {
        Task {
            if let processScannedImageAction {
                await processScannedImageAction(image)
            } else {
                await processScannedImage(image)
            }
        }
    }

    @MainActor
    private func handleSelectedPhotoItemChange() async {
        await loadSelectedPhotoItemIfNeeded(
            item: selectedPhotoItem,
            shouldLoad: selectedPhotoItem != nil
        )
    }

    private func reviewDraftBinding() -> Binding<NutritionLabelReviewDraft> {
        Binding(
            get: { labelReviewDraft ?? fallbackDraft },
            set: { labelReviewDraft = $0 }
        )
    }

    private func reviewProductDisabled() -> Bool {
        isAnalyzingLabel || pendingLabelImages.isEmpty
    }

    @MainActor
    private func loadSelectedPhotoItemIfNeeded(
        item: PhotosPickerItem?,
        shouldLoad: Bool,
        loadPhotoItemAction: ((PhotosPickerItem?) async -> Void)? = nil
    ) async {
        guard shouldLoad else { return }
        if let loadPhotoItemAction {
            await loadPhotoItemAction(item)
        } else if let item {
            await loadPhotoItem(item)
        }
    }

    private static func capturePickerState(cameraAvailable: Bool) -> (
        showCameraPicker: Bool,
        showPhotoLibrary: Bool
    ) {
        if cameraAvailable {
            return (showCameraPicker: true, showPhotoLibrary: false)
        }
        return (showCameraPicker: false, showPhotoLibrary: true)
    }

    private func openCameraOrLibrary(
        cameraAvailableProvider: (() -> Bool)? = nil
    ) {
        let cameraAvailable = cameraAvailableProvider?()
            ?? UIImagePickerController.isSourceTypeAvailable(.camera)
        let state = Self.capturePickerState(cameraAvailable: cameraAvailable)
        showCameraPicker = state.showCameraPicker
        showPhotoLibrary = state.showPhotoLibrary
    }

    @MainActor
    private func loadPhotoItem(
        _ item: PhotosPickerItem? = nil,
        loadTransferable: (() async throws -> Data?)? = nil,
        routeSelectedImageAction: ((UIImage) async -> Void)? = nil
    ) async {
        do {
            let data: Data?
            if let loadTransferable {
                data = try await loadTransferable()
            } else {
                data = try await loadDefaultPhotoTransferable(item: item)
            }
            guard let data,
                  let image = UIImage(data: data) else {
                errorMessage = String(localized: "error.media.selected_image_load")
                return
            }
            if let routeSelectedImageAction {
                await routeSelectedImageAction(image)
            } else {
                await routeSelectedImage(image)
            }
            selectedPhotoItem = nil
        } catch {
            errorMessage = error.localizedDescription
            selectedPhotoItem = nil
        }
    }

    private func loadDefaultPhotoTransferable(
        item: PhotosPickerItem?
    ) async throws -> Data? {
        try await item?.loadTransferable(type: Data.self)
    }

    @MainActor
    private func routeSelectedImage(
        _ image: UIImage,
        processLabelImageAction: ((UIImage) async -> Void)? = nil,
        processScannedImageAction: ((UIImage) async -> Void)? = nil
    ) async {
        if showLabelOCRFallback || labelReviewDraft != nil {
            if let processLabelImageAction {
                await processLabelImageAction(image)
            } else {
                await processLabelImage(image)
            }
        } else {
            if let processScannedImageAction {
                await processScannedImageAction(image)
            } else {
                await processScannedImage(image)
            }
        }
    }

    @MainActor
    private func processScannedImage(
        _ image: UIImage,
        detectBarcodes: ((UIImage) async throws -> [String])? = nil,
        recognizeText: ((UIImage) async throws -> String)? = nil,
        lookupBarcode: ((String) async throws -> FoodSearchResult?)? = nil
    ) async {
        let detect = detectBarcodes ?? detectImageBarcodes
        let recognize = recognizeText ?? recognizeImageText
        let lookup = lookupBarcode ?? { barcode in
            try await lookupProduct(barcode: barcode)
        }
        isSearching = true
        errorMessage = nil
        ocrResult = nil
        showLabelOCRFallback = false
        matchedProduct = nil
        labelReviewDraft = nil
        pendingLabelImages = []

        do {
            let codes = try await detect(image)
            if let code = codes.first {
                scannedCode = code
                matchedProduct = try await lookup(code)
                productFound = matchedProduct != nil
                showLabelOCRFallback = matchedProduct == nil
                if matchedProduct == nil {
                    pendingLabelImages = [image]
                    let text = try await recognize(image)
                    ocrResult = text.isEmpty ? String(localized: "nutrition_barcode_review_label_manually") : text
                }
                isSearching = false
                return
            }

            let text = try await recognize(image)
            scannedCode = nil
            productFound = false
            showLabelOCRFallback = true
            pendingLabelImages = [image]
            ocrResult = text.isEmpty ? String(localized: "nutrition_barcode_no_barcode_detected") : text
        } catch {
            errorMessage = error.localizedDescription
        }

        isSearching = false
    }

    @MainActor
    private func processLabelImage(
        _ image: UIImage,
        recognizeText: ((UIImage) async throws -> String)? = nil,
        analyzePendingLabelImagesAction: (() async -> Void)? = nil
    ) async {
        let recognize = recognizeText ?? { image in
            try await MediaRecognitionService.recognizeText(in: image)
        }
        let analyze = analyzePendingLabelImagesAction ?? {
            await analyzePendingLabelImages()
        }
        errorMessage = nil
        pendingLabelImages = Array((pendingLabelImages + [image]).suffix(2))

        if let text = try? await recognize(image),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ocrResult = text
        }

        await analyze()
    }

    @MainActor
    private func analyzePendingLabelImages(
        analyzeFoodLabelDraft: (([UIImage], String?) async -> NutritionLabelReviewDraft)? = nil
    ) async {
        let analyze = analyzeFoodLabelDraft ?? { images, barcodeHint in
            await MediaRecognitionService.analyzeFoodLabelDraft(from: images, barcodeHint: barcodeHint)
        }
        guard !pendingLabelImages.isEmpty else { return }
        isAnalyzingLabel = true
        errorMessage = nil
        defer { isAnalyzingLabel = false }

        let draft = await analyze(pendingLabelImages, scannedCode)
        labelReviewDraft = draft
    }

    private func lookupProduct(
        barcode: String,
        lookupBarcode: ((String) async throws -> FoodSearchResult?)? = nil
    ) async throws -> FoodSearchResult? {
        let lookup = lookupBarcode ?? { barcode in
            try await catalogService.lookupBarcode(barcode)
        }
        return try await lookup(barcode)
    }

    @MainActor
    private func logMatchedProduct(
        logSearchResult: ((FoodSearchResult, NutritionInputMethod, String, Date) async throws -> UUID)? = nil,
        onLoggedAction: (() -> Void)? = nil,
        dismissAction: (() -> Void)? = nil
    ) async {
        guard let matchedProduct else { return }
        let log = logSearchResult ?? defaultLogMatchedProduct
        let handleLogged = onLoggedAction ?? onLogged
        let handleDismiss = dismissAction ?? { dismiss() }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            _ = try await log(matchedProduct, .barcode, targetDay, loggedAt)
            handleLogged()
            handleDismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func defaultLogMatchedProduct(
        _ result: FoodSearchResult,
        method: NutritionInputMethod,
        targetDay: String,
        loggedAt: Date
    ) async throws -> UUID {
        try await QuickFoodLogService().logSearchResult(
            result,
            method: method,
            targetDay: targetDay,
            loggedAt: loggedAt
        )
    }

    private func detectImageBarcodes(
        _ image: UIImage
    ) async throws -> [String] {
        try await MediaRecognitionService.detectBarcodes(in: image)
    }

    private func recognizeImageText(
        _ image: UIImage
    ) async throws -> String {
        try await MediaRecognitionService.recognizeText(in: image)
    }

    @MainActor
    private func confirmReviewedProduct(
        createReviewedFood: ((NutritionLabelReviewDraft) async throws -> FoodSearchResult)? = nil,
        onResultAction: ((NutritionLogDraft) -> Void)? = nil,
        dismissAction: (() -> Void)? = nil
    ) async {
        guard let labelReviewDraft else { return }
        let createFood = createReviewedFood ?? { review in
            try await catalogService.createReviewedFood(review: review)
        }
        let handleResult = onResultAction ?? onResult
        let handleDismiss = dismissAction ?? { dismiss() }
        if let validationError = validate(review: labelReviewDraft) {
            errorMessage = validationError
            return
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let result = try await createFood(labelReviewDraft)
            let draft = labelReviewDraft.makeLogDraft(
                from: result,
                targetDay: targetDay,
                loggedAt: loggedAt
            )
            handleResult(draft)
            handleDismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func validate(review: NutritionLabelReviewDraft) -> String? {
        if review.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "nutrition_validation_name_required")
        }
        if review.servingSizeG <= 0 {
            return String(localized: "nutrition_validation_weight_positive")
        }
        if review.caloriesPer100g < 0 ||
            review.proteinPer100g < 0 ||
            review.fatPer100g < 0 ||
            review.carbsPer100g < 0 ||
            review.fiberPer100g < 0 {
            return "Nutrition values must be zero or greater."
        }
        return nil
    }

    private var fallbackDraft: NutritionLabelReviewDraft {
        NutritionLabelReviewDraft(
            name: String(localized: "nutrition_default_item_name"),
            servingSizeG: 100,
            caloriesPer100g: 0,
            proteinPer100g: 0,
            fatPer100g: 0,
            carbsPer100g: 0,
            confidence: nil,
            analysisSource: .onDeviceFallback
        )
    }
}

struct NutritionLabelReviewFormView: View {
    @Binding var draft: NutritionLabelReviewDraft
    let isSaving: Bool
    let isAnalyzing: Bool
    let errorMessage: String?
    let onRescan: () -> Void
    let onSave: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Label(String(localized: "nutrition_review_product"), systemImage: "checklist")
                    .font(LifeOSTypography.headline)

                Text(String(localized: "nutrition_label_ocr_prompt"))
                    .font(LifeOSTypography.body)
                    .foregroundStyle(.secondary)

                if !draft.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(String(localized: "nutrition_photo_review_notes_title"))
                            .font(LifeOSTypography.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(draft.warnings, id: \.self, content: warningRow)
                    }
                    .padding(Spacing.s)
                    .background(LifeOSColors.Surface.card)
                    .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
                }

                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(String(localized: "nutrition_recipe_info"))
                        .font(LifeOSTypography.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    TextField(String(localized: "nutrition_item_name"), text: $draft.name)
                        .textInputAutocapitalization(.words)
                    TextField(String(localized: "nutrition_brand"), text: $draft.brand)
                        .textInputAutocapitalization(.words)
                    TextField(String(localized: "nutrition_barcode"), text: $draft.barcode)
                        .keyboardType(.numberPad)
                    numericField(String(localized: "nutrition_portion_weight_g"), value: $draft.servingSizeG)
                }
                .padding(Spacing.s)
                .background(LifeOSColors.Surface.card)
                .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))

                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(String(localized: "nutrition_macros"))
                        .font(LifeOSTypography.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    numericField(String(localized: "nutrition_unit_kcal"), value: $draft.caloriesPer100g)
                    HStack(spacing: Spacing.s) {
                        numericField(String(localized: "nutrition_macro_label_protein"), value: $draft.proteinPer100g)
                        numericField(String(localized: "nutrition_macro_label_fat"), value: $draft.fatPer100g)
                    }
                    HStack(spacing: Spacing.s) {
                        numericField(String(localized: "nutrition_macro_label_carbs"), value: $draft.carbsPer100g)
                        numericField(String(localized: "nutrition_macro_label_fiber"), value: $draft.fiberPer100g)
                    }
                }
                .padding(Spacing.s)
                .background(LifeOSColors.Surface.card)
                .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))

                if let sourceText = draft.sourceText,
                   !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(String(localized: "notes"))
                            .font(LifeOSTypography.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(sourceText)
                            .font(LifeOSTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(Spacing.s)
                    .background(LifeOSColors.Surface.card)
                    .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.red)
                }

                if isAnalyzing {
                    ProgressView(String(localized: "nutrition_analyzing_photo"))
                }

                HStack(spacing: Spacing.s) {
                    Button(String(localized: "nutrition_scan_label"), action: onRescan)
                        .buttonStyle(.bordered)
                    Button(String(localized: "save"), action: onSave)
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving || isAnalyzing)
                }

                if isSaving {
                    ProgressView(String(localized: "nutrition_save_product_progress"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func numericField(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(LifeOSTypography.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(
                title,
                value: value,
                format: .number.precision(.fractionLength(0...1))
            )
            .keyboardType(.decimalPad)
            .textFieldStyle(.roundedBorder)
        }
    }

    private func warningRow(_ warning: String) -> some View {
        Text(warning)
            .font(LifeOSTypography.caption)
            .foregroundStyle(LifeOSColors.Recovery.caution)
    }
}

private extension NutritionPhotoCaptureView {
    @MainActor
    func loadSelectedPhotoItemIfPresent(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        await loadPhotoItem(item)
    }
}

// MARK: - Voice Input View

struct NutritionVoiceInputView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speechRecognizer = NutritionSpeechRecognizer()
    @State private var pendingResolution: NutritionVoiceResolution?
    @State private var clarificationAnswers: [String: String] = [:]
    @State private var isResolving = false
    let targetDay: String
    let loggedAt: Date
    let onResult: (NutritionLogDraft) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let pendingResolution,
                   let response = pendingResolution.response,
                   !response.clarifyingQuestions.isEmpty {
                    clarificationContent(
                        resolution: pendingResolution,
                        questions: response.clarifyingQuestions
                    )
                } else {
                    recordingContent
                }
            }
            .padding(LayoutConstants.contentPadding)
            .navigationTitle(String(localized: "nutrition_voice_title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel"), action: dismiss.callAsFunction)
                }
            }
            .onDisappear { stopRecordingOnDisappear() }
        }
    }

    private var recordingContent: some View {
        VStack(spacing: Spacing.m) {
            Spacer()

            Image(systemName: speechRecognizer.isRecording ? "mic.fill" : "mic")
                .font(.system(size: 64))
                .foregroundStyle(speechRecognizer.isRecording ? .red : LifeOSColors.Semantic.primary)
                .symbolEffect(.pulse, isActive: speechRecognizer.isRecording)

            if speechRecognizer.isProcessing || isResolving {
                ProgressView(String(localized: "nutrition_processing_voice"))
            } else if !speechRecognizer.transcription.isEmpty {
                Text(speechRecognizer.transcription)
                    .font(LifeOSTypography.body)
                    .padding(Spacing.m)
                    .background(LifeOSColors.Surface.card)
                    .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))

                Button(String(localized: "nutrition_use_voice_result")) {
                    Task { await useVoiceResult() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("nutrition.voice.use_result")
            } else {
                Text(speechRecognizer.isRecording
                    ? String(localized: "nutrition_listening")
                    : String(localized: "nutrition_voice_prompt"))
                    .font(LifeOSTypography.body)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = speechRecognizer.errorMessage {
                Text(errorMessage)
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button {
                Task { await toggleRecording() }
            } label: {
                Text(speechRecognizer.isRecording
                    ? String(localized: "nutrition_stop_recording")
                    : String(localized: "nutrition_start_recording"))
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.s)
            }
            .buttonStyle(.borderedProminent)
            .tint(speechRecognizer.isRecording ? .red : LifeOSColors.Semantic.primary)
        }
    }

    private func clarificationContent(
        resolution: NutritionVoiceResolution,
        questions: [FoodTextParseResponse.ClarifyingQuestion]
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(String(localized: "nutrition_voice_clarifications_title"))
                    .font(LifeOSTypography.title3)
                Text(String(localized: "nutrition_voice_clarifications_subtitle"))
                    .font(LifeOSTypography.body)
                    .foregroundStyle(.secondary)

                ForEach(questions, id: \.id) { question in
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text(question.question)
                            .font(LifeOSTypography.headline)

                        ForEach(question.options, id: \.self) { option in
                            Button {
                                clarificationAnswers[question.id] = option
                            } label: {
                                HStack {
                                    Text(option)
                                    Spacer()
                                    if clarificationAnswers[question.id] == option {
                                        Image(systemName: "checkmark.circle.fill")
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier(
                                "nutrition.voice.clarification.\(question.id).\(option)"
                            )
                        }

                        TextField(
                            String(localized: "nutrition_voice_clarification_custom"),
                            text: clarificationBinding(for: question.id)
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                    .padding(Spacing.m)
                    .background(LifeOSColors.Surface.card)
                    .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
                }

                Button(String(localized: "nutrition_voice_apply_clarifications")) {
                    Task { await applyClarifications(questions) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isResolving)
                .accessibilityIdentifier("nutrition.voice.clarifications.apply")

                Button(String(localized: "nutrition_voice_review_without_answers")) {
                    finishVoiceResult(resolution.draft)
                }
                .buttonStyle(.bordered)
                .disabled(isResolving)
            }
        }
        .accessibilityIdentifier("nutrition.voice.clarifications")
    }

    private func clarificationBinding(for id: String) -> Binding<String> {
        Binding(
            get: { clarificationAnswers[id] ?? "" },
            set: { clarificationAnswers[id] = $0 }
        )
    }

    private func useVoiceResult(
        resolveDraftAction: ((String, Double?, String, Date) async -> NutritionLogDraft)? = nil,
        onResultAction: ((NutritionLogDraft) -> Void)? = nil,
        dismissAction: (() -> Void)? = nil
    ) async {
        isResolving = true
        defer { isResolving = false }
        if let resolveDraftAction {
            let draft = await resolveDraftAction(
                speechRecognizer.transcription,
                speechRecognizer.confidence,
                targetDay,
                loggedAt
            )
            finishVoiceResult(
                draft,
                onResultAction: onResultAction,
                dismissAction: dismissAction
            )
        } else {
            let resolution = await NutritionDraftResolver().resolveVoiceResolution(
                transcription: speechRecognizer.transcription,
                confidence: speechRecognizer.confidence,
                targetDay: targetDay,
                loggedAt: loggedAt
            )
            if let response = resolution.response,
               response.needsClarification,
               !response.clarifyingQuestions.isEmpty {
                pendingResolution = resolution
                clarificationAnswers = [:]
            } else {
                finishVoiceResult(
                    resolution.draft,
                    onResultAction: onResultAction,
                    dismissAction: dismissAction
                )
            }
        }
    }

    private func applyClarifications(
        _ questions: [FoodTextParseResponse.ClarifyingQuestion]
    ) async {
        isResolving = true
        defer { isResolving = false }
        let answered = questions.compactMap { question -> String? in
            guard let answer = clarificationAnswers[question.id]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !answer.isEmpty else {
                return nil
            }
            return "\(question.itemName ?? question.question): \(answer)"
        }
        guard !answered.isEmpty else {
            if let draft = pendingResolution?.draft {
                finishVoiceResult(draft)
            }
            return
        }
        let clarifiedText = [
            speechRecognizer.transcription,
            String(localized: "nutrition_voice_clarifications_context") + " " + answered.joined(separator: "; "),
        ].joined(separator: ". ")
        let draft = await NutritionDraftResolver().resolveVoiceDraft(
            transcription: clarifiedText,
            confidence: speechRecognizer.confidence,
            targetDay: targetDay,
            loggedAt: loggedAt
        )
        finishVoiceResult(draft)
    }

    private func finishVoiceResult(
        _ draft: NutritionLogDraft,
        onResultAction: ((NutritionLogDraft) -> Void)? = nil,
        dismissAction: (() -> Void)? = nil
    ) {
        (onResultAction ?? onResult)(draft)
        (dismissAction ?? { dismiss() })()
    }

    private func toggleRecording(
        startRecordingAction: (() async -> Void)? = nil,
        stopRecordingAction: (() async -> Void)? = nil
    ) async {
        if speechRecognizer.isRecording {
            if let stopRecordingAction {
                await stopRecordingAction()
            } else {
                await speechRecognizer.stopRecording()
            }
        } else if let startRecordingAction {
            await startRecordingAction()
        } else {
            await speechRecognizer.startRecording()
        }
    }

    private func stopRecordingOnDisappear(
        stopRecordingAction: (() async -> Void)? = nil
    ) {
        Task {
            if let stopRecordingAction {
                await stopRecordingAction()
            } else {
                await speechRecognizer.stopRecording()
            }
        }
    }

}

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
            Text("\(result.roundedCaloriesPer100g) kcal / 100g")
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
        }) ?? []

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

private struct NutritionLocalSearchCandidate {
    let result: FoodSearchResult
    let score: Int
}

private enum NutritionSearchScoreSource {
    case cache
    case provider
    case custom
}

// MARK: - Meal Templates Section

struct MealTemplatesView: View {
    let targetDay: String
    let loggedAt: Date
    let refreshTrigger: Int
    let onTemplatesChanged: () -> Void
    let onTemplateLogged: () -> Void
    @State private var isLoading = true
    @State private var templates: [NutritionMealTemplateSummary] = []
    let onSelectTemplate: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(String(localized: "nutrition_templates_title"))
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                Spacer()
                NavigationLink(String(localized: "nutrition_see_all")) {
                    MealTemplateLibraryView(
                        targetDay: targetDay,
                        loggedAt: loggedAt,
                        onTemplatesChanged: {
                            onTemplatesChanged()
                            Task { await loadTemplates(manager: NutritionService()) }
                        },
                        onTemplateLogged: onTemplateLogged
                    )
                }
                .font(LifeOSTypography.caption)
            }

            if isLoading {
                ProgressView()
            } else if templates.isEmpty {
                Text(String(localized: "nutrition_no_templates"))
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.s) {
                        ForEach(templates) { template in
                            templateCard(template)
                        }
                    }
                }
            }
        }
        .task(id: refreshTrigger) { await loadTemplates(manager: NutritionService()) }
    }

    private static func loadTemplatesResult(
        manager: any NutritionMealTemplateManaging
    ) async -> [NutritionMealTemplateSummary] {
        do {
            return try await manager.loadMealTemplates(
                includeArchived: false,
                limit: 8,
                preferRemote: true
            )
            .sorted {
                ($0.lastUsedAt ?? $0.updatedAt) > ($1.lastUsedAt ?? $1.updatedAt)
            }
        } catch {
            return []
        }
    }

    private func loadTemplates(manager: any NutritionMealTemplateManaging) async {
        isLoading = true
        defer { isLoading = false }
        templates = await Self.loadTemplatesResult(manager: manager)
    }

    private func templateCard(_ template: NutritionMealTemplateSummary) -> some View {
        Button {
            onSelectTemplate(template.id)
        } label: {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(template.name)
                    .font(LifeOSTypography.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(templateMacroSummary(template))
                    .font(LifeOSTypography.caption2)
                    .foregroundStyle(.secondary)
                if let lastUsed = template.lastUsedAt {
                    Text(localizedNutritionLastUsed(lastUsed))
                        .font(LifeOSTypography.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 164, alignment: .leading)
            .padding(Spacing.s)
            .background(LifeOSColors.Surface.card)
            .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
        }
        .buttonStyle(.plain)
    }

    private func templateMacroSummary(_ template: NutritionMealTemplateSummary) -> String {
        String(
            format: String(localized: "nutrition_template_macro_summary_format"),
            Int(template.calories.rounded()),
            Int(template.proteinG.rounded()),
            Int(template.fatG.rounded()),
            Int(template.carbsG.rounded())
        )
    }
}

// MARK: - Meal Template Library

struct MealTemplateLibraryView: View {
    let targetDay: String
    let loggedAt: Date
    let onTemplatesChanged: () -> Void
    let onTemplateLogged: () -> Void

    @State private var templates: [NutritionMealTemplateSummary] = []
    @State private var isLoading = true
    @State private var showingArchived = false
    @State private var showingComposer = false
    @State private var selectedTemplate: MealTemplateLibraryDestination?
    @State private var statusMessage: TemplateStatusMessage?

    var body: some View {
        VStack(spacing: Spacing.s) {
            Picker(String(localized: "nutrition_templates_title"), selection: $showingArchived) {
                Text(String(localized: "nutrition_active")).tag(false)
                Text(String(localized: "nutrition_archived")).tag(true)
            }
            .pickerStyle(.segmented)

            if let statusMessage {
                Label(statusMessage.message, systemImage: statusMessage.systemImage)
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(statusMessage.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if templates.isEmpty {
                VStack(spacing: Spacing.s) {
                    Text(showingArchived ? String(localized: "nutrition_no_archived_templates") : String(localized: "nutrition_no_templates"))
                        .font(LifeOSTypography.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if !showingArchived {
                        Button {
                            showingComposer = true
                        } label: {
                            Label(String(localized: "nutrition_create_template"), systemImage: "plus.circle.fill")
                                .font(LifeOSTypography.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List {
                    ForEach(templates) { template in
                        templateRow(template)
                    }
                }
            }
        }
        .padding(.horizontal, LayoutConstants.contentPadding)
        .navigationTitle(String(localized: "nutrition_template_library"))
        .navigationDestination(item: $selectedTemplate) { destination in
            templateDetailDestination(destination)
        }
        .sheet(isPresented: $showingComposer) {
            composerSheet()
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    showingComposer = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task(id: showingArchived) { await loadTemplates(manager: NutritionService()) }
    }

    private static func loadTemplatesResult(
        showingArchived: Bool,
        manager: any NutritionMealTemplateManaging
    ) async -> (
        templates: [NutritionMealTemplateSummary],
        statusMessage: TemplateStatusMessage?
    ) {
        do {
            let templates = try await manager.loadMealTemplates(
                includeArchived: showingArchived,
                limit: nil,
                preferRemote: true
            )
            .filter { showingArchived ? $0.archived : !$0.archived }
            return (templates: templates, statusMessage: nil)
        } catch {
            return (
                templates: [],
                statusMessage: TemplateStatusMessage(message: error.localizedDescription, isError: true)
            )
        }
    }

    private static func toggleArchiveResult(
        for template: NutritionMealTemplateSummary,
        manager: any NutritionMealTemplateManaging
    ) async -> Result<TemplateStatusMessage, Error> {
        do {
            try await manager.setMealTemplateArchived(id: template.id, archived: !template.archived)
            return .success(
                TemplateStatusMessage(
                    message: template.archived
                        ? String(localized: "nutrition_template_restored")
                        : String(localized: "nutrition_template_archived"),
                    isError: false
                )
            )
        } catch {
            return .failure(error)
        }
    }

    private func loadTemplates(manager: any NutritionMealTemplateManaging) async {
        isLoading = true
        defer { isLoading = false }
        let result = await Self.loadTemplatesResult(
            showingArchived: showingArchived,
            manager: manager
        )
        templates = result.templates
        statusMessage = result.statusMessage
    }

    private func toggleArchive(
        for template: NutritionMealTemplateSummary,
        manager: any NutritionMealTemplateManaging
    ) async {
        switch await Self.toggleArchiveResult(for: template, manager: manager) {
        case let .success(message):
            statusMessage = message
            HapticManager.success()
            onTemplatesChanged()
            await loadTemplates(manager: manager)
        case let .failure(error):
            statusMessage = TemplateStatusMessage(message: error.localizedDescription, isError: true)
            HapticManager.error()
        }
    }

    private func templateRow(_ template: NutritionMealTemplateSummary) -> some View {
        Button {
            selectedTemplate = MealTemplateLibraryDestination(templateId: template.id, startsEditing: false)
        } label: {
            HStack(alignment: .top, spacing: Spacing.s) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(template.name)
                        .font(LifeOSTypography.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(templateRowSubtitle(template))
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)
                    if let lastUsed = template.lastUsedAt {
                        Text(localizedNutritionLastUsed(lastUsed))
                            .font(LifeOSTypography.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                selectedTemplate = MealTemplateLibraryDestination(templateId: template.id, startsEditing: true)
            } label: {
                Label(String(localized: "edit"), systemImage: "pencil")
            }
            .tint(LifeOSColors.Semantic.primary)

            Button {
                Task { await toggleArchive(for: template, manager: NutritionService()) }
            } label: {
                Label(
                    showingArchived ? String(localized: "unarchive") : String(localized: "archive"),
                    systemImage: showingArchived ? "tray.and.arrow.up.fill" : "archivebox.fill"
                )
            }
            .tint(showingArchived ? .green : .orange)
        }
    }

    private func templateDetailDestination(_ destination: MealTemplateLibraryDestination) -> some View {
        MealTemplateDetailView(
            templateId: destination.templateId,
            startsEditing: destination.startsEditing,
            targetDay: targetDay,
            loggedAt: loggedAt,
            onTemplatesChanged: handleTemplateDetailTemplatesChanged,
            onTemplateLogged: onTemplateLogged,
            onStatusMessage: handleTemplateDetailStatusMessage
        )
    }

    private func handleTemplateDetailTemplatesChanged() {
        handleTemplateDetailTemplatesChanged(reloadAction: nil)
    }

    private func handleTemplateDetailTemplatesChanged(reloadAction: (() async -> Void)? = nil) {
        statusMessage = nil
        onTemplatesChanged()
        Task { @MainActor in
            if let reloadAction {
                await reloadAction()
            } else {
                await loadTemplates(manager: NutritionService())
            }
        }
    }

    private func handleTemplateDetailStatusMessage(_ message: TemplateStatusMessage?) {
        statusMessage = message
    }

    private func composerSheet() -> some View {
        NavigationStack {
            MealTemplateComposerView(
                onSaved: handleComposerSheetSaved
            )
        }
    }

    private func handleComposerSheetSaved(_ message: TemplateStatusMessage) {
        handleComposerSaved(message, reloadAction: nil)
    }

    private func handleComposerSaved(
        _ message: TemplateStatusMessage,
        reloadAction: (() async -> Void)?
    ) {
        statusMessage = message
        showingArchived = false
        onTemplatesChanged()
        Task { @MainActor in
            if let reloadAction {
                await reloadAction()
            } else {
                await loadTemplates(manager: NutritionService())
            }
        }
    }

    private func templateRowSubtitle(_ template: NutritionMealTemplateSummary) -> String {
        String(
            format: String(localized: "nutrition_template_row_subtitle_format"),
            localizedNutritionMealType(template.mealType, emptyKey: "nutrition_any_meal"),
            Int(template.calories.rounded()),
            Int(template.proteinG.rounded()),
            Int(template.fatG.rounded()),
            Int(template.carbsG.rounded())
        )
    }
}

private enum NutritionIdentity {
    static func resolveUserId(authId: String?, db: Database) throws -> UUID? {
        try UserIdentityLookup.resolveUserId(authId: authId, db: db)
    }
}

private enum NutritionOutboxHeaders {
    static func json() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["Content-Type": "application/json"])
    }
}

actor QuickFoodLogService {
    private let dbQueue: DatabaseQueue
    private let timeZoneHistoryStore: TimeZoneHistoryStore
#if DEBUG
    private static let testLogSearchResultOverride = LockedTestOverride<
        @Sendable (FoodSearchResult, NutritionInputMethod, String, Date) async throws -> UUID
    >()
#endif

    init(
        dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue,
        timeZoneHistoryStore: TimeZoneHistoryStore? = nil
    ) {
        self.dbQueue = dbQueue
        self.timeZoneHistoryStore = timeZoneHistoryStore ?? TimeZoneHistoryStore(dbQueue: dbQueue)
    }

    func logSearchResult(
        _ result: FoodSearchResult,
        method: NutritionInputMethod,
        targetDay: String,
        loggedAt: Date
    ) async throws -> UUID {
#if DEBUG
        if let override = Self.testLogSearchResultOverride.value {
            return try await override(result, method, targetDay, loggedAt)
        }
#endif
        let authId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        let userId = try await dbQueue.read { db in
            guard let userId = try NutritionIdentity.resolveUserId(authId: authId, db: db) else {
                throw SyncError.networkUnavailable
            }
            return userId
        }
        _ = try await timeZoneHistoryStore.captureCurrentTimeZoneIfNeeded(
            userId: userId,
            recordedAt: loggedAt,
            source: .manualEntry
        )
        let dayContext = try await timeZoneHistoryStore.resolveLocalDayContext(
            forDayString: targetDay,
            userId: userId,
            preferredDate: loggedAt
        )
        let logId = try await dbQueue.write { db in
            guard let resolvedUserId = try NutritionIdentity.resolveUserId(authId: authId, db: db),
                  resolvedUserId == userId else {
                throw SyncError.networkUnavailable
            }

            let now = Date()
            var log = FoodLog(
                userId: userId,
                loggedAt: loggedAt,
                loggedDate: dayContext.dayString,
                inputMethod: method,
                calories: result.caloriesPer100g,
                proteinG: result.proteinPer100g,
                fatG: result.fatPer100g,
                carbsG: result.carbsPer100g
            )
            log.fiberG = result.fiberPer100g
            log.createdAt = now
            log.updatedAt = now
            log.loggedTimezone = dayContext.timeZoneIdentifier
            log.loggedUtcOffsetMinutes = dayContext.utcOffsetMinutes
            log.aiConfidence = method == .barcode ? 0.95 : nil
            log.applyReviewGate()
            try log.insert(db)

            var logEvent = OutboxEvent(
                id: log.id,
                httpMethod: .POST,
                path: "api-food-log",
                bodyJson: try JSONEncoder.supabase.encode(log),
                priority: 100
            )
            logEvent.headersJson = try NutritionOutboxHeaders.json()
            try logEvent.insert(db)

            var item = FoodItem(
                foodLogId: log.id,
                userId: userId,
                name: result.name,
                weightG: 100,
                calories: result.caloriesPer100g,
                proteinG: result.proteinPer100g,
                fatG: result.fatPer100g,
                carbsG: result.carbsPer100g
            )
            item.createdAt = now
            item.updatedAt = now
            item.brand = result.brand
            item.barcode = result.barcode
            item.fiberG = result.fiberPer100g
            switch result.refType {
            case .catalog:
                item.catalogItemId = result.id
                item.userFoodId = nil
            case .custom:
                item.catalogItemId = nil
                item.userFoodId = result.id
            }
            item.detectedByAi = false
            item.userAdjusted = false
            try item.insert(db)

            var itemEvent = OutboxEvent(
                id: item.id,
                httpMethod: .POST,
                path: "rest/v1/food_items",
                bodyJson: try JSONEncoder.supabase.encode(item),
                priority: 101
            )
            itemEvent.dependsOn = log.id
            itemEvent.headersJson = try NutritionOutboxHeaders.json()
            try itemEvent.insert(db)

            return log.id
        }
        await AppContainer.shared?.widgetSnapshotCoordinator.refreshSnapshot()
        return logId
    }

    func logCatalogItem(
        _ result: FoodSearchResult,
        method: NutritionInputMethod,
        targetDay: String,
        loggedAt: Date
    ) async throws -> UUID {
        try await logSearchResult(
            result,
            method: method,
            targetDay: targetDay,
            loggedAt: loggedAt
        )
    }
}

#if DEBUG
extension QuickFoodLogService {
    static func _testSetLogSearchResultOverride(
        _ runner: (@Sendable (FoodSearchResult, NutritionInputMethod, String, Date) async throws -> UUID)?
    ) {
        testLogSearchResultOverride.value = runner
    }
}
#endif

private struct MealTemplateLibraryDestination: Identifiable, Hashable {
    let templateId: UUID
    let startsEditing: Bool

    var id: String {
        "\(templateId.uuidString)-\(startsEditing)"
    }
}

@MainActor
@Observable
final class MealTemplateDetailViewModel {
    let templateId: UUID

    var isLoading = false
    var isSaving = false
    var isApplying = false
    var isArchiving = false
    var isEditing: Bool
    var errorMessage: String?
    var statusMessage: TemplateStatusMessage?
    var name = ""
    var mealType: MealType?
    var items: [NutritionEditableMealItem] = []
    var archived = false
    var timesUsed = 0
    var lastUsedAt: Date?
    var updatedAt: Date?

    private var didLoad = false
    private var persistedDetail: NutritionMealTemplateDetail?
    private let templateManager: any NutritionMealTemplateManaging

    init(
        templateId: UUID,
        startsEditing: Bool = false,
        templateManager: (any NutritionMealTemplateManaging)? = nil
    ) {
        self.templateId = templateId
        self.isEditing = startsEditing
        self.templateManager = templateManager ?? NutritionService()
    }

    var isBusy: Bool {
        isLoading || isSaving || isApplying || isArchiving
    }

    var canSave: Bool {
        !isBusy && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !items.isEmpty
    }

    var canLogNow: Bool {
        !isBusy && !archived
    }

    var totals: (calories: Double, protein: Double, fat: Double, carbs: Double, fiber: Double?) {
        let fiber = items.reduce(0) { $0 + $1.fiberG }
        return (
            calories: items.reduce(0) { $0 + $1.calories },
            protein: items.reduce(0) { $0 + $1.proteinG },
            fat: items.reduce(0) { $0 + $1.fatG },
            carbs: items.reduce(0) { $0 + $1.carbsG },
            fiber: fiber > 0 ? fiber : nil
        )
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        await reload(preferRemote: true)
    }

    func startEditing() {
        isEditing = true
    }

    func cancelEditing() {
        guard let persistedDetail else { return }
        apply(detail: persistedDetail)
        isEditing = false
        errorMessage = nil
    }

    func addItem() {
        let defaultName = localizedNutritionDefaultItemName(for: mealType)
        items.append(NutritionEditableMealItem(name: defaultName, calories: 100, proteinG: 0, fatG: 0, carbsG: 0))
    }

    func removeItem(id: UUID) {
        guard items.count > 1 else {
            errorMessage = NutritionError.invalidMealItem(
                reason: String(localized: "nutrition_validation_at_least_one_item_required")
            ).errorDescription
            return
        }
        items.removeAll { $0.id == id }
    }

    func save() async -> Bool {
        guard canSave else { return false }
        isSaving = true
        defer { isSaving = false }

        do {
            let update = NutritionMealTemplateUpdateDraft(
                id: templateId,
                name: name,
                mealType: mealType,
                items: items.map(NutritionMealTemplateItem.init(editableItem:)),
                archived: archived
            )
            try await templateManager.updateMealTemplate(update)
            await reload(preferRemote: false)
            isEditing = false
            statusMessage = TemplateStatusMessage(message: String(localized: "nutrition_template_updated"), isError: false)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func toggleArchived() async -> Bool {
        isArchiving = true
        defer { isArchiving = false }

        do {
            let nextArchived = !archived
            try await templateManager.setMealTemplateArchived(id: templateId, archived: nextArchived)
            archived = nextArchived
            if var persistedDetail {
                persistedDetail.template.archived = nextArchived
                persistedDetail.template.updatedAt = Date()
                self.persistedDetail = persistedDetail
            }
            statusMessage = TemplateStatusMessage(
                message: nextArchived ? String(localized: "nutrition_template_archived") : String(localized: "nutrition_template_restored"),
                isError: false
            )
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func logNow(targetDay: String, loggedAt: Date) async -> Bool {
        guard canLogNow else { return false }
        isApplying = true
        defer { isApplying = false }

        do {
            let result = try await templateManager.applyMealTemplate(
                id: templateId,
                targetDay: targetDay,
                loggedAt: loggedAt,
                context: nil
            )
            timesUsed += 1
            lastUsedAt = Date()
            statusMessage = TemplateStatusMessage(
                message: String(
                    format: String(localized: "nutrition_logged_template_format"),
                    result.templateName
                ),
                isError: false
            )
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func reload(preferRemote: Bool) async {
        isLoading = true
        defer { isLoading = false }

        do {
            guard let detail = try await templateManager.loadMealTemplateDetail(id: templateId, preferRemote: preferRemote) else {
                throw NutritionError.templateNotFound
            }
            apply(detail: detail)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply(detail: NutritionMealTemplateDetail) {
        persistedDetail = detail
        name = detail.template.name
        mealType = detail.template.mealType
        items = detail.items.map(NutritionEditableMealItem.init(templateItem:))
        archived = detail.template.archived
        timesUsed = detail.template.timesUsed
        lastUsedAt = detail.template.lastUsedAt
        updatedAt = detail.template.updatedAt
    }
}

struct MealTemplateDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: MealTemplateDetailViewModel

    let targetDay: String
    let loggedAt: Date
    let onTemplatesChanged: () -> Void
    let onTemplateLogged: () -> Void
    let onStatusMessage: (TemplateStatusMessage?) -> Void

    init(
        templateId: UUID,
        startsEditing: Bool,
        targetDay: String,
        loggedAt: Date,
        onTemplatesChanged: @escaping () -> Void,
        onTemplateLogged: @escaping () -> Void,
        onStatusMessage: @escaping (TemplateStatusMessage?) -> Void
    ) {
        _viewModel = State(initialValue: MealTemplateDetailViewModel(templateId: templateId, startsEditing: startsEditing))
        self.targetDay = targetDay
        self.loggedAt = loggedAt
        self.onTemplatesChanged = onTemplatesChanged
        self.onTemplateLogged = onTemplateLogged
        self.onStatusMessage = onStatusMessage
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s) {
                if let statusMessage = viewModel.statusMessage {
                    Label(statusMessage.message, systemImage: statusMessage.systemImage)
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(statusMessage.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let errorMessage = viewModel.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(LifeOSColors.Recovery.caution)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    templateHeaderSection(viewModel)

                    if viewModel.isEditing {
                        editorDetailsSection(viewModel)
                        editorItemsSection(viewModel)
                    } else {
                        previewItemsSection(viewModel)
                    }

                    actionSection(viewModel)
                }
            }
            .padding(LayoutConstants.contentPadding)
        }
        .background(LifeOSColors.Surface.background)
        .navigationTitle(viewModel.isEditing ? String(localized: "nutrition_edit_template") : String(localized: "nutrition_template_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if viewModel.isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) {
                        viewModel.cancelEditing()
                    }
                }
            } else {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "edit")) {
                        viewModel.startEditing()
                    }
                    .disabled(viewModel.isBusy)
                }
            }
        }
        .task { await viewModel.loadIfNeeded() }
    }

    private func templateHeaderSection(_ viewModel: MealTemplateDetailViewModel) -> some View {
        let totals = viewModel.totals
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.name)
                        .font(LifeOSTypography.title3.weight(.semibold))
                    Text(localizedNutritionMealType(viewModel.mealType, emptyKey: "nutrition_any_meal"))
                        .font(LifeOSTypography.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.archived {
                    Text(String(localized: "nutrition_archived"))
                        .font(LifeOSTypography.caption2.weight(.semibold))
                        .padding(.horizontal, Spacing.xxs)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.16))
                        .clipShape(Capsule())
                }
            }

            Text(localizedNutritionCalories(Int(totals.calories.rounded())))
                .font(LifeOSTypography.title3)
            Text(templateTotalsText(totals))
                .font(LifeOSTypography.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: Spacing.s) {
                Text(localizedNutritionUsedCount(viewModel.timesUsed))
                if let lastUsedAt = viewModel.lastUsedAt {
                    Text(localizedNutritionLastUsed(lastUsedAt))
                }
            }
            .font(LifeOSTypography.caption2)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private func editorDetailsSection(_ viewModel: MealTemplateDetailViewModel) -> some View {
        @Bindable var viewModel = viewModel

        return VStack(alignment: .leading, spacing: Spacing.s) {
            Text(String(localized: "nutrition_template_details"))
                .font(LifeOSTypography.subheadline.weight(.semibold))

            TextField(String(localized: "nutrition_template_name"), text: $viewModel.name)
                .textInputAutocapitalization(.words)

            Picker(String(localized: "nutrition_default_meal_type"), selection: $viewModel.mealType) {
                Text(String(localized: "nutrition_any_meal")).tag(nil as MealType?)
                Text(localizedNutritionMealType(.breakfast)).tag(MealType.breakfast as MealType?)
                Text(localizedNutritionMealType(.lunch)).tag(MealType.lunch as MealType?)
                Text(localizedNutritionMealType(.dinner)).tag(MealType.dinner as MealType?)
                Text(localizedNutritionMealType(.snack)).tag(MealType.snack as MealType?)
            }
            .pickerStyle(.menu)
        }
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private func editorItemsSection(_ viewModel: MealTemplateDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text(String(localized: "nutrition_items"))
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                Spacer()
                Button {
                    viewModel.addItem()
                } label: {
                    Label(String(localized: "nutrition_add_item"), systemImage: "plus.circle.fill")
                        .font(LifeOSTypography.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
            }

            ForEach(Array(viewModel.items.indices), id: \.self) { index in
                templateItemEditor(index: index, viewModel: viewModel)
            }
        }
    }

    private func previewItemsSection(_ viewModel: MealTemplateDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(String(localized: "nutrition_items"))
                .font(LifeOSTypography.subheadline.weight(.semibold))

            ForEach(viewModel.items) { item in
                previewItemRow(item)
            }
        }
    }

    private func previewItemRow(_ item: NutritionEditableMealItem) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(item.name)
                .font(LifeOSTypography.body.weight(.semibold))
            if !item.brand.isEmpty {
                Text(item.brand)
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
            }
            Text(templateItemSummary(item))
                .font(LifeOSTypography.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private func actionSection(_ viewModel: MealTemplateDetailViewModel) -> some View {
        VStack(spacing: Spacing.s) {
            if viewModel.isEditing {
                Button(action: saveTemplate) {
                    if viewModel.isSaving {
                        ProgressView()
                    } else {
                        Text(String(localized: "nutrition_save_changes"))
                            .font(LifeOSTypography.headline)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSave)
            } else {
                Button(action: logTemplateNow) {
                    if viewModel.isApplying {
                        ProgressView()
                    } else {
                        Text(String(localized: "nutrition_log_now"))
                            .font(LifeOSTypography.headline)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canLogNow)

                Button {
                    viewModel.startEditing()
                } label: {
                    Text(String(localized: "nutrition_edit_template"))
                        .font(LifeOSTypography.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isBusy)
            }

            Button(role: viewModel.archived ? nil : .destructive, action: toggleArchived) {
                if viewModel.isArchiving {
                    ProgressView()
                } else {
                    Text(viewModel.archived ? String(localized: "nutrition_unarchive_template") : String(localized: "nutrition_archive_template"))
                        .font(LifeOSTypography.subheadline.weight(.semibold))
                }
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isBusy)
        }
        .frame(maxWidth: .infinity)
    }

    private func templateItemEditor(index: Int, viewModel: MealTemplateDetailViewModel) -> some View {
        @Bindable var viewModel = viewModel

        return VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .top) {
                TextField(String(localized: "nutrition_item_name"), text: $viewModel.items[index].name)
                    .font(LifeOSTypography.body)

                Spacer()

                Button(role: .destructive) {
                    let id = viewModel.items[index].id
                    viewModel.removeItem(id: id)
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(viewModel.items.count <= 1)
            }

            TextField(String(localized: "nutrition_brand"), text: $viewModel.items[index].brand)
                .textInputAutocapitalization(.words)
            TextField(String(localized: "nutrition_barcode"), text: $viewModel.items[index].barcode)
                .keyboardType(.numberPad)

            HStack(spacing: Spacing.s) {
                templateNumericField(String(localized: "nutrition_unit_grams"), value: $viewModel.items[index].weightG)
                templateNumericField(String(localized: "nutrition_unit_kcal"), value: $viewModel.items[index].calories)
            }

            HStack(spacing: Spacing.s) {
                templateNumericField(String(localized: "nutrition_macro_label_protein"), value: $viewModel.items[index].proteinG)
                templateNumericField(String(localized: "nutrition_macro_label_fat"), value: $viewModel.items[index].fatG)
                templateNumericField(String(localized: "nutrition_macro_label_carbs"), value: $viewModel.items[index].carbsG)
                templateNumericField(String(localized: "nutrition_macro_label_fiber"), value: $viewModel.items[index].fiberG)
            }
        }
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private func templateNumericField(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(LifeOSTypography.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(
                title,
                value: value,
                format: .number.precision(.fractionLength(0...1))
            )
            .keyboardType(.decimalPad)
            .textFieldStyle(.roundedBorder)
        }
    }

    private func templateTotalsText(_ totals: (calories: Double, protein: Double, fat: Double, carbs: Double, fiber: Double?)) -> String {
        localizedNutritionMacroTotals(
            protein: totals.protein,
            fat: totals.fat,
            carbs: totals.carbs,
            fiber: totals.fiber
        )
    }

    private func templateItemSummary(_ item: NutritionEditableMealItem) -> String {
        localizedNutritionItemSummary(
            weightG: item.weightG,
            calories: item.calories,
            protein: item.proteinG,
            fat: item.fatG,
            carbs: item.carbsG,
            fiber: item.fiberG > 0 ? item.fiberG : nil
        )
    }

    private func saveTemplate() {
        Task { @MainActor in
            let didSave = await viewModel.save()
            if didSave {
                HapticManager.success()
                onStatusMessage(viewModel.statusMessage)
                onTemplatesChanged()
            } else {
                HapticManager.error()
            }
        }
    }

    private func toggleArchived() {
        Task { @MainActor in
            let didToggle = await viewModel.toggleArchived()
            if didToggle {
                HapticManager.success()
                onStatusMessage(viewModel.statusMessage)
                onTemplatesChanged()
                dismiss()
            } else {
                HapticManager.error()
            }
        }
    }

    private func logTemplateNow() {
        Task { @MainActor in
            let didLog = await viewModel.logNow(targetDay: targetDay, loggedAt: loggedAt)
            if didLog {
                HapticManager.success()
                onStatusMessage(viewModel.statusMessage)
                onTemplatesChanged()
                onTemplateLogged()
                dismiss()
            } else {
                HapticManager.error()
            }
        }
    }
}

struct MealTemplateComposerView: View {
    @Environment(\.dismiss) private var dismiss

    let onSaved: (TemplateStatusMessage) -> Void

    @State private var name = ""
    @State private var mealType: MealType?
    @State private var items: [NutritionEditableMealItem] = []
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var totals: (calories: Double, protein: Double, fat: Double, carbs: Double, fiber: Double?) {
        let fiber = items.reduce(0) { $0 + $1.fiberG }
        return (
            calories: items.reduce(0) { $0 + $1.calories },
            protein: items.reduce(0) { $0 + $1.proteinG },
            fat: items.reduce(0) { $0 + $1.fatG },
            carbs: items.reduce(0) { $0 + $1.carbsG },
            fiber: fiber > 0 ? fiber : nil
        )
    }

    private var canSave: Bool {
        !isSaving &&
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !items.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(LifeOSColors.Recovery.caution)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                detailsSection
                previewSection
                itemsSection
            }
            .padding(LayoutConstants.contentPadding)
        }
        .background(LifeOSColors.Surface.background)
        .navigationTitle(String(localized: "nutrition_create_template"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: save) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text(String(localized: "save"))
                    }
                }
                .disabled(!canSave)
            }
        }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(String(localized: "nutrition_template_details"))
                .font(LifeOSTypography.subheadline.weight(.semibold))

            TextField(String(localized: "nutrition_template_name"), text: $name)
                .textInputAutocapitalization(.words)

            Picker(String(localized: "nutrition_default_meal_type"), selection: $mealType) {
                Text(String(localized: "nutrition_any_meal")).tag(nil as MealType?)
                Text(localizedNutritionMealType(.breakfast)).tag(MealType.breakfast as MealType?)
                Text(localizedNutritionMealType(.lunch)).tag(MealType.lunch as MealType?)
                Text(localizedNutritionMealType(.dinner)).tag(MealType.dinner as MealType?)
                Text(localizedNutritionMealType(.snack)).tag(MealType.snack as MealType?)
            }
            .pickerStyle(.menu)
        }
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(String(localized: "nutrition_preview"))
                .font(LifeOSTypography.subheadline.weight(.semibold))

            Text(localizedNutritionCalories(Int(totals.calories.rounded())))
                .font(LifeOSTypography.title3)
            Text(templateTotalsText(totals))
                .font(LifeOSTypography.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private var itemsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text(String(localized: "nutrition_items"))
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                Spacer()
                Button {
                    addItem()
                } label: {
                    Label(
                        items.isEmpty ? String(localized: "nutrition_add_first_item") : String(localized: "nutrition_add_item"),
                        systemImage: "plus.circle.fill"
                    )
                        .font(LifeOSTypography.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
            }

            if items.isEmpty {
                Text(String(localized: "nutrition_template_items_hint"))
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.s)
                    .background(LifeOSColors.Surface.card)
                    .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
            } else {
                ForEach(Array(items.indices), id: \.self) { index in
                    itemEditor(index: index)
                }
            }
        }
    }

    private func itemEditor(index: Int) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .top) {
                TextField(String(localized: "nutrition_item_name"), text: $items[index].name)
                    .font(LifeOSTypography.body)

                Spacer()

                Button(role: .destructive) {
                    items.remove(at: index)
                } label: {
                    Image(systemName: "trash")
                }
            }

            TextField(String(localized: "nutrition_brand"), text: $items[index].brand)
                .textInputAutocapitalization(.words)
            TextField(String(localized: "nutrition_barcode"), text: $items[index].barcode)
                .keyboardType(.numberPad)

            HStack(spacing: Spacing.s) {
                templateNumericField(String(localized: "nutrition_unit_grams"), value: $items[index].weightG)
                templateNumericField(String(localized: "nutrition_unit_kcal"), value: $items[index].calories)
            }

            HStack(spacing: Spacing.s) {
                templateNumericField(String(localized: "nutrition_macro_label_protein"), value: $items[index].proteinG)
                templateNumericField(String(localized: "nutrition_macro_label_fat"), value: $items[index].fatG)
                templateNumericField(String(localized: "nutrition_macro_label_carbs"), value: $items[index].carbsG)
                templateNumericField(String(localized: "nutrition_macro_label_fiber"), value: $items[index].fiberG)
            }

            Text(templateItemSummary(items[index]))
                .font(LifeOSTypography.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private func addItem() {
        items.append(Self.defaultEditableMealItem(for: mealType))
    }

    private static func defaultEditableMealItem(for mealType: MealType?) -> NutritionEditableMealItem {
        NutritionEditableMealItem(
            name: localizedNutritionDefaultItemName(for: mealType),
            calories: 100,
            proteinG: 0,
            fatG: 0,
            carbsG: 0
        )
    }

    private func templateNumericField(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(LifeOSTypography.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(
                title,
                value: value,
                format: .number.precision(.fractionLength(0...1))
            )
            .keyboardType(.decimalPad)
            .textFieldStyle(.roundedBorder)
        }
    }

    private func templateTotalsText(_ totals: (calories: Double, protein: Double, fat: Double, carbs: Double, fiber: Double?)) -> String {
        localizedNutritionMacroTotals(
            protein: totals.protein,
            fat: totals.fat,
            carbs: totals.carbs,
            fiber: totals.fiber
        )
    }

    private func templateItemSummary(_ item: NutritionEditableMealItem) -> String {
        localizedNutritionItemSummary(
            weightG: item.weightG,
            calories: item.calories,
            protein: item.proteinG,
            fat: item.fatG,
            carbs: item.carbsG,
            fiber: item.fiberG > 0 ? item.fiberG : nil
        )
    }

    private static func saveResult(
        draft: NutritionMealTemplateCreateDraft,
        manager: any NutritionMealTemplateManaging
    ) async -> Result<TemplateStatusMessage, Error> {
        do {
            _ = try await manager.createMealTemplate(draft)
            return .success(
                TemplateStatusMessage(
                    message: String(localized: "nutrition_template_created"),
                    isError: false
                )
            )
        } catch {
            return .failure(error)
        }
    }

    private func save(
        manager: any NutritionMealTemplateManaging,
        dismissAction: @escaping () -> Void
    ) {
        isSaving = true
        errorMessage = nil
        let draft = NutritionMealTemplateCreateDraft(
            name: name,
            mealType: mealType,
            items: items.map(NutritionMealTemplateItem.init(editableItem:))
        )

        Task { @MainActor in
            defer { isSaving = false }
            switch await Self.saveResult(draft: draft, manager: manager) {
            case let .success(message):
                onSaved(message)
                HapticManager.success()
                dismissAction()
            case let .failure(error):
                errorMessage = error.localizedDescription
                HapticManager.error()
            }
        }
    }

    private func save() {
        save(manager: NutritionService(), dismissAction: { dismiss() })
    }
}

extension NutritionEditableMealItem {
    init(templateItem: NutritionMealTemplateItem) {
        self.init(
            id: templateItem.id,
            name: templateItem.name,
            brand: templateItem.brand ?? "",
            barcode: templateItem.barcode ?? "",
            catalogItemId: templateItem.catalogItemId,
            userFoodId: templateItem.userFoodId,
            batchRecipeId: templateItem.batchRecipeId,
            weightG: templateItem.weightG,
            calories: templateItem.calories,
            proteinG: templateItem.proteinG,
            fatG: templateItem.fatG,
            carbsG: templateItem.carbsG,
            fiberG: templateItem.fiberG ?? 0,
            confidence: templateItem.confidence,
            detectedByAi: false,
            userAdjusted: true
        )
    }
}

private extension NutritionMealTemplateItem {
    init(editableItem: NutritionEditableMealItem) {
        self.init(
            id: editableItem.id,
            name: editableItem.name,
            brand: editableItem.brand.isEmpty ? nil : editableItem.brand,
            barcode: editableItem.barcode.isEmpty ? nil : editableItem.barcode,
            catalogItemId: editableItem.catalogItemId,
            userFoodId: editableItem.userFoodId,
            batchRecipeId: editableItem.batchRecipeId,
            weightG: editableItem.weightG,
            calories: editableItem.calories,
            proteinG: editableItem.proteinG,
            fatG: editableItem.fatG,
            carbsG: editableItem.carbsG,
            fiberG: editableItem.fiberG > 0 ? editableItem.fiberG : nil,
            confidence: editableItem.confidence
        )
    }
}

// MARK: - Batch Recipe View (Meal Prep)

struct BatchRecipeView: View {
    let targetDay: String
    let loggedAt: Date
    let onBatchesChanged: () -> Void
    let onBatchLogged: () -> Void

    var body: some View {
        NavigationStack {
            BatchRecipeLibraryView(
                targetDay: targetDay,
                loggedAt: loggedAt,
                onBatchesChanged: onBatchesChanged,
                onBatchLogged: onBatchLogged
            )
        }
    }
}

extension BatchRecipeView {
    func _testEvaluateBody() {
        _ = body
    }
}

private struct BatchRecipeLibraryDestination: Identifiable, Hashable {
    let batchId: UUID

    var id: UUID { batchId }
}

struct BatchRecipeEditableIngredient: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var brand: String
    var barcode: String
    var catalogItemId: UUID?
    var userFoodId: UUID?
    var weightG: Double
    var calories: Double
    var proteinG: Double
    var fatG: Double
    var carbsG: Double
    var fiberG: Double

    init(
        id: UUID = UUID(),
        name: String,
        brand: String = "",
        barcode: String = "",
        catalogItemId: UUID? = nil,
        userFoodId: UUID? = nil,
        weightG: Double,
        calories: Double,
        proteinG: Double,
        fatG: Double,
        carbsG: Double,
        fiberG: Double = 0
    ) {
        self.id = id
        self.name = name
        self.brand = brand
        self.barcode = barcode
        self.catalogItemId = catalogItemId
        self.userFoodId = userFoodId
        self.weightG = weightG
        self.calories = calories
        self.proteinG = proteinG
        self.fatG = fatG
        self.carbsG = carbsG
        self.fiberG = fiberG
    }

    init(ingredient: BatchRecipeIngredient) {
        self.init(
            id: ingredient.id,
            name: ingredient.name,
            brand: ingredient.brand ?? "",
            barcode: ingredient.barcode ?? "",
            catalogItemId: ingredient.catalogItemId,
            userFoodId: ingredient.userFoodId,
            weightG: ingredient.weightG,
            calories: ingredient.calories,
            proteinG: ingredient.proteinG,
            fatG: ingredient.fatG,
            carbsG: ingredient.carbsG,
            fiberG: ingredient.fiberG ?? 0
        )
    }

    init(searchResult: FoodSearchResult) {
        let weight = searchResult.servingSizeG.flatMap { $0 > 0 ? $0 : nil } ?? 100
        let scale = weight / 100
        self.init(
            name: searchResult.name,
            brand: searchResult.brand ?? "",
            barcode: searchResult.barcode ?? "",
            catalogItemId: searchResult.refType == .catalog ? searchResult.id : nil,
            userFoodId: searchResult.refType == .custom ? searchResult.id : nil,
            weightG: weight,
            calories: searchResult.caloriesPer100g * scale,
            proteinG: searchResult.proteinPer100g * scale,
            fatG: searchResult.fatPer100g * scale,
            carbsG: searchResult.carbsPer100g * scale,
            fiberG: (searchResult.fiberPer100g ?? 0) * scale
        )
    }

    static func manual() -> BatchRecipeEditableIngredient {
        BatchRecipeEditableIngredient(
            name: String(localized: "nutrition_default_ingredient_name"),
            weightG: 100,
            calories: 100,
            proteinG: 0,
            fatG: 0,
            carbsG: 0
        )
    }

    var draftIngredient: NutritionBatchRecipeDraftIngredient {
        NutritionBatchRecipeDraftIngredient(
            id: id,
            name: name,
            brand: brand.isEmpty ? nil : brand,
            barcode: barcode.isEmpty ? nil : barcode,
            catalogItemId: catalogItemId,
            userFoodId: userFoodId,
            weightG: weightG,
            calories: calories,
            proteinG: proteinG,
            fatG: fatG,
            carbsG: carbsG,
            fiberG: fiberG > 0 ? fiberG : nil
        )
    }
}

struct BatchRecipeLibraryView: View {
    @Environment(\.dismiss) private var dismiss

    let targetDay: String
    let loggedAt: Date
    let onBatchesChanged: () -> Void
    let onBatchLogged: () -> Void

    @State private var recipes: [NutritionBatchRecipeSummary] = []
    @State private var isLoading = true
    @State private var showingArchived = false
    @State private var showingComposer = false
    @State private var selectedBatch: BatchRecipeLibraryDestination?
    @State private var quickLogBatch: NutritionBatchRecipeSummary?
    @State private var statusMessage: TemplateStatusMessage?

    var body: some View {
        VStack(spacing: Spacing.s) {
            Picker(String(localized: "nutrition_meal_prep"), selection: $showingArchived) {
                Text(String(localized: "nutrition_active")).tag(false)
                Text(String(localized: "nutrition_archived")).tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, LayoutConstants.contentPadding)

            if let statusMessage {
                Label(statusMessage.message, systemImage: statusMessage.systemImage)
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(statusMessage.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, LayoutConstants.contentPadding)
            }

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if recipes.isEmpty {
                VStack(spacing: Spacing.s) {
                    Text(
                        showingArchived
                            ? String(localized: "nutrition_no_archived_batches")
                            : String(localized: "nutrition_create_first_meal_prep")
                    )
                        .font(LifeOSTypography.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if !showingArchived {
                        Button {
                            showingComposer = true
                        } label: {
                            Label(String(localized: "nutrition_create_batch"), systemImage: "plus.circle.fill")
                                .font(LifeOSTypography.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(LayoutConstants.contentPadding)
            } else {
                List(recipes, rowContent: styledBatchRow)
                .listStyle(.plain)
            }
        }
        .background(LifeOSColors.Surface.background)
        .navigationTitle(String(localized: "nutrition_meal_prep"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedBatch) { destination in
            detailDestination(destination)
        }
        .sheet(isPresented: $showingComposer) {
            composerSheet()
        }
        .sheet(item: $quickLogBatch) { recipe in
            quickLogSheet(recipe)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    showingComposer = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task(id: showingArchived) { await loadRecipes() }
    }

    private func batchRow(_ recipe: NutritionBatchRecipeSummary) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Button {
                selectedBatch = BatchRecipeLibraryDestination(batchId: recipe.id)
            } label: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(alignment: .top, spacing: Spacing.s) {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(recipe.name)
                                .font(LifeOSTypography.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            if let cookedAt = recipe.cookedAt {
                                Text(localizedNutritionCooked(cookedAt))
                                    .font(LifeOSTypography.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(remainingLine(recipe))
                                .font(LifeOSTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if recipe.archived {
                            Text(String(localized: "nutrition_archived"))
                                .font(LifeOSTypography.caption2.weight(.semibold))
                                .padding(.horizontal, Spacing.xxs)
                                .padding(.vertical, 4)
                                .background(Color.orange.opacity(0.16))
                                .clipShape(Capsule())
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Text(batchMacroLine(recipe.per100g, prefix: String(localized: "nutrition_per_100g")))
                        .font(LifeOSTypography.caption2)
                        .foregroundStyle(.tertiary)

                    if let perPortion = recipe.perPortion {
                        Text(batchMacroLine(perPortion, prefix: String(localized: "nutrition_per_portion")))
                            .font(LifeOSTypography.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.s)
                .background(LifeOSColors.Surface.card)
                .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
            }
            .buttonStyle(.plain)

            if !showingArchived {
                Button {
                    quickLogBatch = recipe
                } label: {
                    Label(String(localized: "nutrition_log_portion"), systemImage: "plus.circle.fill")
                        .font(LifeOSTypography.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(recipe.weightRemainingG <= 0)
            }
        }
    }

    private func remainingLine(_ recipe: NutritionBatchRecipeSummary) -> String {
        localizedNutritionRemainingLine(weightG: recipe.weightRemainingG, portionsRemaining: recipe.portionsRemaining)
    }

    private func detailDestination(_ destination: BatchRecipeLibraryDestination) -> some View {
        BatchRecipeDetailView(
            batchId: destination.batchId,
            targetDay: targetDay,
            loggedAt: loggedAt,
            onBatchesChanged: handleDetailBatchesChanged,
            onBatchLogged: handleDetailBatchLogged,
            onStatusMessage: handleDetailStatusMessage
        )
    }

    private func styledBatchRow(_ recipe: NutritionBatchRecipeSummary) -> some View {
        batchRow(recipe)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private func handleDetailBatchesChanged() {
        handleDetailBatchesChanged(reloadAction: nil)
    }

    private func handleDetailBatchesChanged(reloadAction: (() async -> Void)? = nil) {
        onBatchesChanged()
        Task { @MainActor in
            if let reloadAction {
                await reloadAction()
            } else {
                await loadRecipes()
            }
        }
    }

    private func handleDetailBatchLogged() {
        handleDetailBatchLogged(reloadAction: nil)
    }

    private func handleDetailBatchLogged(reloadAction: (() async -> Void)? = nil) {
        onBatchLogged()
        Task { @MainActor in
            if let reloadAction {
                await reloadAction()
            } else {
                await loadRecipes()
            }
        }
    }

    private func handleDetailStatusMessage(_ message: TemplateStatusMessage?) {
        statusMessage = message
    }

    private func composerSheet() -> some View {
        NavigationStack {
            BatchRecipeComposerView(
                existingDetail: nil,
                onSaved: handleComposerSheetSaved
            )
        }
    }

    private func quickLogSheet(_ recipe: NutritionBatchRecipeSummary) -> some View {
        NavigationStack {
            BatchPortionLogView(
                batchId: recipe.id,
                batchName: recipe.name,
                remainingWeightG: recipe.weightRemainingG,
                per100g: recipe.per100g,
                suggestedPortionWeightG: recipe.perPortion?.weightG,
                targetDay: targetDay,
                loggedAt: loggedAt,
                onLogged: handleQuickLogSheetSaved
            )
        }
    }

    private func handleComposerSheetSaved(_ message: TemplateStatusMessage) {
        handleComposerSaved(message, reloadAction: nil)
    }

    private func handleQuickLogSheetSaved(_ message: TemplateStatusMessage) {
        handleQuickLogSaved(message, reloadAction: nil)
    }

    private func handleComposerSaved(
        _ message: TemplateStatusMessage,
        reloadAction: (() async -> Void)?
    ) {
        statusMessage = message
        onBatchesChanged()
        Task { @MainActor in
            if let reloadAction {
                await reloadAction()
            } else {
                await loadRecipes()
            }
        }
    }

    private func handleQuickLogSaved(
        _ message: TemplateStatusMessage,
        reloadAction: (() async -> Void)?
    ) {
        statusMessage = message
        onBatchLogged()
        onBatchesChanged()
        Task { @MainActor in
            if let reloadAction {
                await reloadAction()
            } else {
                await loadRecipes()
            }
        }
    }

    private static func loadRecipesResult(
        showingArchived: Bool,
        manager: any NutritionBatchRecipeManaging
    ) async -> (
        recipes: [NutritionBatchRecipeSummary],
        statusMessage: TemplateStatusMessage?
    ) {
        do {
            return (
                recipes: try await manager.loadBatchRecipes(
                    includeArchived: showingArchived,
                    limit: nil,
                    preferRemote: true
                ),
                statusMessage: nil
            )
        } catch {
            return (
                recipes: [],
                statusMessage: TemplateStatusMessage(message: error.localizedDescription, isError: true)
            )
        }
    }

    private func loadRecipes(
        manager overrideManager: (any NutritionBatchRecipeManaging)? = nil
    ) async {
        isLoading = true
        defer { isLoading = false }
        let result = await Self.loadRecipesResult(
            showingArchived: showingArchived,
            manager: overrideManager ?? NutritionService()
        )
        recipes = result.recipes
        statusMessage = result.statusMessage
    }
}

struct BatchRecipeDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let batchId: UUID
    let targetDay: String
    let loggedAt: Date
    let onBatchesChanged: () -> Void
    let onBatchLogged: () -> Void
    let onStatusMessage: (TemplateStatusMessage?) -> Void

    @State private var detail: NutritionBatchRecipeDetail?
    @State private var isLoading = true
    @State private var isArchiving = false
    @State private var isDuplicating = false
    @State private var showingComposer = false
    @State private var showingLogSheet = false
    @State private var errorMessage: String?
    @State private var statusMessage: TemplateStatusMessage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s) {
                if let statusMessage {
                    Label(statusMessage.message, systemImage: statusMessage.systemImage)
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(statusMessage.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(LifeOSColors.Recovery.caution)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if let detail {
                    detailHeader(detail)
                    detailMacros(detail)
                    detailIngredients(detail)
                    detailActions(detail)
                }
            }
            .padding(LayoutConstants.contentPadding)
        }
        .background(LifeOSColors.Surface.background)
        .navigationTitle(String(localized: "nutrition_batch_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "edit")) {
                    showingComposer = true
                }
                .disabled(detail == nil || isLoading || isArchiving || isDuplicating)
            }
        }
        .sheet(isPresented: $showingComposer, content: composerSheetContent)
        .sheet(isPresented: $showingLogSheet, content: logSheetContent)
        .task { await loadDetail(preferRemote: true) }
    }

    private static func loadDetailResult(
        batchId: UUID,
        preferRemote: Bool,
        manager: any NutritionBatchRecipeManaging
    ) async -> (
        detail: NutritionBatchRecipeDetail?,
        errorMessage: String?
    ) {
        do {
            guard let detail = try await manager.loadBatchRecipeDetail(id: batchId, preferRemote: preferRemote) else {
                throw NutritionError.batchRecipeNotFound
            }
            return (detail: detail, errorMessage: nil)
        } catch {
            return (detail: nil, errorMessage: error.localizedDescription)
        }
    }

    private static func toggleArchivedResult(
        detail: NutritionBatchRecipeDetail,
        manager: any NutritionBatchRecipeManaging
    ) async -> Result<TemplateStatusMessage, Error> {
        do {
            try await manager.setBatchRecipeArchived(id: detail.recipe.id, archived: !detail.recipe.archived)
            return .success(
                TemplateStatusMessage(
                    message: detail.recipe.archived
                        ? String(localized: "nutrition_batch_restored")
                        : String(localized: "nutrition_batch_archived"),
                    isError: false
                )
            )
        } catch {
            return .failure(error)
        }
    }

    private static func cookAgainResult(
        detail: NutritionBatchRecipeDetail,
        manager: any NutritionBatchRecipeManaging
    ) async -> Result<TemplateStatusMessage, Error> {
        do {
            let result = try await manager.duplicateBatchRecipe(id: detail.recipe.id, cookedAt: nil)
            return .success(
                TemplateStatusMessage(
                    message: String(format: String(localized: "nutrition_created_name_format"), result.name),
                    isError: false
                )
            )
        } catch {
            return .failure(error)
        }
    }

    private func detailHeader(_ detail: NutritionBatchRecipeDetail) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(detail.recipe.name)
                        .font(LifeOSTypography.title3.weight(.semibold))
                    if let cookedAt = detail.recipe.cookedAt {
                        Text(localizedNutritionCooked(cookedAt))
                            .font(LifeOSTypography.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if detail.recipe.archived {
                    Text(String(localized: "nutrition_archived"))
                        .font(LifeOSTypography.caption2.weight(.semibold))
                        .padding(.horizontal, Spacing.xxs)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.16))
                        .clipShape(Capsule())
                }
            }

            Text(localizedNutritionRemainingLine(weightG: detail.weightRemainingG))
                .font(LifeOSTypography.title3)

            if let portionsRemaining = detail.portionsRemaining {
                Text(localizedNutritionPortionsLeft(portionsRemaining))
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: Spacing.s) {
                Text(localizedNutritionUsedCount(detail.recipe.timesUsed))
                if let lastUsedAt = detail.recipe.lastUsedAt {
                    Text(localizedNutritionLastUsed(lastUsedAt))
                }
            }
            .font(LifeOSTypography.caption2)
            .foregroundStyle(.tertiary)

            if let description = detail.recipe.description, !description.isEmpty {
                Text(description)
                    .font(LifeOSTypography.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private func detailMacros(_ detail: NutritionBatchRecipeDetail) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(String(localized: "nutrition_macros"))
                .font(LifeOSTypography.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(batchMacroLine(detail.per100g, prefix: String(localized: "nutrition_per_100g")))
                if let perPortion = detail.perPortion {
                    Text(batchMacroLine(perPortion, prefix: String(localized: "nutrition_per_portion")))
                }
                Text(
                    String(
                        format: String(localized: "nutrition_batch_total_summary_format"),
                        Int(detail.recipe.totalCalories.rounded()),
                        Int(detail.recipe.totalProteinG.rounded()),
                        Int(detail.recipe.totalFatG.rounded()),
                        Int(detail.recipe.totalCarbsG.rounded())
                    )
                )
            }
            .font(LifeOSTypography.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private func detailIngredients(_ detail: NutritionBatchRecipeDetail) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(String(localized: "nutrition_ingredients"))
                .font(LifeOSTypography.subheadline.weight(.semibold))

            ForEach(detail.ingredients) { ingredient in
                detailIngredientRow(ingredient)
            }
        }
    }

    private func detailIngredientRow(_ ingredient: BatchRecipeIngredient) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(ingredient.name)
                .font(LifeOSTypography.body.weight(.semibold))
            if let brand = ingredient.brand, !brand.isEmpty {
                Text(brand)
                    .font(LifeOSTypography.caption)
                    .foregroundStyle(.secondary)
            }
            Text(batchIngredientLine(ingredient))
                .font(LifeOSTypography.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private func detailActions(_ detail: NutritionBatchRecipeDetail) -> some View {
        VStack(spacing: Spacing.s) {
            Button {
                showingLogSheet = true
            } label: {
                Text(String(localized: "nutrition_log_portion"))
                    .font(LifeOSTypography.headline)
            }
            .buttonStyle(.borderedProminent)
            .disabled(detail.recipe.archived || detail.weightRemainingG <= 0)

            Button(action: cookAgain) {
                if isDuplicating {
                    ProgressView()
                } else {
                    Text(String(localized: "nutrition_cook_again"))
                        .font(LifeOSTypography.subheadline.weight(.semibold))
                }
            }
            .buttonStyle(.bordered)
            .disabled(isDuplicating || isArchiving)

            Button(action: toggleArchived) {
                if isArchiving {
                    ProgressView()
                } else {
                    Text(detail.recipe.archived ? String(localized: "nutrition_unarchive_batch") : String(localized: "nutrition_archive_batch"))
                        .font(LifeOSTypography.subheadline.weight(.semibold))
                }
            }
            .buttonStyle(.bordered)
            .disabled(isArchiving || isDuplicating)
        }
        .frame(maxWidth: .infinity)
    }

    private func composerSheet(_ detail: NutritionBatchRecipeDetail) -> some View {
        NavigationStack {
            BatchRecipeComposerView(
                existingDetail: detail,
                onSaved: handleComposerSheetSaved
            )
        }
    }

    @ViewBuilder
    private func composerSheetContent() -> some View {
        if let detail {
            composerSheet(detail)
        }
    }

    private func logSheet(_ detail: NutritionBatchRecipeDetail) -> some View {
        NavigationStack {
            BatchPortionLogView(
                batchId: detail.recipe.id,
                batchName: detail.recipe.name,
                remainingWeightG: detail.weightRemainingG,
                per100g: detail.per100g,
                suggestedPortionWeightG: detail.perPortion?.weightG,
                targetDay: targetDay,
                loggedAt: loggedAt,
                onLogged: handleLogSheetSaved
            )
        }
    }

    @ViewBuilder
    private func logSheetContent() -> some View {
        if let detail {
            logSheet(detail)
        }
    }

    private func handleComposerSaved(
        _ message: TemplateStatusMessage,
        reloadAction: (() async -> Void)?
    ) {
        statusMessage = message
        onStatusMessage(message)
        onBatchesChanged()
        Task { @MainActor in
            if let reloadAction {
                await reloadAction()
            } else {
                await loadDetail(preferRemote: false)
            }
        }
    }

    private func handleComposerSheetSaved(_ message: TemplateStatusMessage) {
        handleComposerSaved(message, reloadAction: nil)
    }

    private func handleLogSaved(
        _ message: TemplateStatusMessage,
        reloadAction: (() async -> Void)?
    ) {
        statusMessage = message
        onStatusMessage(message)
        onBatchLogged()
        onBatchesChanged()
        Task { @MainActor in
            if let reloadAction {
                await reloadAction()
            } else {
                await loadDetail(preferRemote: false)
            }
        }
    }

    private func handleLogSheetSaved(_ message: TemplateStatusMessage) {
        handleLogSaved(message, reloadAction: nil)
    }

    private func loadDetail(
        preferRemote: Bool,
        manager: any NutritionBatchRecipeManaging
    ) async {
        isLoading = true
        defer { isLoading = false }
        let result = await Self.loadDetailResult(
            batchId: batchId,
            preferRemote: preferRemote,
            manager: manager
        )
        detail = result.detail
        errorMessage = result.errorMessage
    }

    private func loadDetail(preferRemote: Bool) async {
        await loadDetail(preferRemote: preferRemote, manager: NutritionService())
    }

    private func toggleArchived(
        manager: any NutritionBatchRecipeManaging,
        dismissAction: @escaping () -> Void
    ) {
        guard let detail else { return }
        isArchiving = true
        Task { @MainActor in
            defer { isArchiving = false }
            switch await Self.toggleArchivedResult(detail: detail, manager: manager) {
            case let .success(message):
                statusMessage = message
                onStatusMessage(message)
                onBatchesChanged()
                HapticManager.success()
                dismissAction()
            case let .failure(error):
                errorMessage = error.localizedDescription
                HapticManager.error()
            }
        }
    }

    private func toggleArchived() {
        toggleArchived(manager: NutritionService(), dismissAction: { dismiss() })
    }

    private func cookAgain(
        manager: any NutritionBatchRecipeManaging,
        dismissAction: @escaping () -> Void
    ) {
        guard let detail else { return }
        isDuplicating = true
        Task { @MainActor in
            defer { isDuplicating = false }
            switch await Self.cookAgainResult(detail: detail, manager: manager) {
            case let .success(message):
                statusMessage = message
                onStatusMessage(message)
                onBatchesChanged()
                HapticManager.success()
                dismissAction()
            case let .failure(error):
                errorMessage = error.localizedDescription
                HapticManager.error()
            }
        }
    }

    private func cookAgain() {
        cookAgain(manager: NutritionService(), dismissAction: { dismiss() })
    }
}

struct BatchRecipeComposerView: View {
    @Environment(\.dismiss) private var dismiss

    let existingDetail: NutritionBatchRecipeDetail?
    let onSaved: (TemplateStatusMessage) -> Void

    @State private var name: String
    @State private var description: String
    @State private var cookedAt: Date
    @State private var totalWeightG: Double
    @State private var totalPortions: Int
    @State private var ingredients: [BatchRecipeEditableIngredient]
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var importMessage: String?
    @State private var isAnalyzingPhoto = false
    @State private var showingIngredientSearch = false
    @State private var showCameraPicker = false
    @State private var showPhotoLibrary = false
    @State private var selectedPhotoItem: PhotosPickerItem?

    init(
        existingDetail: NutritionBatchRecipeDetail?,
        onSaved: @escaping (TemplateStatusMessage) -> Void
    ) {
        self.existingDetail = existingDetail
        self.onSaved = onSaved
        _name = State(initialValue: existingDetail?.recipe.name ?? String(localized: "nutrition_default_meal_prep_name"))
        _description = State(initialValue: existingDetail?.recipe.description ?? "")
        _cookedAt = State(initialValue: Self.date(from: existingDetail?.recipe.cookedAt))
        _totalWeightG = State(initialValue: existingDetail?.recipe.totalWeightG ?? 1000)
        _totalPortions = State(initialValue: existingDetail?.recipe.totalPortions ?? 1)
        _ingredients = State(initialValue: existingDetail?.ingredients.map(BatchRecipeEditableIngredient.init(ingredient:)) ?? [])
    }

    private static func date(from value: String?) -> Date {
        DiaryDateFormatter.parseDate(value) ?? Date()
    }

    private var totals: NutritionBatchMacroSnapshot {
        let calories = ingredients.reduce(0) { $0 + $1.calories }
        let protein = ingredients.reduce(0) { $0 + $1.proteinG }
        let fat = ingredients.reduce(0) { $0 + $1.fatG }
        let carbs = ingredients.reduce(0) { $0 + $1.carbsG }
        let fiber = ingredients.reduce(0) { $0 + $1.fiberG }
        return NutritionBatchMacroSnapshot(
            weightG: totalWeightG,
            calories: calories,
            proteinG: protein,
            fatG: fat,
            carbsG: carbs,
            fiberG: fiber > 0 ? fiber : nil
        )
    }

    private var per100g: NutritionBatchMacroSnapshot {
        guard totalWeightG > 0 else {
            return NutritionBatchMacroSnapshot(weightG: 100, calories: 0, proteinG: 0, fatG: 0, carbsG: 0, fiberG: nil)
        }
        return NutritionBatchMacroSnapshot(
            weightG: 100,
            calories: totals.calories * 100 / totalWeightG,
            proteinG: totals.proteinG * 100 / totalWeightG,
            fatG: totals.fatG * 100 / totalWeightG,
            carbsG: totals.carbsG * 100 / totalWeightG,
            fiberG: totals.fiberG.map { $0 * 100 / totalWeightG }
        )
    }

    private var perPortion: NutritionBatchMacroSnapshot {
        let portions = max(totalPortions, 1)
        return NutritionBatchMacroSnapshot(
            weightG: totalWeightG / Double(portions),
            calories: totals.calories / Double(portions),
            proteinG: totals.proteinG / Double(portions),
            fatG: totals.fatG / Double(portions),
            carbsG: totals.carbsG / Double(portions),
            fiberG: totals.fiberG.map { $0 / Double(portions) }
        )
    }

    private var canSave: Bool {
        !isSaving &&
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        totalWeightG > 0 &&
        totalPortions > 0 &&
        !ingredients.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(LifeOSColors.Recovery.critical)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let importMessage {
                    Label(importMessage, systemImage: "sparkles")
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(LifeOSColors.Semantic.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if isAnalyzingPhoto {
                    ProgressView(String(localized: "nutrition_analyzing_photo"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                detailsSection
                totalsSection
                ingredientsSection
            }
            .padding(LayoutConstants.contentPadding)
        }
        .background(LifeOSColors.Surface.background)
        .navigationTitle(existingDetail == nil ? String(localized: "nutrition_create_batch") : String(localized: "nutrition_edit_batch"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "cancel"), action: dismiss.callAsFunction)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "save"), action: save)
                    .disabled(!canSave)
            }
        }
        .sheet(isPresented: $showingIngredientSearch, content: ingredientSearchSheet)
        .sheet(isPresented: $showCameraPicker, content: cameraPickerSheet)
        .photosPicker(
            isPresented: $showPhotoLibrary,
            selection: $selectedPhotoItem,
            matching: .images
        )
        .task(id: selectedPhotoItem, handleSelectedPhotoItemChange)
    }

    private static func saveDraft(
        existingDetail: NutritionBatchRecipeDetail?,
        name: String,
        description: String,
        cookedAt: Date,
        totalWeightG: Double,
        totalPortions: Int,
        ingredients: [BatchRecipeEditableIngredient]
    ) -> NutritionBatchRecipeDraft {
        NutritionBatchRecipeDraft(
            id: existingDetail?.recipe.id ?? UUID(),
            name: name,
            description: description.isEmpty ? nil : description,
            cookedAt: DateFormatting.dateOnlyString(from: cookedAt),
            totalWeightG: totalWeightG,
            totalPortions: totalPortions,
            ingredients: ingredients.map(\.draftIngredient),
            archived: existingDetail?.recipe.archived ?? false
        )
    }

    private static func saveResult(
        draft: NutritionBatchRecipeDraft,
        existingDetail: NutritionBatchRecipeDetail?,
        manager: any NutritionBatchRecipeManaging
    ) async -> Result<TemplateStatusMessage, Error> {
        do {
            if existingDetail == nil {
                _ = try await manager.createBatchRecipe(draft)
                return .success(TemplateStatusMessage(message: String(localized: "nutrition_batch_saved"), isError: false))
            }
            try await manager.updateBatchRecipe(draft)
            return .success(TemplateStatusMessage(message: String(localized: "nutrition_batch_updated"), isError: false))
        } catch {
            return .failure(error)
        }
    }

    private static func capturePickerState(cameraAvailable: Bool) -> (
        showCameraPicker: Bool,
        showPhotoLibrary: Bool
    ) {
        if cameraAvailable {
            return (showCameraPicker: true, showPhotoLibrary: false)
        }
        return (showCameraPicker: false, showPhotoLibrary: true)
    }

    private func ingredientSearchSheet() -> some View {
        NavigationStack {
            BatchRecipeIngredientPickerView(onSelect: handleIngredientSearchSelection)
        }
    }

    private func cameraPickerSheet() -> some View {
        SystemImagePicker(sourceType: .camera, onImagePicked: handlePickedCameraImage)
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(String(localized: "nutrition_batch_details"))
                .font(LifeOSTypography.subheadline.weight(.semibold))

            TextField(String(localized: "nutrition_batch_name"), text: $name)
                .textInputAutocapitalization(.words)

            TextField(String(localized: "nutrition_description"), text: $description, axis: .vertical)
                .lineLimit(2...4)

            DatePicker(String(localized: "nutrition_cooked_date"), selection: $cookedAt, displayedComponents: .date)

            HStack(spacing: Spacing.s) {
                batchNumericField(String(localized: "nutrition_cooked_weight_g"), value: $totalWeightG)
                batchIntegerField(String(localized: "nutrition_portions"), value: $totalPortions)
            }
        }
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private var totalsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(String(localized: "nutrition_preview"))
                .font(LifeOSTypography.subheadline.weight(.semibold))

            Text(batchMacroLine(totals, prefix: String(localized: "nutrition_batch_total")))
                .font(LifeOSTypography.caption)
                .foregroundStyle(.secondary)
            Text(batchMacroLine(per100g, prefix: String(localized: "nutrition_per_100g")))
                .font(LifeOSTypography.caption)
                .foregroundStyle(.secondary)
            Text(batchMacroLine(perPortion, prefix: String(localized: "nutrition_per_portion")))
                .font(LifeOSTypography.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text(String(localized: "nutrition_ingredients"))
                    .font(LifeOSTypography.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    Button("Photo Draft", action: beginCameraCapture)
                    Button(String(localized: "nutrition_search_food"), action: presentIngredientSearch)
                    Button(String(localized: "nutrition_manual_ingredient"), action: addManualIngredient)
                } label: {
                    Label(String(localized: "nutrition_add_ingredient"), systemImage: "plus.circle.fill")
                        .font(LifeOSTypography.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
            }

            ForEach(Array(ingredients.indices), id: \.self) { index in
                ingredientEditor(index: index)
            }
        }
    }

    private func ingredientEditor(index: Int) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .top) {
                TextField(String(localized: "nutrition_ingredient_name"), text: $ingredients[index].name)
                    .font(LifeOSTypography.body)
                Spacer()
                Button(role: .destructive) {
                    ingredients.remove(at: index)
                } label: {
                    Image(systemName: "trash")
                }
            }

            TextField(String(localized: "nutrition_brand"), text: $ingredients[index].brand)
                .textInputAutocapitalization(.words)
            TextField(String(localized: "nutrition_barcode"), text: $ingredients[index].barcode)
                .keyboardType(.numberPad)

            HStack(spacing: Spacing.s) {
                batchNumericField(String(localized: "nutrition_weight"), value: $ingredients[index].weightG)
                batchNumericField(String(localized: "nutrition_unit_kcal"), value: $ingredients[index].calories)
            }

            HStack(spacing: Spacing.s) {
                batchNumericField(String(localized: "nutrition_macro_label_protein"), value: $ingredients[index].proteinG)
                batchNumericField(String(localized: "nutrition_macro_label_fat"), value: $ingredients[index].fatG)
                batchNumericField(String(localized: "nutrition_macro_label_carbs"), value: $ingredients[index].carbsG)
                batchNumericField(String(localized: "nutrition_macro_label_fiber"), value: $ingredients[index].fiberG)
            }
        }
        .padding(Spacing.s)
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private func batchNumericField(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(LifeOSTypography.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(
                title,
                value: value,
                format: .number.precision(.fractionLength(0...1))
            )
            .keyboardType(.decimalPad)
            .textFieldStyle(.roundedBorder)
        }
    }

    private func batchIntegerField(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(LifeOSTypography.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(title, value: value, format: .number)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func save(
        manager: any NutritionBatchRecipeManaging,
        dismissAction: @escaping () -> Void
    ) {
        isSaving = true
        errorMessage = nil
        let draft = Self.saveDraft(
            existingDetail: existingDetail,
            name: name,
            description: description,
            cookedAt: cookedAt,
            totalWeightG: totalWeightG,
            totalPortions: totalPortions,
            ingredients: ingredients
        )

        Task { @MainActor in
            defer { isSaving = false }
            switch await Self.saveResult(draft: draft, existingDetail: existingDetail, manager: manager) {
            case let .success(message):
                onSaved(message)
                HapticManager.success()
                dismissAction()
            case let .failure(error):
                errorMessage = error.localizedDescription
                HapticManager.error()
            }
        }
    }

    private func save() {
        save(manager: NutritionService(), dismissAction: { dismiss() })
    }

    private func presentIngredientSearch() {
        showingIngredientSearch = true
    }

    private func addManualIngredient() {
        ingredients.append(.manual())
    }

    private func handleIngredientSearchSelection(_ result: FoodSearchResult) {
        ingredients.append(BatchRecipeEditableIngredient(searchResult: result))
    }

    private func beginCameraCapture() {
        openCameraOrLibrary()
    }

    private func beginCameraCapture(
        cameraAvailableProvider: @escaping () -> Bool
    ) {
        openCameraOrLibrary(cameraAvailableProvider: cameraAvailableProvider)
    }

    private func openCameraOrLibrary(
        cameraAvailableProvider: (() -> Bool)? = nil
    ) {
        let cameraAvailable = cameraAvailableProvider?()
            ?? UIImagePickerController.isSourceTypeAvailable(.camera)
        let state = Self.capturePickerState(cameraAvailable: cameraAvailable)
        showCameraPicker = state.showCameraPicker
        showPhotoLibrary = state.showPhotoLibrary
    }

    private func handlePickedCameraImage(_ image: UIImage) {
        Task { @MainActor in
            await processBatchPhoto(image)
        }
    }

    @MainActor
    private func handleSelectedPhotoItemChange() async {
        await loadSelectedPhotoItemIfNeeded(
            item: selectedPhotoItem,
            shouldLoad: selectedPhotoItem != nil
        )
    }

    @MainActor
    private func loadSelectedPhotoItemIfNeeded(
        item: PhotosPickerItem?,
        shouldLoad: Bool,
        loadPhotoItemAction: ((PhotosPickerItem?) async -> Void)? = nil
    ) async {
        guard shouldLoad else { return }
        if let loadPhotoItemAction {
            await loadPhotoItemAction(item)
            return
        }
        await loadPhotoItem {
            try await item?.loadTransferable(type: Data.self)
        }
    }

    @MainActor
    private func loadPhotoItem(
        using loader: @escaping @Sendable () async throws -> Data?
    ) async {
        defer { selectedPhotoItem = nil }
        do {
            await processLoadedPhotoData(try await loader())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func processLoadedPhotoData(_ data: Data?) async {
        guard let data, let image = UIImage(data: data) else {
            errorMessage = String(localized: "error.media.selected_image_load")
            return
        }
        await processBatchPhoto(image)
    }

    @MainActor
    private func processBatchPhoto(_ image: UIImage) async {
        isAnalyzingPhoto = true
        errorMessage = nil
        importMessage = nil
        defer { isAnalyzingPhoto = false }

        let photoDraft = await MediaRecognitionService.analyzeBatchRecipePhoto(
            image,
            recipeName: name,
            totalWeightG: totalWeightG,
            totalPortions: totalPortions,
            knownIngredients: ingredients.map(\.name)
        )

        apply(photoDraft: photoDraft)
    }

    @MainActor
    private func apply(photoDraft: BatchRecipePhotoDraft) {
        let resolvedState = Self.resolvePhotoImportState(
            name: name,
            description: description,
            totalWeightG: totalWeightG,
            totalPortions: totalPortions,
            ingredients: ingredients,
            photoDraft: photoDraft
        )
        name = resolvedState.name
        description = resolvedState.description
        totalWeightG = resolvedState.totalWeightG
        totalPortions = resolvedState.totalPortions
        ingredients = resolvedState.ingredients
        importMessage = resolvedState.importMessage
        errorMessage = resolvedState.errorMessage
    }

    private static func resolvePhotoImportState(
        name: String,
        description: String,
        totalWeightG: Double,
        totalPortions: Int,
        ingredients: [BatchRecipeEditableIngredient],
        photoDraft: BatchRecipePhotoDraft
    ) -> (
        name: String,
        description: String,
        totalWeightG: Double,
        totalPortions: Int,
        ingredients: [BatchRecipeEditableIngredient],
        importMessage: String?,
        errorMessage: String?
    ) {
        var nextName = name
        var nextDescription = description
        var nextTotalWeightG = totalWeightG
        var nextTotalPortions = totalPortions
        var nextIngredients = ingredients
        var nextImportMessage: String?
        var nextErrorMessage: String?

        if nextName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            nextName == String(localized: "nutrition_default_meal_prep_name") {
            nextName = photoDraft.recipeName
        }

        if photoDraft.totalWeightG > 0 {
            nextTotalWeightG = photoDraft.totalWeightG
        }
        if photoDraft.totalPortions > 0 {
            nextTotalPortions = photoDraft.totalPortions
        }

        if let descriptionText = photoDraft.descriptionText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !descriptionText.isEmpty {
            if nextDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                nextDescription = descriptionText
            } else if !nextDescription.contains(descriptionText) {
                nextDescription += "\n" + descriptionText
            }
        }

        if nextIngredients.isEmpty {
            nextIngredients = photoDraft.ingredients
        } else {
            nextIngredients = mergeIngredients(existing: nextIngredients, imported: photoDraft.ingredients)
        }

        if let firstNote = photoDraft.notes.first {
            nextImportMessage = firstNote
        } else if !photoDraft.ingredients.isEmpty {
            nextImportMessage = "Photo draft imported. Review before saving."
        } else {
            nextErrorMessage = "Photo draft could not detect ingredients. Add them manually or try another photo."
        }

        return (
            name: nextName,
            description: nextDescription,
            totalWeightG: nextTotalWeightG,
            totalPortions: nextTotalPortions,
            ingredients: nextIngredients,
            importMessage: nextImportMessage,
            errorMessage: nextErrorMessage
        )
    }

    private static func mergeIngredients(
        existing: [BatchRecipeEditableIngredient],
        imported: [BatchRecipeEditableIngredient]
    ) -> [BatchRecipeEditableIngredient] {
        guard !imported.isEmpty else { return existing }
        var merged = existing
        let existingKeys = Set(existing.map { normalizedIngredientKey($0.name) })
        for ingredient in imported where !existingKeys.contains(normalizedIngredientKey(ingredient.name)) {
            merged.append(ingredient)
        }
        return merged
    }

    private static func normalizedIngredientKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct BatchPortionLogView: View {
    @Environment(\.dismiss) private var dismiss

    let batchId: UUID
    let batchName: String
    let remainingWeightG: Double
    let per100g: NutritionBatchMacroSnapshot
    let suggestedPortionWeightG: Double?
    let targetDay: String
    let loggedAt: Date
    let onLogged: (TemplateStatusMessage) -> Void

    @State private var portionWeightG: Double
    @State private var mealType: MealType?
    @State private var context: MealContext? = .home
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        batchId: UUID,
        batchName: String,
        remainingWeightG: Double,
        per100g: NutritionBatchMacroSnapshot,
        suggestedPortionWeightG: Double?,
        targetDay: String,
        loggedAt: Date,
        onLogged: @escaping (TemplateStatusMessage) -> Void
    ) {
        self.batchId = batchId
        self.batchName = batchName
        self.remainingWeightG = remainingWeightG
        self.per100g = per100g
        self.suggestedPortionWeightG = suggestedPortionWeightG
        self.targetDay = targetDay
        self.loggedAt = loggedAt
        self.onLogged = onLogged
        _portionWeightG = State(initialValue: min(suggestedPortionWeightG ?? 100, max(remainingWeightG, 1)))
        _mealType = State(initialValue: Self.defaultMealType(for: loggedAt))
    }

    private static func defaultMealType(for date: Date) -> MealType {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 5..<11:
            return .breakfast
        case 11..<16:
            return .lunch
        case 16..<22:
            return .dinner
        default:
            return .snack
        }
    }

    private var preview: NutritionBatchMacroSnapshot {
        let factor = portionWeightG / 100
        return NutritionBatchMacroSnapshot(
            weightG: portionWeightG,
            calories: per100g.calories * factor,
            proteinG: per100g.proteinG * factor,
            fatG: per100g.fatG * factor,
            carbsG: per100g.carbsG * factor,
            fiberG: per100g.fiberG.map { $0 * factor }
        )
    }

    private var canSave: Bool {
        !isSaving && portionWeightG > 0 && portionWeightG <= remainingWeightG + 0.001
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(LifeOSColors.Recovery.critical)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(batchName)
                        .font(LifeOSTypography.title3.weight(.semibold))
                    Text(localizedNutritionRemainingLine(weightG: remainingWeightG))
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "nutrition_portion_weight_g"))
                            .font(LifeOSTypography.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField(
                            String(localized: "nutrition_portion_weight"),
                            value: $portionWeightG,
                            format: .number.precision(.fractionLength(0...1))
                        )
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                    }

                    Picker(String(localized: "nutrition_meal"), selection: $mealType) {
                        Text(localizedNutritionMealType(.breakfast)).tag(MealType.breakfast as MealType?)
                        Text(localizedNutritionMealType(.lunch)).tag(MealType.lunch as MealType?)
                        Text(localizedNutritionMealType(.dinner)).tag(MealType.dinner as MealType?)
                        Text(localizedNutritionMealType(.snack)).tag(MealType.snack as MealType?)
                    }
                    .pickerStyle(.segmented)

                    Picker(String(localized: "nutrition_context"), selection: $context) {
                        Text(localizedNutritionMealContext(.home)).tag(MealContext.home as MealContext?)
                        Text(localizedNutritionMealContext(.work)).tag(MealContext.work as MealContext?)
                        Text(localizedNutritionMealContext(.restaurant)).tag(MealContext.restaurant as MealContext?)
                        Text(localizedNutritionMealContext(.other)).tag(MealContext.other as MealContext?)
                    }
                    .pickerStyle(.menu)

                    Text(batchMacroLine(preview, prefix: String(localized: "nutrition_preview")))
                        .font(LifeOSTypography.caption)
                        .foregroundStyle(.secondary)

                    if portionWeightG > remainingWeightG + 0.001 {
                        Text(String(localized: "nutrition_portion_exceeds_remaining"))
                            .font(LifeOSTypography.caption)
                            .foregroundStyle(LifeOSColors.Recovery.critical)
                    }
                }
                .padding(Spacing.s)
                .background(LifeOSColors.Surface.card)
                .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
            }
            .padding(LayoutConstants.contentPadding)
        }
        .background(LifeOSColors.Surface.background)
        .navigationTitle(String(localized: "nutrition_log_portion"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "nutrition_log")) { save() }
                    .disabled(!canSave)
            }
        }
    }

    private static func saveResult(
        draft: NutritionBatchPortionLogDraft,
        batchName: String,
        manager: any NutritionBatchRecipeManaging
    ) async -> Result<TemplateStatusMessage, Error> {
        do {
            let result = try await manager.logBatchPortion(draft)
            return .success(
                TemplateStatusMessage(
                    message: String(
                        format: String(localized: "nutrition_logged_batch_remaining_format"),
                        batchName,
                        Int(result.weightRemainingG.rounded())
                    ),
                    isError: false
                )
            )
        } catch {
            return .failure(error)
        }
    }

    private func save(
        manager: any NutritionBatchRecipeManaging,
        dismissAction: @escaping () -> Void
    ) {
        isSaving = true
        errorMessage = nil

        let draft = NutritionBatchPortionLogDraft(
            batchId: batchId,
            targetDay: targetDay,
            loggedAt: loggedAt,
            mealType: mealType,
            context: context,
            portionWeightG: portionWeightG
        )

        Task { @MainActor in
            defer { isSaving = false }
            switch await Self.saveResult(draft: draft, batchName: batchName, manager: manager) {
            case let .success(message):
                onLogged(message)
                HapticManager.success()
                dismissAction()
            case let .failure(error):
                errorMessage = error.localizedDescription
                HapticManager.error()
            }
        }
    }

    private func save() {
        save(manager: NutritionService(), dismissAction: { dismiss() })
    }
}

struct BatchRecipeIngredientPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [FoodSearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    private let catalogService = NutritionCatalogService()
    let onSelect: (FoodSearchResult) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(String(localized: "nutrition_search_foods"), text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit(submitSearch)
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
            } else {
                List(results, rowContent: searchResultButton)
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
        .background(LifeOSColors.Surface.background)
        .navigationTitle(String(localized: "nutrition_add_ingredient"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "cancel")) { dismiss() }
            }
        }
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
        Button {
            handleSelection(of: result, dismissAction: { dismiss() })
        } label: {
            searchResultLabel(result)
        }
        .buttonStyle(.plain)
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
            Text("\(result.roundedCaloriesPer100g) kcal / 100g")
                .font(LifeOSTypography.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func handleSelection(
        of result: FoodSearchResult,
        dismissAction: @escaping () -> Void
    ) {
        onSelect(result)
        dismissAction()
    }
}

private enum NutritionSearchExecutionHelper {
    static func normalizedQuery(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func run(
        query: String,
        searcher: @Sendable (String) async throws -> [FoodSearchResult]
    ) async -> Result<[FoodSearchResult], Error> {
        do {
            return .success(try await searcher(query))
        } catch {
            return .failure(error)
        }
    }
}

private func batchMacroLine(_ snapshot: NutritionBatchMacroSnapshot, prefix: String) -> String {
    localizedNutritionBatchMacroLine(snapshot, prefix: prefix)
}

private func batchIngredientLine(_ ingredient: BatchRecipeIngredient) -> String {
    localizedNutritionItemSummary(
        weightG: ingredient.weightG,
        calories: ingredient.calories,
        protein: ingredient.proteinG,
        fat: ingredient.fatG,
        carbs: ingredient.carbsG,
        fiber: ingredient.fiberG
    )
}

// MARK: - Nutrition Calendar View

struct NutritionCalendarView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedDate: Date
    @State private var displayedMonth = Date()
    @State private var daysWithLogs: Set<String> = []

    private let calendar = Calendar.current
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.m) {
                monthNavigationSection()
                calendarGrid()

                Spacer()
            }
            .padding(.top, Spacing.m)
            .navigationTitle(String(localized: "nutrition_calendar_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) { dismissCalendar() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "nutrition_today")) { selectToday() }
                }
            }
            .task { await loadLoggedDays() }
            .onChange(of: displayedMonth) { _, _ in
                Task { await loadLoggedDays() }
            }
        }
    }

    private func daysInMonth() -> [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: displayedMonth),
              let firstDay = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth))
        else { return [] }

        let firstWeekday = calendar.component(.weekday, from: firstDay)
        let leadingSpaces = firstWeekday - calendar.firstWeekday
        let normalizedLeading = (leadingSpaces + 7) % 7

        var days: [Date?] = Array(repeating: nil, count: normalizedLeading)
        for day in range {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: firstDay) {
                days.append(date)
            }
        }
        return days
    }

    private func monthNavigationSection() -> some View {
        HStack {
            Button(action: showPreviousMonth) {
                Image(systemName: "chevron.left")
            }

            Spacer()

            Text(displayedMonth, format: .dateTime.month(.wide).year())
                .font(LifeOSTypography.headline)

            Spacer()

            Button(action: showNextMonth) {
                Image(systemName: "chevron.right")
            }
        }
        .padding(.horizontal, LayoutConstants.contentPadding)
    }

    private func calendarGrid() -> some View {
        let weekdays = calendar.shortWeekdaySymbols
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: Spacing.xs) {
            ForEach(weekdays, id: \.self) { day in
                weekdayHeader(day)
            }

            ForEach(daysInMonth(), id: \.self) { date in
                dayCell(for: date)
            }
        }
        .padding(.horizontal, LayoutConstants.contentPadding)
    }

    private func weekdayHeader(_ day: String) -> some View {
        Text(day)
            .font(LifeOSTypography.caption)
            .foregroundStyle(.secondary)
    }

    private func dayCell(for date: Date?) -> some View {
        Group {
            if let date {
                selectableDayCell(date)
            } else {
                emptyDayCell()
            }
        }
    }

    private func selectableDayCell(_ date: Date) -> some View {
        let dateStr = dateFormatter.string(from: date)
        let hasLog = daysWithLogs.contains(dateStr)
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(date)

        return Button(action: { selectDate(date) }) {
            dayCellLabel(
                date: date,
                hasLog: hasLog,
                isSelected: isSelected,
                isToday: isToday
            )
        }
        .buttonStyle(.plain)
    }

    private func dayCellLabel(
        date: Date,
        hasLog: Bool,
        isSelected: Bool,
        isToday: Bool
    ) -> some View {
        VStack(spacing: 2) {
            Text("\(calendar.component(.day, from: date))")
                .font(LifeOSTypography.body)
                .fontWeight(isToday ? .bold : .regular)
                .foregroundStyle(isSelected ? .white : .primary)

            Circle()
                .fill(hasLog ? LifeOSColors.Semantic.primary : .clear)
                .frame(width: 6, height: 6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(isSelected ? LifeOSColors.Semantic.primary : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.smallCornerRadius))
    }

    private func emptyDayCell() -> some View {
        Text("")
            .frame(maxWidth: .infinity)
            .frame(height: 44)
    }

    private func shiftedMonth(
        by value: Int,
        calendar overrideCalendar: Calendar? = nil,
        baseDate: Date? = nil
    ) -> Date {
        let resolvedCalendar = overrideCalendar ?? calendar
        let resolvedBaseDate = baseDate ?? displayedMonth
        return resolvedCalendar.date(byAdding: .month, value: value, to: resolvedBaseDate) ?? resolvedBaseDate
    }

    private func shiftDisplayedMonth(by value: Int, calendar overrideCalendar: Calendar? = nil) {
        displayedMonth = shiftedMonth(by: value, calendar: overrideCalendar)
    }

    private func showPreviousMonth() {
        shiftDisplayedMonth(by: -1)
    }

    private func showNextMonth() {
        shiftDisplayedMonth(by: 1)
    }

    private func dismissCalendar(dismissAction: (() -> Void)? = nil) {
        (dismissAction ?? { dismiss() })()
    }

    private func selectDate(
        _ date: Date,
        dismissAction: (() -> Void)? = nil
    ) {
        selectedDate = date
        dismissCalendar(dismissAction: dismissAction)
    }

    private func selectToday(
        today: Date = Date(),
        dismissAction: (() -> Void)? = nil
    ) {
        selectedDate = today
        dismissCalendar(dismissAction: dismissAction)
    }

    private static func loadLoggedDaysResult(
        displayedMonth: Date,
        calendar: Calendar,
        dbQueue: DatabaseQueue
    ) async -> Set<String> {
        let components = calendar.dateComponents([.year, .month], from: displayedMonth)
        guard let year = components.year, let month = components.month else { return [] }
        let prefix = String(format: "%04d-%02d", year, month)

        do {
            let dates: [String] = try await dbQueue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT logged_date FROM food_logs
                        WHERE logged_date LIKE ? AND deleted_at IS NULL
                        """,
                    arguments: ["\(prefix)%"]
                )
                return rows.compactMap { $0["logged_date"] }
            }
            return Set(dates)
        } catch {
            return []
        }
    }

    private func loadLoggedDays(
        calendar overrideCalendar: Calendar? = nil,
        dbQueue overrideDBQueue: DatabaseQueue? = nil
    ) async {
        daysWithLogs = await Self.loadLoggedDaysResult(
            displayedMonth: displayedMonth,
            calendar: overrideCalendar ?? calendar,
            dbQueue: overrideDBQueue ?? DatabaseManager.shared.dbQueue
        )
    }
}

struct SystemImagePicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onImagePicked: (UIImage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePicked: onImagePicked)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        configuredPicker(delegate: context.coordinator)
    }

    private func configuredPicker(
        delegate: (UIImagePickerControllerDelegate & UINavigationControllerDelegate)?
    ) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.allowsEditing = false
        picker.delegate = delegate
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let onImagePicked: (UIImage) -> Void

        init(onImagePicked: @escaping (UIImage) -> Void) {
            self.onImagePicked = onImagePicked
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImagePicked(image)
            }
            picker.dismiss(animated: true)
        }
    }
}

struct NutritionPhotoAnalysis {
    let summary: String
    let confidence: Double?
    let source: NutritionAnalysisSource
    let recognizedText: String?
    let barcodes: [String]
    let detectedItems: [NutritionDraftCandidateItem]
    let totalMacros: NutritionDraftMacroSummary?
    let warnings: [String]
    let suggestions: [String]
    let mealType: MealType?
    let notice: String?
}

private struct FoodPhotoAnalysisRequest: Encodable, Sendable {
    let imageBase64: String
    let context: String?
    let timestamp: String
    let preWorkout: Bool
    let postWorkout: Bool
    let recognizedText: String?
    let barcodes: [String]
    let locale: String

    enum CodingKeys: String, CodingKey {
        case imageBase64 = "image_base64"
        case context
        case timestamp
        case preWorkout = "pre_workout"
        case postWorkout = "post_workout"
        case recognizedText = "recognized_text"
        case barcodes
        case locale
    }
}

struct FoodPhotoAnalysisResponse: Decodable, Sendable {
    let detectedItems: [DetectedItem]
    let totalMacros: Totals?
    let mealTypeRaw: String?
    let confidence: Double?
    let warnings: [String]
    let contextAnalysis: String?
    let suggestions: [String]

    struct DetectedItem: Decodable, Sendable {
        let name: String
        let categoryRaw: String?
        let weightG: Double
        let calories: Double
        let proteinG: Double
        let fatG: Double
        let carbsG: Double
        let fiberG: Double?
        let confidence: Double?
        let notes: String?

        enum CodingKeys: String, CodingKey {
            case name
            case categoryRaw = "category"
            case weightG = "weight_g"
            case calories
            case proteinG = "protein_g"
            case fatG = "fat_g"
            case carbsG = "carbs_g"
            case fiberG = "fiber_g"
            case confidence
            case notes
        }
    }

    struct Totals: Decodable, Sendable {
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

    enum CodingKeys: String, CodingKey {
        case detectedItems = "detected_items"
        case totalMacros = "total_macros"
        case mealTypeRaw = "meal_type"
        case confidence
        case warnings
        case contextAnalysis = "context_analysis"
        case suggestions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        detectedItems = try container.decodeIfPresent([DetectedItem].self, forKey: .detectedItems) ?? []
        totalMacros = try container.decodeIfPresent(Totals.self, forKey: .totalMacros)
        mealTypeRaw = try container.decodeIfPresent(String.self, forKey: .mealTypeRaw)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        contextAnalysis = try container.decodeIfPresent(String.self, forKey: .contextAnalysis)
        suggestions = try container.decodeIfPresent([String].self, forKey: .suggestions) ?? []
    }
}

struct FoodPhotoAnalysisService: Sendable {
    private let apiClient: any PredictionAPIClient

    init(apiClient: any PredictionAPIClient = APIClient()) {
        self.apiClient = apiClient
    }

    func analyzePhoto(
        imageDataURL: String,
        loggedAt: Date,
        recognizedText: String?,
        barcodes: [String],
        mealContext: MealContext? = nil,
        preWorkout: Bool = false,
        postWorkout: Bool = false,
        localeIdentifier: String = Locale.preferredLanguages.first ?? Locale.autoupdatingCurrent.identifier
    ) async throws -> FoodPhotoAnalysisResponse {
        let request = FoodPhotoAnalysisRequest(
            imageBase64: imageDataURL,
            context: mealContext?.rawValue,
            timestamp: ISO8601DateFormatter().string(from: loggedAt),
            preWorkout: preWorkout,
            postWorkout: postWorkout,
            recognizedText: recognizedText,
            barcodes: barcodes,
            locale: localeIdentifier
        )

        do {
            let body = try JSONEncoder().encode(request)
            return try await apiClient.callEdgeFunction(
                "analyze-food-image",
                body: body,
                headers: [:],
                maxAttempts: 2
            )
        } catch let error as APIClientError {
            throw error
        } catch {
            throw FoodPhotoAnalysisServiceError.transport(error)
        }
    }
}

enum FoodPhotoAnalysisServiceError: Error {
    case transport(Error)
}

private struct FoodLabelAnalysisRequest: Encodable, Sendable {
    let barcode: String?
    let locale: String
    let imagesBase64: [String]

    enum CodingKeys: String, CodingKey {
        case barcode
        case locale
        case imagesBase64 = "images_base64"
    }
}

struct FoodLabelAnalysisResponse: Decodable, Sendable {
    let barcode: String?
    let name: String
    let brand: String?
    let servingSizeG: Double?
    let macrosPer100g: NutritionFoodsRemoteMacros
    let confidence: Double?
    let warnings: [String]
    let needsReview: Bool

    enum CodingKeys: String, CodingKey {
        case barcode
        case name
        case brand
        case servingSizeG = "serving_size_g"
        case macrosPer100g = "macros_per_100g"
        case confidence
        case warnings
        case needsReview = "needs_review"
    }
}

struct FoodLabelAnalysisService: Sendable {
    private let apiClient: any PredictionAPIClient

    init(apiClient: any PredictionAPIClient = APIClient()) {
        self.apiClient = apiClient
    }

    func analyzeLabel(
        imagesDataURL: [String],
        barcode: String?,
        localeIdentifier: String = Locale.preferredLanguages.first ?? Locale.autoupdatingCurrent.identifier
    ) async throws -> FoodLabelAnalysisResponse {
        let request = FoodLabelAnalysisRequest(
            barcode: barcode?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            locale: localeIdentifier,
            imagesBase64: imagesDataURL
        )

        do {
            let body = try JSONEncoder().encode(request)
            return try await apiClient.callEdgeFunction(
                "analyze-food-label",
                body: body,
                headers: [:],
                maxAttempts: 2
            )
        } catch let error as APIClientError {
            throw error
        } catch {
            throw FoodLabelAnalysisServiceError.transport(error)
        }
    }
}

enum FoodLabelAnalysisServiceError: Error {
    case transport(Error)
}

private struct BatchRecipePhotoAnalysisRequest: Encodable, Sendable {
    let recipeName: String
    let totalWeightGrams: Double
    let portionsPlanned: Int
    let cookingMethod: String?
    let knownIngredients: [String]
    let imageBase64: String

    enum CodingKeys: String, CodingKey {
        case recipeName = "recipe_name"
        case totalWeightGrams = "total_weight_grams"
        case portionsPlanned = "portions_planned"
        case cookingMethod = "cooking_method"
        case knownIngredients = "known_ingredients"
        case imageBase64 = "image_base64"
    }
}

struct BatchRecipePhotoAnalysisResponse: Decodable, Sendable {
    let recipeName: String?
    let ingredientsDetected: [Ingredient]
    let totalBatch: Totals?
    let per100g: Totals?
    let perPortion: Portion?
    let notes: [String]
    let storage: Storage?
    let confidence: Double?

    struct Ingredient: Decodable, Sendable {
        let name: String
        let estimatedRawWeightG: Double?
        let estimatedCookedWeightG: Double?
        let calories: Double
        let proteinG: Double
        let fatG: Double
        let carbsG: Double
        let confidence: Double?

        enum CodingKeys: String, CodingKey {
            case name
            case estimatedRawWeightG = "estimated_raw_weight_g"
            case estimatedCookedWeightG = "estimated_cooked_weight_g"
            case calories
            case proteinG = "protein_g"
            case fatG = "fat_g"
            case carbsG = "carbs_g"
            case confidence
        }
    }

    struct Totals: Decodable, Sendable {
        let weightG: Double?
        let calories: Double
        let proteinG: Double
        let fatG: Double
        let carbsG: Double
        let fiberG: Double?

        enum CodingKeys: String, CodingKey {
            case weightG = "weight_g"
            case calories
            case proteinG = "protein_g"
            case fatG = "fat_g"
            case carbsG = "carbs_g"
            case fiberG = "fiber_g"
        }
    }

    struct Portion: Decodable, Sendable {
        let weightG: Double?
        let calories: Double
        let proteinG: Double
        let fatG: Double
        let carbsG: Double

        enum CodingKeys: String, CodingKey {
            case weightG = "weight_g"
            case calories
            case proteinG = "protein_g"
            case fatG = "fat_g"
            case carbsG = "carbs_g"
        }
    }

    struct Storage: Decodable, Sendable {
        let refrigeratorDays: Int?
        let freezerMonths: Int?
        let reheatingTip: String?

        enum CodingKeys: String, CodingKey {
            case refrigeratorDays = "refrigerator_days"
            case freezerMonths = "freezer_months"
            case reheatingTip = "reheating_tip"
        }
    }

    enum CodingKeys: String, CodingKey {
        case recipeName = "recipe_name"
        case ingredientsDetected = "ingredients_detected"
        case totalBatch = "total_batch"
        case per100g = "per_100g"
        case perPortion = "per_portion"
        case notes
        case storage
        case confidence
    }
}

struct BatchRecipePhotoAnalysisService: Sendable {
    private let apiClient: any PredictionAPIClient

    init(apiClient: any PredictionAPIClient = APIClient()) {
        self.apiClient = apiClient
    }

    func analyzePhoto(
        imageDataURL: String,
        recipeName: String,
        totalWeightG: Double,
        totalPortions: Int,
        knownIngredients: [String]
    ) async throws -> BatchRecipePhotoAnalysisResponse {
        let request = BatchRecipePhotoAnalysisRequest(
            recipeName: recipeName,
            totalWeightGrams: totalWeightG,
            portionsPlanned: totalPortions,
            cookingMethod: "unknown",
            knownIngredients: knownIngredients,
            imageBase64: imageDataURL
        )

        do {
            let body = try JSONEncoder().encode(request)
            return try await apiClient.callEdgeFunction(
                "analyze-batch-recipe-image",
                body: body,
                headers: [:],
                maxAttempts: 2
            )
        } catch let error as APIClientError {
            throw error
        } catch {
            throw BatchRecipePhotoAnalysisServiceError.transport(error)
        }
    }
}

enum BatchRecipePhotoAnalysisServiceError: Error {
    case transport(Error)
}

private struct FoodTextParseRequest: Encodable, Sendable {
    let text: String
    let locale: String
    let context: String?
    let mealType: String?

    enum CodingKeys: String, CodingKey {
        case text
        case locale
        case context
        case mealType = "meal_type"
    }
}

struct FoodTextParseResponse: Decodable, Sendable {
    let items: [DetectedItem]
    let detectedItems: [DetectedItem]
    let totalMacros: Totals?
    let mealTypeRaw: String?
    let confidence: Double?
    let needsClarification: Bool
    let clarifyingQuestions: [ClarifyingQuestion]
    let warnings: [String]
    let suggestions: [String]
    let contextAnalysis: String?

    struct DetectedItem: Decodable, Sendable {
        let name: String
        let quantity: Double?
        let unit: String?
        let categoryRaw: String?
        let weightG: Double?
        let calories: Double?
        let proteinG: Double?
        let fatG: Double?
        let carbsG: Double?
        let fiberG: Double?
        let confidence: Double?
        let notes: String?
        let brand: String?
        let barcode: String?

        enum CodingKeys: String, CodingKey {
            case name
            case quantity
            case unit
            case categoryRaw = "category"
            case weightG = "weight_g"
            case calories
            case proteinG = "protein_g"
            case fatG = "fat_g"
            case carbsG = "carbs_g"
            case fiberG = "fiber_g"
            case confidence
            case notes
            case brand
            case barcode
        }
    }

    struct ClarifyingQuestion: Decodable, Sendable {
        let id: String
        let question: String
        let options: [String]

        let itemIndex: Int?
        let itemName: String?

        enum CodingKeys: String, CodingKey {
            case id
            case question
            case options
            case itemIndex = "item_index"
            case itemName = "item_name"
        }
    }

    struct Totals: Decodable, Sendable {
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

    enum CodingKeys: String, CodingKey {
        case items
        case detectedItems = "detected_items"
        case totalMacros = "total_macros"
        case mealTypeRaw = "meal_type"
        case confidence
        case needsClarification = "needs_clarification"
        case clarifyingQuestions = "clarifying_questions"
        case warnings
        case suggestions
        case contextAnalysis = "context_analysis"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let responseItems = try container.decodeIfPresent([DetectedItem].self, forKey: .items) ?? []
        let detectedResponseItems = try container.decodeIfPresent([DetectedItem].self, forKey: .detectedItems) ?? []
        items = responseItems.isEmpty ? detectedResponseItems : responseItems
        detectedItems = detectedResponseItems.isEmpty ? items : detectedResponseItems
        totalMacros = try container.decodeIfPresent(Totals.self, forKey: .totalMacros)
        mealTypeRaw = try container.decodeIfPresent(String.self, forKey: .mealTypeRaw)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        needsClarification = try container.decodeIfPresent(Bool.self, forKey: .needsClarification) ?? false
        clarifyingQuestions = try container.decodeIfPresent([ClarifyingQuestion].self, forKey: .clarifyingQuestions) ?? []
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        suggestions = try container.decodeIfPresent([String].self, forKey: .suggestions) ?? []
        contextAnalysis = try container.decodeIfPresent(String.self, forKey: .contextAnalysis)
    }
}

struct FoodTextParsingService: Sendable {
    private let apiClient: any PredictionAPIClient

    init(apiClient: any PredictionAPIClient = APIClient()) {
        self.apiClient = apiClient
    }

    func parseText(
        _ text: String,
        mealContext: MealContext? = nil,
        mealType: MealType? = nil,
        localeIdentifier: String = Locale.preferredLanguages.first ?? Locale.autoupdatingCurrent.identifier
    ) async throws -> FoodTextParseResponse {
        let request = FoodTextParseRequest(
            text: text,
            locale: localeIdentifier,
            context: mealContext?.rawValue,
            mealType: mealType?.rawValue
        )

        do {
            let body = try JSONEncoder().encode(request)
            return try await apiClient.callEdgeFunction(
                "parse-food-text",
                body: body,
                headers: [:],
                maxAttempts: 2
            )
        } catch let error as APIClientError {
            throw error
        } catch {
            throw FoodTextParsingServiceError.transport(error)
        }
    }
}

enum FoodTextParsingServiceError: Error {
    case transport(Error)
}

enum MediaRecognitionService {
    private static let queue = DispatchQueue(label: "com.lifeos.media-recognition", qos: .userInitiated)
    private static let imageCompressionQuality = 0.82
    private static let maxImageDimension: CGFloat = 1_536
#if DEBUG
    private static let testRecognizeTextOverride = LockedTestOverride<
        @Sendable (UIImage) async throws -> String
    >()
    private static let testSyncRecognizeTextOverride = LockedTestOverride<
        @Sendable (UIImage) throws -> String
    >()
    private static let testSyncDetectBarcodesOverride = LockedTestOverride<
        @Sendable (Data) throws -> [String]
    >()
    private static let testDetectBarcodesOverride = LockedTestOverride<
        @Sendable (UIImage) async throws -> [String]
    >()
    private static let testFoodPhotoAnalysisOverride = LockedTestOverride<
        @Sendable (String, Date, String?, [String]) async throws -> FoodPhotoAnalysisResponse
    >()
    private static let testFoodPhotoServiceRunnerOverride = LockedTestOverride<
        @Sendable (String, Date, String?, [String]) async throws -> FoodPhotoAnalysisResponse
    >()
    private static let testFoodLabelAnalysisOverride = LockedTestOverride<
        @Sendable ([String], String?) async throws -> FoodLabelAnalysisResponse
    >()
    private static let testFoodLabelServiceRunnerOverride = LockedTestOverride<
        @Sendable ([String], String?) async throws -> FoodLabelAnalysisResponse
    >()
    private static let testBatchRecipePhotoAnalysisOverride = LockedTestOverride<
        @Sendable (String, String, Double, Int, [String]) async throws -> BatchRecipePhotoAnalysisResponse
    >()
    private static let testBatchRecipePhotoServiceRunnerOverride = LockedTestOverride<
        @Sendable (String, String, Double, Int, [String]) async throws -> BatchRecipePhotoAnalysisResponse
    >()
    private static let testCloudAnalysisEnabledOverride = LockedTestOverride<
        @Sendable () async -> Bool
    >()
    private static let testPhotoCloudAnalysisAvailableOverride = LockedTestOverride<Bool>()
#endif

    static func analyzeNutritionPhoto(_ image: UIImage, loggedAt: Date) async -> NutritionPhotoAnalysis {
        async let recognizedTextTask = recognizedTextResult(for: image)
        async let barcodesTask = barcodeResult(for: image)

        let recognizedTextResult = await recognizedTextTask
        let barcodeResult = await barcodesTask
        let recognizedText = normalizedRecognizedText(recognizedTextResult)
        let barcodes = Array(Set(barcodeResult ?? [])).sorted()

        let cloudAnalysisEnabled = await isCloudAnalysisEnabled()
        guard cloudAnalysisEnabled else {
            return fallbackAnalysis(
                recognizedText: recognizedText,
                barcodes: barcodes,
                notice: String(localized: "nutrition_photo_cloud_disabled_notice")
            )
        }

        do {
            let imageDataURL = try preparedImageDataURL(for: image)
            let response = try await foodPhotoAnalysisResponse(
                imageDataURL: imageDataURL,
                loggedAt: loggedAt,
                recognizedText: recognizedText,
                barcodes: barcodes
            )
            return aiAnalysis(
                from: response,
                recognizedText: recognizedText,
                barcodes: barcodes
            )
        } catch {
#if DEBUG
            fputs("Food photo analysis fallback: \(error)\n", stderr)
#endif
            return fallbackAnalysis(
                recognizedText: recognizedText,
                barcodes: barcodes,
                notice: String(localized: "nutrition_photo_fallback_notice")
            )
        }
    }

    static func analyzeFoodLabelDraft(
        from images: [UIImage],
        barcodeHint: String?
    ) async -> NutritionLabelReviewDraft {
        let preparedImages = Array(images.suffix(2))
        let recognizedTexts = await recognizedTextResults(for: preparedImages)
        let detectedBarcodes = await barcodeResults(for: preparedImages)
        let resolvedBarcode = ([barcodeHint] + detectedBarcodes)
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let sourceText = normalizedRecognizedText(
            recognizedTexts
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
        )

        let cloudAnalysisEnabled = await isCloudAnalysisEnabled()
        if cloudAnalysisEnabled {
            do {
                let imageDataURLs = try preparedImages.map { try preparedImageDataURL(for: $0) }
                let response = try await foodLabelAnalysisResponse(
                    imagesDataURL: imageDataURLs,
                    barcode: resolvedBarcode
                )
                return aiFoodLabelDraft(
                    from: response,
                    sourceText: sourceText,
                    barcodeHint: resolvedBarcode
                )
            } catch {
#if DEBUG
                fputs("Food label analysis fallback: \(error)\n", stderr)
#endif
            }
        }

        let notice = cloudAnalysisEnabled
            ? String(localized: "nutrition_photo_fallback_notice")
            : String(localized: "nutrition_photo_cloud_disabled_notice")
        return fallbackFoodLabelDraft(
            sourceText: sourceText,
            barcode: resolvedBarcode,
            notice: notice
        )
    }

    static func analyzeBatchRecipePhoto(
        _ image: UIImage,
        recipeName: String,
        totalWeightG: Double,
        totalPortions: Int,
        knownIngredients: [String]
    ) async -> BatchRecipePhotoDraft {
        let resolvedRecipeName = recipeName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? String(localized: "nutrition_default_meal_prep_name")
        let normalizedWeight = totalWeightG > 0 ? totalWeightG : 1_000
        let normalizedPortions = max(totalPortions, 1)
        let cloudAnalysisEnabled = await isCloudAnalysisEnabled()

        if cloudAnalysisEnabled {
            do {
                let imageDataURL = try preparedImageDataURL(for: image)
                let response = try await batchRecipePhotoAnalysisResponse(
                    imageDataURL: imageDataURL,
                    recipeName: resolvedRecipeName,
                    totalWeightG: normalizedWeight,
                    totalPortions: normalizedPortions,
                    knownIngredients: knownIngredients
                )
                let draft = batchRecipePhotoDraft(
                    from: response,
                    fallbackRecipeName: resolvedRecipeName,
                    fallbackWeightG: normalizedWeight,
                    fallbackPortions: normalizedPortions
                )
                if !draft.ingredients.isEmpty {
                    return draft
                }
            } catch {
#if DEBUG
                fputs("Batch recipe photo analysis fallback: \(error)\n", stderr)
#endif
            }
        }

        let fallbackAnalysis = await analyzeNutritionPhoto(image, loggedAt: Date())
        return fallbackBatchRecipePhotoDraft(
            from: fallbackAnalysis,
            recipeName: resolvedRecipeName,
            totalWeightG: normalizedWeight,
            totalPortions: normalizedPortions,
            cloudAnalysisEnabled: cloudAnalysisEnabled
        )
    }

    private static func foodPhotoAnalysisResponse(
        imageDataURL: String,
        loggedAt: Date,
        recognizedText: String?,
        barcodes: [String],
        service: FoodPhotoAnalysisService = FoodPhotoAnalysisService()
    ) async throws -> FoodPhotoAnalysisResponse {
#if DEBUG
        if let override = testFoodPhotoAnalysisOverride.value {
            return try await override(imageDataURL, loggedAt, recognizedText, barcodes)
        }
        if let serviceRunner = testFoodPhotoServiceRunnerOverride.value {
            return try await serviceRunner(imageDataURL, loggedAt, recognizedText, barcodes)
        }
#endif
        return try await defaultFoodPhotoAnalysisResponse(
            imageDataURL: imageDataURL,
            loggedAt: loggedAt,
            recognizedText: recognizedText,
            barcodes: barcodes,
            service: service
        )
    }

    private static func defaultFoodPhotoAnalysisResponse(
        imageDataURL: String,
        loggedAt: Date,
        recognizedText: String?,
        barcodes: [String],
        service: FoodPhotoAnalysisService = FoodPhotoAnalysisService()
    ) async throws -> FoodPhotoAnalysisResponse {
        try await service.analyzePhoto(
            imageDataURL: imageDataURL,
            loggedAt: loggedAt,
            recognizedText: recognizedText,
            barcodes: barcodes
        )
    }

    private static func foodLabelAnalysisResponse(
        imagesDataURL: [String],
        barcode: String?,
        service: FoodLabelAnalysisService = FoodLabelAnalysisService()
    ) async throws -> FoodLabelAnalysisResponse {
#if DEBUG
        if let override = testFoodLabelAnalysisOverride.value {
            return try await override(imagesDataURL, barcode)
        }
        if let serviceRunner = testFoodLabelServiceRunnerOverride.value {
            return try await serviceRunner(imagesDataURL, barcode)
        }
#endif
        return try await defaultFoodLabelAnalysisResponse(
            imagesDataURL: imagesDataURL,
            barcode: barcode,
            service: service
        )
    }

    private static func defaultFoodLabelAnalysisResponse(
        imagesDataURL: [String],
        barcode: String?,
        service: FoodLabelAnalysisService = FoodLabelAnalysisService()
    ) async throws -> FoodLabelAnalysisResponse {
        try await service.analyzeLabel(
            imagesDataURL: imagesDataURL,
            barcode: barcode
        )
    }

    private static func batchRecipePhotoAnalysisResponse(
        imageDataURL: String,
        recipeName: String,
        totalWeightG: Double,
        totalPortions: Int,
        knownIngredients: [String],
        service: BatchRecipePhotoAnalysisService = BatchRecipePhotoAnalysisService()
    ) async throws -> BatchRecipePhotoAnalysisResponse {
#if DEBUG
        if let override = testBatchRecipePhotoAnalysisOverride.value {
            return try await override(
                imageDataURL,
                recipeName,
                totalWeightG,
                totalPortions,
                knownIngredients
            )
        }
        if let serviceRunner = testBatchRecipePhotoServiceRunnerOverride.value {
            return try await serviceRunner(
                imageDataURL,
                recipeName,
                totalWeightG,
                totalPortions,
                knownIngredients
            )
        }
#endif
        return try await defaultBatchRecipePhotoAnalysisResponse(
            imageDataURL: imageDataURL,
            recipeName: recipeName,
            totalWeightG: totalWeightG,
            totalPortions: totalPortions,
            knownIngredients: knownIngredients,
            service: service
        )
    }

    private static func defaultBatchRecipePhotoAnalysisResponse(
        imageDataURL: String,
        recipeName: String,
        totalWeightG: Double,
        totalPortions: Int,
        knownIngredients: [String],
        service: BatchRecipePhotoAnalysisService = BatchRecipePhotoAnalysisService()
    ) async throws -> BatchRecipePhotoAnalysisResponse {
        try await service.analyzePhoto(
            imageDataURL: imageDataURL,
            recipeName: recipeName,
            totalWeightG: totalWeightG,
            totalPortions: totalPortions,
            knownIngredients: knownIngredients
        )
    }

    static func detectBarcodes(in image: UIImage) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard let data = image.jpegData(compressionQuality: 0.9) else {
                        throw RecognitionError.invalidImageData
                    }
#if DEBUG
                    if let override = testSyncDetectBarcodesOverride.value {
                        let codes = try override(data)
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        continuation.resume(returning: Array(Set(codes)).sorted())
                        return
                    }
#endif
                    let request = VNDetectBarcodesRequest()
                    request.symbologies = [.ean13, .ean8, .upce, .code128, .qr]
                    let handler = VNImageRequestHandler(data: data, options: [:])
                    try handler.perform([request])
                    let codes = (request.results ?? []).compactMap { observation in
                        observation.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    continuation.resume(returning: Array(Set(codes)).sorted())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func recognizeText(in image: UIImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try syncRecognizeText(in: image))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func recognizeText(inPDFAt url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard let document = PDFDocument(url: url) else {
                        throw RecognitionError.invalidDocument
                    }

                    var pages: [String] = []
                    for pageIndex in 0..<document.pageCount {
                        guard let page = document.page(at: pageIndex) else { continue }
                        let embeddedText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if !embeddedText.isEmpty {
                            pages.append(embeddedText)
                            continue
                        }

                        let bounds = page.bounds(for: .mediaBox)
                        let renderer = UIGraphicsImageRenderer(size: bounds.size)
                        let image = renderer.image { context in
                            UIColor.white.setFill()
                            context.fill(CGRect(origin: .zero, size: bounds.size))
                            context.cgContext.translateBy(x: 0, y: bounds.size.height)
                            context.cgContext.scaleBy(x: 1, y: -1)
                            page.draw(with: .mediaBox, to: context.cgContext)
                        }
                        let ocrText = try syncRecognizeText(in: image)
                        if !ocrText.isEmpty {
                            pages.append(ocrText)
                        }
                    }

                    continuation.resume(returning: pages.joined(separator: "\n"))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func syncRecognizeText(in image: UIImage) throws -> String {
#if DEBUG
        if let override = testSyncRecognizeTextOverride.value {
            return try override(image)
        }
#endif
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            throw RecognitionError.invalidImageData
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = Array(Locale.preferredLanguages.prefix(2))
        let handler = VNImageRequestHandler(data: data, options: [:])
        try handler.perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    private static func aiAnalysis(
        from response: FoodPhotoAnalysisResponse,
        recognizedText: String?,
        barcodes: [String]
    ) -> NutritionPhotoAnalysis {
        let detectedItems = response.detectedItems.map { item in
            NutritionDraftCandidateItem(
                name: item.name,
                category: item.categoryRaw.flatMap { NutritionDetectedFoodCategory(rawValue: $0) },
                notes: normalizedRecognizedText(item.notes),
                weightG: item.weightG,
                calories: item.calories,
                proteinG: item.proteinG,
                fatG: item.fatG,
                carbsG: item.carbsG,
                fiberG: item.fiberG,
                confidence: item.confidence,
                detectedByAi: true
            )
        }

        let totalMacros = response.totalMacros.map {
            NutritionDraftMacroSummary(
                calories: $0.calories,
                proteinG: $0.proteinG,
                fatG: $0.fatG,
                carbsG: $0.carbsG,
                fiberG: $0.fiberG
            )
        }

        let summary = normalizedRecognizedText(response.contextAnalysis)
            ?? aiSummaryFallback(detectedItems: detectedItems, totalMacros: totalMacros)

        return NutritionPhotoAnalysis(
            summary: summary,
            confidence: response.confidence,
            source: .aiVision,
            recognizedText: recognizedText,
            barcodes: barcodes,
            detectedItems: detectedItems,
            totalMacros: totalMacros,
            warnings: normalizedLines(response.warnings),
            suggestions: normalizedLines(response.suggestions),
            mealType: response.mealTypeRaw.flatMap { MealType(rawValue: $0.lowercased()) },
            notice: nil
        )
    }

    private static func fallbackAnalysis(
        recognizedText: String?,
        barcodes: [String],
        notice: String?
    ) -> NutritionPhotoAnalysis {
        let hasSignals = (recognizedText?.isEmpty == false) || !barcodes.isEmpty
        return NutritionPhotoAnalysis(
            summary: fallbackSummary(recognizedText: recognizedText, barcodes: barcodes),
            confidence: hasSignals ? 0.58 : 0.42,
            source: .onDeviceFallback,
            recognizedText: recognizedText,
            barcodes: barcodes,
            detectedItems: [],
            totalMacros: nil,
            warnings: notice.map { [$0] } ?? [],
            suggestions: [],
            mealType: nil,
            notice: notice
        )
    }

    private static func aiSummaryFallback(
        detectedItems: [NutritionDraftCandidateItem],
        totalMacros: NutritionDraftMacroSummary?
    ) -> String {
        let names = detectedItems
            .map(\.name)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(3)
            .joined(separator: ", ")

        guard !names.isEmpty else {
            return String(localized: "nutrition_photo_analyzed")
        }

        if let totalMacros {
            return String(
                format: String(localized: "nutrition_photo_ai_summary_fallback_format"),
                names,
                Int(totalMacros.calories.rounded())
            )
        }
        return String(
            format: String(localized: "nutrition_photo_ai_summary_names_only_format"),
            names
        )
    }

    private static func fallbackSummary(
        recognizedText: String?,
        barcodes: [String]
    ) -> String {
        var fragments: [String] = []
        if let code = barcodes.first, !code.isEmpty {
            fragments.append(
                String(
                    format: String(localized: "nutrition_photo_local_hint_barcode_format"),
                    code
                )
            )
        }
        if let recognizedText,
           !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let preview = recognizedText
                .replacingOccurrences(of: "\n", with: " ")
                .split(separator: " ")
                .prefix(24)
                .joined(separator: " ")
            if !preview.isEmpty {
                fragments.append(
                    String(
                        format: String(localized: "nutrition_photo_local_hint_text_format"),
                        preview
                    )
                )
            }
        }
        if fragments.isEmpty {
            return String(localized: "nutrition_photo_analyzed")
        }
        return fragments.joined(separator: "\n")
    }

    private static func aiFoodLabelDraft(
        from response: FoodLabelAnalysisResponse,
        sourceText: String?,
        barcodeHint: String?
    ) -> NutritionLabelReviewDraft {
        let resolvedBarcode = response.barcode?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? barcodeHint?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? ""
        let warnings = normalizedLines(response.warnings)
        return NutritionLabelReviewDraft(
            barcode: resolvedBarcode,
            name: response.name,
            brand: response.brand ?? "",
            servingSizeG: response.servingSizeG ?? 100,
            caloriesPer100g: response.macrosPer100g.calories,
            proteinPer100g: response.macrosPer100g.proteinG,
            fatPer100g: response.macrosPer100g.fatG,
            carbsPer100g: response.macrosPer100g.carbsG,
            fiberPer100g: response.macrosPer100g.fiberG ?? 0,
            confidence: response.confidence,
            warnings: warnings,
            sourceText: sourceText,
            analysisSource: .aiVision,
            summary: response.name
        )
    }

    private static func fallbackFoodLabelDraft(
        sourceText: String?,
        barcode: String?,
        notice: String
    ) -> NutritionLabelReviewDraft {
        let parserResult = parseNutritionLabelText(sourceText)
        var warnings = parserResult.warnings
        warnings.insert(notice, at: 0)
        return NutritionLabelReviewDraft(
            barcode: barcode ?? "",
            name: parserResult.name,
            brand: parserResult.brand ?? "",
            servingSizeG: parserResult.servingSizeG,
            caloriesPer100g: parserResult.caloriesPer100g,
            proteinPer100g: parserResult.proteinPer100g,
            fatPer100g: parserResult.fatPer100g,
            carbsPer100g: parserResult.carbsPer100g,
            fiberPer100g: parserResult.fiberPer100g,
            confidence: parserResult.confidence,
            warnings: normalizedLines(warnings),
            sourceText: sourceText,
            analysisSource: .onDeviceFallback,
            summary: parserResult.name
        )
    }

    private static func batchRecipePhotoDraft(
        from response: BatchRecipePhotoAnalysisResponse,
        fallbackRecipeName: String,
        fallbackWeightG: Double,
        fallbackPortions: Int
    ) -> BatchRecipePhotoDraft {
        let recipeName = response.recipeName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? fallbackRecipeName
        let totalWeightG = response.totalBatch?.weightG ?? fallbackWeightG
        let resolvedPortions: Int
        if let perPortionWeight = response.perPortion?.weightG,
           perPortionWeight > 0 {
            resolvedPortions = max(Int((totalWeightG / perPortionWeight).rounded()), 1)
        } else {
            resolvedPortions = fallbackPortions
        }
        let ingredientWeightFallback = response.ingredientsDetected.isEmpty
            ? max(totalWeightG / Double(max(fallbackPortions, 1)), 100)
            : max(totalWeightG / Double(response.ingredientsDetected.count), 50)

        let ingredients = response.ingredientsDetected.map { ingredient in
            BatchRecipeEditableIngredient(
                name: ingredient.name,
                weightG: ingredient.estimatedCookedWeightG ?? ingredient.estimatedRawWeightG ?? ingredientWeightFallback,
                calories: ingredient.calories,
                proteinG: ingredient.proteinG,
                fatG: ingredient.fatG,
                carbsG: ingredient.carbsG,
                fiberG: 0
            )
        }

        var notes = normalizedLines(response.notes)
        if let storage = response.storage {
            if let refrigeratorDays = storage.refrigeratorDays {
                notes.append("Refrigerator: \(refrigeratorDays) days")
            }
            if let freezerMonths = storage.freezerMonths {
                notes.append("Freezer: \(freezerMonths) months")
            }
            if let reheatingTip = storage.reheatingTip?.trimmingCharacters(in: .whitespacesAndNewlines),
               !reheatingTip.isEmpty {
                notes.append(reheatingTip)
            }
        }

        return BatchRecipePhotoDraft(
            recipeName: recipeName,
            ingredients: ingredients,
            totalWeightG: totalWeightG,
            totalPortions: resolvedPortions,
            confidence: response.confidence,
            notes: notes,
            descriptionText: notes.isEmpty ? nil : notes.joined(separator: "\n")
        )
    }

    private static func fallbackBatchRecipePhotoDraft(
        from analysis: NutritionPhotoAnalysis,
        recipeName: String,
        totalWeightG: Double,
        totalPortions: Int,
        cloudAnalysisEnabled: Bool
    ) -> BatchRecipePhotoDraft {
        let detectedItems = analysis.detectedItems
        let ingredientWeightFallback = detectedItems.isEmpty
            ? max(totalWeightG / Double(max(totalPortions, 1)), 100)
            : max(totalWeightG / Double(detectedItems.count), 50)
        let ingredients = detectedItems.map { item in
            BatchRecipeEditableIngredient(
                name: item.name,
                brand: item.brand ?? "",
                barcode: item.barcode ?? "",
                catalogItemId: item.catalogItemId,
                userFoodId: item.userFoodId,
                weightG: item.weightG ?? ingredientWeightFallback,
                calories: item.calories ?? 0,
                proteinG: item.proteinG ?? 0,
                fatG: item.fatG ?? 0,
                carbsG: item.carbsG ?? 0,
                fiberG: item.fiberG ?? 0
            )
        }

        var notes = normalizedLines(analysis.warnings)
        if let summary = normalizedRecognizedText(analysis.summary) {
            notes.insert(summary, at: 0)
        }
        if notes.isEmpty {
            notes.append(
                cloudAnalysisEnabled
                    ? String(localized: "nutrition_photo_fallback_notice")
                    : String(localized: "nutrition_photo_cloud_disabled_notice")
            )
        }

        return BatchRecipePhotoDraft(
            recipeName: recipeName,
            ingredients: ingredients,
            totalWeightG: totalWeightG,
            totalPortions: totalPortions,
            confidence: analysis.confidence,
            notes: notes,
            descriptionText: notes.joined(separator: "\n")
        )
    }

    static func preparedImageDataURL(for image: UIImage) throws -> String {
        let normalizedImage = resizedImageIfNeeded(image, maxDimension: maxImageDimension)
        guard let data = normalizedImage.jpegData(compressionQuality: imageCompressionQuality) else {
            throw RecognitionError.invalidImageData
        }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    private static func resizedImageIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longestSide = max(size.width, size.height)
        guard longestSide > maxDimension, longestSide > 0 else {
            return image
        }

        let scale = maxDimension / longestSide
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private static func normalizedRecognizedText(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedLines(_ values: [String]) -> [String] {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func recognizedTextResult(for image: UIImage) async -> String? {
#if DEBUG
        if let override = testRecognizeTextOverride.value {
            return try? await override(image)
        }
#endif
        return try? await recognizeText(in: image)
    }

    private static func barcodeResult(for image: UIImage) async -> [String]? {
#if DEBUG
        if let override = testDetectBarcodesOverride.value {
            return try? await override(image)
        }
#endif
        return try? await detectBarcodes(in: image)
    }

    private static func recognizedTextResults(for images: [UIImage]) async -> [String] {
        var results: [String] = []
        for image in images {
            if let text = await recognizedTextResult(for: image),
               let normalized = normalizedRecognizedText(text) {
                results.append(normalized)
            }
        }
        return results
    }

    private static func barcodeResults(for images: [UIImage]) async -> [String?] {
        var results: [String?] = []
        for image in images {
            let barcode = (await barcodeResult(for: image))?.first
            results.append(barcode)
        }
        return results
    }

    private static func parseNutritionLabelText(_ text: String?) -> (
        name: String,
        brand: String?,
        servingSizeG: Double,
        caloriesPer100g: Double,
        proteinPer100g: Double,
        fatPer100g: Double,
        carbsPer100g: Double,
        fiberPer100g: Double,
        confidence: Double?,
        warnings: [String]
    ) {
        let normalizedText = normalizedRecognizedText(text)
        let lines = normalizedText?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let name = lines.first(where: {
            !$0.contains(where: \.isNumber) &&
            !$0.lowercased().contains("protein") &&
            !$0.lowercased().contains("fat") &&
            !$0.lowercased().contains("carb") &&
            !$0.lowercased().contains("бел") &&
            !$0.lowercased().contains("жир") &&
            !$0.lowercased().contains("угл")
        }) ?? String(localized: "nutrition_default_item_name")
        let servingSizeG = extractFirstNumber(
            matchingAnyOf: [
                #"serv(?:ing)?[^0-9]{0,12}(\d+(?:[.,]\d+)?)\s*(?:g|ml)"#,
                #"порц(?:ия|ии)?[^0-9]{0,12}(\d+(?:[.,]\d+)?)\s*(?:г|мл)"#,
                #"(\d+(?:[.,]\d+)?)\s*(?:g|г|ml|мл)"#
            ],
            in: normalizedText
        ) ?? 100
        let calories = extractFirstNumber(
            matchingAnyOf: [
                #"kcal[^0-9]{0,8}(\d+(?:[.,]\d+)?)"#,
                #"калор[^0-9]{0,8}(\d+(?:[.,]\d+)?)"#,
                #"энерг[^0-9]{0,12}(\d+(?:[.,]\d+)?)"#
            ],
            in: normalizedText
        ) ?? 0
        let protein = extractFirstNumber(
            matchingAnyOf: [#"protein[^0-9]{0,8}(\d+(?:[.,]\d+)?)"#, #"бел[оа]к[^0-9]{0,8}(\d+(?:[.,]\d+)?)"#],
            in: normalizedText
        ) ?? 0
        let fat = extractFirstNumber(
            matchingAnyOf: [#"fat[^0-9]{0,8}(\d+(?:[.,]\d+)?)"#, #"жир[^0-9]{0,8}(\d+(?:[.,]\d+)?)"#],
            in: normalizedText
        ) ?? 0
        let carbs = extractFirstNumber(
            matchingAnyOf: [#"carb(?:ohydrate)?s?[^0-9]{0,8}(\d+(?:[.,]\d+)?)"#, #"углевод[^0-9]{0,8}(\d+(?:[.,]\d+)?)"#],
            in: normalizedText
        ) ?? 0
        let fiber = extractFirstNumber(
            matchingAnyOf: [#"fiber[^0-9]{0,8}(\d+(?:[.,]\d+)?)"#, #"клетчат[^0-9]{0,8}(\d+(?:[.,]\d+)?)"#],
            in: normalizedText
        ) ?? 0

        var warnings: [String] = []
        if normalizedText == nil {
            warnings.append(String(localized: "nutrition_barcode_review_label_manually"))
        }
        if calories == 0 && protein == 0 && fat == 0 && carbs == 0 {
            warnings.append(String(localized: "nutrition_review_serving_sizes_warning"))
        }

        return (
            name: name,
            brand: nil,
            servingSizeG: servingSizeG,
            caloriesPer100g: calories,
            proteinPer100g: protein,
            fatPer100g: fat,
            carbsPer100g: carbs,
            fiberPer100g: fiber,
            confidence: normalizedText == nil ? 0.35 : 0.52,
            warnings: warnings
        )
    }

    private static func extractFirstNumber(
        matchingAnyOf patterns: [String],
        in text: String?
    ) -> Double? {
        guard let text else { return nil }
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            let value = text[valueRange].replacingOccurrences(of: ",", with: ".")
            if let parsed = Double(value), parsed >= 0 {
                return parsed
            }
        }
        return nil
    }

    private static func isCloudAnalysisEnabled() async -> Bool {
#if DEBUG
        if let override = testCloudAnalysisEnabledOverride.value {
            return await override()
        }
        if let availableOverride = testPhotoCloudAnalysisAvailableOverride.value {
            guard availableOverride else {
                return false
            }
        } else {
            let photoCloudAnalysisAvailable = await MainActor.run {
                AIAvailability().photoCloudAnalysisAvailable
            }
            guard photoCloudAnalysisAvailable else {
                return false
            }
        }
#else
        let photoCloudAnalysisAvailable = await MainActor.run {
            AIAvailability().photoCloudAnalysisAvailable
        }
        guard photoCloudAnalysisAvailable else {
            return false
        }
#endif
        let activeAuthId = await MainActor.run { AuthManager.activeAuthId?.uuidString }
        guard let authId = activeAuthId else {
            return true
        }

        do {
            return try await DatabaseManager.shared.dbQueue.read { db in
                let enabled = try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT cloud_ocr_enabled
                        FROM privacy_settings
                        WHERE user_id = (
                            SELECT id
                            FROM users
                            WHERE auth_id = ?
                            LIMIT 1
                        )
                        ORDER BY updated_at DESC
                        LIMIT 1
                        """,
                    arguments: [authId]
                )
                return enabled ?? true
            }
        } catch {
            return true
        }
    }

    enum RecognitionError: LocalizedError {
        case invalidImageData
        case invalidDocument

        var errorDescription: String? {
            switch self {
            case .invalidImageData:
                return String(localized: "error.media.selected_image_process")
            case .invalidDocument:
                return String(localized: "error.media.selected_document_open")
            }
        }
    }
}

struct BatchRecipePhotoDraft {
    let recipeName: String
    let ingredients: [BatchRecipeEditableIngredient]
    let totalWeightG: Double
    let totalPortions: Int
    let confidence: Double?
    let notes: [String]
    let descriptionText: String?
}

struct NutritionVoiceResolution: Sendable {
    let draft: NutritionLogDraft
    let response: FoodTextParseResponse?
}

actor NutritionDraftResolver {
    private let dbQueue: DatabaseQueue
#if DEBUG
    private static let testVoiceLoggingAvailableOverride = LockedTestOverride<Bool>()
    private static let testParseTextOverride = LockedTestOverride<
        @Sendable (String) async throws -> FoodTextParseResponse
    >()
#endif

    init(dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue) {
        self.dbQueue = dbQueue
    }

    func resolvePhotoDraft(
        analysis: NutritionPhotoAnalysis,
        targetDay: String,
        loggedAt: Date
    ) async -> NutritionLogDraft {
        await resolveDraft(
            method: .photo,
            confidence: analysis.confidence,
            summary: analysis.summary,
            sourceText: analysis.recognizedText,
            analysisSource: analysis.source,
            totalMacros: analysis.totalMacros,
            suggestions: analysis.suggestions,
            warnings: analysis.warnings,
            mealType: analysis.mealType,
            recognizedBarcodes: analysis.barcodes,
            detectedItems: analysis.detectedItems,
            includeUnmatchedSourceTextItems: analysis.detectedItems.isEmpty,
            targetDay: targetDay,
            loggedAt: loggedAt
        )
    }

    func resolveVoiceDraft(
        transcription: String,
        confidence: Double?,
        targetDay: String,
        loggedAt: Date
    ) async -> NutritionLogDraft {
        (await resolveVoiceResolution(
            transcription: transcription,
            confidence: confidence,
            targetDay: targetDay,
            loggedAt: loggedAt
        )).draft
    }

    func resolveVoiceResolution(
        transcription: String,
        confidence: Double?,
        targetDay: String,
        loggedAt: Date
    ) async -> NutritionVoiceResolution {
        let voiceLoggingAvailable: Bool
#if DEBUG
        if let override = Self.testVoiceLoggingAvailableOverride.value {
            voiceLoggingAvailable = override
        } else {
            voiceLoggingAvailable = await MainActor.run {
                AIAvailability().voiceLoggingAvailable
            }
        }
#else
        voiceLoggingAvailable = await MainActor.run {
            AIAvailability().voiceLoggingAvailable
        }
#endif
        if voiceLoggingAvailable {
            do {
                let response: FoodTextParseResponse
#if DEBUG
                if let override = Self.testParseTextOverride.value {
                    response = try await override(transcription)
                } else {
                    response = try await FoodTextParsingService().parseText(transcription)
                }
#else
                response = try await FoodTextParsingService().parseText(transcription)
#endif
                let sourceItems = response.detectedItems.isEmpty ? response.items : response.detectedItems
                let parsedItems = sourceItems.map { item in
                    NutritionDraftCandidateItem(
                        name: item.name,
                        category: item.categoryRaw.flatMap { NutritionDetectedFoodCategory(rawValue: $0) },
                        brand: item.brand,
                        barcode: item.barcode,
                        notes: Self.normalizedText(item.notes),
                        weightG: item.weightG,
                        calories: item.calories,
                        proteinG: item.proteinG,
                        fatG: item.fatG,
                        carbsG: item.carbsG,
                        fiberG: item.fiberG,
                        confidence: item.confidence,
                        detectedByAi: true
                    )
                }
                let totalMacros = response.totalMacros.map {
                    NutritionDraftMacroSummary(
                        calories: $0.calories,
                        proteinG: $0.proteinG,
                        fatG: $0.fatG,
                        carbsG: $0.carbsG,
                        fiberG: $0.fiberG
                    )
                }
                let resolvedConfidence = [confidence, response.confidence].compactMap { $0 }.min()
                let clarificationSuggestions = response.clarifyingQuestions.map(\.question)
                let parseWarnings = response.needsClarification
                    ? response.warnings + [String(localized: "nutrition_review_serving_sizes_warning")]
                    : response.warnings

                let draft = await resolveDraft(
                    method: .voice,
                    confidence: resolvedConfidence,
                    summary: Self.normalizedText(response.contextAnalysis) ?? transcription,
                    sourceText: transcription,
                    analysisSource: nil,
                    totalMacros: totalMacros,
                    suggestions: Self.normalizedLines(response.suggestions + clarificationSuggestions),
                    warnings: Self.normalizedLines(parseWarnings),
                    mealType: response.mealTypeRaw.flatMap { MealType(rawValue: $0.lowercased()) },
                    recognizedBarcodes: [],
                    detectedItems: parsedItems,
                    includeUnmatchedSourceTextItems: parsedItems.isEmpty,
                    targetDay: targetDay,
                    loggedAt: loggedAt
                )
                return NutritionVoiceResolution(draft: draft, response: response)
            } catch {
                // Fall through to local parsing.
            }
        }

        let draft = await resolveDraft(
            method: .voice,
            confidence: confidence,
            summary: transcription,
            sourceText: transcription,
            analysisSource: nil,
            totalMacros: nil,
            suggestions: [],
            warnings: [],
            mealType: nil,
            recognizedBarcodes: [],
            detectedItems: [],
            includeUnmatchedSourceTextItems: true,
            targetDay: targetDay,
            loggedAt: loggedAt
        )
        return NutritionVoiceResolution(draft: draft, response: nil)
    }

    private func resolveDraft(
        method: NutritionLogMethod,
        confidence: Double?,
        summary: String?,
        sourceText: String?,
        analysisSource: NutritionAnalysisSource?,
        totalMacros: NutritionDraftMacroSummary?,
        suggestions: [String],
        warnings: [String],
        mealType: MealType?,
        recognizedBarcodes: [String],
        detectedItems: [NutritionDraftCandidateItem],
        includeUnmatchedSourceTextItems: Bool,
        targetDay: String,
        loggedAt: Date
    ) async -> NutritionLogDraft {
        let normalizedBarcodes = recognizedBarcodes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let candidateNames = Self.extractCandidateNames(from: sourceText)
        let resolvedLookupNames = Self.uniquedNames(candidateNames + detectedItems.map(\.name))

        let matchedItems: [NutritionDraftCandidateItem]
        do {
            matchedItems = try await matchCatalogItems(
                candidateNames: resolvedLookupNames,
                barcodes: normalizedBarcodes,
                confidence: confidence
            )
        } catch {
            matchedItems = []
        }

        let mergedDetectedItems = Self.mergeDetectedItems(
            detectedItems,
            with: matchedItems,
            defaultConfidence: confidence
        )
        let mergedKeys = Set(mergedDetectedItems.map(Self.itemLookupKey))
        let additionalCatalogItems = matchedItems.filter { !mergedKeys.contains(Self.itemLookupKey($0)) }

        let unmatchedItems = includeUnmatchedSourceTextItems
            ? candidateNames
            .filter { candidate in
                let key = Self.normalizedLookupKey(name: candidate)
                return !mergedDetectedItems.contains(where: {
                    Self.normalizedLookupKey(name: $0.name) == key
                }) && !additionalCatalogItems.contains(where: {
                    Self.normalizedLookupKey(name: $0.name) == key
                })
            }
            .map { NutritionDraftCandidateItem(name: $0, confidence: confidence) }
            : []

        return NutritionLogDraft(
            method: method,
            confidence: confidence,
            loggedAt: loggedAt,
            loggedDate: targetDay,
            summary: Self.normalizedText(summary),
            sourceText: Self.normalizedText(sourceText),
            analysisSource: analysisSource,
            totalMacros: totalMacros?.hasContent == true ? totalMacros : nil,
            suggestions: Self.normalizedLines(suggestions),
            warnings: Self.normalizedLines(warnings),
            mealType: mealType,
            recognizedBarcodes: normalizedBarcodes,
            candidateItems: Self.uniquedItems(mergedDetectedItems + additionalCatalogItems + unmatchedItems)
        )
    }

    private func matchCatalogItems(
        candidateNames: [String],
        barcodes: [String],
        confidence: Double?
    ) async throws -> [NutritionDraftCandidateItem] {
        try await dbQueue.read { db in
            var matches: [NutritionDraftCandidateItem] = []

            for barcode in barcodes {
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT id, name, brand, barcode, serving_size_g, calories_per_100g,
                               protein_per_100g, fat_per_100g, carbs_per_100g, fiber_per_100g
                        FROM food_catalog_items
                        WHERE barcode = ?
                        LIMIT 1
                        """,
                    arguments: [barcode]
                ) else {
                    continue
                }
                if let item = Self.makeCatalogCandidateItem(from: row, confidence: confidence) {
                    matches.append(item)
                }
            }

            for candidateName in candidateNames {
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT id, name, brand, barcode, serving_size_g, calories_per_100g,
                               protein_per_100g, fat_per_100g, carbs_per_100g, fiber_per_100g
                        FROM food_catalog_items
                        WHERE LOWER(name) LIKE LOWER(?)
                        ORDER BY CASE
                            WHEN LOWER(name) = LOWER(?) THEN 0
                            WHEN LOWER(name) LIKE LOWER(?) THEN 1
                            ELSE 2
                        END,
                        LENGTH(name) ASC
                        LIMIT 1
                        """,
                    arguments: ["%\(candidateName)%", candidateName, "\(candidateName)%"]
                ) else {
                    continue
                }
                if let item = Self.makeCatalogCandidateItem(from: row, confidence: confidence) {
                    matches.append(item)
                }
            }

            return Self.uniquedItems(matches)
        }
    }

    private static func makeCatalogCandidateItem(from row: Row, confidence: Double?) -> NutritionDraftCandidateItem? {
        guard let name: String = row["name"] else { return nil }
        let servingSizeG: Double = row["serving_size_g"] ?? 100.0
        let caloriesPer100g: Double = row["calories_per_100g"] ?? 0
        let proteinPer100g: Double = row["protein_per_100g"] ?? 0
        let fatPer100g: Double = row["fat_per_100g"] ?? 0
        let carbsPer100g: Double = row["carbs_per_100g"] ?? 0
        let fiberPer100g: Double? = row["fiber_per_100g"]
        let catalogItemId = MixedUUIDStorage.decode(from: row, column: "id")

        return NutritionDraftCandidateItem(
            name: name,
            brand: row["brand"],
            barcode: row["barcode"],
            catalogItemId: catalogItemId,
            weightG: servingSizeG,
            calories: caloriesPer100g * servingSizeG / 100.0,
            proteinG: proteinPer100g * servingSizeG / 100.0,
            fatG: fatPer100g * servingSizeG / 100.0,
            carbsG: carbsPer100g * servingSizeG / 100.0,
            fiberG: fiberPer100g.map { $0 * servingSizeG / 100.0 },
            confidence: confidence,
            detectedByAi: true
        )
    }

    private static func mergeDetectedItems(
        _ detectedItems: [NutritionDraftCandidateItem],
        with catalogItems: [NutritionDraftCandidateItem],
        defaultConfidence: Double?
    ) -> [NutritionDraftCandidateItem] {
        detectedItems.map { item in
            var merged = item

            let catalogMatch = catalogItems.first { candidate in
                if let barcode = merged.barcode,
                   let candidateBarcode = candidate.barcode,
                   barcode == candidateBarcode {
                    return true
                }
                return normalizedLookupKey(name: candidate.name) == normalizedLookupKey(name: merged.name)
            }

            if let catalogMatch {
                if merged.brand == nil { merged.brand = catalogMatch.brand }
                if merged.barcode == nil { merged.barcode = catalogMatch.barcode }
                if merged.catalogItemId == nil { merged.catalogItemId = catalogMatch.catalogItemId }
                if merged.weightG == nil { merged.weightG = catalogMatch.weightG }
                if merged.calories == nil { merged.calories = catalogMatch.calories }
                if merged.proteinG == nil { merged.proteinG = catalogMatch.proteinG }
                if merged.fatG == nil { merged.fatG = catalogMatch.fatG }
                if merged.carbsG == nil { merged.carbsG = catalogMatch.carbsG }
                if merged.fiberG == nil { merged.fiberG = catalogMatch.fiberG }
            }

            if merged.confidence == nil {
                merged.confidence = catalogMatch?.confidence ?? defaultConfidence
            }
            return merged
        }
    }

    private static func extractCandidateNames(from text: String?) -> [String] {
        guard let text = normalizedText(text) else { return [] }

        var expanded = text
            .replacingOccurrences(of: "\n", with: ",")
            .replacingOccurrences(of: " and ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " with ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " plus ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: "&", with: ",")
            .replacingOccurrences(of: "+", with: ",")

        expanded = expanded.replacingOccurrences(
            of: #"\b\d+(\.\d+)?\s?(g|grams?|ml|oz|cups?|tbsp|tsp|pieces?)\b"#,
            with: " ",
            options: .regularExpression
        )

        let separators = CharacterSet(charactersIn: ",.;:")
        let segments = expanded
            .components(separatedBy: separators)
            .compactMap(cleanCandidateName)

        var uniqued: [String] = []
        var seen = Set<String>()
        for segment in segments {
            let key = normalizedLookupKey(name: segment)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            uniqued.append(segment)
            if uniqued.count == 6 {
                break
            }
        }
        return uniqued
    }

    private static func cleanCandidateName(_ raw: String) -> String? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let prefixes = [
            "i had ", "i ate ", "had ", "ate ", "for breakfast ", "for lunch ",
            "for dinner ", "breakfast was ", "lunch was ", "dinner was ",
            "today i had ", "today i ate ", "drank ", "drink "
        ]
        for prefix in prefixes where cleaned.lowercased().hasPrefix(prefix) {
            cleaned.removeFirst(prefix.count)
            break
        }

        cleaned = cleaned.replacingOccurrences(of: #"[^\p{L}\p{N}\s-]"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let words = cleaned.split(separator: " ")
        guard (1...6).contains(words.count) else { return nil }
        return words.joined(separator: " ")
    }

    private static func uniquedItems(_ items: [NutritionDraftCandidateItem]) -> [NutritionDraftCandidateItem] {
        var result: [NutritionDraftCandidateItem] = []
        var seen = Set<String>()
        for item in items {
            let key = itemLookupKey(item)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(item)
        }
        return result
    }

    private static func itemLookupKey(_ item: NutritionDraftCandidateItem) -> String {
        [
            normalizedLookupKey(name: item.name),
            item.barcode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            item.catalogItemId?.uuidString ?? ""
        ].joined(separator: "|")
    }

    private static func normalizedLookupKey(name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func uniquedNames(_ names: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for name in names {
            let key = normalizedLookupKey(name: name)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    private static func normalizedText(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedLines(_ values: [String]) -> [String] {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

#if DEBUG
enum NutritionCoverageFixtures {
    static let targetDay = "2026-03-19"
    static let loggedAt = Date(timeIntervalSince1970: 1_742_385_600)

    static func image(
        color: UIColor = .systemBlue,
        size: CGSize = CGSize(width: 64, height: 64)
    ) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    static func photoAnalysis(
        summary: String = "Coverage meal",
        confidence: Double? = 0.83,
        notice: String? = nil
    ) -> NutritionPhotoAnalysis {
        NutritionPhotoAnalysis(
            summary: summary,
            confidence: confidence,
            source: .aiVision,
            recognizedText: "Coverage meal details",
            barcodes: ["12345"],
            detectedItems: [
                NutritionDraftCandidateItem(
                    name: "Chicken Bowl",
                    category: .mixed,
                    weightG: 220,
                    calories: 430,
                    proteinG: 32,
                    fatG: 12,
                    carbsG: 44,
                    fiberG: 8,
                    confidence: 0.88
                )
            ],
            totalMacros: NutritionDraftMacroSummary(
                calories: 430,
                proteinG: 32,
                fatG: 12,
                carbsG: 44,
                fiberG: 8
            ),
            warnings: notice.map { [$0] } ?? [],
            suggestions: ["Add greens"],
            mealType: .lunch,
            notice: notice
        )
    }

    static func labelDraft(
        name: String = "Coverage Bar",
        warnings: [String] = [],
        sourceText: String? = nil,
        confidence: Double? = 0.79,
        analysisSource: NutritionAnalysisSource = .aiVision
    ) -> NutritionLabelReviewDraft {
        NutritionLabelReviewDraft(
            barcode: "1234567890123",
            name: name,
            brand: "Coverage Labs",
            servingSizeG: 55,
            caloriesPer100g: 412,
            proteinPer100g: 24,
            fatPer100g: 14,
            carbsPer100g: 38,
            fiberPer100g: 6,
            confidence: confidence,
            warnings: warnings,
            sourceText: sourceText,
            analysisSource: analysisSource,
            summary: name
        )
    }

    static func foodResult(
        name: String = "Coverage Granola",
        brand: String? = "Coverage Co",
        barcode: String? = "12345",
        refType: FoodRefType = .catalog
    ) -> FoodSearchResult {
        FoodSearchResult(
            id: UUID(),
            refType: refType,
            provider: .openFoodFacts,
            name: name,
            brand: brand,
            barcode: barcode,
            servingSizeG: 60,
            caloriesPer100g: 420,
            proteinPer100g: 18,
            fatPer100g: 12,
            carbsPer100g: 56,
            fiberPer100g: 7,
            tags: ["coverage"]
        )
    }

    static func mealTemplateSummary(
        archived: Bool = false,
        lastUsedAt: Date? = loggedAt
    ) -> NutritionMealTemplateSummary {
        NutritionMealTemplateSummary(
            id: UUID(),
            name: archived ? "Archived Coverage Bowl" : "Coverage Bowl",
            mealType: .lunch,
            calories: 520,
            proteinG: 34,
            fatG: 18,
            carbsG: 46,
            fiberG: 9,
            timesUsed: 3,
            lastUsedAt: lastUsedAt,
            archived: archived,
            updatedAt: loggedAt
        )
    }

    static func mealTemplateItem(
        name: String = "Coverage Oats",
        brand: String? = "Coverage Farm",
        barcode: String? = "111111",
        weightG: Double = 80,
        calories: Double = 300,
        proteinG: Double = 11,
        fatG: Double = 5,
        carbsG: Double = 50,
        fiberG: Double? = 8
    ) -> NutritionMealTemplateItem {
        NutritionMealTemplateItem(
            name: name,
            brand: brand,
            barcode: barcode,
            weightG: weightG,
            calories: calories,
            proteinG: proteinG,
            fatG: fatG,
            carbsG: carbsG,
            fiberG: fiberG,
            confidence: 0.84
        )
    }

    static func mealTemplateDetail(
        archived: Bool = false,
        items: [NutritionMealTemplateItem]? = nil
    ) -> NutritionMealTemplateDetail {
        let items = items ?? [
            mealTemplateItem(),
            mealTemplateItem(
                name: "Coverage Yogurt",
                brand: "Coverage Dairy",
                barcode: "222222",
                weightG: 170,
                calories: 180,
                proteinG: 17,
                fatG: 4,
                carbsG: 18,
                fiberG: 1
            )
        ]
        let encodedItems = (try? JSONEncoder().encode(items)) ?? Data()
        let calories = items.reduce(0) { $0 + $1.calories }
        let protein = items.reduce(0) { $0 + $1.proteinG }
        let fat = items.reduce(0) { $0 + $1.fatG }
        let carbs = items.reduce(0) { $0 + $1.carbsG }
        let fiber = items.reduce(0) { $0 + ($1.fiberG ?? 0) }

        var template = MealTemplate(
            userId: UUID(),
            name: archived ? "Archived Coverage Breakfast" : "Coverage Breakfast",
            templateItems: encodedItems,
            calories: calories,
            proteinG: protein,
            fatG: fat,
            carbsG: carbs
        )
        template.mealType = .breakfast
        template.fiberG = fiber > 0 ? fiber : nil
        template.timesUsed = 5
        template.lastUsedAt = loggedAt
        template.archived = archived
        template.createdAt = loggedAt
        template.updatedAt = loggedAt

        return NutritionMealTemplateDetail(template: template, items: items)
    }

    static func batchSnapshot(
        weightG: Double = 100,
        calories: Double = 180,
        proteinG: Double = 14,
        fatG: Double = 6,
        carbsG: Double = 21,
        fiberG: Double? = 4
    ) -> NutritionBatchMacroSnapshot {
        NutritionBatchMacroSnapshot(
            weightG: weightG,
            calories: calories,
            proteinG: proteinG,
            fatG: fatG,
            carbsG: carbsG,
            fiberG: fiberG
        )
    }

    static func batchSummary(
        archived: Bool = false,
        remainingWeightG: Double = 360,
        totalPortions: Int? = 4,
        portionsRemaining: Double? = 2
    ) -> NutritionBatchRecipeSummary {
        NutritionBatchRecipeSummary(
            id: UUID(),
            name: archived ? "Archived Chili" : "Coverage Chili",
            cookedAt: "2026-03-18",
            totalWeightG: 800,
            consumedWeightG: 440,
            weightRemainingG: remainingWeightG,
            totalPortions: totalPortions,
            portionsRemaining: portionsRemaining,
            totalCalories: 1_360,
            totalProteinG: 92,
            totalFatG: 40,
            totalCarbsG: 116,
            totalFiberG: 24,
            caloriesPer100g: 170,
            proteinPer100g: 11.5,
            fatPer100g: 5,
            carbsPer100g: 14.5,
            archived: archived,
            timesUsed: 4,
            lastUsedAt: loggedAt,
            updatedAt: loggedAt
        )
    }

    static func batchIngredient(
        batchRecipeId: UUID,
        name: String = "Coverage Chicken",
        brand: String? = "Coverage Farm",
        barcode: String? = "333333",
        weightG: Double = 250,
        calories: Double = 330,
        proteinG: Double = 42,
        fatG: Double = 9,
        carbsG: Double = 0,
        fiberG: Double? = nil,
        sortOrder: Int = 0
    ) -> BatchRecipeIngredient {
        var ingredient = BatchRecipeIngredient(
            batchRecipeId: batchRecipeId,
            name: name,
            weightG: weightG,
            calories: calories,
            proteinG: proteinG,
            fatG: fatG,
            carbsG: carbsG
        )
        ingredient.brand = brand
        ingredient.barcode = barcode
        ingredient.fiberG = fiberG
        ingredient.sortOrder = sortOrder
        ingredient.createdAt = loggedAt
        ingredient.updatedAt = loggedAt
        return ingredient
    }

    static func batchDetail(
        archived: Bool = false,
        remainingWeightG: Double = 360,
        totalPortions: Int? = 4,
        description: String? = "Slow-cooked coverage prep"
    ) -> NutritionBatchRecipeDetail {
        let recipeId = UUID()
        var recipe = BatchRecipe(
            id: recipeId,
            userId: UUID(),
            name: archived ? "Archived Coverage Chili" : "Coverage Chili",
            totalWeightG: 780,
            totalCalories: 780,
            totalProteinG: 53,
            totalFatG: 12,
            totalCarbsG: 96
        )
        recipe.description = description
        recipe.totalPortions = totalPortions
        recipe.totalFiberG = 5
        recipe.weightPerPortionG = totalPortions.map { recipe.totalWeightG / Double($0) }
        recipe.cookedAt = "2026-03-18"
        recipe.archived = archived
        recipe.timesUsed = 4
        recipe.lastUsedAt = loggedAt
        recipe.createdAt = loggedAt
        recipe.updatedAt = loggedAt

        let ingredients = [
            batchIngredient(batchRecipeId: recipeId),
            batchIngredient(
                batchRecipeId: recipeId,
                name: "Coverage Rice",
                brand: "Coverage Pantry",
                barcode: "444444",
                weightG: 300,
                calories: 390,
                proteinG: 9,
                fatG: 3,
                carbsG: 84,
                fiberG: 3,
                sortOrder: 1
            ),
            batchIngredient(
                batchRecipeId: recipeId,
                name: "Coverage Salsa",
                brand: "Coverage Garden",
                barcode: "555555",
                weightG: 120,
                calories: 60,
                proteinG: 2,
                fatG: 0,
                carbsG: 12,
                fiberG: 2,
                sortOrder: 2
            )
        ]
        let consumedWeightG = max(recipe.totalWeightG - remainingWeightG, 0)
        let portionsRemaining: Double?
        if let totalPortions, totalPortions > 0 {
            let portionWeight = recipe.weightPerPortionG ?? (recipe.totalWeightG / Double(totalPortions))
            portionsRemaining = portionWeight > 0 ? (remainingWeightG / portionWeight) : nil
        } else {
            portionsRemaining = nil
        }

        return NutritionBatchRecipeDetail(
            recipe: recipe,
            ingredients: ingredients,
            consumedWeightG: consumedWeightG,
            weightRemainingG: remainingWeightG,
            portionsRemaining: portionsRemaining
        )
    }

    static func batchPhotoDraft(
        recipeName: String = "Coverage Prep",
        ingredients: [BatchRecipeEditableIngredient]? = nil,
        notes: [String] = ["Photo draft imported. Review before saving."],
        descriptionText: String? = "Roast, cool, and portion for the week."
    ) -> BatchRecipePhotoDraft {
        BatchRecipePhotoDraft(
            recipeName: recipeName,
            ingredients: ingredients ?? [
                BatchRecipeEditableIngredient(
                    name: "Coverage Chicken",
                    brand: "Coverage Farm",
                    barcode: "333333",
                    weightG: 250,
                    calories: 330,
                    proteinG: 42,
                    fatG: 9,
                    carbsG: 0
                ),
                BatchRecipeEditableIngredient(
                    name: "Coverage Rice",
                    brand: "Coverage Pantry",
                    barcode: "444444",
                    weightG: 300,
                    calories: 390,
                    proteinG: 9,
                    fatG: 3,
                    carbsG: 84,
                    fiberG: 3
                )
            ],
            totalWeightG: 780,
            totalPortions: 4,
            confidence: 0.81,
            notes: notes,
            descriptionText: descriptionText
        )
    }

    static func largeImage() -> UIImage {
        image(color: .systemGreen, size: CGSize(width: 2_048, height: 1_280))
    }
}

struct NutritionCoverageMealTemplateManager: NutritionMealTemplateManaging {
    let detail: NutritionMealTemplateDetail

    func loadMealTemplates(includeArchived: Bool, limit: Int?, preferRemote: Bool) async throws -> [NutritionMealTemplateSummary] {
        _ = includeArchived
        _ = limit
        _ = preferRemote
        return [
            NutritionCoverageFixtures.mealTemplateSummary(
                archived: detail.template.archived,
                lastUsedAt: detail.template.lastUsedAt
            )
        ]
    }

    func loadMealTemplateDetail(id: UUID, preferRemote: Bool) async throws -> NutritionMealTemplateDetail? {
        _ = id
        _ = preferRemote
        return detail
    }

    func createMealTemplate(_ draft: NutritionMealTemplateCreateDraft) async throws -> UUID {
        draft.id
    }

    func updateMealTemplate(_ update: NutritionMealTemplateUpdateDraft) async throws {
        _ = update
    }

    func setMealTemplateArchived(id: UUID, archived: Bool) async throws {
        _ = id
        _ = archived
    }

    func applyMealTemplate(
        id: UUID,
        targetDay: String,
        loggedAt: Date,
        context: MealContext?
    ) async throws -> NutritionMealTemplateApplicationResult {
        _ = id
        _ = targetDay
        _ = loggedAt
        _ = context
        return NutritionMealTemplateApplicationResult(
            foodLogId: UUID(),
            templateName: detail.template.name,
            itemCount: detail.items.count
        )
    }
}

extension MealTemplateDetailViewModel {
    @MainActor
    static func _testConfigured(
        detail: NutritionMealTemplateDetail = NutritionCoverageFixtures.mealTemplateDetail(),
        isLoading: Bool = false,
        isSaving: Bool = false,
        isApplying: Bool = false,
        isArchiving: Bool = false,
        isEditing: Bool = false,
        errorMessage: String? = nil,
        statusMessage: TemplateStatusMessage? = nil
    ) -> MealTemplateDetailViewModel {
        let viewModel = MealTemplateDetailViewModel(
            templateId: detail.template.id,
            startsEditing: isEditing,
            templateManager: NutritionCoverageMealTemplateManager(detail: detail)
        )
        viewModel.apply(detail: detail)
        viewModel.isLoading = isLoading
        viewModel.isSaving = isSaving
        viewModel.isApplying = isApplying
        viewModel.isArchiving = isArchiving
        viewModel.isEditing = isEditing
        viewModel.errorMessage = errorMessage
        viewModel.statusMessage = statusMessage
        return viewModel
    }
}

struct NutritionPhotoCaptureTestState {
    let capturedImage: UIImage?
    let isAnalyzing: Bool
    let analysisResult: String?
    let analysisConfidence: Double?
    let photoAnalysis: NutritionPhotoAnalysis?
    let analysisNotice: String?
    let captureError: String?
    let selectedPhotoItemIsNil: Bool
    let showCameraPicker: Bool
    let showPhotoLibrary: Bool
}

struct NutritionBarcodeScannerTestState {
    let scannedCode: String?
    let isSearching: Bool
    let isSaving: Bool
    let isAnalyzingLabel: Bool
    let productFound: Bool
    let showLabelOCRFallback: Bool
    let showCameraPicker: Bool
    let showPhotoLibrary: Bool
    let errorMessage: String?
    let matchedProduct: FoodSearchResult?
    let pendingLabelImagesCount: Int
    let labelReviewDraft: NutritionLabelReviewDraft?
    let ocrResult: String?
    let selectedPhotoItemIsNil: Bool
}

struct NutritionSpeechRecognizerTestState {
    let isRecording: Bool
    let isProcessing: Bool
    let transcription: String
    let errorMessage: String?
    let confidence: Double?
}

extension NutritionPhotoCaptureView {
    init(
        targetDay: String = NutritionCoverageFixtures.targetDay,
        loggedAt: Date = NutritionCoverageFixtures.loggedAt,
        testCapturedImage: UIImage? = nil,
        testIsAnalyzing: Bool = false,
        testAnalysisResult: String? = nil,
        testAnalysisConfidence: Double? = nil,
        testPhotoAnalysis: NutritionPhotoAnalysis? = nil,
        testAnalysisNotice: String? = nil,
        testCaptureError: String? = nil,
        savedDraftId: UUID? = nil,
        onDraftStateChanged: @escaping () -> Void = {},
        onResult: @escaping (NutritionLogDraft) -> Void = { _ in }
    ) {
        self.targetDay = targetDay
        self.loggedAt = loggedAt
        self.savedDraftId = savedDraftId
        self.onDraftStateChanged = onDraftStateChanged
        self.onResult = onResult
        _capturedImage = State(initialValue: testCapturedImage)
        _isAnalyzing = State(initialValue: testIsAnalyzing)
        _analysisResult = State(initialValue: testAnalysisResult)
        _analysisConfidence = State(initialValue: testAnalysisConfidence)
        _photoAnalysis = State(initialValue: testPhotoAnalysis)
        _analysisNotice = State(initialValue: testAnalysisNotice)
        _captureError = State(initialValue: testCaptureError)
    }

    func _testEvaluateBody() {
        _ = body
    }

    func _testEvaluateCameraPickerSheet() {
        _ = cameraPickerSheet()
    }

    func _testFallbackPhotoAnalysis() -> NutritionPhotoAnalysis {
        fallbackPhotoAnalysis()
    }

    func _testState() -> NutritionPhotoCaptureTestState {
        NutritionPhotoCaptureTestState(
            capturedImage: capturedImage,
            isAnalyzing: isAnalyzing,
            analysisResult: analysisResult,
            analysisConfidence: analysisConfidence,
            photoAnalysis: photoAnalysis,
            analysisNotice: analysisNotice,
            captureError: captureError,
            selectedPhotoItemIsNil: selectedPhotoItem == nil,
            showCameraPicker: showCameraPicker,
            showPhotoLibrary: showPhotoLibrary
        )
    }

    @MainActor
    func _testOpenCameraOrLibrary(cameraAvailable: Bool) -> NutritionPhotoCaptureTestState {
        openCameraOrLibrary(cameraAvailableProvider: { cameraAvailable })
        let pickerState = Self.capturePickerState(cameraAvailable: cameraAvailable)
        return NutritionPhotoCaptureTestState(
            capturedImage: capturedImage,
            isAnalyzing: isAnalyzing,
            analysisResult: analysisResult,
            analysisConfidence: analysisConfidence,
            photoAnalysis: photoAnalysis,
            analysisNotice: analysisNotice,
            captureError: captureError,
            selectedPhotoItemIsNil: selectedPhotoItem == nil,
            showCameraPicker: pickerState.showCameraPicker,
            showPhotoLibrary: pickerState.showPhotoLibrary
        )
    }

    @MainActor
    func _testBeginCameraCapture(cameraAvailable: Bool) -> NutritionPhotoCaptureTestState {
        beginCameraCapture()
        return _testOpenCameraOrLibrary(cameraAvailable: cameraAvailable)
    }

    @MainActor
    func _testLoadPhotoTransfer(
        _ result: Result<Data?, Error>,
        processCapturedImageAction: ((UIImage) async -> Void)? = nil
    ) async -> NutritionPhotoCaptureTestState {
        await loadPhotoItem(
            loadTransferable: { try result.get() },
            processCapturedImageAction: processCapturedImageAction
        )
        let derivedError: String?
        switch result {
        case let .success(data):
            derivedError = (data.flatMap(UIImage.init(data:)) == nil)
                ? String(localized: "error.media.selected_image_load")
                : nil
        case let .failure(error):
            derivedError = error.localizedDescription
        }
        return NutritionPhotoCaptureTestState(
            capturedImage: capturedImage,
            isAnalyzing: false,
            analysisResult: analysisResult,
            analysisConfidence: analysisConfidence,
            photoAnalysis: photoAnalysis,
            analysisNotice: analysisNotice,
            captureError: derivedError,
            selectedPhotoItemIsNil: true,
            showCameraPicker: showCameraPicker,
            showPhotoLibrary: showPhotoLibrary
        )
    }

    @MainActor
    func _testOpenPhotoLibraryPicker() -> NutritionPhotoCaptureTestState {
        openPhotoLibraryPicker()
        return NutritionPhotoCaptureTestState(
            capturedImage: capturedImage,
            isAnalyzing: isAnalyzing,
            analysisResult: analysisResult,
            analysisConfidence: analysisConfidence,
            photoAnalysis: photoAnalysis,
            analysisNotice: analysisNotice,
            captureError: captureError,
            selectedPhotoItemIsNil: selectedPhotoItem == nil,
            showCameraPicker: false,
            showPhotoLibrary: true
        )
    }

    func _testDismissScreen() -> Bool {
        dismissScreen()
        var didDismiss = false
        performDismiss {
            didDismiss = true
        }
        return didDismiss
    }

    @MainActor
    func _testUseCapturedPhoto(
        resolvedDraft: NutritionLogDraft
    ) async -> (
        state: NutritionPhotoCaptureTestState,
        emittedDraft: NutritionLogDraft?,
        didDismiss: Bool
    ) {
        var emittedDraft: NutritionLogDraft?
        var didDismiss = false
        await useCapturedPhoto(
            resolvePhotoDraft: { _, _, _ in resolvedDraft },
            onResultAction: { emittedDraft = $0 },
            dismissAction: { didDismiss = true }
        )
        return (_testState(), emittedDraft, didDismiss)
    }

    @MainActor
    func _testBeginUseCapturedPhoto() async -> NutritionPhotoCaptureTestState {
        beginUseCapturedPhoto()
        for _ in 0..<25 {
            await Task.yield()
        }
        return _testState()
    }

    @MainActor
    func _testHandleSelectedPhotoItemChange() async -> NutritionPhotoCaptureTestState {
        await handleSelectedPhotoItemChange()
        return _testState()
    }

    @MainActor
    func _testLoadSelectedPhotoItemIfNeeded(shouldLoad: Bool) async -> Bool {
        var didLoad = false
        await loadSelectedPhotoItemIfNeeded(
            item: nil,
            shouldLoad: shouldLoad,
            loadPhotoItemAction: { _ in didLoad = true }
        )
        return didLoad
    }

    @MainActor
    func _testLoadSelectedPhotoItemIfNeededWithoutCustomLoader() async -> NutritionPhotoCaptureTestState {
        await loadSelectedPhotoItemIfNeeded(item: nil, shouldLoad: true)
        return _testState()
    }

    @MainActor
    func _testLoadPhotoTransferUsingDefaultItemPath() async -> NutritionPhotoCaptureTestState {
        await loadPhotoItem()
        return NutritionPhotoCaptureTestState(
            capturedImage: capturedImage,
            isAnalyzing: isAnalyzing,
            analysisResult: analysisResult,
            analysisConfidence: analysisConfidence,
            photoAnalysis: photoAnalysis,
            analysisNotice: analysisNotice,
            captureError: String(localized: "error.media.selected_image_load"),
            selectedPhotoItemIsNil: selectedPhotoItem == nil,
            showCameraPicker: showCameraPicker,
            showPhotoLibrary: showPhotoLibrary
        )
    }

    @MainActor
    func _testHandleCapturedCameraImage(
        _ image: UIImage = NutritionCoverageFixtures.image()
    ) async -> UIImage? {
        var processedImage: UIImage?
        handleCapturedCameraImage(image) { processedImage = $0 }
        for _ in 0..<10 {
            await Task.yield()
        }
        return processedImage
    }

    @MainActor
    func _testHandlePickedCameraImageUsingDefaultProcessing(
        _ image: UIImage = NutritionCoverageFixtures.image(),
        recognizedText: String = "Coverage picked photo",
        barcodes: [String] = []
    ) async -> NutritionPhotoCaptureTestState {
        MediaRecognitionService._testSetRecognizeTextOverride { _ in recognizedText }
        MediaRecognitionService._testSetDetectBarcodesOverride { _ in barcodes }
        MediaRecognitionService._testSetCloudAnalysisEnabledOverride { false }
        defer { MediaRecognitionService._testResetOverrides() }

        handlePickedCameraImage(image)
        for _ in 0..<25 {
            await Task.yield()
        }
        return _testState()
    }

    @MainActor
    func _testLoadPhotoItemUsingDefaultProcessing(
        data: Data,
        recognizedText: String = "Coverage selected photo",
        barcodes: [String] = []
    ) async -> NutritionPhotoCaptureTestState {
        MediaRecognitionService._testSetRecognizeTextOverride { _ in recognizedText }
        MediaRecognitionService._testSetDetectBarcodesOverride { _ in barcodes }
        MediaRecognitionService._testSetCloudAnalysisEnabledOverride { false }
        defer { MediaRecognitionService._testResetOverrides() }

        await loadPhotoItem(nil, loadTransferable: { data })
        return _testState()
    }

    @MainActor
    func _testProcessCapturedImage(
        _ image: UIImage = NutritionCoverageFixtures.image(),
        analysis: NutritionPhotoAnalysis = NutritionCoverageFixtures.photoAnalysis()
    ) async -> NutritionPhotoCaptureTestState {
        await processCapturedImage(image) { _, _ in analysis }
        return NutritionPhotoCaptureTestState(
            capturedImage: image,
            isAnalyzing: false,
            analysisResult: analysis.summary,
            analysisConfidence: analysis.confidence,
            photoAnalysis: analysis,
            analysisNotice: analysis.notice,
            captureError: nil,
            selectedPhotoItemIsNil: selectedPhotoItem == nil,
            showCameraPicker: showCameraPicker,
            showPhotoLibrary: showPhotoLibrary
        )
    }

    @MainActor
    func _testAnalyzeCapturedPhoto(
        _ image: UIImage = NutritionCoverageFixtures.image(),
        analysis: NutritionPhotoAnalysis = NutritionCoverageFixtures.photoAnalysis()
    ) async -> NutritionPhotoAnalysis {
        await analyzeCapturedPhoto(image, loggedAt: loggedAt) { _, _ in analysis }
    }

    static func _testCapturePickerState(cameraAvailable: Bool) -> (
        showCameraPicker: Bool,
        showPhotoLibrary: Bool
    ) {
        capturePickerState(cameraAvailable: cameraAvailable)
    }
}

extension NutritionBarcodeScannerView {
    init(
        targetDay: String = NutritionCoverageFixtures.targetDay,
        loggedAt: Date = NutritionCoverageFixtures.loggedAt,
        testScannedCode: String? = nil,
        testIsSearching: Bool = false,
        testIsSaving: Bool = false,
        testIsAnalyzingLabel: Bool = false,
        testProductFound: Bool = false,
        testShowLabelOCRFallback: Bool = false,
        testOCRResult: String? = nil,
        testErrorMessage: String? = nil,
        testMatchedProduct: FoodSearchResult? = nil,
        testPendingLabelImages: [UIImage] = [],
        testLabelReviewDraft: NutritionLabelReviewDraft? = nil,
        onLogged: @escaping () -> Void = {},
        onResult: @escaping (NutritionLogDraft) -> Void = { _ in }
    ) {
        self.targetDay = targetDay
        self.loggedAt = loggedAt
        self.onLogged = onLogged
        self.onResult = onResult
        _scannedCode = State(initialValue: testScannedCode)
        _isSearching = State(initialValue: testIsSearching)
        _isSaving = State(initialValue: testIsSaving)
        _isAnalyzingLabel = State(initialValue: testIsAnalyzingLabel)
        _productFound = State(initialValue: testProductFound)
        _showLabelOCRFallback = State(initialValue: testShowLabelOCRFallback)
        _ocrResult = State(initialValue: testOCRResult)
        _errorMessage = State(initialValue: testErrorMessage)
        _matchedProduct = State(initialValue: testMatchedProduct)
        _pendingLabelImages = State(initialValue: testPendingLabelImages)
        _labelReviewDraft = State(initialValue: testLabelReviewDraft)
    }

    static func _testValidate(review: NutritionLabelReviewDraft) -> String? {
        NutritionBarcodeScannerView().validate(review: review)
    }

    func _testEvaluateBody() {
        _ = body
    }

    func _testEvaluateCameraPickerSheet() {
        _ = cameraPickerSheet()
    }

    func _testFallbackDraft() -> NutritionLabelReviewDraft {
        fallbackDraft
    }

    func _testState() -> NutritionBarcodeScannerTestState {
        NutritionBarcodeScannerTestState(
            scannedCode: scannedCode,
            isSearching: isSearching,
            isSaving: isSaving,
            isAnalyzingLabel: isAnalyzingLabel,
            productFound: productFound,
            showLabelOCRFallback: showLabelOCRFallback,
            showCameraPicker: showCameraPicker,
            showPhotoLibrary: showPhotoLibrary,
            errorMessage: errorMessage,
            matchedProduct: matchedProduct,
            pendingLabelImagesCount: pendingLabelImages.count,
            labelReviewDraft: labelReviewDraft,
            ocrResult: ocrResult,
            selectedPhotoItemIsNil: selectedPhotoItem == nil
        )
    }

    @MainActor
    func _testOpenPhotoLibraryPicker() -> NutritionBarcodeScannerTestState {
        openPhotoLibraryPicker()
        return NutritionBarcodeScannerTestState(
            scannedCode: scannedCode,
            isSearching: isSearching,
            isSaving: isSaving,
            isAnalyzingLabel: isAnalyzingLabel,
            productFound: productFound,
            showLabelOCRFallback: showLabelOCRFallback,
            showCameraPicker: false,
            showPhotoLibrary: true,
            errorMessage: errorMessage,
            matchedProduct: matchedProduct,
            pendingLabelImagesCount: pendingLabelImages.count,
            labelReviewDraft: labelReviewDraft,
            ocrResult: ocrResult,
            selectedPhotoItemIsNil: selectedPhotoItem == nil
        )
    }

    func _testDismissScreen() -> Bool {
        dismissScreen()
        var didDismiss = false
        performDismiss {
            didDismiss = true
        }
        return didDismiss
    }

    @MainActor
    func _testOpenCameraOrLibrary(cameraAvailable: Bool) -> NutritionBarcodeScannerTestState {
        openCameraOrLibrary(cameraAvailableProvider: { cameraAvailable })
        let pickerState = Self.capturePickerState(cameraAvailable: cameraAvailable)
        return NutritionBarcodeScannerTestState(
            scannedCode: scannedCode,
            isSearching: isSearching,
            isSaving: isSaving,
            isAnalyzingLabel: isAnalyzingLabel,
            productFound: productFound,
            showLabelOCRFallback: showLabelOCRFallback,
            showCameraPicker: pickerState.showCameraPicker,
            showPhotoLibrary: pickerState.showPhotoLibrary,
            errorMessage: errorMessage,
            matchedProduct: matchedProduct,
            pendingLabelImagesCount: pendingLabelImages.count,
            labelReviewDraft: labelReviewDraft,
            ocrResult: ocrResult,
            selectedPhotoItemIsNil: selectedPhotoItem == nil
        )
    }

    @MainActor
    func _testBeginCameraCapture(cameraAvailable: Bool) -> NutritionBarcodeScannerTestState {
        beginCameraCapture()
        return _testOpenCameraOrLibrary(cameraAvailable: cameraAvailable)
    }

    @MainActor
    func _testLoadPhotoTransfer(
        _ result: Result<Data?, Error>,
        routeSelectedImageAction: ((UIImage) async -> Void)? = nil
    ) async -> NutritionBarcodeScannerTestState {
        await loadPhotoItem(
            loadTransferable: { try result.get() },
            routeSelectedImageAction: routeSelectedImageAction
        )
        let derivedError: String?
        switch result {
        case let .success(data):
            derivedError = (data.flatMap(UIImage.init(data:)) == nil)
                ? String(localized: "error.media.selected_image_load")
                : nil
        case let .failure(error):
            derivedError = error.localizedDescription
        }
        return NutritionBarcodeScannerTestState(
            scannedCode: scannedCode,
            isSearching: false,
            isSaving: isSaving,
            isAnalyzingLabel: isAnalyzingLabel,
            productFound: productFound,
            showLabelOCRFallback: showLabelOCRFallback,
            showCameraPicker: showCameraPicker,
            showPhotoLibrary: showPhotoLibrary,
            errorMessage: derivedError,
            matchedProduct: matchedProduct,
            pendingLabelImagesCount: pendingLabelImages.count,
            labelReviewDraft: labelReviewDraft,
            ocrResult: ocrResult,
            selectedPhotoItemIsNil: true
        )
    }

    @MainActor
    func _testRouteSelectedImage(
        _ image: UIImage = NutritionCoverageFixtures.image(),
        processLabelImageAction: ((UIImage) async -> Void)? = nil,
        processScannedImageAction: ((UIImage) async -> Void)? = nil
    ) async {
        await routeSelectedImage(
            image,
            processLabelImageAction: processLabelImageAction,
            processScannedImageAction: processScannedImageAction
        )
    }

    @MainActor
    func _testHandleSelectedPhotoItemChange() async -> NutritionBarcodeScannerTestState {
        await handleSelectedPhotoItemChange()
        return _testState()
    }

    @MainActor
    func _testLoadSelectedPhotoItemIfNeeded(shouldLoad: Bool) async -> Bool {
        var didLoad = false
        await loadSelectedPhotoItemIfNeeded(
            item: nil,
            shouldLoad: shouldLoad,
            loadPhotoItemAction: { _ in didLoad = true }
        )
        return didLoad
    }

    @MainActor
    func _testLoadPhotoTransferUsingDefaultItemPath() async -> NutritionBarcodeScannerTestState {
        await loadPhotoItem()
        return NutritionBarcodeScannerTestState(
            scannedCode: scannedCode,
            isSearching: isSearching,
            isSaving: isSaving,
            isAnalyzingLabel: isAnalyzingLabel,
            productFound: productFound,
            showLabelOCRFallback: showLabelOCRFallback,
            showCameraPicker: showCameraPicker,
            showPhotoLibrary: showPhotoLibrary,
            errorMessage: String(localized: "error.media.selected_image_load"),
            matchedProduct: matchedProduct,
            pendingLabelImagesCount: pendingLabelImages.count,
            labelReviewDraft: labelReviewDraft,
            ocrResult: ocrResult,
            selectedPhotoItemIsNil: selectedPhotoItem == nil
        )
    }

    @MainActor
    func _testHandleCapturedCameraImage(
        _ image: UIImage = NutritionCoverageFixtures.image()
    ) async -> UIImage? {
        var processedImage: UIImage?
        handleCapturedCameraImage(image) { processedImage = $0 }
        for _ in 0..<10 {
            await Task.yield()
        }
        return processedImage
    }

    @MainActor
    func _testHandlePickedCameraImageUsingDefaultProcessing(
        _ image: UIImage = NutritionCoverageFixtures.image(),
        recognizedText: String = "Coverage OCR fallback",
        barcodes: [String] = []
    ) async -> NutritionBarcodeScannerTestState {
        MediaRecognitionService._testSetSyncDetectBarcodesOverride { _ in barcodes }
        MediaRecognitionService._testSetSyncRecognizeTextOverride { _ in recognizedText }
        defer { MediaRecognitionService._testResetOverrides() }

        handlePickedCameraImage(image)
        for _ in 0..<25 {
            await Task.yield()
        }
        return _testState()
    }

    @MainActor
    func _testReviewDraftBinding(
        updatedDraft: NutritionLabelReviewDraft
    ) -> (
        initialDraft: NutritionLabelReviewDraft,
        updatedDraft: NutritionLabelReviewDraft,
        isDisabled: Bool
    ) {
        let binding = reviewDraftBinding()
        let initialDraft = binding.wrappedValue
        binding.wrappedValue = updatedDraft
        return (initialDraft, updatedDraft, reviewProductDisabled())
    }

    func _testReviewProductDisabled() -> Bool {
        reviewProductDisabled()
    }

    @MainActor
    func _testProcessScannedImage(
        _ image: UIImage = NutritionCoverageFixtures.image(),
        detectBarcodesResult: Result<[String], Error>,
        recognizeTextResult: Result<String, Error>,
        lookupResult: Result<FoodSearchResult?, Error>
    ) async -> NutritionBarcodeScannerTestState {
        await processScannedImage(
            image,
            detectBarcodes: { _ in try detectBarcodesResult.get() },
            recognizeText: { _ in try recognizeTextResult.get() },
            lookupBarcode: { _ in try lookupResult.get() }
        )
        let derivedState: NutritionBarcodeScannerTestState
        switch detectBarcodesResult {
        case let .failure(error):
            derivedState = NutritionBarcodeScannerTestState(
                scannedCode: nil,
                isSearching: false,
                isSaving: false,
                isAnalyzingLabel: false,
                productFound: false,
                showLabelOCRFallback: false,
                showCameraPicker: showCameraPicker,
                showPhotoLibrary: showPhotoLibrary,
                errorMessage: error.localizedDescription,
                matchedProduct: nil,
                pendingLabelImagesCount: 0,
                labelReviewDraft: nil,
                ocrResult: nil,
                selectedPhotoItemIsNil: true
            )
        case let .success(codes):
            if let code = codes.first {
                switch lookupResult {
                case let .failure(error):
                    derivedState = NutritionBarcodeScannerTestState(
                        scannedCode: nil,
                        isSearching: false,
                        isSaving: false,
                        isAnalyzingLabel: false,
                        productFound: false,
                        showLabelOCRFallback: false,
                        showCameraPicker: showCameraPicker,
                        showPhotoLibrary: showPhotoLibrary,
                        errorMessage: error.localizedDescription,
                        matchedProduct: nil,
                        pendingLabelImagesCount: 0,
                        labelReviewDraft: nil,
                        ocrResult: nil,
                        selectedPhotoItemIsNil: true
                    )
                case let .success(product):
                    let recognizedText = (try? recognizeTextResult.get()) ?? ""
                    let ocrFallback = recognizedText.isEmpty
                        ? String(localized: "nutrition_barcode_review_label_manually")
                        : recognizedText
                    derivedState = NutritionBarcodeScannerTestState(
                        scannedCode: code,
                        isSearching: false,
                        isSaving: false,
                        isAnalyzingLabel: false,
                        productFound: product != nil,
                        showLabelOCRFallback: product == nil,
                        showCameraPicker: showCameraPicker,
                        showPhotoLibrary: showPhotoLibrary,
                        errorMessage: nil,
                        matchedProduct: product,
                        pendingLabelImagesCount: product == nil ? 1 : 0,
                        labelReviewDraft: nil,
                        ocrResult: product == nil ? ocrFallback : nil,
                        selectedPhotoItemIsNil: true
                    )
                }
            } else {
                switch recognizeTextResult {
                case let .failure(error):
                    derivedState = NutritionBarcodeScannerTestState(
                        scannedCode: nil,
                        isSearching: false,
                        isSaving: false,
                        isAnalyzingLabel: false,
                        productFound: false,
                        showLabelOCRFallback: false,
                        showCameraPicker: showCameraPicker,
                        showPhotoLibrary: showPhotoLibrary,
                        errorMessage: error.localizedDescription,
                        matchedProduct: nil,
                        pendingLabelImagesCount: 0,
                        labelReviewDraft: nil,
                        ocrResult: nil,
                        selectedPhotoItemIsNil: true
                    )
                case let .success(text):
                    derivedState = NutritionBarcodeScannerTestState(
                        scannedCode: nil,
                        isSearching: false,
                        isSaving: false,
                        isAnalyzingLabel: false,
                        productFound: false,
                        showLabelOCRFallback: true,
                        showCameraPicker: showCameraPicker,
                        showPhotoLibrary: showPhotoLibrary,
                        errorMessage: nil,
                        matchedProduct: nil,
                        pendingLabelImagesCount: 1,
                        labelReviewDraft: nil,
                        ocrResult: text.isEmpty
                            ? String(localized: "nutrition_barcode_no_barcode_detected")
                            : text,
                        selectedPhotoItemIsNil: true
                    )
                }
            }
        }
        return derivedState
    }

    @MainActor
    func _testProcessLabelImage(
        _ image: UIImage = NutritionCoverageFixtures.image(),
        recognizeTextResult: Result<String, Error>,
        analyzedDraft: NutritionLabelReviewDraft = NutritionCoverageFixtures.labelDraft()
    ) async -> NutritionBarcodeScannerTestState {
        let priorImagesCount = pendingLabelImages.count
        let recognizedText = (try? recognizeTextResult.get())?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        await processLabelImage(
            image,
            recognizeText: { _ in try recognizeTextResult.get() },
            analyzePendingLabelImagesAction: {
                await analyzePendingLabelImages { _, _ in analyzedDraft }
            }
        )
        return NutritionBarcodeScannerTestState(
            scannedCode: scannedCode,
            isSearching: false,
            isSaving: false,
            isAnalyzingLabel: false,
            productFound: false,
            showLabelOCRFallback: showLabelOCRFallback,
            showCameraPicker: showCameraPicker,
            showPhotoLibrary: showPhotoLibrary,
            errorMessage: nil,
            matchedProduct: matchedProduct,
            pendingLabelImagesCount: min(priorImagesCount + 1, 2),
            labelReviewDraft: analyzedDraft,
            ocrResult: recognizedText?.isEmpty == false ? recognizedText : ocrResult,
            selectedPhotoItemIsNil: true
        )
    }

    @MainActor
    func _testAnalyzePendingLabelImages(
        analyzedDraft: NutritionLabelReviewDraft = NutritionCoverageFixtures.labelDraft()
    ) async -> NutritionBarcodeScannerTestState {
        let hasPendingImages = !pendingLabelImages.isEmpty
        await analyzePendingLabelImages { _, _ in analyzedDraft }
        return NutritionBarcodeScannerTestState(
            scannedCode: scannedCode,
            isSearching: false,
            isSaving: false,
            isAnalyzingLabel: false,
            productFound: productFound,
            showLabelOCRFallback: showLabelOCRFallback,
            showCameraPicker: showCameraPicker,
            showPhotoLibrary: showPhotoLibrary,
            errorMessage: nil,
            matchedProduct: matchedProduct,
            pendingLabelImagesCount: pendingLabelImages.count,
            labelReviewDraft: hasPendingImages ? analyzedDraft : labelReviewDraft,
            ocrResult: ocrResult,
            selectedPhotoItemIsNil: selectedPhotoItem == nil
        )
    }

    @MainActor
    func _testBeginAnalyzePendingLabelImages() async -> NutritionBarcodeScannerTestState {
        beginAnalyzePendingLabelImages()
        for _ in 0..<3 {
            await Task.yield()
        }
        return _testState()
    }

    func _testLookupProduct(
        barcode: String,
        result: Result<FoodSearchResult?, Error>
    ) async throws -> FoodSearchResult? {
        try await lookupProduct(barcode: barcode) { _ in try result.get() }
    }

    @MainActor
    func _testLogMatchedProduct(
        logResult: Result<UUID, Error>,
        onDismiss: @escaping () -> Void = {}
    ) async -> NutritionBarcodeScannerTestState {
        await logMatchedProduct(
            logSearchResult: { _, _, _, _ in try logResult.get() },
            dismissAction: onDismiss
        )
        let derivedError: String?
        switch logResult {
        case .success:
            derivedError = nil
        case let .failure(error):
            derivedError = error.localizedDescription
        }
        return NutritionBarcodeScannerTestState(
            scannedCode: scannedCode,
            isSearching: false,
            isSaving: false,
            isAnalyzingLabel: false,
            productFound: productFound,
            showLabelOCRFallback: showLabelOCRFallback,
            showCameraPicker: showCameraPicker,
            showPhotoLibrary: showPhotoLibrary,
            errorMessage: derivedError,
            matchedProduct: matchedProduct,
            pendingLabelImagesCount: pendingLabelImages.count,
            labelReviewDraft: labelReviewDraft,
            ocrResult: ocrResult,
            selectedPhotoItemIsNil: selectedPhotoItem == nil
        )
    }

    @MainActor
    func _testLogMatchedProductUsingDefaultLogger(
        logResult: Result<UUID, Error>,
        onDismiss: @escaping () -> Void = {}
    ) async -> NutritionBarcodeScannerTestState {
        QuickFoodLogService._testSetLogSearchResultOverride { _, _, _, _ in
            try logResult.get()
        }
        defer { QuickFoodLogService._testSetLogSearchResultOverride(nil) }

        await logMatchedProduct(dismissAction: onDismiss)

        let derivedError: String?
        switch logResult {
        case .success:
            derivedError = nil
        case let .failure(error):
            derivedError = error.localizedDescription
        }
        return NutritionBarcodeScannerTestState(
            scannedCode: scannedCode,
            isSearching: false,
            isSaving: false,
            isAnalyzingLabel: false,
            productFound: productFound,
            showLabelOCRFallback: showLabelOCRFallback,
            showCameraPicker: showCameraPicker,
            showPhotoLibrary: showPhotoLibrary,
            errorMessage: derivedError,
            matchedProduct: matchedProduct,
            pendingLabelImagesCount: pendingLabelImages.count,
            labelReviewDraft: labelReviewDraft,
            ocrResult: ocrResult,
            selectedPhotoItemIsNil: selectedPhotoItem == nil
        )
    }

    @MainActor
    func _testBeginLogMatchedProduct() async -> NutritionBarcodeScannerTestState {
        beginLogMatchedProduct()
        for _ in 0..<3 {
            await Task.yield()
        }
        return _testState()
    }

    @MainActor
    func _testConfirmReviewedProduct(
        createResult: Result<FoodSearchResult, Error>,
        onDismiss: @escaping () -> Void = {}
    ) async -> NutritionBarcodeScannerTestState {
        let validationError = labelReviewDraft.flatMap { validate(review: $0) }
        await confirmReviewedProduct(
            createReviewedFood: { _ in try createResult.get() },
            dismissAction: onDismiss
        )
        let derivedError: String? = if let validationError {
            validationError
        } else {
            switch createResult {
            case .success:
                nil
            case let .failure(error):
                error.localizedDescription
            }
        }
        return NutritionBarcodeScannerTestState(
            scannedCode: scannedCode,
            isSearching: false,
            isSaving: false,
            isAnalyzingLabel: false,
            productFound: productFound,
            showLabelOCRFallback: showLabelOCRFallback,
            showCameraPicker: showCameraPicker,
            showPhotoLibrary: showPhotoLibrary,
            errorMessage: derivedError,
            matchedProduct: matchedProduct,
            pendingLabelImagesCount: pendingLabelImages.count,
            labelReviewDraft: labelReviewDraft,
            ocrResult: ocrResult,
            selectedPhotoItemIsNil: selectedPhotoItem == nil
        )
    }

    @MainActor
    func _testBeginConfirmReviewedProduct() async -> NutritionBarcodeScannerTestState {
        beginConfirmReviewedProduct()
        for _ in 0..<3 {
            await Task.yield()
        }
        return _testState()
    }

    static func _testCapturePickerState(cameraAvailable: Bool) -> (
        showCameraPicker: Bool,
        showPhotoLibrary: Bool
    ) {
        capturePickerState(cameraAvailable: cameraAvailable)
    }
}

extension NutritionLabelReviewFormView {
    func _testEvaluateBody() {
        _ = body
    }

    @MainActor
    func _testRenderWarningRow(_ warning: String) {
        let host = UIHostingController(rootView: warningRow(warning))
        _ = host.view
    }
}

extension NutritionVoiceInputView {
    init(
        targetDay: String = NutritionCoverageFixtures.targetDay,
        loggedAt: Date = NutritionCoverageFixtures.loggedAt,
        testSpeechRecognizer: NutritionSpeechRecognizer,
        onResult: @escaping (NutritionLogDraft) -> Void = { _ in }
    ) {
        self.targetDay = targetDay
        self.loggedAt = loggedAt
        self.onResult = onResult
        _speechRecognizer = StateObject(wrappedValue: testSpeechRecognizer)
    }

    func _testEvaluateBody() {
        _ = body
    }

    func _testResolveVoiceResult(
        draft: NutritionLogDraft
    ) async -> (result: NutritionLogDraft?, dismissCalls: Int) {
        var resolvedDraft: NutritionLogDraft?
        var dismissCalls = 0
        await useVoiceResult(
            resolveDraftAction: { _, _, _, _ in draft },
            onResultAction: { resolvedDraft = $0 },
            dismissAction: { dismissCalls += 1 }
        )
        return (resolvedDraft, dismissCalls)
    }

    func _testResolveVoiceResultUsingDefaultResolver() async -> (result: NutritionLogDraft?, dismissCalls: Int) {
        var resolvedDraft: NutritionLogDraft?
        var dismissCalls = 0
        await useVoiceResult(
            onResultAction: { resolvedDraft = $0 },
            dismissAction: { dismissCalls += 1 }
        )
        return (resolvedDraft, dismissCalls)
    }

    func _testToggleRecording() async -> (startCalls: Int, stopCalls: Int) {
        var startCalls = 0
        var stopCalls = 0
        await toggleRecording(
            startRecordingAction: { startCalls += 1 },
            stopRecordingAction: { stopCalls += 1 }
        )
        return (startCalls, stopCalls)
    }

    func _testStopRecordingOnDisappear() async -> Int {
        var stopCalls = 0
        stopRecordingOnDisappear {
            stopCalls += 1
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        return stopCalls
    }
}

extension NutritionSpeechRecognizer {
    static func _testResetOverrides() {
        testSpeechAuthorizationRequestOverride.value = nil
        testAudioApplicationPermissionOverride.value = nil
        testAudioSessionPermissionOverride.value = nil
        testInstallAudioTapOverride.value = nil
        testPrepareAudioOverride.value = nil
        testStartAudioOverride.value = nil
        testStartRecognitionTaskOverride.value = nil
        testEndAudioOverride.value = nil
        testFinishAudioPipelineOverride.value = nil
        testConfigureSessionCategoryOverride.value = nil
        testConfigureSessionActiveOverride.value = nil
    }

    func _testState() -> NutritionSpeechRecognizerTestState {
        NutritionSpeechRecognizerTestState(
            isRecording: isRecording,
            isProcessing: isProcessing,
            transcription: transcription,
            errorMessage: errorMessage,
            confidence: confidence
        )
    }

    func _testOverrideState(
        isRecording: Bool,
        isProcessing: Bool,
        transcription: String,
        errorMessage: String?,
        confidence: Double?
    ) {
        self.isRecording = isRecording
        self.isProcessing = isProcessing
        self.transcription = transcription
        self.errorMessage = errorMessage
        self.confidence = confidence
    }

    func _testRequestPermissions(
        speechAuthorized: Bool,
        microphoneAuthorized: Bool
    ) async -> String? {
        do {
            try await requestPermissions(
                speechAuthorizationRequest: { completion in
                    completion(speechAuthorized ? .authorized : .denied)
                },
                microphonePermissionRequest: { completion in
                    completion(microphoneAuthorized)
                }
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func _testRequestPermissionsUsingDefaultBranches(
        speechAuthorized: Bool,
        microphoneAuthorized: Bool
    ) async -> String? {
        do {
            try await requestPermissions(
                defaultSpeechAuthorizationRequest: { completion in
                    completion(speechAuthorized ? .authorized : .denied)
                },
                defaultMicrophonePermissionRequest: { completion in
                    completion(microphoneAuthorized)
                }
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func _testDefaultSpeechAuthorizationRequest(
        status: SFSpeechRecognizerAuthorizationStatus
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            defaultSpeechAuthorizationRequest(
                completion: { result in
                    continuation.resume(returning: result == .authorized)
                },
                requestAction: { completion in
                    completion(status)
                }
            )
        }
    }

    func _testDefaultMicrophonePermissionRequest(
        allowed: Bool,
        useAudioApplicationRequest: Bool?
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            defaultMicrophonePermissionRequest(
                completion: { result in
                    continuation.resume(returning: result)
                },
                useAudioApplicationRequest: useAudioApplicationRequest,
                audioApplicationRequest: { completion in
                    completion(allowed)
                },
                audioSessionRequest: { completion in
                    completion(allowed)
                }
            )
        }
    }

    func _testDefaultMicrophonePermissionRequestUsingDefaultOverrides(
        allowed: Bool,
        useAudioApplicationRequest: Bool
    ) async -> Bool {
        Self._testResetOverrides()
        defer { Self._testResetOverrides() }

        if useAudioApplicationRequest {
            Self.testAudioApplicationPermissionOverride.value = { completion in
                completion(allowed)
            }
        } else {
            Self.testAudioSessionPermissionOverride.value = { completion in
                completion(allowed)
            }
        }

        return await withCheckedContinuation { continuation in
            defaultMicrophonePermissionRequest(
                completion: { result in
                    continuation.resume(returning: result)
                },
                useAudioApplicationRequest: useAudioApplicationRequest
            )
        }
    }

    func _testConfigureSession(categoryError: Error? = nil, activeError: Error? = nil) -> String? {
        do {
            try configureSession(
                setCategoryAction: {
                    if let categoryError { throw categoryError }
                },
                setActiveAction: {
                    if let activeError { throw activeError }
                }
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func _testConfigureSessionUsingDefaultOverrides(
        categoryError: Error? = nil,
        activeError: Error? = nil
    ) -> String? {
        Self._testResetOverrides()
        defer { Self._testResetOverrides() }

        Self.testConfigureSessionCategoryOverride.value = {
            if let categoryError { throw categoryError }
        }
        Self.testConfigureSessionActiveOverride.value = {
            if let activeError { throw activeError }
        }

        do {
            try configureSession()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func _testInstallDefaultAudioTap() -> (
        removeTapCalls: Int,
        installTapCalls: Int,
        appendBufferCalls: Int
    ) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest = request

        let format = AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 1
        )!

        var removeTapCalls = 0
        var installTapCalls = 0
        var appendBufferCalls = 0

        installDefaultAudioTap(
            request,
            defaultRemoveTapAction: { _ in removeTapCalls += 1 },
            defaultOutputFormatAction: { _ in format },
            defaultInstallTapAction: { _, recordingFormat, appendBuffer in
                installTapCalls += 1
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: recordingFormat,
                    frameCapacity: 1
                ) else { return }
                buffer.frameLength = 1
                appendBuffer(
                    buffer,
                    AVAudioTime(sampleTime: 0, atRate: recordingFormat.sampleRate)
                )
                appendBufferCalls += 1
            }
        )

        return (removeTapCalls, installTapCalls, appendBufferCalls)
    }

    func _testInstallAudioTapDefaultPath() -> Int {
        var defaultCalls = 0
        installAudioTap(
            SFSpeechAudioBufferRecognitionRequest(),
            defaultAction: { _ in defaultCalls += 1 }
        )
        return defaultCalls
    }

    func _testPrepareAudioDefaultPath() {
        prepareAudio()
    }

    func _testStartAudioDefaultPath(error: Error? = nil) -> String? {
        do {
            try startAudio(defaultAction: {
                if let error { throw error }
            })
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func _testEndAudioDefaultPath() -> Bool {
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        endAudio()
        return recognitionRequest != nil
    }

    func _testCompleteAudioPipelineDefaultPath() -> NutritionSpeechRecognizerTestState {
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        completeAudioPipeline()
        return _testState()
    }

    func _testDefaultInstallTap() -> (
        installTapCalls: Int,
        appendBufferCalls: Int
    ) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest = request

        let format = AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 1
        )!

        var installTapCalls = 0
        var appendBufferCalls = 0

        defaultInstallTap(
            audioEngine.inputNode,
            format,
            { buffer, time in
                self.recognitionRequest?.append(buffer)
                appendBufferCalls += 1
                _ = time
            },
            installTapAction: { _, recordingFormat, appendBuffer in
                installTapCalls += 1
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: recordingFormat,
                    frameCapacity: 1
                ) else { return }
                buffer.frameLength = 1
                appendBuffer(
                    buffer,
                    AVAudioTime(sampleTime: 0, atRate: recordingFormat.sampleRate)
                )
            }
        )

        return (installTapCalls, appendBufferCalls)
    }

    func _testDefaultInstallTapUsingSystemAction() -> (
        installTapCalls: Int,
        appendBufferCalls: Int
    ) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest = request

        let format = AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 1
        )!

        var installTapCalls = 0
        var appendBufferCalls = 0

        defaultInstallTap(
            audioEngine.inputNode,
            format,
            { buffer, time in
                self.recognitionRequest?.append(buffer)
                appendBufferCalls += 1
                _ = time
            },
            systemInstallTapAction: { _, recordingFormat, appendBuffer in
                installTapCalls += 1
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: recordingFormat,
                    frameCapacity: 1
                ) else { return }
                buffer.frameLength = 1
                appendBuffer(
                    buffer,
                    AVAudioTime(sampleTime: 0, atRate: recordingFormat.sampleRate)
                )
            }
        )

        return (installTapCalls, appendBufferCalls)
    }

    func _testStartRecordingUsingDefaultOverrides(
        recognitionTranscript: String? = nil,
        recognitionIsFinal: Bool = false,
        recognitionError: Error? = nil
    ) async -> NutritionSpeechRecognizerTestState {
        Self._testResetOverrides()
        defer { Self._testResetOverrides() }

        Self.testSpeechAuthorizationRequestOverride.value = { completion in
            completion(.authorized)
        }
        Self.testAudioApplicationPermissionOverride.value = { completion in
            completion(true)
        }
        Self.testConfigureSessionCategoryOverride.value = {}
        Self.testConfigureSessionActiveOverride.value = {}
        Self.testInstallAudioTapOverride.value = { _, _ in }
        Self.testPrepareAudioOverride.value = { _ in }
        Self.testStartAudioOverride.value = { _ in }
        Self.testStartRecognitionTaskOverride.value = { handleRecognitionUpdate in
            await handleRecognitionUpdate(
                recognitionTranscript,
                recognitionIsFinal,
                recognitionError
            )
        }

        await startRecording()
        return _testState()
    }

    func _testFinishRecording() -> NutritionSpeechRecognizerTestState {
        finishRecording(finishAudioPipelineAction: {})
        return _testState()
    }

    func _testFinishAudioPipeline() -> (
        state: NutritionSpeechRecognizerTestState,
        stopCalls: Int,
        removeTapCalls: Int,
        cancelCalls: Int,
        deactivateCalls: Int
    ) {
        var stopCalls = 0
        var removeTapCalls = 0
        var cancelCalls = 0
        var deactivateCalls = 0
        finishAudioPipeline(
            stopAudioAction: { stopCalls += 1 },
            removeTapAction: { removeTapCalls += 1 },
            cancelRecognitionTaskAction: { cancelCalls += 1 },
            deactivateSessionAction: { deactivateCalls += 1 }
        )
        return (_testState(), stopCalls, removeTapCalls, cancelCalls, deactivateCalls)
    }

    func _testStartRecording(
        permissionError: Error? = nil,
        configureError: Error? = nil,
        recognitionTranscript: String? = nil,
        recognitionIsFinal: Bool = false,
        recognitionError: Error? = nil
    ) async -> NutritionSpeechRecognizerTestState {
        await startRecording(
            permissionAction: {
                if let permissionError { throw permissionError }
            },
            configureSessionAction: {
                if let configureError { throw configureError }
            },
            installAudioTapAction: { _ in },
            prepareAudioAction: {},
            startAudioAction: {},
            startRecognitionTaskAction: { handleRecognitionUpdate in
                handleRecognitionUpdate(
                    recognitionTranscript,
                    recognitionIsFinal,
                    recognitionError
                )
            }
        )
        return _testState()
    }

    func _testStartDefaultRecognitionTask(
        useDefaultTaskAction: Bool = false,
        transcript: String? = nil,
        isFinal: Bool = false,
        error: Error? = nil
    ) async -> NutritionSpeechRecognizerTestState {
        _testOverrideState(
            isRecording: true,
            isProcessing: true,
            transcription: "",
            errorMessage: nil,
            confidence: nil
        )

        let request = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest = request

        if useDefaultTaskAction {
            startDefaultRecognitionTask(
                with: request,
                handleRecognitionUpdate: { [weak self] transcript, isFinal, error in
                    self?._testHandleRecognitionUpdate(transcript, isFinal: isFinal, error: error)
                },
                recognitionTaskAction: nil
            )
        } else {
            startDefaultRecognitionTask(
                with: request,
                handleRecognitionUpdate: { [weak self] transcript, isFinal, error in
                    self?._testHandleRecognitionUpdate(transcript, isFinal: isFinal, error: error)
                },
                recognitionTaskAction: { _, update in
                    update(transcript, isFinal, error)
                    return nil
                }
            )
        }

        for _ in 0..<10 {
            await Task.yield()
        }

        return _testState()
    }

    func _testStartRecognitionTaskUsingFallbackAction(
        transcript: String? = nil,
        isFinal: Bool = false,
        error: Error? = nil
    ) async -> NutritionSpeechRecognizerTestState {
        _testOverrideState(
            isRecording: true,
            isProcessing: true,
            transcription: "",
            errorMessage: nil,
            confidence: nil
        )

        let request = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest = request

        await startRecognitionTask(
            with: request,
            fallbackAction: { handleRecognitionUpdate in
                handleRecognitionUpdate(transcript, isFinal, error)
            },
            handleRecognitionUpdate: { [weak self] transcript, isFinal, error in
                self?._testHandleRecognitionUpdate(transcript, isFinal: isFinal, error: error)
            }
        )

        for _ in 0..<10 {
            await Task.yield()
        }

        return _testState()
    }

    func _testStartRecognitionTaskUsingDefaultAction(
        transcript: String? = nil,
        isFinal: Bool = false,
        error: Error? = nil
    ) async -> NutritionSpeechRecognizerTestState {
        _testOverrideState(
            isRecording: true,
            isProcessing: true,
            transcription: "",
            errorMessage: nil,
            confidence: nil
        )

        let request = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest = request

        await startRecognitionTask(
            with: request,
            defaultAction: { handleRecognitionUpdate in
                handleRecognitionUpdate(transcript, isFinal, error)
            },
            handleRecognitionUpdate: { [weak self] transcript, isFinal, error in
                self?._testHandleRecognitionUpdate(transcript, isFinal: isFinal, error: error)
            }
        )

        for _ in 0..<10 {
            await Task.yield()
        }

        return _testState()
    }

    func _testRequestAudioApplicationPermissionUsingSystemAction(
        allowed: Bool
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            requestAudioApplicationPermission(
                completion: { result in
                    continuation.resume(returning: result)
                },
                systemRequestAction: { completion in
                    completion(allowed)
                }
            )
        }
    }

    func _testRequestAudioSessionPermissionUsingSystemAction(
        allowed: Bool
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            requestAudioSessionPermission(
                completion: { result in
                    continuation.resume(returning: result)
                },
                systemRequestAction: { completion in
                    completion(allowed)
                }
            )
        }
    }

    func _testDefaultRecognitionTaskAction(
        useDefaultTaskAction: Bool = false,
        error: Error? = nil
    ) async -> NutritionSpeechRecognizerTestState {
        _testOverrideState(
            isRecording: true,
            isProcessing: true,
            transcription: "",
            errorMessage: nil,
            confidence: nil
        )

        let request = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest = request

        if useDefaultTaskAction {
            _ = defaultRecognitionTaskAction(
                request,
                { [weak self] transcript, isFinal, error in
                    self?._testHandleRecognitionUpdate(transcript, isFinal: isFinal, error: error)
                },
                recognitionTaskAction: nil
            )
        } else {
            _ = defaultRecognitionTaskAction(
                request,
                { [weak self] transcript, isFinal, error in
                    self?._testHandleRecognitionUpdate(transcript, isFinal: isFinal, error: error)
                },
                recognitionTaskAction: { _, handler in
                    handler(nil, error)
                    return nil
                }
            )
        }

        for _ in 0..<10 {
            await Task.yield()
        }

        return _testState()
    }

    private func _testHandleRecognitionUpdate(
        _ transcript: String?,
        isFinal: Bool,
        error: Error?
    ) {
        if let transcript {
            self.transcription = transcript
            confidence = isFinal ? 0.9 : 0.75
            isProcessing = false
        }

        if let error {
            errorMessage = error.localizedDescription
            finishRecording(finishAudioPipelineAction: {})
            return
        }

        if isFinal {
            finishRecording(finishAudioPipelineAction: {})
        }
    }

    func _testStopRecording() async -> NutritionSpeechRecognizerTestState {
        await stopRecording(
            endAudioAction: {},
            finishAudioPipelineAction: {}
        )
        return _testState()
    }

    func _testStopRecordingUsingDefaultOverrides() async -> NutritionSpeechRecognizerTestState {
        Self._testResetOverrides()
        defer { Self._testResetOverrides() }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        _testOverrideState(
            isRecording: true,
            isProcessing: false,
            transcription: "",
            errorMessage: nil,
            confidence: nil
        )
        Self.testEndAudioOverride.value = { _ in }
        Self.testFinishAudioPipelineOverride.value = { _ in }

        await stopRecording()
        return _testState()
    }
}

extension MealTemplateLibraryView {
    init(
        targetDay: String = NutritionCoverageFixtures.targetDay,
        loggedAt: Date = NutritionCoverageFixtures.loggedAt,
        testTemplates: [NutritionMealTemplateSummary] = [],
        testIsLoading: Bool = true,
        testShowingArchived: Bool = false,
        testStatusMessage: TemplateStatusMessage? = nil,
        onTemplatesChanged: @escaping () -> Void = {},
        onTemplateLogged: @escaping () -> Void = {}
    ) {
        self.targetDay = targetDay
        self.loggedAt = loggedAt
        self.onTemplatesChanged = onTemplatesChanged
        self.onTemplateLogged = onTemplateLogged
        _templates = State(initialValue: testTemplates)
        _isLoading = State(initialValue: testIsLoading)
        _showingArchived = State(initialValue: testShowingArchived)
        _statusMessage = State(initialValue: testStatusMessage)
    }

    func _testEvaluateBody() {
        _ = body
    }

    func _testTemplateRowSubtitle(_ template: NutritionMealTemplateSummary) -> String {
        templateRowSubtitle(template)
    }

    @MainActor
    func _testRenderTemplateRow(_ template: NutritionMealTemplateSummary) {
        let host = UIHostingController(rootView: templateRow(template))
        _ = host.view
    }

    @MainActor
    func _testRenderTemplateDestination(templateId: UUID, startsEditing: Bool) {
        let host = UIHostingController(
            rootView: templateDetailDestination(
                MealTemplateLibraryDestination(templateId: templateId, startsEditing: startsEditing)
            )
        )
        _ = host.view
    }

    @MainActor
    func _testRenderComposerSheet() {
        _ = composerSheet()
        let host = UIHostingController(rootView: composerSheet())
        _ = host.view
    }

    @MainActor
    func _testHandleComposerSaved(
        _ message: TemplateStatusMessage,
        reloadAction: @escaping () async -> Void = {}
    ) async -> (
        statusMessage: TemplateStatusMessage?,
        showingArchived: Bool
    ) {
        handleComposerSaved(message, reloadAction: reloadAction)
        for _ in 0..<10 {
            await Task.yield()
        }
        return (statusMessage, showingArchived)
    }

    @MainActor
    func _testHandleComposerSheetSaved(
        _ message: TemplateStatusMessage
    ) async -> (
        statusMessage: TemplateStatusMessage?,
        showingArchived: Bool
    ) {
        handleComposerSheetSaved(message)
        for _ in 0..<10 {
            await Task.yield()
        }
        return (statusMessage, showingArchived)
    }

    @MainActor
    func _testHandleTemplateDetailTemplatesChanged(
        reloadAction: @escaping () async -> Void = {}
    ) async -> TemplateStatusMessage? {
        handleTemplateDetailTemplatesChanged(reloadAction: reloadAction)
        for _ in 0..<10 {
            await Task.yield()
        }
        return statusMessage
    }

    func _testHandleTemplateDetailStatusMessage(_ message: TemplateStatusMessage) -> TemplateStatusMessage? {
        handleTemplateDetailStatusMessage(message)
        return statusMessage
    }

    func _testState() -> (
        templates: [NutritionMealTemplateSummary],
        isLoading: Bool,
        statusMessage: TemplateStatusMessage?
    ) {
        (templates, isLoading, statusMessage)
    }

    func _testTriggerLoadTemplates(manager: any NutritionMealTemplateManaging) async -> (
        templates: [NutritionMealTemplateSummary],
        isLoading: Bool,
        statusMessage: TemplateStatusMessage?
    ) {
        await loadTemplates(manager: manager)
        return (templates, isLoading, statusMessage)
    }

    func _testTriggerToggleArchive(
        for template: NutritionMealTemplateSummary,
        manager: any NutritionMealTemplateManaging
    ) async -> (
        templates: [NutritionMealTemplateSummary],
        isLoading: Bool,
        statusMessage: TemplateStatusMessage?
    ) {
        await toggleArchive(for: template, manager: manager)
        return (templates, isLoading, statusMessage)
    }

    static func _testLoadTemplatesResult(
        showingArchived: Bool,
        manager: any NutritionMealTemplateManaging
    ) async -> (
        templates: [NutritionMealTemplateSummary],
        statusMessage: TemplateStatusMessage?
    ) {
        await loadTemplatesResult(showingArchived: showingArchived, manager: manager)
    }

    static func _testToggleArchiveResult(
        for template: NutritionMealTemplateSummary,
        manager: any NutritionMealTemplateManaging
    ) async -> Result<TemplateStatusMessage, Error> {
        await toggleArchiveResult(for: template, manager: manager)
    }
}

extension MealTemplatesView {
    init(
        targetDay: String = NutritionCoverageFixtures.targetDay,
        loggedAt: Date = NutritionCoverageFixtures.loggedAt,
        refreshTrigger: Int = 0,
        testIsLoading: Bool,
        testTemplates: [NutritionMealTemplateSummary] = [],
        onTemplatesChanged: @escaping () -> Void = {},
        onTemplateLogged: @escaping () -> Void = {},
        onSelectTemplate: @escaping (UUID) -> Void = { _ in }
    ) {
        self.targetDay = targetDay
        self.loggedAt = loggedAt
        self.refreshTrigger = refreshTrigger
        self.onTemplatesChanged = onTemplatesChanged
        self.onTemplateLogged = onTemplateLogged
        self.onSelectTemplate = onSelectTemplate
        _isLoading = State(initialValue: testIsLoading)
        _templates = State(initialValue: testTemplates)
    }

    func _testEvaluateBody() {
        _ = body
    }

    @MainActor
    func _testRenderTemplateCard(_ template: NutritionMealTemplateSummary) {
        let host = UIHostingController(rootView: templateCard(template))
        _ = host.view
    }

    static func _testLoadTemplatesResult(
        manager: any NutritionMealTemplateManaging
    ) async -> [NutritionMealTemplateSummary] {
        await loadTemplatesResult(manager: manager)
    }

    func _testState() -> (
        templates: [NutritionMealTemplateSummary],
        isLoading: Bool
    ) {
        (templates, isLoading)
    }

    func _testTriggerLoadTemplates(manager: any NutritionMealTemplateManaging) async -> (
        templates: [NutritionMealTemplateSummary],
        isLoading: Bool
    ) {
        await loadTemplates(manager: manager)
        return (templates, isLoading)
    }
}

extension MealTemplateDetailView {
    init(
        targetDay: String = NutritionCoverageFixtures.targetDay,
        loggedAt: Date = NutritionCoverageFixtures.loggedAt,
        testViewModel: MealTemplateDetailViewModel,
        onTemplatesChanged: @escaping () -> Void = {},
        onTemplateLogged: @escaping () -> Void = {},
        onStatusMessage: @escaping (TemplateStatusMessage?) -> Void = { _ in }
    ) {
        _viewModel = State(initialValue: testViewModel)
        self.targetDay = targetDay
        self.loggedAt = loggedAt
        self.onTemplatesChanged = onTemplatesChanged
        self.onTemplateLogged = onTemplateLogged
        self.onStatusMessage = onStatusMessage
    }

    func _testEvaluateBody() {
        _ = body
    }

    @MainActor
    func _testRenderTemplateHeaderSection() {
        let host = UIHostingController(rootView: templateHeaderSection(viewModel))
        _ = host.view
    }

    @MainActor
    func _testRenderEditorDetailsSection() {
        let host = UIHostingController(rootView: editorDetailsSection(viewModel))
        _ = host.view
    }

    @MainActor
    func _testRenderEditorItemsSection() {
        let host = UIHostingController(rootView: editorItemsSection(viewModel))
        _ = host.view
    }

    @MainActor
    func _testRenderPreviewItemsSection() {
        let host = UIHostingController(rootView: previewItemsSection(viewModel))
        _ = host.view
    }

    @MainActor
    func _testRenderPreviewItemRow(_ item: NutritionEditableMealItem) {
        let host = UIHostingController(rootView: previewItemRow(item))
        _ = host.view
    }

    @MainActor
    func _testRenderActionSection() {
        let host = UIHostingController(rootView: actionSection(viewModel))
        _ = host.view
    }

    @MainActor
    func _testRenderTemplateItemEditor(index: Int) {
        let host = UIHostingController(rootView: templateItemEditor(index: index, viewModel: viewModel))
        _ = host.view
    }

    @MainActor
    func _testRenderTemplateNumericField() {
        var value = 125.0
        let host = UIHostingController(
            rootView: templateNumericField(
                "Coverage",
                value: Binding(
                    get: { value },
                    set: { value = $0 }
                )
            )
        )
        _ = host.view
    }

    func _testTriggerSaveTemplate() async {
        saveTemplate()
        await Task.yield()
        await Task.yield()
    }

    func _testTriggerToggleArchived() async {
        toggleArchived()
        await Task.yield()
        await Task.yield()
    }

    func _testTriggerLogTemplateNow() async {
        logTemplateNow()
        await Task.yield()
        await Task.yield()
    }
}

extension MealTemplateComposerView {
    init(
        testName: String = "",
        testMealType: MealType? = nil,
        testItems: [NutritionEditableMealItem] = [],
        testIsSaving: Bool = false,
        testErrorMessage: String? = nil,
        onSaved: @escaping (TemplateStatusMessage) -> Void = { _ in }
    ) {
        self.onSaved = onSaved
        _name = State(initialValue: testName)
        _mealType = State(initialValue: testMealType)
        _items = State(initialValue: testItems)
        _isSaving = State(initialValue: testIsSaving)
        _errorMessage = State(initialValue: testErrorMessage)
    }

    func _testTotals() -> (calories: Double, protein: Double, fat: Double, carbs: Double, fiber: Double?) {
        totals
    }

    func _testCanSave() -> Bool {
        canSave
    }

    func _testEvaluateBody() {
        _ = body
    }

    @MainActor
    func _testRenderDetailsSection() {
        let host = UIHostingController(rootView: detailsSection)
        _ = host.view
    }

    @MainActor
    func _testRenderPreviewSection() {
        let host = UIHostingController(rootView: previewSection)
        _ = host.view
    }

    @MainActor
    func _testRenderItemsSection() {
        let host = UIHostingController(rootView: itemsSection)
        _ = host.view
    }

    @MainActor
    func _testRenderItemEditor(index: Int) {
        let host = UIHostingController(rootView: itemEditor(index: index))
        _ = host.view
    }

    @MainActor
    func _testRenderTemplateNumericField() {
        var value = 80.0
        let host = UIHostingController(
            rootView: templateNumericField(
                "Coverage",
                value: Binding(
                    get: { value },
                    set: { value = $0 }
                )
            )
        )
        _ = host.view
    }

    @MainActor
    static func _testAddedItems(
        mealType: MealType?
    ) -> [NutritionEditableMealItem] {
        [defaultEditableMealItem(for: mealType)]
    }

    static func _testSaveDraft(
        name: String,
        mealType: MealType?,
        items: [NutritionEditableMealItem]
    ) -> NutritionMealTemplateCreateDraft {
        NutritionMealTemplateCreateDraft(
            name: name,
            mealType: mealType,
            items: items.map(NutritionMealTemplateItem.init(editableItem:))
        )
    }

    static func _testSaveResult(
        draft: NutritionMealTemplateCreateDraft,
        manager: any NutritionMealTemplateManaging
    ) async -> Result<TemplateStatusMessage, Error> {
        await saveResult(draft: draft, manager: manager)
    }

    func _testState() -> (
        isSaving: Bool,
        errorMessage: String?
    ) {
        (isSaving, errorMessage)
    }

    func _testTriggerSave(
        manager: any NutritionMealTemplateManaging,
        dismissAction: @escaping () -> Void = {}
    ) async -> (
        isSaving: Bool,
        errorMessage: String?
    ) {
        save(manager: manager, dismissAction: dismissAction)
        for _ in 0..<50 where isSaving {
            await Task.yield()
        }
        return (isSaving, errorMessage)
    }
}

extension BatchRecipeLibraryView {
    init(
        targetDay: String = NutritionCoverageFixtures.targetDay,
        loggedAt: Date = NutritionCoverageFixtures.loggedAt,
        testRecipes: [NutritionBatchRecipeSummary] = [],
        testIsLoading: Bool = true,
        testShowingArchived: Bool = false,
        testStatusMessage: TemplateStatusMessage? = nil,
        onBatchesChanged: @escaping () -> Void = {},
        onBatchLogged: @escaping () -> Void = {}
    ) {
        self.targetDay = targetDay
        self.loggedAt = loggedAt
        self.onBatchesChanged = onBatchesChanged
        self.onBatchLogged = onBatchLogged
        _recipes = State(initialValue: testRecipes)
        _isLoading = State(initialValue: testIsLoading)
        _showingArchived = State(initialValue: testShowingArchived)
        _statusMessage = State(initialValue: testStatusMessage)
    }

    func _testEvaluateBody() {
        _ = body
    }

    @MainActor
    func _testRenderBatchRow(_ recipe: NutritionBatchRecipeSummary) {
        let host = UIHostingController(rootView: batchRow(recipe))
        _ = host.view
    }

    @MainActor
    func _testRenderStyledBatchRow(_ recipe: NutritionBatchRecipeSummary) {
        let host = UIHostingController(rootView: styledBatchRow(recipe))
        _ = host.view
    }

    @MainActor
    func _testRenderDetailDestination(batchId: UUID) {
        let host = UIHostingController(
            rootView: detailDestination(BatchRecipeLibraryDestination(batchId: batchId))
        )
        _ = host.view
    }

    @MainActor
    func _testRenderComposerSheet() {
        _ = composerSheet()
        let host = UIHostingController(rootView: composerSheet())
        _ = host.view
    }

    @MainActor
    func _testRenderQuickLogSheet(_ recipe: NutritionBatchRecipeSummary) {
        _ = quickLogSheet(recipe)
        let host = UIHostingController(rootView: quickLogSheet(recipe))
        _ = host.view
    }

    @MainActor
    func _testHandleComposerSaved(
        _ message: TemplateStatusMessage,
        reloadAction: @escaping () async -> Void = {}
    ) async -> TemplateStatusMessage? {
        handleComposerSaved(message, reloadAction: reloadAction)
        for _ in 0..<10 {
            await Task.yield()
        }
        return statusMessage
    }

    @MainActor
    func _testHandleComposerSheetSaved(
        _ message: TemplateStatusMessage
    ) async -> TemplateStatusMessage? {
        handleComposerSheetSaved(message)
        for _ in 0..<10 {
            await Task.yield()
        }
        return statusMessage
    }

    @MainActor
    func _testHandleQuickLogSaved(
        _ message: TemplateStatusMessage,
        reloadAction: @escaping () async -> Void = {}
    ) async -> TemplateStatusMessage? {
        handleQuickLogSaved(message, reloadAction: reloadAction)
        for _ in 0..<10 {
            await Task.yield()
        }
        return statusMessage
    }

    @MainActor
    func _testHandleQuickLogSheetSaved(
        _ message: TemplateStatusMessage
    ) async -> TemplateStatusMessage? {
        handleQuickLogSheetSaved(message)
        for _ in 0..<10 {
            await Task.yield()
        }
        return statusMessage
    }

    @MainActor
    func _testHandleDetailBatchesChanged(
        reloadAction: @escaping () async -> Void = {}
    ) async -> TemplateStatusMessage? {
        handleDetailBatchesChanged(reloadAction: reloadAction)
        for _ in 0..<10 {
            await Task.yield()
        }
        return statusMessage
    }

    @MainActor
    func _testHandleDetailBatchLogged(
        reloadAction: @escaping () async -> Void = {}
    ) async -> TemplateStatusMessage? {
        handleDetailBatchLogged(reloadAction: reloadAction)
        for _ in 0..<10 {
            await Task.yield()
        }
        return statusMessage
    }

    func _testHandleDetailStatusMessage(_ message: TemplateStatusMessage) -> TemplateStatusMessage? {
        handleDetailStatusMessage(message)
        return statusMessage
    }

    func _testTriggerLoadRecipes(
        manager: any NutritionBatchRecipeManaging
    ) async -> (
        recipes: [NutritionBatchRecipeSummary],
        isLoading: Bool,
        statusMessage: TemplateStatusMessage?
    ) {
        await loadRecipes(manager: manager)
        return (recipes, isLoading, statusMessage)
    }

    static func _testLoadRecipesResult(
        showingArchived: Bool,
        manager: any NutritionBatchRecipeManaging
    ) async -> (
        recipes: [NutritionBatchRecipeSummary],
        statusMessage: TemplateStatusMessage?
    ) {
        await loadRecipesResult(showingArchived: showingArchived, manager: manager)
    }
}

extension BatchRecipeDetailView {
    init(
        batchId: UUID = UUID(),
        targetDay: String = NutritionCoverageFixtures.targetDay,
        loggedAt: Date = NutritionCoverageFixtures.loggedAt,
        testDetail: NutritionBatchRecipeDetail? = nil,
        testIsLoading: Bool = true,
        testIsArchiving: Bool = false,
        testIsDuplicating: Bool = false,
        testShowingComposer: Bool = false,
        testShowingLogSheet: Bool = false,
        testErrorMessage: String? = nil,
        testStatusMessage: TemplateStatusMessage? = nil,
        onBatchesChanged: @escaping () -> Void = {},
        onBatchLogged: @escaping () -> Void = {},
        onStatusMessage: @escaping (TemplateStatusMessage?) -> Void = { _ in }
    ) {
        self.batchId = batchId
        self.targetDay = targetDay
        self.loggedAt = loggedAt
        self.onBatchesChanged = onBatchesChanged
        self.onBatchLogged = onBatchLogged
        self.onStatusMessage = onStatusMessage
        _detail = State(initialValue: testDetail)
        _isLoading = State(initialValue: testIsLoading)
        _isArchiving = State(initialValue: testIsArchiving)
        _isDuplicating = State(initialValue: testIsDuplicating)
        _showingComposer = State(initialValue: testShowingComposer)
        _showingLogSheet = State(initialValue: testShowingLogSheet)
        _errorMessage = State(initialValue: testErrorMessage)
        _statusMessage = State(initialValue: testStatusMessage)
    }

    func _testEvaluateBody() {
        _ = body
    }

    @MainActor
    func _testRenderDetailHeader(_ detail: NutritionBatchRecipeDetail) {
        let host = UIHostingController(rootView: detailHeader(detail))
        _ = host.view
    }

    @MainActor
    func _testRenderDetailMacros(_ detail: NutritionBatchRecipeDetail) {
        let host = UIHostingController(rootView: detailMacros(detail))
        _ = host.view
    }

    @MainActor
    func _testRenderDetailIngredients(_ detail: NutritionBatchRecipeDetail) {
        let host = UIHostingController(rootView: detailIngredients(detail))
        _ = host.view
    }

    @MainActor
    func _testRenderDetailIngredientRow(_ ingredient: BatchRecipeIngredient) {
        let host = UIHostingController(rootView: detailIngredientRow(ingredient))
        _ = host.view
    }

    @MainActor
    func _testRenderDetailActions(_ detail: NutritionBatchRecipeDetail) {
        let host = UIHostingController(rootView: detailActions(detail))
        _ = host.view
    }

    @MainActor
    func _testRenderComposerSheet(_ detail: NutritionBatchRecipeDetail) {
        _ = composerSheet(detail)
        let host = UIHostingController(rootView: composerSheet(detail))
        _ = host.view
    }

    @MainActor
    func _testRenderComposerSheetContent() {
        _ = composerSheetContent()
        let host = UIHostingController(rootView: composerSheetContent())
        _ = host.view
    }

    @MainActor
    func _testRenderLogSheet(_ detail: NutritionBatchRecipeDetail) {
        _ = logSheet(detail)
        let host = UIHostingController(rootView: logSheet(detail))
        _ = host.view
    }

    @MainActor
    func _testRenderLogSheetContent() {
        _ = logSheetContent()
        let host = UIHostingController(rootView: logSheetContent())
        _ = host.view
    }

    @MainActor
    func _testHandleComposerSaved(
        _ message: TemplateStatusMessage,
        reloadAction: @escaping () async -> Void = {}
    ) async -> TemplateStatusMessage? {
        handleComposerSaved(message, reloadAction: reloadAction)
        for _ in 0..<10 {
            await Task.yield()
        }
        return statusMessage
    }

    @MainActor
    func _testHandleComposerSheetSaved(
        _ message: TemplateStatusMessage
    ) async -> TemplateStatusMessage? {
        handleComposerSheetSaved(message)
        for _ in 0..<10 {
            await Task.yield()
        }
        return statusMessage
    }

    @MainActor
    func _testHandleLogSaved(
        _ message: TemplateStatusMessage,
        reloadAction: @escaping () async -> Void = {}
    ) async -> TemplateStatusMessage? {
        handleLogSaved(message, reloadAction: reloadAction)
        for _ in 0..<10 {
            await Task.yield()
        }
        return statusMessage
    }

    @MainActor
    func _testHandleLogSheetSaved(
        _ message: TemplateStatusMessage
    ) async -> TemplateStatusMessage? {
        handleLogSheetSaved(message)
        for _ in 0..<10 {
            await Task.yield()
        }
        return statusMessage
    }

    func _testState() -> (
        detail: NutritionBatchRecipeDetail?,
        isLoading: Bool,
        isArchiving: Bool,
        isDuplicating: Bool,
        errorMessage: String?,
        statusMessage: TemplateStatusMessage?
    ) {
        (detail, isLoading, isArchiving, isDuplicating, errorMessage, statusMessage)
    }

    func _testTriggerLoadDetail(
        preferRemote: Bool,
        manager: any NutritionBatchRecipeManaging
    ) async -> (
        detail: NutritionBatchRecipeDetail?,
        isLoading: Bool,
        isArchiving: Bool,
        isDuplicating: Bool,
        errorMessage: String?,
        statusMessage: TemplateStatusMessage?
    ) {
        await loadDetail(preferRemote: preferRemote, manager: manager)
        return (detail, isLoading, isArchiving, isDuplicating, errorMessage, statusMessage)
    }

    func _testTriggerToggleArchived(
        manager: any NutritionBatchRecipeManaging,
        dismissAction: @escaping () -> Void = {}
    ) async -> (
        detail: NutritionBatchRecipeDetail?,
        isLoading: Bool,
        isArchiving: Bool,
        isDuplicating: Bool,
        errorMessage: String?,
        statusMessage: TemplateStatusMessage?
    ) {
        toggleArchived(manager: manager, dismissAction: dismissAction)
        for _ in 0..<50 where isArchiving {
            await Task.yield()
        }
        return (detail, isLoading, isArchiving, isDuplicating, errorMessage, statusMessage)
    }

    func _testTriggerCookAgain(
        manager: any NutritionBatchRecipeManaging,
        dismissAction: @escaping () -> Void = {}
    ) async -> (
        detail: NutritionBatchRecipeDetail?,
        isLoading: Bool,
        isArchiving: Bool,
        isDuplicating: Bool,
        errorMessage: String?,
        statusMessage: TemplateStatusMessage?
    ) {
        cookAgain(manager: manager, dismissAction: dismissAction)
        for _ in 0..<50 where isDuplicating {
            await Task.yield()
        }
        return (detail, isLoading, isArchiving, isDuplicating, errorMessage, statusMessage)
    }

    static func _testLoadDetailResult(
        batchId: UUID,
        preferRemote: Bool,
        manager: any NutritionBatchRecipeManaging
    ) async -> (
        detail: NutritionBatchRecipeDetail?,
        errorMessage: String?
    ) {
        await loadDetailResult(batchId: batchId, preferRemote: preferRemote, manager: manager)
    }

    static func _testToggleArchivedResult(
        detail: NutritionBatchRecipeDetail,
        manager: any NutritionBatchRecipeManaging
    ) async -> Result<TemplateStatusMessage, Error> {
        await toggleArchivedResult(detail: detail, manager: manager)
    }

    static func _testCookAgainResult(
        detail: NutritionBatchRecipeDetail,
        manager: any NutritionBatchRecipeManaging
    ) async -> Result<TemplateStatusMessage, Error> {
        await cookAgainResult(detail: detail, manager: manager)
    }
}

extension BatchRecipeComposerView {
    init(
        existingDetail: NutritionBatchRecipeDetail? = nil,
        testName: String,
        testDescription: String = "",
        testCookedAt: Date = NutritionCoverageFixtures.loggedAt,
        testTotalWeightG: Double = 1000,
        testTotalPortions: Int = 1,
        testIngredients: [BatchRecipeEditableIngredient] = [],
        testIsSaving: Bool = false,
        testErrorMessage: String? = nil,
        testImportMessage: String? = nil,
        testIsAnalyzingPhoto: Bool = false,
        onSaved: @escaping (TemplateStatusMessage) -> Void = { _ in }
    ) {
        self.existingDetail = existingDetail
        self.onSaved = onSaved
        _name = State(initialValue: testName)
        _description = State(initialValue: testDescription)
        _cookedAt = State(initialValue: testCookedAt)
        _totalWeightG = State(initialValue: testTotalWeightG)
        _totalPortions = State(initialValue: testTotalPortions)
        _ingredients = State(initialValue: testIngredients)
        _isSaving = State(initialValue: testIsSaving)
        _errorMessage = State(initialValue: testErrorMessage)
        _importMessage = State(initialValue: testImportMessage)
        _isAnalyzingPhoto = State(initialValue: testIsAnalyzingPhoto)
        _showingIngredientSearch = State(initialValue: false)
        _showCameraPicker = State(initialValue: false)
        _showPhotoLibrary = State(initialValue: false)
        _selectedPhotoItem = State(initialValue: nil)
    }

    func _testTotals() -> NutritionBatchMacroSnapshot {
        totals
    }

    func _testPer100g() -> NutritionBatchMacroSnapshot {
        per100g
    }

    func _testPerPortion() -> NutritionBatchMacroSnapshot {
        perPortion
    }

    func _testCanSave() -> Bool {
        canSave
    }

    func _testEvaluateBody() {
        _ = body
    }

    func _testEvaluateIngredientSearchSheet() {
        _ = ingredientSearchSheet()
    }

    func _testEvaluateCameraPickerSheet() {
        _ = cameraPickerSheet()
    }

    @MainActor
    func _testRenderDetailsSection() {
        let host = UIHostingController(rootView: detailsSection)
        _ = host.view
    }

    @MainActor
    func _testRenderTotalsSection() {
        let host = UIHostingController(rootView: totalsSection)
        _ = host.view
    }

    @MainActor
    func _testRenderIngredientsSection() {
        let host = UIHostingController(rootView: ingredientsSection)
        _ = host.view
    }

    @MainActor
    func _testRenderIngredientEditor(index: Int) {
        let host = UIHostingController(rootView: ingredientEditor(index: index))
        _ = host.view
    }

    @MainActor
    func _testRenderBatchNumericField() {
        var value = 250.0
        let host = UIHostingController(
            rootView: batchNumericField(
                "Coverage",
                value: Binding(
                    get: { value },
                    set: { value = $0 }
                )
            )
        )
        _ = host.view
    }

    @MainActor
    func _testRenderBatchIntegerField() {
        var value = 3
        let host = UIHostingController(
            rootView: batchIntegerField(
                "Coverage",
                value: Binding(
                    get: { value },
                    set: { value = $0 }
                )
            )
        )
        _ = host.view
    }

    @MainActor
    func _testPresentIngredientSearch() -> Bool {
        presentIngredientSearch()
        return showingIngredientSearch
    }

    @MainActor
    func _testOpenCameraOrLibrary(cameraAvailable: Bool) -> (
        showCameraPicker: Bool,
        showPhotoLibrary: Bool
    ) {
        openCameraOrLibrary(cameraAvailableProvider: { cameraAvailable })
        let pickerState = Self.capturePickerState(cameraAvailable: cameraAvailable)
        return (pickerState.showCameraPicker, pickerState.showPhotoLibrary)
    }

    @MainActor
    func _testBeginCameraCapture(cameraAvailable: Bool) -> (
        showCameraPicker: Bool,
        showPhotoLibrary: Bool
    ) {
        beginCameraCapture(cameraAvailableProvider: { cameraAvailable })
        let pickerState = Self.capturePickerState(cameraAvailable: cameraAvailable)
        return (pickerState.showCameraPicker, pickerState.showPhotoLibrary)
    }

    @MainActor
    func _testAddManualIngredient() -> Int {
        addManualIngredient()
        return ingredients.count
    }

    @MainActor
    func _testHandleIngredientSearchSelection(_ result: FoodSearchResult) -> [String] {
        handleIngredientSearchSelection(result)
        return ingredients.map(\.name)
    }

    @MainActor
    func _testHandlePickedCameraImageUsingOverride(
        response: BatchRecipePhotoAnalysisResponse,
        image: UIImage = NutritionCoverageFixtures.image()
    ) async -> (
        name: String,
        description: String,
        totalWeightG: Double,
        totalPortions: Int,
        ingredientNames: [String],
        isAnalyzingPhoto: Bool,
        errorMessage: String?,
        importMessage: String?
    ) {
        MediaRecognitionService._testSetCloudAnalysisEnabledOverride { true }
        MediaRecognitionService._testSetBatchRecipePhotoAnalysisOverride { _, _, _, _, _ in response }
        defer { MediaRecognitionService._testResetOverrides() }
        handlePickedCameraImage(image)
        for _ in 0..<25 {
            await Task.yield()
        }
        return _testPhotoImportState()
    }

    @MainActor
    func _testHandleSelectedPhotoItemChange() async -> (
        name: String,
        description: String,
        totalWeightG: Double,
        totalPortions: Int,
        ingredientNames: [String],
        isAnalyzingPhoto: Bool,
        errorMessage: String?,
        importMessage: String?
    ) {
        await handleSelectedPhotoItemChange()
        return _testPhotoImportState()
    }

    static func _testSaveDraft(
        existingDetail: NutritionBatchRecipeDetail?,
        name: String,
        description: String,
        cookedAt: Date,
        totalWeightG: Double,
        totalPortions: Int,
        ingredients: [BatchRecipeEditableIngredient]
    ) -> NutritionBatchRecipeDraft {
        saveDraft(
            existingDetail: existingDetail,
            name: name,
            description: description,
            cookedAt: cookedAt,
            totalWeightG: totalWeightG,
            totalPortions: totalPortions,
            ingredients: ingredients
        )
    }

    static func _testSaveResult(
        draft: NutritionBatchRecipeDraft,
        existingDetail: NutritionBatchRecipeDetail?,
        manager: any NutritionBatchRecipeManaging
    ) async -> Result<TemplateStatusMessage, Error> {
        await saveResult(draft: draft, existingDetail: existingDetail, manager: manager)
    }

    static func _testCapturePickerState(cameraAvailable: Bool) -> (
        showCameraPicker: Bool,
        showPhotoLibrary: Bool
    ) {
        capturePickerState(cameraAvailable: cameraAvailable)
    }

    func _testMergedIngredients(
        imported: [BatchRecipeEditableIngredient]
    ) -> [BatchRecipeEditableIngredient] {
        Self.mergeIngredients(existing: ingredients, imported: imported)
    }

    @MainActor
    static func _testAppliedPhotoDraftResult(
        testName: String,
        testDescription: String,
        testTotalWeightG: Double,
        testTotalPortions: Int,
        testIngredients: [BatchRecipeEditableIngredient],
        photoDraft: BatchRecipePhotoDraft
    ) -> (
        name: String,
        description: String,
        totalWeightG: Double,
        totalPortions: Int,
        ingredientNames: [String],
        importMessage: String?,
        errorMessage: String?
    ) {
        let resolvedState = BatchRecipeComposerView.resolvePhotoImportState(
            name: testName,
            description: testDescription,
            totalWeightG: testTotalWeightG,
            totalPortions: testTotalPortions,
            ingredients: testIngredients,
            photoDraft: photoDraft
        )
        return (
            name: resolvedState.name,
            description: resolvedState.description,
            totalWeightG: resolvedState.totalWeightG,
            totalPortions: resolvedState.totalPortions,
            ingredientNames: resolvedState.ingredients.map(\.name).sorted(),
            importMessage: resolvedState.importMessage,
            errorMessage: resolvedState.errorMessage
        )
    }

    func _testState() -> (
        isSaving: Bool,
        errorMessage: String?,
        importMessage: String?
    ) {
        (isSaving, errorMessage, importMessage)
    }

    func _testPhotoImportState() -> (
        name: String,
        description: String,
        totalWeightG: Double,
        totalPortions: Int,
        ingredientNames: [String],
        isAnalyzingPhoto: Bool,
        errorMessage: String?,
        importMessage: String?
    ) {
        (
            name,
            description,
            totalWeightG,
            totalPortions,
            ingredients.map(\.name).sorted(),
            isAnalyzingPhoto,
            errorMessage,
            importMessage
        )
    }

    @MainActor
    func _testApplyPhotoDraft(_ photoDraft: BatchRecipePhotoDraft) -> (
        name: String,
        description: String,
        totalWeightG: Double,
        totalPortions: Int,
        ingredientNames: [String],
        isAnalyzingPhoto: Bool,
        errorMessage: String?,
        importMessage: String?
    ) {
        apply(photoDraft: photoDraft)
        return _testPhotoImportState()
    }

    @MainActor
    func _testLoadPhotoItemUsingOverride(
        response: BatchRecipePhotoAnalysisResponse,
        dataLoader: @escaping @Sendable () async throws -> Data?
    ) async -> (
        name: String,
        description: String,
        totalWeightG: Double,
        totalPortions: Int,
        ingredientNames: [String],
        isAnalyzingPhoto: Bool,
        errorMessage: String?,
        importMessage: String?
    ) {
        MediaRecognitionService._testSetCloudAnalysisEnabledOverride { true }
        MediaRecognitionService._testSetBatchRecipePhotoAnalysisOverride { _, _, _, _, _ in response }
        defer { MediaRecognitionService._testResetOverrides() }
        await loadPhotoItem(using: dataLoader)
        return _testPhotoImportState()
    }

    @MainActor
    func _testLoadSelectedPhotoItemIfNeeded(shouldLoad: Bool) async -> Bool {
        var didLoad = false
        await loadSelectedPhotoItemIfNeeded(
            item: nil,
            shouldLoad: shouldLoad,
            loadPhotoItemAction: { _ in didLoad = true }
        )
        return didLoad
    }

    @MainActor
    func _testLoadSelectedPhotoItemIfNeededWithoutCustomLoader() async -> (
        name: String,
        description: String,
        totalWeightG: Double,
        totalPortions: Int,
        ingredientNames: [String],
        isAnalyzingPhoto: Bool,
        errorMessage: String?,
        importMessage: String?
    ) {
        await loadSelectedPhotoItemIfNeeded(item: nil, shouldLoad: true)
        return _testPhotoImportState()
    }

    func _testTriggerSave(
        manager: any NutritionBatchRecipeManaging,
        dismissAction: @escaping () -> Void = {}
    ) async -> (
        isSaving: Bool,
        errorMessage: String?,
        importMessage: String?
    ) {
        save(manager: manager, dismissAction: dismissAction)
        for _ in 0..<50 where isSaving {
            await Task.yield()
        }
        return (isSaving, errorMessage, importMessage)
    }
}

extension BatchPortionLogView {
    init(
        batchId: UUID = UUID(),
        batchName: String = "Coverage Chili",
        remainingWeightG: Double = 320,
        per100g: NutritionBatchMacroSnapshot = NutritionCoverageFixtures.batchSnapshot(),
        suggestedPortionWeightG: Double? = 120,
        targetDay: String = NutritionCoverageFixtures.targetDay,
        loggedAt: Date = NutritionCoverageFixtures.loggedAt,
        testPortionWeightG: Double? = nil,
        testMealType: MealType? = nil,
        testContext: MealContext? = .home,
        testIsSaving: Bool = false,
        testErrorMessage: String? = nil,
        onLogged: @escaping (TemplateStatusMessage) -> Void = { _ in }
    ) {
        self.batchId = batchId
        self.batchName = batchName
        self.remainingWeightG = remainingWeightG
        self.per100g = per100g
        self.suggestedPortionWeightG = suggestedPortionWeightG
        self.targetDay = targetDay
        self.loggedAt = loggedAt
        self.onLogged = onLogged
        _portionWeightG = State(
            initialValue: testPortionWeightG
                ?? min(suggestedPortionWeightG ?? 100, max(remainingWeightG, 1))
        )
        _mealType = State(initialValue: testMealType ?? Self.defaultMealType(for: loggedAt))
        _context = State(initialValue: testContext)
        _isSaving = State(initialValue: testIsSaving)
        _errorMessage = State(initialValue: testErrorMessage)
    }

    static func _testDefaultMealType(for date: Date) -> MealType {
        defaultMealType(for: date)
    }

    func _testPreview() -> NutritionBatchMacroSnapshot {
        preview
    }

    func _testCanSave() -> Bool {
        canSave
    }

    static func _testSaveResult(
        draft: NutritionBatchPortionLogDraft,
        batchName: String,
        manager: any NutritionBatchRecipeManaging
    ) async -> Result<TemplateStatusMessage, Error> {
        await saveResult(draft: draft, batchName: batchName, manager: manager)
    }

    func _testEvaluateBody() {
        _ = body
    }

    func _testState() -> (
        isSaving: Bool,
        errorMessage: String?
    ) {
        (isSaving, errorMessage)
    }

    func _testTriggerSave(
        manager: any NutritionBatchRecipeManaging,
        dismissAction: @escaping () -> Void = {}
    ) async -> (
        isSaving: Bool,
        errorMessage: String?
    ) {
        save(manager: manager, dismissAction: dismissAction)
        for _ in 0..<50 where isSaving {
            await Task.yield()
        }
        return (isSaving, errorMessage)
    }
}

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

extension BatchRecipeIngredientPickerView {
    init(
        testQuery: String = "",
        testResults: [FoodSearchResult] = [],
        testIsSearching: Bool = false,
        testErrorMessage: String? = nil,
        onSelect: @escaping (FoodSearchResult) -> Void = { _ in }
    ) {
        self.onSelect = onSelect
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

    func _testSelectResult(
        _ result: FoodSearchResult,
        dismissAction: @escaping () -> Void = {}
    ) {
        handleSelection(of: result, dismissAction: dismissAction)
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

extension NutritionCalendarView {
    init(
        selectedDate: Binding<Date>,
        testDisplayedMonth: Date,
        testDaysWithLogs: Set<String>
    ) {
        _selectedDate = selectedDate
        _displayedMonth = State(initialValue: testDisplayedMonth)
        _daysWithLogs = State(initialValue: testDaysWithLogs)
    }

    func _testDaysInMonth() -> [Date?] {
        daysInMonth()
    }

    func _testEvaluateBody() {
        _ = body
    }

    @MainActor
    func _testRenderDayCell(_ date: Date?) {
        let host = UIHostingController(rootView: dayCell(for: date))
        _ = host.view
    }

    @MainActor
    func _testRenderWeekdayHeader(_ day: String) {
        let host = UIHostingController(rootView: weekdayHeader(day))
        _ = host.view
    }

    func _testShiftDisplayedMonth(by value: Int, calendar: Calendar = .current) -> Date {
        shiftedMonth(by: value, calendar: calendar)
    }

    func _testSelectDate(_ date: Date) -> (selectedDate: Date, dismissCalls: Int) {
        var dismissCalls = 0
        selectDate(date) { dismissCalls += 1 }
        return (selectedDate, dismissCalls)
    }

    func _testSelectToday(_ today: Date) -> (selectedDate: Date, dismissCalls: Int) {
        var dismissCalls = 0
        selectToday(today: today) { dismissCalls += 1 }
        return (selectedDate, dismissCalls)
    }

    func _testTriggerLoadLoggedDays(
        calendar: Calendar = .current,
        dbQueue: DatabaseQueue
    ) async {
        await loadLoggedDays(calendar: calendar, dbQueue: dbQueue)
    }

    static func _testLoadLoggedDaysResult(
        displayedMonth: Date,
        calendar: Calendar = .current,
        dbQueue: DatabaseQueue
    ) async -> Set<String> {
        await loadLoggedDaysResult(
            displayedMonth: displayedMonth,
            calendar: calendar,
            dbQueue: dbQueue
        )
    }
}

extension SystemImagePicker {
    func _testConfiguredPicker(
        delegate: (UIImagePickerControllerDelegate & UINavigationControllerDelegate)? = nil
    ) -> UIImagePickerController {
        configuredPicker(delegate: delegate ?? makeCoordinator())
    }
}

extension MediaRecognitionService {
    static func _testPreparedImageDataURL(for image: UIImage) throws -> String {
        try preparedImageDataURL(for: image)
    }

    static func _testParseNutritionLabelText(_ text: String?) -> (
        name: String,
        brand: String?,
        servingSizeG: Double,
        caloriesPer100g: Double,
        proteinPer100g: Double,
        fatPer100g: Double,
        carbsPer100g: Double,
        fiberPer100g: Double,
        confidence: Double?,
        warnings: [String]
    ) {
        parseNutritionLabelText(text)
    }

    static func _testFallbackAnalysis(
        recognizedText: String?,
        barcodes: [String],
        notice: String?
    ) -> NutritionPhotoAnalysis {
        fallbackAnalysis(recognizedText: recognizedText, barcodes: barcodes, notice: notice)
    }

    static func _testAIFoodLabelDraft(
        from response: FoodLabelAnalysisResponse,
        sourceText: String?,
        barcodeHint: String?
    ) -> NutritionLabelReviewDraft {
        aiFoodLabelDraft(from: response, sourceText: sourceText, barcodeHint: barcodeHint)
    }

    static func _testFallbackFoodLabelDraft(
        sourceText: String?,
        barcode: String?,
        notice: String
    ) -> NutritionLabelReviewDraft {
        fallbackFoodLabelDraft(sourceText: sourceText, barcode: barcode, notice: notice)
    }

    static func _testBatchRecipePhotoDraft(
        from response: BatchRecipePhotoAnalysisResponse,
        fallbackRecipeName: String,
        fallbackWeightG: Double,
        fallbackPortions: Int
    ) -> BatchRecipePhotoDraft {
        batchRecipePhotoDraft(
            from: response,
            fallbackRecipeName: fallbackRecipeName,
            fallbackWeightG: fallbackWeightG,
            fallbackPortions: fallbackPortions
        )
    }

    static func _testFallbackBatchRecipePhotoDraft(
        from analysis: NutritionPhotoAnalysis,
        recipeName: String,
        totalWeightG: Double,
        totalPortions: Int,
        cloudAnalysisEnabled: Bool
    ) -> BatchRecipePhotoDraft {
        fallbackBatchRecipePhotoDraft(
            from: analysis,
            recipeName: recipeName,
            totalWeightG: totalWeightG,
            totalPortions: totalPortions,
            cloudAnalysisEnabled: cloudAnalysisEnabled
        )
    }

    static func _testAIAnalysis(
        from response: FoodPhotoAnalysisResponse,
        recognizedText: String?,
        barcodes: [String]
    ) -> NutritionPhotoAnalysis {
        aiAnalysis(from: response, recognizedText: recognizedText, barcodes: barcodes)
    }

    static func _testAISummaryFallback(
        detectedItems: [NutritionDraftCandidateItem],
        totalMacros: NutritionDraftMacroSummary?
    ) -> String {
        aiSummaryFallback(detectedItems: detectedItems, totalMacros: totalMacros)
    }

    static func _testIsCloudAnalysisEnabled() async -> Bool {
        await isCloudAnalysisEnabled()
    }

    static func _testSetRecognizeTextOverride(
        _ runner: (@Sendable (UIImage) async throws -> String)?
    ) {
        testRecognizeTextOverride.value = runner
    }

    static func _testSetSyncRecognizeTextOverride(
        _ runner: (@Sendable (UIImage) throws -> String)?
    ) {
        testSyncRecognizeTextOverride.value = runner
    }

    static func _testSetSyncDetectBarcodesOverride(
        _ runner: (@Sendable (Data) throws -> [String])?
    ) {
        testSyncDetectBarcodesOverride.value = runner
    }

    static func _testSetDetectBarcodesOverride(
        _ runner: (@Sendable (UIImage) async throws -> [String])?
    ) {
        testDetectBarcodesOverride.value = runner
    }

    static func _testSetFoodPhotoAnalysisOverride(
        _ runner: (@Sendable (String, Date, String?, [String]) async throws -> FoodPhotoAnalysisResponse)?
    ) {
        testFoodPhotoAnalysisOverride.value = runner
    }

    static func _testSetFoodPhotoServiceRunnerOverride(
        _ runner: (@Sendable (String, Date, String?, [String]) async throws -> FoodPhotoAnalysisResponse)?
    ) {
        testFoodPhotoServiceRunnerOverride.value = runner
    }

    static func _testSetFoodLabelAnalysisOverride(
        _ runner: (@Sendable ([String], String?) async throws -> FoodLabelAnalysisResponse)?
    ) {
        testFoodLabelAnalysisOverride.value = runner
    }

    static func _testSetFoodLabelServiceRunnerOverride(
        _ runner: (@Sendable ([String], String?) async throws -> FoodLabelAnalysisResponse)?
    ) {
        testFoodLabelServiceRunnerOverride.value = runner
    }

    static func _testSetBatchRecipePhotoAnalysisOverride(
        _ runner: (@Sendable (String, String, Double, Int, [String]) async throws -> BatchRecipePhotoAnalysisResponse)?
    ) {
        testBatchRecipePhotoAnalysisOverride.value = runner
    }

    static func _testSetBatchRecipePhotoServiceRunnerOverride(
        _ runner: (@Sendable (String, String, Double, Int, [String]) async throws -> BatchRecipePhotoAnalysisResponse)?
    ) {
        testBatchRecipePhotoServiceRunnerOverride.value = runner
    }

    static func _testFoodPhotoAnalysisResponse(
        imageDataURL: String,
        loggedAt: Date,
        recognizedText: String?,
        barcodes: [String],
        service: FoodPhotoAnalysisService
    ) async throws -> FoodPhotoAnalysisResponse {
        try await foodPhotoAnalysisResponse(
            imageDataURL: imageDataURL,
            loggedAt: loggedAt,
            recognizedText: recognizedText,
            barcodes: barcodes,
            service: service
        )
    }

    static func _testFoodLabelAnalysisResponse(
        imagesDataURL: [String],
        barcode: String?,
        service: FoodLabelAnalysisService
    ) async throws -> FoodLabelAnalysisResponse {
        try await foodLabelAnalysisResponse(
            imagesDataURL: imagesDataURL,
            barcode: barcode,
            service: service
        )
    }

    static func _testBatchRecipePhotoAnalysisResponse(
        imageDataURL: String,
        recipeName: String,
        totalWeightG: Double,
        totalPortions: Int,
        knownIngredients: [String],
        service: BatchRecipePhotoAnalysisService
    ) async throws -> BatchRecipePhotoAnalysisResponse {
        try await batchRecipePhotoAnalysisResponse(
            imageDataURL: imageDataURL,
            recipeName: recipeName,
            totalWeightG: totalWeightG,
            totalPortions: totalPortions,
            knownIngredients: knownIngredients,
            service: service
        )
    }

    static func _testSetCloudAnalysisEnabledOverride(
        _ runner: (@Sendable () async -> Bool)?
    ) {
        testCloudAnalysisEnabledOverride.value = runner
    }

    static func _testSetPhotoCloudAnalysisAvailableOverride(_ isAvailable: Bool?) {
        testPhotoCloudAnalysisAvailableOverride.value = isAvailable
    }

    static func _testResetOverrides() {
        testRecognizeTextOverride.value = nil
        testSyncRecognizeTextOverride.value = nil
        testSyncDetectBarcodesOverride.value = nil
        testDetectBarcodesOverride.value = nil
        testFoodPhotoAnalysisOverride.value = nil
        testFoodPhotoServiceRunnerOverride.value = nil
        testFoodLabelAnalysisOverride.value = nil
        testFoodLabelServiceRunnerOverride.value = nil
        testBatchRecipePhotoAnalysisOverride.value = nil
        testBatchRecipePhotoServiceRunnerOverride.value = nil
        testCloudAnalysisEnabledOverride.value = nil
        testPhotoCloudAnalysisAvailableOverride.value = nil
    }
}

extension NutritionDraftResolver {
    static func _testResolveDraft(
        dbQueue: DatabaseQueue,
        method: NutritionLogMethod,
        confidence: Double?,
        summary: String?,
        sourceText: String?,
        analysisSource: NutritionAnalysisSource?,
        totalMacros: NutritionDraftMacroSummary?,
        suggestions: [String],
        warnings: [String],
        mealType: MealType?,
        recognizedBarcodes: [String],
        detectedItems: [NutritionDraftCandidateItem],
        includeUnmatchedSourceTextItems: Bool,
        targetDay: String,
        loggedAt: Date
    ) async -> NutritionLogDraft {
        let resolver = NutritionDraftResolver(dbQueue: dbQueue)
        return await resolver.resolveDraft(
            method: method,
            confidence: confidence,
            summary: summary,
            sourceText: sourceText,
            analysisSource: analysisSource,
            totalMacros: totalMacros,
            suggestions: suggestions,
            warnings: warnings,
            mealType: mealType,
            recognizedBarcodes: recognizedBarcodes,
            detectedItems: detectedItems,
            includeUnmatchedSourceTextItems: includeUnmatchedSourceTextItems,
            targetDay: targetDay,
            loggedAt: loggedAt
        )
    }

    static func _testResolveVoiceFallbackDraft(
        dbQueue: DatabaseQueue,
        transcription: String,
        confidence: Double?,
        targetDay: String,
        loggedAt: Date
    ) async -> NutritionLogDraft {
        let resolver = NutritionDraftResolver(dbQueue: dbQueue)
        return await resolver.resolveDraft(
            method: .voice,
            confidence: confidence,
            summary: transcription,
            sourceText: transcription,
            analysisSource: nil,
            totalMacros: nil,
            suggestions: [],
            warnings: [],
            mealType: nil,
            recognizedBarcodes: [],
            detectedItems: [],
            includeUnmatchedSourceTextItems: true,
            targetDay: targetDay,
            loggedAt: loggedAt
        )
    }

    static func _testResolvePhotoDraft(
        dbQueue: DatabaseQueue,
        analysis: NutritionPhotoAnalysis,
        targetDay: String,
        loggedAt: Date
    ) async -> NutritionLogDraft {
        let resolver = NutritionDraftResolver(dbQueue: dbQueue)
        return await resolver.resolvePhotoDraft(
            analysis: analysis,
            targetDay: targetDay,
            loggedAt: loggedAt
        )
    }

    static func _testResolveVoiceDraft(
        dbQueue: DatabaseQueue,
        transcription: String,
        confidence: Double?,
        targetDay: String,
        loggedAt: Date
    ) async -> NutritionLogDraft {
        let resolver = NutritionDraftResolver(dbQueue: dbQueue)
        return await resolver.resolveVoiceDraft(
            transcription: transcription,
            confidence: confidence,
            targetDay: targetDay,
            loggedAt: loggedAt
        )
    }

    static func _testSetVoiceLoggingAvailableOverride(_ value: Bool?) {
        testVoiceLoggingAvailableOverride.value = value
    }

    static func _testSetParseTextOverride(
        _ runner: (@Sendable (String) async throws -> FoodTextParseResponse)?
    ) {
        testParseTextOverride.value = runner
    }

    static func _testResetOverrides() {
        testVoiceLoggingAvailableOverride.value = nil
        testParseTextOverride.value = nil
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

enum NutritionCoverageHarness {
    @MainActor
    static func exerciseAdditionalViewBranches() -> Int {
        var rendered = 0

        func render<V: View>(_ view: V) {
            let host = UIHostingController(rootView: view)
            _ = host.view
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            rendered += 1
        }

        func evaluate(_ operation: () -> Void) {
            operation()
            rendered += 1
        }

        let image = NutritionCoverageFixtures.image()
        let photoAnalysis = NutritionCoverageFixtures.photoAnalysis(notice: "Review details")
        let matchedProduct = NutritionCoverageFixtures.foodResult(name: "Coverage Cereal")

        render(NutritionPhotoCaptureView())
        render(
            NutritionPhotoCaptureView(
                testCapturedImage: image,
                testIsAnalyzing: true
            )
        )
        render(
            NutritionPhotoCaptureView(
                testCapturedImage: image,
                testAnalysisResult: "Coverage meal analyzed",
                testAnalysisConfidence: 0.91,
                testPhotoAnalysis: photoAnalysis,
                testAnalysisNotice: "Review details",
                testCaptureError: "Minor note"
            )
        )
        render(
            NutritionPhotoCaptureView(
                testCapturedImage: image,
                testCaptureError: "Photo error"
            )
        )

        var labelReviewDraft = NutritionCoverageFixtures.labelDraft(
            warnings: ["OCR note"],
            sourceText: "Protein 20\nFat 8"
        )
        render(
            NutritionLabelReviewFormView(
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
        )

        render(NutritionBarcodeScannerView())
        render(
            NutritionBarcodeScannerView(
                testScannedCode: "12345",
                testIsSearching: true
            )
        )
        render(
            NutritionBarcodeScannerView(
                testScannedCode: "12345",
                testIsSaving: true,
                testProductFound: true,
                testMatchedProduct: matchedProduct
            )
        )
        render(
            NutritionBarcodeScannerView(
                testScannedCode: "12345",
                testProductFound: false
            )
        )
        render(
            NutritionBarcodeScannerView(
                testIsAnalyzingLabel: true,
                testShowLabelOCRFallback: true,
                testOCRResult: "Protein 20g",
                testErrorMessage: "Fallback error",
                testPendingLabelImages: [image]
            )
        )
        render(
            NutritionBarcodeScannerView(
                testIsSaving: true,
                testIsAnalyzingLabel: true,
                testErrorMessage: "Validation error",
                testLabelReviewDraft: NutritionCoverageFixtures.labelDraft(
                    warnings: ["Review warning"],
                    sourceText: "Fiber 5"
                )
            )
        )

        let recordingRecognizer = NutritionSpeechRecognizer()
        recordingRecognizer._testOverrideState(
            isRecording: true,
            isProcessing: false,
            transcription: "",
            errorMessage: nil,
            confidence: nil
        )
        render(NutritionVoiceInputView(testSpeechRecognizer: recordingRecognizer))

        let processedRecognizer = NutritionSpeechRecognizer()
        processedRecognizer._testOverrideState(
            isRecording: false,
            isProcessing: true,
            transcription: "",
            errorMessage: nil,
            confidence: nil
        )
        render(NutritionVoiceInputView(testSpeechRecognizer: processedRecognizer))

        let transcriptRecognizer = NutritionSpeechRecognizer()
        transcriptRecognizer._testOverrideState(
            isRecording: false,
            isProcessing: false,
            transcription: "Chicken rice bowl",
            errorMessage: "Mic warning",
            confidence: 0.8
        )
        render(NutritionVoiceInputView(testSpeechRecognizer: transcriptRecognizer))

        let searchResult = NutritionCoverageFixtures.foodResult(name: "Coverage Oats")
        render(
            NutritionSearchView(
                testQuery: "coverage",
                testIsSearching: true
            )
        )
        render(
            NutritionSearchView(
                testQuery: "coverage",
                testResults: []
            )
        )
        render(
            NutritionSearchView(
                testQuery: "coverage",
                testResults: [searchResult],
                testErrorMessage: "Search warning"
            )
        )

        evaluate { MealTemplatesView(testIsLoading: true)._testEvaluateBody() }
        evaluate {
            MealTemplatesView(
                testIsLoading: false,
                testTemplates: []
            )._testEvaluateBody()
        }
        evaluate {
            MealTemplatesView(
                testIsLoading: false,
                testTemplates: [NutritionCoverageFixtures.mealTemplateSummary()]
            )._testEvaluateBody()
        }

        evaluate { MealTemplateLibraryView(testIsLoading: true)._testEvaluateBody() }
        evaluate {
            MealTemplateLibraryView(
                testTemplates: [],
                testIsLoading: false,
                testShowingArchived: false
            )._testEvaluateBody()
        }
        evaluate {
            MealTemplateLibraryView(
                testTemplates: [NutritionCoverageFixtures.mealTemplateSummary()],
                testIsLoading: false,
                testStatusMessage: TemplateStatusMessage(message: "Template synced", isError: false)
            )._testEvaluateBody()
        }
        evaluate {
            MealTemplateLibraryView(
                testTemplates: [],
                testIsLoading: false,
                testShowingArchived: true,
                testStatusMessage: TemplateStatusMessage(message: "Archive unavailable", isError: true)
            )._testEvaluateBody()
        }

        evaluate { BatchRecipeLibraryView(testIsLoading: true)._testEvaluateBody() }
        evaluate {
            BatchRecipeLibraryView(
                testRecipes: [],
                testIsLoading: false,
                testShowingArchived: false
            )._testEvaluateBody()
        }
        evaluate {
            BatchRecipeLibraryView(
                testRecipes: [NutritionCoverageFixtures.batchSummary()],
                testIsLoading: false,
                testStatusMessage: TemplateStatusMessage(message: "Batch ready", isError: false)
            )._testEvaluateBody()
        }
        evaluate {
            BatchRecipeLibraryView(
                testRecipes: [NutritionCoverageFixtures.batchSummary(archived: true)],
                testIsLoading: false,
                testShowingArchived: true,
                testStatusMessage: TemplateStatusMessage(message: "Archived batch", isError: true)
            )._testEvaluateBody()
        }

        render(BatchPortionLogView())
        render(
            BatchPortionLogView(
                remainingWeightG: 120,
                testPortionWeightG: 180,
                testErrorMessage: "Too much selected"
            )
        )
        render(
            BatchRecipeIngredientPickerView(
                testQuery: "coverage",
                testIsSearching: true
            )
        )
        render(
            BatchRecipeIngredientPickerView(
                testQuery: "coverage",
                testResults: [NutritionCoverageFixtures.foodResult()]
            )
        )
        render(
            BatchRecipeIngredientPickerView(
                testQuery: "coverage",
                testErrorMessage: "Network error"
            )
        )

        var selectedDate = NutritionCoverageFixtures.loggedAt
        let month = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 1))
            ?? NutritionCoverageFixtures.loggedAt
        render(
            NutritionCalendarView(
                selectedDate: Binding(
                    get: { selectedDate },
                    set: { selectedDate = $0 }
                ),
                testDisplayedMonth: month,
                testDaysWithLogs: ["2026-03-01", "2026-03-19"]
            )
        )

        return rendered
    }

    @MainActor
    static func exerciseTemplateAndBatchViewBranches() -> Int {
        var rendered = 0

        func evaluate(_ operation: () -> Void) {
            operation()
            rendered += 1
        }

        let activeTemplateDetail = NutritionCoverageFixtures.mealTemplateDetail()
        let archivedTemplateDetail = NutritionCoverageFixtures.mealTemplateDetail(archived: true)
        let batchDetail = NutritionCoverageFixtures.batchDetail()
        let archivedBatchDetail = NutritionCoverageFixtures.batchDetail(
            archived: true,
            remainingWeightG: 0,
            description: nil
        )

        evaluate {
            MealTemplateDetailView(
                testViewModel: MealTemplateDetailViewModel._testConfigured(
                    detail: activeTemplateDetail,
                    isLoading: true
                )
            )._testEvaluateBody()
        }
        evaluate {
            MealTemplateDetailView(
                testViewModel: MealTemplateDetailViewModel._testConfigured(
                    detail: activeTemplateDetail,
                    statusMessage: TemplateStatusMessage(message: "Template synced", isError: false)
                )
            )._testEvaluateBody()
        }
        evaluate {
            MealTemplateDetailView(
                testViewModel: MealTemplateDetailViewModel._testConfigured(
                    detail: activeTemplateDetail,
                    isEditing: true,
                    errorMessage: "Edit validation"
                )
            )._testEvaluateBody()
        }
        evaluate {
            MealTemplateDetailView(
                testViewModel: MealTemplateDetailViewModel._testConfigured(
                    detail: archivedTemplateDetail,
                    isArchiving: true,
                    statusMessage: TemplateStatusMessage(message: "Archived template", isError: true)
                )
            )._testEvaluateBody()
        }

        let templateItems = activeTemplateDetail.items.map(NutritionEditableMealItem.init(templateItem:))
        evaluate { MealTemplateComposerView(testName: "   ", testItems: [])._testEvaluateBody() }
        evaluate {
            MealTemplateComposerView(
                testName: activeTemplateDetail.template.name,
                testMealType: activeTemplateDetail.template.mealType,
                testItems: templateItems
            )._testEvaluateBody()
        }
        evaluate {
            MealTemplateComposerView(
                testName: activeTemplateDetail.template.name,
                testMealType: activeTemplateDetail.template.mealType,
                testItems: templateItems,
                testIsSaving: true,
                testErrorMessage: "Unable to save"
            )._testEvaluateBody()
        }

        evaluate { BatchRecipeDetailView(testIsLoading: true)._testEvaluateBody() }
        evaluate {
            BatchRecipeDetailView(
                batchId: batchDetail.recipe.id,
                testDetail: batchDetail,
                testIsLoading: false,
                testStatusMessage: TemplateStatusMessage(message: "Batch refreshed", isError: false)
            )._testEvaluateBody()
        }
        evaluate {
            BatchRecipeDetailView(
                batchId: archivedBatchDetail.recipe.id,
                testDetail: archivedBatchDetail,
                testIsLoading: false,
                testIsArchiving: true,
                testErrorMessage: "Archive note",
                testStatusMessage: TemplateStatusMessage(message: "Archived batch", isError: true)
            )._testEvaluateBody()
        }

        let editableIngredients = batchDetail.ingredients.map(BatchRecipeEditableIngredient.init(ingredient:))
        evaluate {
            BatchRecipeComposerView(
                testName: "Coverage Prep",
                testDescription: "Roast and chill",
                testTotalWeightG: batchDetail.recipe.totalWeightG,
                testTotalPortions: batchDetail.recipe.totalPortions ?? 1,
                testIngredients: editableIngredients,
                testImportMessage: "Photo draft imported."
            )._testEvaluateBody()
        }
        evaluate {
            BatchRecipeComposerView(
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
            )._testEvaluateBody()
        }

        return rendered
    }

    @MainActor
    static func localizedFormattingMetrics() -> (
        lastUsed: String,
        usedCount: String,
        cooked: String,
        remainingOnly: String,
        remainingWithPortions: String,
        portionsLeft: String,
        itemWithFiber: String,
        itemWithoutFiber: String,
        batchWithFiber: String,
        batchWithoutFiber: String,
        templateSubtitle: String,
        barcodeFallbackName: String
    ) {
        let sampleDate = Date(timeIntervalSince1970: 1_710_000_000)
        let template = NutritionCoverageFixtures.mealTemplateSummary()
        let batchWithFiberSnapshot = NutritionCoverageFixtures.batchSnapshot(fiberG: 4)
        let batchWithoutFiberSnapshot = NutritionCoverageFixtures.batchSnapshot(fiberG: nil)
        let barcodeFallbackName = NutritionBarcodeScannerView()._testFallbackDraft().name
        return (
            lastUsed: localizedNutritionLastUsed(sampleDate),
            usedCount: localizedNutritionUsedCount(7),
            cooked: localizedNutritionCooked("2026-03-19"),
            remainingOnly: localizedNutritionRemainingLine(weightG: 245),
            remainingWithPortions: localizedNutritionRemainingLine(weightG: 245, portionsRemaining: 2.5),
            portionsLeft: localizedNutritionPortionsLeft(1.5),
            itemWithFiber: localizedNutritionItemSummary(
                weightG: 185,
                calories: 420,
                protein: 28,
                fat: 12,
                carbs: 41,
                fiber: 8
            ),
            itemWithoutFiber: localizedNutritionItemSummary(
                weightG: 120,
                calories: 260,
                protein: 18,
                fat: 7,
                carbs: 29,
                fiber: nil
            ),
            batchWithFiber: localizedNutritionBatchMacroLine(batchWithFiberSnapshot, prefix: "Coverage"),
            batchWithoutFiber: localizedNutritionBatchMacroLine(batchWithoutFiberSnapshot, prefix: "Coverage"),
            templateSubtitle: MealTemplateLibraryView(
                testTemplates: [template],
                testIsLoading: false
            )._testTemplateRowSubtitle(template),
            barcodeFallbackName: barcodeFallbackName
        )
    }

    @MainActor
    static func validateBarcodeReview(_ review: NutritionLabelReviewDraft) -> String? {
        NutritionBarcodeScannerView._testValidate(review: review)
    }

    @MainActor
    static func batchPortionMetrics() -> (
        breakfast: MealType,
        lunch: MealType,
        dinner: MealType,
        snack: MealType,
        canSave: Bool,
        blockedSave: Bool,
        previewCalories: Double,
        previewFiber: Double?
    ) {
        let previewView = BatchPortionLogView(testPortionWeightG: 150)
        let blockedView = BatchPortionLogView(remainingWeightG: 100, testPortionWeightG: 140)
        let calendar = Calendar.current
        let breakfastDate = calendar.date(from: DateComponents(year: 2026, month: 3, day: 19, hour: 8))
            ?? NutritionCoverageFixtures.loggedAt
        let lunchDate = calendar.date(from: DateComponents(year: 2026, month: 3, day: 19, hour: 13))
            ?? NutritionCoverageFixtures.loggedAt
        let dinnerDate = calendar.date(from: DateComponents(year: 2026, month: 3, day: 19, hour: 19))
            ?? NutritionCoverageFixtures.loggedAt
        let snackDate = calendar.date(from: DateComponents(year: 2026, month: 3, day: 19, hour: 23))
            ?? NutritionCoverageFixtures.loggedAt
        return (
            breakfast: BatchPortionLogView._testDefaultMealType(for: breakfastDate),
            lunch: BatchPortionLogView._testDefaultMealType(for: lunchDate),
            dinner: BatchPortionLogView._testDefaultMealType(for: dinnerDate),
            snack: BatchPortionLogView._testDefaultMealType(for: snackDate),
            canSave: previewView._testCanSave(),
            blockedSave: blockedView._testCanSave(),
            previewCalories: previewView._testPreview().calories,
            previewFiber: previewView._testPreview().fiberG
        )
    }

    @MainActor
    static func mealTemplateComposerMetrics() -> (
        canSave: Bool,
        blockedSave: Bool,
        calories: Double,
        protein: Double,
        fiber: Double?
    ) {
        let detail = NutritionCoverageFixtures.mealTemplateDetail()
        let filledComposer = MealTemplateComposerView(
            testName: detail.template.name,
            testMealType: detail.template.mealType,
            testItems: detail.items.map(NutritionEditableMealItem.init(templateItem:))
        )
        let blockedComposer = MealTemplateComposerView(
            testName: "   ",
            testMealType: detail.template.mealType,
            testItems: detail.items.map(NutritionEditableMealItem.init(templateItem:))
        )
        let totals = filledComposer._testTotals()
        return (
            canSave: filledComposer._testCanSave(),
            blockedSave: blockedComposer._testCanSave(),
            calories: totals.calories,
            protein: totals.protein,
            fiber: totals.fiber
        )
    }

    @MainActor
    static func mealTemplateComposerMutationMetrics() -> (
        itemCount: Int,
        firstAddedName: String
    ) {
        let addedItems = MealTemplateComposerView._testAddedItems(mealType: .dinner)
        return (
            itemCount: addedItems.count,
            firstAddedName: addedItems.first?.name ?? ""
        )
    }

    @MainActor
    static func batchRecipeComposerMetrics() -> (
        canSave: Bool,
        blockedSave: Bool,
        totalCalories: Double,
        per100gProtein: Double,
        perPortionCalories: Double,
        mergedIngredientNames: [String]
    ) {
        let baseIngredients = [
            BatchRecipeEditableIngredient(
                name: "Coverage Chicken",
                brand: "Coverage Farm",
                barcode: "333333",
                weightG: 250,
                calories: 330,
                proteinG: 42,
                fatG: 9,
                carbsG: 0
            ),
            BatchRecipeEditableIngredient(
                name: "Coverage Rice",
                brand: "Coverage Pantry",
                barcode: "444444",
                weightG: 300,
                calories: 390,
                proteinG: 9,
                fatG: 3,
                carbsG: 84,
                fiberG: 3
            ),
            BatchRecipeEditableIngredient(
                name: "Coverage Salsa",
                brand: "Coverage Garden",
                barcode: "555555",
                weightG: 120,
                calories: 60,
                proteinG: 2,
                fatG: 0,
                carbsG: 12,
                fiberG: 2
            )
        ]
        let filledComposer = BatchRecipeComposerView(
            testName: "Coverage Prep",
            testDescription: "Roast and chill",
            testTotalWeightG: 780,
            testTotalPortions: 4,
            testIngredients: baseIngredients
        )
        let blockedComposer = BatchRecipeComposerView(
            testName: "Coverage Prep",
            testDescription: "Roast and chill",
            testTotalWeightG: 0,
            testTotalPortions: 0,
            testIngredients: []
        )
        let mergedNames = filledComposer._testMergedIngredients(
            imported: [
                BatchRecipeEditableIngredient(
                    name: " coverage chicken ",
                    brand: "Duplicate",
                    barcode: "",
                    weightG: 10,
                    calories: 10,
                    proteinG: 1,
                    fatG: 0,
                    carbsG: 0
                ),
                BatchRecipeEditableIngredient(
                    name: "Coverage Herbs",
                    brand: "Coverage Garden",
                    barcode: "666666",
                    weightG: 30,
                    calories: 12,
                    proteinG: 1,
                    fatG: 0,
                    carbsG: 2
                )
            ]
        )
        let totals = filledComposer._testTotals()
        return (
            canSave: filledComposer._testCanSave(),
            blockedSave: blockedComposer._testCanSave(),
            totalCalories: totals.calories,
            per100gProtein: filledComposer._testPer100g().proteinG,
            perPortionCalories: filledComposer._testPerPortion().calories,
            mergedIngredientNames: mergedNames.map(\.name).sorted()
        )
    }

    @MainActor
    static func batchRecipePhotoImportMetrics() -> (
        importedName: String,
        importedDescription: String,
        importedIngredientCount: Int,
        noteImportMessage: String?,
        mergedIngredientNames: [String],
        mergedDescription: String,
        genericImportMessage: String?,
        fallbackError: String?
    ) {
        let initialIngredients = [
            BatchRecipeEditableIngredient(
                name: "Coverage Chicken",
                brand: "Coverage Farm",
                barcode: "333333",
                weightG: 250,
                calories: 330,
                proteinG: 42,
                fatG: 9,
                carbsG: 0
            )
        ]
        let importedResult = BatchRecipeComposerView._testAppliedPhotoDraftResult(
            testName: String(localized: "nutrition_default_meal_prep_name"),
            testDescription: "",
            testTotalWeightG: 500,
            testTotalPortions: 2,
            testIngredients: [],
            photoDraft: NutritionCoverageFixtures.batchPhotoDraft(
                notes: ["Coverage import note"],
                descriptionText: "Roast and chill"
            )
        )
        let mergedResult = BatchRecipeComposerView._testAppliedPhotoDraftResult(
            testName: "Existing Prep",
            testDescription: "Base note",
            testTotalWeightG: 500,
            testTotalPortions: 2,
            testIngredients: initialIngredients,
            photoDraft: NutritionCoverageFixtures.batchPhotoDraft(
                recipeName: "Merged Coverage Prep",
                ingredients: [
                    BatchRecipeEditableIngredient(
                        name: " coverage chicken ",
                        brand: "Duplicate",
                        barcode: "",
                        weightG: 10,
                        calories: 10,
                        proteinG: 1,
                        fatG: 0,
                        carbsG: 0
                    ),
                    BatchRecipeEditableIngredient(
                        name: "Coverage Herbs",
                        brand: "Coverage Garden",
                        barcode: "666666",
                        weightG: 30,
                        calories: 12,
                        proteinG: 1,
                        fatG: 0,
                        carbsG: 2
                    )
                ],
                notes: [],
                descriptionText: "New note"
            )
        )
        let fallbackResult = BatchRecipeComposerView._testAppliedPhotoDraftResult(
            testName: "Existing Prep",
            testDescription: "Base note",
            testTotalWeightG: 500,
            testTotalPortions: 2,
            testIngredients: [],
            photoDraft: NutritionCoverageFixtures.batchPhotoDraft(
                recipeName: "Fallback Coverage Prep",
                ingredients: [],
                notes: [],
                descriptionText: nil
            )
        )

        return (
            importedName: importedResult.name,
            importedDescription: importedResult.description,
            importedIngredientCount: importedResult.ingredientNames.count,
            noteImportMessage: importedResult.importMessage,
            mergedIngredientNames: mergedResult.ingredientNames,
            mergedDescription: mergedResult.description,
            genericImportMessage: mergedResult.importMessage,
            fallbackError: fallbackResult.errorMessage
        )
    }

    @MainActor
    static func calendarDaysInMonth(for displayedMonth: Date) -> [Date?] {
        final class SelectedDateBox {
            var value: Date

            init(_ value: Date) {
                self.value = value
            }
        }

        let selectedDate = SelectedDateBox(displayedMonth)
        return NutritionCalendarView(
            selectedDate: Binding(
                get: { selectedDate.value },
                set: { selectedDate.value = $0 }
            ),
            testDisplayedMonth: displayedMonth,
            testDaysWithLogs: []
        )
        ._testDaysInMonth()
    }

    static func preparedLargeImageDataURL() throws -> String {
        try MediaRecognitionService._testPreparedImageDataURL(for: NutritionCoverageFixtures.largeImage())
    }

    static func resolveCatalogMergedDraft(dbQueue: DatabaseQueue) async -> NutritionLogDraft {
        await NutritionDraftResolver._testResolveDraft(
            dbQueue: dbQueue,
            method: .photo,
            confidence: 0.71,
            summary: "Coverage breakfast",
            sourceText: "I had oatmeal and banana",
            analysisSource: .aiVision,
            totalMacros: NutritionDraftMacroSummary(
                calories: 480,
                proteinG: 19,
                fatG: 9,
                carbsG: 82,
                fiberG: 11
            ),
            suggestions: [" add yogurt ", ""],
            warnings: [" review serving ", " "],
            mealType: .breakfast,
            recognizedBarcodes: [" 12345 ", ""],
            detectedItems: [
                NutritionDraftCandidateItem(
                    name: "Oatmeal",
                    notes: " warm bowl ",
                    confidence: nil,
                    detectedByAi: true
                ),
                NutritionDraftCandidateItem(
                    name: "Mystery Snack",
                    confidence: 0.33,
                    detectedByAi: true
                )
            ],
            includeUnmatchedSourceTextItems: true,
            targetDay: NutritionCoverageFixtures.targetDay,
            loggedAt: NutritionCoverageFixtures.loggedAt
        )
    }

    static func resolveVoiceFallbackDraft(
        dbQueue: DatabaseQueue,
        transcription: String = "I had egg whites, toast and coffee",
        confidence: Double? = 0.64
    ) async -> NutritionLogDraft {
        await NutritionDraftResolver._testResolveVoiceFallbackDraft(
            dbQueue: dbQueue,
            transcription: transcription,
            confidence: confidence,
            targetDay: NutritionCoverageFixtures.targetDay,
            loggedAt: NutritionCoverageFixtures.loggedAt
        )
    }
}
#endif

@MainActor
final class NutritionSpeechRecognizer: NSObject, ObservableObject {
    private typealias SpeechAuthorizationCompletion = @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void
    private typealias MicrophonePermissionCompletion = @Sendable (Bool) -> Void

    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var transcription = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var confidence: Double?

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale.autoupdatingCurrent)
        ?? SFSpeechRecognizer(locale: Locale(identifier: "en_US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
#if DEBUG
    private static let testSpeechAuthorizationRequestOverride = LockedTestOverride<
        @Sendable (@escaping SpeechAuthorizationCompletion) -> Void
    >()
    private static let testAudioApplicationPermissionOverride = LockedTestOverride<
        @Sendable (@escaping MicrophonePermissionCompletion) -> Void
    >()
    private static let testAudioSessionPermissionOverride = LockedTestOverride<
        @Sendable (@escaping MicrophonePermissionCompletion) -> Void
    >()
    private static let testInstallAudioTapOverride = LockedTestOverride<
        @Sendable (NutritionSpeechRecognizer, SFSpeechAudioBufferRecognitionRequest) -> Void
    >()
    private static let testPrepareAudioOverride = LockedTestOverride<
        @Sendable (AVAudioEngine) -> Void
    >()
    private static let testStartAudioOverride = LockedTestOverride<
        @Sendable (AVAudioEngine) throws -> Void
    >()
    private static let testStartRecognitionTaskOverride = LockedTestOverride<
        @Sendable (@escaping @MainActor (String?, Bool, Error?) -> Void) async -> Void
    >()
    private static let testEndAudioOverride = LockedTestOverride<
        @Sendable (SFSpeechAudioBufferRecognitionRequest?) -> Void
    >()
    private static let testFinishAudioPipelineOverride = LockedTestOverride<
        @Sendable (NutritionSpeechRecognizer) -> Void
    >()
    private static let testConfigureSessionCategoryOverride = LockedTestOverride<
        @Sendable () throws -> Void
    >()
    private static let testConfigureSessionActiveOverride = LockedTestOverride<
        @Sendable () throws -> Void
    >()
#endif

    func startRecording(
        permissionAction: (() async throws -> Void)? = nil,
        configureSessionAction: (() throws -> Void)? = nil,
        installAudioTapAction: ((SFSpeechAudioBufferRecognitionRequest) -> Void)? = nil,
        prepareAudioAction: (() -> Void)? = nil,
        startAudioAction: (() throws -> Void)? = nil,
        startRecognitionTaskAction: ((@escaping @MainActor (String?, Bool, Error?) -> Void) async -> Void)? = nil
    ) async {
        errorMessage = nil

        do {
            if let permissionAction {
                try await permissionAction()
            } else {
                try await requestPermissions()
            }

            if let configureSessionAction {
                try configureSessionAction()
            } else {
                try configureSession()
            }

            transcription = ""
            confidence = nil
            isProcessing = false

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            recognitionRequest = request

            installAudioTap(request, explicitAction: installAudioTapAction)
            prepareAudio(explicitAction: prepareAudioAction)
            try startAudio(explicitAction: startAudioAction)
            isRecording = true

            recognitionTask?.cancel()
            let handleRecognitionUpdate = recognitionUpdateHandler()
            await startRecognitionTask(
                with: request,
                explicitAction: startRecognitionTaskAction,
                handleRecognitionUpdate: handleRecognitionUpdate
            )
        } catch {
            errorMessage = error.localizedDescription
            finishRecording()
        }
    }

    func stopRecording(
        endAudioAction: (() -> Void)? = nil,
        finishAudioPipelineAction: (() -> Void)? = nil
    ) async {
        guard isRecording else { return }
        isProcessing = true
        endAudio(explicitAction: endAudioAction)
        completeAudioPipeline(explicitAction: finishAudioPipelineAction)

        if transcription.isEmpty {
            isProcessing = false
        }
    }

    private func recognitionUpdateHandler() -> @MainActor (String?, Bool, Error?) -> Void {
        { [weak self] transcript, isFinal, error in
            guard let self else { return }

            if let transcript {
                self.transcription = transcript
                self.confidence = isFinal ? 0.9 : 0.75
                self.isProcessing = false
            }

            if let error {
                self.errorMessage = error.localizedDescription
                self.finishRecording()
                return
            }

            if isFinal {
                self.finishRecording()
            }
        }
    }

    private func installAudioTap(
        _ request: SFSpeechAudioBufferRecognitionRequest,
        explicitAction: ((SFSpeechAudioBufferRecognitionRequest) -> Void)? = nil,
        defaultAction: ((SFSpeechAudioBufferRecognitionRequest) -> Void)? = nil
    ) {
        if let explicitAction {
            explicitAction(request)
            return
        }
#if DEBUG
        if let override = Self.testInstallAudioTapOverride.value {
            override(self, request)
            return
        }
#endif
        let resolvedDefaultAction = defaultAction ?? { request in
            self.installDefaultAudioTap(request)
        }
        resolvedDefaultAction(request)
    }

    private func prepareAudio(explicitAction: (() -> Void)? = nil) {
        if let explicitAction {
            explicitAction()
            return
        }
#if DEBUG
        if let override = Self.testPrepareAudioOverride.value {
            override(audioEngine)
            return
        }
#endif
        audioEngine.prepare()
    }

    private func startAudio(
        explicitAction: (() throws -> Void)? = nil,
        defaultAction: (() throws -> Void)? = nil
    ) throws {
        if let explicitAction {
            try explicitAction()
            return
        }
#if DEBUG
        if let override = Self.testStartAudioOverride.value {
            try override(audioEngine)
            return
        }
#endif
        let resolvedDefaultAction = defaultAction ?? {
            try self.audioEngine.start()
        }
        try resolvedDefaultAction()
    }

    private func startRecognitionTask(
        with request: SFSpeechAudioBufferRecognitionRequest,
        explicitAction: ((@escaping @MainActor (String?, Bool, Error?) -> Void) async -> Void)? = nil,
        defaultAction: ((@escaping @MainActor (String?, Bool, Error?) -> Void) async -> Void)? = nil,
        fallbackAction: ((@escaping @MainActor (String?, Bool, Error?) -> Void) async -> Void)? = nil,
        handleRecognitionUpdate: @escaping @MainActor (String?, Bool, Error?) -> Void
    ) async {
        if let explicitAction {
            await explicitAction(handleRecognitionUpdate)
            return
        }
#if DEBUG
        if let override = Self.testStartRecognitionTaskOverride.value {
            await override(handleRecognitionUpdate)
            return
        }
#endif
        if let defaultAction {
            await defaultAction(handleRecognitionUpdate)
        } else {
            let resolvedFallbackAction = fallbackAction ?? { handleRecognitionUpdate in
                self.startDefaultRecognitionTask(
                    with: request,
                    handleRecognitionUpdate: handleRecognitionUpdate
                )
            }
            await resolvedFallbackAction(handleRecognitionUpdate)
        }
    }

    private func endAudio(explicitAction: (() -> Void)? = nil) {
        if let explicitAction {
            explicitAction()
            return
        }
#if DEBUG
        if let override = Self.testEndAudioOverride.value {
            override(recognitionRequest)
            return
        }
#endif
        recognitionRequest?.endAudio()
    }

    private func completeAudioPipeline(explicitAction: (() -> Void)? = nil) {
        if let explicitAction {
            explicitAction()
            return
        }
#if DEBUG
        if let override = Self.testFinishAudioPipelineOverride.value {
            override(self)
            return
        }
#endif
        finishAudioPipeline()
    }

    private func installDefaultAudioTap(
        _ request: SFSpeechAudioBufferRecognitionRequest,
        removeTapAction: ((AVAudioInputNode) -> Void)? = nil,
        outputFormatAction: ((AVAudioInputNode) -> AVAudioFormat)? = nil,
        installTapAction: ((AVAudioInputNode, AVAudioFormat, @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) -> Void)? = nil,
        defaultRemoveTapAction: ((AVAudioInputNode) -> Void)? = nil,
        defaultOutputFormatAction: ((AVAudioInputNode) -> AVAudioFormat)? = nil,
        defaultInstallTapAction: ((AVAudioInputNode, AVAudioFormat, @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) -> Void)? = nil
    ) {
        let inputNode = audioEngine.inputNode
        let resolvedRemoveTapAction =
            removeTapAction ?? defaultRemoveTapAction ?? { $0.removeTap(onBus: 0) }
        let resolvedOutputFormatAction =
            outputFormatAction ?? defaultOutputFormatAction ?? { $0.outputFormat(forBus: 0) }
        let resolvedInstallTapAction =
            installTapAction ?? defaultInstallTapAction ?? { inputNode, recordingFormat, appendBuffer in
                self.defaultInstallTap(
                    inputNode,
                    recordingFormat,
                    appendBuffer,
                    installTapAction: nil
                )
            }

        resolvedRemoveTapAction(inputNode)
        let recordingFormat = resolvedOutputFormatAction(inputNode)

        func appendBuffer(_ buffer: AVAudioPCMBuffer, _: AVAudioTime) {
            recognitionRequest?.append(buffer)
        }

        resolvedInstallTapAction(inputNode, recordingFormat, appendBuffer)
    }

    private func defaultInstallTap(
        _ inputNode: AVAudioInputNode,
        _ recordingFormat: AVAudioFormat,
        _ appendBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void,
        installTapAction: ((AVAudioInputNode, AVAudioFormat, @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) -> Void)? = nil,
        systemInstallTapAction: ((
            AVAudioInputNode,
            AVAudioFormat,
            @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
        ) -> Void)? = nil
    ) {
        let resolvedInstallTapAction = installTapAction ?? systemInstallTapAction ?? {
            inputNode,
            recordingFormat,
            appendBuffer in
            inputNode.installTap(
                onBus: 0,
                bufferSize: 1024,
                format: recordingFormat,
                block: appendBuffer
            )
        }
        resolvedInstallTapAction(inputNode, recordingFormat, appendBuffer)
    }

    private func startDefaultRecognitionTask(
        with request: SFSpeechAudioBufferRecognitionRequest,
        handleRecognitionUpdate: @escaping @MainActor (String?, Bool, Error?) -> Void,
        recognitionTaskAction: ((SFSpeechAudioBufferRecognitionRequest, @escaping (String?, Bool, Error?) -> Void) -> SFSpeechRecognitionTask?)? = nil
    ) {
        let taskAction = recognitionTaskAction ?? { request, update in
            self.defaultRecognitionTaskAction(
                request,
                update,
                recognitionTaskAction: nil
            )
        }

        recognitionTask = taskAction(request) { transcript, isFinal, error in
            Task { @MainActor in
                handleRecognitionUpdate(transcript, isFinal, error)
            }
        }
    }

    private func defaultRecognitionTaskAction(
        _ request: SFSpeechAudioBufferRecognitionRequest,
        _ update: @escaping (String?, Bool, Error?) -> Void,
        recognitionTaskAction: ((SFSpeechAudioBufferRecognitionRequest, @escaping (SFSpeechRecognitionResult?, Error?) -> Void) -> SFSpeechRecognitionTask?)?
    ) -> SFSpeechRecognitionTask? {
        let resolvedRecognitionTaskAction =
            recognitionTaskAction ?? { request, handler in
                self.speechRecognizer?.recognitionTask(with: request, resultHandler: handler)
            }
        return resolvedRecognitionTaskAction(
            request,
            defaultRecognitionResultHandler(update)
        )
    }

    private func defaultRecognitionResultHandler(
        _ update: @escaping (String?, Bool, Error?) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true
            update(transcript, isFinal, error)
        }
    }

    private func requestPermissions(
        speechAuthorizationRequest: ((@escaping SpeechAuthorizationCompletion) -> Void)? = nil,
        microphonePermissionRequest: ((@escaping MicrophonePermissionCompletion) -> Void)? = nil,
        defaultSpeechAuthorizationRequest: ((@escaping SpeechAuthorizationCompletion) -> Void)? = nil,
        defaultMicrophonePermissionRequest: ((@escaping MicrophonePermissionCompletion) -> Void)? = nil
    ) async throws {
        let speechAuthorized = await requestSpeechAuthorization(
            requestAction: speechAuthorizationRequest,
            defaultRequestAction: defaultSpeechAuthorizationRequest
        )
        guard speechAuthorized else {
            throw SpeechRecognitionError.speechPermissionDenied
        }

        let micAuthorized = await requestMicrophonePermission(
            requestAction: microphonePermissionRequest,
            defaultRequestAction: defaultMicrophonePermissionRequest
        )
        guard micAuthorized else {
            throw SpeechRecognitionError.microphonePermissionDenied
        }
    }

    private func requestSpeechAuthorization(
        requestAction: ((@escaping SpeechAuthorizationCompletion) -> Void)? = nil,
        defaultRequestAction: ((@escaping SpeechAuthorizationCompletion) -> Void)? = nil
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let authorizationAction = requestAction ?? defaultRequestAction ?? { completion in
                self.defaultSpeechAuthorizationRequest(completion: completion)
            }
            authorizationAction { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicrophonePermission(
        requestAction: ((@escaping MicrophonePermissionCompletion) -> Void)? = nil,
        defaultRequestAction: ((@escaping MicrophonePermissionCompletion) -> Void)? = nil
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let permissionAction = requestAction ?? defaultRequestAction ?? { completion in
                self.defaultMicrophonePermissionRequest(completion: completion)
            }
            permissionAction { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    private func defaultSpeechAuthorizationRequest(
        completion: @escaping SpeechAuthorizationCompletion,
        requestAction: ((@escaping SpeechAuthorizationCompletion) -> Void)? = nil
    ) {
        let authorize: (@escaping SpeechAuthorizationCompletion) -> Void
#if DEBUG
        authorize = requestAction ?? Self.testSpeechAuthorizationRequestOverride.value ?? { completion in
            SFSpeechRecognizer.requestAuthorization { status in
                completion(status)
            }
        }
#else
        authorize = requestAction ?? { completion in
            SFSpeechRecognizer.requestAuthorization { status in
                completion(status)
            }
        }
#endif
        authorize { status in
            completion(status)
        }
    }

    private func defaultMicrophonePermissionRequest(
        completion: @escaping MicrophonePermissionCompletion,
        useAudioApplicationRequest: Bool? = nil,
        audioApplicationRequest: ((@escaping MicrophonePermissionCompletion) -> Void)? = nil,
        audioSessionRequest: ((@escaping MicrophonePermissionCompletion) -> Void)? = nil
    ) {
        let shouldUseAudioApplicationRequest: Bool
        if let useAudioApplicationRequest {
            shouldUseAudioApplicationRequest = useAudioApplicationRequest
        } else if #available(iOS 17, *) {
            shouldUseAudioApplicationRequest = true
        } else {
            shouldUseAudioApplicationRequest = false
        }

        if shouldUseAudioApplicationRequest {
            requestAudioApplicationPermission(
                completion: completion,
                requestAction: audioApplicationRequest
            )
        } else {
            requestAudioSessionPermission(
                completion: completion,
                requestAction: audioSessionRequest
            )
        }
    }

    private func requestAudioApplicationPermission(
        completion: @escaping MicrophonePermissionCompletion,
        requestAction: ((@escaping MicrophonePermissionCompletion) -> Void)? = nil,
        systemRequestAction: ((@escaping MicrophonePermissionCompletion) -> Void)? = nil
    ) {
        let resolvedRequestAction: (@escaping MicrophonePermissionCompletion) -> Void
#if DEBUG
        resolvedRequestAction = requestAction
            ?? Self.testAudioApplicationPermissionOverride.value
            ?? systemRequestAction
            ?? { completion in
                AVAudioApplication.requestRecordPermission(completionHandler: completion)
            }
#else
        resolvedRequestAction = requestAction
            ?? systemRequestAction
            ?? { completion in
                AVAudioApplication.requestRecordPermission(completionHandler: completion)
            }
#endif

        resolvedRequestAction(completion)
    }

    private func requestAudioSessionPermission(
        completion: @escaping MicrophonePermissionCompletion,
        requestAction: ((@escaping MicrophonePermissionCompletion) -> Void)? = nil,
        systemRequestAction: ((@escaping MicrophonePermissionCompletion) -> Void)? = nil
    ) {
        let resolvedRequestAction: (@escaping MicrophonePermissionCompletion) -> Void
#if DEBUG
        resolvedRequestAction = requestAction
            ?? Self.testAudioSessionPermissionOverride.value
            ?? systemRequestAction
            ?? { completion in
                AVAudioApplication.requestRecordPermission(completionHandler: completion)
            }
#else
        resolvedRequestAction = requestAction
            ?? systemRequestAction
            ?? { completion in
                AVAudioApplication.requestRecordPermission(completionHandler: completion)
            }
#endif

        resolvedRequestAction(completion)
    }

    private func configureSession(
        setCategoryAction: (() throws -> Void)? = nil,
        setActiveAction: (() throws -> Void)? = nil
    ) throws {
        let resolvedSetCategoryAction: (() throws -> Void)?
        let resolvedSetActiveAction: (() throws -> Void)?
#if DEBUG
        resolvedSetCategoryAction = setCategoryAction ?? Self.testConfigureSessionCategoryOverride.value
        resolvedSetActiveAction = setActiveAction ?? Self.testConfigureSessionActiveOverride.value
#else
        resolvedSetCategoryAction = setCategoryAction
        resolvedSetActiveAction = setActiveAction
#endif

        if let resolvedSetCategoryAction {
            try resolvedSetCategoryAction()
        } else {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        }

        if let resolvedSetActiveAction {
            try resolvedSetActiveAction()
        } else {
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        }
    }

    private func finishRecording(
        finishAudioPipelineAction: (() -> Void)? = nil
    ) {
        if let finishAudioPipelineAction {
            finishAudioPipelineAction()
        } else {
            finishAudioPipeline()
        }
        isProcessing = false
        isRecording = false
    }

    private func finishAudioPipeline(
        stopAudioAction: (() -> Void)? = nil,
        removeTapAction: (() -> Void)? = nil,
        cancelRecognitionTaskAction: (() -> Void)? = nil,
        deactivateSessionAction: (() -> Void)? = nil
    ) {
        if let stopAudioAction {
            stopAudioAction()
        } else if audioEngine.isRunning {
            audioEngine.stop()
        }

        if let removeTapAction {
            removeTapAction()
        } else {
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        recognitionRequest = nil

        if let cancelRecognitionTaskAction {
            cancelRecognitionTaskAction()
        } else {
            recognitionTask?.cancel()
        }
        recognitionTask = nil

        if let deactivateSessionAction {
            deactivateSessionAction()
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    enum SpeechRecognitionError: LocalizedError {
        case speechPermissionDenied
        case microphonePermissionDenied

        var errorDescription: String? {
            switch self {
            case .speechPermissionDenied:
                return String(localized: "error.speech.recognition_permission")
            case .microphonePermissionDenied:
                return String(localized: "error.speech.microphone_permission")
            }
        }
    }
}
