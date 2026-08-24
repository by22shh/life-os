import Foundation

protocol TrainingCalendarRouteAPIClient: Sendable {
    func fetchWorkoutCalendar(
        from fromDay: String,
        to toDay: String
    ) async throws -> WorkoutCalendarRemoteResponse
}

protocol SleepCalendarRouteAPIClient: Sendable {
    func fetchSleepCalendar(
        from fromDay: String,
        to toDay: String
    ) async throws -> SleepCalendarRemoteResponse
}

struct WorkoutCalendarRemoteResponse: Decodable, Sendable {
    let from: String
    let to: String
    let days: [WorkoutCalendarRemoteDay]
}

struct WorkoutCalendarRemoteDay: Decodable, Sendable {
    let date: String
    let loggedCount: Int
    let plannedCount: Int
    let completedPlannedCount: Int
    let totalDurationMinutes: Int
    let totalTrimpScore: Double
    let hasLoggedWorkout: Bool
    let hasPlannedWorkout: Bool

    private enum CodingKeys: String, CodingKey {
        case date
        case loggedCount = "logged_count"
        case plannedCount = "planned_count"
        case completedPlannedCount = "completed_planned_count"
        case totalDurationMinutes = "total_duration_minutes"
        case totalTrimpScore = "total_trimp_score"
        case hasLoggedWorkout = "has_logged_workout"
        case hasPlannedWorkout = "has_planned_workout"
    }
}

struct SleepCalendarRemoteResponse: Decodable, Sendable {
    let from: String
    let to: String
    let days: [SleepCalendarRemoteDay]
}

struct SleepCalendarRemoteDay: Decodable, Sendable {
    let date: String
    let sleepScore: Double?
    let sleepDurationHours: Double?
    let status: String

    private enum CodingKeys: String, CodingKey {
        case date
        case sleepScore = "sleep_score"
        case sleepDurationHours = "sleep_duration_hours"
        case status
    }
}

extension APIClient: TrainingCalendarRouteAPIClient, SleepCalendarRouteAPIClient {
    func fetchWorkoutCalendar(
        from fromDay: String,
        to toDay: String
    ) async throws -> WorkoutCalendarRemoteResponse {
        try await callEdgeRoute(
            function: "api-workouts-calendar",
            route: "",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "from", value: fromDay),
                URLQueryItem(name: "to", value: toDay)
            ],
            body: nil,
            headers: [:],
            maxAttempts: 3
        )
    }

    func fetchSleepCalendar(
        from fromDay: String,
        to toDay: String
    ) async throws -> SleepCalendarRemoteResponse {
        try await callEdgeRoute(
            function: "api-sleep-calendar",
            route: "",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "from", value: fromDay),
                URLQueryItem(name: "to", value: toDay)
            ],
            body: nil,
            headers: [:],
            maxAttempts: 3
        )
    }
}
