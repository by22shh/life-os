import Foundation
@preconcurrency import CoreLocation

/// Protocol for fetching environmental data
protocol EnvironmentServiceProtocol: Sendable {
    /// Resolves the user's current city and fetches environmental context like weather, pressure, AQI.
    func fetchCurrentEnvironment() async throws -> EnvironmentalContext
    /// Resolves environmental context for a specific calendar day.
    func fetchEnvironment(for date: Date) async throws -> EnvironmentalContext
}

extension EnvironmentServiceProtocol {
    func fetchEnvironment(for date: Date) async throws -> EnvironmentalContext {
        _ = date
        return try await fetchCurrentEnvironment()
    }
}

/// Service responsible for gathering environmental data from the user's surroundings.
final class EnvironmentService: NSObject, EnvironmentServiceProtocol, CLLocationManagerDelegate, @unchecked Sendable {
    private struct PendingLocationRequest {
        let continuation: CheckedContinuation<CLLocation, Error>
        let timeoutTask: Task<Void, Never>
    }

    private static let locationRequestTimeoutNanoseconds: UInt64 = 20_000_000_000
#if DEBUG
    private static let testAuthorizationStatusOverride = LockedTestOverride<CLAuthorizationStatus>()
    private static let testRequestLocationActionOverride = LockedTestOverride<@Sendable () -> Void>()
    private static let testRequestWhenInUseAuthorizationOverride = LockedTestOverride<@Sendable () -> Void>()
    private static let testReverseGeocodeOverride = LockedTestOverride<@Sendable (CLLocation) async throws -> [CLPlacemark]>()
    private static let testFetchEnvironmentOverride = LockedTestOverride<@Sendable (CLLocation, String) async throws -> EnvironmentalContext>()
#endif

    private let locationManager = CLLocationManager()
    private let stateLock = NSLock()
    private var locationContinuations: [UUID: PendingLocationRequest] = [:]
    private var authorizationContinuations: [CheckedContinuation<CLAuthorizationStatus, Never>] = []
    
    override init() {
        super.init()
        locationManager.delegate = self
        // Significant location changes are enough for city-level weather/AQI without draining battery
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }
    
    func fetchCurrentEnvironment() async throws -> EnvironmentalContext {
        try await fetchEnvironment(for: Date())
    }

    func fetchEnvironment(for date: Date) async throws -> EnvironmentalContext {
        try await fetchEnvironment(
            for: date,
            requestLocationBlock: { try await self.requestLocation() },
            resolveCityBlock: { try await self.resolveCity(from: $0) },
            fetchEnvironmentBlock: resolvedFetchEnvironmentAction()
        )
    }

    private func fetchEnvironment(
        for date: Date,
        requestLocationBlock: @Sendable () async throws -> CLLocation,
        resolveCityBlock: @Sendable (CLLocation) async throws -> String,
        fetchEnvironmentBlock: @Sendable (CLLocation, String, Date) async throws -> EnvironmentalContext
    ) async throws -> EnvironmentalContext {
        let location = try await requestLocationBlock()
        let city = try await resolveCityBlock(location)
        return try await fetchEnvironmentBlock(location, city, date)
    }

    private func resolvedFetchEnvironmentAction() -> @Sendable (CLLocation, String, Date) async throws -> EnvironmentalContext {
#if DEBUG
        if let override = Self.testFetchEnvironmentOverride.value {
            return { location, city, _ in
                try await override(location, city)
            }
        }
        if Self.isRunningTests {
            return { location, city, date in
                Self.defaultTestEnvironment(for: location, city: city, date: date)
            }
        }
#endif
        return { location, city, date in
            try await OpenMeteoEnvironmentProvider().fetchEnvironment(for: location, city: city, date: date)
        }
    }
    
    // MARK: - Location Management
    
