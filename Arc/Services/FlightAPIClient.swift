import Foundation

/// Communicates with the Arc backend (Cloudflare Worker) which proxies to flight data APIs.
actor FlightAPIClient {
    static let shared = FlightAPIClient()

    private var baseURL: URL {
        let endpoint = UserDefaults.standard.string(forKey: "apiEndpoint") ?? "https://your-worker.workers.dev"
        return URL(string: endpoint) ?? URL(string: "https://your-worker.workers.dev")!
    }
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    // MARK: - Flight Search

    struct FlightSearchResult: Codable, Sendable {
        let flight_number: String
        let airline_name: String
        let airline_iata: String
        let dep_iata: String
        let arr_iata: String
        let dep_city: String?
        let arr_city: String?
        let dep_scheduled: String
        let arr_scheduled: String
        let dep_actual: String?
        let arr_actual: String?
        let status: String
        let dep_gate: String?
        let dep_terminal: String?
        let arr_gate: String?
        let arr_terminal: String?
        let arr_baggage: String?
        let delay: Int?
        let aircraft_type: String?
        let aircraft_registration: String?
        let dep_lat: Double?
        let dep_lon: Double?
        let arr_lat: Double?
        let arr_lon: Double?
    }

    func searchFlight(number: String, date: String) async throws -> [FlightSearchResult] {
        let url = baseURL.appending(path: "/flight")
            .appending(queryItems: [
                URLQueryItem(name: "number", value: number),
                URLQueryItem(name: "date", value: date),
            ])
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode([FlightSearchResult].self, from: data)
    }

    // MARK: - Inbound aircraft ("Where's My Plane")

    /// All legs flown by a given tail number on a given date, per the Worker's
    /// `/inbound` endpoint (AeroDataBox `/flights/reg/{reg}/{date}`).
    func inboundLegs(registration: String, date: String) async throws -> [FlightSearchResult] {
        let url = baseURL.appending(path: "/inbound")
            .appending(queryItems: [
                URLQueryItem(name: "reg", value: registration),
                URLQueryItem(name: "date", value: date),
            ])
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        return (try? JSONDecoder().decode([FlightSearchResult].self, from: data)) ?? []
    }

    // MARK: - Live Position (OpenSky)

    struct LivePosition: Codable, Sendable {
        let icao24: String
        let lat: Double
        let lon: Double
        let altitude: Double   // meters
        let velocity: Double   // m/s
        let heading: Double    // degrees
        let on_ground: Bool
    }

    func livePosition(icao24: String) async throws -> LivePosition? {
        let url = baseURL.appending(path: "/position")
            .appending(queryItems: [URLQueryItem(name: "icao24", value: icao24)])
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return try JSONDecoder().decode(LivePosition.self, from: data)
    }

    // MARK: - Security Wait Times

    struct SecurityInfo: Codable, Sendable {
        let iata: String
        let securityMinutes: Int?
        let source: String?
    }

    func securityWaitTime(iata: String) async throws -> SecurityInfo? {
        let url = baseURL.appending(path: "/security/\(iata)")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return try JSONDecoder().decode(SecurityInfo.self, from: data)
    }
}
