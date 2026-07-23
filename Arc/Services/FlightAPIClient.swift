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
        let aircraft_icao24: String?
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

    // MARK: - Airport Intelligence

    struct AirportStatus: Codable, Sendable {
        struct Weather: Codable, Sendable {
            let category: String?
            let tempC: Double?
            let windKt: Double?
            let gustKt: Double?
            let visibility: String?
            let wx: String?
            let raw: String?
        }
        struct FaaDelay: Codable, Sendable {
            let type: String
            let reason: String
            let avgMinutes: Int?
        }
        let iata: String
        let severity: String          // "normal" | "minor" | "major" | "unknown"
        let headline: String
        let reasons: [String]?
        let weather: Weather?
        let faa: FaaDelay?
        let securityMinutes: Int?
        let updatedAt: String?
    }

    func airportStatus(iata: String, icao: String?, country: String?) async throws -> AirportStatus? {
        var url = baseURL.appending(path: "/airport/\(iata)")
        var items: [URLQueryItem] = []
        if let icao, !icao.isEmpty { items.append(.init(name: "icao", value: icao)) }
        if let country, !country.isEmpty { items.append(.init(name: "country", value: country)) }
        if !items.isEmpty { url = url.appending(queryItems: items) }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return try JSONDecoder().decode(AirportStatus.self, from: data)
    }

    // MARK: - Gate coordinates & observations

    struct Gate: Codable, Sendable {
        let ref: String
        let lat: Double
        let lon: Double
    }

    /// Gate coordinates for an airport. Worker cache first (Supabase-backed,
    /// ~90-day TTL); on a miss, fetches OpenStreetMap's Overpass API directly
    /// from the device — Overpass rejects Cloudflare egress IPs, so this leg
    /// deliberately runs client-side — then stores the result back through
    /// the Worker so the next lookup (any device) is a cache hit.
    func gates(iata: String, lat: Double, lon: Double) async -> [Gate] {
        // 1. Cache
        if let cached = try? await fetchGatesFromWorker(iata: iata), !cached.isEmpty {
            return cached
        }
        // 2. Overpass direct
        guard let fresh = try? await fetchGatesFromOverpass(lat: lat, lon: lon), !fresh.isEmpty else {
            return []
        }
        // 3. Store back (best-effort)
        if let body = try? JSONSerialization.data(withJSONObject: [
            "iata": iata,
            "gates": fresh.map { ["ref": $0.ref, "lat": $0.lat, "lon": $0.lon] },
        ]) {
            await postJSON(path: "/gates/store", data: body)
        }
        return fresh
    }

    private func fetchGatesFromWorker(iata: String) async throws -> [Gate] {
        let url = baseURL.appending(path: "/gates/\(iata)")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        return try JSONDecoder().decode([Gate].self, from: data)
    }

    private func fetchGatesFromOverpass(lat: Double, lon: Double) async throws -> [Gate] {
        var req = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("ArcFlightTracker/1.0 (personal project)", forHTTPHeaderField: "User-Agent")
        let query = "[out:json][timeout:15];node[\"aeroway\"=\"gate\"](around:3500,\(lat),\(lon));out;"
        req.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query)".data(using: .utf8)

        struct OverpassResponse: Codable {
            struct Element: Codable {
                let lat: Double
                let lon: Double
                let tags: [String: String]?
            }
            let elements: [Element]
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        let parsed = try JSONDecoder().decode(OverpassResponse.self, from: data)
        return parsed.elements.compactMap { e in
            guard let ref = e.tags?["ref"], !ref.isEmpty else { return nil }
            return Gate(ref: ref, lat: e.lat, lon: e.lon)
        }
    }

    /// Fire-and-forget gate observation for the prediction flywheel — the
    /// Worker upserts ONE row per flight per day, so calling this repeatedly
    /// is free-tier-safe by design.
    func observeGates(_ bodyJSON: Data) async {
        await postJSON(path: "/gates/observe", data: bodyJSON)
    }

    /// Matches an airline-reported gate ("A54", "54", "B 12") against OSM
    /// refs. Exact first, then digits-only comparison as a fallback.
    static func matchGate(_ gates: [Gate], to reported: String) -> Gate? {
        let wanted = reported.replacingOccurrences(of: " ", with: "").uppercased()
        if let exact = gates.first(where: { $0.ref.replacingOccurrences(of: " ", with: "").uppercased() == wanted }) {
            return exact
        }
        let wantedDigits = wanted.filter(\.isNumber)
        guard !wantedDigits.isEmpty else { return nil }
        return gates.first { $0.ref.filter(\.isNumber) == wantedDigits }
    }

    // MARK: - Live Activity push registration

    /// Registers an APNs Live Activity token with the Worker, which stores it
    /// and pushes content-state updates from its every-minute cron — this is
    /// what makes the Live Activity move with the app fully closed.
    /// Takes pre-serialized JSON (`Data` is Sendable; `[String: Any]` isn't,
    /// so callers on other actors couldn't hand a dictionary across).
    func registerLiveActivityToken(_ bodyJSON: Data) async {
        await postJSON(path: "/la/register", data: bodyJSON)
    }

    func unregisterLiveActivityToken(_ token: String) async {
        guard let data = try? JSONSerialization.data(withJSONObject: ["token": token]) else { return }
        await postJSON(path: "/la/unregister", data: data)
    }

    private func postJSON(path: String, data: Data) async {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        _ = try? await session.data(for: req)   // best-effort; cron just won't know about us on failure
    }
}