    private func requestLocation() async throws -> CLLocation {
#if DEBUG
        let currentStatus = Self.testAuthorizationStatusOverride.value ?? locationManager.authorizationStatus
        let requestLocationAction: @Sendable () -> Void = Self.testRequestLocationActionOverride.value ?? {
            self.locationManager.requestLocation()
        }
#else
        let currentStatus = locationManager.authorizationStatus
        let requestLocationAction: @Sendable () -> Void = {
            self.locationManager.requestLocation()
        }
#endif
        return try await requestLocation(
            currentStatus: currentStatus,
            requestAuthorizationBlock: { await self.requestAuthorization() },
            requestLocationAction: requestLocationAction,
            timeoutNanoseconds: Self.locationRequestTimeoutNanoseconds
        )
    }

    private func requestLocation(
        currentStatus: CLAuthorizationStatus,
        requestAuthorizationBlock: @Sendable @escaping () async -> CLAuthorizationStatus,
        requestLocationAction: @Sendable @escaping () -> Void,
        timeoutNanoseconds: UInt64
    ) async throws -> CLLocation {
        var status = currentStatus
        if status == .notDetermined {
            status = await requestAuthorizationBlock()
        }

        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            throw EnvironmentError.locationPermissionDenied
        }

        return try await withCheckedThrowingContinuation { continuation in
            let requestID = UUID()
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard let self else { return }
                let timedOut = removeLocationContinuation(for: requestID)
                timedOut?.resume(throwing: EnvironmentError.locationRequestTimedOut)
            }

