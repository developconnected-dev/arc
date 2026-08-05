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
        /// The codeshare marketing number the search was made with, when the
        /// backend had to resolve it to the operating flight — "A31653" for a
        /// leg that comes back as LH1751. nil for an ordinary flight, and for
        /// any older backend, so it must stay optional. `var` with a default
        /// so decoding tolerates its absence and callers building one by hand
        /// (tests, fixtures) don't have to name it.
        var marketing_number: String? = nil
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

    // MARK: - Arrival stand

    /// Gate, terminal and belt for an arriving flight.
    ///
    /// The flight-by-number endpoint never carries an arrival gate; the airport
    /// FIDS feed does, but only where the airport publishes stands — Frankfurt
    /// does, Zurich and Heathrow don't. So this legitimately returns nil a lot,
    /// and callers must treat "no gate" as normal rather than as an error.
    struct ArrivalStand: Codable, Sendable {
        let flight: String
        let gate: String?
        let terminal: String?
        let belt: String?
    }

    /// `from`/`to` must be LOCAL to the arrival airport — the backend has no
    /// timezone database, the app does.
    func arrivalStand(icao: String, flight: String,
                      arrival: Date, timeZone: TimeZone) async -> ArrivalStand? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.timeZone = timeZone

        // A window either side of the scheduled arrival, so an early or late
        // aircraft is still inside it.
        let url = baseURL.appending(path: "/arrival-gate").appending(queryItems: [
            .init(name: "icao", value: icao.uppercased()),
            .init(name: "flight", value: flight.replacingOccurrences(of: " ", with: "").uppercased()),
            .init(name: "from", value: formatter.string(from: arrival.addingTimeInterval(-45 * 60))),
            .init(name: "to", value: formatter.string(from: arrival.addingTimeInterval(45 * 60))),
        ])
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(ArrivalStand.self, from: data)
    }

    // MARK: - Airport conditions (what actually delays a departure)

    struct AirportConditions: Codable, Sendable {
        let icao: String
        let now: DelayRisk.Conditions?
        let atTime: DelayRisk.Conditions?
    }

    /// Current METAR plus the TAF period covering `at`. Global coverage, so
    /// European stations work exactly like US ones.
    func airportConditions(icao: String, at date: Date) async throws -> AirportConditions? {
        let url = baseURL.appending(path: "/weather/airport")
            .appending(queryItems: [
                URLQueryItem(name: "icao", value: icao.uppercased()),
                URLQueryItem(name: "at", value: ISO8601DateFormatter().string(from: date)),
            ])
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(AirportConditions.self, from: data)
    }

    // MARK: - En-route weather hazards (real SIGMETs)

    /// A published hazard area: a real polygon from a SIGMET/AIRMET, not a
    /// shape derived from the flight number.
    struct WeatherHazard: Codable, Sendable, Identifiable {
        struct Coord: Codable, Sendable { let lat: Double; let lon: Double }
        let kind: String        // "thunderstorms", "turbulence", "icing", …
        let severe: Bool
        let base: Int?          // feet
        let top: Int?
        let region: String?
        let coords: [Coord]

        /// Stable across refreshes so SwiftUI doesn't rebuild every polygon:
        /// two advisories can't share a kind, altitude band and first vertex.
        var id: String {
            let first = coords.first.map { "\($0.lat),\($0.lon)" } ?? "?"
            return "\(kind)|\(base ?? -1)|\(top ?? -1)|\(first)"
        }

        /// "Thunderstorms · FL180–450" — altitudes in flight levels, the unit
        /// the advisory itself uses.
        var label: String {
            var text = kind.capitalized
            if let top {
                let lower = base.map { "FL\($0 / 100)–" } ?? "below FL"
                text += " · \(lower)\(top / 100)"
            }
            return text
        }
    }

    private struct WeatherHazardResponse: Codable, Sendable { let hazards: [WeatherHazard] }

    func weatherHazards() async throws -> [WeatherHazard] {
        let (data, response) = try await session.data(from: baseURL.appending(path: "/weather/hazards"))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        return try JSONDecoder().decode(WeatherHazardResponse.self, from: data).hazards
    }

    // MARK: - Natural Language & AI Booking Parsing

    struct ParsedFlightItem: Codable, Sendable {
        let flightNumber: String
        let date: String
    }
    struct ParseBookingResponse: Codable, Sendable {
        let flights: [ParsedFlightItem]
    }

    func parseBooking(text: String) async throws -> [ParsedFlightItem] {
        let url = baseURL.appending(path: "/parse-booking")
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["text": text])
        let (data, _) = try await session.data(for: req)
        let response = try JSONDecoder().decode(ParseBookingResponse.self, from: data)
        return response.flights
    }

    private struct NaturalSearchResponse: Codable, Sendable {
        let flights: [FlightSearchResult]
    }

    /// Free-text search: routes ("Athens to Munich on 18 September"), codeshare
    /// numbers, pasted confirmations. The Worker parses the text, discovers
    /// candidate flights from real departure boards, and returns only
    /// candidates verified against schedule data for the date — so everything
    /// in the list is a real, addable flight.
    /// `depIATA`/`arrIATA`/`dateISO`: route already resolved locally — the
    /// Worker skips its AI parse entirely, which is most of a warm search's
    /// latency.
    func searchNatural(query: String, depIATA: String? = nil, arrIATA: String? = nil,
                       dateISO: String? = nil) async throws -> [FlightSearchResult] {
        let url = baseURL.appending(path: "/search-flights")
        // The Worker reads departure boards and verifies every candidate
        // before answering — a cold search takes well over the session's
        // 15 s idle timeout. Without this override the request times out
        // and the caller's `try?` shows it as "no flights found".
        var req = URLRequest(url: url, timeoutInterval: 90)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload = ["query": query]
        payload["dep_iata"] = depIATA
        payload["arr_iata"] = arrIATA
        payload["date"] = dateISO
        req.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        return (try? JSONDecoder().decode(NaturalSearchResponse.self, from: data))?.flights ?? []
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
        let registration: String?
        /// Seconds since the fix was received. A five-minute-old position looks
        /// identical to a current one on a map, so callers get to know.
        let age_seconds: Int?

        var isStale: Bool { (age_seconds ?? 0) > 120 }
    }

    /// A live fix by hex code or registration — either identifies the aircraft,
    /// and a flight added before its aircraft was assigned has only the latter.
    func livePosition(icao24: String? = nil, registration: String? = nil) async throws -> LivePosition? {
        var items: [URLQueryItem] = []
        if let icao24, !icao24.isEmpty { items.append(.init(name: "icao24", value: icao24)) }
        if let registration, !registration.isEmpty { items.append(.init(name: "reg", value: registration)) }
        guard !items.isEmpty else { return nil }

        let url = baseURL.appending(path: "/position").appending(queryItems: items)
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(LivePosition.self, from: data)
    }

    // MARK: - Security Wait Times

    struct SecurityInfo: Codable, Sendable {
        let iata: String
        let securityMinutes: Int?
        let source: String?
        /// When the queue was actually measured. Only present on a real reading
        /// — a "live" number of unknown age is barely better than a guess, so
        /// callers that show it as live should show this alongside.
        let updatedAt: String?
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
