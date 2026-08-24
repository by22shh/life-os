import Foundation
import Combine

@MainActor
class SimulationViewModel: ObservableObject {
    @Published var scenarioText: String = ""
    @Published var selectedType: PredictiveScenarioType = .general

    @Published var isLoading: Bool = false
    @Published var response: PredictiveScenarioResponse? = nil
    @Published var error: String? = nil

    var isSimulationAvailable: Bool {
        availability.simulationAvailable
    }

    var availabilityMessage: String? {
        guard !availability.simulationAvailable else { return nil }
        return String(localized: "insights_simulate_unavailable_notice")
    }

    var canRunSimulation: Bool {
        availability.simulationAvailable && !normalizedScenarioText.isEmpty
    }

    // Default to tomorrow
    private var targetDate: Date {
        Self.resolveTargetDate(now: Date()) {
            Calendar.current.date(byAdding: .day, value: 1, to: $0)
        }
    }
    
    private let predictionService: PredictionServiceProtocol
    private let environmentService: EnvironmentServiceProtocol
    private let availability: AIAvailability
    private var simulationTask: Task<Void, Never>?

    private var normalizedScenarioText: String {
        scenarioText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func resolveTargetDate(
        now: Date,
        addingDay: (Date) -> Date?
    ) -> Date {
        if let tomorrow = addingDay(now) {
            return tomorrow
        }
        return now
    }
    
    init(
        predictionService: PredictionServiceProtocol = PredictionService(),
        environmentService: EnvironmentServiceProtocol = EnvironmentService(),
        availability: AIAvailability? = nil
    ) {
        self.predictionService = predictionService
        self.environmentService = environmentService
        self.availability = availability ?? AIAvailability()
    }

    convenience init(
        predictionService: PredictionServiceProtocol,
        environmentService: EnvironmentServiceProtocol,
        isSimulationAvailable: Bool
    ) {
        self.init(
            predictionService: predictionService,
            environmentService: environmentService,
            availability: AIAvailability(simulationAvailableOverride: isSimulationAvailable)
        )
    }

    func runSimulation() {
        guard availability.simulationAvailable else {
            simulationTask?.cancel()
            clearSimulationOutput()
            error = availabilityMessage
            return
        }

        let scenario = normalizedScenarioText
        guard !scenario.isEmpty else { return }

        scenarioText = scenario
        simulationTask?.cancel()
        clearSimulationOutput()
        isLoading = true
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateString = formatter.string(from: targetDate)
        
        simulationTask = Task { @MainActor in
            do {
                // Fetch context seamlessly
                let context = try? await environmentService.fetchCurrentEnvironment()
                guard !Task.isCancelled else {
                    self.isLoading = false
                    self.simulationTask = nil
                    return
                }
                
                let request = PredictiveScenarioRequest(
                    targetDate: dateString,
                    scenarioText: scenario,
                    scenarioType: selectedType,
                    environmentalContext: context
                )
                
                let result = try await predictionService.runPredictiveSimulation(request: request)
                guard !Task.isCancelled else {
                    self.isLoading = false
                    self.simulationTask = nil
                    return
                }
                self.response = result
                self.isLoading = false
                self.simulationTask = nil
            } catch is CancellationError {
                self.isLoading = false
                self.simulationTask = nil
            } catch {
                guard !Task.isCancelled else {
                    self.isLoading = false
                    self.simulationTask = nil
                    return
                }
                self.error = error.localizedDescription
                self.isLoading = false
                self.simulationTask = nil
            }
        }
    }

    func prepareForAdjustment() {
        simulationTask?.cancel()
        clearSimulationOutput()
    }
    
    func discardSimulation() {
        simulationTask?.cancel()
        scenarioText = ""
        clearSimulationOutput()
    }

    private func clearSimulationOutput() {
        isLoading = false
        response = nil
        error = nil
    }
}

#if DEBUG
extension SimulationViewModel {
    nonisolated static func _testResolveTargetDate(
        now: Date,
        addingDay: (Date) -> Date?
    ) -> Date {
        resolveTargetDate(now: now, addingDay: addingDay)
    }
}
#endif
