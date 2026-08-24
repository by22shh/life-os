import SwiftUI

public struct SimulationView: View {
    public enum PresentationStyle {
        case modal
        case embedded
    }

    @StateObject private var viewModel: SimulationViewModel
    @Environment(\.dismiss) private var dismiss
    private let presentationStyle: PresentationStyle

    public init(presentationStyle: PresentationStyle = .modal) {
        _viewModel = StateObject(wrappedValue: SimulationViewModel())
        self.presentationStyle = presentationStyle
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let availabilityMessage = viewModel.availabilityMessage {
                    unavailableSection(availabilityMessage)
                } else {
                    headerSection
                    inputSection

                    if viewModel.isLoading {
                        loadingSection
                    } else if let response = viewModel.response {
                        resultSection(response)
                    } else if let error = viewModel.error {
                        errorSection(error)
                    }
                }
            }
            .padding()
        }
        .accessibilityIdentifier("simulation.screen")
        .background(LifeOSColors.Surface.background)
        .navigationTitle(screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .refreshOnFeatureFlagChanges()
        .toolbar {
            if presentationStyle == .modal {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: dismiss.callAsFunction) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .accessibilityIdentifier("simulation.dismiss")
                }
            }
        }
    }

    private var screenTitle: String {
        if viewModel.isSimulationAvailable {
            return String(localized: "insights_simulate_title")
        }
        return String(localized: "insights_simulate_unavailable_title")
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "insights_simulate_intro"))
                .font(.body)
                .foregroundColor(.secondary)
            
            Text(String(localized: "insights_simulate_disclaimer"))
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func unavailableSection(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                String(localized: "insights_simulate_unavailable_title"),
                systemImage: "icloud.slash"
            )
            .font(.headline)
            .foregroundStyle(.primary)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(LifeOSColors.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: LayoutConstants.cardCornerRadius))
        .accessibilityIdentifier("simulation.unavailable")
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "insights_simulate_prompt"))
                .font(.headline)
            
            TextField(String(localized: "insights_simulate_placeholder"), text: $viewModel.scenarioText)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .accessibilityIdentifier("simulation.scenario")
            
            Picker(String(localized: "insights_category_prefix"), selection: $viewModel.selectedType) {
                Text(localizedTitle(for: .sleep)).tag(PredictiveScenarioType.sleep)
                Text(localizedTitle(for: .workout)).tag(PredictiveScenarioType.workout)
                Text(localizedTitle(for: .nutrition)).tag(PredictiveScenarioType.nutrition)
                Text(localizedTitle(for: .general)).tag(PredictiveScenarioType.general)
            }
            .pickerStyle(SegmentedPickerStyle())
            .accessibilityIdentifier("simulation.category")
            
            Button(action: runSimulationAction) {
                Text(String(localized: "insights_simulate_run"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(LifeOSColors.Semantic.primary)
            .disabled(!viewModel.canRunSimulation || viewModel.isLoading)
            .accessibilityIdentifier("simulation.run")
        }
    }

    private var loadingSection: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text(String(localized: "loading_what_if"))
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 32)
    }

    private func resultSection(_ response: PredictiveScenarioResponse) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "insights_simulate_result_title"))
                .font(.headline)

            zoneIndicator(response.predictedZone)
            
            HStack {
                Text(String(localized: "insights_simulate_zone"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text(response.predictedZone.label)
                    .font(.headline)
                    .foregroundColor(colorForZone(response.predictedZone))
            }
            
            HStack {
                Text(String(localized: "insights_simulate_recovery"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(response.predictedRecoveryRange[0])% - \(response.predictedRecoveryRange[1])%")
                    .font(.headline)
            }

            HStack {
                Text(String(localized: "insights_simulate_confidence"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int((response.confidenceScore * 100).rounded()))%")
                    .font(.headline)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "insights_simulate_explanation"))
                    .font(.subheadline)
                    .fontWeight(.bold)
                Text(response.explanation)
                    .font(.body)
                    .foregroundColor(.primary)
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            
            HStack(spacing: 16) {
                Button(action: discardAndDismissAction) {
                    Text(String(localized: "insights_simulate_discard"))
                        .font(.subheadline)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                }
                .accessibilityIdentifier("simulation.discard")
                
                Button(action: adjustAndRerunAction) {
                    Text(String(localized: "insights_simulate_adjust"))
                        .font(.subheadline)
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                }
                .accessibilityIdentifier("simulation.adjust")
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(16)
    }

    private func errorSection(_ error: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.red)
                .font(.largeTitle)
            Text(String(localized: "insights_simulate_error_title"))
                .font(.headline)
            Text(error)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(16)
    }

    private func zoneIndicator(_ zone: RecoveryZone) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(RecoveryZone.allCases, id: \.self) { candidate in
                    RoundedRectangle(cornerRadius: 10)
                        .fill(candidate == zone ? colorForZone(candidate) : Color.secondary.opacity(0.12))
                        .frame(height: candidate == zone ? 16 : 12)
                }
            }

            Text(zone.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func colorForZone(_ zone: RecoveryZone) -> Color {
        zone.color
    }

    private func localizedTitle(for type: PredictiveScenarioType) -> String {
        switch type {
        case .sleep:
            return String(localized: "insights_category_sleep")
        case .workout:
            return String(localized: "insights_category_training")
        case .nutrition:
            return String(localized: "insights_category_nutrition")
        case .general:
            return String(localized: "insights_simulate_category_other")
        }
    }

    private func runSimulationAction() {
        viewModel.runSimulation()
    }

    private func discardAndDismissAction() {
        viewModel.discardSimulation()
        dismiss()
    }

    private func adjustAndRerunAction() {
        viewModel.prepareForAdjustment()
    }
}

#if DEBUG
extension SimulationView {
    init(
        testViewModel: SimulationViewModel,
        presentationStyle: PresentationStyle = .modal
    ) {
        _viewModel = StateObject(wrappedValue: testViewModel)
        self.presentationStyle = presentationStyle
    }

    @MainActor
    func _testEvaluateSections(response: PredictiveScenarioResponse, error: String) {
        _ = headerSection
        _ = unavailableSection("Unavailable in offline-local mode")
        _ = inputSection
        _ = loadingSection
        _ = resultSection(response)
        _ = errorSection(error)
        _ = zoneIndicator(.ready)
        _ = colorForZone(.optimal)
        _ = colorForZone(.ready)
        _ = colorForZone(.caution)
        _ = colorForZone(.critical)
        _ = localizedTitle(for: .sleep)
        _ = localizedTitle(for: .workout)
        _ = localizedTitle(for: .nutrition)
        _ = localizedTitle(for: .general)
    }

    @MainActor
    func _testTriggerActions() {
        runSimulationAction()
        adjustAndRerunAction()
        discardAndDismissAction()
    }
}
#endif

#Preview {
    NavigationStack {
        SimulationView()
    }
}