            let shouldRequestLocation = withStateLock {
                locationContinuations[requestID] = PendingLocationRequest(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                return locationContinuations.count == 1
            }
            if shouldRequestLocation {
                requestLocationAction() // Single request for all pending callers
            }
        }
    }

    private func requestAuthorization() async -> CLAuthorizationStatus {
#if DEBUG
        let currentStatus: CLAuthorizationStatus
        if let override = Self.testAuthorizationStatusOverride.value {
            currentStatus = override
        } else {
            currentStatus = locationManager.authorizationStatus
        }

        let requestWhenInUseAuthorization: @Sendable () -> Void
        if let override = Self.testRequestWhenInUseAuthorizationOverride.value {
            requestWhenInUseAuthorization = override
        } else {
            requestWhenInUseAuthorization = { self.locationManager.requestWhenInUseAuthorization() }
        }
#else
        let currentStatus = locationManager.authorizationStatus
        let requestWhenInUseAuthorization: @Sendable () -> Void = {
            self.locationManager.requestWhenInUseAuthorization()
        }
#endif
        return await requestAuthorization(
            currentStatus: currentStatus,
            requestWhenInUseAuthorization: requestWhenInUseAuthorization
        )
    }

    private func requestAuthorization(
        currentStatus: CLAuthorizationStatus,
        requestWhenInUseAuthorization: @Sendable @escaping () -> Void
    ) async -> CLAuthorizationStatus {
        let current = currentStatus
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            let shouldRequestAuthorization = withStateLock {
                authorizationContinuations.append(continuation)
                return authorizationContinuations.count == 1
            }
            if shouldRequestAuthorization {
                requestWhenInUseAuthorization()
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let continuations = drainLocationContinuations()
        guard !continuations.isEmpty else { return }
        guard let location = locations.first else {
            for continuation in continuations {
                continuation.resume(throwing: EnvironmentError.locationUnavailable)
            }
            return
        }
        for continuation in continuations {
            continuation.resume(returning: location)
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let continuations = drainLocationContinuations()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let continuations = drainAuthorizationContinuations()
        guard !continuations.isEmpty else { return }
        let status = manager.authorizationStatus
        continuations.forEach { $0.resume(returning: status) }
    }
    
    // MARK: - City Resolution
    
    private func resolveCity(from location: CLLocation) async throws -> String {
        let reverseGeocode = resolvedReverseGeocodeAction()
        return try await resolveCity(
            from: location,
            reverseGeocode: reverseGeocode
        )
    }

    private func resolvedReverseGeocodeAction() -> @Sendable (CLLocation) async throws -> [CLPlacemark] {
#if DEBUG
        if let override = Self.testReverseGeocodeOverride.value {
            return override
        } else {
            return { try await CLGeocoder().reverseGeocodeLocation($0) }
        }
#else
        return { try await CLGeocoder().reverseGeocodeLocation($0) }
#endif
    }

    private func resolveCity(
        from location: CLLocation,
        reverseGeocode: @Sendable @escaping (CLLocation) async throws -> [CLPlacemark]
    ) async throws -> String {
        let placemarks = try await reverseGeocode(location)
        return Self.resolveCity(locality: placemarks.first?.locality)
    }

    nonisolated private static func resolveCity(locality: String?) -> String {
        if let city = locality {
            return city
        } else {
            return "Unknown"
        }
    }

#if DEBUG
    nonisolated private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    nonisolated private static func defaultTestEnvironment(
        for location: CLLocation,
        city: String,
        date: Date
    ) -> EnvironmentalContext {
        let normalizedTemperature = max(-15.0, min(35.0, 22.0 - abs(location.coordinate.latitude) / 10.0))
        let normalizedPressure = 1015.0 - min(12.0, abs(location.coordinate.longitude) / 20.0)
        return EnvironmentalContext(
            weatherCondition: "Clear",
            temperatureC: normalizedTemperature,
            pressureHpa: normalizedPressure,
            pressureDeltaHpa24h: -1.8,
            aqi: 36,
            indoorCo2Ppm: nil,
            moonPhase: OpenMeteoEnvironmentProvider.moonPhase(for: date),
            daylightHours: 10.5,
            city: city
        )
    }
#endif

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func drainLocationContinuations() -> [CheckedContinuation<CLLocation, Error>] {
        withStateLock {
            let continuations = locationContinuations.values.map(\.continuation)
            locationContinuations.values.forEach { $0.timeoutTask.cancel() }
            locationContinuations.removeAll()
            return continuations
        }
    }

    private func removeLocationContinuation(for id: UUID) -> CheckedContinuation<CLLocation, Error>? {
        withStateLock {
            guard let pending = locationContinuations.removeValue(forKey: id) else {
                return nil
            }
            pending.timeoutTask.cancel()
            return pending.continuation
        }
    }

    private func drainAuthorizationContinuations() -> [CheckedContinuation<CLAuthorizationStatus, Never>] {
        withStateLock {
            let continuations = authorizationContinuations
            authorizationContinuations.removeAll()
            return continuations
        }
    }
}

#if DEBUG
extension EnvironmentService {
    func _testFetchCurrentEnvironment(
        requestLocationBlock: @Sendable () async throws -> CLLocation,
        resolveCityBlock: @Sendable (CLLocation) async throws -> String,
        fetchEnvironmentBlock: @Sendable (CLLocation, String) async throws -> EnvironmentalContext
    ) async throws -> EnvironmentalContext {
        try await fetchEnvironment(
            for: Date(),
            requestLocationBlock: requestLocationBlock,
            resolveCityBlock: resolveCityBlock,
            fetchEnvironmentBlock: { location, city, _ in
                try await fetchEnvironmentBlock(location, city)
            }
        )
    }

    func _testFetchEnvironment(
        for date: Date,
        requestLocationBlock: @Sendable () async throws -> CLLocation,
        resolveCityBlock: @Sendable (CLLocation) async throws -> String,
        fetchEnvironmentBlock: @Sendable (CLLocation, String, Date) async throws -> EnvironmentalContext
    ) async throws -> EnvironmentalContext {
        try await fetchEnvironment(
            for: date,
            requestLocationBlock: requestLocationBlock,
            resolveCityBlock: resolveCityBlock,
            fetchEnvironmentBlock: fetchEnvironmentBlock
        )
    }

    func _testRequestLocation(
        currentStatus: CLAuthorizationStatus,
        requestAuthorizationBlock: @Sendable @escaping () async -> CLAuthorizationStatus,
        requestLocationAction: @Sendable @escaping () -> Void,
        timeoutNanoseconds: UInt64
    ) async throws -> CLLocation {
        try await requestLocation(
            currentStatus: currentStatus,
            requestAuthorizationBlock: requestAuthorizationBlock,
            requestLocationAction: requestLocationAction,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    func _testRequestAuthorization(
        currentStatus: CLAuthorizationStatus,
        requestWhenInUseAuthorization: @Sendable @escaping () -> Void
    ) async -> CLAuthorizationStatus {
        await requestAuthorization(
            currentStatus: currentStatus,
            requestWhenInUseAuthorization: requestWhenInUseAuthorization
        )
    }

    func _testResolveCity(
        from location: CLLocation,
        reverseGeocode: @Sendable @escaping (CLLocation) async throws -> [CLPlacemark]
    ) async throws -> String {
        try await resolveCity(from: location, reverseGeocode: reverseGeocode)
    }

    func _testRequestLocationViaPublicWrapper() async throws -> CLLocation {
        try await requestLocation()
    }

    func _testRequestAuthorizationViaPublicWrapper() async -> CLAuthorizationStatus {
        await requestAuthorization()
    }

    func _testResolveCityViaPublicWrapper(from location: CLLocation) async throws -> String {
        try await resolveCity(from: location)
    }

    nonisolated static func _testSetAuthorizationStatusOverride(_ status: CLAuthorizationStatus?) {
        testAuthorizationStatusOverride.value = status
    }

    nonisolated static func _testSetRequestLocationActionOverride(_ action: (@Sendable () -> Void)?) {
        testRequestLocationActionOverride.value = action
    }

    nonisolated static func _testSetRequestWhenInUseAuthorizationOverride(_ action: (@Sendable () -> Void)?) {
        testRequestWhenInUseAuthorizationOverride.value = action
    }

    nonisolated static func _testSetReverseGeocodeOverride(
        _ action: (@Sendable (CLLocation) async throws -> [CLPlacemark])?
    ) {
        testReverseGeocodeOverride.value = action
    }

    nonisolated static func _testSetFetchEnvironmentOverride(
        _ action: (@Sendable (CLLocation, String) async throws -> EnvironmentalContext)?
    ) {
        testFetchEnvironmentOverride.value = action
    }

    nonisolated static func _testResolvedCity(locality: String?) -> String {
        resolveCity(locality: locality)
    }

    func _testResolveReverseGeocodeActionForCoverage() {
        _ = resolvedReverseGeocodeAction()
    }

    nonisolated static func _testResetOverrides() {
        testAuthorizationStatusOverride.value = nil
        testRequestLocationActionOverride.value = nil
        testRequestWhenInUseAuthorizationOverride.value = nil
        testReverseGeocodeOverride.value = nil
        testFetchEnvironmentOverride.value = nil
    }
}
#endif

enum EnvironmentError: Error {
    case locationPermissionDenied
    case locationUnavailable
    case locationRequestTimedOut
    case environmentDataUnavailable
}

private struct OpenMeteoEnvironmentProvider: Sendable {
    private enum DayKind {
        case historical
        case current
        case forecast
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchEnvironment(
        for location: CLLocation,
        city: String,
        date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> EnvironmentalContext {
        switch dayKind(for: date, now: now, calendar: calendar) {
        case .current:
            return try await fetchCurrentEnvironment(for: location, city: city, date: date)
        case .historical:
            return try await fetchDayEnvironment(for: location, city: city, date: date, dayKind: .historical, calendar: calendar)
        case .forecast:
            return try await fetchDayEnvironment(for: location, city: city, date: date, dayKind: .forecast, calendar: calendar)
        }
    }

    private func fetchCurrentEnvironment(
        for location: CLLocation,
        city: String,
        date: Date
    ) async throws -> EnvironmentalContext {
        async let weatherTask = fetchWeather(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        async let airQualityTask = fetchAirQuality(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)

        let weather = try? await weatherTask
        let airQuality = try? await airQualityTask

        guard weather != nil || airQuality != nil else {
            throw EnvironmentError.environmentDataUnavailable
        }

        let latestPressure = weather?.current?.pressureMsl ?? Self.lastValue(weather?.hourly?.pressureMsl)
        let pressure24hAgo = Self.firstValue(weather?.hourly?.pressureMsl)
        let pressureDelta: Double? = {
            guard let latestPressure, let pressure24hAgo else { return nil }
            return latestPressure - pressure24hAgo
        }()

        return EnvironmentalContext(
            weatherCondition: weather?.current?.weatherCode.map(Self.weatherCondition),
            temperatureC: weather?.current?.temperature2m,
            pressureHpa: latestPressure,
            pressureDeltaHpa24h: pressureDelta,
            aqi: airQuality?.current?.usAqi.flatMap { Int($0.rounded()) },
            indoorCo2Ppm: nil,
            moonPhase: Self.moonPhase(for: date),
            daylightHours: Self.firstValue(weather?.daily?.daylightDuration).map { $0 / 3600.0 },
            city: city
        )
    }

    private func fetchDayEnvironment(
        for location: CLLocation,
        city: String,
        date: Date,
        dayKind: DayKind,
        calendar: Calendar
    ) async throws -> EnvironmentalContext {
        let dayKey = Self.dayKey(for: date, calendar: calendar)
        async let weatherTask = fetchWeather(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            dayKey: dayKey,
            dayKind: dayKind
        )
        async let airQualityTask = fetchAirQuality(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            dayKey: dayKey
        )

        let weather = try? await weatherTask
        let airQuality = try? await airQualityTask

        guard weather != nil || airQuality != nil else {
            throw EnvironmentError.environmentDataUnavailable
        }

        let latestPressure = Self.lastValue(weather?.hourly?.pressureMsl)
        let earliestPressure = Self.firstValue(weather?.hourly?.pressureMsl)
        let pressureDelta: Double? = {
            guard let latestPressure, let earliestPressure else { return nil }
            return latestPressure - earliestPressure
        }()

        let representativeWeatherCode = Self.firstValue(weather?.daily?.weatherCode)
            ?? Self.representativeValue(times: weather?.hourly?.time, values: weather?.hourly?.weatherCode)
        let representativeTemperature = Self.representativeValue(
            times: weather?.hourly?.time,
            values: weather?.hourly?.temperature2m
        )
        let representativeAqi = Self.representativeValue(
            times: airQuality?.hourly?.time,
            values: airQuality?.hourly?.usAqi
        )

        return EnvironmentalContext(
            weatherCondition: representativeWeatherCode.map(Self.weatherCondition),
            temperatureC: representativeTemperature,
            pressureHpa: latestPressure,
            pressureDeltaHpa24h: pressureDelta,
            aqi: representativeAqi.map { Int($0.rounded()) },
            indoorCo2Ppm: nil,
            moonPhase: Self.moonPhase(for: date),
            daylightHours: Self.firstValue(weather?.daily?.daylightDuration).map { $0 / 3600.0 },
            city: city
        )
    }

    private func fetchWeather(latitude: Double, longitude: Double) async throws -> WeatherResponse {
        let url = try makeURL(
            baseURL: "https://api.open-meteo.com/v1/forecast",
            queryItems: [
                URLQueryItem(name: "latitude", value: String(latitude)),
                URLQueryItem(name: "longitude", value: String(longitude)),
                URLQueryItem(name: "current", value: "temperature_2m,pressure_msl,weather_code"),
                URLQueryItem(name: "hourly", value: "pressure_msl"),
                URLQueryItem(name: "daily", value: "daylight_duration"),
                URLQueryItem(name: "past_hours", value: "24"),
                URLQueryItem(name: "forecast_hours", value: "1"),
                URLQueryItem(name: "timezone", value: "auto")
            ]
        )
        return try await fetch(WeatherResponse.self, from: url)
    }

    private func fetchWeather(
        latitude: Double,
        longitude: Double,
        dayKey: String,
        dayKind: DayKind
    ) async throws -> WeatherResponse {
        let baseURL: String
        switch dayKind {
        case .historical:
            baseURL = "https://archive-api.open-meteo.com/v1/archive"
        case .forecast, .current:
            baseURL = "https://api.open-meteo.com/v1/forecast"
        }

        let url = try makeURL(
            baseURL: baseURL,
            queryItems: [
                URLQueryItem(name: "latitude", value: String(latitude)),
                URLQueryItem(name: "longitude", value: String(longitude)),
                URLQueryItem(name: "hourly", value: "temperature_2m,pressure_msl,weather_code"),
                URLQueryItem(name: "daily", value: "daylight_duration,weather_code"),
                URLQueryItem(name: "start_date", value: dayKey),
                URLQueryItem(name: "end_date", value: dayKey),
                URLQueryItem(name: "timezone", value: "auto")
            ]
        )
        return try await fetch(WeatherResponse.self, from: url)
    }

    private func fetchAirQuality(latitude: Double, longitude: Double) async throws -> AirQualityResponse {
        let url = try makeURL(
            baseURL: "https://air-quality-api.open-meteo.com/v1/air-quality",
            queryItems: [
                URLQueryItem(name: "latitude", value: String(latitude)),
                URLQueryItem(name: "longitude", value: String(longitude)),
                URLQueryItem(name: "current", value: "us_aqi,carbon_dioxide"),
                URLQueryItem(name: "timezone", value: "auto")
            ]
        )
        return try await fetch(AirQualityResponse.self, from: url)
    }

    private func fetchAirQuality(
        latitude: Double,
        longitude: Double,
        dayKey: String
    ) async throws -> AirQualityResponse {
        let url = try makeURL(
            baseURL: "https://air-quality-api.open-meteo.com/v1/air-quality",
            queryItems: [
                URLQueryItem(name: "latitude", value: String(latitude)),
                URLQueryItem(name: "longitude", value: String(longitude)),
                URLQueryItem(name: "hourly", value: "us_aqi"),
                URLQueryItem(name: "start_date", value: dayKey),
                URLQueryItem(name: "end_date", value: dayKey),
                URLQueryItem(name: "timezone", value: "auto")
            ]
        )
        return try await fetch(AirQualityResponse.self, from: url)
    }

    private func fetch<Response: Decodable>(_ type: Response.Type, from url: URL) async throws -> Response {
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private func makeURL(baseURL: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(string: baseURL) else {
            throw URLError(.badURL)
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        return url
    }

    private func dayKind(for date: Date, now: Date, calendar: Calendar) -> DayKind {
        let targetDay = calendar.startOfDay(for: date)
        let currentDay = calendar.startOfDay(for: now)
        if targetDay < currentDay {
            return .historical
        }
        if targetDay > currentDay {
            return .forecast
        }
        return .current
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard
            let year = components.year,
            let month = components.month,
            let day = components.day
        else {
            return ""
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func weatherCondition(for code: Int) -> String {
        switch code {
        case 0:
            return "Clear"
        case 1, 2:
            return "Partly Cloudy"
        case 3:
            return "Overcast"
        case 45, 48:
            return "Fog"
        case 51, 53, 55, 56, 57:
            return "Drizzle"
        case 61, 63, 65, 66, 67, 80, 81, 82:
            return "Rain"
        case 71, 73, 75, 77, 85, 86:
            return "Snow"
        case 95, 96, 99:
            return "Thunderstorm"
        default:
            return "Unknown"
        }
    }

    fileprivate static func moonPhase(for date: Date) -> String {
        let synodicMonth = 29.53058867
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = 2000
        components.month = 1
        components.day = 6
        components.hour = 18
        components.minute = 14
        let referenceNewMoon = components.date ?? Date(timeIntervalSince1970: 947182440)

        let daysSinceReference = date.timeIntervalSince(referenceNewMoon) / 86_400
        let rawPhase = daysSinceReference.truncatingRemainder(dividingBy: synodicMonth)
        let phase = rawPhase >= 0 ? rawPhase : rawPhase + synodicMonth

        switch phase {
        case 0..<1.84566:
            return "New Moon"
        case 1.84566..<5.53699:
            return "Waxing Crescent"
        case 5.53699..<9.22831:
            return "First Quarter"
        case 9.22831..<12.91963:
            return "Waxing Gibbous"
        case 12.91963..<16.61096:
            return "Full Moon"
        case 16.61096..<20.30228:
            return "Waning Gibbous"
        case 20.30228..<23.99361:
            return "Last Quarter"
        case 23.99361..<27.68493:
            return "Waning Crescent"
        default:
            return "New Moon"
        }
    }

    private static func representativeValue<Value>(
        times: [String]?,
        values: [Value?]?,
        preferredHour: Int = 12
    ) -> Value? {
        guard
            let times,
            let values
        else {
            return nil
        }

        let candidates = zip(times, values).compactMap { time, value in
            value.map { (time, $0) }
        }
        guard !candidates.isEmpty else { return nil }

        return candidates.min { lhs, rhs in
            let lhsDistance = abs(hourComponent(from: lhs.0) - preferredHour)
            let rhsDistance = abs(hourComponent(from: rhs.0) - preferredHour)
            if lhsDistance == rhsDistance {
                return lhs.0 < rhs.0
            }
            return lhsDistance < rhsDistance
        }?.1
    }

    private static func firstValue<Value>(_ values: [Value?]?) -> Value? {
        values?.compactMap { $0 }.first
    }

    private static func lastValue<Value>(_ values: [Value?]?) -> Value? {
        values?.reversed().compactMap { $0 }.first
    }

    private static func hourComponent(from timestamp: String) -> Int {
        guard
            let timeSeparatorIndex = timestamp.lastIndex(of: "T"),
            let hourRangeEnd = timestamp.index(
                timeSeparatorIndex,
                offsetBy: 3,
                limitedBy: timestamp.endIndex
            )
        else {
            return 12
        }

        let hourStart = timestamp.index(after: timeSeparatorIndex)
        let hourString = String(timestamp[hourStart..<hourRangeEnd])
        return Int(hourString) ?? 12
    }

    private struct WeatherResponse: Decodable {
        let current: Current?
        let hourly: Hourly?
        let daily: Daily?

        struct Current: Decodable {
            let temperature2m: Double?
            let pressureMsl: Double?
            let weatherCode: Int?

            enum CodingKeys: String, CodingKey {
                case temperature2m = "temperature_2m"
                case pressureMsl = "pressure_msl"
                case weatherCode = "weather_code"
            }
        }

        struct Hourly: Decodable {
            let time: [String]?
            let temperature2m: [Double?]?
            let pressureMsl: [Double?]?
            let weatherCode: [Int?]?

            enum CodingKeys: String, CodingKey {
                case time
                case temperature2m = "temperature_2m"
                case pressureMsl = "pressure_msl"
                case weatherCode = "weather_code"
            }
        }

        struct Daily: Decodable {
            let daylightDuration: [Double?]?
            let weatherCode: [Int?]?

            enum CodingKeys: String, CodingKey {
                case daylightDuration = "daylight_duration"
                case weatherCode = "weather_code"
            }
        }
    }

    private struct AirQualityResponse: Decodable {
        let current: Current?
        let hourly: Hourly?

        struct Current: Decodable {
            let usAqi: Double?

            enum CodingKeys: String, CodingKey {
                case usAqi = "us_aqi"
            }
        }

        struct Hourly: Decodable {
            let time: [String]?
            let usAqi: [Double?]?

            enum CodingKeys: String, CodingKey {
                case time
                case usAqi = "us_aqi"
            }
        }
    }
}
