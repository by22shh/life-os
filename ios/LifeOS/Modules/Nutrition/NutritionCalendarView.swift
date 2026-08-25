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
// MARK: - Nutrition Calendar View

struct NutritionCalendarView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedDate: Date
    @State  var displayedMonth = Date()
    @State private var daysWithLogs: Set<String> = []

     let calendar = Calendar.current
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

     func daysInMonth() -> [Date?] {
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

     func weekdayHeader(_ day: String) -> some View {
        Text(day)
            .font(LifeOSTypography.caption)
            .foregroundStyle(.secondary)
    }

     func dayCell(for date: Date?) -> some View {
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

     func shiftedMonth(
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

     func selectDate(
        _ date: Date,
        dismissAction: (() -> Void)? = nil
    ) {
        selectedDate = date
        dismissCalendar(dismissAction: dismissAction)
    }

     func selectToday(
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

     func loadLoggedDays(
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

     func configuredPicker(
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
