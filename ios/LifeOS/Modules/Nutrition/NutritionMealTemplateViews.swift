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
// MARK: - Meal Templates Section

struct MealTemplatesView: View {
    let targetDay: String
    let loggedAt: Date
    let refreshTrigger: Int
    let onTemplatesChanged: () -> Void
    let onTemplateLogged: () -> Void
    @State  var isLoading = true
    @State  var templates: [NutritionMealTemplateSummary] = []
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

     func loadTemplates(manager: any NutritionMealTemplateManaging) async {
        isLoading = true
        defer { isLoading = false }
        templates = await Self.loadTemplatesResult(manager: manager)
    }

     func templateCard(_ template: NutritionMealTemplateSummary) -> some View {
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

    @State  var templates: [NutritionMealTemplateSummary] = []
    @State  var isLoading = true
    @State  var showingArchived = false
    @State private var showingComposer = false
    @State private var selectedTemplate: MealTemplateLibraryDestination?
    @State  var statusMessage: TemplateStatusMessage?

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

     func loadTemplates(manager: any NutritionMealTemplateManaging) async {
        isLoading = true
        defer { isLoading = false }
        let result = await Self.loadTemplatesResult(
            showingArchived: showingArchived,
            manager: manager
        )
        templates = result.templates
        statusMessage = result.statusMessage
    }

     func toggleArchive(
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

     func templateRow(_ template: NutritionMealTemplateSummary) -> some View {
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

     func templateDetailDestination(_ destination: MealTemplateLibraryDestination) -> some View {
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

     func handleTemplateDetailTemplatesChanged() {
        handleTemplateDetailTemplatesChanged(reloadAction: nil)
    }

     func handleTemplateDetailTemplatesChanged(reloadAction: (() async -> Void)? = nil) {
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

     func handleTemplateDetailStatusMessage(_ message: TemplateStatusMessage?) {
        statusMessage = message
    }

     func composerSheet() -> some View {
        NavigationStack {
            MealTemplateComposerView(
                onSaved: handleComposerSheetSaved
            )
        }
    }

     func handleComposerSheetSaved(_ message: TemplateStatusMessage) {
        handleComposerSaved(message, reloadAction: nil)
    }

     func handleComposerSaved(
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

     func templateRowSubtitle(_ template: NutritionMealTemplateSummary) -> String {
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

enum NutritionIdentity {
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

struct MealTemplateLibraryDestination: Identifiable, Hashable {
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
     let templateManager: any NutritionMealTemplateManaging

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

     func apply(detail: NutritionMealTemplateDetail) {
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
    @State  var viewModel: MealTemplateDetailViewModel

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

     func templateHeaderSection(_ viewModel: MealTemplateDetailViewModel) -> some View {
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

     func editorDetailsSection(_ viewModel: MealTemplateDetailViewModel) -> some View {
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

     func editorItemsSection(_ viewModel: MealTemplateDetailViewModel) -> some View {
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

     func previewItemsSection(_ viewModel: MealTemplateDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(String(localized: "nutrition_items"))
                .font(LifeOSTypography.subheadline.weight(.semibold))

            ForEach(viewModel.items) { item in
                previewItemRow(item)
            }
        }
    }

     func previewItemRow(_ item: NutritionEditableMealItem) -> some View {
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

     func actionSection(_ viewModel: MealTemplateDetailViewModel) -> some View {
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

     func templateItemEditor(index: Int, viewModel: MealTemplateDetailViewModel) -> some View {
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

     func templateNumericField(_ title: String, value: Binding<Double>) -> some View {
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

     func saveTemplate() {
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

     func toggleArchived() {
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

     func logTemplateNow() {
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

    @State  var name = ""
    @State  var mealType: MealType?
    @State  var items: [NutritionEditableMealItem] = []
    @State  var isSaving = false
    @State  var errorMessage: String?

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

     var canSave: Bool {
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

     var detailsSection: some View {
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

     var previewSection: some View {
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

     var itemsSection: some View {
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

     func itemEditor(index: Int) -> some View {
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

     func templateNumericField(_ title: String, value: Binding<Double>) -> some View {
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

     func save(
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

     func save() {
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

struct BatchRecipeLibraryDestination: Identifiable, Hashable {
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

    @State  var recipes: [NutritionBatchRecipeSummary] = []
    @State  var isLoading = true
    @State  var showingArchived = false
    @State private var showingComposer = false
    @State private var selectedBatch: BatchRecipeLibraryDestination?
    @State private var quickLogBatch: NutritionBatchRecipeSummary?
    @State  var statusMessage: TemplateStatusMessage?

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

     func batchRow(_ recipe: NutritionBatchRecipeSummary) -> some View {
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

     func detailDestination(_ destination: BatchRecipeLibraryDestination) -> some View {
        BatchRecipeDetailView(
            batchId: destination.batchId,
            targetDay: targetDay,
            loggedAt: loggedAt,
            onBatchesChanged: handleDetailBatchesChanged,
            onBatchLogged: handleDetailBatchLogged,
            onStatusMessage: handleDetailStatusMessage
        )
    }

     func styledBatchRow(_ recipe: NutritionBatchRecipeSummary) -> some View {
        batchRow(recipe)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

     func handleDetailBatchesChanged() {
        handleDetailBatchesChanged(reloadAction: nil)
    }

     func handleDetailBatchesChanged(reloadAction: (() async -> Void)? = nil) {
        onBatchesChanged()
        Task { @MainActor in
            if let reloadAction {
                await reloadAction()
            } else {
                await loadRecipes()
            }
        }
    }

     func handleDetailBatchLogged() {
        handleDetailBatchLogged(reloadAction: nil)
    }

     func handleDetailBatchLogged(reloadAction: (() async -> Void)? = nil) {
        onBatchLogged()
        Task { @MainActor in
            if let reloadAction {
                await reloadAction()
            } else {
                await loadRecipes()
            }
        }
    }

     func handleDetailStatusMessage(_ message: TemplateStatusMessage?) {
        statusMessage = message
    }

     func composerSheet() -> some View {
        NavigationStack {
            BatchRecipeComposerView(
                existingDetail: nil,
                onSaved: handleComposerSheetSaved
            )
        }
    }

     func quickLogSheet(_ recipe: NutritionBatchRecipeSummary) -> some View {
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

     func handleComposerSheetSaved(_ message: TemplateStatusMessage) {
        handleComposerSaved(message, reloadAction: nil)
    }

     func handleQuickLogSheetSaved(_ message: TemplateStatusMessage) {
        handleQuickLogSaved(message, reloadAction: nil)
    }

     func handleComposerSaved(
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

     func handleQuickLogSaved(
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

     func loadRecipes(
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

    @State  var detail: NutritionBatchRecipeDetail?
    @State  var isLoading = true
    @State  var isArchiving = false
    @State  var isDuplicating = false
    @State private var showingComposer = false
    @State private var showingLogSheet = false
    @State  var errorMessage: String?
    @State  var statusMessage: TemplateStatusMessage?

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

     func detailHeader(_ detail: NutritionBatchRecipeDetail) -> some View {
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

     func detailMacros(_ detail: NutritionBatchRecipeDetail) -> some View {
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

     func detailIngredients(_ detail: NutritionBatchRecipeDetail) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(String(localized: "nutrition_ingredients"))
                .font(LifeOSTypography.subheadline.weight(.semibold))

            ForEach(detail.ingredients) { ingredient in
                detailIngredientRow(ingredient)
            }
        }
    }

     func detailIngredientRow(_ ingredient: BatchRecipeIngredient) -> some View {
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

     func detailActions(_ detail: NutritionBatchRecipeDetail) -> some View {
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

     func composerSheet(_ detail: NutritionBatchRecipeDetail) -> some View {
        NavigationStack {
            BatchRecipeComposerView(
                existingDetail: detail,
                onSaved: handleComposerSheetSaved
            )
        }
    }

    @ViewBuilder
     func composerSheetContent() -> some View {
        if let detail {
            composerSheet(detail)
        }
    }

     func logSheet(_ detail: NutritionBatchRecipeDetail) -> some View {
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
     func logSheetContent() -> some View {
        if let detail {
            logSheet(detail)
        }
    }

     func handleComposerSaved(
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

     func handleComposerSheetSaved(_ message: TemplateStatusMessage) {
        handleComposerSaved(message, reloadAction: nil)
    }

     func handleLogSaved(
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

     func handleLogSheetSaved(_ message: TemplateStatusMessage) {
        handleLogSaved(message, reloadAction: nil)
    }

     func loadDetail(
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

     func loadDetail(preferRemote: Bool) async {
        await loadDetail(preferRemote: preferRemote, manager: NutritionService())
    }

     func toggleArchived(
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

     func toggleArchived() {
        toggleArchived(manager: NutritionService(), dismissAction: { dismiss() })
    }

     func cookAgain(
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

     func cookAgain() {
        cookAgain(manager: NutritionService(), dismissAction: { dismiss() })
    }
}

struct BatchRecipeComposerView: View {
    @Environment(\.dismiss) private var dismiss

    let existingDetail: NutritionBatchRecipeDetail?
    let onSaved: (TemplateStatusMessage) -> Void

    @State  var name: String
    @State  var description: String
    @State  var cookedAt: Date
    @State  var totalWeightG: Double
    @State  var totalPortions: Int
    @State  var ingredients: [BatchRecipeEditableIngredient]
    @State  var isSaving = false
    @State  var errorMessage: String?
    @State  var importMessage: String?
    @State  var isAnalyzingPhoto = false
    @State  var showingIngredientSearch = false
    @State  var showCameraPicker = false
    @State  var showPhotoLibrary = false
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

     var totals: NutritionBatchMacroSnapshot {
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

     var per100g: NutritionBatchMacroSnapshot {
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

     var perPortion: NutritionBatchMacroSnapshot {
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

     var canSave: Bool {
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

     func ingredientSearchSheet() -> some View {
        NavigationStack {
            BatchRecipeIngredientPickerView(onSelect: handleIngredientSearchSelection)
        }
    }

     func cameraPickerSheet() -> some View {
        SystemImagePicker(sourceType: .camera, onImagePicked: handlePickedCameraImage)
    }

     var detailsSection: some View {
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

     var totalsSection: some View {
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

     var ingredientsSection: some View {
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

     func ingredientEditor(index: Int) -> some View {
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

     func batchNumericField(_ title: String, value: Binding<Double>) -> some View {
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

     func batchIntegerField(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(LifeOSTypography.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(title, value: value, format: .number)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
        }
    }

     func save(
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

     func save() {
        save(manager: NutritionService(), dismissAction: { dismiss() })
    }

     func presentIngredientSearch() {
        showingIngredientSearch = true
    }

     func addManualIngredient() {
        ingredients.append(.manual())
    }

     func handleIngredientSearchSelection(_ result: FoodSearchResult) {
        ingredients.append(BatchRecipeEditableIngredient(searchResult: result))
    }

     func beginCameraCapture() {
        openCameraOrLibrary()
    }

     func beginCameraCapture(
        cameraAvailableProvider: @escaping () -> Bool
    ) {
        openCameraOrLibrary(cameraAvailableProvider: cameraAvailableProvider)
    }

     func openCameraOrLibrary(
        cameraAvailableProvider: (() -> Bool)? = nil
    ) {
        let cameraAvailable = cameraAvailableProvider?()
            ?? UIImagePickerController.isSourceTypeAvailable(.camera)
        let state = Self.capturePickerState(cameraAvailable: cameraAvailable)
        showCameraPicker = state.showCameraPicker
        showPhotoLibrary = state.showPhotoLibrary
    }

     func handlePickedCameraImage(_ image: UIImage) {
        Task { @MainActor in
            await processBatchPhoto(image)
        }
    }

    @MainActor
     func handleSelectedPhotoItemChange() async {
        await loadSelectedPhotoItemIfNeeded(
            item: selectedPhotoItem,
            shouldLoad: selectedPhotoItem != nil
        )
    }

    @MainActor
     func loadSelectedPhotoItemIfNeeded(
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
     func loadPhotoItem(
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
     func apply(photoDraft: BatchRecipePhotoDraft) {
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
    @State  var isSaving = false
    @State  var errorMessage: String?

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

     var preview: NutritionBatchMacroSnapshot {
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

     var canSave: Bool {
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

     func save(
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

     func save() {
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

     func search(
        searcher: @escaping @Sendable (String) async throws -> [FoodSearchResult]
    ) {
        guard let normalizedQuery = NutritionSearchExecutionHelper.normalizedQuery(query) else { return }
        isSearching = true
        errorMessage = nil
        Task { @MainActor in
            await applySearch(query: normalizedQuery, searcher: searcher)
        }
    }

     func submitSearch() {
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

     func searchResultButton(_ result: FoodSearchResult) -> some View {
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

     func handleSelection(
        of result: FoodSearchResult,
        dismissAction: @escaping () -> Void
    ) {
        onSelect(result)
        dismissAction()
    }
}

enum NutritionSearchExecutionHelper {
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
