import Foundation

enum PredictionError: Error {
    case invalidURL
    case networkError(Error)
    case invalidResponse
    case decodingError(Error)
    case serverError(String)
}

protocol PredictionAPIClient: Sendable {
    func callEdgeFunction<T: Decodable & Sendable>(
        _ name: String,
        body: Data,
        headers: [String: String],
        maxAttempts: Int
    ) async throws -> T
}

protocol PredictionServiceProtocol: Sendable {
    func runPredictiveSimulation(request: PredictiveScenarioRequest) async throws -> PredictiveScenarioResponse
}

struct PredictionService: PredictionServiceProtocol, Sendable {
    private let apiClient: any PredictionAPIClient
    private let isRuntimeConfigured: Bool

    init(
        apiClient: any PredictionAPIClient = APIClient(),
        isRuntimeConfigured: Bool = SupabaseConfig.isRuntimeConfigured
    ) {
        self.apiClient = apiClient
        self.isRuntimeConfigured = isRuntimeConfigured
    }

    func runPredictiveSimulation(request: PredictiveScenarioRequest) async throws -> PredictiveScenarioResponse {
        guard isRuntimeConfigured else {
            throw APIClientError.runtimeNotConfigured
        }

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(request)

            // Invoke edge function using the centralized APIClient via explicit hyphenated route
            return try await apiClient.callEdgeFunction(
                "api-insights-predict",
                body: data,
                headers: [:],
                maxAttempts: 3
            )
        } catch let error as APIClientError {
            throw error
        } catch {
            throw PredictionError.networkError(error)
        }
    }
}
