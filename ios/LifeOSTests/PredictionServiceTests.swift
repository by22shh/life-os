import Foundation
import XCTest
@testable import LifeOS

private actor PredictionServiceAPIClientMock: PredictionAPIClient {
    struct Invocation: Sendable {
        let name: String
        let body: Data
        let headers: [String: String]
        let maxAttempts: Int
    }

    enum MockError: Error {
        case missingResponse
    }

    private var responseData: Data?
    private var errorToThrow: Error?
    private var invocations: [Invocation] = []

    init(responseData: Data? = nil, errorToThrow: Error? = nil) {
        self.responseData = responseData
        self.errorToThrow = errorToThrow
    }

    func callEdgeFunction<T: Decodable & Sendable>(
        _ name: String,
        body: Data,
        headers: [String: String],
        maxAttempts: Int
    ) async throws -> T {
        invocations.append(
            Invocation(
                name: name,
                body: body,
                headers: headers,
                maxAttempts: maxAttempts
            )
        )

        if let errorToThrow {
            throw errorToThrow
        }
        guard let responseData else {
            throw MockError.missingResponse
        }
        return try JSONDecoder().decode(T.self, from: responseData)
    }

    func invocationCount() -> Int {
        invocations.count
    }

    func firstInvocation() -> Invocation? {
        invocations.first
    }
}

private enum PredictionServiceTestsError: Error {
    case transportFailed
}

final class PredictionServiceTests: XCTestCase {

    private func makeRequest(temperature: Double = 18.5) -> PredictiveScenarioRequest {
        PredictiveScenarioRequest(
            targetDate: "2026-02-24",
            scenarioText: "Sleep early after training",
            scenarioType: .sleep,
            environmentalContext: EnvironmentalContext(
                weatherCondition: "Cloudy",
                temperatureC: temperature,
                pressureHpa: 1012,
                pressureDeltaHpa24h: -3,
                aqi: 40,
                indoorCo2Ppm: 650,
                moonPhase: "Waxing",
                daylightHours: 11.2,
                city: "Baku"
            )
        )
    }

