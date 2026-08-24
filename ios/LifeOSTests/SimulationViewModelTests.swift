import Foundation
import XCTest
@testable import LifeOS

private actor SimulationPredictionServiceMock: PredictionServiceProtocol {
    enum Mode {
        case success(PredictiveScenarioResponse)
        case failure(Error)
    }

    private var mode: Mode
    private var requests: [PredictiveScenarioRequest] = []

    init(mode: Mode) {
        self.mode = mode
    }

    func runPredictiveSimulation(request: PredictiveScenarioRequest) async throws -> PredictiveScenarioResponse {
        requests.append(request)
        switch mode {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }

    func requestCount() -> Int {
        requests.count
    }

    func lastRequest() -> PredictiveScenarioRequest? {
        requests.last
    }
}

private actor SimulationEnvironmentServiceMock: EnvironmentServiceProtocol {
    enum Mode {
        case success(EnvironmentalContext)
        case failure(Error)
    }

    private var mode: Mode
    private var callCount: Int = 0

    init(mode: Mode) {
        self.mode = mode
    }

    func fetchCurrentEnvironment() async throws -> EnvironmentalContext {
        callCount += 1
        switch mode {
        case .success(let context):
            return context
        case .failure(let error):
            throw error
        }
    }

    func fetchCount() -> Int {
        callCount
    }
}

private enum SimulationTestsError: Error {
    case failed
}

@MainActor
final class SimulationViewModelTests: XCTestCase {

    private func sampleResponse() -> PredictiveScenarioResponse {
        PredictiveScenarioResponse(
            predictedRecoveryRange: [52, 66],
            predictedZone: .ready,
            explanation: "stable",
            confidenceScore: 0.77
        )
    }

    private func sampleEnvironment() -> EnvironmentalContext {
        EnvironmentalContext(
            weatherCondition: "Partly Cloudy",
            temperatureC: 21,
            pressureHpa: 1008,
            pressureDeltaHpa24h: -2,
            aqi: 34,
            indoorCo2Ppm: 620,
            moonPhase: "Waxing",
            daylightHours: 10.8,
            city: "Baku"
        )
    }

    private func waitForSimulationToFinish(_ viewModel: SimulationViewModel) async {
        for _ in 0..<200 {
            if !viewModel.isLoading {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for simulation to complete")
    }

    func testRunSimulationWithEmptyScenarioDoesNotStart() async {
        let prediction = SimulationPredictionServiceMock(mode: .success(sampleResponse()))
        let environment = SimulationEnvironmentServiceMock(mode: .success(sampleEnvironment()))
        let viewModel = SimulationViewModel(
            predictionService: prediction,
            environmentService: environment,
            isSimulationAvailable: true
        )

        viewModel.scenarioText = ""
        viewModel.runSimulation()

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.response)
        XCTAssertNil(viewModel.error)
        let predictionCalls = await prediction.requestCount()
        let environmentCalls = await environment.fetchCount()
        XCTAssertEqual(predictionCalls, 0)
        XCTAssertEqual(environmentCalls, 0)
    }

    func testRunSimulationWithWhitespaceOnlyScenarioDoesNotStart() async {
        let prediction = SimulationPredictionServiceMock(mode: .success(sampleResponse()))
        let environment = SimulationEnvironmentServiceMock(mode: .success(sampleEnvironment()))
        let viewModel = SimulationViewModel(
            predictionService: prediction,
            environmentService: environment,
            isSimulationAvailable: true
        )

        viewModel.scenarioText = "   \n  "
        viewModel.runSimulation()

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.canRunSimulation)
        XCTAssertNil(viewModel.response)
        XCTAssertNil(viewModel.error)
        let predictionCalls = await prediction.requestCount()
        XCTAssertEqual(predictionCalls, 0)
    }

    func testRunSimulationSuccessUpdatesResponseAndBuildsRequest() async {
        let prediction = SimulationPredictionServiceMock(mode: .success(sampleResponse()))
        let environment = SimulationEnvironmentServiceMock(mode: .success(sampleEnvironment()))
        let viewModel = SimulationViewModel(
            predictionService: prediction,
            environmentService: environment,
            isSimulationAvailable: true
        )

        viewModel.scenarioText = "Sleep by 23:00"
        viewModel.selectedType = .sleep
        viewModel.runSimulation()
        await waitForSimulationToFinish(viewModel)

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.error)
        XCTAssertEqual(viewModel.response?.predictedZone, .ready)
        XCTAssertEqual(viewModel.response?.predictedRecoveryRange, [52, 66])
        let predictionCalls = await prediction.requestCount()
        let environmentCalls = await environment.fetchCount()
        XCTAssertEqual(predictionCalls, 1)
        XCTAssertEqual(environmentCalls, 1)

        let request = await prediction.lastRequest()
        XCTAssertEqual(request?.scenarioText, "Sleep by 23:00")
        XCTAssertEqual(request?.scenarioType, .sleep)
        XCTAssertEqual(request?.environmentalContext?.city, "Baku")

        if let targetDate = request?.targetDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            XCTAssertNotNil(formatter.date(from: targetDate))
        } else {
            XCTFail("Expected target date in predictive request")
        }
    }

    func testRunSimulationContinuesWhenEnvironmentLookupFails() async {
        let prediction = SimulationPredictionServiceMock(mode: .success(sampleResponse()))
        let environment = SimulationEnvironmentServiceMock(mode: .failure(SimulationTestsError.failed))
        let viewModel = SimulationViewModel(
            predictionService: prediction,
            environmentService: environment,
            isSimulationAvailable: true
        )

        viewModel.scenarioText = "Late workout"
        viewModel.selectedType = .workout
        viewModel.runSimulation()
        await waitForSimulationToFinish(viewModel)

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.error)
        XCTAssertEqual(viewModel.response?.predictedZone, .ready)
        let environmentCalls = await environment.fetchCount()
        XCTAssertEqual(environmentCalls, 1)

        let request = await prediction.lastRequest()
        XCTAssertEqual(request?.scenarioType, .workout)
        XCTAssertNil(request?.environmentalContext)
    }

    func testRunSimulationErrorUpdatesErrorState() async {
        let error = NSError(
            domain: "SimulationViewModelTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "prediction failed"]
        )
        let prediction = SimulationPredictionServiceMock(mode: .failure(error))
        let environment = SimulationEnvironmentServiceMock(mode: .success(sampleEnvironment()))
        let viewModel = SimulationViewModel(
            predictionService: prediction,
            environmentService: environment,
            isSimulationAvailable: true
        )

        viewModel.scenarioText = "Skip sleep"
        viewModel.runSimulation()
        await waitForSimulationToFinish(viewModel)

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.response)
        XCTAssertEqual(viewModel.error, "prediction failed")
        let predictionCalls = await prediction.requestCount()
        XCTAssertEqual(predictionCalls, 1)
    }

    func testDiscardSimulationClearsInputAndOutputs() async {
        let viewModel = SimulationViewModel(
            predictionService: SimulationPredictionServiceMock(mode: .success(sampleResponse())),
            environmentService: SimulationEnvironmentServiceMock(mode: .success(sampleEnvironment())),
            isSimulationAvailable: true
        )

        viewModel.scenarioText = "Some scenario"
        viewModel.error = "some error"
        viewModel.response = sampleResponse()

        viewModel.discardSimulation()

        XCTAssertEqual(viewModel.scenarioText, "")
        XCTAssertNil(viewModel.response)
        XCTAssertNil(viewModel.error)
    }

    func testPrepareForAdjustmentKeepsScenarioButClearsOutputs() {
        let viewModel = SimulationViewModel(
            predictionService: SimulationPredictionServiceMock(mode: .success(sampleResponse())),
            environmentService: SimulationEnvironmentServiceMock(mode: .success(sampleEnvironment())),
            isSimulationAvailable: true
        )

        viewModel.scenarioText = "Sleep at 23:30"
        viewModel.selectedType = .sleep
        viewModel.error = "temporary issue"
        viewModel.response = sampleResponse()

        viewModel.prepareForAdjustment()

        XCTAssertEqual(viewModel.scenarioText, "Sleep at 23:30")
        XCTAssertEqual(viewModel.selectedType, .sleep)
        XCTAssertNil(viewModel.response)
        XCTAssertNil(viewModel.error)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertTrue(viewModel.canRunSimulation)
    }

    func testRunSimulationOfflineLocalShowsUnavailableMessageAndSkipsServices() async {
        let prediction = SimulationPredictionServiceMock(mode: .success(sampleResponse()))
        let environment = SimulationEnvironmentServiceMock(mode: .success(sampleEnvironment()))
        let viewModel = SimulationViewModel(
            predictionService: prediction,
            environmentService: environment,
            isSimulationAvailable: false
        )

        viewModel.scenarioText = "Sleep by 23:00"
        viewModel.runSimulation()

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.isSimulationAvailable)
        XCTAssertFalse(viewModel.canRunSimulation)
        XCTAssertNil(viewModel.response)
        XCTAssertEqual(
            viewModel.error,
            String(localized: "insights_simulate_unavailable_notice")
        )
        XCTAssertEqual(
            viewModel.availabilityMessage,
            String(localized: "insights_simulate_unavailable_notice")
        )

        let predictionCalls = await prediction.requestCount()
        let environmentCalls = await environment.fetchCount()
        XCTAssertEqual(predictionCalls, 0)
        XCTAssertEqual(environmentCalls, 0)
    }
}
