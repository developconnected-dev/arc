import Foundation

/// Communicates with the Arc backend (Cloudflare Worker) which proxies to flight data APIs.
actor FlightAPIClient {
    static let shared = FlightAPIClient()

    private var baseURL: URL {
        let endpoint = UserDefaults.standard.string(forKey: "apiEndpoint") ?? "https://arc-backend.owncalai.workers.dev"
        return URL(string: endpoint) ?? URL(string: "https://arc-backend.owncalai.workers.dev")!
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
}