    func testRunPredictiveSimulationUsesExpectedFunctionAndPayload() async throws {
        let responseData = Data(
            """
            {
              "predicted_recovery_range": [60, 72],
              "predicted_zone": "ready",
              "explanation": "stable",
              "confidence_score": 0.83
            }
            """.utf8
        )
        let client = PredictionServiceAPIClientMock(responseData: responseData)
        let service = PredictionService(apiClient: client, isRuntimeConfigured: true)

        let response = try await service.runPredictiveSimulation(request: makeRequest())

        XCTAssertEqual(response.predictedRecoveryRange, [60, 72])
        XCTAssertEqual(response.predictedZone, .ready)
        XCTAssertEqual(response.explanation, "stable")
        XCTAssertEqual(response.confidenceScore, 0.83, accuracy: 0.0001)

        let invocationCount = await client.invocationCount()
        XCTAssertEqual(invocationCount, 1)
        let firstInvocation = await client.firstInvocation()
        let invocation = try XCTUnwrap(firstInvocation)
        XCTAssertEqual(invocation.name, "api-insights-predict")
        XCTAssertEqual(invocation.headers, [:])
        XCTAssertEqual(invocation.maxAttempts, 3)

        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: invocation.body) as? [String: Any]
        )
        XCTAssertEqual(payload["target_date"] as? String, "2026-02-24")
        XCTAssertEqual(payload["scenario_type"] as? String, "sleep")
        XCTAssertEqual(payload["scenario_text"] as? String, "Sleep early after training")
        XCTAssertNotNil(payload["environmental_context"])
    }

    func testRunPredictiveSimulationRethrowsAPIClientError() async {
        let client = PredictionServiceAPIClientMock(
            errorToThrow: APIClientError.rateLimited(function: "api-insights-predict")
        )
        let service = PredictionService(apiClient: client, isRuntimeConfigured: true)

        do {
            _ = try await service.runPredictiveSimulation(request: makeRequest())
            XCTFail("Expected APIClientError.rateLimited")
        } catch let error as APIClientError {
            switch error {
            case .rateLimited(let function):
                XCTAssertEqual(function, "api-insights-predict")
            default:
                XCTFail("Unexpected APIClientError case: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testRunPredictiveSimulationWrapsNonAPIErrorsAsNetworkError() async {
        let client = PredictionServiceAPIClientMock(errorToThrow: PredictionServiceTestsError.transportFailed)
        let service = PredictionService(apiClient: client, isRuntimeConfigured: true)

        do {
            _ = try await service.runPredictiveSimulation(request: makeRequest())
            XCTFail("Expected PredictionError.networkError")
        } catch let error as PredictionError {
            switch error {
            case .networkError(let underlying):
                XCTAssertTrue(underlying is PredictionServiceTestsError)
            default:
                XCTFail("Unexpected PredictionError case: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testRunPredictiveSimulationWrapsEncodingErrorsAndSkipsNetworkCall() async {
        let responseData = Data(
            """
            {
              "predicted_recovery_range": [45, 55],
              "predicted_zone": "ready",
              "explanation": "",
              "confidence_score": 0.5
            }
            """.utf8
        )
        let client = PredictionServiceAPIClientMock(responseData: responseData)
        let service = PredictionService(apiClient: client, isRuntimeConfigured: true)

        do {
            _ = try await service.runPredictiveSimulation(request: makeRequest(temperature: .nan))
            XCTFail("Expected PredictionError.networkError for encoding failure")
        } catch let error as PredictionError {
            switch error {
            case .networkError(let underlying):
                XCTAssertTrue(underlying is EncodingError)
            default:
                XCTFail("Unexpected PredictionError case: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        let invocationCount = await client.invocationCount()
        XCTAssertEqual(invocationCount, 0)
    }

    func testRunPredictiveSimulationShortCircuitsWhenRuntimeIsNotConfigured() async {
        let responseData = Data(
            """
            {
              "predicted_recovery_range": [45, 55],
              "predicted_zone": "ready",
              "explanation": "",
              "confidence_score": 0.5
            }
            """.utf8
        )
        let client = PredictionServiceAPIClientMock(responseData: responseData)
        let service = PredictionService(apiClient: client, isRuntimeConfigured: false)

        do {
            _ = try await service.runPredictiveSimulation(request: makeRequest())
            XCTFail("Expected APIClientError.runtimeNotConfigured")
        } catch let error as APIClientError {
            switch error {
            case .runtimeNotConfigured:
                break
            default:
                XCTFail("Unexpected APIClientError case: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        let invocationCount = await client.invocationCount()
        XCTAssertEqual(invocationCount, 0)
    }

    func testFoodPhotoAnalysisServiceUsesExpectedFunctionAndPayload() async throws {
        let responseData = Data(
            """
            {
              "detected_items": [
                {
                  "name": "Chicken breast",
                  "category": "protein",
                  "weight_g": 160,
                  "calories": 260,
                  "protein_g": 48,
                  "fat_g": 5,
                  "carbs_g": 0,
                  "fiber_g": 0,
                  "confidence": 0.91,
                  "notes": "Visible grill marks"
                }
              ],
              "total_macros": {
                "calories": 260,
                "protein_g": 48,
                "fat_g": 5,
                "carbs_g": 0,
                "fiber_g": 0
              },
              "meal_type": "lunch",
              "confidence": 0.87,
              "warnings": ["Portion size estimated from image"],
              "context_analysis": "Balanced high-protein meal.",
              "suggestions": ["Add vegetables"]
            }
            """.utf8
        )
        let client = PredictionServiceAPIClientMock(responseData: responseData)
        let service = FoodPhotoAnalysisService(apiClient: client)
        let loggedAt = Date(timeIntervalSince1970: 1_710_414_000)

        let response = try await service.analyzePhoto(
            imageDataURL: "data:image/jpeg;base64,ZmFrZQ==",
            loggedAt: loggedAt,
            recognizedText: "chicken bowl",
            barcodes: ["4601234567890"],
            mealContext: .restaurant,
            postWorkout: true,
            localeIdentifier: "ru-RU"
        )

        XCTAssertEqual(response.detectedItems.count, 1)
        XCTAssertEqual(response.detectedItems.first?.name, "Chicken breast")
        XCTAssertEqual(response.mealTypeRaw, "lunch")
        XCTAssertEqual(try XCTUnwrap(response.confidence), 0.87, accuracy: 0.0001)

        let firstInvocation = await client.firstInvocation()
        let invocation = try XCTUnwrap(firstInvocation)
        XCTAssertEqual(invocation.name, "analyze-food-image")
        XCTAssertEqual(invocation.maxAttempts, 2)

        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: invocation.body) as? [String: Any]
        )
        XCTAssertEqual(payload["image_base64"] as? String, "data:image/jpeg;base64,ZmFrZQ==")
        XCTAssertEqual(payload["context"] as? String, "restaurant")
        XCTAssertEqual(payload["post_workout"] as? Bool, true)
        XCTAssertEqual(payload["recognized_text"] as? String, "chicken bowl")
        XCTAssertEqual(payload["locale"] as? String, "ru-RU")
        XCTAssertEqual(payload["barcodes"] as? [String], ["4601234567890"])
        XCTAssertNotNil(payload["timestamp"] as? String)
    }

    func testFoodPhotoAnalysisServiceWrapsNonAPIErrors() async {
        let client = PredictionServiceAPIClientMock(errorToThrow: PredictionServiceTestsError.transportFailed)
        let service = FoodPhotoAnalysisService(apiClient: client)

        do {
            _ = try await service.analyzePhoto(
                imageDataURL: "data:image/jpeg;base64,ZmFrZQ==",
                loggedAt: Date(),
                recognizedText: nil,
                barcodes: []
            )
            XCTFail("Expected FoodPhotoAnalysisServiceError.transport")
        } catch let error as FoodPhotoAnalysisServiceError {
            switch error {
            case .transport(let underlying):
                XCTAssertTrue(underlying is PredictionServiceTestsError)
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
